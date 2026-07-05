import SwiftUI
import Observation
import OffloadCore
import OffloadEngine

/// One tile in the grid. A RAW+JPEG pair collapses into a single item: the JPEG
/// is shown, the RAW rides along (openable via right-click, deleted with it).
struct DisplayItem: Identifiable {
    let id: String
    let isFolder: Bool
    let primary: LibraryEntry       // folder, or the shown photo (JPEG preferred)
    let raw: LibraryEntry?
    let all: [LibraryEntry]         // every file this item represents

    init(folder: LibraryEntry) {
        id = folder.id; isFolder = true; primary = folder; raw = nil; all = [folder]
    }
    init(group: [LibraryEntry]) {
        let p = LibraryModel.pickPrimary(group)
        id = p.id; isFolder = false; primary = p
        raw = group.first { if case .media(.raw) = $0.kind { return true }; return false }
        all = group
    }
}

/// Drives the Library window: which source (NAS or card), the current folder
/// path within it, the entries to show, and the progressive media count.
@MainActor @Observable
final class LibraryModel {
    enum Source: Equatable { case nas, card }

    var source: Source = .nas
    private(set) var pathStack: [URL] = []       // root … current
    private(set) var entries: [LibraryEntry] = []
    private(set) var loading = false

    // Overview counts for the current source root.
    private(set) var totalMedia: Int?
    private(set) var totalBytes: Int64 = 0
    private(set) var countComplete = false
    private(set) var freeBytes: Int64 = 0
    private(set) var totalVolumeBytes: Int64 = 0
    private(set) var mounted = false

    // Content search / AI analysis.
    var searchText = "" { didSet { if searchText != oldValue { runSearch() } } }
    private(set) var searchResults: [LibraryEntry]?      // nil = not searching
    private(set) var analyzing = false
    private(set) var analyzeDone = 0
    private(set) var analyzeTotal = 0
    private(set) var suggestions: [(tag: String, count: Int)] = []
    private(set) var tagsByPath: [String: [String]] = [:]   // for tile overlays

    private let browser = LibraryBrowser()
    private let analyzer = PhotoAnalyzer()
    let photoIndex = PhotoIndex()
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var analyzeTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var nasRootPath: String
    @ObservationIgnored private var cardRootPath: String?

    init(nasRootPath: String, cardRootPath: String?) {
        self.nasRootPath = nasRootPath
        self.cardRootPath = cardRootPath
    }

    var hasCard: Bool { cardRootPath != nil }
    var currentDir: URL? { pathStack.last }
    var rootURL: URL? { pathStack.first }

    /// Breadcrumb labels (root shown as the source name).
    var breadcrumb: [(label: String, index: Int)] {
        pathStack.enumerated().map { i, url in
            (i == 0 ? (source == .nas ? "Photos" : "Card") : url.lastPathComponent, i)
        }
    }

    func update(nasRootPath: String, cardRootPath: String?) {
        let cardChanged = self.cardRootPath != cardRootPath
        self.nasRootPath = nasRootPath
        self.cardRootPath = cardRootPath
        if source == .card && cardRootPath == nil {
            select(.nas)               // card ejected while viewing it
        } else if cardChanged && source == .card, let root = cardRootPath {
            openRoot(URL(fileURLWithPath: root))
        }
    }

    func select(_ newSource: Source) {
        guard newSource != source || pathStack.isEmpty else { return }
        source = newSource
        switch newSource {
        case .nas:
            openRoot(URL(fileURLWithPath: nasRootPath, isDirectory: true))
        case .card:
            guard let card = cardRootPath else { return }
            // Prefer DCIM if present, else the mount root.
            let dcim = URL(fileURLWithPath: card).appendingPathComponent("DCIM", isDirectory: true)
            let root = FileManager.default.fileExists(atPath: dcim.path) ? dcim
                : URL(fileURLWithPath: card, isDirectory: true)
            openRoot(root)
        }
    }

    private func openRoot(_ root: URL) {
        pathStack = [root]
        searchText = ""
        searchResults = nil
        refreshVolumeStats(root)
        loadEntries()
        startCount(root)
        refreshSuggestions()
    }

    /// What the grid shows: content-search results when searching, else the
    /// current folder's contents.
    var displayedEntries: [LibraryEntry] { searchResults ?? entries }
    var isSearching: Bool { searchResults != nil }

    /// Grid items with RAW+JPEG pairs collapsed. Folders first, then photos.
    var displayedItems: [DisplayItem] {
        var folders: [DisplayItem] = []
        var byKey: [String: [LibraryEntry]] = [:]
        var order: [String] = []
        for e in displayedEntries {
            if e.isFolder { folders.append(DisplayItem(folder: e)); continue }
            let key = Self.groupKey(e.id)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(e)
        }
        return folders + order.map { DisplayItem(group: byKey[$0]!) }
    }

    func tags(for entry: LibraryEntry) -> [String] { tagsByPath[entry.id] ?? [] }

    /// Directory + basename (no extension), so DSCF0037.JPG and DSCF0037.RAF group.
    nonisolated static func groupKey(_ path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        return dir + "/" + base
    }

    nonisolated static func pickPrimary(_ group: [LibraryEntry]) -> LibraryEntry {
        group.first { if case .media(.photo) = $0.kind { return true }; return false }
            ?? group.first { if case .media(.video) = $0.kind { return true }; return false }
            ?? group[0]
    }

    /// One representative per RAW+JPEG group (JPEG preferred) — avoids analyzing
    /// a RAW when its JPEG twin carries the same content.
    nonisolated static func primaryEntries(_ media: [LibraryEntry]) -> [LibraryEntry] {
        var byKey: [String: [LibraryEntry]] = [:]
        var order: [String] = []
        for e in media {
            let key = groupKey(e.id)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(e)
        }
        return order.map { pickPrimary(byKey[$0]!) }
    }

    // MARK: - Delete + RAW helpers

    /// The RAW file that pairs with this photo, if one exists on disk (even when
    /// it isn't in the current view, e.g. content-search results).
    func rawSibling(of url: URL) -> URL? {
        siblingFiles(of: url).first {
            MediaKind.classify(ext: $0.pathExtension) == .raw
        }
    }

    /// All files in the same folder sharing this file's basename — the JPEG, its
    /// RAW, and any sidecars (THM/XMP). Deleting a photo removes the whole set.
    func siblingFiles(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent.lowercased()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [url] }
        let sibs = items.filter { $0.deletingPathExtension().lastPathComponent.lowercased() == base }
        return sibs.isEmpty ? [url] : sibs
    }

    func delete(_ item: DisplayItem) async {
        let targets = siblingFiles(of: item.primary.url)
        for url in targets { try? FileManager.default.removeItem(at: url) }
        await photoIndex.remove(paths: targets.map(\.path))
        await photoIndex.save()
        if isSearching { runSearch() } else { loadEntries() }
        if let root = rootURL { startCount(root); refreshVolumeStats(root) }
    }

    // MARK: - Content search

    private func runSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { searchResults = nil; return }
        guard let prefix = rootURL?.path else { return }
        let index = photoIndex
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))   // debounce typing
            guard !Task.isCancelled else { return }
            let paths = await index.search(query, underPrefix: prefix)
            let recs = await index.records(forPaths: Array(paths))
            guard let self, !Task.isCancelled else { return }
            let results = recs.values
                .map { rec -> LibraryEntry in
                    let kind: LibraryEntry.Kind = MediaKind.classify(ext: (rec.path as NSString).pathExtension)
                        .map { .media($0) } ?? .media(.photo)
                    return LibraryEntry(id: rec.path, name: (rec.path as NSString).lastPathComponent,
                                        kind: kind, size: rec.size, modified: rec.mtime)
                }
                .sorted { $0.name < $1.name }
            self.searchResults = results
        }
    }

    private func refreshSuggestions() {
        guard let prefix = rootURL?.path else { return }
        let index = photoIndex
        Task { [weak self] in
            let tags = await index.topTags(underPrefix: prefix)
            guard let self else { return }
            self.suggestions = tags
        }
    }

    // MARK: - AI analysis

    func analyzeCurrentSource() {
        guard !analyzing, let root = rootURL else { return }
        analyzing = true
        analyzeDone = 0
        analyzeTotal = 0
        let browser = self.browser
        let analyzer = self.analyzer
        let index = photoIndex
        analyzeTask = Task { [weak self] in
            let media = await Task.detached(priority: .utility) { browser.allMedia(root: root) }.value
            // One representative per RAW+JPEG pair — no point analyzing both.
            let primaries = Self.primaryEntries(media)
            var todo: [LibraryEntry] = []
            for e in primaries where await index.needsAnalysis(path: e.id, mtime: e.modified) {
                todo.append(e)
            }
            await MainActor.run { [weak self] in
                self?.analyzeTotal = todo.count
                self?.tagsByPath.reserveCapacity(primaries.count)
            }
            // Populate tag overlays for already-analyzed photos too.
            let existing = await index.records(forPaths: primaries.map(\.id))
            await MainActor.run { [weak self] in
                for (p, r) in existing { self?.tagsByPath[p] = Array(r.tags.prefix(3)) }
            }

            // Analyze up to 4 at a time.
            let width = 4
            var i = 0
            while i < todo.count {
                if Task.isCancelled { break }
                let batch = Array(todo[i..<min(i + width, todo.count)])
                await withTaskGroup(of: (String, PhotoRecord?).self) { group in
                    for e in batch {
                        group.addTask {
                            let r = analyzer.analyze(url: e.url).map {
                                PhotoRecord(path: e.id, size: e.size, mtime: e.modified,
                                            labels: $0.labels, animals: $0.animals)
                            }
                            return (e.id, r)
                        }
                    }
                    for await (path, rec) in group {
                        if let rec { await index.put(rec) }
                        await MainActor.run { [weak self] in
                            self?.analyzeDone += 1
                            if let rec { self?.tagsByPath[path] = Array(rec.tags.prefix(3)) }
                        }
                    }
                }
                i += width
            }
            await index.save()
            guard let self else { return }
            await MainActor.run {
                self.analyzing = false
                self.refreshSuggestions()
                if self.isSearching { self.runSearch() }
            }
        }
    }

    func cancelAnalysis() {
        analyzeTask?.cancel()
        analyzing = false
        Task { await photoIndex.save() }
    }

    func enter(_ entry: LibraryEntry) {
        guard entry.isFolder else { return }
        pathStack.append(entry.url)
        loadEntries()
    }

    func navigate(toBreadcrumb index: Int) {
        guard index < pathStack.count - 1 else { return }
        pathStack = Array(pathStack.prefix(index + 1))
        loadEntries()
    }

    func refresh() {
        if let root = rootURL { refreshVolumeStats(root); startCount(root) }
        loadEntries()
    }

    private func loadEntries() {
        guard let dir = currentDir else { entries = []; return }
        loading = true
        let browser = self.browser
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                browser.browse(dir)
            }.value
            self.entries = result
            self.loading = false
        }
    }

    private func refreshVolumeStats(_ root: URL) {
        // statfs is accurate on SMB; volumeAvailableCapacityForImportantUsage
        // returns 0 on network shares (it's an APFS purgeable-space concept).
        if let fs = statfsInfo(path: root.path) {
            freeBytes = fs.freeBytes
            totalVolumeBytes = fs.totalBytes
            mounted = true
        } else {
            freeBytes = 0
            totalVolumeBytes = 0
            mounted = false
        }
    }

    private func startCount(_ root: URL) {
        countTask?.cancel()
        let cached = LibraryIndex.load(rootPath: root.path)
        totalMedia = cached?.totalMedia
        totalBytes = cached?.totalBytes ?? 0
        countComplete = false
        let browser = self.browser
        let isNAS = source == .nas
        countTask = Task { [weak self] in
            // Bridge the synchronous walk (on a utility thread) to the main
            // actor through a stream — no shared mutable state to race on.
            let stream = AsyncStream<(Int, Int64)> { continuation in
                Task.detached(priority: .utility) {
                    browser.countMedia(root: root, isCancelled: { Task.isCancelled }) { count, bytes, _ in
                        continuation.yield((count, bytes))
                    }
                    continuation.finish()
                }
            }
            var final: (count: Int, bytes: Int64) = (0, 0)
            for await (count, bytes) in stream {
                self?.totalMedia = count
                self?.totalBytes = bytes
                final = (count, bytes)
            }
            guard let self, !Task.isCancelled else { return }
            self.countComplete = true
            if isNAS {
                LibraryIndex(rootPath: root.path, totalMedia: final.count, totalBytes: final.bytes,
                             updatedAt: Date(), complete: true).save()
            }
        }
    }
}
