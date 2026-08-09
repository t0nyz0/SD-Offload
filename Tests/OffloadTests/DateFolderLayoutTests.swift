import XCTest
@testable import OffloadCore

final class DateFolderLayoutTests: XCTestCase {
    private var sample: Date {
        var dc = DateComponents(); dc.year = 2026; dc.month = 7; dc.day = 4
        return Calendar.current.date(from: dc)!
    }

    func testEveryPresetRoundTripsDay() {
        for layout in DateFolderLayout.presets {
            XCTAssertNil(layout.validationError, layout.name)
            let path = layout.folderPath(for: sample)
            let parsed = layout.parse(folderPath: path)
            XCTAssertEqual(parsed?.precision, .day, "\(layout.name): \(path)")
            let c = parsed.map { Calendar.current.dateComponents([.year, .month, .day], from: $0.date) }
            XCTAssertEqual(c?.year, 2026); XCTAssertEqual(c?.month, 7); XCTAssertEqual(c?.day, 4)
        }
    }

    func testNamedMonthUsesStableEnglishAndParses() {
        XCTAssertEqual(DateFolderLayout.namedMonth.folderPath(for: sample), "2026/07 - July/04")
        XCTAssertEqual(DateFolderLayout.namedMonth.parse(folderPath: "2026/07 - July/04")?.precision, .day)
    }

    func testPrefixParsingDrivesIntermediateCaptions() {
        XCTAssertEqual(DateFolderLayout.nestedNumeric.parse(folderPath: "2026")?.precision, .year)
        XCTAssertEqual(DateFolderLayout.nestedNumeric.parse(folderPath: "2026/07")?.precision, .month)
        XCTAssertEqual(DateFolderLayout.nestedNumeric.parse(folderPath: "2026/07/04")?.precision, .day)
    }

    func testCustomPatternAndRouter() {
        let layout = DateFolderLayout(id: "custom", name: "Custom", pattern: "Photos {YYYY}/{MMM}-{DD}")
        XCTAssertNil(layout.validationError)
        XCTAssertEqual(layout.destinationRelPath(fileName: "A.RAF", captureDate: sample),
                       "Photos 2026/Jul-04/A.RAF")
        XCTAssertNotNil(layout.parse(folderPath: "Photos 2026/Jul-04"))
        XCTAssertEqual(DateFolderRouter(layout: layout).destinationRelPath(fileName: "A.RAF", captureDate: sample),
                       "Photos 2026/Jul-04/A.RAF")
    }

    func testRejectsUnsafeOrIrreversiblePatterns() {
        let invalid = ["", "/{YYYY}/{MM}/{DD}", "{YYYY}/../{MM}/{DD}",
                       "{YYYY}/{MM}", "{YYYY}/{XX}/{DD}", ".hidden/{YYYY}-{MM}-{DD}"]
        for pattern in invalid {
            XCTAssertNotNil(DateFolderLayout(id: "x", name: "x", pattern: pattern).validationError, pattern)
        }
    }

    func testInvalidCalendarDateDoesNotParse() {
        XCTAssertNil(DateFolderLayout.nestedNumeric.parse(folderPath: "2026/02/29"))
        XCTAssertNotNil(DateFolderLayout.nestedNumeric.parse(folderPath: "2024/02/29"))
    }

    func testConfigDecodingDefaultsAndRejectsAnUnsafeSavedLayout() throws {
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.dateFolderLayout, .nestedNumeric)
        XCTAssertEqual(legacy.recognizedDateFolderLayouts, [.nestedNumeric])

        let unsafe = #"{"dateFolderLayout":{"id":"custom","name":"Custom","pattern":"{YYYY}/../{MM}/{DD}"},"recognizedDateFolderLayouts":[]}"#
        let recovered = try JSONDecoder().decode(AppConfig.self, from: Data(unsafe.utf8))
        XCTAssertEqual(recovered.dateFolderLayout, .nestedNumeric)
        XCTAssertEqual(recovered.recognizedDateFolderLayouts, [.nestedNumeric])
    }
}
