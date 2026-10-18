import XCTest
import OffloadCore
@testable import OffloadEngine

final class LibraryTrashTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("offload-trash-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func makeFile(_ path: String, bytes: Data = Data("original photo bytes".utf8)) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func fallback(_ files: Set<URL>, archive: URL? = nil) -> LibraryTrash.Result {
        LibraryTrash.perform(files, archiveRoot: archive ?? root) { _ in throw CocoaError(.featureUnsupported) }
    }

    private func batches() throws -> [URL] {
        try fm.contentsOfDirectory(at: LibraryTrash.folder(under: root), includingPropertiesForKeys: nil)
    }

    func testSupportedNativeTrashNeedsNoRecoveryFolder() throws {
        let file = try makeFile("2026/10/18/photo.JPG")
        let fakeTrash = root.appendingPathComponent(".native-trash-photo.JPG")
        let result = LibraryTrash.perform([file], archiveRoot: root) { try fm.moveItem(at: $0, to: fakeTrash) }
        XCTAssertEqual(result.removed, [file])
        XCTAssertTrue(result.recovered.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.recoveryFolder)
        XCTAssertFalse(fm.fileExists(atPath: LibraryTrash.folder(under: root).path))
        XCTAssertEqual(try Data(contentsOf: fakeTrash), Data("original photo bytes".utf8))
    }

    func testUnsupportedTrashPreservesPairsSidecarsAndPathsForManualRecovery() throws {
        let names = ["2026/10/18/Photo #1 é.JPG", "2026/10/18/Photo #1 é.RAF", "2026/10/18/Photo #1 é.XMP"]
        let bytes = Data(repeating: 0xBA, count: 16_385)
        let files = try Set(names.map { try makeFile($0, bytes: bytes) })
        let result = fallback(files)
        XCTAssertEqual(result.removed, files)
        XCTAssertEqual(result.recovered, files)
        XCTAssertTrue(result.failures.isEmpty)
        let batch = try XCTUnwrap(try batches().first)
        XCTAssertTrue(fm.fileExists(atPath: batch.appendingPathComponent("Restore Instructions.txt").path))
        XCTAssertTrue(try LibraryBrowser().allMediaChecked(root: root).isEmpty,
                      "Deleted photos must not reappear in Library search/count/analysis inventories")
        for relative in names {
            let saved = batch.appendingPathComponent(relative)
            let original = root.appendingPathComponent(relative)
            XCTAssertEqual(try Data(contentsOf: saved), bytes)
            XCTAssertFalse(fm.fileExists(atPath: original.path))
            // The documented Finder move-back flow restores exact original bytes.
            try fm.moveItem(at: saved, to: original)
            XCTAssertEqual(try Data(contentsOf: original), bytes)
        }
    }

    func testRecoveryFailurePreservesOriginalAndReportsBothErrors() throws {
        let file = try makeFile("2026/10/18/photo.JPG")
        try Data("existing file, never overwrite".utf8).write(to: LibraryTrash.folder(under: root))
        let result = fallback([file])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failures.map(\.url), [file])
        XCTAssertTrue(result.failures[0].detail.contains("NSCocoaErrorDomain 3328"))
        XCTAssertTrue(result.failures[0].detail.contains("NSPOSIXErrorDomain"))
        XCTAssertEqual(try Data(contentsOf: file), Data("original photo bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: LibraryTrash.folder(under: root)), Data("existing file, never overwrite".utf8))
    }

    func testOutsidePathsSymlinksFoldersAndRecoveryFilesAreRejectedBeforeNativeTrash() throws {
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: false)
        let outside = try makeFile("outside.JPG")
        let link = archive.appendingPathComponent("link.JPG")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let recovered = try makeFile("archive/.offload-trash/batch/keep.JPG")
        let inputs: Set<URL> = [outside, link, archive, recovered]
        var nativeCalls = 0
        let result = LibraryTrash.perform(inputs, archiveRoot: archive) { _ in nativeCalls += 1 }
        XCTAssertEqual(nativeCalls, 0)
        XCTAssertEqual(Set(result.failures.map(\.url)), inputs)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertTrue(fm.fileExists(atPath: recovered.path))
    }

    func testArchiveAliasCanRecoverFilesUnderCanonicalRoot() throws {
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let file = try makeFile("archive/2026/10/18/photo.JPG")
        let alias = root.appendingPathComponent("archive-link", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: archive)
        let aliasedFile = alias.appendingPathComponent("2026/10/18/photo.JPG")
        let result = fallback([aliasedFile], archive: alias)
        XCTAssertEqual(result.removed, [aliasedFile])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertEqual(result.recoveryFolder, LibraryTrash.folder(under: archive))
    }

    func testRepeatedNamesNeverReplaceEarlierRecoverableFiles() throws {
        let first = try makeFile("2026/10/18/photo.JPG", bytes: Data("first".utf8))
        XCTAssertEqual(fallback([first]).recovered, [first])
        let second = try makeFile("2026/10/18/photo.JPG", bytes: Data("second".utf8))
        XCTAssertEqual(fallback([second]).recovered, [second])
        let contents = try Set(batches().map { try Data(contentsOf: $0.appendingPathComponent("2026/10/18/photo.JPG")) })
        XCTAssertEqual(contents, [Data("first".utf8), Data("second".utf8)])
    }

    func testPartialFailureReportsOnlyMovedFilesAndCachesUnsupportedVolume() throws {
        let files = try Set([makeFile("a.JPG"), makeFile("b.RAF")])
        let missing = root.appendingPathComponent("missing.JPG")
        var nativeCalls = 0
        let result = LibraryTrash.perform(files.union([missing]), archiveRoot: root) { _ in
            nativeCalls += 1
            throw CocoaError(.featureUnsupported)
        }
        XCTAssertEqual(nativeCalls, 1, "A bulk delete should not re-probe missing macOS Trash for every photo")
        XCTAssertEqual(result.removed, files)
        XCTAssertEqual(result.recovered, files)
        XCTAssertEqual(result.failures.map(\.url), [missing])
        XCTAssertTrue(result.failures[0].detail.contains("NSPOSIXErrorDomain 2"))
    }

    func testSymlinkedRecoveryDirectoryCannotMoveFilesOutsideArchive() throws {
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let file = try makeFile("archive/photo.JPG")
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: LibraryTrash.folder(under: archive), withDestinationURL: outside)
        let result = fallback([file], archive: archive)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.failures.map(\.url), [file])
        XCTAssertTrue(fm.fileExists(atPath: file.path))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testOptInLiveSMBTrashAndRecoveryUsesOnlyDisposableFiles() async throws {
        guard let path = ProcessInfo.processInfo.environment["OFFLOAD_TRASH_TEST_ROOT"] else {
            throw XCTSkip("Set OFFLOAD_TRASH_TEST_ROOT for a disposable real-SMB compatibility check")
        }
        XCTAssertEqual(statfsInfo(path: path)?.fsTypeName, "smbfs")
        let archive = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(".offload-trash-probe-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: archive) }
        let bytes = Data(repeating: 0xCA, count: 65_537)
        let files = try Set(["JPG", "RAF", "XMP"].map { ext -> URL in
            let file = archive.appendingPathComponent("2026/10/18/disposable." + ext)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            return file
        })
        let result = await LibraryTrash.move(files, archiveRoot: archive)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures.map(\.detail))")
        XCTAssertEqual(result.removed, files)
        XCTAssertEqual(result.recovered, files)
        let batches = try fm.contentsOfDirectory(at: LibraryTrash.folder(under: archive), includingPropertiesForKeys: nil)
        let batch = try XCTUnwrap(batches.first)
        for file in files {
            let saved = batch.appendingPathComponent("2026/10/18/" + file.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: saved), bytes)
            try fm.moveItem(at: saved, to: file)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        print("LIVE SMB TRASH PASS: JPEG, RAW, sidecar recovered and restored byte-for-byte; only disposable fixtures touched")
    }
}
