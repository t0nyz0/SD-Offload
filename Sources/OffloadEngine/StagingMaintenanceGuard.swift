import Foundation

/// A transfer reserves this guard before its first suspension. Maintenance only
/// holds the lock for local unlinks, never while reading a card or NAS.
final class StagingMaintenanceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false

    func setBusy(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        busy = value
    }

    var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return !busy
    }

    @discardableResult
    func whileIdle(_ action: () throws -> Bool) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy else { return false }
        return try action()
    }
}
