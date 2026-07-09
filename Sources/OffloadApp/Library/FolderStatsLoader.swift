import Foundation
import OffloadEngine

/// Recursive media count + total bytes for a folder, so a date-folder card can show
/// "N photos · X GB" at a glance. Reuses LibraryBrowser.countMedia (the same recursive
/// enumeration the library total uses), memory-cached per folder path + mtime, with
/// bounded concurrency so browsing a month view doesn't storm the NAS. Loaded lazily
/// per visible tile, exactly like the folder preview collage.
struct FolderStats: Sendable { let count: Int; let bytes: Int64 }

final class FolderStatsLoader: @unchecked Sendable {
    static let shared = FolderStatsLoader()

    private final class Box { let stats: FolderStats; init(_ s: FolderStats) { stats = s } }
    private let mem: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 600
        return c
    }()
    private let browser = LibraryBrowser()
    private let limiter = ThumbLimiter(limit: 3)

    func stats(folder: URL, mtime: Date) async -> FolderStats? {
        let key = "\(folder.path)|\(Int(mtime.timeIntervalSince1970))" as NSString
        if let box = mem.object(forKey: key) { return box.stats }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }

        let browser = self.browser
        let result: FolderStats = await Task.detached(priority: .utility) {
            var count = 0
            var bytes: Int64 = 0
            // countMedia reports totals on every ~250 files AND once at the end, so
            // capturing the last callback yields the exact final count/bytes.
            browser.countMedia(root: folder, isCancelled: { Task.isCancelled }) { c, b, _ in
                count = c; bytes = b
            }
            return FolderStats(count: count, bytes: bytes)
        }.value
        if Task.isCancelled { return nil }
        mem.setObject(Box(result), forKey: key)
        return result
    }
}
