import Foundation
import OffloadCore

/// Tiny actor channel: unbounded in item count (backpressure is byte-based via
/// StagingBudget, not count-based). `receive()` returns nil after `finish()`
/// drains.
public actor AsyncQueue<T: Sendable> {
    private var buffer: [T?] = []
    private var head = 0
    private var receivers: [(UUID, CheckedContinuation<T?, Never>)] = []
    private var finished = false
    public init() {}

    public func send(_ item: T) {
        guard !finished else { return }
        if !receivers.isEmpty { receivers.removeFirst().1.resume(returning: item) }
        else { buffer.append(item) }
    }
    public func finish() {
        finished = true
        for (_, receiver) in receivers { receiver.resume(returning: nil) }
        receivers.removeAll()
    }
    public func receive() async -> T? {
        guard !Task.isCancelled else { return nil }
        if head < buffer.count {
            let item = buffer[head]; buffer[head] = nil; head += 1
            if head >= 1024 && head * 2 >= buffer.count {
                buffer.removeFirst(head); head = 0
            }
            return item
        }
        if finished { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { receivers.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancelReceiver(id) } }
    }
    private func cancelReceiver(_ id: UUID) {
        guard let index = receivers.firstIndex(where: { $0.0 == id }) else { return }
        receivers.remove(at: index).1.resume(returning: nil)
    }
}

/// Pause gate. Workers `await whenOpen()` between chunks — pause latency is
/// one chunk (≤ ~30 ms at 8 MiB).
public actor Gate {
    private var isOpen = true
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    public init() {}
    public func close() { isOpen = false }
    public func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
    public func whenOpen() async {
        guard !isOpen, !Task.isCancelled else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }
}

/// Byte-reservation backpressure for staging. Subsumes "batch mode": when the
/// card is bigger than the budget, hop 1 naturally stalls until hop 2
/// verifies-and-purges — continuous, adaptive, one mechanism.
public actor StagingBudget {
    private let capBytes: Int64
    private let headroomBytes: Int64
    private let availableBytes: @Sendable () -> Int64?
    private var committed: Int64 = 0
    private var reserved: [UUID: Int64] = [:]
    private var draining = false

    public init(stagingPath: String, capBytes: Int64, headroomBytes: Int64,
                availableBytes: (@Sendable () -> Int64?)? = nil) {
        self.capBytes = max(1, capBytes)
        self.headroomBytes = max(0, headroomBytes)
        self.availableBytes = availableBytes ?? { statfsInfo(path: stagingPath)?.freeBytes }
    }
    public func reserve(_ id: UUID, _ bytes: Int64,
                        onWaiting: (@Sendable () -> Void)? = nil) async throws {
        if let old = reserved.removeValue(forKey: id) { committed = max(0, committed - old) }
        var notified = false
        while !canReserve(bytes) {
            try Task.checkCancellation()
            if draining { throw CancellationError() }
            if !notified { onWaiting?(); notified = true }
            // Disk space may change without another worker releasing a reservation.
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
        if draining { throw CancellationError() }
        committed += bytes; reserved[id] = bytes
    }
    public func release(_ id: UUID) {
        if let bytes = reserved.removeValue(forKey: id) { committed = max(0, committed - bytes) }
    }
    public func drain() { draining = true }
    public func resumeReservations() { draining = false }
    public var committedBytes: Int64 { committed }
    private func canReserve(_ bytes: Int64) -> Bool {
        guard bytes >= 0, let free = availableBytes(), free >= headroomBytes,
              committed <= free - headroomBytes,
              bytes <= free - headroomBytes - committed else { return false }
        if bytes >= capBytes { return committed == 0 }
        return bytes <= capBytes - min(capBytes, committed)
    }
}

/// Serializes NAS destination-directory creation so each routed date directory is
/// created once per session even under concurrent hop2 workers. Creation happens
/// inside the actor's critical section, so a second worker can never start a
/// write into a dir the first worker hasn't finished creating.
/// `createDirectory(withIntermediateDirectories: true)` is idempotent, so this
/// is safe even if the dir already exists on the NAS.
public actor NASDirCache {
    private var created: Set<String> = []

    public init() {}

    public func ensure(_ dir: URL) throws {
        if created.contains(dir.path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        created.insert(dir.path)
    }

    /// Forget created dirs (after a destination IO error) so recovery re-creates
    /// a dir that may have vanished with a dropped mount.
    public func reset() { created.removeAll() }
}
