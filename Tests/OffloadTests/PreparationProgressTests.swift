import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine
@testable import OffloadApp

final class PreparationProgressTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offload-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func cardFiles() throws -> [IngestPlanner.ScannedFile] {
        let dcim = root.appendingPathComponent("DCIM/100_TEST")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: dcim.appendingPathComponent("one.JPG"))
        try Data(repeating: 2, count: 200).write(to: dcim.appendingPathComponent("two.RAF"))
        try Data(repeating: 3, count: 999).write(to: dcim.appendingPathComponent("._one.JPG"))
        try Data("camera database".utf8).write(to: root.appendingPathComponent("camera.DAT"))
        return IngestPlanner().scan(cardRoot: root, scope: .mediaRootsOnly)
    }

    func testScanReportsMeasuredFilesAndBytesWithoutChangingManifest() throws {
        let baseline = try cardFiles(), tracker = PreparationTracker()
        let scanned = IngestPlanner().scan(cardRoot: root, scope: .mediaRootsOnly, progress: tracker)
        XCTAssertEqual(scanned.map(\.relPath), baseline.map(\.relPath))
        XCTAssertEqual(scanned.map(\.size), [100, 200])
        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.stage, .findingFiles)
        XCTAssertEqual(snapshot.filesFound, 2)
        XCTAssertEqual(snapshot.bytesFound, 300)
        XCTAssertEqual(snapshot.itemsTotal, 0, "Discovery has no invented denominator")
    }

    private struct SlowDater: CaptureDating {
        let started: XCTestExpectation
        let release: DispatchSemaphore
        func captureDate(of url: URL, creationDate: Date?, mtime: Date) -> Date {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
            return mtime
        }
    }

    func testDateProgressIsVisibleWhileMetadataReadIsBlocked() async throws {
        let files = try cardFiles(), tracker = PreparationTracker()
        let started = expectation(description: "both metadata reads started")
        started.expectedFulfillmentCount = 2
        let release = DispatchSemaphore(value: 0)
        let planner = IngestPlanner(dater: SlowDater(started: started, release: release))
        let task = Task { await planner.plan(scanned: files, progress: tracker) }
        await fulfillment(of: [started], timeout: 3)
        let during = tracker.snapshot(now: ProcessInfo.processInfo.systemUptime + 15)
        XCTAssertEqual(during.stage, .readingDates)
        XCTAssertEqual(during.itemsTotal, 2)
        XCTAssertEqual(during.itemsDone, 0)
        XCTAssertNotNil(during.currentPath)
        XCTAssertGreaterThanOrEqual(during.secondsWithoutActivity, 15)
        release.signal(); release.signal()
        let plan = await task.value
        XCTAssertEqual(plan.files.count, 2)
        XCTAssertEqual(tracker.snapshot().itemsDone, 2)
        XCTAssertNil(tracker.snapshot().currentPath)
    }

    func testElapsedTimeSurvivesStageChangesAndWaitResetsOnRealActivity() {
        let tracker = PreparationTracker(now: 100)
        tracker.examining("DCIM", now: 101)
        tracker.foundFile(bytes: 300, now: 102)
        tracker.begin(.readingDates, total: 1, now: 103)
        tracker.beginDate("DCIM/one.JPG", now: 105)
        let waiting = tracker.snapshot(now: 120)
        XCTAssertEqual(waiting.elapsed, 20)
        XCTAssertEqual(waiting.secondsWithoutActivity, 15)
        tracker.finishedItem("DCIM/one.JPG", now: 121)
        XCTAssertEqual(tracker.snapshot(now: 122).secondsWithoutActivity, 1)
        tracker.begin(.checkingNAS, now: 123)
        let next = tracker.snapshot(now: 124)
        XCTAssertEqual(next.elapsed, 24)
        XCTAssertEqual(next.secondsWithoutActivity, 1)
        XCTAssertEqual(next.filesFound, 1)
        XCTAssertEqual(next.bytesFound, 300)
        XCTAssertEqual(next.itemsDone, 0)
        XCTAssertNil(next.currentPath)
    }

    func testConcurrentDiscoveryCountersStayAccurateAndCheap() {
        let tracker = PreparationTracker(), started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<25_000 { tracker.foundFile(bytes: 10) }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertEqual(tracker.snapshot().filesFound, 100_000)
        XCTAssertEqual(tracker.snapshot().bytesFound, 1_000_000)
        XCTAssertLessThan(elapsed, 5, "Progress updates must stay constant-time; no formatting, I/O, or events per file")
        print("PERF preparation: 100,000 concurrent counter updates in \(elapsed)s")
    }

    func testResumeProgressPreservesVerifiedDestinationAndReportsMatching() async throws {
        let files = try cardFiles(), tracker = PreparationTracker()
        var plan = await IngestPlanner().plan(scanned: files)
        for i in plan.files.indices { plan.files[i].state = .nasVerified }
        let merged = await IngestPlanner().merge(scanned: files, into: plan.files, progress: tracker)
        XCTAssertEqual(merged.files.map(\.id), plan.files.map(\.id))
        XCTAssertEqual(merged.files.map(\.destRelPath), plan.files.map(\.destRelPath))
        XCTAssertTrue(merged.resumed)
        XCTAssertEqual(tracker.snapshot().stage, .matchingSavedProgress)
        XCTAssertEqual(tracker.snapshot().itemsDone, 2)
        XCTAssertEqual(tracker.snapshot().itemsTotal, 2)
    }

    func testPreviousBackupProgressKeepsCorruptedRecoveryData() async throws {
        let data = Data(repeating: 9, count: 2 << 20)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = FileRecord(relPath: "photo.JPG", size: Int64(data.count), mtime: Date(), creationDate: nil,
                              destRelPath: "photo.JPG", sourceHashHex: hash, state: .nasVerified)
        let record = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100,
                                   state: .done, files: [file], endedAt: Date().addingTimeInterval(-10))
        let store = StagingStore(rootPath: root.appendingPathComponent("staging").path)
        let tracker = PreparationTracker()
        tracker.begin(.checkingSavedCopies)
        try store.ensureSessionDir(record.id)
        try data.write(to: store.stagedURL(session: record.id, file: file))
        try Data(repeating: 8, count: data.count).write(to: root.appendingPathComponent("photo.JPG"))
        await store.pruneCompletedBeforeNextRun([record], nasRoot: root.path, keepDays: 0, preparation: tracker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionDir(record.id).path))
        XCTAssertEqual(tracker.snapshot().savedCopyCheck?.filesDone, 0)
        try data.write(to: root.appendingPathComponent("photo.JPG"))
        await store.pruneCompletedBeforeNextRun([record], nasRoot: root.path, keepDays: 0, preparation: tracker)
        XCTAssertEqual(tracker.snapshot().savedCopyCheck?.filesDone, 1)
        XCTAssertEqual(tracker.snapshot().savedCopyCheck?.bytesDone, Int64(data.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionDir(record.id).path))
    }

    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PreparationProgress] = []
        let ready = XCTestExpectation(description: "live preparation snapshots")
        init() { ready.expectedFulfillmentCount = 3 }
        func record(_ event: EngineEvent) {
            guard case .preparation(let snapshot) = event else { return }
            lock.lock(); values.append(snapshot); let count = values.count; lock.unlock()
            if count <= 3 { ready.fulfill() }
        }
        var snapshots: [PreparationProgress] { lock.lock(); defer { lock.unlock() }; return values }
    }

    func testSamplerTicksDuringNoActivityAndStopsWhenPreparationEnds() async throws {
        let samples = Samples(), tracker = PreparationTracker()
        var config = AppConfig(); config.defaultCardAction = .ignore
        let fixed = config
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        let coordinator = Coordinator(configProvider: { fixed }, configMutator: { _ in }, journal: journal,
                                      emit: { samples.record($0) })
        let sampler = await coordinator.samplePreparation(tracker)
        await fulfillment(of: [samples.ready], timeout: 3)
        sampler.cancel()
        await sampler.value
        let snapshots = samples.snapshots
        XCTAssertGreaterThanOrEqual(snapshots.count, 3)
        for pair in zip(snapshots, snapshots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.elapsed - pair.0.elapsed, 0.20, "No event per file or busy loop")
        }
        XCTAssertGreaterThan(snapshots.last!.secondsWithoutActivity, 0.4)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(samples.snapshots.count, snapshots.count)
    }

    @MainActor
    func testPreparationDisplayHasNoFakePercentageAndDistinguishesCardFromNASWaits() {
        let card = CardInfo(volumeUUID: "fixture", bsdName: "fixture", mountPath: "/fixture", volumeName: "fixture",
                            capacityBytes: 100, freeBytes: 0, hasMediaRoot: true)
        let vm = SessionViewModel(sessionID: UUID(), card: card, resumed: false)
        vm.scratchPreparation = PreparationProgress(filesFound: 38, bytesFound: 1_220_000_000,
                                                     elapsed: 25, secondsWithoutActivity: 12)
        vm.applyScratchTick()
        let finding = PreparationPresentation(progress: vm.preparation)
        XCTAssertNil(finding.fraction)
        XCTAssertEqual(finding.step, 1)
        XCTAssertTrue(finding.countText.contains("38 files found"))
        XCTAssertTrue(finding.waitMessage!.contains("card response"))
        XCTAssertTrue(finding.waitHelp.contains("macOS access prompt"))
        let nas = PreparationPresentation(progress: PreparationProgress(stage: .checkingNAS, secondsWithoutActivity: 12))
        XCTAssertTrue(nas.waitMessage!.contains("NAS response"))
        XCTAssertFalse(nas.waitHelp.contains("access prompt"))
        XCTAssertNil(PreparationPresentation(progress: PreparationProgress(secondsWithoutActivity: 9)).waitMessage)
        vm.phase = .transferring
        vm.scratchPreparation.filesFound = 999
        vm.applyScratchTick()
        XCTAssertEqual(vm.preparation.filesFound, 38, "Late preparation updates cannot change transfer UI")
    }
}
