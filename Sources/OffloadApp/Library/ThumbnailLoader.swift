import SwiftUI
import ImageIO
import CryptoKit
import QuickLookThumbnailing
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
/// Three wins over the naive approach:
/// 1. **Embedded previews.** `CGImageSourceCreateThumbnailAtIndex` with
///    `…FromImageIfAbsent` pulls the JPEG/RAW file's *embedded* thumbnail —
///    kilobytes over SMB instead of downloading a 50 MB RAW to decode it.
/// 2. **Two-tier cache.** In-memory NSCache + an on-disk JPEG cache under
///    Application Support, keyed by path+size+mtime, so revisits (and relaunches)
///    are instant and re-fetch nothing from the NAS.
/// 3. **Bounded concurrency.** At most a handful of NAS reads at once.
final class ThumbnailLoader: @unchecked Sendable {
    static let shared = ThumbnailLoader()

    private let mem: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 800; return c
    }()
    private let limiter = ThumbLimiter(limit: 6)
    private let cacheDir: URL

    init() {
        cacheDir = Paths.appSupport.appendingPathComponent("ThumbCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let dir = cacheDir
        Task.detached(priority: .background) { Self.trimCache(dir, maxBytes: 500 << 20) }
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

    private func key(path: String, size: Int64, mtime: Date, side: CGFloat, quality: ThumbnailQuality) -> String {
        let s = "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970))|\(Int(side))|q\(quality.rawValue)"
        let hash = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(40))
    }

    func thumbnail(url: URL, size: Int64, mtime: Date, side: CGFloat,
                   quality: ThumbnailQuality = .current) async -> NSImage? {
        let k = key(path: url.path, size: size, mtime: mtime, side: side, quality: quality)
        if let hit = mem.object(forKey: k as NSString) { return hit }

        let diskURL = cacheDir.appendingPathComponent(k + ".jpg")
        if let img = NSImage(contentsOf: diskURL) {
            mem.setObject(img, forKey: k as NSString)
            return img
        }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }

        // ImageIO off the main actor; QuickLook fallback is its own async bridge —
        // never a blocking wait on a cooperative thread.
        var img = await Task.detached(priority: .utility) { Self.cgThumbnail(url: url, side: side, quality: quality) }.value
        if img == nil { img = await Self.qlThumbnail(url: url, side: side) }
        if let img {
            mem.setObject(img, forKey: k as NSString)
            Self.writeJPEG(img, to: diskURL, compression: quality.jpegCompression)
        }
        return img
    }

    // MARK: - Generation

    private static func cgThumbnail(url: URL, side: CGFloat, quality: ThumbnailQuality) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            // Higher qualities decode the full image for a sharp thumbnail; Fast
            // prefers the file's (small) embedded preview — quick, but softer.
            kCGImageSourceCreateThumbnailFromImageAlways: quality.fullDecode,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * quality.pixelScale),
            kCGImageSourceCreateThumbnailWithTransform: true,      // honor EXIF orientation
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// QuickLook fallback for anything ImageIO can't thumbnail (some video/RAW).
    /// Bridged via a continuation — QuickLook runs on its own queue, so we never
    /// block a Swift-concurrency cooperative thread.
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

    private static func writeJPEG(_ image: NSImage, to url: URL, compression: CGFloat) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: compression]) else { return }
        try? data.write(to: url)
    }
}
