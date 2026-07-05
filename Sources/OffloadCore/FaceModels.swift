import Foundation

/// Normalized bounding box in Vision's coordinate space (origin bottom-left,
/// 0…1), stored so a crop or annotation can be reproduced without re-detecting.
public struct NormRect: Codable, Sendable, Hashable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// A named person or pet. Learns from confirmations: each confirmed detection's
/// embedding becomes an exemplar and the centroid is their averaged prototype.
public struct Identity: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case person, pet }
    public let id: UUID
    public var name: String
    public var kind: Kind
    public var embedderID: String          // which embedder produced these vectors
    public var exemplars: [[Float]]        // confirmed, L2-normalized embeddings
    public var centroid: [Float]           // normalized mean of exemplars
    public var coverPath: String?          // a representative photo

    public init(id: UUID = UUID(), name: String, kind: Kind, embedderID: String,
                exemplars: [[Float]], centroid: [Float], coverPath: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.embedderID = embedderID
        self.exemplars = exemplars; self.centroid = centroid; self.coverPath = coverPath
    }
}

/// A detected face or animal in one photo, with its identity embedding. EVERY
/// vector carries the embedderID that produced it — vectors from different
/// embedders (or Vision revisions) live on different scales and must never be
/// compared, so all matching is filtered by embedderID.
public struct Detection: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable { case face, pet }
    public let id: UUID
    public var kind: Kind
    public var bbox: NormRect
    public var embedding: [Float]
    public var embedderID: String
    public var quality: Double             // face capture-quality, or pet detection confidence
    public var assignedID: UUID?           // confirmed identity
    public var suggestedID: UUID?          // proposed, awaiting confirm
    public var rejectedIDs: [UUID]         // "not this one" — never re-suggest these

    public init(id: UUID = UUID(), kind: Kind, bbox: NormRect, embedding: [Float],
                embedderID: String, quality: Double, assignedID: UUID? = nil,
                suggestedID: UUID? = nil, rejectedIDs: [UUID] = []) {
        self.id = id; self.kind = kind; self.bbox = bbox; self.embedding = embedding
        self.embedderID = embedderID; self.quality = quality
        self.assignedID = assignedID; self.suggestedID = suggestedID; self.rejectedIDs = rejectedIDs
    }

    /// A face maps to a person, an animal to a pet — so suggestions never cross.
    public var identityKind: Identity.Kind { kind == .pet ? .pet : .person }
}

/// Vector math for identity matching. Cosine distance on L2-normalized vectors.
public enum FaceMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine distance (0 = identical … 2 = opposite) assuming both vectors are
    /// L2-normalized. Returns nil for incomparable vectors (different length ⇒
    /// different embedder — never compare those).
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return 1 - dot
    }

    /// Normalized mean of a set of (already-normalized) exemplars.
    public static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first, !first.isEmpty else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        var n: Float = 0
        for v in vectors where v.count == sum.count {
            for i in v.indices { sum[i] += v[i] }
            n += 1
        }
        guard n > 0 else { return [] }
        return normalized(sum.map { $0 / n })
    }
}
