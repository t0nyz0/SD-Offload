import Foundation
import OffloadCore

public struct VerificationProgress: Sendable, Equatable {
    public var label: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var filesDone: Int
    public var filesTotal: Int
    public var currentFile: String?
    public var activeFiles: Int
    public var bytesPerSecond: Double?
    public var secondsWithoutProgress: TimeInterval
    public init(label: String, bytesDone: Int64, bytesTotal: Int64, filesDone: Int, filesTotal: Int,
                currentFile: String?, activeFiles: Int, bytesPerSecond: Double?, secondsWithoutProgress: TimeInterval) {
        self.label = label; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        self.filesDone = filesDone; self.filesTotal = filesTotal; self.currentFile = currentFile
        self.activeFiles = activeFiles; self.bytesPerSecond = bytesPerSecond; self.secondsWithoutProgress = secondsWithoutProgress
    }
    public var fraction: Double { bytesTotal > 0 ? min(filesDone == filesTotal ? 1 : 0.999, Double(bytesDone) / Double(bytesTotal)) : 0 }
    public var eta: TimeInterval? {
        guard secondsWithoutProgress < 10, let rate = bytesPerSecond, rate > 0, bytesDone < bytesTotal else { return nil }
        return Double(bytesTotal - bytesDone) / rate
    }
}

/// Chunk callbacks update counters only. Formatting and events stay on the sampler.
final class VerificationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var label = "Checking NAS copies"
    private var sizes: [UUID: Int64] = [:]
    private var progress: [UUID: Int64] = [:]
    private var complete: Set<UUID> = []
    private var active: [UUID: String] = [:]
    private var total: Int64 = 0, done: Int64 = 0, observed: Int64 = 0, previousObserved: Int64 = 0
    private var lastActivity = Date(), lastSample = Date(), started = Date()
    private var rate: Double = 0

    func reset(files: [FileRecord], label: String, acceptingRecorded: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.label = label; sizes = [:]; progress = [:]; complete = []; active = [:]
        total = 0; done = 0; observed = 0; previousObserved = 0; rate = 0
        lastActivity = Date(); lastSample = lastActivity; started = lastActivity
        for file in files {
            sizes[file.id] = file.size; total += file.size
            if acceptingRecorded && file.state.recordsNASVerification {
                progress[file.id] = file.size; done += file.size; complete.insert(file.id)
            }
        }
    }
    func begin(_ file: FileRecord) {
        lock.lock(); defer { lock.unlock() }
        done -= progress[file.id] ?? 0; progress[file.id] = 0
        complete.remove(file.id); active[file.id] = file.fileName; lastActivity = Date()
    }
    func add(_ bytes: Int, file: UUID) {
        lock.lock(); defer { lock.unlock() }
        let before = progress[file] ?? 0
        let after = min(sizes[file] ?? 0, before + Int64(bytes))
        progress[file] = after; done += after - before; observed += Int64(bytes); lastActivity = Date()
    }
    func finish(_ file: FileRecord, verified: Bool) {
        lock.lock(); defer { lock.unlock() }
        active[file.id] = nil
        if verified {
            done += file.size - (progress[file.id] ?? 0); progress[file.id] = file.size; complete.insert(file.id)
        } else {
            done -= progress[file.id] ?? 0; progress[file.id] = 0; complete.remove(file.id)
        }
        lastActivity = Date()
    }
    func snapshot(now: Date = Date()) -> VerificationProgress {
        lock.lock(); defer { lock.unlock() }
        let dt = now.timeIntervalSince(lastSample)
        if dt > 0 {
            let sample = Double(observed - previousObserved) / dt
            let alpha = 1 - exp(-dt / 2)
            rate += alpha * (sample - rate)
            previousObserved = observed; lastSample = now
        }
        return VerificationProgress(label: label, bytesDone: done, bytesTotal: total, filesDone: complete.count,
                                    filesTotal: sizes.count, currentFile: active.values.sorted().first,
                                    activeFiles: active.count, bytesPerSecond: now.timeIntervalSince(started) >= 1 && observed > 0 ? rate : nil,
                                    secondsWithoutProgress: max(0, now.timeIntervalSince(lastActivity)))
    }
}
