import Foundation

/// One content label from on-device analysis, e.g. ("dog", 0.92).
public struct PhotoLabel: Codable, Sendable, Hashable {
    public let name: String
    public let confidence: Double
    public init(name: String, confidence: Double) { self.name = name; self.confidence = confidence }
}

/// A photo's capture coordinate, from EXIF GPS. Displayed in the viewer info
/// panel when present.
public struct GeoPoint: Codable, Sendable, Hashable {
    public let lat: Double
    public let lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

/// What we know about one photo's contents — the row in the searchable database.
public struct PhotoRecord: Codable, Sendable {
    public var path: String
    public let size: Int64
    public let mtime: Date
    public var labels: [PhotoLabel]    // scene/object classifications
    public var animals: [String]       // "Dog", "Cat" from animal recognition
    public var analyzedAt: Date
    // Fine-grained identification from the `claude` CLI (on-demand, richer than the
    // on-device labels). Optional so index files written before this still decode.
    public var aiTags: [String]? = nil
    public var aiDescription: String? = nil
    public var aiAnalyzedAt: Date? = nil
    /// nil uses generated tags; an empty array deliberately removes every tag.
    public var userTags: [String]? = nil

    public init(path: String, size: Int64, mtime: Date, labels: [PhotoLabel],
                animals: [String], analyzedAt: Date = Date()) {
        self.path = path; self.size = size; self.mtime = mtime
        self.labels = labels; self.animals = animals; self.analyzedAt = analyzedAt
    }

    /// De-duplicated tag list, lowercased — AI tags first (the specific ones), then
    /// animals, then on-device labels. Powers tile overlays, search, and suggestions.
    public var tags: [String] {
        if let userTags { return Self.normalizedTags(userTags) }
        var seen = Set<String>()
        var out: [String] = []
        for t in (aiTags ?? []).map({ $0.lowercased() }) + animals.map({ $0.lowercased() }) + labels.map({ $0.name.lowercased() }) {
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap {
            let tag = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !tag.isEmpty && seen.insert(tag).inserted ? tag : nil
        }
    }

    public var searchText: String {
        (tags + [(path as NSString).lastPathComponent.lowercased(), (aiDescription ?? "").lowercased()]).joined(separator: " ")
    }
}

/// The photo content database: analyze once, search forever. Persisted as a
/// single JSON array under Application Support. Keyed by path; a changed mtime
/// invalidates the entry so edited/replaced files get re-analyzed.
public actor PhotoIndex {
    private var records: [String: PhotoRecord] = [:]
    /// Lowercased haystack per path — the string `search()` matches against.
    /// Rebuilding this per keystroke over tens of thousands of records was
    /// visibly janky, so we cache the derivation and invalidate an entry
    /// whenever we mutate its record.
    private var haystack: [String: String] = [:]
    private var dirty = false
    private let file: URL

    public init(file: URL = Paths.photoIndexFile) {
        self.file = file
    }

    private var loaded = false
    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        if let arr = JSONIO.loadGuarded([PhotoRecord].self, from: file) {
            records = Dictionary(arr.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    public func needsAnalysis(path: String, mtime: Date) -> Bool {
        ensureLoaded()
        guard let r = records[path] else { return true }
        return abs(r.mtime.timeIntervalSince(mtime)) > 2
    }

    public func put(_ record: PhotoRecord) {
        ensureLoaded()
        var record = record
        if record.userTags == nil { record.userTags = records[record.path]?.userTags }
        records[record.path] = record
        haystack.removeValue(forKey: record.path)
        dirty = true
    }

    /// Store on-demand AI identification for a photo, creating a record if it hasn't
    /// been analyzed on-device yet. Leaves any existing labels/GPS intact.
    public func setAI(path: String, size: Int64, mtime: Date, tags: [String], description: String) {
        ensureLoaded()
        var r = records[path] ?? PhotoRecord(path: path, size: size, mtime: mtime, labels: [], animals: [])
        r.aiTags = tags
        r.aiDescription = description
        r.aiAnalyzedAt = Date()
        records[path] = r
        haystack.removeValue(forKey: path)
        dirty = true
    }

    /// Persist before publishing success. A failed write leaves the prior tags and
    /// search cache intact, so the editor can truthfully offer a retry.
    public func saveUserTags(path: String, size: Int64, mtime: Date, tags: [String]) throws -> [String] {
        ensureLoaded()
        var record = records[path] ?? PhotoRecord(path: path, size: size, mtime: mtime, labels: [], animals: [])
        let normalized = PhotoRecord.normalizedTags(tags)
        record.userTags = normalized
        var updated = records
        updated[path] = record
        try JSONIO.save(Array(updated.values), to: file)
        records = updated
        haystack.removeValue(forKey: path)
        dirty = false
        return normalized
    }

    public func remove(paths: [String]) {
        ensureLoaded()
        for p in paths where records[p] != nil {
            records.removeValue(forKey: p)
            haystack.removeValue(forKey: p)
            dirty = true
        }
    }

    public func remapPaths(_ mapping: [String: String]) {
        ensureLoaded()
        guard !mapping.isEmpty else { return }
        for (old, new) in mapping where old != new {
            guard var record = records.removeValue(forKey: old) else { continue }
            record.path = new
            records[new] = record
            haystack.removeValue(forKey: old)
            haystack.removeValue(forKey: new)
            dirty = true
        }
    }

    /// Drop entries under `prefix` whose file is no longer in `keeping` (deleted
    /// or moved outside the app) so the index doesn't grow stale forever.
    public func pruneMissing(underPrefix prefix: String, keeping: Set<String>) {
        ensureLoaded()
        for path in records.keys where Self.isUnder(path, prefix) && !keeping.contains(path) {
            records.removeValue(forKey: path)
            haystack.removeValue(forKey: path)
            dirty = true
        }
    }

    /// True path containment (boundary-aware): "/nas/Photos" contains
    /// "/nas/Photos/a.jpg" but NOT "/nas/PhotosBackup/a.jpg".
    private static func isUnder(_ path: String, _ prefix: String) -> Bool {
        if path == prefix { return true }
        let p = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.hasPrefix(p)
    }

    public func record(_ path: String) -> PhotoRecord? { ensureLoaded(); return records[path] }

    public func records(forPaths paths: [String]) -> [String: PhotoRecord] {
        ensureLoaded()
        var out: [String: PhotoRecord] = [:]
        for p in paths where records[p] != nil { out[p] = records[p] }
        return out
    }

    @discardableResult
    public func save() -> Bool {
        ensureLoaded()
        guard dirty else { return true }
        do { try JSONIO.save(Array(records.values), to: file) } catch { return false }
        dirty = false
        return true
    }

    public func analyzedCount(underPrefix prefix: String) -> Int {
        ensureLoaded()
        return records.keys.filter { Self.isUnder($0, prefix) }.count
    }

    /// Paths whose contents match ALL space-separated query terms.
    public func search(_ query: String, underPrefix prefix: String? = nil) -> Set<String> {
        ensureLoaded()
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var out = Set<String>()
        for (path, rec) in records {
            if let prefix, !Self.isUnder(path, prefix) { continue }
            let hay: String
            if let cached = haystack[path] {
                hay = cached
            } else {
                hay = rec.searchText
                haystack[path] = hay
            }
            if terms.allSatisfy({ hay.contains($0) }) { out.insert(path) }
        }
        return out
    }

    /// Top content tags with counts — the "what's in your library" suggestions.
    public func topTags(underPrefix prefix: String, limit: Int = 24) -> [(tag: String, count: Int)] {
        ensureLoaded()
        var counts: [String: Int] = [:]
        for (path, rec) in records where Self.isUnder(path, prefix) {
            for t in rec.tags.prefix(4) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { (tag: $0.key, count: $0.value) }
    }
}
