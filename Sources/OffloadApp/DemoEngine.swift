import Foundation
import OffloadCore
import OffloadEngine

/// Scripted fake engine for hardware-free UI development (`OFFLOAD_DEMO=1`):
/// plays a realistic ~41 GB session in ~35 s, exercising every popover state.
/// Deterministic — no randomness — so screenshots are reproducible.
final class DemoEngine: EngineControlling, @unchecked Sendable {
    private var continuation: AsyncStream<EngineEvent>.Continuation!
    let events: AsyncStream<EngineEvent>
    private var scriptTask: Task<Void, Never>?
    private var paused = false

    init() {
        var cont: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    private func emit(_ e: EngineEvent) { continuation.yield(e) }

    func start() {
        scriptTask = Task { [weak self] in
            await self?.runScript()
        }
    }

    private func runScript() async {
        let card = CardInfo(volumeUUID: "DEMO-UUID", bsdName: "disk9s1", mountPath: "/Volumes/DEMO-A7IV",
                            volumeName: "A7IV-1", capacityBytes: 128 << 30, freeBytes: 84 << 30, hasDCIM: true)
        emit(.nasGlance(NASGlance(mounted: true, healthy: true,
                                  freeBytes: 2_100_000_000_000, totalBytes: 8_000_000_000_000,
                                  photoCount: 38_412, photoBytes: 1_320_000_000_000)))
        try? await Task.sleep(for: .seconds(1))

        emit(.cardMounted(card))
        emit(.sessionStarted(sessionID: UUID(), card: card, resumed: false))
        emit(.phase(.scanning))
        try? await Task.sleep(for: .seconds(1.5))

        let totalBytes: Int64 = 41_200_000_000
        let totalFiles = 412
        emit(.planned(files: totalFiles, bytes: totalBytes))
        emit(.phase(.transferring))

        let hop1Duration = 22.0   // SD read finishes first…
        let hop2Duration = 33.0   // …NAS write drains behind it (pipelined)
        let dt = 0.1
        var t = 0.0
        var lastSample = 0.0
        while t < hop2Duration {
            if Task.isCancelled { return }
            while paused { try? await Task.sleep(for: .milliseconds(100)) }
            t += dt

            let h1 = min(1.0, t / hop1Duration)
            let h2 = min(1.0, max(0, t - 1.5) / (hop2Duration - 1.5))
            var snap = ProgressSnapshot()
            snap.hop1BytesTotal = totalBytes
            snap.hop2BytesTotal = totalBytes
            snap.hop1BytesDone = Int64(Double(totalBytes) * h1)
            snap.hop2BytesDone = Int64(Double(totalBytes) * h2)
            snap.filesTotal = totalFiles
            snap.filesSettled = Int(Double(totalFiles) * h2)
            snap.currentFileName = h1 < 1 ? String(format: "DSC%05d.ARW", 4000 + Int(Double(totalFiles) * h1)) : nil
            // Gentle deterministic wobble so the sparkline looks alive.
            let wobble1 = 1 + 0.12 * sin(t * 1.7)
            let wobble2 = 1 + 0.09 * sin(t * 1.1 + 1.3)
            snap.sdReadBps = h1 < 1 ? (Double(totalBytes) / hop1Duration) * wobble1 : 0
            snap.nasWriteBps = (Double(totalBytes) / hop2Duration) * wobble2
            snap.etaCardFree = max(0, hop1Duration - t) + 4
            snap.etaAllSafe = max(0, hop2Duration - t) + 2
            emit(.progress(snap))

            if t - lastSample >= 1.0 {
                lastSample = t
                emit(.speedSample(SpeedSample(t: t, sdReadBps: snap.sdReadBps ?? 0,
                                              nasWriteBps: snap.nasWriteBps ?? 0)))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        emit(.phase(.wipeCountdown))
        for s in stride(from: 5, through: 1, by: -1) {
            emit(.wipeCountdown(secondsRemaining: s))
            try? await Task.sleep(for: .seconds(1))
        }
        emit(.phase(.wiping))
        try? await Task.sleep(for: .seconds(1.2))
        emit(.phase(.ejecting))
        try? await Task.sleep(for: .seconds(0.8))

        var record = SessionRecord(cardVolumeUUID: card.volumeUUID, cardVolumeName: card.volumeName,
                                   cardCapacityBytes: card.capacityBytes)
        record.state = .done
        record.endedAt = Date()
        record.stats.filesPlanned = totalFiles
        record.stats.bytesPlanned = totalBytes
        record.stats.bytesRead = totalBytes
        record.stats.bytesUploaded = totalBytes
        record.stats.filesNASVerified = totalFiles
        record.stats.filesWiped = totalFiles
        record.stats.avgSDReadBps = Double(totalBytes) / hop1Duration
        record.stats.avgNASWriteBps = Double(totalBytes) / hop2Duration
        emit(.completed(record))
        emit(.safeToRemove(cardName: card.volumeName))
        emit(.phase(.done))
    }

    func consentToIngest(cardUUID: String, remember: CardPolicy?) {}
    func declineIngest(cardUUID: String, remember: CardPolicy?) {}
    func pause() { paused = true; emit(.phase(.pausedByUser)) }
    func resume() { paused = false; emit(.phase(.transferring)) }
    func cancel() { scriptTask?.cancel(); emit(.phase(.cancelled)) }
    func confirmWipe() {}
    func cancelWipe() { emit(.phase(.transferring)) }
    func eject() {}
    func retry() {}
    func refreshNASGlance() {
        emit(.nasGlance(NASGlance(mounted: true, healthy: true,
                                  freeBytes: 2_100_000_000_000, totalBytes: 8_000_000_000_000,
                                  photoCount: 38_412, photoBytes: 1_320_000_000_000)))
    }
}
