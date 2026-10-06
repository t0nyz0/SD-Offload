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
    func testTagSearchAndSuggestionsIncludeCanonicalAndLegacyRootPaths() async throws {
        let library = root.appendingPathComponent("photos").resolvingSymlinksInPath()
        let alias = root.appendingPathComponent("photos-link")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        let model = LibraryModel(nasRootPath: alias.path, cardRootPath: nil)
        model.openPinned(alias.path)
        let canonical = try XCTUnwrap(realpath(library.path, nil))
        let canonicalPath = String(cString: canonical)
        free(canonical)
        let paths = [canonicalPath + "/canonical.JPG",
                     alias.appendingPathComponent("legacy.JPG").path,
                     library.path + "Backup/outside.JPG"]
        for path in paths {
            let entry = LibraryEntry(id: path, name: (path as NSString).lastPathComponent,
                                     kind: .media(.photo), size: 7, modified: Date())
            _ = try await model.saveTags(["QA audit"], for: entry)
        }
        model.searchText = "qa audit"
        for _ in 0..<200 {
            if model.isSearching && model.suggestions.first?.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.isSearching)
        XCTAssertEqual(Set(model.displayedEntries.map(\.id)), Set(paths.prefix(2)))
        XCTAssertEqual(model.suggestions.map(\.tag), ["qa audit"])
        XCTAssertEqual(model.suggestions.map(\.count), [2])
    }

    @MainActor
    func testFaceSearchAndReviewIncludeRootAliasesWithoutCrossingLibraryBoundary() async throws {
        let library = root.appendingPathComponent("photos")
        let alias = root.appendingPathComponent("photos-link")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: library)
        let canonical = try XCTUnwrap(realpath(library.path, nil))
        let canonicalPath = String(cString: canonical)
        free(canonical)
        let model = LibraryModel(nasRootPath: alias.path, cardRootPath: nil)
        model.openPinned(alias.path)
        let person = await model.identityIndex.create(name: "Audit Person", kind: .person,
                                                      embedderID: "fixture", exemplar: [1, 0])
        let paths = [canonicalPath + "/named.JPG", alias.appendingPathComponent("unnamed.JPG").path,
                     canonicalPath + "Backup/outside.JPG"]
        for (i, path) in paths.enumerated() {
            await model.photoIndex.put(PhotoRecord(path: path, size: 7, mtime: Date(), labels: [], animals: []))
            let detection = Detection(kind: .face, bbox: NormRect(x: 0, y: 0, w: 0.2, h: 0.2),
                                      embedding: [1, 0], embedderID: "fixture", quality: 1,
                                      assignedID: i == 1 ? nil : person.id)
            await model.faceIndex.setDetections([detection], for: path)
        }
        await model.refreshFaceState()
        XCTAssertEqual(model.faceUnnamed, 1)
        model.reviewUnnamedFaces()
        for _ in 0..<200 {
            if model.displayedEntries.map(\.id) == [paths[1]] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.displayedEntries.map(\.id), [paths[1]])
        model.filterByIdentity(person.id)
        for _ in 0..<200 {
            if model.displayedEntries.map(\.id) == [paths[0]] { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.displayedEntries.map(\.id), [paths[0]])
        model.clearFaceFilter()
        model.searchText = "Audit Person"
        for _ in 0..<200 {
            if model.isSearching { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.displayedEntries.map(\.id), [paths[0]])
    }

    @MainActor
    func testCompletedBatchOpensNewestDayAndLoadsItsPhotos() async throws {
        let oldDay = root.appendingPathComponent("2026/09/29")
        let newDay = root.appendingPathComponent("2026/10/06")
        for dir in [oldDay, newDay] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("fixture".utf8).write(to: oldDay.appendingPathComponent("old.JPG"))
        try Data("fixture".utf8).write(to: newDay.appendingPathComponent("new.JPG"))
        let files = ["2026/09/29/old.JPG", "2026/09/29/other.JPG", "2026/10/06/new.JPG"].map {
            FileRecord(relPath: "DCIM/" + ($0 as NSString).lastPathComponent, size: 7, mtime: Date(),
                       creationDate: nil, destRelPath: $0, state: .nasVerified)
        }
        let session = SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "Card", cardCapacityBytes: 100,
                                    state: .done, files: files)
        let folder = try XCTUnwrap(AppState.uploadedFolder(from: session, nasRoot: root.path))
        let model = LibraryModel(nasRootPath: root.path, cardRootPath: nil)
        model.openPinned(oldDay.path)
        model.openPinned(folder) // Same navigation used by a new or already-open Library window.
        for _ in 0..<200 {
            if !model.loading { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.currentDir?.path, newDay.path)
        XCTAssertEqual(model.entries.map(\.name), ["new.JPG"])
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
