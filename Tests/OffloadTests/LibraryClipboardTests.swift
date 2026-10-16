import XCTest
import AppKit
import OffloadCore
@testable import OffloadApp

final class LibraryClipboardTests: XCTestCase {
    private func entry(_ path: String, kind: MediaKind = .photo) -> LibraryEntry {
        LibraryEntry(id: path, name: (path as NSString).lastPathComponent,
                     kind: .media(kind), size: 7, modified: .distantPast)
    }

    func testSelectionCopiesVisiblePhotosInDisplayOrder() {
        let first = DisplayItem(group: [entry("/Volumes/Photos/first.JPG")])
        let second = DisplayItem(group: [entry("/Volumes/Photos/second.JPG")])
        let folder = DisplayItem(folder: LibraryEntry(id: "/Volumes/Photos/folder", name: "folder",
                                                      kind: .folder, size: 0, modified: .distantPast))
        let visible = [folder, second, first]
        let selected: Set<String> = [first.id, second.id, folder.id, "/filtered-out.JPG"]
        XCTAssertEqual(LibraryClipboard.items(in: visible, selection: selected).map(\.id),
                       [second.id, first.id])
        XCTAssertTrue(LibraryClipboard.items(in: visible, selection: []).isEmpty)
    }

    func testRightClickUsesMultipleSelectionOnlyWhenClickedPhotoIsSelected() {
        let photos = (1...3).map { DisplayItem(group: [entry("/Volumes/Photos/\($0).JPG")]) }
        let selection: Set<String> = [photos[0].id, photos[1].id]
        XCTAssertEqual(LibraryClipboard.items(in: photos, selection: selection, clicked: photos[1]).map(\.id),
                       [photos[0].id, photos[1].id])
        XCTAssertEqual(LibraryClipboard.items(in: photos, selection: selection, clicked: photos[2]).map(\.id),
                       [photos[2].id])
        XCTAssertEqual(LibraryClipboard.items(in: photos, selection: [], clicked: photos[2]).map(\.id),
                       [photos[2].id])
    }

    func testCopyUsesShownFileAndExplicitRAWOptionAddsCompanionsWithoutDuplicates() {
        let jpeg = entry("/Volumes/Photos/paired.JPG")
        let raw = entry("/Volumes/Photos/paired.RAF", kind: .raw)
        let rawOnly = entry("/Volumes/Photos/raw-only.NEF", kind: .raw)
        let video = entry("/Volumes/Photos/movie.MOV", kind: .video)
        let pair = DisplayItem(group: [raw, jpeg])
        let items = [pair, DisplayItem(group: [rawOnly]), DisplayItem(group: [video]), pair]
        XCTAssertEqual(LibraryClipboard.urls(for: items), [jpeg.url, rawOnly.url, video.url])
        XCTAssertEqual(LibraryClipboard.urls(for: items, includingRAW: true),
                       [jpeg.url, raw.url, rawOnly.url, video.url])
    }

    @MainActor
    func testNativeFileClipboardCanPasteOriginalBytesIntoAnotherFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("NAS stand-in")
        let destination = root.appendingPathComponent("Desktop stand-in")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["Photo #1 é.JPG", "Photo #1 é.RAF", "movie.MOV"]
        let originals = names.enumerated().map { Data(repeating: UInt8($0.offset + 1), count: 4_097) }
        for (name, bytes) in zip(names, originals) {
            try bytes.write(to: source.appendingPathComponent(name))
        }
        let entries = names.map { name in
            entry(source.appendingPathComponent(name).path,
                  kind: MediaKind.classify(ext: (name as NSString).pathExtension)!)
        }
        let items = LibraryModel.groupPhotos(entries)
        // A private pasteboard leaves the user's clipboard and windows untouched.
        let pasteboard = NSPasteboard(name: .init("OffloadClipboardTest-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(LibraryClipboard.copy(items, includingRAW: true, to: pasteboard))
        let written = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(written.count, 3)
        XCTAssertTrue(written.allSatisfy { $0.types.contains(.fileURL) })
        XCTAssertTrue(written.allSatisfy { !$0.types.contains(.tiff) })
        let pasted = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(pasted.map(\.lastPathComponent), names)
        for (url, bytes) in zip(pasted, originals) {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertEqual(try Data(contentsOf: url), bytes) // Copy never moves the original.
        }
    }

    @MainActor
    func testEmptyCopyPreservesExistingClipboard() {
        let pasteboard = NSPasteboard(name: .init("OffloadClipboardTest-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep existing clipboard", forType: .string)
        let changeCount = pasteboard.changeCount
        XCTAssertFalse(LibraryClipboard.copy([], to: pasteboard))
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Keep existing clipboard")
    }

    func testLargeSelectionNeedsNoMountedSourceOrFileReads() {
        // Deliberately nonexistent network paths: copying references cannot depend
        // on opening, probing, or downloading any of the originals.
        let photos = (0..<10_000).map {
            DisplayItem(group: [entry("/Volumes/Unavailable-NAS/\($0).JPG")])
        }
        let start = Date()
        let items = LibraryClipboard.items(in: photos, selection: Set(photos.map(\.id)))
        let urls = LibraryClipboard.urls(for: items)
        XCTAssertEqual(urls.count, 10_000)
        XCTAssertEqual(urls.first?.lastPathComponent, "0.JPG")
        XCTAssertEqual(urls.last?.lastPathComponent, "9999.JPG")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
