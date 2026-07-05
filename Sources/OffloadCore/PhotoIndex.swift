import Foundation

/// One content label from on-device analysis, e.g. ("dog", 0.92).
public struct PhotoLabel: Codable, Sendable, Hashable {
    public let name: String
    public let confidence: Double
    public init(name: String, confidence: Double) { self.name = name; self.confidence = confidence }
}

/// A photo's capture coordinate, read from EXIF GPS (nil when the camera didn't
/// record one — common for dedicated cameras). Place names come later, from an
/// opt-in reverse-geocode; this is just the raw point.
public struct GeoPoint: Codable, Sendable, Hashable {
    public let lat: Double
    public let lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
}

/// What we know about one photo's contents — the row in the searchable database.
public struct PhotoRecord: Codable, Sendable {
    public let path: String
    public let size: Int64
    public let mtime: Date
    public var labels: [PhotoLabel]    // scene/object classifications
    public var animals: [String]       // "Dog", "Cat" from animal recognition
    public var analyzedAt: Date
    // Optional (both decode as nil on records written before GPS support, so old
    // index files still load). `gpsChecked == true` means we've already looked
    // for a coordinate, so a re-scan doesn't re-read every no-GPS photo's header.
    public var location: GeoPoint?
    public var gpsChecked: Bool?

    public init(path: String, size: Int64, mtime: Date, labels: [PhotoLabel],
                animals: [String], analyzedAt: Date = Date(),
                location: GeoPoint? = nil, gpsChecked: Bool? = nil) {
        self.path = path; self.size = size; self.mtime = mtime
        self.labels = labels; self.animals = animals; self.analyzedAt = analyzedAt
        self.location = location; self.gpsChecked = gpsChecked
    }

    /// De-duplicated tag list (animals first, then labels), lowercased.
    public var tags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for t in animals.map({ $0.lowercased() }) + labels.map({ $0.name.lowercased() }) {
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    public var searchText: String {
        (tags + [(path as NSString).lastPathComponent.lowercased()]).joined(separator: " ")
    }
}

/// The photo content database: analyze once, search forever. Persisted as a
/// single JSON array under Application Support. Keyed by path; a changed mtime
/// invalidates the entry so edited/replaced files get re-analyzed.
public actor PhotoIndex {
    private var records: [String: PhotoRecord] = [:]
    private var dirty = false
    private let file: URL

    public init(file: URL = Paths.photoIndexFile) {
        self.file = file
        if let arr = JSONIO.loadGuarded([PhotoRecord].self, from: file) {
            records = Dictionary(arr.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    public func needsAnalysis(path: String, mtime: Date) -> Bool {
        guard let r = records[path] else { return true }
        return abs(r.mtime.timeIntervalSince(mtime)) > 2
    }

    public func put(_ record: PhotoRecord) {
        records[record.path] = record
        dirty = true
    }

    /// Set (or clear) a photo's coordinate and mark it GPS-checked, leaving its
    /// content labels intact. Used by the cheap GPS backfill.
    public func setGPS(path: String, location: GeoPoint?) {
        guard var r = records[path] else { return }
        r.location = location
        r.gpsChecked = true
        records[path] = r
        dirty = true
    }

    public func remove(paths: [String]) {
        for p in paths where records[p] != nil { records.removeValue(forKey: p); dirty = true }
    }

    /// Drop entries under `prefix` whose file is no longer in `keeping` (deleted
    /// or moved outside the app) so the index doesn't grow stale forever.
    public func pruneMissing(underPrefix prefix: String, keeping: Set<String>) {
        for path in records.keys where Self.isUnder(path, prefix) && !keeping.contains(path) {
            records.removeValue(forKey: path)
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

    public func record(_ path: String) -> PhotoRecord? { records[path] }

    public func records(forPaths paths: [String]) -> [String: PhotoRecord] {
        var out: [String: PhotoRecord] = [:]
        for p in paths where records[p] != nil { out[p] = records[p] }
        return out
    }

    public func save() {
        guard dirty else { return }
        try? JSONIO.save(Array(records.values), to: file)
        dirty = false
    }

    public func analyzedCount(underPrefix prefix: String) -> Int {
        records.keys.filter { Self.isUnder($0, prefix) }.count
    }

    /// GPS coverage under a root: how many analyzed photos we've checked, and how
    /// many of those actually carried a coordinate. Answers "how much of my
    /// library even has GPS" before we invest in place-name lookups.
    public func geoStats(underPrefix prefix: String) -> (withGPS: Int, checked: Int) {
        var withGPS = 0, checked = 0
        for (path, rec) in records where Self.isUnder(path, prefix) {
            if rec.gpsChecked == true { checked += 1 }
            if rec.location != nil { withGPS += 1 }
        }
        return (withGPS, checked)
    }

    /// True if this analyzed record hasn't yet been examined for a GPS tag — used
    /// to cheaply backfill coordinates on photos analyzed before GPS support,
    /// without re-running Vision on them.
    public func needsGPSCheck(path: String) -> Bool {
        guard let r = records[path] else { return false }   // not analyzed yet → full analyze covers it
        return r.gpsChecked != true
    }

    /// Paths whose contents match ALL space-separated query terms.
    public func search(_ query: String, underPrefix prefix: String? = nil) -> Set<String> {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var out = Set<String>()
        for (path, rec) in records {
            if let prefix, !Self.isUnder(path, prefix) { continue }
            let hay = rec.searchText
            if terms.allSatisfy({ hay.contains($0) }) { out.insert(path) }
        }
        return out
    }

    /// Top content tags with counts — the "what's in your library" suggestions.
    public func topTags(underPrefix prefix: String, limit: Int = 24) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for (path, rec) in records where Self.isUnder(path, prefix) {
            for t in rec.tags.prefix(4) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { (tag: $0.key, count: $0.value) }
    }
}
