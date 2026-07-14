import SwiftUI
import Observation
import OffloadCore
import OffloadEngine

/// Which parts of a RAW+JPEG item a delete should remove.
enum DeleteScope: Sendable { case all, rawOnly, jpegOnly }

/// Grid sort order (culling).
enum SortOrder: String, CaseIterable, Sendable {
    case nameAsc, nameDesc, dateNewest, dateOldest, sizeDesc, ratingDesc
    var label: String {
        switch self {
        case .nameAsc: "Name (A–Z)"; case .nameDesc: "Name (Z–A)"
        case .dateNewest: "Newest first"; case .dateOldest: "Oldest first"
        case .sizeDesc: "Largest first"; case .ratingDesc: "Highest rated"
        }
    }
}

/// Grid flag filter (culling).
enum FlagFilter: String, CaseIterable, Sendable {
    case all, picks, unrejected
    var label: String {
        switch self { case .all: "All"; case .picks: "Picks only"; case .unrejected: "Hide rejected" }
    }
}

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

    // Culling: per-photo star ratings + pick/reject flags (persisted), plus the
    // current sort + filter for the grid.
    private(set) var ratings: [String: Int] = [:]      // path → 1…5
    private(set) var flags: [String: PhotoFlag] = [:]  // path → pick/reject
    var sortOrder: SortOrder = .nameAsc { didSet { if sortOrder != oldValue { rebuildDisplayed() } } }
    var minRating: Int = 0 { didSet { if minRating != oldValue { rebuildDisplayed() } } }
    var flagFilter: FlagFilter = .all { didSet { if flagFilter != oldValue { rebuildDisplayed() } } }
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
    private(set) var analyzeError: String?
    /// Paths with a deep (AI) analysis — drives the tile "analyzed" badge.
    private(set) var aiDonePaths: Set<String> = []
    private(set) var suggestions: [(tag: String, count: Int)] = []
    private(set) var tagsByPath: [String: [String]] = [:]   // for tile overlays

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
        self.hasCard = cardRootPath != nil
        favoritePaths = Set(JSONIO.loadGuarded([String].self, from: Paths.favoritesFile) ?? [])
        pinnedFolders = JSONIO.loadGuarded([String].self, from: Paths.pinnedFoldersFile) ?? []
        let cull = JSONIO.loadGuarded(CullData.self, from: Paths.cullFile)
        ratings = cull?.ratings ?? [:]
        flags = cull?.flags ?? [:]
    }

    /// Whether a card is mounted. Stored (not computed off the @ObservationIgnored
    /// cardRootPath) so the sidebar's "SD Card" row reactively appears AND disappears
    /// — a computed getter over ignored state never re-evaluates when the card leaves.
    private(set) var hasCard: Bool
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
        self.hasCard = cardRootPath != nil
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

    // MARK: - Culling (ratings + flags)

    func rating(for item: DisplayItem) -> Int { ratings[item.primary.id] ?? 0 }
    func flag(for item: DisplayItem) -> PhotoFlag? { flags[item.primary.id] }

    /// Set a star rating (0 clears). If the active filter would now hide it, the grid
    /// re-filters. Applies to the current selection if the item is part of it.
    func setRating(_ stars: Int, for item: DisplayItem) {
        let targets = selection.contains(item.id) && selection.count > 1
            ? photoItems.filter { selection.contains($0.id) } : [item]
        let clamped = max(0, min(5, stars))
        for t in targets {
            if clamped == 0 { ratings.removeValue(forKey: t.primary.id) } else { ratings[t.primary.id] = clamped }
        }
        saveCull()
        if minRating > 0 { rebuildDisplayed() }
    }

    /// Toggle a pick/reject flag (tapping the same flag clears it).
    func toggleFlag(_ flag: PhotoFlag, for item: DisplayItem) {
        let targets = selection.contains(item.id) && selection.count > 1
            ? photoItems.filter { selection.contains($0.id) } : [item]
        // If any target lacks this flag, set it on all; else clear it on all.
        let shouldSet = targets.contains { flags[$0.primary.id] != flag }
        for t in targets {
            if shouldSet { flags[t.primary.id] = flag } else { flags.removeValue(forKey: t.primary.id) }
        }
        saveCull()
        if flagFilter != .all { rebuildDisplayed() }
    }

    /// Rejected photos in the current folder (ignores the active filter, so you can
    /// still purge them even while "Hide rejected" is on).
    var rejectedInFolder: [DisplayItem] {
        Self.groupPhotos(displayedEntries.filter { !$0.isFolder }).filter { flags[$0.primary.id] == .reject }
    }

    func deleteRejected() async {
        let rejected = rejectedInFolder
        for item in rejected {
            await delete(item, scope: .all)
            flags.removeValue(forKey: item.primary.id)
            ratings.removeValue(forKey: item.primary.id)
        }
        saveCull()
    }

    /// Apply a rating to the whole current selection (for the selection bar / grid).
    func rateSelection(_ stars: Int) {
        let targets = photoItems.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        let clamped = max(0, min(5, stars))
        for t in targets {
            if clamped == 0 { ratings.removeValue(forKey: t.primary.id) } else { ratings[t.primary.id] = clamped }
        }
        saveCull()
        if minRating > 0 { rebuildDisplayed() }
    }

    func flagSelection(_ flag: PhotoFlag) {
        let targets = photoItems.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        let shouldSet = targets.contains { flags[$0.primary.id] != flag }
        for t in targets { if shouldSet { flags[t.primary.id] = flag } else { flags.removeValue(forKey: t.primary.id) } }
        saveCull()
        if flagFilter != .all { rebuildDisplayed() }
    }

    private func saveCull() {
        let data = CullData(ratings: ratings, flags: flags)
        Task.detached(priority: .utility) { try? JSONIO.save(data, to: Paths.cullFile) }
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
            // One pass over byPath, not one per identity.
            self.identityCounts = await self.faceIndex.identityCounts()
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
        let photos = applySort(applyCullFilter(Self.groupPhotos(media)))
        folderItems = folders
        photoItems = photos
        displayedItems = folders + photos
    }

    private func applyCullFilter(_ items: [DisplayItem]) -> [DisplayItem] {
        guard minRating > 0 || flagFilter != .all else { return items }
        return items.filter { item in
            let p = item.primary.id
            if minRating > 0, (ratings[p] ?? 0) < minRating { return false }
            switch flagFilter {
            case .all: return true
            case .picks: return flags[p] == .pick
            case .unrejected: return flags[p] != .reject
            }
        }
    }

    private func applySort(_ items: [DisplayItem]) -> [DisplayItem] {
        switch sortOrder {
        case .nameAsc:  return items.sorted { $0.primary.name.localizedStandardCompare($1.primary.name) == .orderedAscending }
        case .nameDesc: return items.sorted { $0.primary.name.localizedStandardCompare($1.primary.name) == .orderedDescending }
        case .dateNewest: return items.sorted { $0.primary.modified > $1.primary.modified }
        case .dateOldest: return items.sorted { $0.primary.modified < $1.primary.modified }
        case .sizeDesc:   return items.sorted { $0.primary.size > $1.primary.size }
        case .ratingDesc: return items.sorted { (ratings[$0.primary.id] ?? 0) > (ratings[$1.primary.id] ?? 0) }
        }
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

    // MARK: - AI identification (on-demand, via the claude CLI)

    /// A previously-run identification for this photo, if any (so reopening shows it
    /// without spending another call).
    func existingIdentification(for item: DisplayItem) async -> PhotoIdentifier.Identification? {
        guard let r = await photoIndex.record(item.primary.id), let d = r.aiDescription else { return nil }
        return PhotoIdentifier.Identification(description: d, tags: r.aiTags ?? [])
    }

    /// Identify a photo with Claude vision, persist the result, and fold its tags into
    /// the searchable index + tile overlays. Throws on CLI/parse failure.
    func identify(_ item: DisplayItem) async throws -> PhotoIdentifier.Identification {
        let result = try await makeIdentifier().identify(imageURL: item.primary.url)
        await photoIndex.setAI(path: item.primary.id, size: item.primary.size,
                               mtime: item.primary.modified, tags: result.tags, description: result.description)
        await photoIndex.save()
        if !result.tags.isEmpty { tagsByPath[item.primary.id] = Array(result.tags.prefix(3)) }
        aiDonePaths.insert(item.primary.id)
        refreshSuggestions()
        return result
    }

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
    /// The currently-selected photos (for "scan selected" in Analyze).
    var selectedItems: [DisplayItem] { photoItems.filter { selection.contains($0.id) } }

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
        let namedMatches = Set(identities
            .filter { idn in terms.contains { idn.name.lowercased().contains($0) } }
            .map(\.id))
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))   // debounce typing
            guard !Task.isCancelled else { return }
            var paths = await index.search(query, underPrefix: prefix)
            if !namedMatches.isEmpty {
                paths.formUnion(await faces.photos(withIdentities: namedMatches, underPrefix: prefix))
            }
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
        let ids = Set(identities.filter { $0.kind == kind }.map(\.id))
        applyFaceFilter(label: kind == .pet ? "All pets" : "All people") { faces, prefix in
            await faces.photos(withIdentities: ids, underPrefix: prefix)
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
            guard let self else { return }
            self.suggestions = tags
        }
    }

    // MARK: - AI analysis

    /// Deep-analyze every photo in the CURRENT folder (recursively, so a month/year
    /// view covers what's inside) — not the whole library.
    func aiAnalyzeAll() {
        guard let dir = currentDir else { return }
        let browser = self.browser
        Task { [weak self] in
            let media = await Task.detached(priority: .utility) { browser.allMedia(root: dir) }.value
            let primaries = Self.primaryEntries(media)
            await MainActor.run { self?.startAIAnalysis(primaries) }
        }
    }

    /// AI-analyze a specific set of photos (the "scan selected" choice).
    func aiAnalyze(_ items: [DisplayItem]) {
        startAIAnalysis(items.filter { !$0.isFolder }.map(\.primary))
    }

    /// Core deep-analysis: identify each photo with Claude (per the AI provider
    /// setting). Bounded concurrency (AI calls are heavy), cancellable, skips photos
    /// already deep-analyzed, persists incrementally so a Stop keeps what's done, and
    /// folds tags into search + overlays. A fatal setup error (no CLI / no API key /
    /// bad key) stops the run and surfaces the message.
    private func startAIAnalysis(_ entries: [LibraryEntry]) {
        guard !analyzing, !entries.isEmpty else { return }
        analyzing = true; analyzeDone = 0; analyzeTotal = 0; analyzeError = nil
        analyzeEpoch += 1
        let epoch = analyzeEpoch
        let index = photoIndex
        let id = makeIdentifier()
        analyzeTask = Task { [weak self] in
            var todo: [LibraryEntry] = []
            for e in entries {
                if let r = await index.record(e.id), r.aiDescription != nil { continue }   // already deep-analyzed
                todo.append(e)
            }
            await MainActor.run { self?.analyzeTotal = todo.count }
            let width = 2
            var i = 0
            var fatal: String?
            while i < todo.count, fatal == nil {
                if Task.isCancelled { break }
                let batch = Array(todo[i..<min(i + width, todo.count)])
                await withTaskGroup(of: (LibraryEntry, Result<PhotoIdentifier.Identification, Error>).self) { group in
                    for e in batch {
                        group.addTask {
                            do { return (e, .success(try await id.identify(imageURL: e.url))) }
                            catch { return (e, .failure(error)) }
                        }
                    }
                    for await (e, outcome) in group {
                        switch outcome {
                        case .success(let r):
                            await index.setAI(path: e.id, size: e.size, mtime: e.modified, tags: r.tags, description: r.description)
                            await MainActor.run { [weak self] in
                                if !r.tags.isEmpty { self?.tagsByPath[e.id] = Array(r.tags.prefix(3)) }
                                self?.aiDonePaths.insert(e.id)
                            }
                        case .failure(let err):
                            if Self.isFatalAIError(err) { fatal = (err as? LocalizedError)?.errorDescription ?? "\(err)" }
                        }
                        await MainActor.run { [weak self] in self?.analyzeDone += 1 }
                    }
                }
                i += width
                if i % 10 == 0 { await index.save() }   // persist every ~10 photos, not every batch (whole-file rewrite)
            }
            await index.save()
            guard let self else { return }
            await MainActor.run {
                guard self.analyzeEpoch == epoch else { return }
                self.analyzing = false
                self.analyzeError = fatal
                self.refreshSuggestions()
                if self.isSearching { self.runSearch() }
            }
        }
    }

    /// Build an identifier from the current AI settings (provider, model, and — in API
    /// mode — the key from the Keychain).
    private func makeIdentifier() -> PhotoIdentifier {
        let cfg = AppConfig.load()
        let key = cfg.aiProvider == .api ? Keychain.get(service: Keychain.aiAPIKeyService) : nil
        return PhotoIdentifier(provider: cfg.aiProvider, apiKey: key, model: cfg.aiModel)
    }

    private static func isFatalAIError(_ err: Error) -> Bool {
        guard let e = err as? PhotoIdentifier.IDError else { return false }
        switch e {
        case .cliNotFound, .noAPIKey: return true
        case .apiError(let m):
            let l = m.lowercased()
            return l.contains("authentication") || l.contains("api key") || l.contains("401") || l.contains("invalid")
        default: return false
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
        FolderStatsLoader.shared.invalidateAll()   // rebuild folder counts (catches deep-added photos)
        if let root = rootURL { refreshVolumeStats(root); startCount(root, force: true) }
        loadEntries()
    }

    /// Cheap re-scan of just the current folder — used to auto-pick-up external
    /// changes (e.g. files deleted in Finder) when the window regains focus,
    /// without paying for a full library recount.
    func reloadCurrentFolder() {
        guard currentDir != nil else { return }
        loadEntries()
    }

    @ObservationIgnored private var lastFocusReload = Date.distantPast
    /// Focus-return reload, throttled — re-listing the folder over SMB on every app
    /// activation is wasteful and makes the grid appear to rebuild constantly.
    func reloadOnFocus() {
        guard Date().timeIntervalSince(lastFocusReload) > 20 else { return }
        lastFocusReload = Date()
        reloadCurrentFolder()
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
            self.loadTagOverlays(for: result)
        }
    }

    /// Populate tile tag overlays + the "deep analyzed" badge from the index for the
    /// photos now on screen — so analysis results show up on browse, not only right
    /// after an Analyze run. Fixes results appearing to vanish on revisit.
    private func loadTagOverlays(for entries: [LibraryEntry]) {
        let paths = entries.map(\.id)
        guard !paths.isEmpty else { return }
        let index = photoIndex
        Task { [weak self] in
            let recs = await index.records(forPaths: paths)
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (p, r) in recs {
                    let tags = Array(r.tags.prefix(3))
                    if !tags.isEmpty { self.tagsByPath[p] = tags }
                    if r.aiDescription != nil { self.aiDonePaths.insert(p) }
                }
            }
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

    private func startCount(_ root: URL, force: Bool = false) {
        countTask?.cancel()
        let cached = LibraryIndex.load(rootPath: root.path)
        totalMedia = cached?.totalMedia
        totalBytes = cached?.totalBytes ?? 0
        // Skip the full-tree SMB walk when a complete total is already cached and the
        // caller didn't force it — otherwise every folder open re-counts the whole
        // library over the NAS and starves thumbnail loads. It's invalidated after an
        // offload and by Refresh, so the number stays accurate.
        if !force, let cached, cached.complete {
            countComplete = true
            return
        }
        countComplete = false
        let browser = self.browser
        let isNAS = source == .nas
        countTask = Task { [weak self] in
            // Bridge the synchronous walk (on a utility thread) to the main
            // actor through a stream — no shared mutable state to race on.
            let stream = AsyncStream<(Int, Int64)> { continuation in
                Task.detached(priority: .utility) {
                    browser.countMedia(root: root, isCancelled: { Task.isCancelled }) { count, bytes in
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
