import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine

final class TransferSafetyRegressionTests: XCTestCase {
    private func fixture() throws -> (URL, FileRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = Data("new camera video".utf8)
        try data.write(to: root.appendingPathComponent("clip.MOV"))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (root, FileRecord(relPath: "DCIM/clip.MOV", size: Int64(data.count), mtime: Date(),
                                creationDate: nil, destRelPath: "clip.MOV", sourceHashHex: hash, state: .nasVerified))
    }

    func testFinalCheckAcceptsMatchingDestination() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await DestinationVerifier.verify(files: [file], root: root.path)
    }

    func testPreviouslyVerifiedButNowMissingDestinationBlocks() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("clip.MOV"))
        do { try await DestinationVerifier.verify(files: [file], root: root.path); XCTFail("Missing NAS copy allowed") }
        catch {}
    }

    func testSameSizeChangedDestinationBlocks() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 42, count: Int(file.size)).write(to: root.appendingPathComponent("clip.MOV"))
        do { try await DestinationVerifier.verify(files: [file], root: root.path); XCTFail("Changed NAS copy allowed") }
        catch {}
    }

    func testUploadedWithoutVerificationDoesNotCountAsSuccess() async throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var file = original; file.state = .uploaded
        XCTAssertFalse(file.state.recordsNASVerification)
        do { try await DestinationVerifier.verify(files: [file], root: root.path); XCTFail("Unverified upload allowed") }
        catch {}
    }

    func testMissingHashBlocksEvenWithRecordedSuccess() async throws {
        let (root, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var file = original; file.sourceHashHex = nil
        do { try await DestinationVerifier.verify(files: [file], root: root.path); XCTFail("Missing hash allowed") }
        catch {}
    }

    func testRetentionClearsOnlyReverifiedCompletedBatchOnNextRun() async throws {
        let (root, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = StagingStore(rootPath: root.appendingPathComponent("staging").path)
        let completed = SessionRecord(cardVolumeUUID: "card", cardVolumeName: "Test", cardCapacityBytes: 100,
                                      state: .done, files: [file], endedAt: Date().addingTimeInterval(-10))
        var missing = SessionRecord(cardVolumeUUID: "card", cardVolumeName: "Test", cardCapacityBytes: 100, state: .done, files: [file], endedAt: completed.endedAt)
        missing.files[0].destRelPath = "missing.MOV"
        let failed = SessionRecord(cardVolumeUUID: "card", cardVolumeName: "Test", cardCapacityBytes: 100, state: .doneWipeBlocked, files: [file], endedAt: completed.endedAt)
        for record in [completed, missing, failed] {
            try staging.ensureSessionDir(record.id)
            try Data("recovery".utf8).write(to: staging.stagedURL(session: record.id, file: file))
        }
        await staging.pruneCompletedBeforeNextRun([completed, missing, failed], nasRoot: root.path, keepDays: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.sessionDir(completed.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.stagedURL(session: missing.id, file: file).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.stagedURL(session: failed.id, file: file).path))
    }

    func testLegacyStagingEraseSettingMigratesButNextRunRetentionIsPreserved() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{\"wipePolicy\":\"afterStagingVerify\",\"keepStagedDays\":0}".utf8))
        XCTAssertEqual(config.wipePolicy, .afterNASVerify)
        XCTAssertEqual(config.keepStagedDays, 0)
    }

    func testHistoricalFailureKeepsReasonAndStagingIsNotNASSuccess() {
        XCTAssertTrue(FileState.failed(.sourceMissing).historyResult.contains("File disappeared"))
        XCTAssertFalse(FileState.stagedVerified.recordsNASVerification)
        XCTAssertTrue(FileState.wiped.historyResult.contains("at transfer"))
    }
}
