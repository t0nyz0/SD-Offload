import Foundation

extension FileState {
    /// Historical evidence only, never a claim about present-day destination health.
    public var historyResult: String {
        switch self {
        case .pending: return "Not transferred"
        case .copying: return "Copy to staging incomplete"
        case .staged: return "Staged — not verified"
        case .stagedVerified: return "Local copy verified — NAS not verified"
        case .uploading: return "NAS upload incomplete"
        case .uploaded: return "Uploaded — NAS verification incomplete"
        case .nasVerified: return "NAS verified at transfer"
        case .skippedDuplicate: return "Existing NAS copy verified — duplicate skipped"
        case .wiped: return "NAS verified at transfer — erased from card"
        case .failed(let failure): return "Failed — \(failure.summary)"
        }
    }

    public var recordsNASVerification: Bool {
        switch self {
        case .nasVerified, .skippedDuplicate, .wiped: return true
        default: return false
        }
    }
}
