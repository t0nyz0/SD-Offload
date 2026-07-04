import XCTest
@testable import OffloadCore

final class StateMachineTests: XCTestCase {
    func testHappyPathIsLegal() {
        let path: [FileState] = [.pending, .copying, .staged, .stagedVerified,
                                 .uploading, .uploaded, .nasVerified, .wiped]
        for i in 0..<(path.count - 1) {
            XCTAssertTrue(FileState.isLegal(from: path[i], to: path[i + 1]),
                          "\(path[i]) → \(path[i + 1]) must be legal")
        }
    }

    func testDuplicateSkipPath() {
        XCTAssertTrue(FileState.isLegal(from: .copying, to: .skippedDuplicate))
        XCTAssertTrue(FileState.isLegal(from: .skippedDuplicate, to: .wiped))
    }

    func testRetryRollbacks() {
        XCTAssertTrue(FileState.isLegal(from: .copying, to: .pending))
        XCTAssertTrue(FileState.isLegal(from: .staged, to: .pending))
        XCTAssertTrue(FileState.isLegal(from: .uploading, to: .stagedVerified))
        XCTAssertTrue(FileState.isLegal(from: .uploaded, to: .stagedVerified))
        XCTAssertTrue(FileState.isLegal(from: .uploaded, to: .pending))
    }

    func testAnyNonTerminalMayFail() {
        for state: FileState in [.pending, .copying, .staged, .stagedVerified, .uploading, .uploaded] {
            XCTAssertTrue(FileState.isLegal(from: state, to: .failed(.cancelled)))
        }
    }

    func testTerminalStatesCannotFail() {
        for state: FileState in [.nasVerified, .skippedDuplicate, .wiped, .failed(.sourceMissing)] {
            XCTAssertFalse(FileState.isLegal(from: state, to: .failed(.cancelled)))
        }
    }

    func testIllegalJumps() {
        XCTAssertFalse(FileState.isLegal(from: .pending, to: .staged))
        XCTAssertFalse(FileState.isLegal(from: .pending, to: .nasVerified))
        XCTAssertFalse(FileState.isLegal(from: .pending, to: .wiped))
        XCTAssertFalse(FileState.isLegal(from: .copying, to: .nasVerified))
        XCTAssertFalse(FileState.isLegal(from: .staged, to: .uploading))       // must verify first
        XCTAssertFalse(FileState.isLegal(from: .uploading, to: .nasVerified))  // must land first
        XCTAssertFalse(FileState.isLegal(from: .failed(.sourceMissing), to: .wiped)) // NEVER
        XCTAssertFalse(FileState.isLegal(from: .wiped, to: .pending))
    }

    func testCrashRemap() {
        XCTAssertEqual(FileState.crashRemap(.copying), .pending)
        XCTAssertEqual(FileState.crashRemap(.uploading), .stagedVerified)
        // Verification states re-verify in place; everything else is sticky.
        for state: FileState in [.pending, .staged, .stagedVerified, .uploaded,
                                 .nasVerified, .skippedDuplicate, .wiped, .failed(.cancelled)] {
            XCTAssertEqual(FileState.crashRemap(state), state)
        }
    }

    func testWipeEligibility() {
        XCTAssertTrue(FileState.nasVerified.isWipeEligible)
        XCTAssertTrue(FileState.skippedDuplicate.isWipeEligible)
        for state: FileState in [.pending, .copying, .staged, .stagedVerified,
                                 .uploading, .uploaded, .failed(.cancelled)] {
            XCTAssertFalse(state.isWipeEligible, "\(state) must not be wipe-eligible")
        }
    }
}
