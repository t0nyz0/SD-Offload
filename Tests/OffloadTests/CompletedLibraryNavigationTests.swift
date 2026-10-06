import XCTest
import OffloadCore
@testable import OffloadApp

final class CompletedLibraryNavigationTests: XCTestCase {
    private let nasRoot = "/fixture/nas"

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func file(_ folder: String, name: String = "photo.JPG", captured: Date? = nil,
                      state: FileState = .nasVerified) -> FileRecord {
        FileRecord(relPath: "DCIM/\(name)", size: 100, mtime: date(2030, 1, 1),
                   creationDate: date(2020, 1, 1), captureDate: captured,
                   destRelPath: "\(folder)/\(name)", state: state)
    }

    private func record(_ files: [FileRecord]) -> SessionRecord {
        SessionRecord(cardVolumeUUID: "fixture", cardVolumeName: "Card", cardCapacityBytes: 1000,
                      state: .done, files: files)
    }

    @MainActor
    func testNewestDayWinsEvenWhenOlderDayContainsMostPhotos() {
        let older = (0..<20).map { file("2026/09/29", name: "old-\($0).JPG", captured: date(2026, 9, 29)) }
        let newest = file("2026/10/06", captured: date(2026, 10, 6))
        XCTAssertEqual(AppState.uploadedFolder(from: record(older + [newest]), nasRoot: nasRoot),
                       nasRoot + "/2026/10/06")
    }

    @MainActor
    func testFileOrderAndEqualCountsCannotSelectOlderDayAcrossYearBoundary() {
        let files = [file("2025/12/31"), file("2026/01/01"), file("2025/01/02")]
        for ordered in [files, Array(files.reversed()), [files[1], files[2], files[0]]] {
            XCTAssertEqual(AppState.uploadedFolder(from: record(ordered), nasRoot: nasRoot),
                           nasRoot + "/2026/01/01")
        }
    }

    @MainActor
    func testCaptureDatesAndLegacyFoldersSupportEveryLayout() {
        let named = DateFolderLayout(id: "month-name", name: "Month name", pattern: "{MMMM}/{DD}/{YYYY}")
        for layout in DateFolderLayout.presets + [named] {
            // Folder dates must win over the camera's misleading filesystem dates.
            // September sorts after October alphabetically in the custom layout.
            let older = layout.folderPath(for: date(2026, 9, 29))
            let newest = layout.folderPath(for: date(2026, 10, 6))
            let session = record([file(older), file(newest, name: "photo (2).RAF")])
            XCTAssertEqual(AppState.uploadedFolder(from: session, nasRoot: nasRoot, layouts: [layout]),
                           nasRoot + "/" + newest, layout.pattern)
        }
        // A previously recognized numeric layout can parse a custom day/month
        // layout as a different day. The planner's saved capture date resolves it.
        let reversed = DateFolderLayout(id: "day-month", name: "Day / month", pattern: "{YYYY}/{DD}/{MM}")
        let olderDate = date(2026, 6, 10), newestDate = date(2026, 10, 6)
        let newestFolder = reversed.folderPath(for: newestDate)
        let session = record([file(reversed.folderPath(for: olderDate), captured: olderDate),
                              file(newestFolder, captured: newestDate)])
        XCTAssertEqual(AppState.uploadedFolder(from: session, nasRoot: nasRoot,
                                              layouts: [.nestedNumeric, reversed]),
                       nasRoot + "/" + newestFolder)
    }

    @MainActor
    func testOnlyVerifiedCopiesCountIncludingWipedAndDuplicateFiles() {
        let files = [file("2026/09/29"), file("2026/10/03", state: .wiped),
                     file("2026/10/06", state: .skippedDuplicate),
                     file("2026/10/07", state: .uploaded),
                     file("2026/10/08", state: .uploading),
                     file("2026/10/09", state: .failed(.sourceMissing))]
        XCTAssertEqual(AppState.uploadedFolder(from: record(files), nasRoot: nasRoot),
                       nasRoot + "/2026/10/06")
        let saved = file("saved-destination", name: "photo (2).JPG", captured: date(2026, 10, 9))
        XCTAssertEqual(AppState.uploadedFolder(from: record(files + [saved]), nasRoot: nasRoot),
                       nasRoot + "/saved-destination")
    }

    @MainActor
    func testEmptyOrUnverifiedBatchDoesNotRequestLibraryNavigation() {
        for files in [[], [file("2026/10/06", state: .pending)], [file(".", state: .nasVerified)]] {
            XCTAssertNil(AppState.uploadedFolder(from: record(files), nasRoot: nasRoot))
        }
    }
}
