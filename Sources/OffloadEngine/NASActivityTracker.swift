import Foundation

/// Tracks slow metadata/flush operations that byte counters cannot explain.
final class NASActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: (label: String, started: TimeInterval)] = [:]

    func set(_ id: UUID, _ label: String?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard let label else { active[id] = nil; return }
        if active[id]?.label != label { active[id] = (label, now) }
    }

    func detail(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let oldest = active.values.min(by: { $0.started < $1.started }),
              now - oldest.started >= 3 else { return nil }
        return "\(oldest.label) · \(Int(now - oldest.started))s"
    }

    func copyPhase(_ phase: ChunkedIO.CopyPhase, file: UUID) {
        switch phase {
        case .openingDestination: set(file, "Waiting for NAS to open a file")
        case .writing: set(file, nil)
        case .flushing: set(file, "Waiting for NAS to finish saving")
        }
    }
}
