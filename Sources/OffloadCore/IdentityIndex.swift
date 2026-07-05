import Foundation

/// The named people/pets store. Suggestions are proposed by nearest-centroid
/// within a threshold, but NOTHING is auto-assigned — a human confirms, and each
/// confirmation appends an exemplar so the identity gets better over time.
/// Persisted to its own file so it survives a photo-index rebuild.
public actor IdentityIndex {
    private var identities: [UUID: Identity] = [:]
    private var dirty = false
    private let file: URL

    /// Suggest-only distance ceiling. Deliberately a GUESS — the Vision
    /// feature-print has no documented same-identity threshold — and used ONLY to
    /// surface a suggestion the user confirms, never to auto-assign a name.
    public static let suggestThreshold: Float = 0.45

    /// Cap exemplars per identity so the store can't grow without bound; the most
    /// recent confirmations dominate the centroid.
    private static let maxExemplars = 40

    public init(file: URL = Paths.identityIndexFile) {
        self.file = file
        if let arr = JSONIO.loadGuarded([Identity].self, from: file) {
            identities = Dictionary(arr.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        }
    }

    public func all() -> [Identity] {
        Array(identities.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func identity(_ id: UUID) -> Identity? { identities[id] }

    /// Create a named identity seeded with one confirmed exemplar.
    @discardableResult
    public func create(name: String, kind: Identity.Kind, embedderID: String,
                       exemplar: [Float], coverPath: String? = nil) -> Identity {
        let e = FaceMath.normalized(exemplar)
        let identity = Identity(name: name, kind: kind, embedderID: embedderID,
                                exemplars: [e], centroid: FaceMath.centroid([e]), coverPath: coverPath)
        identities[identity.id] = identity
        dirty = true
        return identity
    }

    /// Learn from a confirmation: append an exemplar and recompute the centroid.
    /// Refuses vectors from a different embedder (incomparable scales).
    public func addExemplar(_ vector: [Float], to id: UUID, embedderID: String) {
        guard var idn = identities[id], idn.embedderID == embedderID else { return }
        idn.exemplars.append(FaceMath.normalized(vector))
        if idn.exemplars.count > Self.maxExemplars {
            idn.exemplars.removeFirst(idn.exemplars.count - Self.maxExemplars)
        }
        idn.centroid = FaceMath.centroid(idn.exemplars)
        identities[id] = idn
        dirty = true
    }

    public func rename(_ id: UUID, to name: String) {
        guard var idn = identities[id] else { return }
        idn.name = name
        identities[id] = idn
        dirty = true
    }

    public func setCover(_ id: UUID, path: String) {
        guard var idn = identities[id] else { return }
        idn.coverPath = path
        identities[id] = idn
        dirty = true
    }

    public func delete(_ id: UUID) {
        if identities.removeValue(forKey: id) != nil { dirty = true }
    }

    /// The best suggestion for a detection embedding: the nearest centroid of the
    /// SAME kind and SAME embedder, within the suggest threshold, excluding any
    /// identities the user already rejected for this detection.
    public func suggest(for embedding: [Float], embedderID: String, kind: Identity.Kind,
                        excluding rejected: [UUID] = []) -> (id: UUID, distance: Float)? {
        let e = FaceMath.normalized(embedding)
        var best: (id: UUID, distance: Float)?
        for idn in identities.values
        where idn.kind == kind && idn.embedderID == embedderID && !rejected.contains(idn.id) {
            guard let d = FaceMath.cosineDistance(e, idn.centroid) else { continue }
            if d <= Self.suggestThreshold, best == nil || d < best!.distance {
                best = (idn.id, d)
            }
        }
        return best
    }

    public func save() {
        guard dirty else { return }
        try? JSONIO.save(Array(identities.values), to: file)
        JSONIO.harden(file)   // biometric data: owner-only, never backed up/synced
        dirty = false
    }

    /// Erase all named identities (and the on-disk file). For "Delete all face data".
    public func deleteAll() {
        identities.removeAll()
        dirty = false
        JSONIO.purge(file)   // main + .bak + .damaged — leave no biometric residue
    }
}
