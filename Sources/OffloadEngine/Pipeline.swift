import Foundation
import OffloadCore

/// Tiny actor channel: unbounded in item count (backpressure is byte-based via
/// StagingBudget, not count-based). `receive()` returns nil after `finish()`
/// drains.
public actor AsyncQueue<T: Sendable> {
    private var buffer: [T] = []
    private var receivers: [CheckedContinuation<T?, Never>] = []
    private var finished = false

    public init() {}

    public func send(_ item: T) {
        guard !finished else { return }
        if !receivers.isEmpty {
            receivers.removeFirst().resume(returning: item)
        } else {
            buffer.append(item)
        }
    }

    public func finish() {
        finished = true
        for receiver in receivers { receiver.resume(returning: nil) }
        receivers.removeAll()
    }

    public func receive() async -> T? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { receivers.append($0) }
    }
}

/// Pause gate. Workers `await whenOpen()` between chunks — pause latency is
/// one chunk (≤ ~30 ms at 8 MiB).
public actor Gate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func close() { isOpen = false }

    public func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    public func whenOpen() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Byte-reservation backpressure for staging. Subsumes "batch mode": when the
/// card is bigger than the budget, hop 1 naturally stalls until hop 2
/// verifies-and-purges — continuous, adaptive, one mechanism.
public actor StagingBudget {
    private let stagingPath: String
    private let capBytes: Int64
    private let headroomBytes: Int64
    private var committed: Int64 = 0
    private var reserved: [UUID: Int64] = [:]   // keyed so release balances reserve exactly
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var draining = false

    public init(stagingPath: String, capBytes: Int64, headroomBytes: Int64) {
        self.stagingPath = stagingPath
        self.capBytes = capBytes
        self.headroomBytes = headroomBytes
    }

    /// Reserve for a specific file. Idempotent per id (re-reserving replaces the
    /// prior amount). Returns early without reserving if the session is draining.
    public func reserve(_ id: UUID, _ bytes: Int64) async {
        if let old = reserved[id] { committed = max(0, committed - old); reserved[id] = nil }
        while !draining && !canReserve(bytes) {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard !draining else { return }
        committed += bytes
        reserved[id] = bytes
    }

    /// Release a file's reservation. No-op if it was never reserved (e.g. a file
    /// preloaded on resume) — so accounting never goes negative or double-counts.
    public func release(_ id: UUID) {
        guard let bytes = reserved.removeValue(forKey: id) else { return }
        committed = max(0, committed - bytes)
        wakeWaiters()
    }

    /// Session ending (or card removed): unblock everything parked in reserve()
    /// so cancelled workers can exit instead of leaking a suspended continuation.
    public func drain() {
        draining = true
        wakeWaiters()
    }

    /// Card re-inserted: allow reservations again after a drain().
    public func resumeReservations() {
        draining = false
    }

    private func wakeWaiters() {
        let woken = waiters
        waiters.removeAll()
        for waiter in woken { waiter.resume() }
    }

    public var committedBytes: Int64 { committed }

    private func canReserve(_ bytes: Int64) -> Bool {
        // Oversized-file exception: a file bigger than the whole budget gets
        // the budget to itself (otherwise it could never transfer).
        if bytes >= capBytes { return committed == 0 }
        guard committed + bytes <= capBytes else { return false }
        if let fs = statfsInfo(path: stagingPath) {
            return fs.freeBytes - bytes >= headroomBytes
        }
        return true
    }
}
