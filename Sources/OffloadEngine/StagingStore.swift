import Foundation
import Darwin
import OffloadCore

/// Layout: <stagingRoot>/<sessionID>/<fileID>-<originalName>[.partial]
/// The fileID prefix dodges name collisions across card folders; the original
/// name is kept so staged files stay readable/inspectable.
public struct StagingStore: Sendable {
    public let root: URL

    public init(rootPath: String) {
        self.root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func requiresReclamation(bytesToRead: Int64, headroomBytes: Int64, freeBytes: Int64) -> Bool {
        let headroom = max(0, headroomBytes)
        return freeBytes < headroom || max(0, bytesToRead) > freeBytes - headroom
    }

    public func sessionDir(_ sessionID: UUID) -> URL {
        root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    public func stagedURL(session: UUID, file: FileRecord) -> URL {
        sessionDir(session).appendingPathComponent("\(file.id.uuidString)-\(file.fileName)")
    }

    public func partialURL(session: UUID, file: FileRecord) -> URL {
        stagedURL(session: session, file: file).appendingPathExtension("partial")
    }

    public func ensureSessionDir(_ sessionID: UUID) throws {
        try FileManager.default.createDirectory(at: sessionDir(sessionID), withIntermediateDirectories: true)
    }

    public func purgeFile(session: UUID, file: FileRecord) {
        try? FileManager.default.removeItem(at: stagedURL(session: session, file: file))
        try? FileManager.default.removeItem(at: partialURL(session: session, file: file))
    }

    public func purgeSession(_ sessionID: UUID) {
        try? FileManager.default.removeItem(at: sessionDir(sessionID))
    }

    /// Remove leftover `.partial` files (crash cleanup at session resume).
    public func removePartials(_ sessionID: UUID) {
        let dir = sessionDir(sessionID)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "partial" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Retire only manifest-owned, NAS-verified files. Session failure, a stopped
    /// wipe, or one missing destination must not strand unrelated verified files.
    func pruneCompletedBeforeNextRun(_ history: [SessionRecord], nasRoot: String,
                                           keepDays: Int, now: Date = Date(),
                                           preparation: PreparationTracker? = nil,
                                           protectedSessionID: UUID? = nil,
                                           secondaryRoot: String? = nil,
                                           deletionStore: DestinationDeletionStore? = nil,
                                           excluding activeSessions: Set<UUID> = [],
                                           protection: StagingMaintenanceGuard? = nil) async {
        for record in history {
            guard !Task.isCancelled, protection?.isIdle != false else { return }
            guard record.id != protectedSessionID, !activeSessions.contains(record.id),
                  isPlainSession(record.id) else { continue }
            let verified = record.files.filter { file in
                file.state.recordsNASVerification && !(file.sourceHashHex ?? "").isEmpty
                    && now.timeIntervalSince(record.endedAt ?? file.stateChangedAt) >= Double(max(0, keepDays)) * 86_400
            }
            preparation?.beginSavedCopyCheck(verified)
            for file in verified {
                guard !Task.isCancelled, protection?.isIdle != false else { return }
                guard hasManagedCopy(session: record.id, file: file) else { continue }
                do {
                    var canonicalSource: URL?
                    do {
                        try await DestinationVerifier.verify(files: [file], root: nasRoot,
                            tracker: preparation?.savedCopyTracker)
                        if let secondaryRoot, !secondaryRoot.isEmpty {
                            try await DestinationVerifier.verify(files: [file], root: secondaryRoot)
                        }
                        canonicalSource = URL(fileURLWithPath: nasRoot).appendingPathComponent(file.destRelPath)
                    } catch {
                        // A missing NAS file is never reconstructed. Only durable
                        // user deletion intent permits retiring that recovery copy.
                        guard try deletionStore?.permitsRetirement(of: file, root: nasRoot) == true,
                              destinationIsAbsent(file, root: nasRoot) else { continue }
                    }
                    try Task.checkCancellation()
                    _ = try await retireVerifiedFile(session: record.id, file: file,
                        protection: protection, canonicalSource: canonicalSource)
                } catch {
                    // Retain unconfirmed/changed local data and retry when idle.
                    continue
                }
            }
            let removeEmpty = { () -> Bool in
                guard !Task.isCancelled, self.isPlainSession(record.id) else { return false }
                return rmdir(self.sessionDir(record.id).path) == 0
            }
            if let protection { _ = protection.whileIdle(removeEmpty) }
            else { _ = removeEmpty() }
        }
    }

    private func isPlainSession(_ session: UUID) -> Bool {
        guard let base = WipeGate.liveStat(root.path), base.isDirectory, !base.isSymlink,
              let dir = WipeGate.liveStat(sessionDir(session).path), dir.isDirectory, !dir.isSymlink else { return false }
        return true
    }

    private func hasManagedCopy(session: UUID, file: FileRecord) -> Bool {
        [stagedURL(session: session, file: file), partialURL(session: session, file: file)]
            .contains { WipeGate.liveStat($0.path) != nil }
    }

    private func destinationIsAbsent(_ file: FileRecord, root: String) -> Bool {
        guard !file.destRelPath.hasPrefix("/"), !file.destRelPath.split(separator: "/").contains("..") else { return false }
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(file.destRelPath).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(base.path + "/") else { return false }
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    /// Called only after durable NAS verification, or by maintenance after a
    /// fresh read-back. Never recursively delete a session or follow its symlink.
    @discardableResult
    func retireVerifiedFile(session: UUID, file: FileRecord,
                            protection: StagingMaintenanceGuard? = nil,
                            canonicalSource: URL? = nil) async throws -> Bool {
        guard file.state.recordsNASVerification, let hash = file.sourceHashHex, !hash.isEmpty,
              isPlainSession(session) else { return false }
        let staged = stagedURL(session: session, file: file)
        let partial = partialURL(session: session, file: file)
        let before = WipeGate.liveStat(staged.path)
        if let before {
            guard before.isRegularFile, !before.isSymlink, before.size == file.size,
                  try await ChunkedIO.hashFile(staged, noCache: false) == hash else { return false }
        }
        let partialBefore = WipeGate.liveStat(partial.path)
        var mayRemovePartial = false
        if let partialBefore, partialBefore.isRegularFile, !partialBefore.isSymlink,
           partialBefore.size >= 0, partialBefore.size <= file.size {
            if let source = before != nil ? staged : canonicalSource,
               let sourceBefore = WipeGate.liveStat(source.path), sourceBefore.isRegularFile,
               !sourceBefore.isSymlink, sourceBefore.size == file.size {
                mayRemovePartial = try await prefixMatches(partial, source: source, bytes: partialBefore.size)
                    && WipeGate.liveStat(source.path) == sourceBefore
            } else if partialBefore.size == file.size {
                mayRemovePartial = try await ChunkedIO.hashFile(partial, noCache: false) == hash
            }
        }
        try Task.checkCancellation()
        let removePartial = mayRemovePartial
        let remove = { () -> Bool in
            guard !Task.isCancelled, self.isPlainSession(session),
                  WipeGate.liveStat(staged.path) == before else { return false }
            var removed = false
            if before != nil {
                guard unlink(staged.path) == 0 else { return false }
                removed = true
            }
            // Only discard a partial whose bytes are proven redundant. A sole
            // unknown partial or an edited cache may be the only recovery copy.
            if removePartial, WipeGate.liveStat(partial.path) == partialBefore {
                removed = unlink(partial.path) == 0 || removed
            }
            _ = rmdir(self.sessionDir(session).path) // Empty only; unknown entries survive.
            return removed
        }
        if let protection { return protection.whileIdle(remove) }
        return remove()
    }

    private func prefixMatches(_ partial: URL, source: URL, bytes: Int64) async throws -> Bool {
        let fds = try await ChunkedIO.blocking { () throws -> (Int32, Int32) in
            let left = open(partial.path, O_RDONLY | O_NOFOLLOW)
            guard left >= 0 else { throw OffloadError.posix(errno, stage: "read staging partial") }
            let right = open(source.path, O_RDONLY | O_NOFOLLOW)
            guard right >= 0 else {
                let code = errno; close(left)
                throw OffloadError.posix(code, stage: "read verified copy")
            }
            return (left, right)
        }
        defer { close(fds.0); close(fds.1) }
        var remaining = bytes
        while remaining > 0 {
            try Task.checkCancellation()
            let count = Int(min(remaining, 1 << 20))
            let matches = try await ChunkedIO.blocking {
                var left = [UInt8](repeating: 0, count: count)
                var right = [UInt8](repeating: 0, count: count)
                let l = left.withUnsafeMutableBytes { read(fds.0, $0.baseAddress, count) }
                let r = right.withUnsafeMutableBytes { read(fds.1, $0.baseAddress, count) }
                return l == count && r == count && left == right
            }
            guard matches else { return false }
            remaining -= Int64(count)
        }
        return true
    }

    @discardableResult
    func retirePersistedFile(session: UUID, fileID: UUID, journal: Journal) async throws -> Bool {
        try await journal.flushNow(session)
        guard let recorded = await journal.session(id: session)?.files.first(where: { $0.id == fileID }) else { return false }
        return try await retireVerifiedFile(session: session, file: recorded)
    }
}
