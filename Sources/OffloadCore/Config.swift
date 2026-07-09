import Foundation

/// Everything the user (or the engine) can configure, persisted to
/// `~/Library/Application Support/Offload/config.json`.
/// Decoding is tolerant of missing keys so the file can grow across versions.
public struct AppConfig: Codable, Sendable, Equatable {
    // Destination
    public var nasRootPath: String = "/Volumes/Photos"
    /// statfs f_mntfromname learned at first successful validation — the ghost-mount guard.
    public var nasExpectedMntFromName: String?
    /// smb:// URL for NetFS remount, learned from the live mount.
    public var nasSMBURL: String?
    /// Optional second verified destination (a local/external drive folder). When
    /// set, each file is mirrored here and read back before the card is wipe-eligible,
    /// so the card is never reduced to a single copy at wipe time. nil = off.
    public var secondaryDestPath: String?

    // Wipe. Default to asking before erasing a card — a new user should opt in to
    // unattended wipes, not discover them. (Existing configs keep their setting.)
    public var wipePolicy: WipePolicy = .askEachTime
    public var autoEject: Bool = true
    public var wipeCountdownSeconds: Int = 10

    // Ingest
    public var ingestScope: IngestScope = .mediaRootsOnly
    /// What to do with ANY camera card on insert — one global rule, not a per-card
    /// memory. `alwaysIngest`: offload automatically. `ask`: prompt each insert.
    /// `ignore`: do nothing. Default is to offload automatically.
    public var defaultCardAction: CardPolicy = .alwaysIngest
    /// Volume-name prefixes that classify as cards regardless of DA quirks (test DMGs).
    public var testVolumeAllowlist: [String] = ["OFFLOADTEST"]
    /// TEST SEAM ONLY. When true, a plain local folder at the NAS path counts as
    /// a healthy destination — lets the DMG harness stand in for a real share.
    /// Never set in production: the ghost-mount guard is what stops the app from
    /// silently filling the boot disk when the share is unmounted.
    public var testAllowLocalNAS: Bool = false

    // Staging
    public var stagingRootPath: String = Paths.stagingRoot.path
    public var stagingBudgetCapBytes: Int64 = 100 << 30
    public var stagingHeadroomBytes: Int64 = 12 << 30
    public var keepStagedDays: Int = 0        // 0 = purge as soon as NAS-verified

    // Performance
    public var hop1Workers: Int = 1
    public var hop2Workers: Int = 4
    /// Opt-in: on card insert, start validating/establishing the NAS connection
    /// (read-only) so the first upload doesn't pay the ~4–5 s cold-SMB + disk
    /// spin-up cost. Never writes. Off by default.
    public var prewarmNAS: Bool = false

    // Notifications / general
    public var notifyCardDetected: Bool = true
    public var notifyComplete: Bool = true
    public var notifyProblems: Bool = true
    public var playSounds: Bool = true
    /// Name of the macOS system sound played on a completed offload. One of the
    /// built-in ~/System/Library/Sounds names (Glass, Ping, Hero, …).
    public var completionSoundName: String = "Glass"
    public var launchAtLogin: Bool = false
    /// Reveal the uploaded batch in the Library window when an offload finishes
    /// (jumps to the folder that received the photos).
    public var autoShowLibrary: Bool = true
    /// Pop the menu-bar tray open on card insert so progress is visible without
    /// clicking the status item.
    public var autoOpenTrayOnInsert: Bool = true

    public init() {}

    // Tolerant decoding: every key optional, defaults fill the gaps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        nasRootPath = try c.decodeIfPresent(String.self, forKey: .nasRootPath) ?? d.nasRootPath
        nasExpectedMntFromName = try c.decodeIfPresent(String.self, forKey: .nasExpectedMntFromName)
        nasSMBURL = try c.decodeIfPresent(String.self, forKey: .nasSMBURL)
        secondaryDestPath = try c.decodeIfPresent(String.self, forKey: .secondaryDestPath)
        wipePolicy = try c.decodeIfPresent(WipePolicy.self, forKey: .wipePolicy) ?? d.wipePolicy
        autoEject = try c.decodeIfPresent(Bool.self, forKey: .autoEject) ?? d.autoEject
        wipeCountdownSeconds = try c.decodeIfPresent(Int.self, forKey: .wipeCountdownSeconds) ?? d.wipeCountdownSeconds
        ingestScope = try c.decodeIfPresent(IngestScope.self, forKey: .ingestScope) ?? d.ingestScope
        defaultCardAction = try c.decodeIfPresent(CardPolicy.self, forKey: .defaultCardAction) ?? d.defaultCardAction
        // Note: legacy per-card `cardPolicies` / `cardNames` keys are intentionally
        // no longer decoded — the old per-card model is gone, so any stored entries
        // (e.g. a card stuck on "alwaysIngest") are dropped on the next save.
        testVolumeAllowlist = try c.decodeIfPresent([String].self, forKey: .testVolumeAllowlist) ?? d.testVolumeAllowlist
        testAllowLocalNAS = try c.decodeIfPresent(Bool.self, forKey: .testAllowLocalNAS) ?? d.testAllowLocalNAS
        stagingRootPath = try c.decodeIfPresent(String.self, forKey: .stagingRootPath) ?? d.stagingRootPath
        stagingBudgetCapBytes = try c.decodeIfPresent(Int64.self, forKey: .stagingBudgetCapBytes) ?? d.stagingBudgetCapBytes
        stagingHeadroomBytes = try c.decodeIfPresent(Int64.self, forKey: .stagingHeadroomBytes) ?? d.stagingHeadroomBytes
        keepStagedDays = try c.decodeIfPresent(Int.self, forKey: .keepStagedDays) ?? d.keepStagedDays
        hop1Workers = try c.decodeIfPresent(Int.self, forKey: .hop1Workers) ?? d.hop1Workers
        hop2Workers = try c.decodeIfPresent(Int.self, forKey: .hop2Workers) ?? d.hop2Workers
        prewarmNAS = try c.decodeIfPresent(Bool.self, forKey: .prewarmNAS) ?? d.prewarmNAS
        notifyCardDetected = try c.decodeIfPresent(Bool.self, forKey: .notifyCardDetected) ?? d.notifyCardDetected
        notifyComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyComplete) ?? d.notifyComplete
        notifyProblems = try c.decodeIfPresent(Bool.self, forKey: .notifyProblems) ?? d.notifyProblems
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        completionSoundName = try c.decodeIfPresent(String.self, forKey: .completionSoundName) ?? d.completionSoundName
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        autoShowLibrary = try c.decodeIfPresent(Bool.self, forKey: .autoShowLibrary) ?? d.autoShowLibrary
        autoOpenTrayOnInsert = try c.decodeIfPresent(Bool.self, forKey: .autoOpenTrayOnInsert) ?? d.autoOpenTrayOnInsert
    }

    public static func load() -> AppConfig {
        JSONIO.loadGuarded(AppConfig.self, from: Paths.configFile) ?? AppConfig()
    }

    public func save() {
        try? JSONIO.save(self, to: Paths.configFile)
    }
}
