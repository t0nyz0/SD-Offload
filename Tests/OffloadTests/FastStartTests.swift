import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine

final class FastStartTests: XCTestCase {
    func testPreviousBackupsAreNotAStartupPrerequisiteWhenTheCardFits() {
        XCTAssertFalse(StagingStore.requiresReclamation(bytesToRead: 303_400_000, headroomBytes: 1_000_000_000,
                                                       freeBytes: 20_000_000_000))
        XCTAssertFalse(StagingStore.requiresReclamation(bytesToRead: 100, headroomBytes: 20, freeBytes: 120))
        XCTAssertTrue(StagingStore.requiresReclamation(bytesToRead: 100, headroomBytes: 20, freeBytes: 119))
        XCTAssertTrue(StagingStore.requiresReclamation(bytesToRead: 0, headroomBytes: 20, freeBytes: 19))
        XCTAssertFalse(StagingStore.requiresReclamation(bytesToRead: Int64.max, headroomBytes: 0, freeBytes: Int64.max))
    }

    func testSleepingNASGlanceCannotBlockCardEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = expectation(description: "NAS glance blocked"), handled = expectation(description: "card event handled")
        let release = DispatchSemaphore(value: 0)
        let coordinator = Coordinator(configProvider: { AppConfig() }, configMutator: { _ in },
            journal: Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history")),
            glanceProvider: { _ in started.fulfill(); _ = release.wait(timeout: .now() + 5); return NASGlance() },
            emit: { event in if case .cardGone = event { handled.fulfill() } })
        let task = Task { await coordinator.emitGlance() }
        await fulfillment(of: [started], timeout: 2)
        let cardTask = Task { await coordinator.handle(.volumeUnmounted(volumeUUID: "fixture", bsdName: "fixture")) }
        await fulfillment(of: [handled], timeout: 1)
        release.signal()
        await task.value
        await cardTask.value
    }

    func testCancelledMaintenanceAndLatestBatchKeepRecoveryCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("verified backup".utf8)
        try data.write(to: root.appendingPathComponent("photo.JPG"))
        let file = FileRecord(relPath: "photo.JPG", size: Int64(data.count), mtime: Date(), creationDate: nil,
            destRelPath: "photo.JPG", sourceHashHex: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), state: .nasVerified)
        let record = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100,
            state: .done, files: [file], endedAt: Date().addingTimeInterval(-10))
        let store = StagingStore(rootPath: root.appendingPathComponent("staging").path)
        try store.ensureSessionDir(record.id)
        let recovery = store.stagedURL(session: record.id, file: file)
        try data.write(to: recovery)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.pruneCompletedBeforeNextRun([record], nasRoot: root.path, keepDays: 0)
        }
        await task.value
        XCTAssertEqual(try Data(contentsOf: recovery), data)
        await store.pruneCompletedBeforeNextRun([record], nasRoot: root.path, keepDays: 0,
                                                protectedSessionID: record.id)
        XCTAssertEqual(try Data(contentsOf: recovery), data, "The just-completed batch stays available for recovery")
    }
}
