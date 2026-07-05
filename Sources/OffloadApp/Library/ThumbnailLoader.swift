import SwiftUI
import ImageIO
import CryptoKit
import QuickLookThumbnailing
import OffloadCore

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
    }

    private func key(path: String, size: Int64, mtime: Date, side: CGFloat) -> String {
        let s = "\(path)|\(size)|\(Int(mtime.timeIntervalSince1970))|\(Int(side))"
        let hash = SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hash.prefix(40))
    }

    func thumbnail(url: URL, size: Int64, mtime: Date, side: CGFloat) async -> NSImage? {
        let k = key(path: url.path, size: size, mtime: mtime, side: side)
        if let hit = mem.object(forKey: k as NSString) { return hit }

        let diskURL = cacheDir.appendingPathComponent(k + ".jpg")
        if let img = NSImage(contentsOf: diskURL) {
            mem.setObject(img, forKey: k as NSString)
            return img
        }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }

        let img = await Task.detached(priority: .utility) { Self.generate(url: url, side: side) }.value
        if let img {
            mem.setObject(img, forKey: k as NSString)
            Self.writeJPEG(img, to: diskURL)
        }
        return img
    }

    // MARK: - Generation (off-main)

    private static func generate(url: URL, side: CGFloat) -> NSImage? {
        let maxPixel = Int(side * 2)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: false,   // prefer the embedded preview
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,      // honor EXIF orientation
        ]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        return qlFallback(url: url, side: side)
    }

    /// QuickLook fallback for anything ImageIO can't thumbnail (some video/RAW).
    private static func qlFallback(url: URL, side: CGFloat) -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: 2,
            representationTypes: .thumbnail)
        let sem = DispatchSemaphore(value: 0)
        var result: NSImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            result = rep?.nsImage
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 20)
        return result
    }

    private static func writeJPEG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        try? data.write(to: url)
    }
}
