import XCTest
import CryptoKit
@testable import OffloadCore
@testable import OffloadEngine

final class StagingCleanupTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var nas: URL!
    private var staging: StagingStore!
    private let bytes = Data(repeating: 0x5B, count: 4096)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("offload-staging-test-" + UUID().uuidString).resolvingSymlinksInPath()
        nas = root.appendingPathComponent("nas")
        try fm.createDirectory(at: nas, withIntermediateDirectories: true)
        staging = StagingStore(rootPath: root.appendingPathComponent("staging").path)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func file(_ name: String = "photo.JPG", state: FileState = .nasVerified) -> FileRecord {
        FileRecord(relPath: "DCIM/" + name, size: Int64(bytes.count), mtime: Date(), creationDate: nil,
            destRelPath: "2026/10/29/" + name,
            sourceHashHex: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            state: state, stateChangedAt: Date().addingTimeInterval(-30))
    }

    private func record(_ files: [FileRecord], state: SessionState = .doneWipeBlocked) -> SessionRecord {
        var result = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "fixture", cardCapacityBytes: 100_000,
            state: state, files: files, endedAt: Date().addingTimeInterval(-15))
        result.nasRootPath = nas.path
        result.stagingRootPath = staging.root.path
        return result
    }

    private func destination(_ file: FileRecord, root: URL? = nil) throws -> URL {
        let target = (root ?? nas).appendingPathComponent(file.destRelPath)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target)
        return target
    }

    @discardableResult
    private func stage(_ file: FileRecord, in record: SessionRecord) throws -> URL {
        try staging.ensureSessionDir(record.id)
        let target = staging.stagedURL(session: record.id, file: file)
        try bytes.write(to: target)
        return target
    }

    private func config() -> AppConfig {
        var c = AppConfig()
        c.nasRootPath = nas.path; c.stagingRootPath = staging.root.path
        c.testAllowLocalNAS = true; c.stagingHeadroomBytes = 0
        c.wipePolicy = .askEachTime; c.autoEject = false
        c.hop1Workers = 1; c.hop2Workers = 1
        return c
    }

    private func journal() -> Journal {
        Journal(directory: root.appendingPathComponent("journal"), historyDir: root.appendingPathComponent("history"))
    }

    func testVerifiedFilesCleanIndividuallyEvenWhenSessionWipeIsBlocked() async throws {
        let good = file("good.JPG"), failed = file("failed.JPG", state: .failed(.sourceMissing))
        let missing = file("missing.JPG"), corrupt = file("corrupt.JPG")
        let r = record([good, failed, missing, corrupt])
        for item in r.files { try stage(item, in: r) }
        _ = try destination(good); _ = try destination(failed)
        let corruptDest = try destination(corrupt)
        try Data(repeating: 0xEE, count: bytes.count).write(to: corruptDest)
        let unknown = staging.sessionDir(r.id).appendingPathComponent("unrecognized-original.JPG")
        try Data("keep unrelated original".utf8).write(to: unknown)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: good).path))
        for item in [failed, missing, corrupt] {
            XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: unknown), Data("keep unrelated original".utf8))
        XCTAssertFalse(fm.fileExists(atPath: nas.appendingPathComponent(missing.destRelPath).path))
    }

    func testLatestCompletedBatchDoesNotNeedAnotherTransfer() async throws {
        let r = record([file()], state: .done)
        // Use the exact manifest file identity.
        let item = r.files[0]
        try stage(item, in: r); _ = try destination(item)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
    }

    func testRetentionDaysRemainHonored() async throws {
        let r = record([file()], state: .done)
        let item = r.files[0]
        try stage(item, in: r); _ = try destination(item)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 7)
        XCTAssertTrue(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: item).path))
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 7,
            now: Date().addingTimeInterval(8 * 86_400))
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
    }

    func testRequiredSecondCopyMustAlsoVerifyBeforeCleanup() async throws {
        let r = record([file()])
        let item = r.files[0]
        try stage(item, in: r); _ = try destination(item)
        let second = root.appendingPathComponent("second")
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, secondaryRoot: second.path)
        XCTAssertTrue(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: item).path))
        _ = try destination(item, root: second)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, secondaryRoot: second.path)
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
    }

    func testInactiveCrashJournalCleansOnlyDurablyVerifiedFilesWithoutCardInsert() async throws {
        let good = file("good.JPG"), pending = file("pending.JPG", state: .stagedVerified)
        var r = record([good, pending], state: .transferring); r.endedAt = nil
        try stage(good, in: r); try stage(pending, in: r)
        _ = try destination(good); _ = try destination(pending)
        let beforeCrash = journal(); try await beforeCrash.begin(r)
        let journalURL = root.appendingPathComponent("journal/session-\(r.id.uuidString).json")
        let durableBefore = try Data(contentsOf: journalURL)
        let restarted = journal(), fixed = config()
        let coordinator = Coordinator(configProvider: { fixed }, configMutator: { _ in }, journal: restarted, emit: { _ in })
        await coordinator.performIdleCleanup()
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: good).path))
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: pending)), bytes)
        XCTAssertEqual(try Data(contentsOf: journalURL), durableBefore,
            "Maintenance must not relabel or rewrite unfinished transfers")
    }

    func testInMemoryActiveSessionIsExcludedFromCrashCleanup() async throws {
        let r = record([file()], state: .transferring)
        let item = r.files[0]
        try stage(item, in: r); _ = try destination(item)
        let j = journal(); try await j.begin(r)
        let candidates = await j.stagingCleanupRecords()
        XCTAssertFalse(candidates.contains { $0.id == r.id })
        await staging.pruneCompletedBeforeNextRun(candidates, nasRoot: nas.path, keepDays: 0)
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
    }

    func testBusyGuardAndCancellationPreserveAllCopies() async throws {
        let r = record([file()])
        let item = r.files[0]
        try stage(item, in: r); _ = try destination(item)
        let protection = StagingMaintenanceGuard(); protection.setBusy(true)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, protection: protection)
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
        protection.setBusy(false)
        let store = staging!, nasRoot = nas.path
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.pruneCompletedBeforeNextRun([r], nasRoot: nasRoot, keepDays: 0, protection: protection)
        }.value
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, protection: protection)
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
    }

    func testChangedLocalCopyAndSessionSymlinkAreNeverDeleted() async throws {
        let r = record([file()])
        let item = r.files[0]
        let staged = try stage(item, in: r); _ = try destination(item)
        let edited = Data(repeating: 0xF0, count: bytes.count)
        try edited.write(to: staged)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertEqual(try Data(contentsOf: staged), edited)
        let outside = root.appendingPathComponent("outside")
        try fm.moveItem(at: staging.sessionDir(r.id), to: outside)
        try fm.createSymbolicLink(at: staging.sessionDir(r.id), withDestinationURL: outside)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent(staged.lastPathComponent)), edited)
    }

    func testVerifiedPartialIsRemovedWithoutSweepingAnotherFilesPartial() async throws {
        let good = file(), unfinished = file("new.JPG", state: .copying)
        let r = record([good, unfinished])
        try stage(good, in: r); _ = try destination(good)
        try Data(bytes.prefix(100)).write(to: staging.partialURL(session: r.id, file: good))
        let untransferred = staging.partialURL(session: r.id, file: unfinished)
        try Data("untransferred original bytes".utf8).write(to: untransferred)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertFalse(fm.fileExists(atPath: staging.partialURL(session: r.id, file: good).path))
        XCTAssertEqual(try Data(contentsOf: untransferred), Data("untransferred original bytes".utf8))
    }

    func testDurableDeletionIntentRetiresOldVerifiedCacheWithoutResurrectingNAS() async throws {
        let r = record([file()])
        let item = r.files[0]
        try stage(item, in: r)
        let original = try destination(item)
        let ledgerURL = root.appendingPathComponent("deletions.json")
        let ledger = DestinationDeletionStore(file: ledgerURL)
        let trash = root.appendingPathComponent("deleted-photo.JPG")
        let result = LibraryTrash.perform([original], archiveRoot: nas, deletionStore: ledger) {
            try self.fm.moveItem(at: $0, to: trash)
        }
        XCTAssertEqual(result.removed, [original])
        let reopened = DestinationDeletionStore(file: ledgerURL)
        XCTAssertTrue(try reopened.blocksCreation(of: item, root: nas.path))
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, deletionStore: reopened)
        XCTAssertFalse(fm.fileExists(atPath: original.path))
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
        XCTAssertEqual(try Data(contentsOf: trash), bytes)
    }

    func testDeletionFailureRevokesIntentAndPreservesOriginal() throws {
        let item = file(), original = try destination(file())
        let ledger = DestinationDeletionStore(file: root.appendingPathComponent("deletions.json"))
        try Data("blocks recovery directory".utf8).write(to: LibraryTrash.folder(under: nas))
        let result = LibraryTrash.perform([original], archiveRoot: nas, deletionStore: ledger) { _ in
            throw CocoaError(.featureUnsupported)
        }
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertFalse(try ledger.blocksCreation(of: item, root: nas.path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testLedgerWriteFailurePreventsDeletionBeforeItStarts() throws {
        let original = try destination(file())
        let blocked = root.appendingPathComponent("not-a-directory")
        try bytes.write(to: blocked)
        let ledger = DestinationDeletionStore(file: blocked.appendingPathComponent("deletions.json"))
        var nativeCalled = false
        let result = LibraryTrash.perform([original], archiveRoot: nas, deletionStore: ledger) { _ in nativeCalled = true }
        XCTAssertFalse(nativeCalled)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testMissingFinderDeletedDestinationIsNotRecreatedOnRetry() async throws {
        try await assertMissingVerifiedDestinationIsNotRecreated(crashJournal: false, secondary: false)
    }

    func testMissingFinderDeletedDestinationInCrashJournalIsNotRecreatedOnRetry() async throws {
        try await assertMissingVerifiedDestinationIsNotRecreated(crashJournal: true, secondary: false)
    }

    func testMissingPreviouslyVerifiedSecondaryIsNotRecreatedByFreshRetry() async throws {
        try await assertMissingVerifiedDestinationIsNotRecreated(crashJournal: false, secondary: true)
    }

    private func assertMissingVerifiedDestinationIsNotRecreated(crashJournal: Bool, secondary: Bool) async throws {
        let second = root.appendingPathComponent("second")
        var previous = record([file()])
        if secondary { previous.secondaryDestPath = second.path }
        if crashJournal { previous.state = .transferring; previous.endedAt = nil }
        let historical = previous.files[0]
        let beforeRestart = journal(); try await beforeRestart.begin(previous)
        if !crashJournal { try await beforeRestart.complete(previous.id) }
        let j = journal()
        if secondary {
            _ = try destination(historical)
            try fm.createDirectory(at: second, withIntermediateDirectories: true)
        }
        var retryFile = historical; retryFile.state = .stagedVerified
        let retry = record([retryFile], state: .transferring)
        try stage(retryFile, in: retry)
        let source = root.appendingPathComponent("card").appendingPathComponent(retryFile.relPath)
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: source)
        try await j.begin(retry)
        var c = config()
        if secondary { c.secondaryDestPath = second.path }
        let fixed = c
        let runner = SessionRunner(sessionID: retry.id,
            card: CardInfo(volumeUUID: "fixture", bsdName: "fixture-not-device", mountPath: root.appendingPathComponent("card").path,
                volumeName: "fixture", capacityBytes: 100_000, freeBytes: 50_000, hasMediaRoot: true),
            config: fixed, journal: j, staging: staging, nas: NASLocator(configProvider: { fixed }), cardWatcher: CardWatcher(), emit: { _ in })
        await runner.run()
        XCTAssertFalse(fm.fileExists(atPath: (secondary ? second : nas).appendingPathComponent(retryFile.destRelPath).path))
        if secondary { XCTAssertEqual(try Data(contentsOf: nas.appendingPathComponent(retryFile.destRelPath)), bytes) }
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: retry.id, file: retryFile)), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let history = await j.historySession(id: retry.id)
        XCTAssertEqual(history?.state, .doneWipeBlocked)
    }

    func testPriorVerificationDoesNotBlockDifferentBytesOrDifferentConfiguredNAS() async throws {
        let previous = record([file()])
        let j = journal(); try await j.begin(previous); try await j.complete(previous.id)
        var changed = previous.files[0]; changed.sourceHashHex = String(repeating: "f", count: 64)
        let sameRootDifferentBytes = await j.previouslyVerifiedDestination(changed, root: nas.path)
        let differentRoot = await j.previouslyVerifiedDestination(previous.files[0], root: root.appendingPathComponent("new-nas").path)
        XCTAssertFalse(sameRootDifferentBytes)
        XCTAssertFalse(differentRoot)
    }

    func testLiveTransferReleasesStagingAfterDurableNASAndSecondaryVerification() async throws {
        try await assertLiveTransferReleasesStaging(legacyHistory: false)
    }

    func testNewSecondDestinationStillReceivesCopyWhenLegacyHistoryHasNoArchiveRoot() async throws {
        try await assertLiveTransferReleasesStaging(legacyHistory: true)
    }

    private func assertLiveTransferReleasesStaging(legacyHistory: Bool) async throws {
        let item = file(state: .pending)
        var r = record([item], state: .scanning); r.endedAt = nil
        let cardRoot = root.appendingPathComponent("card")
        let source = cardRoot.appendingPathComponent(item.relPath)
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: source)
        var c = config(); c.secondaryDestPath = root.appendingPathComponent("second").path
        try fm.createDirectory(atPath: c.secondaryDestPath!, withIntermediateDirectories: true)
        let fixed = c, j = journal()
        if legacyHistory {
            var previous = record([item]); previous.nasRootPath = nil
            previous.files[0].state = .nasVerified
            try await j.begin(previous); try await j.complete(previous.id)
            _ = try destination(item)
        }
        try await j.begin(r)
        let ready = expectation(description: "transfer verified; awaiting wipe consent")
        let runner = SessionRunner(sessionID: r.id,
            card: CardInfo(volumeUUID: "fixture", bsdName: "fixture-not-device", mountPath: cardRoot.path,
                volumeName: "fixture", capacityBytes: 100_000, freeBytes: 50_000, hasMediaRoot: true),
            config: fixed, journal: j, staging: staging, nas: NASLocator(configProvider: { fixed }), cardWatcher: CardWatcher(), emit: {
                if case .phase(.awaitingWipeConsent) = $0 { ready.fulfill() }
            })
        let task = Task { await runner.run() }
        await fulfillment(of: [ready], timeout: 10)
        let durable = try JSONIO.load(SessionRecord.self, from: root.appendingPathComponent("journal/session-\(r.id.uuidString).json"))
        XCTAssertTrue(durable.files[0].state.recordsNASVerification)
        XCTAssertNotNil(durable.files[0].sourceHashHex)
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: item).path))
        XCTAssertEqual(try Data(contentsOf: nas.appendingPathComponent(item.destRelPath)), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: c.secondaryDestPath!).appendingPathComponent(item.destRelPath)), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        await runner.cancelWipe(); await task.value
    }

    func testFailedDurableCheckpointLeavesStagingIntact() async throws {
        let r = record([file()])
        let recorded = r.files[0]
        try stage(recorded, in: r)
        let j = journal(); try await j.begin(r)
        let path = root.appendingPathComponent("journal/session-\(r.id.uuidString).json")
        try fm.removeItem(at: path)
        try fm.createDirectory(at: path, withIntermediateDirectories: false)
        do {
            _ = try await staging.retirePersistedFile(session: r.id, fileID: recorded.id, journal: j)
            XCTFail("A failed durable save must block staging removal")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: recorded)), bytes)
    }

    func testCrashAfterTrashKeepsIntentAcrossStoreReopen() async throws {
        let r = record([file()]), ledgerURL = root.appendingPathComponent("deletions.json")
        let item = r.files[0]
        try stage(item, in: r)
        let original = try destination(item)
        let ledger = DestinationDeletionStore(file: ledgerURL)
        _ = try ledger.begin(url: original, root: nas, size: item.size)
        let deleted = root.appendingPathComponent("trashed-before-crash.JPG")
        try fm.moveItem(at: original, to: deleted)
        // Simulate process loss before the deletion call returns: no revocation.
        let reopened = DestinationDeletionStore(file: ledgerURL)
        XCTAssertTrue(try reopened.blocksCreation(of: item, root: nas.path))
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, deletionStore: reopened)
        XCTAssertFalse(fm.fileExists(atPath: original.path))
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
        XCTAssertEqual(try Data(contentsOf: deleted), bytes)
    }

    func testDeletionIntentNeverDiscardsUnverifiedOrNewerLocalOriginal() async throws {
        let older = file(), original = try destination(file())
        let ledger = DestinationDeletionStore(file: root.appendingPathComponent("deletions.json"))
        let deletedAt = Date().addingTimeInterval(-10)
        _ = try ledger.begin(url: original, root: nas, size: older.size, now: deletedAt)
        try fm.removeItem(at: original)
        let unverified = file(state: .stagedVerified)
        var newer = file(); newer.stateChangedAt = Date()
        for item in [unverified, newer] {
            let r = record([item]); try stage(item, in: r)
            await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, deletionStore: ledger)
            XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
        }
    }

    func testDeletionIntentAndPriorVerificationRecognizeArchiveAliases() async throws {
        let r = record([file()]), item = file()
        let original = try destination(item)
        let alias = root.appendingPathComponent("nas-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: nas)
        let ledger = DestinationDeletionStore(file: root.appendingPathComponent("deletions.json"))
        _ = try ledger.begin(url: alias.appendingPathComponent(item.destRelPath), root: alias, size: item.size)
        XCTAssertTrue(try ledger.blocksCreation(of: item, root: nas.path))
        let j = journal(); try await j.begin(r); try await j.complete(r.id)
        let wasVerified = await j.previouslyVerifiedDestination(r.files[0], root: alias.path)
        XCTAssertTrue(wasVerified)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testCorruptDeletionLedgerPreventsAutomaticCreation() throws {
        let url = root.appendingPathComponent("deletions.json")
        try Data("{not-valid-json".utf8).write(to: url)
        let ledger = DestinationDeletionStore(file: url)
        XCTAssertThrowsError(try ledger.blocksCreation(of: file(), root: nas.path))
    }

    func testExistingVerifiedSecondCopyIsNotRecreatedAfterDeletion() async throws {
        let item = file(), second = root.appendingPathComponent("second")
        try fm.createDirectory(at: second, withIntermediateDirectories: true)
        _ = try destination(item)
        var r = record([item], state: .transferring)
        r.secondaryDestPath = second.path; r.endedAt = nil
        try stage(item, in: r)
        var c = config(); c.secondaryDestPath = second.path
        let fixed = c, j = journal(); try await j.begin(r)
        let ready = expectation(description: "recheck reached consent")
        let runner = SessionRunner(sessionID: r.id,
            card: CardInfo(volumeUUID: "fixture", bsdName: "fixture-not-device", mountPath: root.appendingPathComponent("card").path,
                volumeName: "fixture", capacityBytes: 100_000, freeBytes: 50_000, hasMediaRoot: true),
            config: fixed, journal: j, staging: staging, nas: NASLocator(configProvider: { fixed }), cardWatcher: CardWatcher(), emit: {
                if case .phase(.awaitingWipeConsent) = $0 { ready.fulfill() }
            })
        let task = Task { await runner.run() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertFalse(fm.fileExists(atPath: second.appendingPathComponent(item.destRelPath).path))
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
        await runner.cancelWipe(); await task.value
    }

    func testUnexpectedPartialBytesArePreservedEvenWhenFullCopyVerified() async throws {
        let r = record([file()])
        let recorded = r.files[0]
        try stage(recorded, in: r); _ = try destination(recorded)
        let partial = staging.partialURL(session: r.id, file: recorded)
        let changed = Data("untransferred bytes".utf8)
        try changed.write(to: partial)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: recorded).path))
        XCTAssertEqual(try Data(contentsOf: partial), changed)
    }

    func testCrashPartialWithoutFullStagingCopyIsComparedToVerifiedNASBytes() async throws {
        let r = record([file()])
        let recorded = r.files[0]
        try staging.ensureSessionDir(r.id); _ = try destination(recorded)
        try Data(bytes.prefix(100)).write(to: staging.partialURL(session: r.id, file: recorded))
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
    }

    func testKnownEmptySessionDirectoryIsRemovedWithoutSweepingUnknownDirectory() async throws {
        let r = record([file()])
        try staging.ensureSessionDir(r.id)
        let unknown = staging.sessionDir(UUID()); try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertFalse(fm.fileExists(atPath: staging.sessionDir(r.id).path))
        XCTAssertTrue(fm.fileExists(atPath: unknown.path))
    }

    func testIntentFromDeletingVisiblePartialUploadBlocksFullSizeRetry() throws {
        let item = file(), original = try destination(file())
        try Data().write(to: original)
        let ledger = DestinationDeletionStore(file: root.appendingPathComponent("deletions.json"))
        _ = try ledger.begin(url: original, root: nas, size: 0)
        try fm.removeItem(at: original)
        XCTAssertTrue(try ledger.blocksCreation(of: item, root: nas.path))
        XCTAssertFalse(try ledger.permitsRetirement(of: item, root: nas.path),
            "Deleting an unverified partial is not evidence to discard a full local original")
    }

    func testCollisionSuffixRetryDoesNotRestoreHistoricallyVerifiedDeletedFile() async throws {
        let base = file()
        var old = base; old.destRelPath = CollisionPolicy.suffixed(base.destRelPath, attempt: 2)
        let previous = record([old])
        let j = journal(); try await j.begin(previous); try await j.complete(previous.id)
        let occupied = try destination(base)
        let unrelated = Data(repeating: 0xEF, count: bytes.count)
        try unrelated.write(to: occupied)
        var retryFile = base; retryFile.state = .stagedVerified
        let retry = record([retryFile], state: .transferring)
        try stage(retryFile, in: retry); try await j.begin(retry)
        let c = config()
        let runner = SessionRunner(sessionID: retry.id,
            card: CardInfo(volumeUUID: "fixture", bsdName: "fixture-not-device", mountPath: root.appendingPathComponent("card").path,
                volumeName: "fixture", capacityBytes: 100_000, freeBytes: 50_000, hasMediaRoot: true),
            config: c, journal: j, staging: staging, nas: NASLocator(configProvider: { c }), cardWatcher: CardWatcher(), emit: { _ in })
        await runner.run()
        XCTAssertFalse(fm.fileExists(atPath: nas.appendingPathComponent(old.destRelPath).path))
        XCTAssertEqual(try Data(contentsOf: occupied), unrelated)
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: retry.id, file: retryFile)), bytes)
    }

    func testDeletedFileDoesNotHoldBudgetAndStrandOtherTransfers() async throws {
        let deleted = file("deleted.JPG"), good = file("good.JPG", state: .pending)
        let j = journal(), previous = record([deleted])
        try await j.begin(previous); try await j.complete(previous.id)
        var pending = deleted; pending.state = .pending
        let r = record([pending, good], state: .scanning)
        let cardRoot = root.appendingPathComponent("card")
        for item in r.files {
            let source = cardRoot.appendingPathComponent(item.relPath)
            try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: source)
        }
        var c = config(); c.stagingBudgetCapBytes = Int64(bytes.count)
        let fixed = c; try await j.begin(r)
        let finished = expectation(description: "failed and successful files settled within one-file budget")
        let runner = SessionRunner(sessionID: r.id,
            card: CardInfo(volumeUUID: "fixture", bsdName: "fixture-not-device", mountPath: cardRoot.path,
                volumeName: "fixture", capacityBytes: 100_000, freeBytes: 50_000, hasMediaRoot: true),
            config: fixed, journal: j, staging: staging, nas: NASLocator(configProvider: { fixed }), cardWatcher: CardWatcher(), emit: {
                if case .phase(.doneWipeBlocked) = $0 { finished.fulfill() }
            })
        let task = Task { await runner.run() }
        await fulfillment(of: [finished], timeout: 10)
        await runner.cancel(); await task.value
        XCTAssertFalse(fm.fileExists(atPath: nas.appendingPathComponent(pending.destRelPath).path))
        XCTAssertEqual(try Data(contentsOf: nas.appendingPathComponent(good.destRelPath)), bytes)
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: pending)), bytes)
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: good).path))
        for item in r.files { XCTAssertEqual(try Data(contentsOf: cardRoot.appendingPathComponent(item.relPath)), bytes) }
    }

    func testHistoryRetentionKeepsManifestWhileStagedDataStillExists() async throws {
        let j = journal()
        let kept = record([file()])
        try stage(kept.files[0], in: kept)
        let history = root.appendingPathComponent("history")
        try JSONIO.saveDurable(kept, to: history.appendingPathComponent("session-\(kept.id.uuidString).json"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: history.appendingPathComponent("session-\(kept.id.uuidString).json").path)
        for _ in 0..<300 {
            let r = record([])
            try JSONIO.saveDurable(r, to: history.appendingPathComponent("session-\(r.id.uuidString).json"))
        }
        let newest = record([]); try await j.begin(newest); try await j.complete(newest.id)
        XCTAssertTrue(fm.fileExists(atPath: history.appendingPathComponent("session-\(kept.id.uuidString).json").path))
        XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: kept.id, file: kept.files[0])), bytes)
    }

    func testRetirementHonorsBusyGuardImmediatelyBeforeLocalDeletion() async throws {
        let r = record([file()]), protection = StagingMaintenanceGuard()
        let item = r.files[0], local = try stage(r.files[0], in: r)
        _ = try destination(item)
        let partial = staging.partialURL(session: r.id, file: item)
        try Data(bytes.prefix(100)).write(to: partial)
        protection.setBusy(true)
        // Exercise the final deletion guard directly: preliminary maintenance
        // checks alone cannot protect a transfer that starts during read-back.
        let removed = try await staging.retireVerifiedFile(session: r.id, file: item, protection: protection)
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(try Data(contentsOf: partial), Data(bytes.prefix(100)))
        XCTAssertEqual(try Data(contentsOf: nas.appendingPathComponent(item.destRelPath)), bytes)
    }

    func testSymlinkedStagingRootAndManagedFilePreserveTheirTargets() async throws {
        let r = record([file()])
        let managed = r.files[0], local = try stage(r.files[0], in: r)
        _ = try destination(managed)
        let outsideRoot = root.appendingPathComponent("relocated-staging")
        try fm.moveItem(at: staging.root, to: outsideRoot)
        try fm.createSymbolicLink(at: staging.root, withDestinationURL: outsideRoot)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        try fm.removeItem(at: staging.root)
        try fm.moveItem(at: outsideRoot, to: staging.root)
        let outside = root.appendingPathComponent("unmanaged-original.JPG")
        try fm.moveItem(at: local, to: outside)
        try fm.createSymbolicLink(at: local, withDestinationURL: outside)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
        XCTAssertTrue(try local.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertEqual(try Data(contentsOf: outside), bytes)
    }

    func testDestinationPathEscapesCannotAuthorizeStagingCleanup() async throws {
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let original = outside.appendingPathComponent("photo.JPG")
        try bytes.write(to: original)
        try fm.createSymbolicLink(at: nas.appendingPathComponent("escaped"), withDestinationURL: outside)
        for path in [original.path, "../outside/photo.JPG", "escaped/photo.JPG"] {
            var item = file(); item.destRelPath = path
            let r = record([item])
            try stage(item, in: r)
            await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0)
            XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    func testDeletionIntentDoesNotDiscardRecoveryForChangedDestinationOrMissingSecondCopy() async throws {
        let r = record([file()]), item = r.files[0]
        let local = try stage(item, in: r), target = try destination(item)
        let ledger = DestinationDeletionStore(file: root.appendingPathComponent("deletions.json"))
        _ = try ledger.begin(url: target, root: nas, size: item.size)
        let changed = Data(repeating: 0xF1, count: bytes.count)
        try changed.write(to: target)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, deletionStore: ledger)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(try Data(contentsOf: target), changed)
        try bytes.write(to: target)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0,
            secondaryRoot: root.appendingPathComponent("missing-second").path, deletionStore: ledger)
        XCTAssertEqual(try Data(contentsOf: local), bytes)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testConcurrentMaintenanceKeepsUntransferredFilesAndLeavesNASBytesUnchanged() async throws {
        let verified = (0..<16).map { file("verified-\($0).JPG") }
        let unfinished = (0..<16).map { file("unfinished-\($0).JPG", state: .stagedVerified) }
        let r = record(verified + unfinished)
        for item in r.files { try stage(item, in: r) }
        for item in verified { _ = try destination(item) }
        let unknown = staging.sessionDir(r.id).appendingPathComponent("unknown-original")
        try bytes.write(to: unknown)
        let store = staging!, nasPath = nas.path
        let before = try fileSnapshot(nas)
        async let first: Void = store.pruneCompletedBeforeNextRun([r], nasRoot: nasPath, keepDays: 0)
        async let second: Void = store.pruneCompletedBeforeNextRun([r], nasRoot: nasPath, keepDays: 0)
        _ = await (first, second)
        for item in verified { XCTAssertFalse(fm.fileExists(atPath: store.stagedURL(session: r.id, file: item).path)) }
        for item in unfinished { XCTAssertEqual(try Data(contentsOf: store.stagedURL(session: r.id, file: item)), bytes) }
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
        XCTAssertEqual(try fileSnapshot(nas), before)
    }

    func testCleanupWithRequiredSecondCopyNeverChangesEitherDestinationTree() async throws {
        let good = file("good.JPG"), missing = file("missing.JPG"), changed = file("changed.JPG")
        let r = record([good, missing, changed]), second = root.appendingPathComponent("second")
        for item in r.files { try stage(item, in: r); _ = try destination(item) }
        _ = try destination(good, root: second)
        let corrupt = try destination(changed, root: second)
        try Data(repeating: 0xF2, count: bytes.count).write(to: corrupt)
        let primaryBefore = try fileSnapshot(nas), secondBefore = try fileSnapshot(second)
        await staging.pruneCompletedBeforeNextRun([r], nasRoot: nas.path, keepDays: 0, secondaryRoot: second.path)
        XCTAssertFalse(fm.fileExists(atPath: staging.stagedURL(session: r.id, file: good).path))
        for item in [missing, changed] { XCTAssertEqual(try Data(contentsOf: staging.stagedURL(session: r.id, file: item)), bytes) }
        XCTAssertEqual(try fileSnapshot(nas), primaryBefore)
        XCTAssertEqual(try fileSnapshot(second), secondBefore)
    }

    private func fileSnapshot(_ directory: URL) throws -> [String: Data] {
        let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in entries where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }
}
