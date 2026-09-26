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

    /// Only a new transfer may retire recovery copies. Never sweep unknown,
    /// failed, interrupted, or unverifiable sessions based on directory age.
    public func pruneCompletedBeforeNextRun(_ history: [SessionRecord], nasRoot: String,
                                            keepDays: Int, now: Date = Date()) async {
        for record in history {
            guard record.state == .done, let ended = record.endedAt,
                  now.timeIntervalSince(ended) >= Double(max(0, keepDays)) * 86_400,
                  let retained = try? FileManager.default.contentsOfDirectory(
                    at: sessionDir(record.id), includingPropertiesForKeys: nil),
                  !retained.isEmpty else { continue }
            do {
                try await DestinationVerifier.verify(files: record.files, root: nasRoot)
                purgeSession(record.id)
            } catch {
                // A missing/changed NAS file makes the local copy essential.
                continue
            }
        }
    }
}
