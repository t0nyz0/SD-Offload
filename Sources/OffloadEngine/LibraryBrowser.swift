import Foundation
import OffloadCore

/// Read-only browsing + counting of a photo library root (the NAS, or a card).
/// Browsing is lazy per-directory (fast, even over SMB); counting walks the
/// whole tree progressively and caches the total.
public struct LibraryBrowser: Sendable {
    public init() {}

    /// List one directory: subfolders first (newest-name first, so date folders
    /// read chronologically), then media files (by name). Non-media and hidden
    /// files are skipped.
    public func browse(_ directory: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var folders: [LibraryEntry] = []
        var media: [LibraryEntry] = []
        for url in items {
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

    /// Count media under a root, reporting partial progress as it walks. Cheap
    /// per-file (no hashing); one callback per ~250 files keeps the UI live.
    public func countMedia(root: URL, isCancelled: @Sendable () -> Bool = { false },
                           progress: @Sendable (_ count: Int, _ bytes: Int64, _ byYear: [String: Int]) -> Void) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else {
            progress(0, 0, [:]); return
        }
        var count = 0
        var bytes: Int64 = 0
        var byYear: [String: Int] = [:]
        var sinceReport = 0
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            if isCancelled() { break }
            guard MediaKind.isMedia(url.pathExtension) else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            guard vals?.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(vals?.fileSize ?? 0)
            // First path component under root that looks like a year.
            let rel = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.path
            if let first = rel.split(separator: "/").first, first.count == 4, Int(first) != nil {
                byYear[String(first), default: 0] += 1
            }
            sinceReport += 1
            if sinceReport >= 250 {
                sinceReport = 0
                progress(count, bytes, byYear)
            }
        }
        progress(count, bytes, byYear)
    }
}
