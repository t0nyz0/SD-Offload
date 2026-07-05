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

    // Wipe
    public var wipePolicy: WipePolicy = .afterNASVerify
    public var autoEject: Bool = true
    public var wipeCountdownSeconds: Int = 10

    // Ingest
    public var ingestScope: IngestScope = .mediaRootsOnly
    public var cardPolicies: [String: CardPolicy] = [:]
    /// volumeUUID → last-seen name, for the Settings list.
    public var cardNames: [String: String] = [:]
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
    public var hop2Workers: Int = 3

    // Notifications / general
    public var notifyCardDetected: Bool = true
    public var notifyComplete: Bool = true
    public var notifyProblems: Bool = true
    public var playSounds: Bool = true
    public var launchAtLogin: Bool = false

    public init() {}

    // Tolerant decoding: every key optional, defaults fill the gaps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        nasRootPath = try c.decodeIfPresent(String.self, forKey: .nasRootPath) ?? d.nasRootPath
        nasExpectedMntFromName = try c.decodeIfPresent(String.self, forKey: .nasExpectedMntFromName)
        nasSMBURL = try c.decodeIfPresent(String.self, forKey: .nasSMBURL)
        wipePolicy = try c.decodeIfPresent(WipePolicy.self, forKey: .wipePolicy) ?? d.wipePolicy
        autoEject = try c.decodeIfPresent(Bool.self, forKey: .autoEject) ?? d.autoEject
        wipeCountdownSeconds = try c.decodeIfPresent(Int.self, forKey: .wipeCountdownSeconds) ?? d.wipeCountdownSeconds
        ingestScope = try c.decodeIfPresent(IngestScope.self, forKey: .ingestScope) ?? d.ingestScope
        cardPolicies = try c.decodeIfPresent([String: CardPolicy].self, forKey: .cardPolicies) ?? d.cardPolicies
        cardNames = try c.decodeIfPresent([String: String].self, forKey: .cardNames) ?? d.cardNames
        testVolumeAllowlist = try c.decodeIfPresent([String].self, forKey: .testVolumeAllowlist) ?? d.testVolumeAllowlist
        testAllowLocalNAS = try c.decodeIfPresent(Bool.self, forKey: .testAllowLocalNAS) ?? d.testAllowLocalNAS
        stagingRootPath = try c.decodeIfPresent(String.self, forKey: .stagingRootPath) ?? d.stagingRootPath
        stagingBudgetCapBytes = try c.decodeIfPresent(Int64.self, forKey: .stagingBudgetCapBytes) ?? d.stagingBudgetCapBytes
        stagingHeadroomBytes = try c.decodeIfPresent(Int64.self, forKey: .stagingHeadroomBytes) ?? d.stagingHeadroomBytes
        keepStagedDays = try c.decodeIfPresent(Int.self, forKey: .keepStagedDays) ?? d.keepStagedDays
        hop1Workers = try c.decodeIfPresent(Int.self, forKey: .hop1Workers) ?? d.hop1Workers
        hop2Workers = try c.decodeIfPresent(Int.self, forKey: .hop2Workers) ?? d.hop2Workers
        notifyCardDetected = try c.decodeIfPresent(Bool.self, forKey: .notifyCardDetected) ?? d.notifyCardDetected
        notifyComplete = try c.decodeIfPresent(Bool.self, forKey: .notifyComplete) ?? d.notifyComplete
        notifyProblems = try c.decodeIfPresent(Bool.self, forKey: .notifyProblems) ?? d.notifyProblems
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? d.playSounds
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    public static func load() -> AppConfig {
        JSONIO.loadGuarded(AppConfig.self, from: Paths.configFile) ?? AppConfig()
    }

    public func save() {
        try? JSONIO.save(self, to: Paths.configFile)
    }
}
