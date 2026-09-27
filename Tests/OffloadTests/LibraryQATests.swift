import XCTest
import AppKit
@testable import OffloadApp
import OffloadCore
import OffloadEngine

final class LibraryQATests: XCTestCase {
    private var root: URL!
    private var oldDemo: String?
    private var oldRoot: String?

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        oldDemo = ProcessInfo.processInfo.environment["OFFLOAD_DEMO"]
        oldRoot = ProcessInfo.processInfo.environment["OFFLOAD_DEMO_DATA_ROOT"]
        setenv("OFFLOAD_DEMO", "1", 1)
        setenv("OFFLOAD_DEMO_DATA_ROOT", root.appendingPathComponent("state").path, 1)
    }

    override func tearDownWithError() throws {
        if let oldDemo { setenv("OFFLOAD_DEMO", oldDemo, 1) } else { unsetenv("OFFLOAD_DEMO") }
        if let oldRoot { setenv("OFFLOAD_DEMO_DATA_ROOT", oldRoot, 1) } else { unsetenv("OFFLOAD_DEMO_DATA_ROOT") }
        try FileManager.default.removeItem(at: root)
    }

    func testCountDistinguishesEmptyMissingAndCancelled() throws {
        let browser = LibraryBrowser()
        XCTAssertTrue(browser.countMedia(root: root) { _, _ in })
        XCTAssertFalse(browser.countMedia(root: root.appendingPathComponent("missing")) { _, _ in })
        XCTAssertFalse(browser.countMedia(root: root, isCancelled: { true }) { _, _ in
            XCTFail("Cancelled counts must not publish a completed zero")
        })
        XCTAssertThrowsError(try browser.browseChecked(root.appendingPathComponent("missing")))
    }

    func testCountIncludesNestedMediaButNotHiddenOrNonMedia() throws {
        let nested = root.appendingPathComponent("2026/09/26")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["one.JPG", "two.RAF", "clip.MOV", "notes.txt", ".hidden.JPG"] {
            try Data(repeating: 1, count: 100).write(to: nested.appendingPathComponent(name))
        }
        let result = LibraryCountAccumulator()
        XCTAssertTrue(LibraryBrowser().countMedia(root: root) { result.update($0, $1) })
        XCTAssertEqual(result.snapshot().0, 3)
        XCTAssertEqual(result.snapshot().1, 300)
        XCTAssertTrue(LibraryBrowser().sampleMedia(under: root, isCancelled: { true }).isEmpty)
        XCTAssertTrue(LibraryBrowser().sampleMedia(under: root, limit: 0).isEmpty)
    }

    func testBackgroundCancellationReachesWorker() async {
        let started = expectation(description: "worker started")
        let worker = Task {
            await BackgroundWork.run {
                started.fulfill()
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
                return Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 2)
        worker.cancel()
        let cancelled = await worker.value
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testViewerCacheEvictsByDecodedBytes() throws {
        let cache = FullImageCache(byteLimit: 80_000)
        func image() throws -> NSImage {
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 400, bitsPerPixel: 32))
            let image = NSImage(size: NSSize(width: 100, height: 100))
            image.addRepresentation(rep)
            return image
        }
        let date = Date()
        for i in 0..<3 {
            cache.put(url: root.appendingPathComponent("\(i).jpg"), mtime: date, image: try image())
        }
        XCTAssertEqual(cache.residentBytes, 80_000)
        XCTAssertNil(cache.get(url: root.appendingPathComponent("0.jpg"), mtime: date))
        XCTAssertNotNil(cache.get(url: root.appendingPathComponent("2.jpg"), mtime: date))
        cache.clear()
        XCTAssertEqual(cache.residentBytes, 0)
    }

    @MainActor
    func testUnavailableLibraryDoesNotPersistAnEmptyCount() async throws {
        let missing = root.appendingPathComponent("offline")
        let model = LibraryModel(nasRootPath: missing.path, cardRootPath: nil)
        model.openPinned(missing.path)
        for _ in 0..<200 {
            if !model.loading && model.countUnavailable { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.countUnavailable)
        XCTAssertFalse(model.countComplete)
        XCTAssertNil(LibraryIndex.load(rootPath: missing.path))
    }

    @MainActor
    func testOfflineFavoritesStaySaved() async throws {
        let missing = root.appendingPathComponent("offline/photo.JPG").path
        try JSONIO.save([missing], to: Paths.favoritesFile)
        let model = LibraryModel(nasRootPath: root.path, cardRootPath: nil)
        model.loadFavorites()
        for _ in 0..<200 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.favoriteItems.isEmpty)
        XCTAssertEqual(model.favoritePaths, [missing])
        XCTAssertEqual(try JSONIO.load([String].self, from: Paths.favoritesFile), [missing])
    }

    @MainActor
    func testSlowFolderCannotReplaceNewerNavigationAndRatingResorts() async throws {
        let started = expectation(description: "slow browse started")
        let slow = root.appendingPathComponent("slow")
        let fast = root.appendingPathComponent("fast")
        for dir in [slow, fast] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let model = LibraryModel(nasRootPath: root.path, cardRootPath: nil, browseDirectory: { url in
            if url.path == slow.path { started.fulfill(); Thread.sleep(forTimeInterval: 0.15) }
            return .success(["a.JPG", "b.JPG"].map {
                LibraryEntry(id: url.appendingPathComponent($0).path, name: $0, kind: .media(.photo), size: 100, modified: Date())
            })
        })
        model.openPinned(slow.path)
        await fulfillment(of: [started], timeout: 2)
        model.openPinned(fast.path)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.currentDir?.path, fast.path)
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(model.entries.allSatisfy { $0.id.hasPrefix(fast.path + "/") })
        model.sortOrder = .ratingDesc
        let b = try XCTUnwrap(model.photoItems.first { $0.primary.name == "b.JPG" })
        model.setRating(5, for: b)
        XCTAssertEqual(model.photoItems.first?.id, b.id)
        // Allow the local persistence tasks to finish before removing the fixture.
        try await Task.sleep(for: .milliseconds(50))
    }
}
