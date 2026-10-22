import Foundation
import OffloadCore

/// Decides whether a mounted volume is a camera card and what to do with it.
/// USB readers remain eligible: removable/ejectable/external + a media root (DCIM etc.).
/// Disk images require the explicit name allowlist for test DMGs. The action comes from ONE
/// global setting (`defaultCardAction`) — there is no per-card memory.
public enum CardClassifier {
    /// macOS reports simulator runtime images as removable, ejectable and external.
    /// Those flags alone cannot distinguish them from a physical camera card.
    static func isDiskImage(deviceProtocol: String?, deviceModel: String? = nil) -> Bool {
        // Disk Arbitration exposes APFS simulator images with protocol "Virtual
        // Interface" and model "Disk Image". diskutil's resolved bus protocol
        // differs, so check both direct description fields.
        [deviceProtocol, deviceModel].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Disk Image") == .orderedSame
        }
    }

    public enum Classification: Equatable, Sendable {
        case ingest      // global setting: offload automatically
        case ask         // global setting: prompt this insert
        case ignore
    }

    public static func classify(_ volume: CandidateVolume, config: AppConfig) -> Classification {
        // Network shares are never cards (and the NAS itself must never classify).
        guard !volume.isNetwork else { return .ignore }

        let allowlisted = config.testVolumeAllowlist.contains {
            !$0.isEmpty && volume.info.volumeName.hasPrefix($0)
        }

        guard !volume.isDiskImage || allowlisted else { return .ignore }

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
