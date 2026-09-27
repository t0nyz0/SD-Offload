import Foundation

/// Snapshot synchronous enumeration callbacks before publishing their result.
final class LibraryCountAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, Int64) = (0, 0)
    func update(_ count: Int, _ bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        value = (count, bytes)
    }
    func snapshot() -> (Int, Int64) {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
