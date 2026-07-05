import Foundation
import OffloadCore

/// Decides whether a mounted volume is a camera card and what to do with it.
/// Never classifies by device protocol string (the built-in reader on this
/// machine reports "USB"): removable/ejectable/external + DCIM + remembered
/// per-UUID policy, plus a name allowlist for test DMGs.
public enum CardClassifier {
    public enum Classification: Equatable, Sendable {
        case ingest      // remembered alwaysIngest
        case ask         // camera card, no remembered decision
        case ignore
    }

    public static func classify(_ volume: CandidateVolume, config: AppConfig) -> Classification {
        // Network shares are never cards (and the NAS itself must never classify).
        guard !volume.isNetwork else { return .ignore }

        let allowlisted = config.testVolumeAllowlist.contains {
            volume.info.volumeName.hasPrefix($0)
        }

        // Physically card-like: removable OR ejectable OR an external device.
        let cardLike = volume.isRemovable || volume.isEjectable || !volume.isInternal
        guard allowlisted || (cardLike && volume.info.hasMediaRoot) else { return .ignore }

        switch config.cardPolicies[volume.info.volumeUUID] {
        case .alwaysIngest: return .ingest
        case .ignore: return .ignore
        case .ask, .none: return .ask
        }
    }
}
