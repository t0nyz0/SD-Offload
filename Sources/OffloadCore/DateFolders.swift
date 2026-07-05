import Foundation

/// Interprets a NAS date-folder path (`YYYY/MM/DD`) into human-readable labels,
/// so the Library can show "Saturday, July 4th, 2026" instead of a bare "04".
/// Pure, locale-aware, and unit-tested. Non-date folders (e.g. a card's DCIM
/// subfolders) fall back to their raw name.
public enum DateFolders {
    public struct Caption: Sendable, Equatable {
        public let title: String       // card title: "2026" / "July" / "Jul 4"
        public let subtitle: String?   // "2026" (month) / "Saturday" (day)
        public init(title: String, subtitle: String?) { self.title = title; self.subtitle = subtitle }
    }

    /// Path components of `folderPath` relative to `rootPath` ([] if it *is* the
    /// root or isn't under it).
    public static func relComponents(_ folderPath: String, root rootPath: String) -> [String] {
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let f = folderPath.hasSuffix("/") ? String(folderPath.dropLast()) : folderPath
        guard f != root else { return [] }
        let prefix = root + "/"
        guard f.hasPrefix(prefix) else { return [] }
        return f.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    /// Parse a `[YYYY]`, `[YYYY,MM]`, or `[YYYY,MM,DD]` component list into a Date
    /// (nil if it doesn't look like a date folder).
    static func date(from comps: [String]) -> Date? {
        guard (1...3).contains(comps.count),
              comps[0].count == 4, let y = Int(comps[0]), (1900...3000).contains(y) else { return nil }
        var dc = DateComponents()
        dc.year = y
        if comps.count >= 2 {
            guard comps[1].count <= 2, let m = Int(comps[1]), (1...12).contains(m) else { return nil }
            dc.month = m
        } else { dc.month = 1 }
        if comps.count >= 3 {
            guard comps[2].count <= 2, let d = Int(comps[2]), (1...31).contains(d) else { return nil }
            dc.day = d
        } else { dc.day = 1 }
        return Calendar.current.date(from: dc)
    }

    private static func formatted(_ template: String, _ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// A compact caption for a folder card.
    public static func caption(folderPath: String, rootPath: String, rawName: String) -> Caption {
        let comps = relComponents(folderPath, root: rootPath)
        guard let d = date(from: comps) else { return Caption(title: rawName, subtitle: nil) }
        switch comps.count {
        case 1:  return Caption(title: comps[0], subtitle: nil)                       // 2026
        case 2:  return Caption(title: formatted("LLLL", d), subtitle: comps[0])      // July · 2026
        default: return Caption(title: formatted("MMMd", d), subtitle: formatted("EEEE", d)) // Jul 4 · Saturday
        }
    }

    /// The full header label for the currently-open folder, or nil if it isn't a
    /// date folder. Day → "Saturday, July 4th, 2026"; month → "July 2026"; year → "2026".
    public static func headerLabel(folderPath: String, rootPath: String) -> String? {
        let comps = relComponents(folderPath, root: rootPath)
        guard let d = date(from: comps) else { return nil }
        switch comps.count {
        case 1:  return comps[0]
        case 2:  return formatted("yyyyLLLL", d)                                       // July 2026
        default: return "\(formatted("EEEE", d)), \(formatted("LLLL", d)) \(ordinalDay(d)), \(comps[0])"
        }
    }

    static func ordinalDay(_ date: Date) -> String {
        let day = Calendar.current.component(.day, from: date)
        let nf = NumberFormatter()
        nf.numberStyle = .ordinal
        nf.locale = .current
        return nf.string(from: NSNumber(value: day)) ?? "\(day)"
    }
}
