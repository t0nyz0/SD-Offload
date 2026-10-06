import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine
@testable import OffloadApp

final class AuditFixRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offload-fix-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func approved(_ data: Data) async throws -> (FileRecord, SessionRecord, Journal, WipeGate.Verdict) {
        let source = root.appendingPathComponent("photo.jpg")
        try data.write(to: source)
        let st = WipeGate.liveStat(source.path)!
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = FileRecord(relPath: "photo.jpg", size: st.size, mtime: st.mtime, creationDate: nil,
                              destRelPath: "photo.jpg", sourceHashHex: hash, state: .nasVerified)
        let session = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100, files: [file])
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        try await journal.begin(session)
        let verdict = WipeGate.evaluate(session: session, policy: .afterNASVerify,
                                        cardMount: .init(volumeUUID: "fixture", rootPath: root.path, isReadOnly: false),
                                        nasHealth: .healthy, statOf: WipeGate.liveStat, journalFlushed: true)
        XCTAssertTrue(verdict.allowed)
        return (file, session, journal, verdict)
    }

    func testSameSizeSameTimestampMutationSurvivesErasure() async throws {
        let (_, session, journal, verdict) = try await approved(Data("original".utf8))
        let source = root.appendingPathComponent("photo.jpg")
        var st = stat(); XCTAssertEqual(lstat(source.path, &st), 0)
        let fd = open(source.path, O_WRONLY); XCTAssertGreaterThanOrEqual(fd, 0)
        let replacement = Data("modified".utf8)
        replacement.withUnsafeBytes { XCTAssertEqual(write(fd, $0.baseAddress, $0.count), $0.count) }
        var times = [st.st_atimespec, st.st_mtimespec]
        XCTAssertEqual(futimens(fd, &times), 0); close(fd)
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal, sessionID: session.id, fileIDs: [:])
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertNotNil(result.stoppedEarly)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
    }

    func testUnchangedApprovedFileIsErased() async throws {
        let (_, session, journal, verdict) = try await approved(Data("original".utf8))
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal, sessionID: session.id, fileIDs: [:])
        XCTAssertEqual(result.filesDeleted, 1); XCTAssertNil(result.stoppedEarly)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
    }

    func testInterruptedErasureRestoresWithoutReplacingAnotherFile() async throws {
        let (file, _, _, _) = try await approved(Data("original".utf8))
        let original = root.appendingPathComponent(file.relPath)
        let claimed = root.appendingPathComponent(Wiper.recoveryName(fileID: file.id, name: file.relPath))
        try FileManager.default.moveItem(at: original, to: claimed)
        try Data("new photo".utf8).write(to: original)
        do { try await Wiper.restoreInterruptedClaims(files: [file], root: root.path); XCTFail("Overwrote occupied original") } catch { }
        XCTAssertEqual(try Data(contentsOf: original), Data("new photo".utf8))
        XCTAssertEqual(try Data(contentsOf: claimed), Data("original".utf8))
        try FileManager.default.removeItem(at: original)
        try await Wiper.restoreInterruptedClaims(files: [file], root: root.path)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testSymlinkReplacementDoesNotEraseTarget() async throws {
        let (_, session, journal, verdict) = try await approved(Data("original".utf8))
        let original = root.appendingPathComponent("photo.jpg"), target = root.appendingPathComponent("other.jpg")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: target)
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal, sessionID: session.id, fileIDs: [:])
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep me".utf8))
    }

    func testFaceAndIdentitySaveRetryAndDeferredLoad() async throws {
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let facesFile = blocked.appendingPathComponent("faces.json"), idsFile = blocked.appendingPathComponent("ids.json")
        let faces = FaceIndex(file: facesFile), ids = IdentityIndex(file: idsFile)
        await faces.setDetections([], for: "/photos/a.jpg")
        _ = await ids.create(name: "Test", kind: .person, embedderID: "fixture", exemplar: [1,0])
        let failedFace = await faces.save(), failedIDs = await ids.save()
        XCTAssertFalse(failedFace); XCTAssertFalse(failedIDs)
        // Construct before the files exist: hydration must happen on the actor's first read.
        let reloadedFaces = FaceIndex(file: facesFile), reloadedIDs = IdentityIndex(file: idsFile)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let savedFace = await faces.save(), savedIDs = await ids.save()
        XCTAssertTrue(savedFace); XCTAssertTrue(savedIDs)
        let needsScan = await reloadedFaces.needsScan(path: "/photos/a.jpg")
        let names = await reloadedIDs.all().map(\.name)
        XCTAssertFalse(needsScan); XCTAssertEqual(names, ["Test"])
    }

    func testCompletedScanPrunesAndCancelledScanThrows() async throws {
        let photo = root.appendingPathComponent("a.jpg")
        try Data().write(to: photo)
        let faces = FaceIndex(file: root.appendingPathComponent("faces.json"))
        await faces.setDetections([], for: photo.path)
        let missing = root.appendingPathComponent("missing.jpg").path
        await faces.setDetections([], for: missing)
        _ = try await LibraryBrowser().refreshFaceInventory(root: root, index: faces)
        let missingNeedsScan = await faces.needsScan(path: missing)
        let presentNeedsScan = await faces.needsScan(path: photo.path)
        XCTAssertTrue(missingNeedsScan); XCTAssertFalse(presentNeedsScan)
        XCTAssertThrowsError(try LibraryBrowser().allMediaChecked(root: root, isCancelled: { true }))
    }

    func testOrderedSnapshotsPersistNewestAndRetryNewest() throws {
        let writer = OrderedJSONWriter()
        let file = root.appendingPathComponent("ordered.json")
        for i in 0..<100 { writer.save([i], to: file) }
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(JSONIO.loadGuarded([Int].self, from: file), [99])
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let retry = blocked.appendingPathComponent("retry.json")
        writer.save([1], to: retry); writer.save([2], to: retry)
        XCTAssertFalse(writer.flush())
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(JSONIO.loadGuarded([Int].self, from: retry), [2])
        writer.save([3], to: retry); writer.remove(retry)
        XCTAssertTrue(writer.flush())
        XCTAssertFalse(FileManager.default.fileExists(atPath: retry.path))
    }

    func testDiskSpaceRecoveryWakesOversizedReservation() async throws {
        let free = AuditFreeSpace(30)
        let budget = StagingBudget(stagingPath: root.path, capBytes: 50, headroomBytes: 10, availableBytes: { free.value })
        let waiting = expectation(description: "waiting for real disk space")
        let done = expectation(description: "external space recovery")
        let task = Task {
            try await budget.reserve(UUID(), 100, onWaiting: { waiting.fulfill() })
            done.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        let before = await budget.committedBytes
        XCTAssertEqual(before, 0, "Oversized reservations must not bypass headroom")
        free.value = 200
        await fulfillment(of: [done], timeout: 2)
        task.cancel(); _ = try? await task.value
        let after = await budget.committedBytes
        XCTAssertEqual(after, 100)
    }

    func testCancelledBudgetAndPauseWaitsExit() async throws {
        let budget = StagingBudget(stagingPath: root.path, capBytes: 50, headroomBytes: 10, availableBytes: { 0 })
        let waiting = expectation(description: "budget waiting")
        let task = Task { try await budget.reserve(UUID(), 1, onWaiting: { waiting.fulfill() }) }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled reservation succeeded") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let gate = Gate(); await gate.close()
        let done = expectation(description: "cancelled pause waiter")
        let paused = Task { await gate.whenOpen(); done.fulfill() }
        try await Task.sleep(for: .milliseconds(30)); paused.cancel()
        await fulfillment(of: [done], timeout: 2)
        await gate.open(); await paused.value
    }

    func testLargeQueueRetainsFIFOOrder() async {
        let queue = AsyncQueue<Int>()
        for i in 0..<20_000 { await queue.send(i) }
        await queue.finish()
        for i in 0..<20_000 { let value = await queue.receive(); XCTAssertEqual(value, i) }
        let end = await queue.receive(); XCTAssertNil(end)
    }

    func testJournalCachedWorkInvalidatesAndSnapshotsStayImmutable() async throws {
        let (_, session, journal, _) = try await approved(Data("original".utf8))
        let pending = FileRecord(relPath: "new.jpg", size: 100, mtime: Date(), creationDate: nil, destRelPath: "new.jpg")
        await journal.replaceFiles([pending], in: session.id)
        let initial = await journal.session(id: session.id)
        let before = await journal.remainingWork(in: session.id)
        XCTAssertEqual(before.sdBytes, 100)
        await journal.transition(file: pending.id, to: .copying, in: session.id)
        await journal.transition(file: pending.id, to: .staged, in: session.id)
        let after = await journal.remainingWork(in: session.id)
        XCTAssertEqual(after.sdBytes, 0); XCTAssertEqual(after.verifyBytes, 100)
        XCTAssertEqual(initial?.files.first?.state, .pending)
        let resumed = await journal.openIncompleteSession(cardUUID: "fixture")
        XCTAssertNotNil(resumed)
        await journal.bumpAttempts(file: pending.id, in: session.id)
        let current = await journal.session(id: session.id)
        XCTAssertEqual(current?.files.first?.attempts, 1)
    }

    func testLargeManifestAndIndexPerformance() async throws {
        let count = 100_000
        let now = Date()
        let records = (0..<count).map { PhotoRecord(path: "/photos/\($0).jpg", size: 100, mtime: now, labels: [], animals: []) }
        let indexFile = root.appendingPathComponent("large-index.json")
        try JSONIO.save(records, to: indexFile)
        let started = Date()
        let index = PhotoIndex(file: indexFile)
        let construction = Date().timeIntervalSince(started)
        let loading = Date()
        let loaded = await index.record("/photos/99999.jpg")
        XCTAssertNotNil(loaded)
        let hydration = Date().timeIntervalSince(loading)
        let files = (0..<count).map { FileRecord(relPath: "\($0).jpg", size: 100, mtime: now, creationDate: nil, destRelPath: "\($0).jpg") }
        let session = SessionRecord(cardVolumeUUID: "large", cardVolumeName: "large", cardCapacityBytes: 1 << 30, files: files)
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        try await journal.begin(session)
        _ = await journal.remainingWork(in: session.id)
        let transitions = Date()
        for file in files.prefix(10_000) {
            await journal.transition(file: file.id, to: .copying, in: session.id)
            await journal.transition(file: file.id, to: .staged, in: session.id)
            _ = await journal.remainingWork(in: session.id)
        }
        let elapsed = Date().timeIntervalSince(transitions)
        let work = await journal.remainingWork(in: session.id)
        XCTAssertEqual(work.sdFiles, 90_000)
        XCTAssertEqual(work.verifyFiles, count)
        print("PERF 100k index constructor=\(construction)s hydration=\(hydration)s; 20k transitions + 10k progress reads in 100k manifest=\(elapsed)s")
    }

    func testThumbnailCacheTrimsToByteBudget() throws {
        for i in 0..<10 { try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("\(i).jpg")) }
        ThumbnailLoader.trimCache(root, maxBytes: 300)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, 300)
    }
}

private final class AuditFreeSpace: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64
    init(_ bytes: Int64) { self.bytes = bytes }
    var value: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return bytes }
        set { lock.lock(); bytes = newValue; lock.unlock() }
    }
}
