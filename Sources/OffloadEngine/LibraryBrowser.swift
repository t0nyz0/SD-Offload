import Foundation
import OffloadCore

/// Read-only browsing + counting of a photo library root (the NAS, or a card).
/// Browsing is lazy per-directory (fast, even over SMB); counting walks the
/// whole tree progressively and caches the total.
public struct LibraryBrowser: Sendable {
    public init() {}

    /// Index IDs retain their original spelling. Resolve the root once, off the
    /// UI thread, so both legacy alias IDs and canonical enumeration IDs match.
    public func indexPrefixes(root: URL) -> [String] {
        var prefixes = Set([root.path, root.resolvingSymlinksInPath().path])
        if let resolved = realpath(root.path, nil) {
            prefixes.insert(String(cString: resolved))
            free(resolved)
        }
        return prefixes.sorted()
    }

    /// List one directory: subfolders first (newest-name first, so date folders
    /// read chronologically), then media files (by name). Non-media and hidden
    /// files are skipped.
    public func browse(_ directory: URL) -> [LibraryEntry] {
        (try? browseChecked(directory)) ?? []
    }

    public func browseChecked(_ directory: URL) throws -> [LibraryEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                              options: [.skipsHiddenFiles])
        var folders: [LibraryEntry] = []
        var media: [LibraryEntry] = []
        for url in items {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let modified = vals.contentModificationDate ?? .distantPast
            if vals.isDirectory == true {
                folders.append(LibraryEntry(id: url.path, name: name, kind: .folder, size: 0, modified: modified))
            } else if let kind = MediaKind.classify(ext: url.pathExtension) {
                media.append(LibraryEntry(id: url.path, name: name, kind: .media(kind),
                                          size: Int64(vals.fileSize ?? 0), modified: modified))
            }
        }
        folders.sort { $0.name > $1.name }     // 2026 before 2025; 07 before 06
        media.sort { $0.name < $1.name }
        return folders + media
    }

    /// Every media file under a root (for bulk content analysis).
    public func allMedia(root: URL, isCancelled: @Sendable () -> Bool = { false }) -> [LibraryEntry] {
        (try? allMediaChecked(root: root, isCancelled: isCancelled)) ?? []
    }

    public func allMediaChecked(root: URL, isCancelled: @Sendable () -> Bool = { false }) throws -> [LibraryEntry] {
        if isCancelled() { throw CancellationError() }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var scanError: Error?
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { _, error in
            scanError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var out: [LibraryEntry] = []
        for case let url as URL in e {
            if isCancelled() { throw CancellationError() }
            guard let kind = MediaKind.classify(ext: url.pathExtension) else { continue }
            let v = try url.resourceValues(forKeys: Set(keys))
            guard v.isRegularFile == true else { continue }
            out.append(LibraryEntry(id: url.path, name: url.lastPathComponent, kind: .media(kind),
                                    size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        if let scanError { throw scanError }
        if isCancelled() { throw CancellationError() }
        return out
    }

    /// Pruning is permitted only after a complete, uncancelled inventory.
    public func refreshFaceInventory(root: URL, index: FaceIndex) async throws -> [LibraryEntry] {
        let result = await BackgroundWork.run {
            Result { try allMediaChecked(root: root, isCancelled: { Task.isCancelled }) }
        }
        let media = try result.get()
        try Task.checkCancellation()
        // Foundation may enumerate /var through its /private/var alias. Preserve
        // records under either spelling of the selected root.
        let canonical: String
        if let resolved = realpath(root.path, nil) {
            canonical = String(cString: resolved); free(resolved)
        } else { throw CocoaError(.fileReadUnknown) }
        var keeping = Set(media.map(\.id))
        if canonical != root.path {
            for entry in media where entry.id.hasPrefix(canonical + "/") {
                keeping.insert(root.path + entry.id.dropFirst(canonical.count))
            }
        }
        await index.pruneMissing(underPrefix: root.path, keeping: keeping)
        return media
    }

    /// Up to `limit` representative media files under `folder`, for a folder
    /// preview collage. Walks lazily and stops after finding `scanCap` files,
    /// prefers JPEG/HEIC over RAW, dedupes RAW+JPEG pairs by basename, then
    /// samples evenly across what it found. Cheap over SMB (enumerator is lazy).
    public func sampleMedia(under folder: URL, limit: Int = 4, scanCap: Int = 32,
                            isCancelled: @Sendable () -> Bool = { false }) -> [LibraryEntry] {
        guard limit > 0, scanCap > 0, !isCancelled() else { return [] }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                    options: [.skipsHiddenFiles]) else { return [] }
        var found: [LibraryEntry] = []
        for case let url as URL in e {
            if isCancelled() { return [] }
            guard let kind = MediaKind.classify(ext: url.pathExtension) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            found.append(LibraryEntry(id: url.path, name: url.lastPathComponent, kind: .media(kind),
                                      size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast))
            if found.count >= scanCap { break }
        }
        func isRaw(_ e: LibraryEntry) -> Bool { if case .media(.raw) = e.kind { return true }; return false }
        let ordered = found.sorted { (isRaw($0) ? 1 : 0) < (isRaw($1) ? 1 : 0) }   // JPEGs first
        var seen = Set<String>()
        var uniq: [LibraryEntry] = []
        for entry in ordered {
            let base = (entry.name as NSString).deletingPathExtension.lowercased()
            if seen.insert(base).inserted { uniq.append(entry) }
        }
        guard uniq.count > limit else { return uniq }
        let step = Double(uniq.count) / Double(limit)
        return (0..<limit).map { uniq[min(uniq.count - 1, Int(Double($0) * step))] }
    }

    /// Count media under a root, reporting partial progress as it walks. Cheap
    /// per-file (no hashing); one callback per ~250 files keeps the UI live.
    @discardableResult
    public func countMedia(root: URL, isCancelled: @Sendable () -> Bool = { false },
                           progress: @Sendable (_ count: Int, _ bytes: Int64) -> Void) -> Bool {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var complete = true
        guard !isCancelled() else { return false }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles], errorHandler: { _, _ in
                                                 complete = false
                                                 return false
                                             }) else { return false }
        var count = 0
        var bytes: Int64 = 0
        var sinceReport = 0
        for case let url as URL in enumerator {
            if isCancelled() { return false }
            guard MediaKind.isMedia(url.pathExtension) else { continue }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)) else {
                complete = false
                continue
            }
            guard vals.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(vals.fileSize ?? 0)
            sinceReport += 1
            if sinceReport >= 250 {
                sinceReport = 0
                progress(count, bytes)
            }
        }
        guard complete, !isCancelled() else { return false }
        progress(count, bytes)
        return true
    }
}
