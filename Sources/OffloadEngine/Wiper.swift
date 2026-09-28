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

    /// Per-file: claim exclusively, then validate identity and hash before removal.
    /// ENOENT is tolerated (already gone); any other surprise stops the loop.
    static func execute(deletions: [WipeGate.PlannedDeletion],
                        journal: Journal,
                        sessionID: UUID,
                        fileIDs: [UUID: WipeGate.PlannedDeletion],
                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result {
        var result = Result()
        for (index, deletion) in deletions.enumerated() {
            do {
                try Task.checkCancellation()
                try await removeApproved(deletion)
                await journal.transition(file: deletion.fileID, to: .wiped, in: sessionID)
                result.filesDeleted += 1
                onProgress?(index + 1, deletions.count)
            } catch {
                result.stoppedEarly = "Erasure stopped at \(deletion.absolutePath): \(error.localizedDescription)"
                break
            }
        }
        return result
    }

    /// Anchor every operation to a directory descriptor. First claim the file by
    /// a unique, exclusive rename, then validate the claimed inode and contents.
    /// A replacement at the original name is never unlinked. On failure restore
    /// exclusively, or leave a clearly reported recovery file if the name is taken.
    private static func removeApproved(_ deletion: WipeGate.PlannedDeletion) async throws {
        let (parent, name) = try openParent(root: deletion.cardRoot, relative: deletion.relativePath)
        defer { close(parent) }
        let claimed = recoveryName(fileID: deletion.fileID, name: name)
        guard renameatx_np(parent, name, parent, claimed, UInt32(RENAME_EXCL)) == 0 else {
            if errno == ENOENT { return }
            throw OffloadError.posix(errno, stage: "claim source for erasure")
        }
        do {
            let fd = openat(parent, claimed, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw OffloadError.posix(errno, stage: "open claimed source") }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, matches(before, deletion.expected) else {
                throw OffloadError(.sourceChangedDuringCopy)
            }
            if let hash = deletion.sourceHash {
                guard try await ChunkedIO.hashOpenFile(fd, noCache: true) == hash else {
                    throw OffloadError(.sourceChangedDuringCopy)
                }
            }
            try Task.checkCancellation()
            var after = stat(), named = stat()
            guard fstat(fd, &after) == 0, matches(after, deletion.expected),
                  fstatat(parent, claimed, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_ino == before.st_ino, named.st_dev == before.st_dev else {
                throw OffloadError(.sourceChangedDuringCopy)
            }
            guard unlinkat(parent, claimed, 0) == 0 else {
                throw OffloadError.posix(errno, stage: "remove verified source")
            }
        } catch {
            if renameatx_np(parent, claimed, parent, name, UInt32(RENAME_EXCL)) != 0 {
                throw OffloadError(.internalError("Source preserved as \(claimed) in its original folder; restore it before retrying. \(error.localizedDescription)"))
            }
            throw error
        }
    }

    static func recoveryName(fileID: UUID, name: String) -> String {
        ".offload-recovery-\(fileID.uuidString)"
    }

    /// A process can stop between claiming and deleting/restoring. Recover that
    /// exact journaled file before evaluating a new wipe verdict.
    static func restoreInterruptedClaims(files: [FileRecord], root: String) throws {
        for file in files {
            let parent: Int32, name: String
            do { (parent, name) = try openParent(root: root, relative: file.relPath) }
            catch let error as OffloadError {
                if case .ioError(let code, _) = error.failure, code == ENOENT { continue }
                throw error
            }
            defer { close(parent) }
            let claimed = recoveryName(fileID: file.id, name: name)
            var st = stat()
            if fstatat(parent, claimed, &st, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw OffloadError.posix(errno, stage: "inspect interrupted erasure")
            }
            guard renameatx_np(parent, claimed, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                throw OffloadError(.internalError("Interrupted erasure preserved \(claimed). Original name is occupied or cannot be restored; neither file was deleted."))
            }
        }
    }

    private static func openParent(root: String, relative: String) throws -> (Int32, String) {
        let parts = relative.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(".."), !relative.hasPrefix("/") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var parent = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw OffloadError.posix(errno, stage: "open card for erasure") }
        for component in parts.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0 {
                let code = errno; close(parent)
                throw OffloadError.posix(code, stage: "open erasure parent")
            }
            close(parent); parent = next
        }
        return (parent, name)
    }

    private static func matches(_ st: stat, _ expected: WipeGate.LStatResult) -> Bool {
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        return (st.st_mode & S_IFMT) == S_IFREG && Int64(st.st_size) == expected.size
            && mtime == expected.mtime
            && (expected.inode == nil || expected.inode == st.st_ino)
            && (expected.device == nil || expected.device == st.st_dev)
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
