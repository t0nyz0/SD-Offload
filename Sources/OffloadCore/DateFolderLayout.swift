import Foundation

/// A reversible, versioned date-folder pattern. `/` creates folder levels;
/// supported tokens are deliberately small so every generated path can also be
/// parsed during a future library migration.
public struct DateFolderLayout: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Precision: Int, Sendable, Comparable {
        case year = 1, month = 2, day = 3
        public static func < (lhs: Precision, rhs: Precision) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Parsed: Sendable, Equatable {
        public let date: Date
        public let precision: Precision
    }

    public let id: String
    public var name: String
    public var pattern: String

    public init(id: String, name: String, pattern: String) {
        self.id = id
        self.name = name
        self.pattern = pattern
    }

    public static let nestedNumeric = DateFolderLayout(
        id: "nested-numeric", name: "Year / Month / Day", pattern: "{YYYY}/{MM}/{DD}")
    public static let yearISODay = DateFolderLayout(
        id: "year-iso-day", name: "Year / ISO date", pattern: "{YYYY}/{YYYY}-{MM}-{DD}")
    public static let yearCompactDay = DateFolderLayout(
        id: "year-compact-day", name: "Year / Month-Day", pattern: "{YYYY}/{MM}-{DD}")
    public static let flatISO = DateFolderLayout(
        id: "flat-iso", name: "ISO date", pattern: "{YYYY}-{MM}-{DD}")
    public static let flatUnderscore = DateFolderLayout(
        id: "flat-underscore", name: "Underscored date", pattern: "{YYYY}_{MM}_{DD}")
    public static let namedMonth = DateFolderLayout(
        id: "named-month", name: "Year / Named month / Day", pattern: "{YYYY}/{MM} - {MMMM}/{DD}")
    public static let namedFullDate = DateFolderLayout(
        id: "named-full-date", name: "Year / Named month / Full date",
        pattern: "{YYYY}/{MM} - {MMMM}/{YYYY}-{MM}-{DD}")

    public static let presets: [DateFolderLayout] = [
        .nestedNumeric, .yearISODay, .yearCompactDay, .flatISO,
        .flatUnderscore, .namedMonth, .namedFullDate,
    ]

    public var isPreset: Bool { Self.presets.contains { $0.pattern == pattern } }

    /// nil means valid; otherwise a user-facing explanation.
    public var validationError: String? {
        guard !pattern.isEmpty else { return "The pattern can’t be empty." }
        guard !pattern.hasPrefix("/"), !pattern.hasSuffix("/"), !pattern.contains("//") else {
            return "The pattern must contain non-empty relative folders."
        }
        guard !pattern.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return "Parent-directory components aren’t allowed."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789{} /-_.")
        guard pattern.unicodeScalars.allSatisfy(allowed.contains) else {
            return "Use letters, numbers, spaces, /, -, _, and date tokens only."
        }
        var stripped = pattern
        for token in Self.tokens { stripped = stripped.replacingOccurrences(of: token.marker, with: "") }
        guard !stripped.contains("{") && !stripped.contains("}") else {
            return "The pattern contains an unsupported date token."
        }
        guard pattern.contains("{YYYY}"), pattern.contains("{DD}") else {
            return "The pattern must include {YYYY}, a month token, and {DD}."
        }
        guard pattern.contains("{MM}") || pattern.contains("{MMM}") || pattern.contains("{MMMM}") else {
            return "The pattern must include {MM}, {MMM}, or {MMMM}."
        }
        for component in pattern.split(separator: "/", omittingEmptySubsequences: false) {
            guard component != ".", component != "..", !component.hasPrefix(".") else {
                return "Generated folders can’t be hidden or use dot components."
            }
        }
        return nil
    }

    public func folderPath(for date: Date, calendar: Calendar = .current) -> String {
        guard validationError == nil else { return Self.nestedNumeric.folderPath(for: date, calendar: calendar) }
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let year = comps.year ?? 0, month = comps.month ?? 0, day = comps.day ?? 0
        let monthDate = Self.date(year: year, month: month, day: max(1, day), calendar: calendar) ?? date
        var out = pattern
        out = out.replacingOccurrences(of: "{YYYY}", with: String(format: "%04d", year))
        out = out.replacingOccurrences(of: "{MMMM}", with: Self.monthName(monthDate, abbreviated: false))
        out = out.replacingOccurrences(of: "{MMM}", with: Self.monthName(monthDate, abbreviated: true))
        out = out.replacingOccurrences(of: "{MM}", with: String(format: "%02d", month))
        out = out.replacingOccurrences(of: "{DD}", with: String(format: "%02d", day))
        return out
    }

    public func destinationRelPath(fileName: String, captureDate: Date) -> String {
        folderPath(for: captureDate) + "/" + fileName
    }

    /// Parse a complete layout path, or an intermediate prefix such as `2026/07`
    /// for a three-level layout. Prefix parsing powers Library folder captions.
    public func parse(folderPath: String) -> Parsed? {
        let values = folderPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let patterns = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !values.isEmpty, values.count <= patterns.count else { return nil }
        return Self.parse(value: values.joined(separator: "/"),
                          pattern: patterns.prefix(values.count).joined(separator: "/"))
    }

    public func parse(relativeFilePath: String) -> Parsed? {
        let folder = (relativeFilePath as NSString).deletingLastPathComponent
        guard folder != ".", !folder.isEmpty else { return nil }
        return parse(folderPath: folder)
    }

    public static func firstParse(folderPath: String, layouts: [DateFolderLayout]) -> Parsed? {
        for layout in layouts where layout.validationError == nil {
            if let parsed = layout.parse(folderPath: folderPath) { return parsed }
        }
        return nil
    }

    private enum Token: CaseIterable {
        case year, monthNumber, monthAbbreviated, monthFull, day
        var marker: String {
            switch self {
            case .year: "{YYYY}"
            case .monthNumber: "{MM}"
            case .monthAbbreviated: "{MMM}"
            case .monthFull: "{MMMM}"
            case .day: "{DD}"
            }
        }
        var regex: String {
            switch self {
            case .year: #"(\d{4})"#
            case .monthNumber: #"(\d{2})"#
            case .monthAbbreviated, .monthFull: #"([A-Za-z]+)"#
            case .day: #"(\d{2})"#
            }
        }
    }

    /// Longest markers first so {MMMM} is not partially consumed as {MMM}.
    private static let tokens: [Token] = [.monthFull, .monthAbbreviated, .year, .monthNumber, .day]

    private static func parse(value: String, pattern: String) -> Parsed? {
        var regex = "^"
        var captures: [Token] = []
        var cursor = pattern.startIndex
        while cursor < pattern.endIndex {
            let remaining = pattern[cursor...]
            if let token = tokens.first(where: { remaining.hasPrefix($0.marker) }) {
                regex += token.regex
                captures.append(token)
                cursor = pattern.index(cursor, offsetBy: token.marker.count)
            } else {
                let ch = String(pattern[cursor])
                regex += NSRegularExpression.escapedPattern(for: ch)
                cursor = pattern.index(after: cursor)
            }
        }
        regex += "$"
        guard let re = try? NSRegularExpression(pattern: regex),
              let match = re.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }

        var year: Int?, month: Int?, day: Int?
        for (idx, token) in captures.enumerated() {
            let range = match.range(at: idx + 1)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
            let raw = String(value[swiftRange])
            switch token {
            case .year:
                guard Self.merge(&year, Int(raw)) else { return nil }
            case .monthNumber:
                guard Self.merge(&month, Int(raw)) else { return nil }
            case .monthAbbreviated, .monthFull:
                guard Self.merge(&month, Self.monthNumber(raw)) else { return nil }
            case .day:
                guard Self.merge(&day, Int(raw)) else { return nil }
            }
        }
        guard let year, (1900...3000).contains(year) else { return nil }
        let precision: Precision = day == nil ? (month == nil ? .year : .month) : .day
        let resolvedMonth = month ?? 1, resolvedDay = day ?? 1
        guard let date = Self.date(year: year, month: resolvedMonth, day: resolvedDay, calendar: .current) else { return nil }
        return Parsed(date: date, precision: precision)
    }

    private static func merge(_ current: inout Int?, _ candidate: Int?) -> Bool {
        guard let candidate else { return false }
        if let current { return current == candidate }
        current = candidate
        return true
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        var cal = calendar
        cal.locale = Locale(identifier: "en_US_POSIX")
        var dc = DateComponents(); dc.year = year; dc.month = month; dc.day = day
        guard let date = cal.date(from: dc) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    private static func monthName(_ date: Date, abbreviated: Bool) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = abbreviated ? "MMM" : "MMMM"
        return f.string(from: date)
    }

    private static func monthNumber(_ name: String) -> Int? {
        let lower = name.lowercased()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let full = calendar.monthSymbols.map { $0.lowercased() }
        let short = calendar.shortMonthSymbols.map { $0.lowercased() }
        if let idx = full.firstIndex(of: lower) { return idx + 1 }
        if let idx = short.firstIndex(of: lower) { return idx + 1 }
        return nil
    }
}
