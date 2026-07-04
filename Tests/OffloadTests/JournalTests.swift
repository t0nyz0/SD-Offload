import XCTest
@testable import OffloadCore

final class JournalTests: XCTestCase {
    var dir: URL!
    var historyDir: URL!

    override func setUp() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("offload-journal-tests-\(UUID().uuidString)")
        dir = base.appendingPathComponent("Journal")
        historyDir = base.appendingPathComponent("History")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func makeSession(states: [FileState]) -> SessionRecord {
        let files = states.enumerated().map { i, state in
            FileRecord(relPath: "DCIM/100TEST/IMG_\(i).RAF", size: 1000, mtime: Date(),
                       creationDate: nil, destRelPath: "2026/07/04/IMG_\(i).RAF", state: state)
        }
        return SessionRecord(cardVolumeUUID: "TEST-UUID", cardVolumeName: "TEST-1",
                             cardCapacityBytes: 1 << 30, files: files)
    }

    func testBeginPersistsDurably() async throws {
        let journal = Journal(directory: dir, historyDir: historyDir)
        let session = makeSession(states: [.pending])
        try await journal.begin(session)
        let onDisk = JSONIO.loadGuarded(SessionRecord.self,
                                        from: dir.appendingPathComponent("session-\(session.id.uuidString).json"))
        XCTAssertEqual(onDisk?.id, session.id)
    }

    func testResumeAppliesCrashRemap() async throws {
        let journal = Journal(directory: dir, historyDir: historyDir)
        let session = makeSession(states: [.copying, .uploading, .staged, .nasVerified])
        try await journal.begin(session)

        // Fresh journal instance = app relaunch.
        let journal2 = Journal(directory: dir, historyDir: historyDir)
        let resumed = await journal2.openIncompleteSession(cardUUID: "TEST-UUID")
        XCTAssertNotNil(resumed)
        XCTAssertEqual(resumed!.files[0].state, .pending)          // copying → pending
        XCTAssertEqual(resumed!.files[1].state, .stagedVerified)   // uploading → stagedVerified
        XCTAssertEqual(resumed!.files[2].state, .staged)           // re-verifies in place
        XCTAssertEqual(resumed!.files[3].state, .nasVerified)      // sticky
    }

    func testNoResumeForCompletedSession() async throws {
        let journal = Journal(directory: dir, historyDir: historyDir)
        var session = makeSession(states: [.nasVerified])
        session.state = .done
        try await journal.begin(session)
        await journal.setSessionState(.done, in: session.id)
        try await journal.complete(session.id)

        let journal2 = Journal(directory: dir, historyDir: historyDir)
        let resumed = await journal2.openIncompleteSession(cardUUID: "TEST-UUID")
        XCTAssertNil(resumed)
        let history = await journal2.loadHistory(limit: 10)
        XCTAssertEqual(history.count, 1)
    }

    func testIllegalTransitionCoercesToFailedAndBlocksWipe() async throws {
        let journal = Journal(directory: dir, historyDir: historyDir)
        let session = makeSession(states: [.pending])
        try await journal.begin(session)
        let fileID = session.files[0].id
        await journal.transition(file: fileID, to: .wiped, in: session.id)   // illegal jump
        let after = await journal.session(id: session.id)
        guard case .failed = after?.files[0].state else {
            return XCTFail("illegal transition must coerce to .failed, got \(String(describing: after?.files[0].state))")
        }
        XCTAssertFalse(after!.files[0].state.isWipeEligible)
    }

    func testTransitionUpdatesStatsAndFlushSurvivesReload() async throws {
        let journal = Journal(directory: dir, historyDir: historyDir)
        let session = makeSession(states: [.uploaded, .uploaded])
        try await journal.begin(session)
        await journal.transition(file: session.files[0].id, to: .nasVerified, in: session.id)
        try await journal.flushNow(session.id)

        let journal2 = Journal(directory: dir, historyDir: historyDir)
        let reloaded = await journal2.openIncompleteSession(cardUUID: "TEST-UUID")
        XCTAssertEqual(reloaded?.files[0].state, .nasVerified)
        XCTAssertEqual(reloaded?.stats.filesNASVerified, 1)
    }
}
