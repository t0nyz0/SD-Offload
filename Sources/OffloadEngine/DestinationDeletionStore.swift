import Foundation
import OffloadCore

/// Durable user intent, written BEFORE moving an archive file to Trash. A crash
/// between the move and its return must not let a retry recreate that file.
public struct DestinationDeletionStore: Sendable {
    private struct Entry: Codable {
        let id: UUID
        let archive: String
        let relativePath: String
        let size: Int64
        let recordedAt: Date
    }
    private static let lock = NSLock()
    public let file: URL

    public init(file: URL) { self.file = file }

    static func forConfig(_ config: AppConfig) -> Self {
        // Fixture engines must never read or write the real deletion ledger.
        let file = config.testAllowLocalNAS
            ? URL(fileURLWithPath: config.stagingRootPath).deletingLastPathComponent().appendingPathComponent("test-destination-deletions.json")
            : Paths.destinationDeletionsFile
        return Self(file: file)
    }

    private func load() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        // Corrupt/unreadable intent is an error, never permission to re-upload.
        return try JSONIO.load([Entry].self, from: file)
    }

    private func archive(_ root: String) -> String {
        URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func begin(url: URL, root: URL, size: Int64, now: Date = Date()) throws -> UUID {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let base = archive(root.path)
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else {
            throw OffloadError(.destinationUnwritable("Deletion intent is outside the archive"))
        }
        var entries = try load()
        let entry = Entry(id: UUID(), archive: base,
            relativePath: String(path.dropFirst(base.count + 1)), size: size, recordedAt: now)
        entries.append(entry)
        try JSONIO.saveDurable(entries, to: file)
        return entry.id
    }

    func revoke(_ id: UUID) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var entries = try load()
        entries.removeAll { $0.id == id }
        try JSONIO.saveDurable(entries, to: file)
    }

    func blocksCreation(of record: FileRecord, root: String) throws -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let base = archive(root)
        return try load().contains {
            // A visible upload can be trashed before it reaches its final size.
            $0.archive == base && $0.relativePath == record.destRelPath
        }
    }

    func permitsRetirement(of record: FileRecord, root: String) throws -> Bool {
        guard record.state.recordsNASVerification else { return false }
        Self.lock.lock(); defer { Self.lock.unlock() }
        let base = archive(root)
        return try load().contains {
            $0.archive == base && $0.relativePath == record.destRelPath && $0.size == record.size
                && $0.recordedAt >= record.stateChangedAt.addingTimeInterval(-2)
        }
    }

    struct Suppressed: LocalizedError {
        let relativePath: String
        var errorDescription: String? { "This destination was deleted and will not be automatically restored: \(relativePath)" }
    }
}
