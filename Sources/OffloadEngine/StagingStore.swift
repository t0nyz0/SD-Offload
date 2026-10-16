import Foundation
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

    /// Idle maintenance may retire completed recovery copies. Never sweep unknown,
    /// failed, interrupted, or unverifiable sessions based on directory age.
    public func pruneCompletedBeforeNextRun(_ history: [SessionRecord], nasRoot: String,
                                           keepDays: Int, now: Date = Date(),
                                           preparation: PreparationTracker? = nil,
                                           protectedSessionID: UUID? = nil) async {
        for record in history {
            guard !Task.isCancelled else { return }
            guard record.id != protectedSessionID, record.state == .done, let ended = record.endedAt,
                  now.timeIntervalSince(ended) >= Double(max(0, keepDays)) * 86_400,
                  let retained = try? FileManager.default.contentsOfDirectory(
                    at: sessionDir(record.id), includingPropertiesForKeys: nil),
                  !retained.isEmpty else { continue }
            do {
                try Task.checkCancellation()
                preparation?.beginSavedCopyCheck(record.files)
                try await DestinationVerifier.verify(files: record.files, root: nasRoot,
                                                       tracker: preparation?.savedCopyTracker)
                try Task.checkCancellation()
                purgeSession(record.id)
            } catch {
                // A missing/changed NAS file makes the local copy essential.
                continue
            }
        }
    }
}
