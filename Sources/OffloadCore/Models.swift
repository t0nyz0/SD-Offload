import Foundation

// MARK: - Policies

public enum WipePolicy: String, Codable, Sendable, CaseIterable {
    case afterNASVerify
    case afterStagingVerify
    case askEachTime
}

public enum CardPolicy: String, Codable, Sendable {
    case alwaysIngest, ask, ignore
}

public enum IngestScope: String, Codable, Sendable {
    case mediaRootsOnly   // DCIM, PRIVATE, AVCHD, CLIP, MP_ROOT
    case wholeCard
}

// MARK: - Card

public struct CardInfo: Codable, Sendable, Equatable {
    public let volumeUUID: String
    public let bsdName: String
    public let mountPath: String
    public let volumeName: String
    public let capacityBytes: Int64
    public let freeBytes: Int64
    public let hasDCIM: Bool

    public init(volumeUUID: String, bsdName: String, mountPath: String, volumeName: String,
                capacityBytes: Int64, freeBytes: Int64, hasDCIM: Bool) {
        self.volumeUUID = volumeUUID
        self.bsdName = bsdName
        self.mountPath = mountPath
        self.volumeName = volumeName
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.hasDCIM = hasDCIM
    }

    public var usedBytes: Int64 { max(0, capacityBytes - freeBytes) }
}

// MARK: - Per-file state machine

public enum FileState: Codable, Equatable, Sendable {
    case pending
    case copying
    case staged
    case stagedVerified
    case uploading
    case uploaded
    case nasVerified
    case skippedDuplicate
    case wiped
    case failed(TransferFailure)

    public var isTerminal: Bool {
        switch self {
        case .nasVerified, .skippedDuplicate, .wiped, .failed: return true
        default: return false
        }
    }

    public var isWipeEligible: Bool {
        switch self {
        case .nasVerified, .skippedDuplicate, .wiped: return true
        default: return false
        }
    }

    /// Applied when reopening a journal after a crash/relaunch: in-flight work
    /// rolls back to its last safe checkpoint; verification states re-verify.
    public static func crashRemap(_ state: FileState) -> FileState {
        switch state {
        case .copying: return .pending
        case .uploading: return .stagedVerified
        default: return state
        }
    }

    /// Legal forward transitions. Anything else is a programmer error.
    public static func isLegal(from: FileState, to: FileState) -> Bool {
        if case .failed = to {
            // Any non-terminal state may fail.
            return !from.isTerminal
        }
        switch (from, to) {
        case (.pending, .copying),
             (.copying, .staged),
             (.copying, .skippedDuplicate),
             (.copying, .pending),                 // retry rollback
             (.staged, .stagedVerified),
             (.staged, .pending),                  // verify mismatch → re-copy
             (.stagedVerified, .uploading),
             (.uploading, .uploaded),
             (.uploading, .stagedVerified),        // retry rollback
             (.uploaded, .nasVerified),
             (.uploaded, .stagedVerified),         // NAS verify mismatch → re-upload
             (.uploaded, .pending),                // NAS verify mismatch, staging gone → re-copy
             (.nasVerified, .wiped),
             (.skippedDuplicate, .wiped):
            return true
        default:
            return false
        }
    }
}

public struct FileRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// Relative to the card mount root — the only path we ever store.
    public let relPath: String
    public let size: Int64
    public let mtime: Date          // exFAT granularity: compare ±2 s
    public let creationDate: Date?
    public var captureDate: Date?
    /// e.g. "2026/07/04/DSCF0523.RAF" (post-collision-resolution), relative to NAS root.
    public var destRelPath: String
    /// SHA-256 from the hop-1 read pass — the end-to-end reference hash.
    public var sourceHashHex: String?
    public var state: FileState
    public var attempts: Int
    public var stateChangedAt: Date

    public init(id: UUID = UUID(), relPath: String, size: Int64, mtime: Date,
                creationDate: Date?, captureDate: Date? = nil, destRelPath: String,
                sourceHashHex: String? = nil, state: FileState = .pending,
                attempts: Int = 0, stateChangedAt: Date = Date()) {
        self.id = id
        self.relPath = relPath
        self.size = size
        self.mtime = mtime
        self.creationDate = creationDate
        self.captureDate = captureDate
        self.destRelPath = destRelPath
        self.sourceHashHex = sourceHashHex
        self.state = state
        self.attempts = attempts
        self.stateChangedAt = stateChangedAt
    }

    public var fileName: String { (relPath as NSString).lastPathComponent }
}

// MARK: - Session

public enum SessionState: String, Codable, Sendable {
    case scanning, transferring, waitingForNAS, pausedCardGone, pausedByUser,
         awaitingWipeConsent, wipeCountdown, wiping, ejecting,
         done, doneWipeBlocked, cancelled, failed
}

public struct PhaseSpan: Codable, Sendable, Equatable {
    public let name: String
    public var start: Date
    public var end: Date?
    public init(name: String, start: Date = Date(), end: Date? = nil) {
        self.name = name; self.start = start; self.end = end
    }
    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

public struct SpeedSample: Codable, Sendable, Equatable {
    /// Seconds since session start.
    public let t: TimeInterval
    public let sdReadBps: Double
    public let nasWriteBps: Double
    public init(t: TimeInterval, sdReadBps: Double, nasWriteBps: Double) {
        self.t = t; self.sdReadBps = sdReadBps; self.nasWriteBps = nasWriteBps
    }
}

public struct SessionStats: Codable, Sendable, Equatable {
    public var bytesPlanned: Int64 = 0
    public var filesPlanned: Int = 0
    public var bytesRead: Int64 = 0
    public var bytesUploaded: Int64 = 0
    public var filesNASVerified: Int = 0
    public var filesSkippedDuplicate: Int = 0
    public var filesFailed: Int = 0
    public var filesWiped: Int = 0
    public var avgSDReadBps: Double = 0
    public var peakSDReadBps: Double = 0
    public var avgNASWriteBps: Double = 0
    public var peakNASWriteBps: Double = 0
    public var phases: [PhaseSpan] = []
    /// Downsampled to ≤ 600 buckets before persisting.
    public var timeline: [SpeedSample] = []
    public init() {}
}

public struct WipeReport: Codable, Sendable, Equatable {
    public var ran: Bool
    public var filesDeleted: Int
    public var blockers: [String]
    public var finishedAt: Date?
    public init(ran: Bool, filesDeleted: Int = 0, blockers: [String] = [], finishedAt: Date? = nil) {
        self.ran = ran; self.filesDeleted = filesDeleted; self.blockers = blockers; self.finishedAt = finishedAt
    }
}

public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let cardVolumeUUID: String
    public let cardVolumeName: String
    public let cardCapacityBytes: Int64
    /// statfs f_mntfromname recorded at session start; re-checked by the wipe gate.
    public var nasMntFromName: String?
    public var state: SessionState
    public var files: [FileRecord]
    public var stats: SessionStats
    public var wipeReport: WipeReport?
    public var endedAt: Date?

    public init(id: UUID = UUID(), startedAt: Date = Date(), cardVolumeUUID: String,
                cardVolumeName: String, cardCapacityBytes: Int64, nasMntFromName: String? = nil,
                state: SessionState = .scanning, files: [FileRecord] = [],
                stats: SessionStats = SessionStats(), wipeReport: WipeReport? = nil,
                endedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.cardVolumeUUID = cardVolumeUUID
        self.cardVolumeName = cardVolumeName
        self.cardCapacityBytes = cardCapacityBytes
        self.nasMntFromName = nasMntFromName
        self.state = state
        self.files = files
        self.stats = stats
        self.wipeReport = wipeReport
        self.endedAt = endedAt
    }

    public var isIncomplete: Bool {
        switch state {
        case .done, .doneWipeBlocked, .cancelled, .failed: return false
        default: return true
        }
    }
}
