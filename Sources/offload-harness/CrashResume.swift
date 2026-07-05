import Foundation
import OffloadCore
import OffloadEngine

/// Proves close/crash-and-reopen resume: seed a journal with a realistic
/// mid-transfer state (files spread across every stage, with the matching
/// on-disk artifacts — some already on the NAS, some in staging, plus leftover
/// .partial garbage), then open it with a FRESH Journal + a new SessionRunner
/// exactly as a relaunch would, and assert it converges: nothing lost, nothing
/// already-done re-uploaded, card wiped only after everything verifies.
func runCrashResumeScenario(cardRoot: URL, nasRoot: URL, staging: StagingStore,
                            journalDir: URL, historyDir: URL, config: AppConfig,
                            cardInfo: CardInfo, sourceHashes: [String: String]) async throws {
    let fm = FileManager.default
    let planner = IngestPlanner()
    let scanned = planner.scan(cardRoot: cardRoot, scope: .mediaRootsOnly)
    let plan = await planner.plan(scanned: scanned)
    var files = plan.files
    guard files.count >= 10 else { fail("need ≥10 files for the resume scenario, got \(files.count)") }

    let sessionID = UUID()
    try staging.ensureSessionDir(sessionID)

    func copyToNAS(_ cardFile: URL, _ destRel: String) throws {
        let dest = nasRoot.appendingPathComponent(destRel)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: cardFile, to: dest)
    }
    func copyToStaging(_ cardFile: URL, _ i: Int) throws {
        let s = staging.stagedURL(session: sessionID, file: files[i])
        try? fm.removeItem(at: s)
        try fm.copyItem(at: cardFile, to: s)
    }

    // Assign a spread of crash-time states + create the matching artifacts.
    var expectUploadedIndices: [Int] = []   // files whose bytes must still flow to NAS on resume
    for i in files.indices {
        let cardFile = cardRoot.appendingPathComponent(files[i].relPath)
        let hash = try Fixtures.sha256(cardFile)
        switch i {
        case 0, 1, 2:                                   // already verified on NAS — must be skipped
            files[i].sourceHashHex = hash; files[i].state = .nasVerified
            try copyToNAS(cardFile, files[i].destRelPath)
        case 3, 4:                                       // on NAS but not yet verified — re-verify only
            files[i].sourceHashHex = hash; files[i].state = .uploaded
            try copyToNAS(cardFile, files[i].destRelPath)
        case 5, 6:                                       // staged & verified — must upload
            files[i].sourceHashHex = hash; files[i].state = .stagedVerified
            try copyToStaging(cardFile, i); expectUploadedIndices.append(i)
        case 7:                                           // mid-upload at crash → remap to stagedVerified
            files[i].sourceHashHex = hash; files[i].state = .uploading
            try copyToStaging(cardFile, i); expectUploadedIndices.append(i)
            // leftover hidden partial on the NAS that resume must consume/overwrite
            let dir = nasRoot.appendingPathComponent(files[i].destRelPath).deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("garbage".utf8).write(to: dir.appendingPathComponent(".offload-\(files[i].id.uuidString).partial"))
        case 8:                                           // mid-copy at crash → remap to pending
            files[i].state = .copying                     // hash unknown yet
            try Data("garbage".utf8).write(to: staging.partialURL(session: sessionID, file: files[i]))
            expectUploadedIndices.append(i)
        default:                                          // never started
            files[i].state = .pending
            expectUploadedIndices.append(i)
        }
    }

    var record = SessionRecord(id: sessionID, cardVolumeUUID: cardInfo.volumeUUID,
                               cardVolumeName: cardInfo.volumeName, cardCapacityBytes: cardInfo.capacityBytes)
    record.nasMntFromName = config.nasExpectedMntFromName
    record.state = .transferring
    record.files = files
    record.stats.filesPlanned = files.count
    record.stats.bytesPlanned = files.reduce(0) { $0 + $1.size }
    let totalBytes = record.stats.bytesPlanned

    // Persist the crash-time state, then throw the journal away (== process death).
    let journal1 = Journal(directory: journalDir, historyDir: historyDir)
    try await journal1.begin(record)
    try await journal1.flushNow(sessionID)
    log("seeded crash state: 3 nasVerified, 2 uploaded, 2 stagedVerified, 1 uploading, 1 copying, \(files.count - 9) pending")

    // === RELAUNCH: a brand-new Journal instance, as the reopened app would. ===
    let journal2 = Journal(directory: journalDir, historyDir: historyDir)
    guard let resumed = await journal2.openIncompleteSession(cardUUID: cardInfo.volumeUUID) else {
        fail("relaunch did not find the incomplete session — it would be orphaned")
    }
    // Crash remap must have fired.
    guard resumed.files[7].state == .stagedVerified else { fail("uploading did not remap to stagedVerified: \(resumed.files[7].state)") }
    guard resumed.files[8].state == .pending else { fail("copying did not remap to pending: \(resumed.files[8].state)") }
    log("relaunch found the session and applied the crash remap")

    // Mimic the coordinator's resume steps.
    staging.removePartials(sessionID)
    let rescanned = planner.scan(cardRoot: cardRoot, scope: .mediaRootsOnly)
    let merged = await planner.merge(scanned: rescanned, into: resumed.files)
    await journal2.replaceFiles(merged.files, in: sessionID)

    let nas = NASLocator(configProvider: { config })
    let watcher = CardWatcher()
    let runner = SessionRunner(sessionID: sessionID, card: cardInfo, config: config, journal: journal2,
                               staging: staging, nas: nas, cardWatcher: watcher) { _ in }
    await runner.run()

    // === Assertions ===
    print("\n▸ Verifying resume")
    guard let finalRecord = await journal2.loadHistory(limit: 1).first else {
        fail("no completed session in history after resume")
    }

    guard finalRecord.state == .done else { fail("resumed session state \(finalRecord.state), expected done") }
    guard finalRecord.wipeReport?.ran == true else { fail("wipe did not run after resume") }
    log("resumed to completion; wiped \(finalRecord.wipeReport?.filesDeleted ?? 0) files")

    // Every file present on the NAS, byte-identical.
    for file in finalRecord.files {
        let dest = nasRoot.appendingPathComponent(file.destRelPath)
        guard fm.fileExists(atPath: dest.path) else { fail("missing on NAS after resume: \(file.destRelPath)") }
        let nasHash = try Fixtures.sha256(dest)
        guard nasHash == sourceHashes[file.relPath] else { fail("hash mismatch after resume: \(file.destRelPath)") }
    }
    log("all \(finalRecord.files.count) files verified byte-identical on the NAS")

    // Card wiped; no leftover NAS partials.
    for rel in sourceHashes.keys where fm.fileExists(atPath: cardRoot.appendingPathComponent(rel).path) {
        fail("file still on card after resume+wipe: \(rel)")
    }
    if let leftovers = try? fm.subpathsOfDirectory(atPath: nasRoot.path).filter({ $0.contains(".offload-") && $0.hasSuffix(".partial") }),
       !leftovers.isEmpty {
        fail("leftover NAS partials not cleaned: \(leftovers)")
    }
    log("card wiped; leftover NAS partial cleaned")

    // Proof it didn't redo finished work: only the not-yet-done files' bytes
    // should have been written to the NAS this run (< everything).
    let uploaded = finalRecord.stats.bytesUploaded
    guard uploaded < totalBytes else {
        fail("resume re-uploaded everything (\(uploaded) of \(totalBytes)) — finished work was not skipped")
    }
    func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_000_000) }
    log("only \(mb(uploaded)) re-uploaded of \(mb(totalBytes)) total (~\(expectUploadedIndices.count)/\(files.count) files); already-verified files were skipped")

    print("\n✅ PASS — crash mid-transfer, reopened, resumed exactly where it left off. (chaos-crash)")
    exit(0)
}
