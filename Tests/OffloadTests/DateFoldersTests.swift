import XCTest
@testable import OffloadCore

final class DateFoldersTests: XCTestCase {
    func testRelComponents() {
        XCTAssertEqual(DateFolders.relComponents("/Volumes/Photos/2026/07/04", root: "/Volumes/Photos"),
                       ["2026", "07", "04"])
        XCTAssertEqual(DateFolders.relComponents("/Volumes/Photos/2026", root: "/Volumes/Photos/"), ["2026"])
        XCTAssertEqual(DateFolders.relComponents("/Volumes/Photos", root: "/Volumes/Photos"), [])
        XCTAssertEqual(DateFolders.relComponents("/somewhere/else", root: "/Volumes/Photos"), [])
    }

    func testCaptionDay() {
        // 2026/07/04 is a Saturday.
        let c = DateFolders.caption(folderPath: "/V/2026/07/04", rootPath: "/V", rawName: "04")
        XCTAssertEqual(c.subtitle, "Saturday")
        XCTAssertTrue(c.title.contains("4"))          // "Jul 4" (or locale variant)
    }

    func testCaptionYearAndMonth() {
        XCTAssertEqual(DateFolders.caption(folderPath: "/V/2026", rootPath: "/V", rawName: "2026").title, "2026")
        let m = DateFolders.caption(folderPath: "/V/2026/07", rootPath: "/V", rawName: "07")
        XCTAssertEqual(m.subtitle, "2026")
        XCTAssertTrue(m.title.localizedCaseInsensitiveContains("jul"))
    }

    func testHeaderLabelDay() {
        let s = DateFolders.headerLabel(folderPath: "/V/2026/07/04", rootPath: "/V")
        XCTAssertNotNil(s)
        XCTAssertTrue(s!.contains("Saturday"))
        XCTAssertTrue(s!.contains("July"))
        XCTAssertTrue(s!.contains("2026"))
        XCTAssertTrue(s!.contains("4"))
    }

    func testHeaderLabelMonthAndYear() {
        XCTAssertEqual(DateFolders.headerLabel(folderPath: "/V/2026", rootPath: "/V"), "2026")
        let m = DateFolders.headerLabel(folderPath: "/V/2026/07", rootPath: "/V")
        XCTAssertTrue(m!.contains("July"))
        XCTAssertTrue(m!.contains("2026"))
    }

    func testNonDateFolderFallsBack() {
        XCTAssertEqual(
            DateFolders.caption(folderPath: "/card/DCIM/100FUJI", rootPath: "/card/DCIM", rawName: "100FUJI").title,
            "100FUJI")
        XCTAssertNil(DateFolders.headerLabel(folderPath: "/card/DCIM/100FUJI", rootPath: "/card/DCIM"))
        // Garbage numeric-ish but out of range.
        XCTAssertNil(DateFolders.headerLabel(folderPath: "/V/2026/13/40", rootPath: "/V"))
    }
}
