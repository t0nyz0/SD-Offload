import Foundation

/// Persisted failure taxonomy. Anything that blocks the wipe names the file and
/// surfaces loudly; anything that auto-heals leaves a journal trace.
public enum TransferFailure: Codable, Equatable, Sendable {
    case ioError(errno: Int32, stage: String)
    case hashMismatch(stage: String)
    case sourceMissing
    case sourceChangedDuringCopy
    case destinationUnwritable(String)
    case nasUnavailable
    case stagingFull
    case cancelled
    case internalError(String)

    public var summary: String {
        switch self {
        case .ioError(let errno, let stage):
            return "I/O error during \(stage) (\(String(cString: strerror(errno))))"
        case .hashMismatch(let stage):
            return "Checksum mismatch during \(stage)"
        case .sourceMissing:
            return "File disappeared from the card"
        case .sourceChangedDuringCopy:
            return "File changed on the card during transfer"
        case .destinationUnwritable(let why):
            return "Can't write to destination: \(why)"
        case .nasUnavailable:
            return "NAS unavailable"
        case .stagingFull:
            return "Local staging is full"
        case .cancelled:
            return "Cancelled"
        case .internalError(let why):
            return "Internal error: \(why)"
        }
    }
}

public struct OffloadError: Error, CustomStringConvertible {
    public let failure: TransferFailure
    public init(_ failure: TransferFailure) { self.failure = failure }
    public var description: String { failure.summary }

    public static func posix(_ err: Int32, stage: String) -> OffloadError {
        OffloadError(.ioError(errno: err, stage: stage))
    }
}
