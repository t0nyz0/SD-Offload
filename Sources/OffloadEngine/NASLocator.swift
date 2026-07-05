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
    private var cached: (health: NASHealth, at: Date)?
    private var remountBackoff: TimeInterval = 5

    public init(configProvider: @escaping ConfigProvider) {
        self.configProvider = configProvider
    }

    public static func evaluate(config: AppConfig) -> NASHealth {
        guard let fs = statfsInfo(path: config.nasRootPath) else { return .notMounted }
        let networkTypes = ["smbfs", "afpfs", "nfs", "webdav"]
        guard networkTypes.contains(fs.fsTypeName) else {
            // statfs succeeded, so the path exists — on a local volume. Ghost.
            return .ghostLocalFolder(fstype: fs.fsTypeName)
        }
        // Must be mounted exactly at our root, not merely under some other share.
        guard fs.mntOnName == config.nasRootPath else { return .notMounted }
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
        let health = Self.evaluate(config: await configProvider())
        cached = (health, Date())
        if health == .healthy { remountBackoff = 5 }
        return health
    }

    /// Blocks until the share is healthy. Attempts a NetFS remount, then
    /// backoff-retries (5 s → 60 s). Ghost folders are NEVER retried past —
    /// the caller surfaces them loudly and waits for the user.
    public func ensureMountedAndHealthy(onWaiting: (@Sendable (NASHealth) -> Void)? = nil) async throws -> URL {
        while true {
            try Task.checkCancellation()
            let health = await validateNow(force: true)
            switch health {
            case .healthy:
                return URL(fileURLWithPath: (await configProvider()).nasRootPath, isDirectory: true)
            case .notMounted:
                onWaiting?(health)
                if await attemptRemount() { continue }
            case .ghostLocalFolder, .wrongShare, .readOnly:
                onWaiting?(health)
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

        var user: String?
        var password: String?
        if let creds = Keychain.get(service: Keychain.nasCredentialsService),
           let newline = creds.firstIndex(of: "\n") {
            user = String(creds[..<newline])
            password = String(creds[creds.index(after: newline)...])
        }
        // With nil credentials NetFS falls back to the login keychain entry
        // Finder saved when the user ticked "Remember this password".

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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
    }
}
