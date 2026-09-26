import XCTest
@testable import OffloadEngine

final class CardProbeStateTests: XCTestCase {
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
}
