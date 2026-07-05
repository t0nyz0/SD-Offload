import Foundation

/// The single source of truth for the menu bar label. Recomputed ≤ ~1 Hz with
/// set-if-changed so the label render stays off the engine's hot path.
enum MenuBarState: Equatable {
    case idle
    case scanning
    case transferring(Int)
    case verifying(Int)
    case uploading(Int)     // card already free, NAS leg still draining
    case paused(Int)
    case doneFlash
    case attention

    var symbolName: String {
        switch self {
        case .idle: "sdcard"
        case .scanning: "sdcard.fill"
        case .transferring: "sdcard.fill"
        case .verifying: "checkmark.shield"
        case .uploading: "externaldrive"
        case .paused: "pause.circle"
        case .doneFlash: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    var percent: Int? {
        switch self {
        case .transferring(let p), .verifying(let p), .uploading(let p), .paused(let p):
            min(100, max(0, p))
        default:
            nil
        }
    }

    var isIdle: Bool { self == .idle }

    /// Fixed-width percent: FIGURE SPACE (U+2007) pads to three digit cells so
    /// the menu bar never jitters as digits change ("  7%" → " 47%" → "100%").
    static func percentText(_ pct: Int) -> String {
        let s = String(min(100, max(0, pct)))
        return String(repeating: "\u{2007}", count: max(0, 3 - s.count)) + s + "%"
    }

    var accessibilityText: String {
        switch self {
        case .idle: "SD Offload: waiting for a card"
        case .scanning: "SD Offload: card detected, scanning"
        case .transferring(let p): "SD Offload: transferring, \(p) percent"
        case .verifying(let p): "SD Offload: verifying, \(p) percent"
        case .uploading(let p): "SD Offload: uploading to NAS, \(p) percent, card is free"
        case .paused(let p): "SD Offload: paused at \(p) percent"
        case .doneFlash: "SD Offload: card offloaded"
        case .attention: "SD Offload: needs attention"
        }
    }
}
