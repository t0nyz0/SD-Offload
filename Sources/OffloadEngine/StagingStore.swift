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

    /// keepStagedDays sweep at app launch (0 = purge-on-verify mode, nothing to sweep here
    /// beyond orphaned session dirs older than a day).
    public func sweep(keepDays: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(max(keepDays, 1)) * 86_400)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
