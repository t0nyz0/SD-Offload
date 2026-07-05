import Foundation
import OffloadCore

/// Scans a card, builds the manifest, and merges against an incomplete journal
/// session (resume). Destination-collision resolution against EXISTING NAS
/// files happens at upload time (dest state can change between plan and
/// upload); the planner only dedupes within the plan itself.
public struct IngestPlanner: Sendable {
    /// Camera media roots. Verified on a Fujifilm card: the root also carries
    /// FFDB/ and UPD/ camera-system folders that must never be uploaded or wiped.
    public static let mediaRoots = ["DCIM", "PRIVATE", "AVCHD", "CLIP", "MP_ROOT"]
    static let skippedDirNames: Set<String> = [".Spotlight-V100", ".Trashes", ".fseventsd", "System Volume Information"]

    public let router: DestinationRouting
    public let dater: CaptureDating

    public init(router: DestinationRouting = DateFolderRouter(), dater: CaptureDating = CaptureDater()) {
        self.router = router
        self.dater = dater
    }

    public struct Plan: Sendable {
        public var files: [FileRecord]
        /// Bytes that still need a hop-1 read (excludes ≥ stagedVerified on resume).
        public var bytesToRead: Int64
        public var resumed: Bool
    }

    public struct ScannedFile: Sendable {
        public let relPath: String
        public let size: Int64
        public let mtime: Date
        public let creationDate: Date?
        public let url: URL
    }

    // MARK: - Scan

    public func scan(cardRoot rawRoot: URL, scope: IngestScope) -> [ScannedFile] {
        let fm = FileManager.default
        // Compute relative paths by diffing resolved path COMPONENTS, not string
        // replacement: FileManager's enumerator canonicalizes child URLs (e.g.
        // /var → /private/var) independently of the root string, which breaks a
        // naive prefix strip. Resolving both sides makes the root a true prefix.
        let cardRoot = rawRoot.resolvingSymlinksInPath()
        let rootComps = cardRoot.pathComponents
        var roots: [URL] = []
        switch scope {
        case .mediaRootsOnly:
            for name in Self.mediaRoots {
                let url = cardRoot.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    roots.append(url)
                }
            }
        case .wholeCard:
            roots = [cardRoot]
        }

        var out: [ScannedFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey, .isDirectoryKey]
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    if Self.skippedDirNames.contains(name) { enumerator.skipDescendants() }
                    continue
                }
                // Belt and braces beyond .skipsHiddenFiles — hidden-flag
                // semantics on FSKit-exFAT are not worth trusting.
                if name.hasPrefix("._") || name == ".DS_Store" { continue }
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true else { continue }

                let comps = url.resolvingSymlinksInPath().pathComponents
                guard comps.count > rootComps.count else { continue }
                let relPath = comps[rootComps.count...].joined(separator: "/")
                out.append(ScannedFile(relPath: relPath,
                                       size: Int64(values.fileSize ?? 0),
                                       mtime: values.contentModificationDate ?? .distantPast,
                                       creationDate: values.creationDate,
                                       url: url))
            }
        }
        return out.sorted { $0.relPath < $1.relPath }   // deterministic order
    }

    // MARK: - Plan (fresh)

    public func plan(scanned: [ScannedFile]) async -> Plan {
        var records: [FileRecord] = []
        records.reserveCapacity(scanned.count)

        // Capture-date extraction 4-wide (a 1,000-file card plans in ~1–2 s).
        let dated: [(ScannedFile, Date)] = await withTaskGroup(of: (Int, Date).self) { group in
            var results = [Date?](repeating: nil, count: scanned.count)
            var next = 0
            var inFlight = 0
            func submit(_ index: Int) {
                let file = scanned[index]
                let dater = self.dater
                group.addTask {
                    (index, dater.captureDate(of: file.url, creationDate: file.creationDate, mtime: file.mtime))
                }
            }
            while next < min(4, scanned.count) { submit(next); next += 1; inFlight += 1 }
            while inFlight > 0 {
                guard let (index, date) = await group.next() else { break }
                results[index] = date
                inFlight -= 1
                if next < scanned.count { submit(next); next += 1; inFlight += 1 }
            }
            return zip(scanned, results).map { ($0, $1 ?? $0.mtime) }
        }

        // Within-plan collision dedupe: deterministic (sorted input) suffixing.
        var takenDest: Set<String> = []
        for (file, captureDate) in dated {
            var dest = router.destinationRelPath(fileName: (file.relPath as NSString).lastPathComponent,
                                                 captureDate: captureDate)
            var attempt = 2
            while takenDest.contains(dest) {
                dest = CollisionPolicy.suffixed(
                    router.destinationRelPath(fileName: (file.relPath as NSString).lastPathComponent,
                                              captureDate: captureDate),
                    attempt: attempt)
                attempt += 1
            }
            takenDest.insert(dest)
            records.append(FileRecord(relPath: file.relPath, size: file.size, mtime: file.mtime,
                                      creationDate: file.creationDate, captureDate: captureDate,
                                      destRelPath: dest))
        }

        let bytes = records.reduce(Int64(0)) { $0 + $1.size }
        return Plan(files: records, bytesToRead: bytes, resumed: false)
    }

    // MARK: - Resume merge

    /// Merge a fresh scan against an incomplete session (crash-remapped by the
    /// journal). Identity = relPath + size + mtime(±2 s, exFAT granularity).
    public func merge(scanned: [ScannedFile], into existing: [FileRecord]) async -> Plan {
        var byRelPath = Dictionary(uniqueKeysWithValues: scanned.map { ($0.relPath, $0) })
        var merged: [FileRecord] = []
        merged.reserveCapacity(existing.count)

        for var record in existing {
            if let match = byRelPath.removeValue(forKey: record.relPath) {
                let sameIdentity = match.size == record.size &&
                    abs(match.mtime.timeIntervalSince(record.mtime)) <= 2
                if sameIdentity {
                    merged.append(record)
                } else if record.state.isWipeEligible {
                    // Data already safe; the changed card file is a NEW file.
                    merged.append(record)
                    byRelPath[match.relPath] = match
                } else {
                    record.state = .failed(.sourceChangedDuringCopy)
                    merged.append(record)
                    byRelPath[match.relPath] = match
                }
            } else {
                // In manifest, missing from card.
                if record.state.isWipeEligible {
                    merged.append(record)   // data safe; nothing to wipe — gate tolerates ENOENT here
                } else {
                    record.state = .failed(.sourceMissing)
                    merged.append(record)
                }
            }
        }

        // Files the camera added between insertions → plan fresh.
        let newcomers = byRelPath.values.sorted { $0.relPath < $1.relPath }
        if !newcomers.isEmpty {
            let fresh = await plan(scanned: Array(newcomers))
            var taken = Set(merged.map(\.destRelPath))
            for var record in fresh.files {
                var attempt = 2
                let base = record.destRelPath
                while taken.contains(record.destRelPath) {
                    record.destRelPath = CollisionPolicy.suffixed(base, attempt: attempt)
                    attempt += 1
                }
                taken.insert(record.destRelPath)
                merged.append(record)
            }
        }

        let bytesToRead = merged
            .filter { !$0.state.isPastStaging }
            .reduce(Int64(0)) { $0 + $1.size }
        return Plan(files: merged, bytesToRead: bytesToRead, resumed: true)
    }
}

extension FileState {
    /// States where the hop-1 read is behind us.
    var isPastStaging: Bool {
        switch self {
        case .stagedVerified, .uploading, .uploaded, .nasVerified, .skippedDuplicate, .wiped:
            return true
        case .pending, .copying, .staged, .failed:
            return false
        }
    }
}
