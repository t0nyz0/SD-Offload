import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine

final class AuditReproductionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offload-code-audit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testCancelledQueueWaiterMustExit() async throws {
        let queue = AsyncQueue<Int>()
        let flag = AuditCompletionFlag()
        let task = Task { _ = await queue.receive(); await flag.markDone() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let completed = await flag.done
        await queue.finish()
        await task.value
        XCTAssertTrue(completed, "Cancellation did not release the suspended queue worker")
    }
    func testChangedSourceAfterGateMustSurvive() async throws {
        let source = root.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: source)
        let st = WipeGate.liveStat(source.path)!
        let file = FileRecord(relPath: "photo.jpg", size: st.size, mtime: st.mtime, creationDate: nil, destRelPath: "photo.jpg", state: .nasVerified)
        let session = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100, files: [file])
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        try await journal.begin(session)
        let verdict = WipeGate.evaluate(session: session, policy: .afterNASVerify, cardMount: .init(volumeUUID: "fixture", rootPath: root.path, isReadOnly: false), nasHealth: .healthy, statOf: WipeGate.liveStat, journalFlushed: true)
        XCTAssertTrue(verdict.allowed)
        try Data("new content never copied to NAS".utf8).write(to: source)
        _ = await Wiper.execute(deletions: verdict.deletions, journal: journal, sessionID: session.id, fileIDs: [:])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Unbacked-up replacement was deleted")
    }
    func testSecondaryCollisionMustPreserveExistingFile() async throws {
        let card = root.appendingPathComponent("card"), nas = root.appendingPathComponent("nas"), second = root.appendingPathComponent("second")
        for dir in [card,nas,second] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let data = Data("new camera image".utf8), old = Data("existing unique backup".utf8)
        try data.write(to: card.appendingPathComponent("photo.jpg"))
        try data.write(to: nas.appendingPathComponent("photo.jpg"))
        try old.write(to: second.appendingPathComponent("photo.jpg"))
        let st = WipeGate.liveStat(card.appendingPathComponent("photo.jpg").path)!
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let file = FileRecord(relPath: "photo.jpg", size: st.size, mtime: st.mtime, creationDate: nil, destRelPath: "photo.jpg", sourceHashHex: hash, state: .nasVerified)
        let session = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100, files: [file])
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        try await journal.begin(session)
        var config = AppConfig(); config.nasRootPath = nas.path; config.secondaryDestPath = second.path
        config.testAllowLocalNAS = true; config.wipePolicy = .afterNASVerify; config.wipeCountdownSeconds = 0; config.autoEject = false
        let fixed = config
        let runner = SessionRunner(sessionID: session.id, card: .init(volumeUUID: "fixture", bsdName: "fixture-not-device", mountPath: card.path, volumeName: "fixture", capacityBytes: 100, freeBytes: 50, hasMediaRoot: true), config: config, journal: journal, staging: StagingStore(rootPath: root.appendingPathComponent("staging").path), nas: NASLocator(configProvider: { fixed }), cardWatcher: CardWatcher(), emit: { _ in })
        await runner.run()
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("photo.jpg")), old, "Existing unrelated secondary file was overwritten")
        XCTAssertEqual(try Data(contentsOf: card.appendingPathComponent("photo.jpg")), data, "Conflict must block card erasure")
    }
    func testDescriptionIsSearchable() async {
        let index = PhotoIndex(file: root.appendingPathComponent("index.json"))
        await index.setAI(path: "/photos/a.jpg", size: 1, mtime: Date(), tags: ["beach"], description: "A lighthouse by the coast")
        let paths = await index.search("lighthouse")
        XCTAssertEqual(paths, ["/photos/a.jpg"])
    }
    func testIndexSaveRetriesAfterStorageRecovers() async throws {
        let parent = root.appendingPathComponent("blocked")
        try Data().write(to: parent)
        let file = parent.appendingPathComponent("index.json")
        let index = PhotoIndex(file: file)
        await index.setAI(path: "/photos/a.jpg", size: 1, mtime: Date(), tags: ["beach"], description: "coast")
        await index.save()
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        await index.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Failed save cleared dirty state; retry did nothing")
    }
    func testIncompleteEnumerationMustNotPurgeFaceScan() async throws {
        let offline = root.appendingPathComponent("unmounted")
        let faces = FaceIndex(file: root.appendingPathComponent("faces.json"))
        let path = offline.appendingPathComponent("a.jpg").path
        await faces.setDetections([], for: path)
        do {
            _ = try await LibraryBrowser().refreshFaceInventory(root: offline, index: faces)
            XCTFail("An unavailable root must fail the scan")
        } catch { }
        let needsScan = await faces.needsScan(path: path)
        XCTAssertFalse(needsScan, "Offline scan discarded existing face data")
    }
}

private actor AuditCompletionFlag {
    var done = false
    func markDone() { done = true }
}
