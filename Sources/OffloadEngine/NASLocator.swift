import Foundation
import NetFS
import OffloadCore

public enum NASHealth: Equatable, Sendable {
    case healthy
    case notMounted
    /// The path exists but sits on a LOCAL filesystem — the share unmounted and
    /// something recreated the folder. Writing here would silently fill the
    /// boot disk instead of the NAS. Hard stop.
    case ghostLocalFolder(fstype: String)
    case wrongShare(mntFrom: String)
    case readOnly

    public var isWritableNAS: Bool { self == .healthy }

    public var summary: String {
        switch self {
        case .healthy: "healthy"
        case .notMounted: "share not mounted"
        case .ghostLocalFolder(let fs): "ghost local folder (\(fs)) at the NAS path"
        case .wrongShare(let from): "a different share is mounted (\(from))"
        case .readOnly: "share is read-only"
        }
    }
}

public typealias ConfigProvider = @Sendable () async -> AppConfig
public typealias ConfigMutator = @Sendable (_ mutate: @Sendable @escaping (inout AppConfig) -> Void) async -> Void

/// Destination identity + remount. statfs is primary (volumeUUID is unreliable
/// on smbfs); checked at session start, per-file open (5 s cache), after any
/// destination IO error, and inside the wipe gate.
public actor NASLocator {
    private let configProvider: ConfigProvider
    private let allowTestSubdirectory: Bool
    private var cached: (health: NASHealth, at: Date)?
    private var remountBackoff: TimeInterval = 5
    private var remountInProgress = false
    private var remountWaiters: [CheckedContinuation<Bool, Never>] = []

    public init(configProvider: @escaping ConfigProvider, allowTestSubdirectory: Bool = false) {
        self.configProvider = configProvider
        self.allowTestSubdirectory = allowTestSubdirectory
    }

    public static func evaluate(config: AppConfig, allowTestSubdirectory: Bool = false) -> NASHealth {
        guard let fs = statfsInfo(path: config.nasRootPath) else { return .notMounted }
        let networkTypes = ["smbfs", "afpfs", "nfs", "webdav"]
        guard networkTypes.contains(fs.fsTypeName) else {
            // TEST SEAM: a local folder is allowed to stand in for a share.
            if config.testAllowLocalNAS {
                return fs.isReadOnly ? .readOnly : .healthy
            }
            // statfs succeeded, so the path exists — on a local volume. Ghost.
            return .ghostLocalFolder(fstype: fs.fsTypeName)
        }
        // Must be mounted exactly at our root, not merely under some other share.
        let fixtureSubdirectory = allowTestSubdirectory && config.testAllowLocalNAS
            && config.nasRootPath.hasPrefix(fs.mntOnName + "/.offload-session-test-")
        guard fs.mntOnName == config.nasRootPath || fixtureSubdirectory else { return .notMounted }
        if let expected = config.nasExpectedMntFromName, fs.mntFromName != expected {
            return .wrongShare(mntFrom: fs.mntFromName)
        }
        if fs.isReadOnly { return .readOnly }
        return .healthy
    }

    public func validateNow(force: Bool = false) async -> NASHealth {
        if !force, let cached, Date().timeIntervalSince(cached.at) < 5 {
            return cached.health
        }
        let health = Self.evaluate(config: await configProvider(), allowTestSubdirectory: allowTestSubdirectory)
        cached = (health, Date())
        if health == .healthy { remountBackoff = 5 }
        return health
    }

    /// Drop the cached health verdict so the next non-forced check re-evaluates.
    /// Called after a destination IO error so the ≤5 s fast-path can't keep
    /// reporting "healthy" for a mount that just disappeared.
    public func invalidate() { cached = nil }

    /// One immediate health check with a single safe remount attempt. This is the
    /// non-blocking variant used by idle UI monitoring; active transfers use the
    /// persistent backoff loop below.
    public func reconnectIfNeeded() async -> NASHealth {
        var health = await validateNow(force: true)
        if health == .notMounted {
            _ = await attemptRemount()
            health = await validateNow(force: true)
        }
        return health
    }

    /// Opt-in pre-warm, kicked off when a card is inserted. READ-ONLY: wakes the SMB
    /// session (and spins up the NAS disks) early so the first hop-2 upload doesn't
    /// pay the cold-connection cost. Never writes → can't violate the ghost-mount
    /// guard. Best-effort and non-throwing. (Even if the ≤5 s health cache lapses
    /// before uploads start, the SMB session + spun-up disks stay warm — the real win.)
    public func prewarm() async {
        let health = await reconnectIfNeeded()               // forced statfs classifies + wakes the session
        guard health == .healthy else { return }             // never probe a ghost/wrong/read-only share
        let root = (await configProvider()).nasRootPath
        await Task.detached(priority: .utility) {            // off-actor: don't hold NASLocator during the read
            _ = try? FileManager.default.contentsOfDirectory(atPath: root)   // cheap read-only round-trip
        }.value
    }

    /// Blocks until the share is healthy. Attempts a NetFS remount, then
    /// backoff-retries (5 s → 60 s). Ghost folders are NEVER retried past —
    /// the caller surfaces them loudly and waits for the user.
    public func ensureMountedAndHealthy(onWaiting: (@Sendable (NASHealth) async -> Void)? = nil) async throws -> URL {
        while true {
            try Task.checkCancellation()
            let health = await validateNow(force: true)
            switch health {
            case .healthy:
                return URL(fileURLWithPath: (await configProvider()).nasRootPath, isDirectory: true)
            case .notMounted:
                await onWaiting?(health)
                if await attemptRemount() { continue }
            case .ghostLocalFolder, .wrongShare, .readOnly:
                await onWaiting?(health)
                // Nothing we can safely automate — wait for the user/system.
            }
            try await Task.sleep(for: .seconds(remountBackoff))
            remountBackoff = min(60, remountBackoff * 2)
        }
    }

    // MARK: - NetFS remount

    private func attemptRemount() async -> Bool {
        let config = await configProvider()
        guard let smb = config.nasSMBURL, let url = URL(string: smb) else { return false }

        // Several upload workers and the visible-window monitor can notice the
        // same outage together. Join the in-flight NetFS request instead of
        // launching competing mounts for the same share.
        if remountInProgress {
            return await withCheckedContinuation { remountWaiters.append($0) }
        }
        remountInProgress = true

        var user: String?
        var password: String?
        if let creds = Keychain.get(service: Keychain.nasCredentialsService),
           let newline = creds.firstIndex(of: "\n") {
            user = String(creds[..<newline])
            password = String(creds[creds.index(after: newline)...])
        }
        // With nil credentials NetFS falls back to the login keychain entry
        // Finder saved when the user ticked "Remember this password".

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let options = NSMutableDictionary()
            options[kNAUIOptionKey as String] = kNAUIOptionNoUI
            var requestID: AsyncRequestID?
            let status = NetFSMountURLAsync(
                url as CFURL,
                nil,                       // default mount dir (/Volumes)
                user as CFString?,
                password as CFString?,
                options,
                nil,
                &requestID,
                DispatchQueue.global(qos: .utility)
            ) { status, _, _ in
                continuation.resume(returning: status == 0)
            }
            if status != 0 {
                continuation.resume(returning: false)
            }
        }
        remountInProgress = false
        let waiters = remountWaiters
        remountWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        return result
    }
}
