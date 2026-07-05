import Foundation
import OffloadCore

/// The "no mistakes" core: a PURE precondition checker. Every dependency is
/// injected (card snapshot, NAS health, a stat closure) so the full truth
/// table is unit-tested without a filesystem.
///
/// STRICT ALL-OR-NOTHING: any blocker ⇒ delete NOTHING.
public struct WipeGate {
    public struct CardMountSnapshot: Sendable, Equatable {
        public let volumeUUID: String
        public let rootPath: String
        public let isReadOnly: Bool
        public init(volumeUUID: String, rootPath: String, isReadOnly: Bool) {
            self.volumeUUID = volumeUUID; self.rootPath = rootPath; self.isReadOnly = isReadOnly
        }
    }

    public struct LStatResult: Sendable, Equatable {
        public let isRegularFile: Bool
        public let isSymlink: Bool
        public let isDirectory: Bool
        public let size: Int64
        public let mtime: Date
        public init(isRegularFile: Bool, isSymlink: Bool, isDirectory: Bool, size: Int64, mtime: Date) {
            self.isRegularFile = isRegularFile; self.isSymlink = isSymlink
            self.isDirectory = isDirectory; self.size = size; self.mtime = mtime
        }
    }

    public struct PlannedDeletion: Sendable, Equatable {
        public let fileID: UUID
        public let absolutePath: String
    }

    public enum Blocker: Equatable, Sendable, CustomStringConvertible {
        case emptyManifest
        case fileNotTerminal(String)
        case fileFailed(String, String)
        case nasUnhealthy(String)
        case cardNotMounted
        case cardUUIDMismatch
        case cardReadOnly
        case statMismatch(String, String)
        case symlinkOrIrregular(String)
        case pathEscapesCard(String)
        case parentNotPlainDirectory(String)
        case journalNotFlushed
        case cardTokenMismatch

        public var description: String {
            switch self {
            case .emptyManifest: "nothing was planned — refusing to treat an empty scan as success"
            case .fileNotTerminal(let p): "\(p) is not fully transferred"
            case .fileFailed(let p, let why): "\(p) failed: \(why)"
            case .nasUnhealthy(let why): "NAS is not healthy right now (\(why))"
            case .cardNotMounted: "the card is not mounted"
            case .cardUUIDMismatch: "a different card is mounted"
            case .cardReadOnly: "the card's lock switch is on"
            case .statMismatch(let p, let why): "\(p) changed on the card since planning (\(why))"
            case .symlinkOrIrregular(let p): "\(p) is not a regular file"
            case .pathEscapesCard(let p): "\(p) escapes the card mount"
            case .parentNotPlainDirectory(let p): "parent folder \(p) is not a plain directory"
            case .journalNotFlushed: "journal not flushed to disk"
            case .cardTokenMismatch: "the inserted card is not the one this session was copying"
            }
        }
    }

    public struct Verdict: Equatable, Sendable {
        public let allowed: Bool
        public let blockers: [Blocker]
        public let deletions: [PlannedDeletion]
        /// nasVerified files already absent from the card (nothing to delete) —
        /// legitimate after a resume where the camera deleted files; reported.
        public let alreadyAbsent: [UUID]
    }

    /// The checklist — ALL must pass.
    public static func evaluate(session: SessionRecord,
                                policy: WipePolicy,
                                cardMount: CardMountSnapshot?,
                                nasHealth: NASHealth,
                                statOf: (String) -> LStatResult?,
                                journalFlushed: Bool,
                                cardTokenOnCard: String? = nil) -> Verdict {
        var blockers: [Blocker] = []

        // 1. Non-empty manifest.
        if session.files.isEmpty { blockers.append(.emptyManifest) }

        // 1b. Per-card token: if this session stamped the card, the card in the
        //     slot right now must carry the SAME token. This defeats the
        //     synthesized-UUID collision where a different physical card of the
        //     same size/name could otherwise be re-stat-matched and wiped.
        if let expected = session.cardSessionToken, expected != cardTokenOnCard {
            blockers.append(.cardTokenMismatch)
        }

        // 2 + 3. Policy satisfied; zero failed; zero non-terminal.
        for file in session.files {
            switch file.state {
            case .failed(let why):
                blockers.append(.fileFailed(file.relPath, why.summary))
            case .nasVerified, .skippedDuplicate, .wiped:
                break
            case .stagedVerified, .uploading, .uploaded:
                // Safe under afterStagingVerify (the fsync'd staged copy is the
                // safety net); not under the NAS policies.
                if policy != .afterStagingVerify {
                    blockers.append(.fileNotTerminal(file.relPath))
                }
            case .pending, .copying, .staged:
                blockers.append(.fileNotTerminal(file.relPath))
            }
        }

        // 4. NAS healthy RIGHT NOW (a ghost here means the verifications may
        //    predate an unmount). Not required for afterStagingVerify.
        if policy != .afterStagingVerify && nasHealth != .healthy {
            blockers.append(.nasUnhealthy(nasHealth.summary))
        }

        // 5. Card present, same card, writable.
        guard let card = cardMount else {
            blockers.append(.cardNotMounted)
            return Verdict(allowed: false, blockers: blockers, deletions: [], alreadyAbsent: [])
        }
        if card.volumeUUID != session.cardVolumeUUID { blockers.append(.cardUUIDMismatch) }
        if card.isReadOnly { blockers.append(.cardReadOnly) }

        // 6 + 7. Per-file re-stat + path containment. Paths come ONLY from the
        //    manifest — never from re-enumeration.
        var deletions: [PlannedDeletion] = []
        var alreadyAbsent: [UUID] = []
        var checkedParents: Set<String> = []
        let root = card.rootPath.hasSuffix("/") ? String(card.rootPath.dropLast()) : card.rootPath

        for file in session.files where file.state.isWipeEligible {
            if file.state == .wiped { continue }   // already unlinked (crash-mid-wipe reconciliation)
            let rel = file.relPath
            if rel.hasPrefix("/") || rel.split(separator: "/").contains("..") || rel.isEmpty {
                blockers.append(.pathEscapesCard(rel))
                continue
            }
            let absolute = root + "/" + rel

            // Parent chain: every component must be a real directory, no symlinks.
            var parent = (absolute as NSString).deletingLastPathComponent
            var parentOK = true
            while parent.count > root.count {
                if !checkedParents.contains(parent) {
                    guard let st = statOf(parent), st.isDirectory, !st.isSymlink else {
                        blockers.append(.parentNotPlainDirectory(parent))
                        parentOK = false
                        break
                    }
                    checkedParents.insert(parent)
                }
                parent = (parent as NSString).deletingLastPathComponent
            }
            guard parentOK else { continue }

            guard let st = statOf(absolute) else {
                // ENOENT on a verified file: data is safe on the NAS, there is
                // simply nothing to delete (camera deleted it between inserts).
                alreadyAbsent.append(file.id)
                continue
            }
            if st.isSymlink || !st.isRegularFile {
                blockers.append(.symlinkOrIrregular(rel))
                continue
            }
            if st.size != file.size {
                blockers.append(.statMismatch(rel, "size \(st.size) ≠ \(file.size)"))
                continue
            }
            // exFAT timestamp granularity: ±2 s.
            if abs(st.mtime.timeIntervalSince(file.mtime)) > 2 {
                blockers.append(.statMismatch(rel, "modified since planning"))
                continue
            }
            deletions.append(PlannedDeletion(fileID: file.id, absolutePath: absolute))
        }

        // 8. Journal durably on disk before anything is destroyed.
        if !journalFlushed { blockers.append(.journalNotFlushed) }

        let allowed = blockers.isEmpty
        return Verdict(allowed: allowed,
                       blockers: blockers,
                       deletions: allowed ? deletions : [],
                       alreadyAbsent: alreadyAbsent)
    }

    /// Live lstat closure for production use.
    public static func liveStat(_ path: String) -> LStatResult? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        return LStatResult(
            isRegularFile: mode == S_IFREG,
            isSymlink: mode == S_IFLNK,
            isDirectory: mode == S_IFDIR,
            size: Int64(st.st_size),
            mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) +
                        TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        )
    }
}
