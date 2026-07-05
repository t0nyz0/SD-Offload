import XCTest
@testable import OffloadCore

final class FaceIndexTests: XCTestCase {
    var idFile: URL!
    var faceFile: URL!

    override func setUp() {
        idFile = FileManager.default.temporaryDirectory.appendingPathComponent("id-\(UUID()).json")
        faceFile = FileManager.default.temporaryDirectory.appendingPathComponent("face-\(UUID()).json")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: idFile)
        try? FileManager.default.removeItem(at: faceFile)
    }

    // A unit vector pointing mostly along axis `i`, with a little noise on `j`.
    private func vec(_ i: Int, dim: Int = 8, noise: Float = 0, at j: Int = 0) -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        v[i] = 1
        if noise != 0 { v[j] += noise }
        return FaceMath.normalized(v)
    }

    // MARK: - FaceMath

    func testCosineDistanceAndIncomparable() {
        XCTAssertEqual(FaceMath.cosineDistance(vec(0), vec(0))!, 0, accuracy: 1e-5)   // identical
        XCTAssertEqual(FaceMath.cosineDistance(vec(0), vec(3))!, 1, accuracy: 1e-5)   // orthogonal
        XCTAssertNil(FaceMath.cosineDistance([1, 0], [1, 0, 0]))                      // different dim
    }

    // MARK: - IdentityIndex

    func testSuggestMatchesNearestWithinThreshold() async {
        let idx = IdentityIndex(file: idFile)
        let elizabeth = await idx.create(name: "Elizabeth", kind: .person, embedderID: "vfp1", exemplar: vec(0))
        _ = await idx.create(name: "James", kind: .person, embedderID: "vfp1", exemplar: vec(3))

        let near = await idx.suggest(for: vec(0, noise: 0.15, at: 1), embedderID: "vfp1", kind: .person)
        XCTAssertEqual(near?.id, elizabeth.id)

        let far = await idx.suggest(for: vec(6), embedderID: "vfp1", kind: .person)
        XCTAssertNil(far)
    }

    func testSuggestNeverCrossesEmbedderOrKind() async {
        let idx = IdentityIndex(file: idFile)
        _ = await idx.create(name: "Elizabeth", kind: .person, embedderID: "vfp1", exemplar: vec(0))
        _ = await idx.create(name: "Hurley", kind: .pet, embedderID: "vfp1", exemplar: vec(0))

        let otherEmbedder = await idx.suggest(for: vec(0), embedderID: "arcface2", kind: .person)
        XCTAssertNil(otherEmbedder)   // different embedder ⇒ incomparable, never matches

        let personMatch = await idx.suggest(for: vec(0), embedderID: "vfp1", kind: .person)
        let matchedName = await idx.identity(personMatch!.id)?.name
        XCTAssertEqual(matchedName, "Elizabeth")   // the person, not the identically-placed pet
    }

    func testSuggestExcludesRejected() async {
        let idx = IdentityIndex(file: idFile)
        let e = await idx.create(name: "Elizabeth", kind: .person, embedderID: "vfp1", exemplar: vec(0))
        let near = vec(0, noise: 0.1, at: 2)
        let first = await idx.suggest(for: near, embedderID: "vfp1", kind: .person)
        XCTAssertEqual(first?.id, e.id)
        let excluded = await idx.suggest(for: near, embedderID: "vfp1", kind: .person, excluding: [e.id])
        XCTAssertNil(excluded)
    }

    func testConfirmLearnsAndRoundTrips() async {
        let idx = IdentityIndex(file: idFile)
        let e = await idx.create(name: "Elizabeth", kind: .person, embedderID: "vfp1", exemplar: vec(0))
        await idx.addExemplar(vec(1), to: e.id, embedderID: "vfp1")     // learns a 2nd exemplar
        await idx.addExemplar(vec(0), to: e.id, embedderID: "wrong")    // wrong embedder ignored
        let storedCount = await idx.identity(e.id)?.exemplars.count
        XCTAssertEqual(storedCount, 2)
        await idx.save()

        let reloaded = IdentityIndex(file: idFile)
        let names = await reloaded.all().map(\.name)
        XCTAssertEqual(names, ["Elizabeth"])
        let reloadedCount = await reloaded.identity(e.id)?.exemplars.count
        XCTAssertEqual(reloadedCount, 2)
    }

    // MARK: - FaceIndex

    private func det(_ vec: [Float], kind: Detection.Kind = .face) -> Detection {
        Detection(kind: kind, bbox: NormRect(x: 0, y: 0, w: 0.2, h: 0.2),
                  embedding: vec, embedderID: "vfp1", quality: 0.8)
    }

    func testScanBookkeepingAndAssignmentQueries() async {
        let fi = FaceIndex(file: faceFile)
        let needsBefore = await fi.needsScan(path: "/nas/a.jpg")
        XCTAssertTrue(needsBefore)

        let d = det(vec(0))
        await fi.setDetections([d], for: "/nas/a.jpg")
        await fi.setDetections([], for: "/nas/b.jpg")            // scanned, no faces
        let needsA = await fi.needsScan(path: "/nas/a.jpg")
        let needsB = await fi.needsScan(path: "/nas/b.jpg")
        XCTAssertFalse(needsA)
        XCTAssertFalse(needsB)                                   // empty result still counts as scanned

        var unnamed = await fi.unassigned(kind: .face)
        XCTAssertEqual(unnamed.count, 1)
        let personID = UUID()
        await fi.assign(detection: d.id, in: "/nas/a.jpg", to: personID)
        unnamed = await fi.unassigned(kind: .face)
        XCTAssertTrue(unnamed.isEmpty)

        let photos = await fi.photos(withIdentity: personID)
        XCTAssertEqual(photos, ["/nas/a.jpg"])
        let counts = await fi.counts()
        XCTAssertEqual(counts.named, 1)
        XCTAssertEqual(counts.unnamed, 0)
    }

    func testRejectRemembersAndClearsSuggestion() async {
        let fi = FaceIndex(file: faceFile)
        let d = det(vec(0))
        await fi.setDetections([d], for: "/nas/a.jpg")
        let wrongID = UUID()
        await fi.setSuggestion(detection: d.id, in: "/nas/a.jpg", to: wrongID)
        await fi.reject(detection: d.id, in: "/nas/a.jpg", identity: wrongID)
        let dets = await fi.detections(for: "/nas/a.jpg")
        XCTAssertEqual(dets.first?.rejectedIDs, [wrongID])
        XCTAssertNil(dets.first?.suggestedID)   // cleared
    }

    func testPruneAndPersistence() async {
        let fi = FaceIndex(file: faceFile)
        await fi.setDetections([det(vec(0))], for: "/nas/a.jpg")
        await fi.setDetections([det(vec(1))], for: "/nas/gone.jpg")
        await fi.pruneMissing(underPrefix: "/nas", keeping: ["/nas/a.jpg"])
        let goneNeedsScan = await fi.needsScan(path: "/nas/gone.jpg")
        XCTAssertTrue(goneNeedsScan)   // pruned
        await fi.save()

        let reloaded = FaceIndex(file: faceFile)
        let aScanned = await reloaded.needsScan(path: "/nas/a.jpg")
        let goneScanned = await reloaded.needsScan(path: "/nas/gone.jpg")
        XCTAssertFalse(aScanned)
        XCTAssertTrue(goneScanned)
    }
}
