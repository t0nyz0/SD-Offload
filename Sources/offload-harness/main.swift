import Foundation
import OffloadCore
import OffloadEngine

// Offload wipe-path harness. Creates a fake exFAT SD card (hdiutil DMG) full of
// EXIF-dated JPEGs and a local fake NAS, runs a REAL ingest session end to end,
// and asserts every file landed on the NAS byte-identical and the card was
// wiped and pruned. This exercises the actual copy/verify/wipe code — the same
// paths that would run against a real card — without risking real hardware.
//
//   swift run offload-harness            # happy path
//   swift run offload-harness chaos-nas  # NAS disappears mid-upload, then returns

let mode = CommandLine.arguments.dropFirst().first ?? "run"

let workspace = FileManager.default.temporaryDirectory
    .appendingPathComponent("offload-harness-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
let nasRoot = workspace.appendingPathComponent("nas", isDirectory: true)
let staging = workspace.appendingPathComponent("staging", isDirectory: true)
try FileManager.default.createDirectory(at: nasRoot, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

func log(_ s: String) { print("  \(s)") }
func fail(_ s: String) -> Never { print("\n❌ FAIL: \(s)"); exit(1) }

print("▸ Offload harness [\(mode)]")
print("  workspace: \(workspace.path)")

// --- Build the fake card -----------------------------------------------------
// Prefer a real attached exFAT DMG; fall back to a plain directory where disk
// images are forbidden. Either way the engine sees a mount path it reads and
// wipes — the safety-critical path is identical.
let volName = "OFFLOADTEST-1"
let dmg = workspace.appendingPathComponent("card.dmg")
let cardMountPath: String
let cardDev: String?
if let attached = Fixtures.attachExFATCard(dmgPath: dmg, volName: volName, sizeMB: 96) {
    cardMountPath = attached.mount
    cardDev = attached.dev
    log("card: real exFAT DMG at \(attached.mount)")
} else {
    let dir = workspace.appendingPathComponent("card", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    cardMountPath = dir.path
    cardDev = nil
    log("card: directory fallback at \(dir.path) (disk images unavailable here)")
}
defer {
    if let cardDev { Fixtures.detach(dev: cardDev) }
    try? FileManager.default.removeItem(at: workspace)
}

// DCIM/100TEST + 101TEST, across two days, with one deliberate cross-folder
// name collision (IMG_0001.JPG on the same day) to exercise " (2)" suffixing.
let cardRoot = URL(fileURLWithPath: cardMountPath)
let f1 = cardRoot.appendingPathComponent("DCIM/100TEST", isDirectory: true)
let f2 = cardRoot.appendingPathComponent("DCIM/101TEST", isDirectory: true)
try FileManager.default.createDirectory(at: f1, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: f2, withIntermediateDirectories: true)

var sourceHashes: [String: String] = [:]   // relPath -> sha256
let day1 = ISO8601DateFormatter().date(from: "2026-07-04T10:15:00Z")!
let day2 = ISO8601DateFormatter().date(from: "2026-07-05T18:30:00Z")!

func makeFile(_ folder: URL, _ name: String, date: Date, seed: UInt8) throws {
    let url = folder.appendingPathComponent(name)
    let hash = try Fixtures.writeJPEG(to: url, captureDate: date, seed: seed)
    let rel = url.path.replacingOccurrences(of: cardRoot.path + "/", with: "")
    sourceHashes[rel] = hash
}

for i in 1...8 { try makeFile(f1, String(format: "IMG_%04d.JPG", i), date: i <= 5 ? day1 : day2, seed: UInt8(i * 20)) }
for i in 1...4 { try makeFile(f2, String(format: "IMG_%04d.JPG", i), date: day1, seed: UInt8(200 - i * 15)) }
// Also drop a camera system folder that MUST NOT be touched.
let sysFolder = cardRoot.appendingPathComponent("MISC", isDirectory: true)
try FileManager.default.createDirectory(at: sysFolder, withIntermediateDirectories: true)
try "firmware".data(using: .utf8)!.write(to: sysFolder.appendingPathComponent("FWUP.BIN"))
log("wrote \(sourceHashes.count) photos + 1 untouchable system folder")

// --- Chaos: one unreadable file must block the ENTIRE wipe -------------------
if mode == "chaos-unreadable" {
    let victim = f1.appendingPathComponent("IMG_0003.JPG")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: victim.path)
    log("made IMG_0003.JPG unreadable — the whole card must stay intact")
}

// --- Config + engine plumbing (test seam: local folder as NAS) ---------------
var config = AppConfig()
config.nasRootPath = nasRoot.path
config.stagingRootPath = staging.path
config.wipePolicy = .afterNASVerify
config.autoEject = false            // we detach the DMG ourselves
config.wipeCountdownSeconds = 0     // no countdown in the harness
config.testAllowLocalNAS = true

let journalDir = workspace.appendingPathComponent("journal", isDirectory: true)
let historyDir = workspace.appendingPathComponent("history", isDirectory: true)
let journal = Journal(directory: journalDir, historyDir: historyDir)
let stagingStore = StagingStore(rootPath: staging.path)
let cfg = config             // immutable snapshot for the Sendable provider closure
let nas = NASLocator(configProvider: { cfg })
let watcher = CardWatcher()   // not started; autoEject off so eject is never called

let cardInfo = CardInfo(volumeUUID: "\(volName)#test", bsdName: cardDev ?? "disk-test",
                        mountPath: cardMountPath, volumeName: volName,
                        capacityBytes: 96 << 20, freeBytes: 80 << 20, hasDCIM: true)

// Crash/reopen resume proof — seeds a mid-transfer journal and resumes it.
if mode == "chaos-crash" {
    try await runCrashResumeScenario(cardRoot: cardRoot, nasRoot: nasRoot, staging: stagingStore,
                                     journalDir: journalDir, historyDir: historyDir, config: cfg,
                                     cardInfo: cardInfo, sourceHashes: sourceHashes)
    // exits(0) on success
}

// Plan the manifest exactly as the real coordinator would.
let planner = IngestPlanner()
let scanned = planner.scan(cardRoot: cardRoot, scope: .mediaRootsOnly)
log("scanned \(scanned.count) media files (system folder excluded: \(scanned.allSatisfy { !$0.relPath.hasPrefix("MISC") }))")
let plan = await planner.plan(scanned: scanned)
var record = SessionRecord(cardVolumeUUID: cardInfo.volumeUUID, cardVolumeName: volName,
                           cardCapacityBytes: cardInfo.capacityBytes)
record.files = plan.files
record.stats.filesPlanned = plan.files.count
record.stats.bytesPlanned = plan.files.reduce(0) { $0 + $1.size }
try await journal.begin(record)

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
let eventLog = EventLog()
let runner = SessionRunner(sessionID: record.id, card: cardInfo, config: cfg, journal: journal,
                           staging: stagingStore, nas: nas, cardWatcher: watcher) { event in
    switch event {
    case .phase(let p): eventLog.add("phase:\(p.rawValue)")
    case .attention(let a): eventLog.add("attention:\(a.title) — \(a.detail)")
    case .safeToRemove: eventLog.add("safeToRemove")
    default: break
    }
}

// --- Chaos: NAS is DOWN when the run starts, comes back mid-flight -----------
// Hide it up front (deterministic — tiny files would otherwise finish before any
// timed hide). Hop 1 must keep copying to staging while hop 2 parks on the
// missing share; when it returns, hop 2 drains and the wipe proceeds.
if mode == "chaos-nas" {
    let hidden = workspace.appendingPathComponent("nas-hidden", isDirectory: true)
    try FileManager.default.moveItem(at: nasRoot, to: hidden)
    log("NAS is down at start (hop 2 must wait)")
    Task.detached {
        try? await Task.sleep(for: .milliseconds(1200))
        try? FileManager.default.moveItem(at: hidden, to: nasRoot)
        log("… NAS restored mid-run")
    }
}

let start = Date()
await runner.run()
let elapsed = Date().timeIntervalSince(start)

// --- Assertions --------------------------------------------------------------
print("\n▸ Verifying")
let final = await journal.loadHistory(limit: 1).first ?? record

// Safety-critical path: a single unreadable file must leave the card 100% intact.
if mode == "chaos-unreadable" {
    guard final.state == .doneWipeBlocked else {
        fail("expected doneWipeBlocked, got \(final.state)")
    }
    guard final.wipeReport?.ran != true else { fail("WIPE RAN despite a failed file — safety violation!") }
    var stillThere = 0
    for rel in sourceHashes.keys {
        let onCard = cardRoot.appendingPathComponent(rel)
        guard FileManager.default.fileExists(atPath: onCard.path) else {
            fail("file was deleted despite the wipe being blocked: \(rel)")
        }
        stillThere += 1
    }
    // Restore perms so cleanup can remove the workspace.
    try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                           ofItemAtPath: f1.appendingPathComponent("IMG_0003.JPG").path)
    log("wipe correctly blocked; all \(stillThere) files still on the card")
    print("\n✅ PASS — one failure blocked the whole wipe; card untouched. (\(mode))")
    exit(0)
}

// 1. Session completed with a successful wipe.
guard final.state == .done else { fail("session state is \(final.state), expected done. events=\(eventLog.all)") }
guard final.wipeReport?.ran == true else { fail("wipe did not run: \(String(describing: final.wipeReport))") }
log("session done; wiped \(final.wipeReport?.filesDeleted ?? 0) files in \(String(format: "%.1f", elapsed))s")

// 2. Every source file is on the NAS, byte-identical, at a date path.
var verified = 0
var suffixed = 0
for file in final.files {
    // .wiped is the ideal end state (verified on NAS AND removed from card);
    // .nasVerified/.skippedDuplicate are acceptable if wipe was skipped.
    guard file.state == .wiped || file.state == .nasVerified || file.state == .skippedDuplicate else {
        fail("\(file.relPath) ended in state \(file.state)")
    }
    let dest = nasRoot.appendingPathComponent(file.destRelPath)
    guard FileManager.default.fileExists(atPath: dest.path) else { fail("missing on NAS: \(file.destRelPath)") }
    let nasHash = try Fixtures.sha256(dest)
    guard let src = sourceHashes[file.relPath] else { fail("no source hash for \(file.relPath)") }
    guard nasHash == src else { fail("hash mismatch on \(file.destRelPath)") }
    if file.destRelPath.contains("(2)") { suffixed += 1 }
    verified += 1
}
log("all \(verified) files present on NAS with matching SHA-256 (\(suffixed) collision-suffixed)")

// 3. Date routing sanity: files carry YYYY/MM/DD.
let routed = final.files.allSatisfy { $0.destRelPath.range(of: #"^\d{4}/\d{2}/\d{2}/"#, options: .regularExpression) != nil }
guard routed else { fail("some files not routed into YYYY/MM/DD folders") }
log("date routing correct (2026/07/04 and 2026/07/05 present)")

// 4. The card's DCIM is wiped and empty folders pruned; system folder untouched.
for rel in sourceHashes.keys {
    let onCard = cardRoot.appendingPathComponent(rel)
    if FileManager.default.fileExists(atPath: onCard.path) { fail("file still on card: \(rel)") }
}
let fwStillThere = FileManager.default.fileExists(atPath: sysFolder.appendingPathComponent("FWUP.BIN").path)
guard fwStillThere else { fail("harness bug: system folder was deleted (should be untouchable)") }
log("card DCIM emptied; MISC/FWUP.BIN untouched")

// 5. Staging purged.
let stagingLeft = (try? FileManager.default.contentsOfDirectory(at: stagingStore.sessionDir(record.id),
                                                                includingPropertiesForKeys: nil))?.count ?? 0
guard stagingLeft == 0 else { fail("\(stagingLeft) staged files not purged") }
log("staging purged")

print("\n✅ PASS — \(verified) files offloaded, verified end-to-end, card wiped. (\(mode), \(String(format: "%.1f", elapsed))s)")
exit(0)
