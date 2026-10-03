import XCTest
import CryptoKit
@testable import OffloadEngine

final class NASPerformanceRegressionTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var sizes: [Int] = []
        var phases: [ChunkedIO.CopyPhase] = []
        func add(_ size: Int) { lock.lock(); defer { lock.unlock() }; sizes.append(size) }
        func phase(_ value: ChunkedIO.CopyPhase) { lock.lock(); defer { lock.unlock() }; phases.append(value) }
    }

    func testSequentialVerificationReadsLargeChunksAndChecksEveryByte() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        // Cross two full read boundaries and a partial final read.
        let data = Data((0..<((32 << 20) + 117)).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: file)
        let counter = Counter()
        let hash = try await ChunkedIO.hashFile(file, noCache: true) { counter.add($0) }
        XCTAssertEqual(hash, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(counter.sizes.reduce(0, +), data.count)
        XCTAssertEqual(counter.sizes, [16 << 20, 16 << 20, 117], "Avoid many small synchronous NAS reads")
    }

    func testCopyReportsOpenWriteAndDurableFlushInOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        try Data(repeating: 19, count: 12345).write(to: source)
        let counter = Counter()
        let result = try await ChunkedIO.copyAndHash(from: source, to: target, phase: { counter.phase($0) })
        XCTAssertEqual(counter.phases, [.openingDestination, .writing, .flushing])
        let verified = try await ChunkedIO.hashFile(target, noCache: true)
        XCTAssertEqual(result.sha256Hex, verified)
    }

    func testSlowNASOperationClearsAndResetsBetweenFiles() {
        let tracker = NASActivityTracker(), first = UUID(), second = UUID()
        tracker.set(first, "Waiting for NAS to finish saving", now: 10)
        XCTAssertNil(tracker.detail(now: 12))
        XCTAssertEqual(tracker.detail(now: 15), "Waiting for NAS to finish saving · 5s")
        tracker.set(second, "Waiting for NAS file information", now: 14)
        tracker.set(first, nil, now: 16)
        XCTAssertEqual(tracker.detail(now: 18), "Waiting for NAS file information · 4s")
        tracker.set(second, nil, now: 19)
        XCTAssertNil(tracker.detail(now: 100))
    }
}
