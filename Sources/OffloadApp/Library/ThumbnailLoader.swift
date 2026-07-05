import SwiftUI
import QuickLookThumbnailing

/// Lazy QuickLook thumbnails with an in-memory LRU cache. QLThumbnailGenerator
/// handles RAW (ARW/CR3/…) and video posters; over SMB it's slower, so we ask
/// for small sizes and cache aggressively. Keyed by path + pixel size.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 400
        return c
    }()

    func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side))
    }

    func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        let k = key(url, side)
        if let hit = cache.object(forKey: k) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: 2,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
        if let image { cache.setObject(image, forKey: k) }
        return image
    }

    private func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(url.path)@\(Int(side))" as NSString
    }
}
