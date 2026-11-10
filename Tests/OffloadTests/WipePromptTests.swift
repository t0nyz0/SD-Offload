import XCTest
import SwiftUI
import AppKit
@testable import OffloadApp
import OffloadCore
import OffloadEngine

final class WipePromptTests: XCTestCase {
    private var root: URL!
    private var oldEnvironment: [String: String] = [:]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("offload-wipe-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for key in ["OFFLOAD_DEMO", "OFFLOAD_DEMO_DATA_ROOT"] {
            oldEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        setenv("OFFLOAD_DEMO", "1", 1)
        setenv("OFFLOAD_DEMO_DATA_ROOT", root.path, 1)
    }

    override func tearDownWithError() throws {
        for key in ["OFFLOAD_DEMO", "OFFLOAD_DEMO_DATA_ROOT"] {
            if let value = oldEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
        }
        try FileManager.default.removeItem(at: root)
    }

    private final class Engine: EngineControlling {
        let events: AsyncStream<EngineEvent>
        let continuation: AsyncStream<EngineEvent>.Continuation
        var resumed: [UUID] = []
        var requested: [UUID] = []
        init() {
            let stream = AsyncStream<EngineEvent>.makeStream()
            events = stream.stream; continuation = stream.continuation
        }
        func start() {}
        func consentToIngest(cardUUID: String) {}
        func declineIngest(cardUUID: String) {}
        func pause() {}
        func resume() {}
        func cancel() {}
        func confirmWipe() {}
        func cancelWipe() {}
        func requestWipeNow(sessionID: UUID) { requested.append(sessionID) }
        func confirmWipeNow(sessionID: UUID) {}
        func resumeWipeCountdown(sessionID: UUID) { resumed.append(sessionID) }
        func eject() {}
        func retry() {}
        func retryWipe(sessionID: UUID) {}
        func refreshNASGlance() {}
        func rescan() {}
    }

    private var card: CardInfo {
        CardInfo(volumeUUID: "fixture", bsdName: "not-a-device", mountPath: root.path,
                 volumeName: "SD Card", capacityBytes: 128 << 30, freeBytes: 64 << 30, hasMediaRoot: true)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected UI event was not received")
    }

    @MainActor
    func testClosingBeforeConfirmationEventResumesUnseenPrompt() async throws {
        // Each app owns only an injected mock, never the real card watcher.
        let engine = Engine(), id = UUID(), state = AppState(engine: engine)
        engine.continuation.yield(.sessionStarted(sessionID: id, card: card, resumed: false))
        engine.continuation.yield(.phase(.wipeCountdown))
        try await waitUntil { state.session?.phase == .wipeCountdown }
        state.popoverVisible = true
        state.requestWipeNowTapped(sessionID: id)
        state.popoverVisible = false
        XCTAssertEqual(engine.requested, [id])
        XCTAssertEqual(engine.resumed, [id])
        engine.continuation.yield(.phase(.awaitingWipeNowConfirmation))
        try await waitUntil { engine.resumed.count == 2 }
        XCTAssertEqual(engine.resumed, [id, id])
        engine.continuation.finish()
    }

    @MainActor
    func testClosingAfterCardRemovalStillResumesPendingCountdown() async throws {
        let engine = Engine(), id = UUID(), state = AppState(engine: engine)
        engine.continuation.yield(.sessionStarted(sessionID: id, card: card, resumed: false))
        try await waitUntil { state.session?.sessionID == id }
        state.popoverVisible = true
        engine.continuation.yield(.phase(.awaitingWipeNowConfirmation))
        engine.continuation.yield(.phase(.pausedCardGone))
        try await waitUntil { state.session?.phase == .pausedCardGone }
        state.popoverVisible = false
        XCTAssertEqual(engine.resumed, [id])
        engine.continuation.finish()
    }

    @MainActor
    func testWipePromptsRenderOffscreenAtPopoverWidth() throws {
        let engine = Engine(), app = AppState(engine: engine)
        let vm = SessionViewModel(sessionID: UUID(), card: card, resumed: false)
        vm.plannedFiles = 412; vm.wipeCountdown = 4
        for phase in [EnginePhase.wipeCountdown, .awaitingWipeNowConfirmation, .awaitingWipeConsent] {
            vm.phase = phase
            let renderer = ImageRenderer(content: WipePromptView(vm: vm).environment(app)
                .frame(width: 360).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, 720)
            XCTAssertGreaterThan(image.height, 100)
            XCTAssertLessThan(image.height, 700)
            if let output = ProcessInfo.processInfo.environment["OFFLOAD_UI_SNAPSHOT_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(phase.rawValue).png"))
            }
        }
        engine.continuation.finish()
    }
}
