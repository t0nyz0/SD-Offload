import XCTest
@testable import OffloadCore
@testable import OffloadEngine

final class WipeGateTests: XCTestCase {
    let cardRoot = "/Volumes/TESTCARD"
    let cardUUID = "CARD-UUID"

    // A baseline that PASSES; each test toggles exactly one precondition.
    private func baselineSession(states: [FileState] = [.nasVerified, .nasVerified]) -> SessionRecord {
        let files = states.enumerated().map { i, state in
            FileRecord(relPath: "DCIM/100TEST/IMG_\(i).RAF", size: 1000,
                       mtime: Date(timeIntervalSince1970: 1_700_000_000),
                       creationDate: nil, destRelPath: "2026/07/04/IMG_\(i).RAF", state: state)
        }
        return SessionRecord(cardVolumeUUID: cardUUID, cardVolumeName: "TESTCARD",
                             cardCapacityBytes: 1 << 30, files: files)
    }

    private func card(readOnly: Bool = false) -> WipeGate.CardMountSnapshot {
        WipeGate.CardMountSnapshot(volumeUUID: cardUUID, rootPath: cardRoot, isReadOnly: readOnly)
    }

    // stat closure: every manifest file present, regular, matching size+mtime;
    // every parent a plain directory.
    private func goodStat(_ session: SessionRecord) -> (String) -> WipeGate.LStatResult? {
        var map: [String: WipeGate.LStatResult] = [:]
        for file in session.files {
            map[cardRoot + "/" + file.relPath] = WipeGate.LStatResult(
                isRegularFile: true, isSymlink: false, isDirectory: false,
                size: file.size, mtime: file.mtime)
        }
        for dir in [cardRoot + "/DCIM", cardRoot + "/DCIM/100TEST"] {
            map[dir] = WipeGate.LStatResult(isRegularFile: false, isSymlink: false,
                                            isDirectory: true, size: 0, mtime: Date())
        }
        return { map[$0] }
    }

    func testBaselinePasses() {
        let s = baselineSession()
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertTrue(v.allowed, "\(v.blockers)")
        XCTAssertEqual(v.deletions.count, 2)
    }

    func testEmptyManifestBlocks() {
        let s = baselineSession(states: [])
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains(.emptyManifest))
    }

    func testNonTerminalFileBlocks() {
        for state: FileState in [.pending, .copying, .staged, .stagedVerified, .uploading, .uploaded] {
            let s = baselineSession(states: [.nasVerified, state])
            let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                      nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
            XCTAssertFalse(v.allowed, "\(state) must block under afterNASVerify")
            XCTAssertTrue(v.deletions.isEmpty, "no deletions when blocked")
        }
    }

    func testFailedFileBlocks() {
        let s = baselineSession(states: [.nasVerified, .failed(.hashMismatch(stage: "NAS"))])
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains { if case .fileFailed = $0 { return true }; return false })
    }

    func testNASUnhealthyBlocksUnderNASPolicy() {
        let s = baselineSession()
        for health: NASHealth in [.notMounted, .ghostLocalFolder(fstype: "apfs"), .wrongShare(mntFrom: "//x/y"), .readOnly] {
            let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                      nasHealth: health, statOf: goodStat(s), journalFlushed: true)
            XCTAssertFalse(v.allowed, "\(health) must block")
        }
    }

    func testStagingPolicyToleratesUnhealthyNASAndStagedVerified() {
        // afterStagingVerify: staged copy is the safety net, NAS not required.
        let s = baselineSession(states: [.stagedVerified, .stagedVerified])
        let v = WipeGate.evaluate(session: s, policy: .afterStagingVerify, cardMount: card(),
                                  nasHealth: .notMounted, statOf: goodStat(s), journalFlushed: true)
        XCTAssertTrue(v.allowed, "\(v.blockers)")
    }

    func testCardNotMountedBlocks() {
        let s = baselineSession()
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: nil,
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains(.cardNotMounted))
    }

    func testWrongCardBlocks() {
        let s = baselineSession()
        let wrong = WipeGate.CardMountSnapshot(volumeUUID: "OTHER", rootPath: cardRoot, isReadOnly: false)
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: wrong,
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains(.cardUUIDMismatch))
    }

    func testReadOnlyCardBlocks() {
        let s = baselineSession()
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(readOnly: true),
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains(.cardReadOnly))
    }

    func testSizeMismatchBlocks() {
        let s = baselineSession()
        var stat = goodStat(s)
        let target = cardRoot + "/" + s.files[0].relPath
        let base = stat
        stat = { path in
            if path == target {
                return WipeGate.LStatResult(isRegularFile: true, isSymlink: false, isDirectory: false,
                                            size: 999, mtime: s.files[0].mtime)   // wrong size
            }
            return base(path)
        }
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: stat, journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains { if case .statMismatch = $0 { return true }; return false })
    }

    func testMtimeDriftBeyondToleranceBlocks() {
        let s = baselineSession()
        let base = goodStat(s)
        let target = cardRoot + "/" + s.files[0].relPath
        let stat: (String) -> WipeGate.LStatResult? = { path in
            if path == target {
                return WipeGate.LStatResult(isRegularFile: true, isSymlink: false, isDirectory: false,
                                            size: s.files[0].size, mtime: s.files[0].mtime.addingTimeInterval(10))
            }
            return base(path)
        }
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: stat, journalFlushed: true)
        XCTAssertFalse(v.allowed)
    }

    func testMtimeWithinTolerancePasses() {
        let s = baselineSession()
        let base = goodStat(s)
        let stat: (String) -> WipeGate.LStatResult? = { path in
            if let r = base(path), r.isRegularFile {
                return WipeGate.LStatResult(isRegularFile: true, isSymlink: false, isDirectory: false,
                                            size: r.size, mtime: r.mtime.addingTimeInterval(1.5)) // exFAT ±2 s
            }
            return base(path)
        }
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: stat, journalFlushed: true)
        XCTAssertTrue(v.allowed, "\(v.blockers)")
    }

    func testSymlinkBlocks() {
        let s = baselineSession()
        let base = goodStat(s)
        let target = cardRoot + "/" + s.files[0].relPath
        let stat: (String) -> WipeGate.LStatResult? = { path in
            if path == target {
                return WipeGate.LStatResult(isRegularFile: false, isSymlink: true, isDirectory: false,
                                            size: s.files[0].size, mtime: s.files[0].mtime)
            }
            return base(path)
        }
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: stat, journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains { if case .symlinkOrIrregular = $0 { return true }; return false })
    }

    func testSymlinkedParentBlocks() {
        let s = baselineSession()
        let base = goodStat(s)
        let stat: (String) -> WipeGate.LStatResult? = { path in
            if path == self.cardRoot + "/DCIM/100TEST" {
                return WipeGate.LStatResult(isRegularFile: false, isSymlink: true, isDirectory: true,
                                            size: 0, mtime: Date())
            }
            return base(path)
        }
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: stat, journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains { if case .parentNotPlainDirectory = $0 { return true }; return false })
    }

    func testPathEscapeBlocks() {
        var s = baselineSession(states: [.nasVerified])
        s.files[0] = FileRecord(relPath: "../../etc/passwd", size: 1000, mtime: s.files[0].mtime,
                                creationDate: nil, destRelPath: "x", state: .nasVerified)
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: { _ in
            WipeGate.LStatResult(isRegularFile: true, isSymlink: false, isDirectory: false, size: 1000, mtime: s.files[0].mtime)
        }, journalFlushed: true)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains { if case .pathEscapesCard = $0 { return true }; return false })
    }

    func testUnflushedJournalBlocks() {
        let s = baselineSession()
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: false)
        XCTAssertFalse(v.allowed)
        XCTAssertTrue(v.blockers.contains(.journalNotFlushed))
    }

    func testAbsentVerifiedFileIsAlreadyAbsentNotBlocker() {
        // Camera deleted a file between inserts; its data is safe on the NAS.
        let s = baselineSession()
        let base = goodStat(s)
        let target = cardRoot + "/" + s.files[1].relPath
        let stat: (String) -> WipeGate.LStatResult? = { path in
            path == target ? nil : base(path)
        }
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: stat, journalFlushed: true)
        XCTAssertTrue(v.allowed, "\(v.blockers)")
        XCTAssertEqual(v.deletions.count, 1)
        XCTAssertEqual(v.alreadyAbsent.count, 1)
    }

    func testSkippedDuplicateIsWipeEligible() {
        let s = baselineSession(states: [.nasVerified, .skippedDuplicate])
        let v = WipeGate.evaluate(session: s, policy: .afterNASVerify, cardMount: card(),
                                  nasHealth: .healthy, statOf: goodStat(s), journalFlushed: true)
        XCTAssertTrue(v.allowed, "\(v.blockers)")
        XCTAssertEqual(v.deletions.count, 2)
    }
}
