import Foundation

/// errno classification + backoff. Anything that auto-heals leaves a journal
/// trace; anything that blocks the wipe surfaces immediately.
enum RetryPolicy {
    static let maxAttempts = 3

    /// 1 s, 4 s, 16 s.
    static func backoffSeconds(attempt: Int) -> Double {
        pow(4, Double(max(0, attempt - 1)))
    }

    static func isTransient(_ err: Int32) -> Bool {
        [EAGAIN, EIO, ETIMEDOUT, ESTALE, ECONNRESET, ENETRESET].contains(err)
    }

    static func isSourceGone(_ err: Int32) -> Bool {
        [ENXIO, ENODEV, ENOENT, ENOTCONN].contains(err)
    }

    static func isDestinationGone(_ err: Int32) -> Bool {
        [ENOTCONN, ENETDOWN, ENETUNREACH, ETIMEDOUT, ESTALE, EIO].contains(err)
    }

    static func isOutOfSpace(_ err: Int32) -> Bool {
        err == ENOSPC || err == EDQUOT
    }
}
