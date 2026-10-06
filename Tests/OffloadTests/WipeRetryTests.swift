import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine
@testable import OffloadApp

final class WipeRetryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offload-wipe-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        let finished = XCTestExpectation(description: "wipe attempt finished")
        private var items: [EngineEvent] = []
        func record(_ event: EngineEvent) {
            lock.lock(); items.append(event); lock.unlock()
            if case .completed = event { finished.fulfill() }
        }
        var all: [EngineEvent] { lock.lock(); defer { lock.unlock() }; return items }
        var completion: SessionRecord? {
            all.compactMap { if case .completed(let s) = $0 { return s }; return nil }.last
        }
        var starts: Int { all.filter { if case .sessionStarted = $0 { return true }; return false }.count }
        var phases: [EnginePhase] { all.compactMap { if case .phase(let p) = $0 { return p }; return nil } }
    }
    private struct Fixture {
        let card: URL, nas: URL, staging: URL
        let source: URL, backup: URL
        let journal: Journal
        var record: SessionRecord
        var config: AppConfig
        let volume: CandidateVolume
    }
    private func fixture() async throws -> Fixture {
        let card = root.appendingPathComponent("card"), nas = root.appendingPathComponent("nas")
        let staging = root.appendingPathComponent("staging")
        let source = card.appendingPathComponent("DCIM/photo.JPG")
        let backup = nas.appendingPathComponent("saved-folder/resolved-name (2).JPG")
        for dir in [source.deletingLastPathComponent(), backup.deletingLastPathComponent(), staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = Data("verified photo bytes".utf8)
        try data.write(to: source); try data.write(to: backup)
        try Data("keep recovery".utf8).write(to: staging.appendingPathComponent("recovery.bin"))
        try Data("trusted-token".utf8).write(to: card.appendingPathComponent(Paths.cardSessionMarkerName))
        let st = try XCTUnwrap(WipeGate.liveStat(source.path))
        let file = FileRecord(relPath: "DCIM/photo.JPG", size: st.size, mtime: st.mtime,
            creationDate: nil, destRelPath: "saved-folder/resolved-name (2).JPG",
            sourceHashHex: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), state: .nasVerified)
        var stats = SessionStats(); stats.bytesRead = st.size; stats.bytesUploaded = st.size
        stats.filesPlanned = 1; stats.bytesPlanned = st.size; stats.filesNASVerified = 1
        let record = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "Test", cardCapacityBytes: 100,
            cardSessionToken: "trusted-token", state: .doneWipeBlocked, files: [file], stats: stats,
            wipeReport: WipeReport(ran: true, blockers: ["unsupported erasure"]), endedAt: Date())
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        try await journal.begin(record); try await journal.complete(record.id)
        var config = AppConfig(); config.defaultCardAction = .ask; config.testAllowLocalNAS = true
        config.nasRootPath = nas.path; config.stagingRootPath = staging.path
        config.wipePolicy = .afterNASVerify; config.wipeCountdownSeconds = 0; config.autoEject = false
        let info = CardInfo(volumeUUID: "fixture", bsdName: "fixture-not-a-device", mountPath: card.path,
            volumeName: "Test", capacityBytes: 100, freeBytes: 50, hasMediaRoot: true)
        return Fixture(card: card, nas: nas, staging: staging, source: source, backup: backup, journal: journal,
            record: record, config: config,
            volume: CandidateVolume(info: info, isRemovable: true, isEjectable: true, isInternal: false, isNetwork: false))
    }
    private func coordinator(_ f: Fixture, events: Events) async -> Coordinator {
        let fixed = f.config, expected = f.card.path
        let c = Coordinator(configProvider: { fixed }, configMutator: { _ in }, journal: f.journal,
            cardPresenceCheck: { $0.mountPath == expected }, emit: { events.record($0) })
        await c.handle(.volumeMounted(f.volume)) // Ask mode: records this card without starting a transfer.
        return c
    }
    private func assertNoTransfer(_ f: Fixture, events: Events, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(events.phases.contains(.scanning), file: file, line: line)
        XCTAssertFalse(events.phases.contains(.transferring), file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.staging.path), ["recovery.bin"], file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: f.staging.appendingPathComponent("recovery.bin")), Data("keep recovery".utf8), file: file, line: line)
    }

    func testRetryWipeUsesSavedPathsWithoutCopyingAndPreservesNewPhotos() async throws {
        let f = try await fixture(), events = Events()
        let newPhoto = f.card.appendingPathComponent("DCIM/new.JPG")
        try Data("not backed up".utf8).write(to: newPhoto)
        let originalBackup = try XCTUnwrap(WipeGate.liveStat(f.backup.path))
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        await fulfillment(of: [events.finished], timeout: 5)
        let final = try XCTUnwrap(events.completion)
        XCTAssertEqual(final.state, .done)
        XCTAssertEqual(final.id, f.record.id)
        XCTAssertEqual(final.files.map(\.destRelPath), f.record.files.map(\.destRelPath))
        XCTAssertEqual(final.stats.bytesRead, f.record.stats.bytesRead)
        XCTAssertEqual(final.stats.bytesUploaded, f.record.stats.bytesUploaded)
        XCTAssertEqual(final.wipeReport?.filesDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: newPhoto), Data("not backed up".utf8))
        XCTAssertEqual(WipeGate.liveStat(f.backup.path), originalBackup)
        XCTAssertTrue(events.phases.contains(.verifyingDestination))
        try assertNoTransfer(f, events: events)
    }

    func testMissingNASCopyBlocksRetryWithoutRecopying() async throws {
        let f = try await fixture(), events = Events()
        try FileManager.default.removeItem(at: f.backup)
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        await fulfillment(of: [events.finished], timeout: 5)
        XCTAssertEqual(events.completion?.state, .doneWipeBlocked)
        XCTAssertEqual(events.completion?.wipeReport?.ran, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.backup.path))
        try assertNoTransfer(f, events: events)
    }

    func testChangedSourceSurvivesWipeOnlyRetry() async throws {
        let f = try await fixture(), events = Events()
        let changed = Data("new photo never backed up".utf8)
        try changed.write(to: f.source)
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        await fulfillment(of: [events.finished], timeout: 5)
        XCTAssertEqual(events.completion?.state, .doneWipeBlocked)
        XCTAssertEqual(try Data(contentsOf: f.source), changed)
        try assertNoTransfer(f, events: events)
    }

    func testPartialWipeRetriesOnlyRemainingApprovedFiles() async throws {
        var f = try await fixture(); let events = Events()
        var remaining = f.record.files[0]
        let source = f.card.appendingPathComponent("DCIM/remaining.JPG")
        try Data(contentsOf: f.source).write(to: source)
        let st = try XCTUnwrap(WipeGate.liveStat(source.path))
        remaining = FileRecord(relPath: "DCIM/remaining.JPG", size: st.size, mtime: st.mtime,
            creationDate: nil, destRelPath: "saved-folder/remaining.JPG", sourceHashHex: remaining.sourceHashHex, state: .nasVerified)
        try Data(contentsOf: source).write(to: f.nas.appendingPathComponent(remaining.destRelPath))
        try FileManager.default.removeItem(at: f.source)
        f.record.files[0].state = .wiped; f.record.files.append(remaining)
        f.record.stats.filesWiped = 1; f.record.stats.filesPlanned = 2
        try await f.journal.begin(f.record); try await f.journal.complete(f.record.id)
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        await fulfillment(of: [events.finished], timeout: 5)
        XCTAssertEqual(events.completion?.state, .done)
        XCTAssertEqual(events.completion?.wipeReport?.filesDeleted, 1)
        XCTAssertEqual(events.completion?.stats.filesWiped, 2)
        XCTAssertTrue(events.completion?.files.allSatisfy { $0.state == .wiped } == true)
        try assertNoTransfer(f, events: events)
    }

    func testDifferentCardTokenBlocksBeforeStarting() async throws {
        let f = try await fixture(), events = Events()
        let history = root.appendingPathComponent("history/session-\(f.record.id.uuidString).json")
        let before = try Data(contentsOf: history)
        try Data("different-card".utf8).write(to: f.card.appendingPathComponent(Paths.cardSessionMarkerName))
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        XCTAssertEqual(events.starts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertEqual(try Data(contentsOf: history), before)
        try assertNoTransfer(f, events: events)
    }

    func testUnmountedCardBlocksBeforeStarting() async throws {
        let f = try await fixture(), events = Events(), fixed = f.config
        // Default presence checking uses the kernel mount table. This directory
        // has no mounted card device even though its token and photos exist.
        let c = Coordinator(configProvider: { fixed }, configMutator: { _ in }, journal: f.journal,
            emit: { events.record($0) })
        await c.handle(.volumeMounted(f.volume))
        await c.retryWipe(sessionID: f.record.id)
        XCTAssertEqual(events.starts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        try assertNoTransfer(f, events: events)
    }

    func testIncompleteManifestCannotUseWipeOnlyRetry() async throws {
        var f = try await fixture(); let events = Events()
        f.record.files[0].state = .failed(.sourceMissing)
        try await f.journal.begin(f.record); try await f.journal.complete(f.record.id)
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        XCTAssertEqual(events.starts, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertFalse(f.record.canRetryWipe)
        try assertNoTransfer(f, events: events)
    }

    func testNewMissingSecondaryBlocksWithoutBackfilling() async throws {
        var f = try await fixture(); let events = Events()
        let secondary = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        f.config.secondaryDestPath = secondary.path
        let c = await coordinator(f, events: events)
        await c.retryWipe(sessionID: f.record.id)
        await fulfillment(of: [events.finished], timeout: 5)
        XCTAssertEqual(events.completion?.state, .doneWipeBlocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.source.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: secondary.path).isEmpty)
        try assertNoTransfer(f, events: events)
    }

    func testRepeatedClicksStartOneWipeAttempt() async throws {
        let f = try await fixture(), events = Events()
        let c = await coordinator(f, events: events)
        async let first: Void = c.retryWipe(sessionID: f.record.id)
        async let second: Void = c.retryWipe(sessionID: f.record.id)
        _ = await (first, second)
        await fulfillment(of: [events.finished], timeout: 5)
        XCTAssertEqual(events.starts, 1)
        XCTAssertEqual(events.completion?.state, .done)
        try assertNoTransfer(f, events: events)
    }

    @MainActor
    func testRetryLabelDistinguishesErasureFromIncompleteTransfer() async throws {
        let f = try await fixture()
        let vm = SessionViewModel(sessionID: f.record.id, card: f.volume.info, resumed: false)
        vm.completed = f.record
        XCTAssertEqual(vm.retryButtonTitle, "Retry wipe")
        vm.completed?.files[0].state = .failed(.sourceMissing)
        XCTAssertEqual(vm.retryButtonTitle, "Retry transfer")
        vm.completed = f.record; vm.completed?.files[0].sourceHashHex = nil
        XCTAssertEqual(vm.retryButtonTitle, "Retry transfer")
    }
}
