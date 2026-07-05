import Foundation

/// Pure math for speeds and ETAs — no clocks, no IO, fully unit-testable.

/// Time-correct exponentially weighted moving average:
/// alpha = 1 − e^(−dt/tau), so jittery sampling intervals stay honest.
public struct EWMA: Sendable {
    public private(set) var value: Double?
    public let tau: Double

    public init(tau: Double) { self.tau = tau }

    public mutating func add(sample: Double, dt: Double) {
        guard dt > 0 else { return }
        let alpha = 1 - exp(-dt / tau)
        if let v = value {
            value = v + alpha * (sample - v)
        } else {
            value = sample
        }
    }

    public mutating func reset() { value = nil }
}

/// Learns the per-file fixed cost (open/close/fsync/rename/SMB round-trips)
/// that keeps many-small-file ETAs honest.
public struct OverheadModel: Sendable {
    public private(set) var seconds: Double
    private let gain = 0.2

    public init(seed: Double) { self.seconds = seed }

    /// Observe a completed file: wall time `w`, size `z`, current stage rate `r`.
    /// Overhead o = max(0, w − z/r); c ← c + gain·(o − c).
    public mutating func observe(fileWall w: Double, size z: Int64, rate r: Double?) {
        guard w > 0, let r, r > 0 else { return }
        let o = max(0, w - Double(z) / r)
        seconds += gain * (o - seconds)
    }
}

public enum ETAMath {
    /// Remaining time for one stage:
    ///   R = B/r + N·c/W
    /// where B = remaining bytes (minus in-flight partial progress),
    /// N = remaining files, c = per-file overhead, W = workers.
    /// Returns nil until the stage rate is warm.
    public static func stageRemaining(bytesRemaining: Int64, filesRemaining: Int,
                                      rate: Double?, overheadSeconds: Double,
                                      workers: Int) -> TimeInterval? {
        guard bytesRemaining > 0 || filesRemaining > 0 else { return 0 }
        guard let rate, rate > 0 else { return nil }
        let byteTerm = Double(bytesRemaining) / rate
        let overheadTerm = Double(filesRemaining) * overheadSeconds / Double(max(1, workers))
        return byteTerm + overheadTerm
    }

    /// Pipelined stages overlap: total ≈ max(stage remainings) + last-file tail.
    /// Any unwarm stage with remaining work makes the whole ETA nil ("estimating…").
    public static func pipelineETA(stages: [TimeInterval?], tail: TimeInterval) -> TimeInterval? {
        var maxR: TimeInterval = 0
        for s in stages {
            guard let s else { return nil }
            maxR = max(maxR, s)
        }
        return maxR + tail
    }

    /// A photo-card offload legitimately runs from minutes to a few hours; a value
    /// beyond a few days means a rate estimate collapsed (a stage went briefly
    /// idle and its EWMA decayed toward zero, so B/rate exploded). Rather than
    /// surface a nonsense "53446:21:00", treat such a value — and any non-finite
    /// or negative one — as "estimating…" (nil). Feeding nil to the display
    /// smoother also resets it, so a single spike can't bleed into later frames.
    public static func clampETA(_ eta: TimeInterval?, max maxSane: TimeInterval = 72 * 3600) -> TimeInterval? {
        guard let eta, eta.isFinite, eta >= 0, eta <= maxSane else { return nil }
        return eta
    }

    /// Warm-up gate: a stage's rate is trustworthy after ≥ minSeconds of samples
    /// AND (≥ minBytes observed OR ≥ minFiles completed).
    public static func isWarm(sampledSeconds: Double, bytesObserved: Int64, filesObserved: Int,
                              minSeconds: Double = 2, minBytes: Int64 = 16 << 20, minFiles: Int = 3) -> Bool {
        sampledSeconds >= minSeconds && (bytesObserved >= minBytes || filesObserved >= minFiles)
    }

    /// Downsample a 10 Hz timeline into ≤ maxBuckets samples, preserving means
    /// per bucket (peaks folded into the stored mean stream separately by caller).
    public static func downsample(_ samples: [SpeedSample], maxBuckets: Int = 600) -> [SpeedSample] {
        guard samples.count > maxBuckets, maxBuckets > 0 else { return samples }
        let bucketSize = Int(ceil(Double(samples.count) / Double(maxBuckets)))
        var out: [SpeedSample] = []
        out.reserveCapacity(maxBuckets)
        var i = 0
        while i < samples.count {
            let slice = samples[i..<min(i + bucketSize, samples.count)]
            var sdSum = 0.0
            var nasSum = 0.0
            for s in slice {
                sdSum += s.sdReadBps
                nasSum += s.nasWriteBps
            }
            let n = Double(slice.count)
            out.append(SpeedSample(t: slice.first!.t, sdReadBps: sdSum / n, nasWriteBps: nasSum / n))
            i += bucketSize
        }
        return out
    }
}
