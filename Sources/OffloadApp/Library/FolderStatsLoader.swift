import Foundation
import OffloadCore
import OffloadEngine

/// Recursive media count + total bytes for a folder, so a date-folder card can show
/// "N photos · X GB" at a glance. Reuses LibraryBrowser.countMedia, and — the key perf
/// win — PERSISTS results to disk keyed by folder path + mtime, so reopening the
/// Library (or the app) serves them instantly instead of re-walking every visible
/// folder's subtree over SMB. Concurrency is bounded so a month view doesn't storm
/// the NAS. (Caveat: a folder's mtime only changes when its direct children change, so
/// a deep add may leave a parent count stale until Refresh — see invalidateAll().)
struct FolderStats: Sendable, Codable { let count: Int; let bytes: Int64 }

/// `countMedia` reports through a `@Sendable` callback. Keep the progressive
/// result in a tiny locked box so this remains valid when the package moves to
/// Swift 6 language mode as well as today's Swift 5 compatibility mode.
private final class FolderStatsAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var value = FolderStats(count: 0, bytes: 0)

    func update(count: Int, bytes: Int64) {
        lock.lock(); value = FolderStats(count: count, bytes: bytes); lock.unlock()
    }

    func snapshot() -> FolderStats {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class FolderStatsLoader: @unchecked Sendable {
    static let shared = FolderStatsLoader()

    private struct Entry: Codable { let mtime: Double; let stats: FolderStats }
    private let lock = NSLock()
    private var cache: [String: Entry]        // folder path → {mtime, stats}
    private let file: URL
    private let browser = LibraryBrowser()
    private let limiter = ThumbLimiter(limit: 3)

    init() {
        file = Paths.appSupport.appendingPathComponent("folder-stats.json", isDirectory: false)
        cache = JSONIO.loadGuarded([String: Entry].self, from: file) ?? [:]
    }

    func stats(folder: URL, mtime: Date) async -> FolderStats? {
        let path = folder.path
        let m = mtime.timeIntervalSince1970
        if let hit = peek(path: path, mtime: m) { return hit }   // persisted hit → no SMB walk

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }

        let browser = self.browser
        let result: FolderStats = await Task.detached(priority: .utility) {
            let accumulator = FolderStatsAccumulator()
            browser.countMedia(root: folder, isCancelled: { Task.isCancelled }) { count, bytes in
                accumulator.update(count: count, bytes: bytes)
            }
            return accumulator.snapshot()
        }.value
        if Task.isCancelled { return nil }
        store(path: path, mtime: m, stats: result)
        return result
    }

    /// Forget all cached stats — used by the Library's Refresh so a stale (deep-added)
    /// count can be rebuilt on demand.
    func invalidateAll() {
        lock.lock(); cache.removeAll(); lock.unlock()
        let f = file
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: f) }
    }

    private func peek(path: String, mtime: Double) -> FolderStats? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[path], abs(e.mtime - mtime) < 2 else { return nil }
        return e.stats
    }

    private func store(path: String, mtime: Double, stats: FolderStats) {
        lock.lock()
        cache[path] = Entry(mtime: mtime, stats: stats)
        let snapshot = cache
        lock.unlock()
        let f = file
        Task.detached(priority: .background) { try? JSONIO.save(snapshot, to: f) }
    }
}
