import SwiftUI
import Observation
import OffloadCore
import OffloadEngine

/// Which parts of a RAW+JPEG item a delete should remove.
enum DeleteScope: Sendable { case all, rawOnly, jpegOnly }

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

    /// The display photo in this item, if any.
    var photo: LibraryEntry? {
        all.first { if case .media(.photo) = $0.kind { return true }; return false }
    }
    /// A RAW that is a *distinct companion* to the shown photo — nil when the item
    /// is RAW-only (there the RAW is the primary, not a companion). This is the
    /// correct "is there a separate RAW" signal; `raw != nil` alone is true even for
    /// a lone RAW, which is what mislabeled RAW-only files as "JPEG + RAW".
    var rawCompanion: LibraryEntry? {
        guard let raw, raw.id != primary.id else { return nil }
        return raw
    }
    /// True when the item bundles both a display photo and a distinct RAW.
    var isRawJpegPair: Bool { photo != nil && rawCompanion != nil }
}

/// Drives the Library window: which source (NAS or card), the current folder
/// path within it, the entries to show, and the progressive media count.
@MainActor @Observable
final class LibraryModel {
    enum Source: Equatable { case nas, card, favorites, faces }

    var source: Source = .nas
    private(set) var pathStack: [URL] = []       // root … current
    private(set) var entries: [LibraryEntry] = [] { didSet { rebuildDisplayed() } }
    private(set) var loading = false
    // Cached grouping of displayedEntries, rebuilt ONLY when entries/searchResults
    // change — so selection taps, tag updates during Analyze, and grid re-renders
    // read O(1) instead of re-running the O(n) dictionary grouping every time.
    private(set) var displayedItems: [DisplayItem] = []
    private(set) var photoItems: [DisplayItem] = []
    private(set) var folderItems: [DisplayItem] = []

    // Favorites: a set of absolute photo paths (persisted), and the grouped,
    // date-sorted photos shown in the Favorites timeline.
    private(set) var favoritePaths: Set<String> = []
    private(set) var favoriteItems: [DisplayItem] = []
    // Pinned folders (absolute paths, ordered) shown in the sidebar for quick access.
    private(set) var pinnedFolders: [String] = []
    // Per-identity photo counts for the Faces gallery.
    private(set) var identityCounts: [UUID: Int] = [:]

    // Overview counts for the current source root.
    private(set) var totalMedia: Int?
    private(set) var totalBytes: Int64 = 0
    private(set) var countComplete = false
    private(set) var freeBytes: Int64 = 0
    private(set) var totalVolumeBytes: Int64 = 0
    private(set) var mounted = false

    // Set when a delete couldn't complete (read-only volume, locked/in-use file, …)
    // so the UI can surface it, instead of the file silently reappearing on reload.
    var deleteError: String?

    // Content search / AI analysis.
    var searchText = "" { didSet { if searchText != oldValue { runSearch() } } }
    private(set) var searchResults: [LibraryEntry]? { didSet { rebuildDisplayed() } }      // nil = not searching
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
    // Active people/pets filter label (nil = not filtering). Drives the filter chip;
    // reuses searchResults to show the matching photos in the grid.
    private(set) var faceFilterLabel: String?
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
        favoritePaths = Set(JSONIO.loadGuarded([String].self, from: Paths.favoritesFile) ?? [])
        pinnedFolders = JSONIO.loadGuarded([String].self, from: Paths.pinnedFoldersFile) ?? []
    }

    var hasCard: Bool { cardRootPath != nil }
    var currentDir: URL? { pathStack.last }
    var rootURL: URL? { pathStack.first }

    /// Header title for the current source — the mounted volume's own name (so it
    /// reads correctly on anyone's machine, not a hard-coded NAS name), or "SD Card".
    var sourceTitle: String {
        switch source {
        case .favorites: return "Favorites"
        case .faces: return "Faces"
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
        case .favorites:
            loadFavorites()
        case .faces:
            loadFaces()
        }
    }

    // MARK: - Favorites

    func isFavorite(_ path: String) -> Bool { favoritePaths.contains(path) }

    /// Toggle a photo's favorite state (keyed by the shown photo's path), persist,
    /// and refresh the timeline if it's on screen.
    func toggleFavorite(_ item: DisplayItem) {
        let path = item.primary.id
        if favoritePaths.contains(path) { favoritePaths.remove(path) } else { favoritePaths.insert(path) }
        saveFavorites()
        if source == .favorites { loadFavorites() }
    }

    private func saveFavorites() {
        let arr = Array(favoritePaths)
        Task.detached(priority: .utility) { try? JSONIO.save(arr, to: Paths.favoritesFile) }
    }

    /// Capture date for timeline grouping — parsed from the YYYY/MM/DD folder path,
    /// falling back to the file's modified date.
    func timelineDate(_ item: DisplayItem) -> Date {
        let comps = (item.primary.id as NSString).deletingLastPathComponent
            .split(separator: "/").suffix(3).map(String.init)
        return DateFolders.date(from: comps) ?? item.primary.modified
    }

    /// Build the Favorites timeline: resolve favorite paths to entries (dropping any
    /// whose file has gone), group RAW+JPEG, and sort oldest → newest by capture date.
    func loadFavorites() {
        source = .favorites
        pathStack = []
        searchText = ""
        searchResults = nil
        loading = true
        favoriteItems = []
        let paths = Array(favoritePaths)
        Task { [weak self] in
            guard let self else { return }
            let existing = await Task.detached(priority: .userInitiated) {
                paths.filter { FileManager.default.fileExists(atPath: $0) }
            }.value
            let built = await self.entries(forPaths: existing)
            let photos = Self.groupPhotos(built).sorted { self.timelineDate($0) < self.timelineDate($1) }
            self.favoriteItems = photos
            self.totalMedia = photos.count
            self.totalBytes = photos.reduce(0) { acc, it in acc + it.all.reduce(0) { $0 + $1.size } }
            self.countComplete = true
            self.loading = false
            if existing.count < paths.count {          // prune favorites pointing at deleted files
                self.favoritePaths = Set(existing)
                self.saveFavorites()
            }
        }
    }

    // MARK: - Faces gallery

    /// Show the Faces source: a gallery of every named person/pet. Loads the
    /// identities and their photo counts.
    func loadFaces() {
        source = .faces
        pathStack = []
        searchText = ""
        searchResults = nil
        faceFilterLabel = nil
        Task { [weak self] in
            guard let self else { return }
            await self.refreshFaceState()
            var counts: [UUID: Int] = [:]
            for idn in self.identities {
                counts[idn.id] = await self.faceIndex.photos(withIdentity: idn.id).count
            }
            self.identityCounts = counts
        }
    }

    /// Open a named person/pet: jump to the NAS source with that identity's filter
    /// applied — reuses the grid, viewer, and filter chip.
    func showIdentity(_ id: UUID) {
        if source != .nas { select(.nas) }
        filterByIdentity(id)
    }

    // MARK: - Pinned folders

    func isPinned(_ path: String) -> Bool { pinnedFolders.contains(path) }

    func togglePin(_ folder: DisplayItem) {
        let path = folder.primary.id
        if let i = pinnedFolders.firstIndex(of: path) { pinnedFolders.remove(at: i) }
        else { pinnedFolders.append(path) }
        savePinned()
    }

    func unpin(_ path: String) {
        pinnedFolders.removeAll { $0 == path }
        savePinned()
    }

    private func savePinned() {
        let arr = pinnedFolders
        Task.detached(priority: .utility) { try? JSONIO.save(arr, to: Paths.pinnedFoldersFile) }
    }

    /// Short sidebar label for a pinned folder — a friendly date for a date folder,
    /// else the folder's own name.
    func pinLabel(_ path: String) -> String {
        let comps = DateFolders.relComponents(path, root: nasRootPath)
        if let d = DateFolders.date(from: comps) {
            let f = DateFormatter(); f.locale = .current
            switch comps.count {
            case 1: return comps[0]                                          // "2026"
            case 2: f.setLocalizedDateFormatFromTemplate("LLLyyyy")          // "Jul 2026"
            default: f.setLocalizedDateFormatFromTemplate("MMMdyyyy")        // "Jul 4, 2026"
            }
            return f.string(from: d)
        }
        return (path as NSString).lastPathComponent
    }

    /// Navigate straight to a pinned folder (NAS source, full breadcrumb path).
    func openPinned(_ path: String) {
        let root = URL(fileURLWithPath: nasRootPath, isDirectory: true)
        source = .nas
        searchText = ""
        searchResults = nil
        faceFilterLabel = nil
        pathStack = Self.pathStack(from: root, to: URL(fileURLWithPath: path, isDirectory: true))
        refreshVolumeStats(root)
        loadEntries()
        startCount(root)
        refreshSuggestions()
        Task { await refreshFaceState() }
    }

    private static func pathStack(from root: URL, to target: URL) -> [URL] {
        let rootC = root.pathComponents, tgtC = target.pathComponents
        guard tgtC.count >= rootC.count, Array(tgtC.prefix(rootC.count)) == rootC else { return [root] }
        var stack = [root]; var cur = root
        for comp in tgtC[rootC.count...] {
            cur = cur.appendingPathComponent(comp, isDirectory: true)
            stack.append(cur)
        }
        return stack
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
    private func rebuildDisplayed() {
        var folders: [DisplayItem] = []
        var media: [LibraryEntry] = []
        for e in displayedEntries {
            if e.isFolder { folders.append(DisplayItem(folder: e)) } else { media.append(e) }
        }
        let photos = Self.groupPhotos(media)
        folderItems = folders
        photoItems = photos
        displayedItems = folders + photos
    }

    /// Group a flat media list into photo DisplayItems (RAW+JPEG paired), preserving
    /// input order. Folders excluded. Shared by the grid, search, and favorites.
    nonisolated static func groupPhotos(_ media: [LibraryEntry]) -> [DisplayItem] {
        var byKey: [String: [LibraryEntry]] = [:]
        var order: [String] = []
        for e in media where !e.isFolder {
            let key = groupKey(e.id)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(e)
        }
        return order.map { DisplayItem(group: byKey[$0]!) }
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
    nonisolated static func deleteTargets(for item: DisplayItem, scope: DeleteScope = .all) -> [URL] {
        switch scope {
        case .rawOnly:
            // Just the RAW file(s) — the JPEG (and its sidecars) stay.
            return item.all.compactMap { if case .media(.raw) = $0.kind { return $0.url }; return nil }
        case .jpegOnly:
            // Just the display photo — the RAW stays.
            return item.all.compactMap { if case .media(.photo) = $0.kind { return $0.url }; return nil }
        case .all:
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
    }

    func delete(_ item: DisplayItem, scope: DeleteScope = .all) async {
        let targets = await Task.detached(priority: .userInitiated) {
            Set(Self.deleteTargets(for: item, scope: scope))
        }.value
        await removeURLs(targets)
    }

    // MARK: - Multi-selection

    var selection: Set<String> = []
    @ObservationIgnored private var anchorID: String?
    var selectedCount: Int { selection.count }

    /// Click behavior: plain = select only; ⌘ = toggle; ⇧ = range from anchor.
    /// Folders never select (they navigate).
    func handleTap(_ item: DisplayItem, command: Bool, shift: Bool) {
        guard !item.isFolder else { clearSelection(); return }
        let ids = photoItems.map(\.id)
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
        selection = Set(photoItems.map(\.id))
        anchorID = selection.first
    }

    func deleteSelection() async {
        let items = photoItems.filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        let targets = await Task.detached(priority: .userInitiated) {
            var urls = Set<URL>()
            for item in items { urls.formUnion(Self.deleteTargets(for: item, scope: .all)) }
            return urls
        }.value
        await removeURLs(targets)
    }

    private func removeURLs(_ targets: Set<URL>) async {
        guard !targets.isEmpty else { return }
        // Move to the Trash rather than hard-unlink, so a mistaken delete is
        // recoverable. (Falls back to a hard delete if the volume has no Trash.)
        // Track what actually got removed so a failure isn't silently swallowed —
        // otherwise the file vanishes from the grid, then reappears on reload.
        let failed = await Task.detached(priority: .userInitiated) { () -> Set<URL> in
            var failures = Set<URL>()
            for url in targets {
                do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                catch {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { failures.insert(url) }
                }
            }
            return failures
        }.value
        let removed = targets.subtracting(failed)
        await photoIndex.remove(paths: removed.map(\.path))
        await photoIndex.save()
        // Drop only the files that actually went away from the in-memory lists so
        // the grid/viewer reflect the removal synchronously (the authoritative
        // reload below reconciles the rest).
        entries.removeAll { removed.contains($0.url) }
        searchResults?.removeAll { removed.contains($0.url) }
        // Drop any deleted photos from favorites.
        let removedFav = favoritePaths.intersection(Set(removed.map(\.path)))
        if !removedFav.isEmpty { favoritePaths.subtract(removedFav); saveFavorites() }
        clearSelection()
        if !failed.isEmpty {
            let n = failed.count
            deleteError = "Couldn't delete \(n) item\(n == 1 ? "" : "s"). The volume may be read-only, or the file\(n == 1 ? " may be" : "s may be") locked or in use."
        }
        if source == .favorites { loadFavorites() }
        else if isSearching { runSearch() } else { loadEntries() }
        if let root = rootURL { startCount(root); refreshVolumeStats(root) }
    }

    // MARK: - Content search

    private func runSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { searchResults = nil; faceFilterLabel = nil; return }
        faceFilterLabel = nil          // a content search replaces any active face filter
        guard let prefix = rootURL?.path else { return }
        let index = photoIndex
        let faces = faceIndex
        // Named people/pets whose name matches a query term (computed on the main
        // actor from the published list, then unioned into the content results).
        let terms = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let namedMatches = identities
            .filter { idn in terms.contains { idn.name.lowercased().contains($0) } }
            .map(\.id)
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))   // debounce typing
            guard !Task.isCancelled else { return }
            var paths = await index.search(query, underPrefix: prefix)
            for id in namedMatches { paths.formUnion(await faces.photos(withIdentity: id, underPrefix: prefix)) }
            guard let self, !Task.isCancelled else { return }
            self.searchResults = await self.entries(forPaths: Array(paths))
        }
    }

    /// Build display entries for a set of paths (a content search or a face filter):
    /// use the content index where available, stat the rest.
    private func entries(forPaths paths: [String]) async -> [LibraryEntry] {
        let recs = await photoIndex.records(forPaths: paths)
        return paths.map { path in
            let kind: LibraryEntry.Kind = MediaKind.classify(ext: (path as NSString).pathExtension)
                .map { .media($0) } ?? .media(.photo)
            if let rec = recs[path] {
                return LibraryEntry(id: path, name: (path as NSString).lastPathComponent,
                                    kind: kind, size: rec.size, modified: rec.mtime)
            }
            let vals = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LibraryEntry(id: path, name: (path as NSString).lastPathComponent, kind: kind,
                                size: Int64(vals?.fileSize ?? 0), modified: vals?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Faces filter (reuses searchResults to show matching photos)

    /// Show the photos that still have an unnamed face/pet to label.
    func reviewUnnamedFaces() {
        applyFaceFilter(label: "Faces to review") { faces, prefix in
            Set((await faces.unassigned(underPrefix: prefix)).map(\.path))
        }
    }

    /// Show every photo containing a specific named person/pet.
    func filterByIdentity(_ id: UUID) {
        let label = identities.first { $0.id == id }?.name ?? "Person"
        applyFaceFilter(label: label) { faces, prefix in
            await faces.photos(withIdentity: id, underPrefix: prefix)
        }
    }

    /// Show every photo containing any named identity of a kind (all people / all pets).
    func filterByKind(_ kind: Identity.Kind) {
        let ids = identities.filter { $0.kind == kind }.map(\.id)
        applyFaceFilter(label: kind == .pet ? "All pets" : "All people") { faces, prefix in
            var paths = Set<String>()
            for id in ids { paths.formUnion(await faces.photos(withIdentity: id, underPrefix: prefix)) }
            return paths
        }
    }

    func clearFaceFilter() {
        faceFilterLabel = nil
        searchResults = nil
    }

    private func applyFaceFilter(label: String,
                                 _ gather: @escaping @Sendable (FaceIndex, String?) async -> Set<String>) {
        searchTask?.cancel()
        searchText = ""            // face filter and text search are mutually exclusive
        faceFilterLabel = label    // set AFTER clearing searchText (its didSet nils this)
        let prefix = rootURL?.path
        let faces = faceIndex
        searchTask = Task { [weak self] in
            let paths = await gather(faces, prefix)
            guard let self, !Task.isCancelled else { return }
            self.searchResults = await self.entries(forPaths: Array(paths))
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

    func detections(for path: String) async -> [Detection] {
        await faceIndex.detections(for: path)
    }

    func identityName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return identities.first { $0.id == id }?.name
    }

    /// Name a detection — reuse an existing identity of the same name+kind (and
    /// learn this exemplar) or create a new one, then confirm the assignment.
    func nameDetection(_ det: Detection, in path: String, as rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let match = await identityIndex.all().first {
            $0.kind == det.identityKind && $0.embedderID == det.embedderID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let id: UUID
        if let match {
            await identityIndex.addExemplar(det.embedding, to: match.id, embedderID: det.embedderID)
            id = match.id
        } else {
            id = await identityIndex.create(name: name, kind: det.identityKind,
                                            embedderID: det.embedderID, exemplar: det.embedding, coverPath: path).id
        }
        await faceIndex.assign(detection: det.id, in: path, to: id)
        await identityIndex.save(); await faceIndex.save()
        await refreshFaceState()
    }

    /// Confirm/assign a detection to an existing identity, learning the exemplar.
    func assignDetection(_ det: Detection, in path: String, to identityID: UUID) async {
        await identityIndex.addExemplar(det.embedding, to: identityID, embedderID: det.embedderID)
        await faceIndex.assign(detection: det.id, in: path, to: identityID)
        await identityIndex.save(); await faceIndex.save()
        await refreshFaceState()
    }

    func confirmSuggestion(_ det: Detection, in path: String) async {
        guard let sid = det.suggestedID else { return }
        await assignDetection(det, in: path, to: sid)
    }

    func rejectSuggestion(_ det: Detection, in path: String) async {
        guard let sid = det.suggestedID else { return }
        await faceIndex.reject(detection: det.id, in: path, identity: sid)
        await faceIndex.save()
        await refreshFaceState()
    }

    func unnameDetection(_ det: Detection, in path: String) async {
        await faceIndex.assign(detection: det.id, in: path, to: nil)
        await faceIndex.save()
        await refreshFaceState()
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

    /// Full refresh: re-scan the current folder, re-check free space, and recount
    /// the whole library (the item/GB totals). Use after external changes.
    func refresh() {
        if let root = rootURL { refreshVolumeStats(root); startCount(root) }
        loadEntries()
    }

    /// Cheap re-scan of just the current folder — used to auto-pick-up external
    /// changes (e.g. files deleted in Finder) when the window regains focus,
    /// without paying for a full library recount.
    func reloadCurrentFolder() {
        guard currentDir != nil else { return }
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
