import SwiftUI
import Observation
import OffloadCore
import OffloadEngine

/// One tile in the grid. A RAW+JPEG pair collapses into a single item: the JPEG
/// is shown, the RAW rides along (openable via right-click, deleted with it).
struct DisplayItem: Identifiable, Sendable {
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

    // GPS coverage for the current root (populated after Analyze). Answers
    // "how many of my photos even have location" before we build place-names.
    private(set) var geoWithGPS = 0
    private(set) var geoChecked = 0
    var geoSummary: String? {
        guard geoChecked > 0 else { return nil }
        return "\(geoWithGPS.formatted()) of \(geoChecked.formatted()) photos have GPS"
    }

    // Faces & pets (opt-in "Find Faces" pass; embeddings + names stay on this Mac).
    private(set) var findingFaces = false
    private(set) var facesDone = 0
    private(set) var facesTotal = 0
    private(set) var identities: [Identity] = []
    private(set) var faceUnnamed = 0
    var facesSummary: String? {
        guard !identities.isEmpty || faceUnnamed > 0 else { return nil }
        var parts: [String] = []
        if !identities.isEmpty { parts.append("\(identities.count) named") }
        if faceUnnamed > 0 { parts.append("\(faceUnnamed) to review") }
        return parts.joined(separator: " · ")
    }

    private let browser = LibraryBrowser()
    private let analyzer = PhotoAnalyzer()
    let photoIndex = PhotoIndex()
    let faceIndex = FaceIndex()
    let identityIndex = IdentityIndex()
    private let faceDetector = FaceDetector()
    @ObservationIgnored private var faceTask: Task<Void, Never>?
    @ObservationIgnored private var faceEpoch = 0
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var analyzeTask: Task<Void, Never>?
    @ObservationIgnored private var analyzeEpoch = 0
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

    /// Header title for the current source — the mounted volume's own name (so it
    /// reads correctly on anyone's machine, not a hard-coded NAS name), or "SD Card".
    var sourceTitle: String {
        switch source {
        case .card: return "SD Card"
        case .nas:
            guard let root = rootURL else { return "Photos" }
            let name = (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            return name ?? root.lastPathComponent
        }
    }

    /// Breadcrumb labels (root shown as the source name).
    var breadcrumb: [(label: String, index: Int)] {
        pathStack.enumerated().map { i, url in
            (i == 0 ? (source == .nas ? "Photos" : "Card") : url.lastPathComponent, i)
        }
    }

    /// A human-readable label for the currently-open date folder, e.g.
    /// "Saturday, July 4th, 2026" for 2026/07/04, "July 2026" for a month,
    /// "2026" for a year — nil at the root or in a non-date folder (e.g. a card).
    var currentDateLabel: String? {
        guard source == .nas, let root = rootURL, let dir = currentDir, dir.path != root.path else { return nil }
        return DateFolders.headerLabel(folderPath: dir.path, rootPath: root.path)
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
        Task { await refreshFaceState() }
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

    /// Files a delete will remove: everything grouped into the tile, plus any
    /// on-disk RAW or sidecar (XMP/THM/…) that shares the basename. Deliberately
    /// does NOT sweep in unrelated same-stem files (a .txt/.mp3) or a video that
    /// wasn't already part of the tile. Does a directory listing — call off-main.
    nonisolated static func deleteTargets(for item: DisplayItem) -> [URL] {
        var set = Set(item.all.map(\.url))
        let primary = item.primary.url
        let dir = primary.deletingLastPathComponent()
        let base = primary.deletingPathExtension().lastPathComponent.lowercased()
        if let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for u in items where u.deletingPathExtension().lastPathComponent.lowercased() == base {
                let ext = u.pathExtension.lowercased()
                if MediaKind.rawExts.contains(ext) || MediaKind.sidecarExts.contains(ext) { set.insert(u) }
            }
        }
        return Array(set)
    }

    func delete(_ item: DisplayItem) async {
        await deleteFiles(for: [item])
    }

    // MARK: - Multi-selection

    var selection: Set<String> = []
    @ObservationIgnored private var anchorID: String?
    var selectedCount: Int { selection.count }

    /// Click behavior: plain = select only; ⌘ = toggle; ⇧ = range from anchor.
    /// Folders never select (they navigate).
    func handleTap(_ item: DisplayItem, command: Bool, shift: Bool) {
        guard !item.isFolder else { clearSelection(); return }
        let ids = displayedItems.filter { !$0.isFolder }.map(\.id)
        if shift, let anchor = anchorID,
           let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: item.id) {
            selection = Set(ids[min(a, b)...max(a, b)])
        } else if command {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchorID = item.id
        } else {
            selection = [item.id]
            anchorID = item.id
        }
    }

    func clearSelection() { selection.removeAll(); anchorID = nil }

    func selectAllPhotos() {
        selection = Set(displayedItems.filter { !$0.isFolder }.map(\.id))
        anchorID = selection.first
    }

    func deleteSelection() async {
        let items = displayedItems.filter { selection.contains($0.id) && !$0.isFolder }
        await deleteFiles(for: items)
    }

    private func deleteFiles(for items: [DisplayItem]) async {
        guard !items.isEmpty else { return }
        let targets = await Task.detached(priority: .userInitiated) {
            var urls = Set<URL>()
            for item in items { urls.formUnion(Self.deleteTargets(for: item)) }
            return urls
        }.value
        await Task.detached(priority: .userInitiated) {
            // Move to the Trash rather than hard-unlink, so a mistaken delete is
            // recoverable. (Falls back to a hard delete if the volume has no Trash.)
            for url in targets {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch { try? FileManager.default.removeItem(at: url) }
            }
        }.value
        await photoIndex.remove(paths: targets.map(\.path))
        await photoIndex.save()
        // Drop the deleted files from the in-memory lists right away so the grid
        // and the open viewer reflect the removal synchronously (the authoritative
        // reload below reconciles a beat later).
        entries.removeAll { targets.contains($0.url) }
        searchResults?.removeAll { targets.contains($0.url) }
        clearSelection()
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
            let stats = await index.geoStats(underPrefix: prefix)
            guard let self else { return }
            self.suggestions = tags
            self.geoWithGPS = stats.withGPS
            self.geoChecked = stats.checked
        }
    }

    // MARK: - AI analysis

    func analyzeCurrentSource() {
        guard !analyzing, let root = rootURL else { return }
        analyzing = true
        analyzeDone = 0
        analyzeTotal = 0
        analyzeEpoch += 1
        let epoch = analyzeEpoch
        let browser = self.browser
        let analyzer = self.analyzer
        let index = photoIndex
        analyzeTask = Task { [weak self] in
            let media = await Task.detached(priority: .utility) { browser.allMedia(root: root) }.value
            // One representative per RAW+JPEG pair — no point analyzing both.
            let primaries = Self.primaryEntries(media)
            // Drop index entries for photos that no longer exist under this root.
            await index.pruneMissing(underPrefix: root.path, keeping: Set(media.map(\.id)))
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
                await withTaskGroup(of: (String, PhotoRecord).self) { group in
                    for e in batch {
                        group.addTask {
                            // Always store a record (empty if Vision found nothing)
                            // so an unlabelable photo isn't re-analyzed every run.
                            let result = analyzer.analyze(url: e.url)
                            let rec = PhotoRecord(path: e.id, size: e.size, mtime: e.modified,
                                                  labels: result?.labels ?? [], animals: result?.animals ?? [],
                                                  location: result?.location, gpsChecked: true)
                            return (e.id, rec)
                        }
                    }
                    for await (path, rec) in group {
                        await index.put(rec)
                        await MainActor.run { [weak self] in
                            self?.analyzeDone += 1
                            let tags = Array(rec.tags.prefix(3))
                            if !tags.isEmpty { self?.tagsByPath[path] = tags }
                        }
                    }
                }
                i += width
            }

            // Cheap GPS backfill (header-only, no Vision) for photos analyzed
            // before GPS support, so coverage reflects the whole library.
            let todoIDs = Set(todo.map(\.id))
            var gpsTodo: [LibraryEntry] = []
            for e in primaries where !todoIDs.contains(e.id) {
                if await index.needsGPSCheck(path: e.id) { gpsTodo.append(e) }
            }
            await MainActor.run { [weak self] in self?.analyzeTotal += gpsTodo.count }
            var g = 0
            while g < gpsTodo.count {
                if Task.isCancelled { break }
                let batch = Array(gpsTodo[g..<min(g + width, gpsTodo.count)])
                await withTaskGroup(of: (String, GeoPoint?).self) { group in
                    for e in batch { group.addTask { (e.id, analyzer.gpsOnly(url: e.url)) } }
                    for await (path, geo) in group {
                        await index.setGPS(path: path, location: geo)
                        await MainActor.run { [weak self] in self?.analyzeDone += 1 }
                    }
                }
                g += width
            }

            await index.save()
            let stats = await index.geoStats(underPrefix: root.path)
            guard let self else { return }
            await MainActor.run {
                // Ignore a stale task that a newer Analyze run superseded.
                guard self.analyzeEpoch == epoch else { return }
                self.analyzing = false
                self.geoWithGPS = stats.withGPS
                self.geoChecked = stats.checked
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

    // MARK: - Faces & pets (opt-in, on-device, local-only)

    /// Heavier than content Analyze: face detection needs a larger decode per
    /// photo, so it's a separate action. Detects faces/pets, embeds each, proposes
    /// (never auto-assigns) an identity, and stores the result locally.
    func findFaces() {
        guard !findingFaces, let root = rootURL else { return }
        findingFaces = true
        facesDone = 0
        facesTotal = 0
        faceEpoch += 1
        let epoch = faceEpoch
        let browser = self.browser
        let detector = self.faceDetector
        let faces = faceIndex
        let ids = identityIndex
        faceTask = Task { [weak self] in
            let media = await Task.detached(priority: .utility) { browser.allMedia(root: root) }.value
            let primaries = Self.primaryEntries(media)
            await faces.pruneMissing(underPrefix: root.path, keeping: Set(media.map(\.id)))
            var todo: [LibraryEntry] = []
            for e in primaries where await faces.needsScan(path: e.id) { todo.append(e) }
            await MainActor.run { [weak self] in self?.facesTotal = todo.count }

            let width = 2   // larger decode + per-crop embeds — go easier than Analyze
            var i = 0
            while i < todo.count {
                if Task.isCancelled { break }
                let batch = Array(todo[i..<min(i + width, todo.count)])
                await withTaskGroup(of: (String, [Detection]).self) { group in
                    for e in batch { group.addTask { (e.id, detector.detect(url: e.url)) } }
                    for await (path, dets) in group {
                        var stamped: [Detection] = []
                        for var d in dets {
                            if let s = await ids.suggest(for: d.embedding, embedderID: d.embedderID,
                                                         kind: d.identityKind, excluding: d.rejectedIDs) {
                                d.suggestedID = s.id
                            }
                            stamped.append(d)
                        }
                        await faces.setDetections(stamped, for: path)
                        await MainActor.run { [weak self] in self?.facesDone += 1 }
                    }
                }
                i += width
            }
            await faces.save()
            guard let self else { return }
            await self.refreshFaceState()
            await MainActor.run {
                guard self.faceEpoch == epoch else { return }
                self.findingFaces = false
                if self.isSearching { self.runSearch() }
            }
        }
    }

    func cancelFindFaces() {
        faceTask?.cancel()
        findingFaces = false
        Task { await faceIndex.save() }
    }

    /// Reload the named-identity list + unnamed count (after a scan or a label).
    func refreshFaceState() async {
        let all = await identityIndex.all()
        let counts = await faceIndex.counts(underPrefix: rootURL?.path)
        identities = all
        faceUnnamed = counts.unnamed
    }

    /// Erase all locally-stored face/pet embeddings and names.
    func deleteAllFaceData() {
        Task {
            await faceIndex.deleteAll()
            await identityIndex.deleteAll()
            identities = []
            faceUnnamed = 0
        }
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
        clearSelection()
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
