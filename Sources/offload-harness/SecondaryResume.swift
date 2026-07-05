import Foundation
import OffloadCore
import OffloadEngine

/// Regression proof for the second-copy resume gap: a session verifies every file
/// on the NAS but is interrupted BEFORE the wipe, with NO second destination
/// configured; the user THEN enables a second drive and resumes. The card must not
/// be wiped until each file has been backfilled and verified on the second drive.
///
/// This exercises SessionRunner.reconcileSecondaries (sourcing from the NAS, since
/// staging is purged post-verify) and the WipeGate.secondaryMissing precondition.
func runSecondaryResumeScenario(cardRoot: URL, nasRoot: URL, secondary: URL, staging: StagingStore,
                                journalDir: URL, historyDir: URL, config baseConfig: AppConfig,
                                cardInfo: CardInfo, sourceHashes: [String: String]) async throws {
    let fm = FileManager.default
    let planner = IngestPlanner()
    let scanned = planner.scan(cardRoot: cardRoot, scope: .mediaRootsOnly)
    let plan = await planner.plan(scanned: scanned)
    var files = plan.files
    guard !files.isEmpty else { fail("no files to seed for the secondary-resume scenario") }

    let sessionID = UUID()

    // Seed: every file already NAS-verified (byte-identical on the NAS) but NOT on
    // the second drive — as if a prior run verified them, was interrupted before
    // the wipe, and the user THEN enabled a second destination. Staging is left
    // purged (the realistic post-verify state), so reconcile must source from the NAS.
    for i in files.indices {
        let cardFile = cardRoot.appendingPathComponent(files[i].relPath)
        let hash = try Fixtures.sha256(cardFile)
        files[i].sourceHashHex = hash
        files[i].state = .nasVerified
        let dest = nasRoot.appendingPathComponent(files[i].destRelPath)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: cardFile, to: dest)
    }

    // The second drive must start EMPTY (this is the gap: files are safe on the NAS
    // only, and the config to require a second copy didn't exist when they verified).
    for entry in (try? fm.contentsOfDirectory(at: secondary, includingPropertiesForKeys: nil)) ?? [] {
        try? fm.removeItem(at: entry)
    }

    let token = UUID().uuidString
    try Data(token.utf8).write(to: cardRoot.appendingPathComponent(".offload-session"))

    var record = SessionRecord(id: sessionID, cardVolumeUUID: cardInfo.volumeUUID,
                               cardVolumeName: cardInfo.volumeName, cardCapacityBytes: cardInfo.capacityBytes,
                               cardSessionToken: token)
    record.nasMntFromName = baseConfig.nasExpectedMntFromName
    record.state = .transferring
    record.files = files
    record.stats.filesPlanned = files.count
    record.stats.bytesPlanned = files.reduce(0) { $0 + $1.size }

    let journal1 = Journal(directory: journalDir, historyDir: historyDir)
    try await journal1.begin(record)
    try await journal1.flushNow(sessionID)
    log("seeded \(files.count) NAS-verified files with NO second copy; enabling the second drive on resume")

    // The config change the user made after the fact: enable the second destination.
    var config = baseConfig
    config.secondaryDestPath = secondary.path
    let resumeConfig = config   // immutable snapshot for the Sendable provider closure

    // === RELAUNCH: fresh Journal + SessionRunner, exactly as the reopened app. ===
    let journal2 = Journal(directory: journalDir, historyDir: historyDir)
    guard await journal2.openIncompleteSession(cardUUID: cardInfo.volumeUUID) != nil else {
        fail("relaunch did not find the incomplete session")
    }
    let nas = NASLocator(configProvider: { resumeConfig })
    let watcher = CardWatcher()
    let runner = SessionRunner(sessionID: sessionID, card: cardInfo, config: resumeConfig, journal: journal2,
                               staging: staging, nas: nas, cardWatcher: watcher) { _ in }
    await runner.run()

    // === Assertions ===
    print("\n▸ Verifying second-copy resume")
    guard let finalRecord = await journal2.loadHistory(limit: 1).first else {
        fail("no completed session in history after resume")
    }
    guard finalRecord.state == .done else { fail("resumed session state \(finalRecord.state), expected done") }
    guard finalRecord.wipeReport?.ran == true else {
        fail("wipe did not run after the second copies were reconciled: \(String(describing: finalRecord.wipeReport))")
    }

    // Every file must now be on BOTH the NAS and the second drive, byte-identical…
    for file in finalRecord.files {
        for (label, root) in [("NAS", nasRoot), ("second drive", secondary)] {
            let dest = root.appendingPathComponent(file.destRelPath)
            guard fm.fileExists(atPath: dest.path) else { fail("missing on \(label) after resume: \(file.destRelPath)") }
            guard try Fixtures.sha256(dest) == sourceHashes[file.relPath] else {
                fail("\(label) hash mismatch after resume: \(file.destRelPath)")
            }
        }
    }
    log("all \(finalRecord.files.count) files verified byte-identical on BOTH the NAS and the second drive")

    // …and ONLY then was the card wiped.
    for rel in sourceHashes.keys where fm.fileExists(atPath: cardRoot.appendingPathComponent(rel).path) {
        fail("card file still present after resume+wipe: \(rel)")
    }
    log("card wiped only after the missing second copies were backfilled and verified")

    print("\n✅ PASS — resume backfilled the missing second copy before wiping. (secondary-resume)")
    exit(0)
}
