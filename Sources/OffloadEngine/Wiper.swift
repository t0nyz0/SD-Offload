import Foundation
import OffloadCore

/// Executes an APPROVED wipe verdict. The countdown and the gate evaluation
/// happen in SessionRunner BEFORE this runs; this is just the careful unlink
/// loop + empty-dir prune.
struct Wiper {
    typealias ExclusiveRename = @Sendable (Int32, String, Int32, String) -> Int32
    static let liveExclusiveRename: ExclusiveRename = { fromFD, from, toFD, to in
        renameatx_np(fromFD, from, toFD, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }

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
                        exclusiveRename: @escaping ExclusiveRename = liveExclusiveRename,
                        onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> Result {
        var result = Result()
        for (index, deletion) in deletions.enumerated() {
            do {
                try Task.checkCancellation()
                try await removeApproved(deletion, exclusiveRename: exclusiveRename)
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

    /// Pin the approved source before claiming it. Rename can change exFAT's
    /// directory-derived inode, so compare the claimed name to the pinned open
    /// descriptor AFTER the rename, rather than to a stale pre-rename inode.
    private static func removeApproved(_ deletion: WipeGate.PlannedDeletion,
                                       exclusiveRename: @escaping ExclusiveRename) async throws {
        let (parent, name) = try openParent(root: deletion.cardRoot, relative: deletion.relativePath)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return }
            throw OffloadError.posix(errno, stage: "open approved source")
        }
        defer { close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, matches(original, deletion.expected) else {
            throw OffloadError(.sourceChangedDuringCopy)
        }
        let recovery = recoveryName(fileID: deletion.fileID, name: name)
        guard let claim = try ErasureClaim.acquire(parent: parent, name: name, recovery: recovery,
                                                  exclusiveRename: exclusiveRename) else { return }
        defer { claim.closeDirectory(); claim.removeEmptyContainer(parent: parent) }
        do {
            var before = stat()
            guard fstat(fd, &before) == 0, matchesMetadata(before, deletion.expected),
                  claimMatches(claim, openFile: before) else {
                throw OffloadError(.sourceChangedDuringCopy)
            }
            if let hash = deletion.sourceHash {
                guard try await ChunkedIO.hashOpenFile(fd, noCache: true) == hash else {
                    throw OffloadError(.sourceChangedDuringCopy)
                }
            }
            try Task.checkCancellation()
            var after = stat()
            guard fstat(fd, &after) == 0, matchesMetadata(after, deletion.expected),
                  after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
                  after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                  claimMatches(claim, openFile: after) else {
                throw OffloadError(.sourceChangedDuringCopy)
            }
            guard unlinkat(claim.directory, claim.name, 0) == 0 else {
                throw OffloadError.posix(errno, stage: "remove verified source")
            }
            claim.removeEmptyContainer(parent: parent)
        } catch {
            do {
                // Recovery must complete even when the parent wipe was cancelled.
                try await Task.detached(priority: .userInitiated) {
                    try await restore(claim, parent: parent, name: name, exclusiveRename: exclusiveRename)
                }.value
            } catch let restoreError {
                throw OffloadError(.internalError("Source preserved at \(claim.relativePath) in its original folder; restore it before retrying. \(restoreError.localizedDescription) Original failure: \(error.localizedDescription)"))
            }
            throw error
        }
    }

    private static func claimMatches(_ claim: ErasureClaim, openFile: stat) -> Bool {
        var named = stat()
        return fstatat(claim.directory, claim.name, &named, AT_SYMLINK_NOFOLLOW) == 0
            && (named.st_mode & S_IFMT) == S_IFREG
            && named.st_ino == openFile.st_ino && named.st_dev == openFile.st_dev
    }

    static func recoveryName(fileID: UUID, name: String) -> String {
        ".offload-recovery-\(fileID.uuidString)"
    }

    /// Recover either legacy recovery files or the directory-based claims. Never
    /// replace a file already occupying the original name.
    static func restoreInterruptedClaims(files: [FileRecord], root: String,
                                         exclusiveRename: @escaping ExclusiveRename = liveExclusiveRename) async throws {
        for file in files {
            let parent: Int32, name: String
            do { (parent, name) = try openParent(root: root, relative: file.relPath) }
            catch let error as OffloadError {
                if case .ioError(let code, _) = error.failure, code == ENOENT { continue }
                throw error
            }
            defer { close(parent) }
            let recovery = recoveryName(fileID: file.id, name: name)
            guard let claim = try ErasureClaim.find(parent: parent, recovery: recovery) else { continue }
            defer { claim.closeDirectory(); claim.removeEmptyContainer(parent: parent) }
            try await Task.detached(priority: .userInitiated) {
                try await restore(claim, parent: parent, name: name, exclusiveRename: exclusiveRename)
            }.value
        }
    }

    private static func restore(_ claim: ErasureClaim, parent: Int32, name: String,
                                exclusiveRename: ExclusiveRename) async throws {
        let code = exclusiveRename(claim.directory, claim.name, parent, name)
        if code == 0 { claim.removeEmptyContainer(parent: parent); return }
        guard code == ENOTSUP || code == ENOSYS else {
            throw OffloadError.posix(code, stage: "restore source without replacement")
        }
        // No exclusive rename exists on this filesystem. Restore through exclusive
        // creation, durable copy, and full read-back. The claim remains recoverable
        // until the new original has been verified; collisions preserve both files.
        let source = openat(claim.directory, claim.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard source >= 0 else { throw OffloadError.posix(errno, stage: "open recovery source") }
        defer { close(source) }
        var before = stat()
        guard fstat(source, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw OffloadError(.sourceChangedDuringCopy)
        }
        let dest = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard dest >= 0 else { throw OffloadError.posix(errno, stage: "restore original with exclusive creation") }
        defer { close(dest) }
        var complete = false
        defer {
            if !complete {
                var owned = stat(), named = stat()
                if fstat(dest, &owned) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   owned.st_dev == named.st_dev, owned.st_ino == named.st_ino {
                    _ = unlinkat(parent, name, 0)
                }
            }
        }
        let originalTimes = [before.st_atimespec, before.st_mtimespec]
        try await ChunkedIO.blocking {
            guard fcopyfile(source, dest, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                throw OffloadError.posix(errno, stage: "restore recovery data")
            }
            var times = originalTimes
            guard futimens(dest, &times) == 0, fsync(dest) == 0 else {
                throw OffloadError.posix(errno, stage: "flush restored source")
            }
        }
        guard lseek(source, 0, SEEK_SET) >= 0, lseek(dest, 0, SEEK_SET) >= 0 else {
            throw OffloadError.posix(errno, stage: "rewind restored source")
        }
        let sourceHash = try await ChunkedIO.hashOpenFile(source, noCache: true)
        let destHash = try await ChunkedIO.hashOpenFile(dest, noCache: true)
        var after = stat(), restored = stat(), restoredName = stat()
        guard sourceHash == destHash, fstat(source, &after) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              fstat(dest, &restored) == 0, restored.st_size == before.st_size,
              fstatat(parent, name, &restoredName, AT_SYMLINK_NOFOLLOW) == 0,
              restoredName.st_ino == restored.st_ino, restoredName.st_dev == restored.st_dev,
              claimMatches(claim, openFile: after) else {
            throw OffloadError(.sourceChangedDuringCopy)
        }
        // Mark complete before removing the claim: if unlink fails, preserve both
        // complete copies and let the error name the remaining recovery source.
        complete = true
        guard unlinkat(claim.directory, claim.name, 0) == 0 else {
            throw OffloadError.posix(errno, stage: "remove restored recovery source")
        }
        claim.removeEmptyContainer(parent: parent)
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
        return matchesMetadata(st, expected)
            && (expected.inode == nil || expected.inode == st.st_ino)
            && (expected.device == nil || expected.device == st.st_dev)
    }

    private static func matchesMetadata(_ st: stat, _ expected: WipeGate.LStatResult) -> Bool {
        let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
        return (st.st_mode & S_IFMT) == S_IFREG && Int64(st.st_size) == expected.size
            && mtime == expected.mtime
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
