import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine
@testable import OffloadApp

final class VerificationProgressTests: XCTestCase {
    func file(size: Int64 = 100) -> FileRecord {
        FileRecord(relPath: "test.jpg", size: size, mtime: Date(), creationDate: nil, destRelPath: "test.jpg")
    }
    func testRetriesDoNotInflateVerifiedBytes() {
        let tracker = VerificationTracker(), f = file()
        tracker.reset(files: [f], label: "Checking NAS copies")
        tracker.begin(f); tracker.add(80, file: f.id)
        XCTAssertEqual(tracker.snapshot().bytesDone, 80)
        tracker.finish(f, verified: false); tracker.begin(f); tracker.add(50, file: f.id)
        XCTAssertEqual(tracker.snapshot().bytesDone, 50)
        tracker.add(50, file: f.id)
        XCTAssertLessThan(tracker.snapshot().fraction, 1, "A full read is not yet a hash match")
        tracker.finish(f, verified: true)
        XCTAssertEqual(tracker.snapshot().fraction, 1)
        XCTAssertEqual(tracker.snapshot().filesDone, 1)
    }
    func testFinalPassResetsAndShowsStalledRead() {
        let tracker = VerificationTracker(), f = file()
        tracker.reset(files: [f], label: "Checking NAS copies")
        tracker.finish(f, verified: true)
        tracker.reset(files: [f], label: "Final NAS safety check")
        tracker.begin(f)
        let progress = tracker.snapshot(now: Date().addingTimeInterval(12))
        XCTAssertEqual(progress.filesDone, 0)
        XCTAssertEqual(progress.bytesDone, 0)
        XCTAssertEqual(progress.currentFile, "test.jpg")
        XCTAssertGreaterThanOrEqual(progress.secondsWithoutProgress, 12)
        XCTAssertNil(progress.eta)
    }
    @MainActor func testUploadRetriesAreNotLabeledVerificationOrComplete() {
        let card = CardInfo(volumeUUID: "test", bsdName: "fixture", mountPath: "/fixture", volumeName: "test", capacityBytes: 100, freeBytes: 0, hasMediaRoot: true)
        let vm = SessionViewModel(sessionID: UUID(), card: card, resumed: true)
        vm.phase = .transferring
        vm.scratch.hop1BytesDone = 100; vm.scratch.hop1BytesTotal = 100
        vm.scratch.hop2BytesDone = 200; vm.scratch.hop2BytesTotal = 100
        vm.scratch.uploadFilesRemaining = 2
        vm.applyScratchTick()
        XCTAssertEqual(vm.transferStatus, "Saving to NAS")
        XCTAssertFalse(vm.isChecking)
        XCTAssertLessThan(vm.headlinePercent, 100)
        vm.phase = .verifyingDestination
        XCTAssertTrue(vm.isChecking)
    }
    func testFinalVerifierReportsProgressAndRejectsCorruption() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-final-progress-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data(repeating: 9, count: 2 << 20), url = dir.appendingPathComponent("photo.jpg")
        try data.write(to: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let f = FileRecord(relPath: "photo.jpg", size: Int64(data.count), mtime: Date(), creationDate: nil,
                           destRelPath: "photo.jpg", sourceHashHex: hash, state: .nasVerified)
        let tracker = VerificationTracker()
        tracker.reset(files: [f], label: "Final NAS safety check")
        try await DestinationVerifier.verify(files: [f], root: dir.path, tracker: tracker)
        XCTAssertEqual(tracker.snapshot().bytesDone, Int64(data.count))
        XCTAssertEqual(tracker.snapshot().filesDone, 1)
        try Data(repeating: 8, count: data.count).write(to: url)
        tracker.reset(files: [f], label: "Final NAS safety check")
        do { try await DestinationVerifier.verify(files: [f], root: dir.path, tracker: tracker); XCTFail("Corruption accepted") }
        catch { }
        XCTAssertEqual(tracker.snapshot().filesDone, 0)
        XCTAssertEqual(tracker.snapshot().bytesDone, 0)
    }

    func testSMBUsesExclusiveCreation() {
        XCTAssertTrue(DestinationWriter.usesExclusiveCreate(fileSystem: "smbfs"))
        XCTAssertFalse(DestinationWriter.usesExclusiveCreate(fileSystem: "apfs"))
    }
    func testExclusiveCopyPreservesCollisionAndHashesNewFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-exclusive-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source"), dest = dir.appendingPathComponent("destination")
        try Data(repeating: 7, count: 2 << 20).write(to: source)
        let original = Data("unique backup".utf8); try original.write(to: dest)
        var options = ChunkedIO.CopyOptions(); options.exclusiveCreate = true; options.preallocate = false
        do { _ = try await ChunkedIO.copyAndHash(from: source, to: dest, options: options); XCTFail("Overwrote existing file") }
        catch let error as OffloadError { XCTAssertEqual(error.failure, .ioError(errno: EEXIST, stage: "open destination")) }
        XCTAssertEqual(try Data(contentsOf: dest), original)
        let fresh = dir.appendingPathComponent("new")
        let copied = try await ChunkedIO.copyAndHash(from: source, to: fresh, options: options)
        let readBack = try await ChunkedIO.hashFile(fresh, noCache: true)
        XCTAssertEqual(readBack, copied.sha256Hex)
        XCTAssertEqual(copied.bytes, 2 << 20)
    }
}
