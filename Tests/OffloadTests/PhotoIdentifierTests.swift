import XCTest
@testable import OffloadEngine
import OffloadCore

final class PhotoIdentifierTests: XCTestCase {
    private var directory: URL!
    private var image: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/OffloadApp/Resources/icon-1024.png")
    }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func executable(_ body: String) throws -> String {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file.path
    }
    func testLiveProvidersWithAppIcon() async throws {
        guard ProcessInfo.processInfo.environment["OFFLOAD_LIVE_AI_TESTS"] == "1" else {
            throw XCTSkip("Opt-in test uses signed-in CLI accounts with the repository app icon only")
        }
        for provider in [AIProvider.cli, .codex] {
            let result = try await PhotoIdentifier(provider: provider, timeout: 90).identify(imageURL: image)
            XCTAssertFalse(result.description.isEmpty, provider.label)
            XCTAssertFalse(result.tags.isEmpty, provider.label)
            print("Live \(provider.label): valid description and \(result.tags.count) tags")
        }
    }
    func testProviderSettingsRemainBackwardCompatible() throws {
        for raw in ["cli", "api", "codex"] {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data("{\"aiProvider\":\"\(raw)\"}".utf8))
            XCTAssertEqual(config.aiProvider.rawValue, raw)
            let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(restored.aiProvider, config.aiProvider)
        }
    }
    func testClaudeRouting() async throws {
        let path = try executable("""
        [ "$1" = '-p' ] || exit 10
        [ "$3" = '--output-format' ] || exit 11
        [ -f preview.jpg ] || exit 12
        printf '%s' '{"description":"Claude fixture","tags":["test"]}'
        """)
        let result = try await PhotoIdentifier(provider: .cli, binaryPath: path).identify(imageURL: image)
        XCTAssertEqual(result.description, "Claude fixture")
    }
    func testCodexRoutingUsesFinalMessageAndImage() async throws {
        let path = try executable("""
        [ "$1" = 'exec' ] || exit 10
        [ -f preview.jpg ] || exit 11
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --image) shift; [ -f "$1" ] || exit 12 ;;
            --output-schema) shift; [ -f "$1" ] || exit 13 ;;
            --output-last-message) shift; output="$1" ;;
          esac
          shift
        done
        printf '%s' '{"description":"Codex fixture","tags":["test"]}' > "$output"
        printf 'unrelated CLI progress'
        """)
        let result = try await PhotoIdentifier(provider: .codex, model: "claude-api-model", binaryPath: path).identify(imageURL: image)
        XCTAssertEqual(result.description, "Codex fixture")
    }
    func testMissingExecutableNamesSelectedProvider() async throws {
        do {
            _ = try await PhotoIdentifier(provider: .codex, binaryPath: "/missing/offload-codex").identify(imageURL: image)
            XCTFail("Expected missing executable")
        } catch { XCTAssertTrue(error.localizedDescription.contains("codex")) }
    }
    func testNonzeroExitIsReported() async throws {
        let path = try executable("echo 'Authentication required: sign in' >&2; exit 1")
        do {
            _ = try await PhotoIdentifier(provider: .codex, binaryPath: path).identify(imageURL: image)
            XCTFail("Expected error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Authentication required")) }
    }
    func testMalformedAnswerIsRejected() async throws {
        let path = try executable("printf 'not JSON'")
        do {
            _ = try await PhotoIdentifier(binaryPath: path).identify(imageURL: image)
            XCTFail("Expected error")
        } catch { guard case PhotoIdentifier.IDError.unparseable = error else { return XCTFail("\(error)") } }
    }
    func testTimeoutKillsProcessThatIgnoresTermination() async throws {
        let path = try executable("trap '' TERM\nwhile :; do :; done")
        let start = Date()
        do {
            _ = try await PhotoIdentifier(binaryPath: path, timeout: 0.2).identify(imageURL: image)
            XCTFail("Expected timeout")
        } catch { guard case PhotoIdentifier.IDError.timedOut = error else { return XCTFail("\(error)") } }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testCancellationTerminatesAnalysis() async throws {
        let path = try executable("while :; do :; done")
        let task = Task { try await PhotoIdentifier(binaryPath: path).identify(imageURL: image) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
