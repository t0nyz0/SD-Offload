import AppKit
import ImageIO
import OffloadCore

private final class CropBox { let image: NSImage?; init(_ i: NSImage?) { image = i } }

/// Crops a detected face/pet region out of a photo for the labeling UI. Decodes a
/// moderate-size copy once (embedded preview when possible), crops the (padded)
/// bounding box, and caches the result. Bounded concurrency so paging the viewer
/// doesn't hammer the NAS.
final class FaceCropLoader: @unchecked Sendable {
    static let shared = FaceCropLoader()

    private let mem: NSCache<NSString, CropBox> = {
        let c = NSCache<NSString, CropBox>(); c.countLimit = 1000; return c
    }()
    private let limiter = ThumbLimiter(limit: 4)

    func crop(url: URL, bbox: NormRect, mtime: Date) async -> NSImage? {
        let key = "\(url.path)|\(Int(mtime.timeIntervalSince1970))|\(bbox.x),\(bbox.y),\(bbox.w),\(bbox.h)" as NSString
        if let box = mem.object(forKey: key) { return box.image }
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        let img = await Task.detached(priority: .userInitiated) { Self.render(url, bbox) }.value
        mem.setObject(CropBox(img), forKey: key)
        return img
    }

    private static func render(_ url: URL, _ bbox: NormRect) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = Double(cg.width), h = Double(cg.height)
        let ex = bbox.w * 0.35, ey = bbox.h * 0.35                 // pad around the region
        let minX = max(0, bbox.x - ex), maxX = min(1, bbox.x + bbox.w + ex)
        let minY = max(0, bbox.y - ey), maxY = min(1, bbox.y + bbox.h + ey)
        // Vision bbox origin is bottom-left; CGImage crop is top-left.
        let rect = CGRect(x: minX * w, y: (1 - maxY) * h, width: (maxX - minX) * w, height: (maxY - minY) * h)
        guard rect.width >= 1, rect.height >= 1, let cropped = cg.cropping(to: rect) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }
}
