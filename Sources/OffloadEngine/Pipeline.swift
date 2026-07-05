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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(stagingPath: String, capBytes: Int64, headroomBytes: Int64) {
        self.stagingPath = stagingPath
        self.capBytes = capBytes
        self.headroomBytes = headroomBytes
    }

    public func reserve(_ bytes: Int64) async {
        while !canReserve(bytes) {
            await withCheckedContinuation { waiters.append($0) }
        }
        committed += bytes
    }

    public func release(_ bytes: Int64) {
        committed = max(0, committed - bytes)
        let woken = waiters
        waiters.removeAll()
        for waiter in woken { waiter.resume() }   // each re-checks in its reserve() loop
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
