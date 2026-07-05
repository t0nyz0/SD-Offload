import XCTest
@testable import OffloadCore

final class JSONIOTests: XCTestCase {
    struct Doc: Codable, Equatable {
        var name: String
        var count: Int
    }

    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offload-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundtrip() throws {
        let url = dir.appendingPathComponent("doc.json")
        let doc = Doc(name: "hello", count: 42)
        try JSONIO.save(doc, to: url)
        XCTAssertEqual(try JSONIO.load(Doc.self, from: url), doc)
    }

    func testGuardedLoadRefreshesBackup() throws {
        let url = dir.appendingPathComponent("doc.json")
        try JSONIO.save(Doc(name: "a", count: 1), to: url)
        XCTAssertNotNil(JSONIO.loadGuarded(Doc.self, from: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    func testGuardedLoadRecoversFromBackupAndPreservesDamaged() throws {
        let url = dir.appendingPathComponent("doc.json")
        let good = Doc(name: "good", count: 7)
        try JSONIO.save(good, to: url)
        _ = JSONIO.loadGuarded(Doc.self, from: url)      // writes .bak
        try Data("{corrupt!!".utf8).write(to: url)        // corrupt the main file
        let recovered = JSONIO.loadGuarded(Doc.self, from: url)
        XCTAssertEqual(recovered, good)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("damaged").path))
    }

    func testPurgeRemovesMainAndAllSidecars() throws {
        // "Delete all face data" must leave NO biometric residue — the main file
        // and every sidecar (.bak, .damaged) it can produce.
        let url = dir.appendingPathComponent("faces.json")
        let bak = url.appendingPathExtension("bak")
        let damaged = url.appendingPathExtension("damaged")
        for u in [url, bak, damaged] { try Data("{}".utf8).write(to: u) }
        for u in [url, bak, damaged] { XCTAssertTrue(FileManager.default.fileExists(atPath: u.path)) }
        JSONIO.purge(url)
        for u in [url, bak, damaged] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: u.path), "leftover: \(u.lastPathComponent)")
        }
    }

    func testSaveDurableRoundtripAndNoTempLeftovers() throws {
        let url = dir.appendingPathComponent("durable.json")
        let doc = Doc(name: "durable", count: 9)
        try JSONIO.saveDurable(doc, to: url)
        XCTAssertEqual(try JSONIO.load(Doc.self, from: url), doc)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp-") }
        XCTAssertTrue(leftovers.isEmpty, "temp files left behind: \(leftovers)")
    }
}
