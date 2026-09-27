import Foundation
import OffloadEngine

/// Reproducible local baseline. Never opens a real card or writes to a NAS.
enum PerformanceBaseline {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("offload-perf-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("copy.bin")
        fm.createFile(atPath: source.path, contents: nil)
        let file = try FileHandle(forWritingTo: source)
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        for _ in 0..<256 { try file.write(contentsOf: chunk) }
        try file.synchronize(); try file.close()
        let clock = ContinuousClock()
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        print("Local 256 MiB copy + SHA-256, fsync, then uncached verification (3 trials)")
        for trial in 1...3 {
            let start = clock.now
            let copy = try await ChunkedIO.copyAndHash(from: source, to: destination)
            let copied = clock.now
            let hash = try await ChunkedIO.hashFile(destination, noCache: true)
            let end = clock.now
            guard hash == copy.sha256Hex, copy.bytes == 256 << 20 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            print(String(format: "Trial %d: copy %.0f MiB/s; verify %.0f MiB/s; total %.3f s; hashes match",
                         trial, 256 / seconds(start.duration(to: copied)),
                         256 / seconds(copied.duration(to: end)), seconds(start.duration(to: end))))
        }
        let library = root.appendingPathComponent("library")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        for i in 0..<2000 {
            try Data(repeating: 1, count: 128).write(to: library.appendingPathComponent("IMG_\(i).JPG"))
        }
        let start = clock.now
        let entries = try LibraryBrowser().browseChecked(library)
        let end = clock.now
        guard entries.count == 2000 else { throw CocoaError(.fileReadCorruptFile) }
        print(String(format: "Browse 2,000 local entries: %.3f s", seconds(start.duration(to: end))))
        print("These are local filesystem baselines, not SD-card or SMB throughput measurements.")
    }
}
