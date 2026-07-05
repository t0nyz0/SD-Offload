import SwiftUI

/// Offload's "instrument-grade" design system.
///
/// One idea runs through everything: the **verification gradient**. Data heats
/// up while it moves (amber) and cools to proven-safe (emerald) once it's
/// verified on the NAS. Amber and green are not two accents competing — they're
/// the two ends of one meaningful ramp, and it appears identically in the app
/// icon, the menu bar fill, and the popover gauge.
enum DS {

    // MARK: - Palette (graphite, cool-biased neutrals — chosen, not defaulted)

    enum Palette {
        static let ink        = Color(hex: 0x0E0F13)   // near-black base
        static let surface    = Color(hex: 0x16181D)
        static let surfaceRaised = Color(hex: 0x1E2127)
        static let hairline   = Color(hex: 0x2A2E37)

        static let textPrimary   = Color(hex: 0xF2F4F8)
        static let textSecondary = Color(hex: 0x9BA1AD)
        static let textTertiary  = Color(hex: 0x5E6472)

        // The verification gradient endpoints.
        static let motion     = Color(hex: 0xF5A524)   // in motion (amber/gold)
        static let motionHot  = Color(hex: 0xFF8A3D)   // leading edge (warmer)
        static let verified   = Color(hex: 0x34D399)   // proven safe (emerald)
        static let verifiedDeep = Color(hex: 0x2BB673)

        static let danger     = Color(hex: 0xFF5D5D)   // attention only
        static let info       = Color(hex: 0x5AA9FF)
    }

    // MARK: - Semantic (what the UI asks for)

    /// "In motion" — hop-1 read, progress fills, live activity.
    static let motion = Palette.motion
    /// "Verified safe" — hop-2 confirmed, done state, safe-to-remove.
    static let safe = Palette.verified
    static let danger = Palette.danger
    static let info = Palette.info

    // MARK: - Gradients

    /// The card-gauge fill: emerald at the base (already-verified feeling)
    /// rising into amber at the leading edge (active).
    static let verificationFill = LinearGradient(
        colors: [Palette.verifiedDeep, Palette.verified, Palette.motion, Palette.motionHot],
        startPoint: .bottom, endPoint: .top
    )

    static let motionBar = LinearGradient(
        colors: [Palette.motion.opacity(0.85), Palette.motionHot],
        startPoint: .leading, endPoint: .trailing
    )

    static let safeBar = LinearGradient(
        colors: [Palette.verifiedDeep, Palette.verified],
        startPoint: .leading, endPoint: .trailing
    )

    /// A machined-graphite plate wash for hero surfaces.
    static let plate = LinearGradient(
        colors: [Palette.surfaceRaised, Palette.surface],
        startPoint: .top, endPoint: .bottom
    )

    // MARK: - Spacing (8pt rhythm)

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let pill: CGFloat = 999
    }

    // MARK: - Type scale (SF Pro; rounded tabular for instrument readouts)

    enum Typo {
        static let readout = Font.system(size: 34, weight: .bold, design: .rounded)
        static let readoutSmall = Font.system(size: 22, weight: .semibold, design: .rounded)
        static let title = Font.system(size: 15, weight: .semibold)
        static let headline = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 12, weight: .regular)
        static let caption = Font.system(size: 11, weight: .regular)
        static let micro = Font.system(size: 10.5, weight: .medium)
        /// Uppercase telemetry labels.
        static let label = Font.system(size: 9.5, weight: .bold)
    }
}

// MARK: - Reusable surfaces

extension View {
    /// A raised inset card with hairline stroke — the panel unit of the popover.
    func dsPanel(padding: CGFloat = DS.Space.m) -> some View {
        self
            .padding(padding)
            .background(DS.Palette.surfaceRaised.opacity(0.5), in: RoundedRectangle(cornerRadius: DS.Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m)
                    .strokeBorder(DS.Palette.hairline.opacity(0.6), lineWidth: 1)
            )
    }

    /// Uppercase telemetry label with tracked letters.
    func dsLabel() -> some View {
        self.font(DS.Typo.label)
            .tracking(0.8)
            .foregroundStyle(DS.Palette.textTertiary)
    }
}

// MARK: - Status dot

struct StatusDot: View {
    enum State { case good, warn, off }
    let state: State
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().fill(color).blur(radius: 3).opacity(state == .good ? 0.6 : 0))
    }

    private var color: Color {
        switch state {
        case .good: DS.safe
        case .warn: DS.motion
        case .off: DS.Palette.textTertiary.opacity(0.5)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
