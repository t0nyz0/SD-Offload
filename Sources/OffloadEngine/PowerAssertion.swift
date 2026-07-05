import Foundation

/// RAII wrapper: the Mac must not idle-sleep mid-transfer.
public final class PowerAssertion: @unchecked Sendable {
    private var activity: NSObjectProtocol?
    private let lock = NSLock()

    public init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: reason
        )
    }

    public func end() {
        lock.lock(); defer { lock.unlock() }
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit { end() }
}
