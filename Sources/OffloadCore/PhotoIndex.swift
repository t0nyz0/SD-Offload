import Foundation

/// One content label from on-device analysis, e.g. ("dog", 0.92).
public struct PhotoLabel: Codable, Sendable, Hashable {
    public let name: String
    public let confidence: Double
    public init(name: String, confidence: Double) { self.name = name; self.confidence = confidence }
}

/// What we know about one photo's contents — the row in the searchable database.
public struct PhotoRecord: Codable, Sendable {
    public let path: String
    public let size: Int64
    public let mtime: Date
    public var labels: [PhotoLabel]    // scene/object classifications
    public var animals: [String]       // "Dog", "Cat" from animal recognition
    public var analyzedAt: Date

    public init(path: String, size: Int64, mtime: Date, labels: [PhotoLabel],
                animals: [String], analyzedAt: Date = Date()) {
        self.path = path; self.size = size; self.mtime = mtime
        self.labels = labels; self.animals = animals; self.analyzedAt = analyzedAt
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

    public func remove(paths: [String]) {
        for p in paths where records[p] != nil { records.removeValue(forKey: p); dirty = true }
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
        records.keys.filter { $0.hasPrefix(prefix) }.count
    }

    /// Paths whose contents match ALL space-separated query terms.
    public func search(_ query: String, underPrefix prefix: String? = nil) -> Set<String> {
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        var out = Set<String>()
        for (path, rec) in records {
            if let prefix, !path.hasPrefix(prefix) { continue }
            let hay = rec.searchText
            if terms.allSatisfy({ hay.contains($0) }) { out.insert(path) }
        }
        return out
    }

    /// Top content tags with counts — the "what's in your library" suggestions.
    public func topTags(underPrefix prefix: String, limit: Int = 24) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for (path, rec) in records where path.hasPrefix(prefix) {
            for t in rec.tags.prefix(4) { counts[t, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).map { (tag: $0.key, count: $0.value) }
    }
}
