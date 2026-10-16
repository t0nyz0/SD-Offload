import XCTest
@testable import OffloadEngine

final class CardProbeStateTests: XCTestCase {
    func testDetectionIsAnnouncedBeforeProbeCompletionAndOncePerInsertion() throws {
        var state = CardProbeState()
        let identity = CardProbeState.Identity(uuid: "card", path: "/Volumes/Card", mountID: "mount")
        let first = state.begin(device: "disk4", identity: identity, now: 0)
        XCTAssertTrue(first.detected)
        XCTAssertNotNil(first.probe)
        XCTAssertFalse(state.begin(device: "disk4", identity: identity, now: 1).detected)
        let probe = try XCTUnwrap(first.probe)
        XCTAssertFalse(state.complete(device: "disk4", probe: probe, ready: false))
        XCTAssertFalse(state.begin(device: "disk4", identity: identity, now: 2).detected)
        _ = state.remove(path: identity.path)
        XCTAssertTrue(state.begin(device: "disk4", identity: identity, now: 3).detected)
    }

    func testFastWorkspaceUnmountAndReusedMediaIdentityInvalidateOldProbes() throws {
        var state = CardProbeState()
        let mount = try XCTUnwrap(CardMountSnapshot(source: "/dev/disk4", path: "/Volumes/Card", mountID: "same-fsid",
                                                   capacityBytes: 1_000, freeBytes: 500))
        let old = try XCTUnwrap(state.begin(device: "disk4", identity: mount.probeIdentity(uuid: "same-card", mediaID: 10)).probe)
        XCTAssertTrue(state.complete(device: "disk4", probe: old, ready: true))
        let removed = state.remove(path: mount.path)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed.first?.uuid, "same-card")
        let reinserted = try XCTUnwrap(state.begin(device: "disk4", identity: old.identity).probe)
        XCTAssertFalse(state.complete(device: "disk4", probe: old, ready: true))
        XCTAssertTrue(state.complete(device: "disk4", probe: reinserted, ready: true))
        let replaced = state.begin(device: "disk4", identity: mount.probeIdentity(uuid: "same-card", mediaID: 11))
        XCTAssertEqual(replaced.removed, "same-card")
        XCTAssertTrue(replaced.detected)
        XCTAssertNotNil(replaced.probe)
        XCTAssertEqual(mount, CardMountSnapshot(source: "/dev/disk4", path: mount.path, mountID: "same-fsid",
                                               capacityBytes: 1_000, freeBytes: 400), "Free-space changes are not a reinsertion")
    }
    let identity = CardProbeState.Identity(uuid: "card", path: "/Volumes/Card", mountID: "1")

    func testSlowProbeDoesNotLaunchDuplicateWork() {
        var state = CardProbeState()
        XCTAssertNotNil(state.begin(device: "disk4", identity: identity).probe)
        XCTAssertNil(state.begin(device: "disk4", identity: identity).probe)
    }

    func testEarlyUnreadableCardRemainsRetryable() throws {
        var state = CardProbeState()
        let first = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        XCTAssertFalse(state.complete(device: "disk4", probe: first, ready: false))
        let retry = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        XCTAssertTrue(state.complete(device: "disk4", probe: retry, ready: true))
        XCTAssertNil(state.begin(device: "disk4", identity: identity).probe)
    }

    func testLateProbeCannotResurrectRemovedCard() throws {
        var state = CardProbeState()
        let probe = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        _ = state.remove(device: "disk4")
        XCTAssertFalse(state.complete(device: "disk4", probe: probe, ready: true))
    }

    func testSameCardReinsertedRejectsOldProbe() throws {
        var state = CardProbeState()
        let old = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        _ = state.remove(device: "disk4")
        let current = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        XCTAssertFalse(state.complete(device: "disk4", probe: old, ready: true))
        XCTAssertTrue(state.complete(device: "disk4", probe: current, ready: true))
    }

    func testMountIdentityChangeReportsRemovalBeforeNewInsertion() throws {
        var state = CardProbeState()
        let first = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        XCTAssertTrue(state.complete(device: "disk4", probe: first, ready: true))
        let next = state.begin(device: "disk4", identity: .init(uuid: "card", path: identity.path, mountID: "2"))
        XCTAssertEqual(next.removed, "card")
        XCTAssertNotNil(next.probe)
    }

    func testManualRefreshInvalidatesPendingResult() throws {
        var state = CardProbeState()
        let first = try XCTUnwrap(state.begin(device: "disk4", identity: identity).probe)
        state.reset()
        XCTAssertFalse(state.complete(device: "disk4", probe: first, ready: true))
        XCTAssertNotNil(state.begin(device: "disk4", identity: identity).probe)
    }

    func testHungProbeRetriesOnceWithoutSpawningUnboundedWork() throws {
        var state = CardProbeState()
        let first = try XCTUnwrap(state.begin(device: "disk4", identity: identity, now: 0).probe)
        XCTAssertNil(state.begin(device: "disk4", identity: identity, now: 29).probe)
        let replacement = try XCTUnwrap(state.begin(device: "disk4", identity: identity, now: 30).probe)
        for time in [60.0, 3600, 86400] {
            XCTAssertNil(state.begin(device: "disk4", identity: identity, now: time).probe)
        }
        XCTAssertFalse(state.complete(device: "disk4", probe: first, ready: true))
        XCTAssertTrue(state.complete(device: "disk4", probe: replacement, ready: true))
        XCTAssertNil(state.begin(device: "disk4", identity: identity, now: 86401).probe)
    }

    func testHungCardDoesNotBlockAnotherReader() throws {
        var state = CardProbeState()
        _ = state.begin(device: "disk4", identity: identity, now: 0)
        let other = try XCTUnwrap(state.begin(device: "disk5", identity: identity, now: 100).probe)
        XCTAssertTrue(state.complete(device: "disk5", probe: other, ready: true))
    }

    func testKernelMountSnapshotRejectsNetworkAndDistinguishesRemounts() throws {
        XCTAssertNil(CardMountSnapshot(source: "//server/Photos", path: "/Volumes/Photos", mountID: "1"))
        let first = try XCTUnwrap(CardMountSnapshot(source: "/dev/disk4s1", path: "/Volumes/Card", mountID: "1"))
        XCTAssertEqual(first.device, "disk4s1")
        XCTAssertNotEqual(first, CardMountSnapshot(source: "/dev/disk4s1", path: first.path, mountID: "2"))
        XCTAssertNotEqual(first, CardMountSnapshot(source: "/dev/disk4s1", path: "/Volumes/Card 1", mountID: "1"))
    }
}
