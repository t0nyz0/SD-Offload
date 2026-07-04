import SwiftUI

/// Two accents only: amber = data in motion, green = verified safe on the NAS.
/// Everything else is system materials so the popover follows light/dark.
enum Theme {
    static let accent = Color(red: 0.93, green: 0.62, blue: 0.18)
    static let safe = Color(red: 0.30, green: 0.72, blue: 0.38)

    static let accentGradient = LinearGradient(
        colors: [accent.opacity(0.7), accent],
        startPoint: .bottom, endPoint: .top
    )
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file))
    }

    static func speed(_ bps: Double?) -> String {
        guard let bps, bps > 0 else { return "—" }
        if bps >= 995_000 { return String(format: "%.0f MB/s", bps / 1_000_000) }
        return String(format: "%.0f KB/s", bps / 1_000)
    }

    /// "~2:40" (10 s rounding above a minute), "~40s" below, "~1:12:00" above an hour.
    static func eta(_ t: TimeInterval?) -> String? {
        guard var t else { return nil }
        t = max(0, t)
        if t >= 3600 {
            let rounded = (t / 60).rounded() * 60
            let h = Int(rounded) / 3600
            let m = (Int(rounded) % 3600) / 60
            return String(format: "~%d:%02d:00", h, m)
        }
        if t >= 60 {
            let rounded = (t / 10).rounded() * 10
            return String(format: "~%d:%02d", Int(rounded) / 60, Int(rounded) % 60)
        }
        return "~\(Int(t.rounded()))s"
    }

    static func duration(_ t: TimeInterval) -> String {
        let ti = Int(t.rounded())
        if ti >= 3600 { return String(format: "%dh %02dm", ti / 3600, (ti % 3600) / 60) }
        if ti >= 60 { return String(format: "%dm %02ds", ti / 60, ti % 60) }
        return "\(ti)s"
    }
}
