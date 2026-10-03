import Foundation
import Observation
import OffloadCore
import OffloadEngine

/// Display-ready state for one ingest session. Raw engine progress lands in an
/// `@ObservationIgnored` scratch snapshot; a 4 Hz display tick formats once and
/// assigns observable properties ONLY when the value changed (Observation
/// notifies on every set, equal or not — the guard is the anti-jank trick).
@MainActor @Observable
final class SessionViewModel {
    let sessionID: UUID
    let card: CardInfo
    let resumed: Bool

    var phase: EnginePhase = .scanning
    var verification: VerificationProgress?
    var nasActivityDetail: String?
    var uploadFilesRemaining = 0
    var isChecking: Bool {
        phase == .verifyingDestination || (phase == .transferring && hop1Fraction >= 1 && hop2Fraction >= 1 && uploadFilesRemaining == 0)
    }
    var transferStatus: String {
        if isChecking { return verification?.label ?? "Checking NAS copies" }
        if hop1Fraction < 1 { return "Copying from card" }
        if (verification?.activeFiles ?? 0) > 0 { return "Saving and checking NAS" }
        return "Saving to NAS"
    }
    var headlinePercent: Int {
        if phase == .done { return 100 }
        if isChecking, let verification { return min(99, Int(verification.fraction * 100)) }
        return min(99, percentInt)
    }
    var verificationDetail: String? {
        guard let v = verification else { return nil }
        if v.activeFiles > 0 && v.secondsWithoutProgress >= 10 {
            return "Waiting for NAS data · no bytes received for \(Int(v.secondsWithoutProgress))s"
        }
        if let file = v.currentFile {
            return v.activeFiles > 1 ? "\(file) + \(v.activeFiles - 1) more" : file
        }
        return v.filesDone == v.filesTotal ? "This check passed" : "Waiting for files to finish uploading"
    }
    var percentInt = 0
    var overallFraction: Double = 0
    var hop1Fraction: Double = 0
    var hop2Fraction: Double = 0
    var hop1SpeedText = "—"
    var hop2SpeedText = "—"
    var etaCardFreeText: String?
    var etaAllSafeText: String?
    var filesText = ""
    var bytesText = ""
    var currentFileName: String?
    var samples: [SpeedSample] = []
    var wipeCountdown: Int?
    var completed: SessionRecord?
    var failure: AttentionItem?
    var plannedFiles = 0
    var plannedBytes: Int64 = 0

    @ObservationIgnored var scratch = ProgressSnapshot()

    init(sessionID: UUID, card: CardInfo, resumed: Bool) {
        self.sessionID = sessionID
        self.card = card
        self.resumed = resumed
    }

    var cardTitle: String {
        "\(card.volumeName) · \(Fmt.bytes(card.capacityBytes))"
    }

    /// Called at 4 Hz by AppState while a session is live.
    func applyScratchTick() {
        let s = scratch
        set(\.verification, s.verification)
        set(\.nasActivityDetail, s.nasActivityDetail)
        set(\.uploadFilesRemaining, s.uploadFilesRemaining)
        // Monotonic clamps — progress never moves backwards on retries.
        set(\.hop1Fraction, max(hop1Fraction, s.hop1Fraction))
        set(\.hop2Fraction, max(hop2Fraction, s.hop2Fraction))
        let overall = max(overallFraction, s.overallFraction)
        set(\.overallFraction, overall)
        set(\.percentInt, max(percentInt, min(100, Int((overall * 100).rounded(.down)))))
        set(\.hop1SpeedText, Fmt.speed(s.sdReadBps))
        set(\.hop2SpeedText, Fmt.speed(s.nasWriteBps))
        set(\.etaCardFreeText, Fmt.eta(s.etaCardFree))
        set(\.etaAllSafeText, Fmt.eta(s.etaAllSafe))
        if s.filesTotal > 0 {
            set(\.filesText, s.filesFailed > 0
                ? "\(max(0, s.filesSettled - s.filesFailed)) verified · \(s.filesFailed) need attention"
                : "\(s.filesSettled) / \(s.filesTotal) files verified")
        }
        if s.hop1BytesTotal > 0 {
            set(\.bytesText, "\(Fmt.bytes(s.hop1BytesDone)) of \(Fmt.bytes(s.hop1BytesTotal))")
        }
        set(\.currentFileName, s.currentFileName)
    }

    /// 1 Hz from the engine; keep a longer tail for the sparkline.
    func appendSample(_ sample: SpeedSample) {
        samples.append(sample)
        if samples.count > 180 { samples.removeFirst(samples.count - 180) }
    }

    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SessionViewModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
