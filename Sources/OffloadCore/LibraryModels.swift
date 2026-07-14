import Foundation

public enum MediaKind: String, Codable, Sendable {
    case photo, raw, video

    public static let photoExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"]
    /// Still-photo RAW formats across brands. NOTE: the *offload* is format-agnostic
    /// — the ingest scan copies EVERY file under the camera folders regardless of
    /// extension, so a RAW is never skipped. This list only drives Library
    /// recognition (RAW+JPEG pairing, the "RAW" label, showing it as a photo tile).
    public static let rawExts: Set<String> = [
        "arw", "sr2", "srf",          // Sony
        "cr2", "cr3", "crw",          // Canon
        "nef", "nrw",                 // Nikon
        "raf",                        // Fujifilm
        "rw2", "raw",                 // Panasonic / generic
        "orf",                        // Olympus / OM System
        "pef",                        // Pentax / Ricoh
        "srw",                        // Samsung
        "dng",                        // Adobe DNG (Leica, DJI, phones, Pentax…)
        "3fr", "fff",                 // Hasselblad
        "rwl",                        // Leica
        "x3f",                        // Sigma (Foveon)
        "iiq", "cap",                 // Phase One
        "mos",                        // Leaf
        "mef",                        // Mamiya
        "mrw",                        // Minolta / Konica Minolta
        "dcr", "kdc", "k25",          // Kodak
        "erf",                        // Epson
        "gpr",                        // GoPro
    ]
    public static let videoExts: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf", "braw"]
    /// Non-media companion files that belong to a photo (edit/metadata sidecars).
    public static let sidecarExts: Set<String> = ["xmp", "thm", "aae", "dop", "pp3", "on1", "cos", "lrv"]

    public static func classify(ext: String) -> MediaKind? {
        let e = ext.lowercased()
        if photoExts.contains(e) { return .photo }
        if rawExts.contains(e) { return .raw }
        if videoExts.contains(e) { return .video }
        return nil
    }

    public static func isMedia(_ ext: String) -> Bool { classify(ext: ext) != nil }
}

/// A single row in the browser: a folder or a media file.
public struct LibraryEntry: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case folder
        case media(MediaKind)
    }
    public let id: String          // absolute path
    public let name: String
    public let kind: Kind
    public let size: Int64
    public let modified: Date

    public init(id: String, name: String, kind: Kind, size: Int64, modified: Date) {
        self.id = id; self.name = name; self.kind = kind; self.size = size; self.modified = modified
    }

    public var url: URL { URL(fileURLWithPath: id) }
    public var isFolder: Bool { if case .folder = kind { return true }; return false }
}

/// Cached, progressively-built count of a library root, so the Library window
/// can show "38,412 photos · 1.3 TB" without re-walking the tree every open.
public struct LibraryIndex: Codable, Sendable {
    public var rootPath: String
    public var totalMedia: Int
    public var totalBytes: Int64
    public var updatedAt: Date
    public var complete: Bool

    public init(rootPath: String, totalMedia: Int = 0, totalBytes: Int64 = 0,
                updatedAt: Date = Date(), complete: Bool = false) {
        self.rootPath = rootPath
        self.totalMedia = totalMedia
        self.totalBytes = totalBytes
        self.updatedAt = updatedAt
        self.complete = complete
    }

    public static func load(rootPath: String) -> LibraryIndex? {
        guard let cached = JSONIO.loadGuarded(LibraryIndex.self, from: Paths.libraryIndexFile),
              cached.rootPath == rootPath else { return nil }
        return cached
    }

    public func save() {
        try? JSONIO.save(self, to: Paths.libraryIndexFile)
    }

    /// Drop the cached library total so the next open re-counts — call after an
    /// offload adds photos, so the header stays accurate without a manual Refresh.
    public static func invalidate() {
        try? FileManager.default.removeItem(at: Paths.libraryIndexFile)
    }
}

/// A culling verdict flag: keep (pick) or throw away (reject).
public enum PhotoFlag: String, Codable, Sendable { case pick, reject }

/// Persisted culling state, keyed by the shown photo's absolute path.
public struct CullData: Codable, Sendable {
    public var ratings: [String: Int]        // 0…5 (0 / absent = unrated)
    public var flags: [String: PhotoFlag]
    public init(ratings: [String: Int] = [:], flags: [String: PhotoFlag] = [:]) {
        self.ratings = ratings; self.flags = flags
    }
}
