import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine

final class ExFATErasureTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offload-exfat-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func fixture() async throws -> (FileRecord, SessionRecord, Journal, WipeGate.Verdict) {
        let data = Data("verified disposable photo".utf8), source = root.appendingPathComponent("photo.jpg")
        try data.write(to: source)
        let st = try XCTUnwrap(WipeGate.liveStat(source.path))
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

    func testUnsupportedExclusiveRenameStillErasesOnlyApprovedFile() async throws {
        let (_, session, journal, verdict) = try await fixture()
        let untouched = root.appendingPathComponent("unrelated.jpg")
        try Data("keep".utf8).write(to: untouched)
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
            sessionID: session.id, fileIDs: [:], exclusiveRename: { _, _, _, _ in ENOTSUP })
        XCTAssertNil(result.stoppedEarly)
        XCTAssertEqual(result.filesDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.jpg").path))
        XCTAssertEqual(try Data(contentsOf: untouched), Data("keep".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.hasPrefix(".offload-recovery-") }))
    }

    func testOtherRenameErrorsDoNotUseFallback() async throws {
        let (_, session, journal, verdict) = try await fixture()
        let source = root.appendingPathComponent("photo.jpg"), original = try Data(contentsOf: source)
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
            sessionID: session.id, fileIDs: [:], exclusiveRename: { _, _, _, _ in EACCES })
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertTrue(result.stoppedEarly?.contains("errno \(EACCES)") == true)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testEmptyInterruptedRecoveryDirectoryAndENOSYSFallback() async throws {
        let (file, session, journal, verdict) = try await fixture()
        let source = root.appendingPathComponent(file.relPath), original = try Data(contentsOf: source)
        let recovery = root.appendingPathComponent(Wiper.recoveryName(fileID: file.id, name: file.relPath))
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try await Wiper.restoreInterruptedClaims(files: [file], root: root.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
            sessionID: session.id, fileIDs: [:], exclusiveRename: { _, _, _, _ in ENOSYS })
        XCTAssertNil(result.stoppedEarly)
        XCTAssertEqual(result.filesDeleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testExistingRecoveryDirectoryAndSourceArePreserved() async throws {
        let (file, session, journal, verdict) = try await fixture()
        let recovery = root.appendingPathComponent(Wiper.recoveryName(fileID: file.id, name: file.relPath))
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let saved = recovery.appendingPathComponent("source")
        try Data("earlier recovery".utf8).write(to: saved)
        let original = try Data(contentsOf: root.appendingPathComponent("photo.jpg"))
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
            sessionID: session.id, fileIDs: [:], exclusiveRename: { _, _, _, _ in ENOTSUP })
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertEqual(try Data(contentsOf: saved), Data("earlier recovery".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.jpg")), original)
    }

    func testChangedBytesWithOriginalSizeAndTimestampAreRestored() async throws {
        let (_, session, journal, verdict) = try await fixture()
        let source = root.appendingPathComponent("photo.jpg")
        var old = stat(); XCTAssertEqual(lstat(source.path, &old), 0)
        let modified = Data(repeating: 8, count: Int(old.st_size))
        let fd = open(source.path, O_WRONLY)
        modified.withUnsafeBytes { XCTAssertEqual(write(fd, $0.baseAddress, $0.count), $0.count) }
        var times = [old.st_atimespec, old.st_mtimespec]
        XCTAssertEqual(futimens(fd, &times), 0); close(fd)
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
            sessionID: session.id, fileIDs: [:], exclusiveRename: { _, _, _, _ in ENOTSUP })
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertNotNil(result.stoppedEarly)
        XCTAssertEqual(try Data(contentsOf: source), modified)
        XCTAssertEqual(WipeGate.liveStat(source.path)?.mtime, verdict.deletions.first?.expected.mtime)
    }

    func testDirectoryClaimRecoveryNeverOverwritesOccupiedOriginal() async throws {
        let (file, _, _, _) = try await fixture()
        let source = root.appendingPathComponent("photo.jpg"), original = try Data(contentsOf: source)
        let recovery = root.appendingPathComponent(Wiper.recoveryName(fileID: file.id, name: file.relPath))
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let claimed = recovery.appendingPathComponent("source")
        try FileManager.default.moveItem(at: source, to: claimed)
        try Data("new photo".utf8).write(to: source)
        do {
            try await Wiper.restoreInterruptedClaims(files: [file], root: root.path, exclusiveRename: { _, _, _, _ in ENOTSUP })
            XCTFail("Occupied original was replaced")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: source), Data("new photo".utf8))
        XCTAssertEqual(try Data(contentsOf: claimed), original)
        try FileManager.default.removeItem(at: source)
        try await Wiper.restoreInterruptedClaims(files: [file], root: root.path, exclusiveRename: { _, _, _, _ in ENOTSUP })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testLegacyRecoveryFileRestoresWithoutExclusiveRename() async throws {
        let (file, _, _, _) = try await fixture()
        let source = root.appendingPathComponent("photo.jpg"), original = try Data(contentsOf: source)
        let recovery = root.appendingPathComponent(Wiper.recoveryName(fileID: file.id, name: file.relPath))
        try FileManager.default.moveItem(at: source, to: recovery)
        try await Wiper.restoreInterruptedClaims(files: [file], root: root.path, exclusiveRename: { _, _, _, _ in ENOTSUP })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testReplacementBetweenOpenAndClaimIsNotErased() async throws {
        let (_, session, journal, verdict) = try await fixture()
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
            sessionID: session.id, fileIDs: [:], exclusiveRename: { parent, name, _, _ in
                // Replace the source after Wiper pins the approved open file.
                // Restoration uses the same hook; only act on the original name.
                if name == "photo.jpg" {
                    _ = unlinkat(parent, name, 0)
                    let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
                    let replacement = Data("new photo".utf8)
                    replacement.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
                    close(fd)
                }
                return ENOTSUP
            })
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.jpg")), Data("new photo".utf8))
    }

    func testCancellationAfterClaimRestoresOriginal() async throws {
        let (_, session, journal, verdict) = try await fixture()
        let source = root.appendingPathComponent("photo.jpg"), original = try Data(contentsOf: source)
        let task = Task {
            await Wiper.execute(deletions: verdict.deletions, journal: journal,
                sessionID: session.id, fileIDs: [:], exclusiveRename: { _, name, _, _ in
                    if name == "photo.jpg" { withUnsafeCurrentTask { $0?.cancel() } }
                    return ENOTSUP
                })
        }
        let result = await task.value
        XCTAssertEqual(result.filesDeleted, 0)
        XCTAssertNotNil(result.stoppedEarly)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
