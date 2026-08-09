import XCTest
@testable import OffloadCore
@testable import OffloadEngine

final class LibraryMigrationTests: XCTestCase {
    private struct Fixture {
        let root: URL, support: URL, nas: URL, secondary: URL
        let oldPrimary: URL, oldSecondary: URL
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID())", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let nas = root.appendingPathComponent("nas", isDirectory: true)
        let secondary = root.appendingPathComponent("secondary", isDirectory: true)
        let oldPrimary = nas.appendingPathComponent("2026/07/04", isDirectory: true)
        let oldSecondary = secondary.appendingPathComponent("2026/07/04", isDirectory: true)
        for dir in [support, support.appendingPathComponent("Journal"), support.appendingPathComponent("History"),
                    oldPrimary, oldSecondary] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dir in [oldPrimary, oldSecondary] {
            try Data("photo".utf8).write(to: dir.appendingPathComponent("IMG_0001.JPG"))
            try Data("sidecar".utf8).write(to: dir.appendingPathComponent("IMG_0001.XMP"))
        }
        var config = AppConfig(); config.nasRootPath = nas.path; config.secondaryDestPath = secondary.path
        config.testAllowLocalNAS = true; config.dateFolderLayout = .nestedNumeric
        config.recognizedDateFolderLayouts = [.nestedNumeric]
        try JSONIO.saveDurable(config, to: support.appendingPathComponent("config.json"))
        return Fixture(root: root, support: support, nas: nas, secondary: secondary,
                       oldPrimary: oldPrimary, oldSecondary: oldSecondary)
    }

    func testMigrationMovesBothDestinationsAndRemapsMetadata() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let oldPhoto = f.oldPrimary.appendingPathComponent("IMG_0001.JPG").path
        let oldFolder = f.oldPrimary.path
        try JSONIO.saveDurable([oldPhoto], to: f.support.appendingPathComponent("favorites.json"))
        try JSONIO.saveDurable([oldFolder], to: f.support.appendingPathComponent("pinned-folders.json"))
        try JSONIO.saveDurable(CullData(ratings: [oldPhoto: 5], flags: [oldPhoto: .pick]),
                                   to: f.support.appendingPathComponent("cull.json"))
        let photoIndex = PhotoIndex(file: f.support.appendingPathComponent("photo-index.json"))
        await photoIndex.put(PhotoRecord(path: oldPhoto, size: 5, mtime: Date(), labels: [], animals: []))
        await photoIndex.save()
        let faceIndex = FaceIndex(file: f.support.appendingPathComponent("face-index.json"))
        await faceIndex.setDetections([], for: oldPhoto); await faceIndex.save()
        let identities = IdentityIndex(file: f.support.appendingPathComponent("identity-index.json"))
        _ = await identities.create(name: "Person", kind: .person, embedderID: "test",
                                    exemplar: [1, 0], coverPath: oldPhoto)
        await identities.save()

        var history = SessionRecord(cardVolumeUUID: "card", cardVolumeName: "Card", cardCapacityBytes: 100)
        history.files = [FileRecord(relPath: "DCIM/IMG_0001.JPG", size: 5, mtime: Date(), creationDate: nil,
                                    captureDate: nil, destRelPath: "2026/07/04/IMG_0001.JPG", state: .nasVerified)]
        try JSONIO.saveDurable(history, to: f.support.appendingPathComponent("History/session.json"))

        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        let plan = try await migrator.makePlan(config: config, target: .flatISO)
        XCTAssertEqual(plan.moves.count, 2); XCTAssertEqual(plan.collisionCount, 0)
        XCTAssertEqual(plan.ignoredFolderCount, 0)
        try await migrator.start(plan)

        let newPhoto = f.nas.appendingPathComponent("2026-07-04/IMG_0001.JPG").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPhoto))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.secondary.appendingPathComponent("2026-07-04/IMG_0001.JPG").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPhoto))
        XCTAssertEqual(JSONIO.loadGuarded([String].self, from: f.support.appendingPathComponent("favorites.json")), [newPhoto])
        XCTAssertEqual(JSONIO.loadGuarded(CullData.self, from: f.support.appendingPathComponent("cull.json"))?.ratings[newPhoto], 5)
        let migratedPhoto = await PhotoIndex(file: f.support.appendingPathComponent("photo-index.json")).record(newPhoto)
        let migratedFaces = await FaceIndex(file: f.support.appendingPathComponent("face-index.json")).detections(for: newPhoto)
        let migratedIdentities = await IdentityIndex(file: f.support.appendingPathComponent("identity-index.json")).all()
        XCTAssertNotNil(migratedPhoto)
        XCTAssertEqual(migratedFaces, [])
        XCTAssertEqual(migratedIdentities.first?.coverPath, newPhoto)
        XCTAssertEqual(JSONIO.loadGuarded(SessionRecord.self, from: f.support.appendingPathComponent("History/session.json"))?.files.first?.destRelPath,
                       "2026-07-04/IMG_0001.JPG")
        XCTAssertEqual(JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))?.dateFolderLayout, .flatISO)
        let completedState = await migrator.pendingState()
        XCTAssertEqual(completedState?.status, .completed)
    }

    func testCompletedMigrationCanRollBackExactly() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        let plan = try await migrator.makePlan(config: config, target: .yearISODay)
        try await migrator.start(plan)

        // Simulate a process stopping after the final rename but before its
        // journal update. Rollback must inspect the filesystem, not trust the
        // stale recorded location.
        let stateFile = f.support.appendingPathComponent("library-migration.json")
        var stale = try XCTUnwrap(JSONIO.loadGuarded(LibraryMigrationState.self, from: stateFile))
        stale.status = .failed
        for index in stale.moves.indices {
            stale.moves[index].primary = .original
            stale.moves[index].secondary = .original
        }
        try JSONIO.saveDurable(stale, to: stateFile)
        try await migrator.rollback()
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.oldPrimary.appendingPathComponent("IMG_0001.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.oldSecondary.appendingPathComponent("IMG_0001.XMP").path))
        XCTAssertEqual(JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))?.dateFolderLayout,
                       .nestedNumeric)
        let rolledBackState = await migrator.pendingState()
        XCTAssertEqual(rolledBackState?.status, .rolledBack)
    }

    func testResumeReconcilesRenameThatBeatJournalWrite() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        let plan = try await migrator.makePlan(config: config, target: .flatISO)
        try await migrator.start(plan)

        let stateFile = f.support.appendingPathComponent("library-migration.json")
        var stale = try XCTUnwrap(JSONIO.loadGuarded(LibraryMigrationState.self, from: stateFile))
        stale.status = .moving
        stale.completedMoves = 0
        for index in stale.moves.indices {
            stale.moves[index].primary = .staged
            stale.moves[index].secondary = .staged
        }
        try JSONIO.saveDurable(stale, to: stateFile)

        try await migrator.resume()
        let resumed = await migrator.pendingState()
        XCTAssertEqual(resumed?.status, .completed)
        XCTAssertEqual(resumed?.completedMoves, plan.moves.count)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: f.nas.appendingPathComponent("2026-07-04/IMG_0001.JPG").path))
    }

    func testExistingTargetNeverOverwritten() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let target = f.nas.appendingPathComponent("2026-07-04", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: target.appendingPathComponent("IMG_0001.JPG"))
        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        let plan = try await migrator.makePlan(config: config, target: .flatISO)
        XCTAssertTrue(plan.moves.contains { $0.newRelativePath == "2026-07-04/IMG_0001 (2).JPG" })
        try await migrator.start(plan)
        XCTAssertEqual(String(data: try Data(contentsOf: target.appendingPathComponent("IMG_0001.JPG")), encoding: .utf8), "existing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("IMG_0001 (2).JPG").path))
    }

    func testIncompleteSessionBlocksPlanning() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("{}".utf8).write(to: f.support.appendingPathComponent("Journal/session.json"))
        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        do {
            _ = try await migrator.makePlan(config: config, target: .flatISO)
            XCTFail("Expected incomplete session to block")
        } catch LibraryMigrationError.incompleteSession { }
    }

    func testSecondarySizeMismatchBlocksPlanning() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("different-size".utf8).write(to: f.oldSecondary.appendingPathComponent("IMG_0001.JPG"))
        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        do {
            _ = try await migrator.makePlan(config: config, target: .flatISO)
            XCTFail("Expected a mismatched second destination to block")
        } catch LibraryMigrationError.secondaryMismatch { }
    }

    func testFileAppearingAfterPreflightIsLeftUntouched() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let migrator = LibraryMigrator(supportRoot: f.support)
        let config = JSONIO.loadGuarded(AppConfig.self, from: f.support.appendingPathComponent("config.json"))!
        let plan = try await migrator.makePlan(config: config, target: .flatISO)

        // A separate process adds a file after the read-only plan. It was never
        // authorized by that plan, so cleanup must retain the old folder and file.
        for folder in [f.oldPrimary, f.oldSecondary] {
            try Data("late arrival".utf8).write(to: folder.appendingPathComponent("LATE.TXT"))
        }
        try await migrator.start(plan)

        XCTAssertEqual(try Data(contentsOf: f.oldPrimary.appendingPathComponent("LATE.TXT")),
                       Data("late arrival".utf8))
        XCTAssertEqual(try Data(contentsOf: f.oldSecondary.appendingPathComponent("LATE.TXT")),
                       Data("late arrival".utf8))
    }
}
