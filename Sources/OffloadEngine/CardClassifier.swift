import Foundation
import OffloadCore

/// Decides whether a mounted volume is a camera card and what to do with it.
/// Never classifies by device protocol string (the built-in reader on this
/// machine reports "USB"): removable/ejectable/external + a media root (DCIM etc.),
/// plus a name allowlist for test DMGs. The action for a camera card comes from ONE
/// global setting (`defaultCardAction`) — there is no per-card memory.
public enum CardClassifier {
    public enum Classification: Equatable, Sendable {
        case ingest      // global setting: offload automatically
        case ask         // global setting: prompt this insert
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

        switch config.defaultCardAction {
        case .alwaysIngest: return .ingest
        case .ignore: return .ignore
        case .ask: return .ask
        }
    }
}
