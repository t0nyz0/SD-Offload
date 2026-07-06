import AppKit
import OffloadCore
import OffloadEngine

private final class ImagesBox { let images: [NSImage]; init(_ i: [NSImage]) { images = i } }

/// Builds a small photo collage for a folder tile: samples a few media files
/// inside the folder and loads their thumbnails (reusing ThumbnailLoader's
/// two-tier cache), so a date folder shows a preview of what's inside instead
/// of a bland glyph. Results are memory-cached per folder path + mtime, and
/// concurrency is bounded so browsing a month view doesn't storm the NAS.
final class FolderPreviewLoader: @unchecked Sendable {
    static let shared = FolderPreviewLoader()

    private let mem: NSCache<NSString, ImagesBox> = {
        let c = NSCache<NSString, ImagesBox>()
        c.countLimit = 150
        c.totalCostLimit = 128 << 20   // byte budget: each box holds up to 4 decoded previews
        return c
    }()
    private let browser = LibraryBrowser()
    private let limiter = ThumbLimiter(limit: 3)   // each fans out to up to 4 thumbs

    func preview(folder: URL, mtime: Date, count: Int = 4, side: CGFloat = 200) async -> [NSImage] {
        let key = "\(folder.path)|\(Int(mtime.timeIntervalSince1970))|\(count)|\(Int(side))" as NSString
        if let box = mem.object(forKey: key) { return box.images }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return [] }

        let browser = self.browser
        let entries = await Task.detached(priority: .utility) {
            browser.sampleMedia(under: folder, limit: count)
        }.value

        var images: [NSImage] = []
        for e in entries {
            if let img = await ThumbnailLoader.shared.thumbnail(url: e.url, size: e.size,
                                                                mtime: e.modified, side: side) {
                images.append(img)
            }
        }
        let cost = images.reduce(0) { acc, img in
            let px = (img.representations.first as? NSBitmapImageRep).map { $0.pixelsWide * $0.pixelsHigh }
                     ?? Int(img.size.width * img.size.height)
            return acc + px * 4
        }
        mem.setObject(ImagesBox(images), forKey: key, cost: cost)
        return images
    }
}
