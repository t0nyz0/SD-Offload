import Foundation

/// Per-photo face/pet detections (and their embeddings). Kept separate from the
/// content PhotoIndex so the eagerly-loaded content index stays lean, and so a
/// heavy face re-scan doesn't churn it. Answers "which photos show identity X"
/// and "what's still unnamed" for the labeling UI and search.
public actor FaceIndex {
    /// On-disk row: one photo path and everything detected in it.
    private struct Entry: Codable, Sendable {
        var path: String
        var detections: [Detection]
    }

    private var byPath: [String: [Detection]] = [:]
    private var dirty = false
    private let file: URL

    public init(file: URL = Paths.faceIndexFile) {
        self.file = file
        if let arr = JSONIO.loadGuarded([Entry].self, from: file) {
            byPath = Dictionary(arr.map { ($0.path, $0.detections) }, uniquingKeysWith: { _, b in b })
        }
    }

    // MARK: - Scan bookkeeping

    /// A photo needs a face scan if we've never recorded a result for it (even an
    /// empty one — a face-less photo gets an empty array so it isn't re-scanned).
    public func needsScan(path: String) -> Bool { byPath[path] == nil }

    /// Record the scan result for a photo (empty array = scanned, nothing found).
    public func setDetections(_ detections: [Detection], for path: String) {
        byPath[path] = detections
        dirty = true
    }

    public func detections(for path: String) -> [Detection] { byPath[path] ?? [] }

    public func remove(paths: [String]) {
        for p in paths where byPath[p] != nil { byPath.removeValue(forKey: p); dirty = true }
    }

    public func pruneMissing(underPrefix prefix: String, keeping: Set<String>) {
        for path in byPath.keys where Self.isUnder(path, prefix) && !keeping.contains(path) {
            byPath.removeValue(forKey: path)
            dirty = true
        }
    }

    // MARK: - Labeling mutations

    public func assign(detection detID: UUID, in path: String, to identityID: UUID?) {
        mutate(detID, in: path) {
            $0.assignedID = identityID
            if identityID != nil { $0.suggestedID = nil }
        }
    }

    public func setSuggestion(detection detID: UUID, in path: String, to identityID: UUID?) {
        mutate(detID, in: path) { $0.suggestedID = identityID }
    }

    /// "Not this one": remember the rejection so it's never re-suggested, and drop
    /// the current suggestion if it was the rejected identity.
    public func reject(detection detID: UUID, in path: String, identity identityID: UUID) {
        mutate(detID, in: path) {
            if !$0.rejectedIDs.contains(identityID) { $0.rejectedIDs.append(identityID) }
            if $0.suggestedID == identityID { $0.suggestedID = nil }
        }
    }

    private func mutate(_ detID: UUID, in path: String, _ body: (inout Detection) -> Void) {
        guard var dets = byPath[path], let i = dets.firstIndex(where: { $0.id == detID }) else { return }
        body(&dets[i])
        byPath[path] = dets
        dirty = true
    }

    // MARK: - Queries

    /// Photos containing a confirmed detection of `identity`.
    public func photos(withIdentity id: UUID, underPrefix prefix: String? = nil) -> Set<String> {
        var out = Set<String>()
        for (path, dets) in byPath {
            if let prefix, !Self.isUnder(path, prefix) { continue }
            if dets.contains(where: { $0.assignedID == id }) { out.insert(path) }
        }
        return out
    }

    /// Every detection not yet confirmed to an identity (the labeling queue),
    /// best-quality first, optionally filtered by kind and root.
    public func unassigned(kind: Detection.Kind? = nil, underPrefix prefix: String? = nil)
        -> [(path: String, detection: Detection)] {
        var out: [(String, Detection)] = []
        for (path, dets) in byPath {
            if let prefix, !Self.isUnder(path, prefix) { continue }
            for d in dets where d.assignedID == nil && (kind == nil || d.kind == kind) {
                out.append((path, d))
            }
        }
        return out.sorted { $0.1.quality > $1.1.quality }.map { (path: $0.0, detection: $0.1) }
    }

    public func counts(underPrefix prefix: String? = nil) -> (detections: Int, named: Int, unnamed: Int) {
        var total = 0, named = 0
        for (path, dets) in byPath {
            if let prefix, !Self.isUnder(path, prefix) { continue }
            for d in dets { total += 1; if d.assignedID != nil { named += 1 } }
        }
        return (total, named, total - named)
    }

    private static func isUnder(_ path: String, _ prefix: String) -> Bool {
        if path == prefix { return true }
        let p = prefix.hasSuffix("/") ? prefix : prefix + "/"
        return path.hasPrefix(p)
    }

    public func save() {
        guard dirty else { return }
        let arr = byPath.map { Entry(path: $0.key, detections: $0.value) }
        try? JSONIO.save(arr, to: file)
        dirty = false
    }
}
