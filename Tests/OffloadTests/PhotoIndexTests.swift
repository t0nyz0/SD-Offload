import XCTest
@testable import OffloadCore

final class PhotoIndexTests: XCTestCase {
    var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-index-\(UUID().uuidString).json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: file) }

    private func rec(_ path: String, labels: [String], animals: [String] = [], mtime: Date = Date()) -> PhotoRecord {
        PhotoRecord(path: path, size: 1000, mtime: mtime,
                    labels: labels.map { PhotoLabel(name: $0, confidence: 0.9) }, animals: animals)
    }

    func testSearchMatchesLabelsAndAnimals() async {
        let index = PhotoIndex(file: file)
        await index.put(rec("/nas/2026/07/04/a.jpg", labels: ["grass", "outdoor"], animals: ["Dog"]))
        await index.put(rec("/nas/2026/07/04/b.jpg", labels: ["food", "plate"]))
        await index.put(rec("/nas/2026/07/05/c.jpg", labels: ["beach", "ocean"], animals: ["Dog"]))

        let dogs = await index.search("dog")
        XCTAssertEqual(dogs, ["/nas/2026/07/04/a.jpg", "/nas/2026/07/05/c.jpg"])
        let food = await index.search("food")
        XCTAssertEqual(food, ["/nas/2026/07/04/b.jpg"])
        let beachDog = await index.search("dog beach")   // multi-term = AND
        XCTAssertEqual(beachDog, ["/nas/2026/07/05/c.jpg"])
        let byName = await index.search("a.jpg")          // filename searchable too
        XCTAssertEqual(byName, ["/nas/2026/07/04/a.jpg"])
        let empty = await index.search("   ")             // empty matches nothing
        XCTAssertTrue(empty.isEmpty)
    }

    func testSearchScopedByPrefix() async {
        let index = PhotoIndex(file: file)
        await index.put(rec("/nas/2026/a.jpg", labels: ["dog"]))
        await index.put(rec("/card/DCIM/b.jpg", labels: ["dog"]))
        let onlyNAS = await index.search("dog", underPrefix: "/nas")
        XCTAssertEqual(onlyNAS, ["/nas/2026/a.jpg"])
    }

    func testTopTagsRanked() async {
        let index = PhotoIndex(file: file)
        for i in 0..<5 { await index.put(rec("/nas/d\(i).jpg", labels: ["dog"], animals: ["Dog"])) }
        for i in 0..<2 { await index.put(rec("/nas/f\(i).jpg", labels: ["flower"])) }
        let tags = await index.topTags(underPrefix: "/nas")
        XCTAssertEqual(tags.first?.tag, "dog")
        XCTAssertEqual(tags.first?.count, 5)
        XCTAssertTrue(tags.contains { $0.tag == "flower" && $0.count == 2 })
    }

    func testNeedsAnalysisOnNewAndChanged() async {
        let index = PhotoIndex(file: file)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let isNew = await index.needsAnalysis(path: "/x.jpg", mtime: t)
        XCTAssertTrue(isNew)
        await index.put(rec("/x.jpg", labels: ["dog"], mtime: t))
        let same = await index.needsAnalysis(path: "/x.jpg", mtime: t)
        XCTAssertFalse(same)
        let within = await index.needsAnalysis(path: "/x.jpg", mtime: t.addingTimeInterval(1))
        XCTAssertFalse(within)
        let changed = await index.needsAnalysis(path: "/x.jpg", mtime: t.addingTimeInterval(60))
        XCTAssertTrue(changed)
    }

    func testPrefixMatchIsBoundaryAware() async {
        let index = PhotoIndex(file: file)
        await index.put(rec("/nas/Photos/a.jpg", labels: ["dog"]))
        await index.put(rec("/nas/PhotosBackup/b.jpg", labels: ["dog"]))   // sibling with shared name prefix
        let scoped = await index.search("dog", underPrefix: "/nas/Photos")
        XCTAssertEqual(scoped, ["/nas/Photos/a.jpg"], "must not leak into /nas/PhotosBackup")
        let count = await index.analyzedCount(underPrefix: "/nas/Photos")
        XCTAssertEqual(count, 1)
    }

    func testPruneMissingDropsVanishedFiles() async {
        let index = PhotoIndex(file: file)
        await index.put(rec("/nas/a.jpg", labels: ["dog"]))
        await index.put(rec("/nas/b.jpg", labels: ["cat"]))
        await index.put(rec("/other/c.jpg", labels: ["dog"]))
        await index.pruneMissing(underPrefix: "/nas", keeping: ["/nas/a.jpg"])   // b.jpg vanished
        let dogs = await index.search("dog")
        XCTAssertEqual(dogs, ["/nas/a.jpg", "/other/c.jpg"])   // b gone, /other untouched
        let b = await index.record("/nas/b.jpg")
        XCTAssertNil(b)
        let c = await index.record("/other/c.jpg")
        XCTAssertNotNil(c)
    }

    func testPersistenceRoundtrip() async {
        let a = PhotoIndex(file: file)
        await a.put(rec("/nas/a.jpg", labels: ["dog", "grass"], animals: ["Dog"]))
        await a.save()
        let b = PhotoIndex(file: file)     // reload from disk
        let found = await b.search("dog")
        XCTAssertEqual(found, ["/nas/a.jpg"])
        let label = await b.record("/nas/a.jpg")?.labels.first?.name
        XCTAssertEqual(label, "dog")
    }
}
