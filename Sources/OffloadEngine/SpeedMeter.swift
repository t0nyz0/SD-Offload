import Foundation
import OffloadCore

/// Lock-protected per-stage byte counters, sampled at 10 Hz into EWMA rates
/// (τ = 5 s) and per-file overhead models. Chunk callbacks land here ~37×/s
/// per worker — an NSLock is invisible at that rate.
public final class SpeedMeter: @unchecked Sendable {
    public enum Stage: Int, CaseIterable, Sendable {
        case sdRead, stagingVerify, nasWrite, nasVerify
    }

    private let lock = NSLock()
    private var bytes = [Int64](repeating: 0, count: 4)
    private var filesDone = [Int](repeating: 0, count: 4)
    private var lastSampleBytes = [Int64](repeating: 0, count: 4)
    private var rates: [EWMA] = (0..<4).map { _ in EWMA(tau: 5) }
    private var overheads: [OverheadModel] = [
        OverheadModel(seed: 0.015),   // sdRead: FSKit-exFAT metadata is not cheap
        OverheadModel(seed: 0.005),   // stagingVerify
        OverheadModel(seed: 0.080),   // nasWrite: SMB create+flush+rename+setinfo
        OverheadModel(seed: 0.040),   // nasVerify
    ]
    private var lastSampleAt: Date?
    private var firstActivityAt: [Date?] = [nil, nil, nil, nil]
    private var peaks = [Double](repeating: 0, count: 4)
    private var displayETACardFree = EWMA(tau: 3)
    private var displayETAAllSafe = EWMA(tau: 3)
    private let startedAt = Date()
    private var timeline: [SpeedSample] = []

    public init() {}

    // MARK: - Feed (from workers)

    public func addBytes(_ n: Int, stage: Stage) {
        lock.lock(); defer { lock.unlock() }
        bytes[stage.rawValue] += Int64(n)
        if firstActivityAt[stage.rawValue] == nil { firstActivityAt[stage.rawValue] = Date() }
    }

    public func fileCompleted(stage: Stage, wall: TimeInterval, size: Int64) {
        lock.lock(); defer { lock.unlock() }
        filesDone[stage.rawValue] += 1
        overheads[stage.rawValue].observe(fileWall: wall, size: size, rate: rates[stage.rawValue].value)
    }

    // MARK: - Sample (10 Hz from the session sampler)

    public func sample(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastSampleAt else {
            lastSampleAt = now
            lastSampleBytes = bytes
            return
        }
        let dt = now.timeIntervalSince(last)
        guard dt > 0 else { return }
        for stage in Stage.allCases {
            let i = stage.rawValue
            let delta = Double(bytes[i] - lastSampleBytes[i])
            let instantaneous = delta / dt
            rates[i].add(sample: instantaneous, dt: dt)
            peaks[i] = max(peaks[i], instantaneous)
        }
        lastSampleAt = now
        lastSampleBytes = bytes
        timeline.append(SpeedSample(t: now.timeIntervalSince(startedAt),
                                    sdReadBps: rates[Stage.sdRead.rawValue].value ?? 0,
                                    nasWriteBps: rates[Stage.nasWrite.rawValue].value ?? 0))
    }

    // MARK: - Read

    /// Warm rate or nil ("estimating…").
    public func rate(_ stage: Stage) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let i = stage.rawValue
        guard let first = firstActivityAt[i] else { return nil }
        let warm = ETAMath.isWarm(sampledSeconds: Date().timeIntervalSince(first),
                                  bytesObserved: bytes[i], filesObserved: filesDone[i])
        return warm ? rates[i].value : nil
    }

    public func overheadSeconds(_ stage: Stage) -> Double {
        lock.lock(); defer { lock.unlock() }
        return overheads[stage.rawValue].seconds
    }

    public func bytesTotal(_ stage: Stage) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return bytes[stage.rawValue]
    }

    /// Display-smoothed ETAs (τ = 3 s) so the headline numbers don't flap.
    public func smoothedETAs(cardFree: TimeInterval?, allSafe: TimeInterval?, dt: TimeInterval) -> (TimeInterval?, TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        if let cardFree { displayETACardFree.add(sample: cardFree, dt: dt) } else { displayETACardFree.reset() }
        if let allSafe { displayETAAllSafe.add(sample: allSafe, dt: dt) } else { displayETAAllSafe.reset() }
        return (displayETACardFree.value, displayETAAllSafe.value)
    }

    public struct Finals: Sendable {
        public let avgSDReadBps: Double
        public let peakSDReadBps: Double
        public let avgNASWriteBps: Double
        public let peakNASWriteBps: Double
        public let timeline: [SpeedSample]
    }

    public func finals() -> Finals {
        lock.lock(); defer { lock.unlock() }
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        return Finals(
            avgSDReadBps: Double(bytes[Stage.sdRead.rawValue]) / elapsed,
            peakSDReadBps: peaks[Stage.sdRead.rawValue],
            avgNASWriteBps: Double(bytes[Stage.nasWrite.rawValue]) / elapsed,
            peakNASWriteBps: peaks[Stage.nasWrite.rawValue],
            timeline: ETAMath.downsample(timeline, maxBuckets: 600)
        )
    }

    public func latestSample() -> SpeedSample? {
        lock.lock(); defer { lock.unlock() }
        return timeline.last
    }
}
