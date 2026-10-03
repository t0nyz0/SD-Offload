import XCTest
@testable import OffloadCore
@testable import OffloadEngine

final class RecoveryConsentTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        let lock = NSLock()
        var prompts = 0
        var starts = 0
        func record(_ event: EngineEvent) {
            lock.lock(); defer { lock.unlock() }
            if case .cardAwaitingConsent = event { prompts += 1 }
            if case .sessionStarted = event { starts += 1 }
        }
    }

    private func checkRecovery(policy: CardPolicy, expectedPrompts: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
        let session = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100)
        try await journal.begin(session)
        let incomplete = await journal.hasIncompleteSession(cardUUID: "fixture")
        XCTAssertTrue(incomplete)
        var config = AppConfig()
        config.defaultCardAction = policy
        config.nasRootPath = root.appendingPathComponent("nas").path
        config.stagingRootPath = root.appendingPathComponent("staging").path
        let fixed = config, events = Events()
        let coordinator = Coordinator(configProvider: { fixed }, configMutator: { _ in }, journal: journal, emit: { events.record($0) })
        let card = CardInfo(volumeUUID: "fixture", bsdName: "fixture", mountPath: root.path,
                            volumeName: "fixture", capacityBytes: 100, freeBytes: 50, hasMediaRoot: true)
        let volume = CandidateVolume(info: card, isRemovable: true, isEjectable: true, isInternal: false, isNetwork: false)
        await coordinator.handle(.volumeMounted(volume))
        await coordinator.handle(.volumeMounted(volume))
        XCTAssertEqual(events.prompts, expectedPrompts)
        XCTAssertEqual(events.starts, 0, "An unfinished journal must not override consent")
        await coordinator.decline(cardUUID: "fixture")
        XCTAssertEqual(events.starts, 0)
        await coordinator.handle(.volumeUnmounted(volumeUUID: "fixture", bsdName: "fixture"))
        await coordinator.handle(.volumeMounted(volume))
        XCTAssertEqual(events.prompts, expectedPrompts * 2, "A fresh insertion asks again")
        XCTAssertEqual(events.starts, 0)
    }

    func testInterruptedTransferHonorsAskAndDecline() async throws {
        try await checkRecovery(policy: .ask, expectedPrompts: 1)
    }

    func testInterruptedTransferHonorsIgnore() async throws {
        try await checkRecovery(policy: .ignore, expectedPrompts: 0)
    }

    func testWipeErrorPreservesOperationAndErrnoThroughNSError() {
        let error: Error = OffloadError.posix(ENOTSUP, stage: "claim source for erasure")
        XCTAssertTrue(error.localizedDescription.contains("claim source for erasure"))
        XCTAssertTrue(error.localizedDescription.contains("errno \(ENOTSUP)"))
        XCTAssertEqual((error as NSError).localizedDescription, error.localizedDescription)
    }
}
