import SwiftUI
import ImageIO
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import OffloadCore

/// User-tunable thumbnail fidelity (Settings → Library). Higher = sharper but
/// slower to generate: it decodes the full photo instead of the file's small
/// embedded preview, at more pixels and less cache compression — noticeably
/// heavier over SMB, especially for RAW.
enum ThumbnailQuality: Int, CaseIterable, Sendable {
    case fast = 0, balanced = 1, high = 2, maximum = 3

    static let defaultQuality: ThumbnailQuality = .high

    var label: String {
        switch self {
        case .fast: "Fast"; case .balanced: "Balanced"; case .high: "High"; case .maximum: "Maximum"
        }
    }
    /// Pixel budget as a multiple of the base tile side (retina baseline ≈ 2×).
    /// Maximum bumps this so very large tiles stay sharp.
    var pixelScale: CGFloat {
        switch self { case .fast: 1.5; case .balanced: 2.2; case .high: 3.2; case .maximum: 4.0 }
    }
    /// Decode the full image for a crisp thumbnail rather than the file's small
    /// embedded preview. Off for Fast (embedded preview is quick over SMB).
    var fullDecode: Bool { self != .fast }
    /// Also full-decode over SMB (pulling the whole file) for a crisp tile — only at
    /// the top tiers, where the user has opted into quality over speed. This skips a
    /// JPEG's tiny embedded EXIF thumbnail, the usual reason NAS tiles look soft. Not
    /// applied to RAW: its embedded preview is already large, and its full file is
    /// tens of MB to pull per tile.
    var fullDecodeOverNetwork: Bool { self == .high || self == .maximum }
    /// JPEG quality of the on-disk thumbnail cache.
    var jpegCompression: CGFloat {
        switch self { case .fast: 0.6; case .balanced: 0.8; case .high: 0.92; case .maximum: 0.97 }
    }

    static let storageKey = "offload.library.thumbQuality"
    static var current: ThumbnailQuality {
        // integer(forKey:) can't tell "unset" from 0 (.fast) — check presence so an
        // untouched preference resolves to the intended default, not Fast.
        guard UserDefaults.standard.object(forKey: storageKey) != nil else { return defaultQuality }
        return ThumbnailQuality(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? defaultQuality
    }
}

/// A small async semaphore so we don't fire dozens of concurrent thumbnail
/// reads at the NAS at once (that thrashes SMB and makes everything slower).
actor ThumbLimiter {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if inUse < limit { inUse += 1; return }
        await withCheckedContinuation { waiters.append($0) }   // resumed already holding a slot
    }
    func release() {
        if let w = waiters.first { waiters.removeFirst(); w.resume() }
        else { inUse -= 1 }
    }
}

/// Fast, persistent thumbnails for the Library.
///
/// Wins over the naive approach:
/// 1. **Embedded previews over SMB.** Local sources full-decode (sharpest); NAS
///    sources pull the file's embedded preview (~1600px+, KBs) instead of the
///    whole RAW/JPEG — same on-screen sharpness at a ~220px tile, far less wire.
/// 2. **Two-tier cache with a BYTE budget.** In-memory NSCache (bounded by bytes,
///    not just count, so High/Maximum can't pile up 1 GB of decoded bitmaps) +
///    an on-disk JPEG cache, keyed by path+size+mtime+quality+source.
/// 3. **Bounded, cancellable decodes.** ≤6 concurrent NAS reads; a tile scrolled
///    off-screen cancels its decode and frees its slot. Cached tiles decode
///    eagerly OFF the main thread so scroll-back never hitches on a draw-time JPEG.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let mem: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        c.totalCostLimit = 384 << 20   // decoded-bitmap RAM cap — bigger so scroll-back stays warm at High/Max
        return c
    }()
    private let limiter = ThumbLimiter(limit: 6)
    private let cacheDir: URL

    init() {
        cacheDir = Paths.appSupport.appendingPathComponent("ThumbCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dir = cacheDir
        Task.detached(priority: .background) { Self.trimCache(dir, maxBytes: 500 << 20) }
    }

    /// Drop every cached thumbnail — the in-memory bitmaps and the on-disk JPEGs —
    /// so thumbnails regenerate at the current quality. Called when the user changes
    /// thumbnail quality. Cheap: clearing memory is instant and deleting the cache
    /// files is a quick local operation; the (bounded, lazy) regeneration happens as
    /// tiles come on screen, so it never storms the NAS.
    func clearCaches() {
        mem.removeAllObjects()
        let dir = cacheDir
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for url in items { try? fm.removeItem(at: url) }
        }
    }

    /// Evict the oldest on-disk thumbnails so the cache can't grow forever.
    private static func trimCache(_ dir: URL, maxBytes: Int64) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var total: Int64 = 0
        let entries = items.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let size = Int64(v.fileSize ?? 0)
            total += size
            return (url, size, v.contentAccessDate ?? v.contentModificationDate ?? .distantPast)
        }
        guard total > maxBytes else { return }
        for (url, size, _) in entries.sorted(by: { $0.2 < $1.2 }) {   // oldest first
            if total <= maxBytes { break }
            try? fm.removeItem(at: url)
            total -= size
        }
    }

    /// Approximate resident bytes of a decoded image (pixels × 4 RGBA), so the
    /// NSCache byte budget reflects real memory rather than an object count.
    private static func cost(_ image: NSImage) -> Int {
        if let rep = image.representations.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return max(1, Int(image.size.width * image.size.height) * 4)
    }

    private func key(path: String, size: Int64, mtime: Date, side: CGFloat,
                     quality: ThumbnailQuality, isLocal: Bool) -> String {
        let s = "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970))|\(Int(side))|q\(quality.rawValue)|l\(isLocal ? 1 : 0)"
        let hash = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(40))
    }

    /// Synchronous in-memory cache peek — returns a warm bitmap instantly (no decode,
    /// no SMB) so a recycled/reopened tile paints on the FIRST frame instead of
    /// flashing the placeholder. nil ⇒ not warm; fall back to the async path.
    func cached(url: URL, size: Int64, mtime: Date, side: CGFloat,
                quality: ThumbnailQuality = .current, isLocal: Bool = false) -> NSImage? {
        mem.object(forKey: key(path: url.path, size: size, mtime: mtime, side: side,
                               quality: quality, isLocal: isLocal) as NSString)
    }

    func thumbnail(url: URL, size: Int64, mtime: Date, side: CGFloat,
                   quality: ThumbnailQuality = .current, isLocal: Bool = false) async -> NSImage? {
        let k = key(path: url.path, size: size, mtime: mtime, side: side, quality: quality, isLocal: isLocal)
        if let hit = mem.object(forKey: k as NSString) { return hit }
        if Task.isCancelled { return nil }

        // Warm disk cache: decode eagerly OFF the main thread so the tile paints
        // without a draw-time JPEG decode. It's a local read, so it doesn't need
        // the NAS limiter.
        let diskURL = cacheDir.appendingPathComponent(k + ".jpg")
        if FileManager.default.fileExists(atPath: diskURL.path) {
            if let img = await Task.detached(priority: .utility, operation: { Self.decodeEager(diskURL) }).value {
                mem.setObject(img, forKey: k as NSString, cost: Self.cost(img))
                return img
            }
            // Unreadable cache file → fall through and regenerate.
        }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }

        // Cold generate. Bridge cancellation into the detached decode so a tile
        // scrolled off-screen stops (at the next boundary) and frees its slot for
        // a visible tile, instead of running a full SMB decode nobody will see.
        let decode = Task.detached(priority: .utility) {
            Self.cgThumbnailCG(url: url, side: side, quality: quality, isLocal: isLocal)
        }
        let cg = await withTaskCancellationHandler {
            await decode.value
        } onCancel: {
            decode.cancel()
        }
        if Task.isCancelled { return nil }

        if let cg {
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            mem.setObject(img, forKey: k as NSString, cost: Self.cost(img))
            let comp = quality.jpegCompression
            Task.detached(priority: .background) { Self.writeJPEG(cg, to: diskURL, compression: comp) }   // don't block first paint
            return img
        }
        // ImageIO couldn't thumbnail (some RAW/video) → QuickLook fallback.
        if Task.isCancelled { return nil }
        if let img = await Self.qlThumbnail(url: url, side: side) {
            mem.setObject(img, forKey: k as NSString, cost: Self.cost(img))
            if let cg2 = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let comp = quality.jpegCompression
                Task.detached(priority: .background) { Self.writeJPEG(cg2, to: diskURL, compression: comp) }
            }
            return img
        }
        return nil
    }

    // MARK: - Generation

    /// Eagerly decode a cached JPEG to a bitmap-backed image (off-main), so the
    /// UI draw is a plain composite instead of a deferred main-thread decode.
    private static func decodeEager(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0,
                        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func cgThumbnailCG(url: URL, side: CGFloat, quality: ThumbnailQuality, isLocal: Bool) -> CGImage? {
        if Task.isCancelled { return nil }
        // Force a full-image decode (skip the file's tiny embedded thumbnail — the
        // usual cause of soft NAS tiles) when the tier wants it: locally at Balanced+,
        // and over SMB at High/Maximum. Never for RAW over SMB (huge file per tile;
        // its embedded preview is already large).
        let isRaw = MediaKind.rawExts.contains(url.pathExtension.lowercased())
        let forceFullDecode = isLocal ? quality.fullDecode
                                      : (quality.fullDecodeOverNetwork && !isRaw)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: forceFullDecode,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * quality.pixelScale),
            kCGImageSourceCreateThumbnailWithTransform: true,      // honor EXIF orientation
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if Task.isCancelled { return nil }                         // bail before the expensive decode
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// QuickLook fallback for anything ImageIO can't thumbnail (some video/RAW).
    private static func qlThumbnail(url: URL, side: CGFloat) async -> NSImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: side, height: side), scale: 2,
                representationTypes: .thumbnail)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                cont.resume(returning: rep?.nsImage)
            }
        }
    }

    /// Encode a CGImage straight to a JPEG on disk (no TIFF round-trip), at the
    /// tier's compression. Same pixels, cheaper.
    private static func writeJPEG(_ cg: CGImage, to url: URL, compression: CGFloat) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: compression] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
