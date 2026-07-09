import Foundation
import OffloadCore

// MARK: - Events (engine → UI)

public enum EnginePhase: String, Sendable {
    case idle, awaitingConsent, scanning, transferring, waitingForNAS,
         wipeCountdown, awaitingWipeConsent, wiping, ejecting,
         done, doneWipeBlocked, failed, pausedCardGone, pausedByUser, cancelled
}

/// Coalesced progress snapshot, emitted by the engine at ≤ ~10 Hz.
public struct ProgressSnapshot: Sendable, Equatable {
    public var hop1BytesDone: Int64 = 0
    public var hop1BytesTotal: Int64 = 0
    public var hop2BytesDone: Int64 = 0
    public var hop2BytesTotal: Int64 = 0
    public var filesSettled: Int = 0        // nasVerified + skippedDuplicate + failed
    public var filesTotal: Int = 0
    public var currentFileName: String?
    public var sdReadBps: Double?
    public var nasWriteBps: Double?
    public var etaCardFree: TimeInterval?
    public var etaAllSafe: TimeInterval?
    public init() {}

    public var hop1Fraction: Double { hop1BytesTotal > 0 ? Double(hop1BytesDone) / Double(hop1BytesTotal) : 0 }
    public var hop2Fraction: Double { hop2BytesTotal > 0 ? Double(hop2BytesDone) / Double(hop2BytesTotal) : 0 }
    /// Overall = both hops weighted equally by bytes (each byte travels twice).
    public var overallFraction: Double {
        let total = hop1BytesTotal + hop2BytesTotal
        guard total > 0 else { return 0 }
        return Double(hop1BytesDone + hop2BytesDone) / Double(total)
    }
}

public struct AttentionItem: Sendable, Equatable {
    public enum Severity: Sendable { case info, warning, error }
    public var severity: Severity
    public var title: String
    public var detail: String
    public var cardWiped: Bool     // always false when attention fires — surfaced for reassurance copy
    public init(severity: Severity, title: String, detail: String, cardWiped: Bool = false) {
        self.severity = severity; self.title = title; self.detail = detail; self.cardWiped = cardWiped
    }
}

public struct NASGlance: Sendable, Equatable {
    public var mounted: Bool
    public var healthy: Bool
    public var freeBytes: Int64
    public var totalBytes: Int64
    public var photoCount: Int?     // nil while the library index is still counting
    public var photoBytes: Int64?
    /// statfs f_mntfromname of the live mount — used to learn the ghost-mount guard string.
    public var mntFromName: String?
    public init(mounted: Bool = false, healthy: Bool = false, freeBytes: Int64 = 0,
                totalBytes: Int64 = 0, photoCount: Int? = nil, photoBytes: Int64? = nil,
                mntFromName: String? = nil) {
        self.mounted = mounted; self.healthy = healthy
        self.freeBytes = freeBytes; self.totalBytes = totalBytes
        self.photoCount = photoCount; self.photoBytes = photoBytes
        self.mntFromName = mntFromName
    }
}

public enum EngineEvent: Sendable {
    case cardMounted(CardInfo)
    case cardAwaitingConsent(CardInfo)
    case cardGone
    case sessionStarted(sessionID: UUID, card: CardInfo, resumed: Bool)
    case planned(files: Int, bytes: Int64)
    case phase(EnginePhase)
    case progress(ProgressSnapshot)
    case speedSample(SpeedSample)              // 1 Hz, for the sparkline
    case wipeCountdown(secondsRemaining: Int)
    case attention(AttentionItem)
    case safeToRemove(cardName: String)
    case completed(SessionRecord)
    case sessionFailed(SessionRecord, AttentionItem)
    case nasGlance(NASGlance)
}

// MARK: - Control (UI → engine)

public protocol EngineControlling: AnyObject {
    var events: AsyncStream<EngineEvent> { get }
    func start()
    /// Ask-mode consent for a detected card (one-time — the global default decides
    /// whether the prompt appears at all; there is no per-card memory).
    func consentToIngest(cardUUID: String)
    func declineIngest(cardUUID: String)
    func pause()
    func resume()
    func cancel()
    func confirmWipe()
    func cancelWipe()
    func eject()
    func retry()
    func refreshNASGlance()
    /// Force a re-check of every mounted volume, ignoring the per-insertion dedup.
    /// Recovery for a card whose insert was swallowed because its previous removal
    /// event never cleared the dedup markers (e.g. it sat busy in the Library).
    func rescan()
}
