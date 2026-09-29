import Foundation
import OffloadCore
import OffloadEngine

enum NASProbe {
    /// Only generated data in a uniquely named folder. Never scans or erases a card.
    static func run(root: String) async throws {
        guard statfsInfo(path: root)?.fsTypeName == "smbfs" else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fm = FileManager.default
        let local = fm.temporaryDirectory.appendingPathComponent("offload-nas-probe-\(UUID())")
        let remote = URL(fileURLWithPath: root).appendingPathComponent(".offload-nas-probe-\(UUID())")
        try fm.createDirectory(at: local, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: local) }
        try fm.createDirectory(at: remote, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: remote) }
        let source = local.appendingPathComponent("generated.bin"), destination = remote.appendingPathComponent("generated.bin")
        try Data(repeating: 0x57, count: 4 << 20).write(to: source)
        var options = ChunkedIO.CopyOptions(); options.preallocate = false; options.exclusiveCreate = true
        let start = Date()
        let copied = try await ChunkedIO.copyAndHash(from: source, to: destination, options: options)
        let written = Date()
        let hash = try await ChunkedIO.hashFile(destination, noCache: true)
        guard hash == copied.sha256Hex else { throw OffloadError(.hashMismatch(stage: "NAS fixture")) }
        let verified = Date()
        do {
            _ = try await ChunkedIO.copyAndHash(from: source, to: destination, options: options)
            throw OffloadError(.internalError("Exclusive creation replaced existing fixture"))
        } catch let error as OffloadError {
            guard error.failure == .ioError(errno: EEXIST, stage: "open destination") else { throw error }
        }
        let unchanged = try await ChunkedIO.hashFile(destination, noCache: true)
        guard unchanged == hash else { throw OffloadError(.hashMismatch(stage: "collision preservation")) }
        print("PASS: SMB exclusive write, uncached SHA-256 read-back, and collision preservation")
        print("4 MiB fixture: write \(written.timeIntervalSince(start))s; read-back \(verified.timeIntervalSince(written))s")
    }
}
