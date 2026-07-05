import Foundation
import OffloadCore

/// Executes an APPROVED wipe verdict. The countdown and the gate evaluation
/// happen in SessionRunner BEFORE this runs; this is just the careful unlink
/// loop + empty-dir prune.
struct Wiper {
    struct Result: Sendable {
        var filesDeleted = 0
        var stoppedEarly: String?   // first unexpected error — deletion stops there
    }

    /// Per-file: a FINAL lstat guard immediately before unlink(2). ENOENT is
    /// tolerated (already gone); any other surprise stops the loop.
    static func execute(deletions: [WipeGate.PlannedDeletion],
                        journal: Journal,
                        sessionID: UUID,
                        fileIDs: [UUID: WipeGate.PlannedDeletion],
                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result {
        var result = Result()
        for (index, deletion) in deletions.enumerated() {
            guard let st = WipeGate.liveStat(deletion.absolutePath) else {
                // Already gone — count as done, journal it.
                await journal.transition(file: deletion.fileID, to: .wiped, in: sessionID)
                result.filesDeleted += 1
                onProgress?(index + 1, deletions.count)
                continue
            }
            guard st.isRegularFile, !st.isSymlink else {
                result.stoppedEarly = "\(deletion.absolutePath) is no longer a regular file"
                break
            }
            if unlink(deletion.absolutePath) != 0 {
                if errno == ENOENT {
                    await journal.transition(file: deletion.fileID, to: .wiped, in: sessionID)
                    result.filesDeleted += 1
                    onProgress?(index + 1, deletions.count)
                    continue
                }
                result.stoppedEarly = "unlink \(deletion.absolutePath): \(String(cString: strerror(errno)))"
                break
            }
            await journal.transition(file: deletion.fileID, to: .wiped, in: sessionID)
            result.filesDeleted += 1
            onProgress?(index + 1, deletions.count)
        }
        return result
    }

    /// Deepest-first rmdir(2) of the deletions' parent directories. rmdir
    /// fails on non-empty — exactly the guard we want (no recursive deletes,
    /// EVER). Never removes media roots or the mount root.
    static func pruneEmptyDirectories(deletions: [WipeGate.PlannedDeletion], cardRoot: String) {
        let root = cardRoot.hasSuffix("/") ? String(cardRoot.dropLast()) : cardRoot
        let protected: Set<String> = Set(
            IngestPlanner.mediaRoots.map { root + "/" + $0 } + [root]
        )
        var parents: Set<String> = []
        for deletion in deletions {
            var dir = (deletion.absolutePath as NSString).deletingLastPathComponent
            while dir.count > root.count, !protected.contains(dir) {
                parents.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        for dir in parents.sorted(by: { $0.count > $1.count }) {
            rmdir(dir)   // fails on non-empty — by design
        }
    }
}
