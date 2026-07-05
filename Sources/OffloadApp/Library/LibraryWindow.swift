import SwiftUI
import OffloadCore

/// Browse the NAS (and an inserted card) at a glance: storage gauge, live photo
/// count, and a date-folder thumbnail grid.
struct LibraryWindow: View {
    @Environment(AppState.self) private var app
    @State private var model: LibraryModel?
    @State private var viewerIndex: Int?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .onAppear {
            if model == nil {
                let m = LibraryModel(nasRootPath: app.settings.config.nasRootPath,
                                     cardRootPath: app.cardMountPath)
                m.select(.nas)
                model = m
            } else {
                model?.update(nasRootPath: app.settings.config.nasRootPath, cardRootPath: app.cardMountPath)
            }
        }
        .onChange(of: app.cardMountPath) { _, newValue in
            model?.update(nasRootPath: app.settings.config.nasRootPath, cardRootPath: newValue)
        }
    }

    private func content(_ model: LibraryModel) -> some View {
        @Bindable var model = model
        return NavigationSplitView {
            List(selection: Binding(
                get: { model.source },
                set: { model.select($0) }
            )) {
                Section("Sources") {
                    Label("Photos on NAS", systemImage: "externaldrive.fill")
                        .tag(LibraryModel.Source.nas)
                    if model.hasCard {
                        Label("SD Card", systemImage: "sdcard.fill")
                            .tag(LibraryModel.Source.card)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                LibraryHeader(model: model)
                SearchBar(model: model)
                if !model.isSearching && !model.suggestions.isEmpty {
                    SuggestionChips(model: model)
                }
                Divider()
                LibraryGrid(model: model, openViewer: { openInViewer($0, model) })
            }
            .background(DS.Palette.ink)
        }
        .overlay {
            ImageViewer(items: model.displayedItems.filter { !$0.isFolder },
                        index: $viewerIndex, model: model)
        }
        .alert("Delete failed", isPresented: Binding(
            get: { model.deleteError != nil },
            set: { if !$0 { model.deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { model.deleteError = nil }
        } message: {
            Text(model.deleteError ?? "")
        }
    }

    private func openInViewer(_ item: DisplayItem, _ model: LibraryModel) {
        let photos = model.displayedItems.filter { !$0.isFolder }
        viewerIndex = photos.firstIndex { $0.id == item.id }
    }
}

private struct LibraryHeader: View {
    let model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: model.source == .nas ? "externaldrive.fill.badge.checkmark" : "sdcard.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(model.mounted ? DS.safe : DS.Palette.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sourceTitle)
                        .font(.system(size: 17, weight: .bold))
                    countLine
                    if let geo = model.geoSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill").font(.system(size: 9))
                            Text(geo).font(.system(size: 10.5)).monospacedDigit()
                        }
                        .foregroundStyle(.tertiary)
                    }
                    if let faces = model.facesSummary {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.fill").font(.system(size: 9))
                            Text(faces).font(.system(size: 10.5)).monospacedDigit()
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if model.totalVolumeBytes > 0 {
                    storageGauge
                }
            }
            Breadcrumb(model: model)
            if let label = model.currentDateLabel {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.safe)
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
        .padding(DS.Space.l)
    }

    private var countLine: some View {
        HStack(spacing: 6) {
            if let media = model.totalMedia {
                Text("\(media.formatted()) items")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                if model.totalBytes > 0 {
                    Text("· \(Fmt.bytes(model.totalBytes))")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if !model.countComplete {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
            } else {
                Text("Counting…").font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
    }

    private var storageGauge: some View {
        let used = max(0, model.totalVolumeBytes - model.freeBytes)
        let frac = model.totalVolumeBytes > 0 ? Double(used) / Double(model.totalVolumeBytes) : 0
        return VStack(alignment: .trailing, spacing: 4) {
            Text("\(Fmt.bytes(model.freeBytes)) free")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 160, height: 6)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(frac > 0.9 ? AnyShapeStyle(DS.motion) : AnyShapeStyle(DS.safeBar))
                        .frame(width: 160 * frac, height: 6)
                }
            Text("\(Fmt.bytes(model.totalVolumeBytes)) total")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

private struct Breadcrumb: View {
    let model: LibraryModel
    var body: some View {
        HStack(spacing: 7) {
            ForEach(model.breadcrumb, id: \.index) { crumb in
                let isLast = crumb.index == model.breadcrumb.count - 1
                if crumb.index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button(crumb.label) { model.navigate(toBreadcrumb: crumb.index) }
                    .buttonStyle(.plain)
                    .font(.system(size: 19, weight: isLast ? .bold : .semibold))
                    .foregroundStyle(isLast ? .primary : .secondary)
            }
        }
    }
}

private struct SearchBar: View {
    @Bindable var model: LibraryModel
    @AppStorage("offload.library.tileSize") private var tileSize = 150.0
    @AppStorage("offload.faces.consented") private var facesConsented = false
    @State private var showFacesConsent = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search photos by content — try “dog”, “beach”, “food”…", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(DS.Palette.surfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.s))

            // Tile size
            HStack(spacing: 5) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.tertiary)
                Slider(value: $tileSize, in: 110...320)
                    .frame(width: 90)
                    .controlSize(.small)
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .help("Thumbnail size")

            if model.analyzing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Analyzing \(model.analyzeDone)/\(model.analyzeTotal)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Button("Stop") { model.cancelAnalysis() }.controlSize(.small)
                }
            } else {
                Button {
                    model.analyzeCurrentSource()
                } label: {
                    Label("Analyze", systemImage: "sparkles")
                }
                .help("Scan this library on-device to tag what's in each photo, so you can search by content.")
            }

            if model.findingFaces {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Finding faces \(model.facesDone)/\(model.facesTotal)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Button("Stop") { model.cancelFindFaces() }.controlSize(.small)
                }
            } else {
                Menu {
                    Button { startFindFaces() } label: { Label("Find faces & pets", systemImage: "person.crop.rectangle") }
                    if !model.identities.isEmpty || model.faceUnnamed > 0 {
                        Divider()
                        Button(role: .destructive) { model.deleteAllFaceData() } label: {
                            Label("Delete all face data", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Faces", systemImage: "person.crop.square")
                } primaryAction: {
                    startFindFaces()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Detect faces & pets on-device so you can name and search them — stored locally only.")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .sheet(isPresented: $showFacesConsent) {
            FacesConsentSheet(
                onEnable: { facesConsented = true; showFacesConsent = false; model.findFaces() },
                onCancel: { showFacesConsent = false })
        }
    }

    private func startFindFaces() {
        if facesConsented { model.findFaces() } else { showFacesConsent = true }
    }
}

/// One-time disclosure before any face data is created — what's detected, what's
/// stored, and that it's local-only and removable. (Biometric-data consent.)
private struct FacesConsentSheet: View {
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Label("Find faces & pets", systemImage: "person.crop.rectangle")
                .font(.system(size: 15, weight: .semibold))
            Text("Scans your photos on-device (Apple Vision — no cloud) to detect faces and pets, so you can name them (\"Elizabeth\", \"Hurley\") and search by who's in a shot.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("What's stored: a mathematical face/pet template plus any names you assign — as files on **this Mac only** (owner-only, excluded from backups and cloud sync). Nothing is uploaded. Remove it any time with \"Delete all face data.\"")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Grouping is a starting point you confirm — it can mistake similar-looking people, and never auto-labels.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not now", action: onCancel)
                Button("Enable & scan", action: onEnable).buttonStyle(.borderedProminent)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 380)
    }
}

private struct SuggestionChips: View {
    @Bindable var model: LibraryModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("IN YOUR LIBRARY").dsLabel().padding(.trailing, 2)
                ForEach(model.suggestions.prefix(20), id: \.tag) { s in
                    Button {
                        model.searchText = s.tag
                    } label: {
                        HStack(spacing: 4) {
                            Text(s.tag.capitalized).font(.system(size: 11, weight: .medium))
                            Text("\(s.count)").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(DS.Palette.surfaceRaised.opacity(0.6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.s)
        }
    }
}

private struct LibraryGrid: View {
    let model: LibraryModel
    let openViewer: (DisplayItem) -> Void
    @State private var pendingDelete: DisplayItem?
    @State private var pendingScope: DeleteScope = .all
    @State private var bulkConfirm = false
    @AppStorage("offload.library.tileSize") private var tileSize = 150.0
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize + 60), spacing: 12)]
    }
    // Folders get their own, larger tiles so a date hierarchy is easy to scan.
    private var folderColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)]
    }

    private var canDelete: Bool { model.source == .nas }

    var body: some View {
        VStack(spacing: 0) {
            if !model.selection.isEmpty { selectionBar }
            grid
        }
        .background(
            // Off-screen shortcut hosts: ⌘A select all, ⌦/⌫ delete selection.
            Group {
                Button("") { model.selectAllPhotos() }
                    .keyboardShortcut("a", modifiers: .command)
                Button("") { if canDelete && !model.selection.isEmpty { bulkConfirm = true } }
                    .keyboardShortcut(.delete, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false)
        )
        .confirmationDialog("Delete this photo?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { item in
            Button(pendingScope == .all ? "Delete" : (pendingScope == .rawOnly ? "Delete RAW" : "Delete JPEG"),
                   role: .destructive) {
                let target = item; let scope = pendingScope
                pendingDelete = nil
                Task { await model.delete(target, scope: scope) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text(deleteMessage(item, scope: pendingScope))
        }
        .confirmationDialog("Delete \(model.selectedCount) photos?",
                            isPresented: $bulkConfirm) {
            Button("Delete \(model.selectedCount) Photos", role: .destructive) {
                Task { await model.deleteSelection() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes \(model.selectedCount) photos (with their RAW/sidecar files) from your NAS. This can't be undone.")
        }
    }

    private var selectionBar: some View {
        HStack(spacing: DS.Space.m) {
            Text("\(model.selectedCount) selected")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Spacer()
            Button("Select All") { model.selectAllPhotos() }
                .controlSize(.small)
            Button("Clear") { model.clearSelection() }
                .controlSize(.small)
            if canDelete {
                Button(role: .destructive) { bulkConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(.quaternary.opacity(0.3))
    }

    private var grid: some View {
        ScrollView {
            let items = model.displayedItems
            let folders = items.filter { $0.isFolder }
            let photos = items.filter { !$0.isFolder }
            if items.isEmpty {
                ContentUnavailableView(emptyTitle,
                                       systemImage: model.isSearching ? "magnifyingglass" : "photo.on.rectangle",
                                       description: Text(emptyDetail))
                    .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    if !folders.isEmpty {
                        LazyVGrid(columns: folderColumns, spacing: 14) {
                            ForEach(folders) { item in
                                FolderTile(item: item, rootPath: model.rootURL?.path)
                                    .onTapGesture(count: 2) { model.enter(item.primary) }
                                    .onTapGesture { model.clearSelection() }
                                    .contextMenu { menu(for: item) }
                            }
                        }
                    }
                    if !photos.isEmpty {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(photos) { item in
                                LibraryTile(item: item, tags: model.tags(for: item.primary),
                                            selected: model.selection.contains(item.id))
                                    .onTapGesture(count: 2) { open(item) }
                                    .onTapGesture {
                                        let flags = NSEvent.modifierFlags
                                        model.handleTap(item,
                                                        command: flags.contains(.command),
                                                        shift: flags.contains(.shift))
                                    }
                                    .contextMenu { menu(for: item) }
                            }
                        }
                    }
                }
                .padding(DS.Space.l)
            }
        }
        .onExitCommand { model.clearSelection() }
    }

    private func deleteMessage(_ item: DisplayItem, scope: DeleteScope = .all) -> String {
        switch scope {
        case .rawOnly:
            let n = (item.rawCompanion?.name).map { "the RAW (\($0))" } ?? "the RAW"
            return "Permanently deletes \(n) from your NAS. The JPEG stays. This can't be undone."
        case .jpegOnly:
            let n = (item.photo?.name).map { "the JPEG (\($0))" } ?? "the JPEG"
            return "Permanently deletes \(n) from your NAS. The RAW stays. This can't be undone."
        case .all:
            let names = item.all.map { ($0.id as NSString).lastPathComponent }
            let listed = names.count <= 3 ? names.joined(separator: ", ")
                : names.prefix(2).joined(separator: ", ") + ", and \(names.count - 2) more"
            return "Permanently deletes \(listed) (plus any matching RAW/sidecar files) from your NAS. This can't be undone."
        }
    }

    @ViewBuilder
    private func menu(for item: DisplayItem) -> some View {
        if item.isFolder {
            Button("Open") { model.enter(item.primary) }
            Button("Reveal in Finder") { reveal(item.primary.url) }
        } else {
            Button("Open") { openViewer(item) }
            Button("Open in Preview") { NSWorkspace.shared.open(item.primary.url) }
            if let rawURL = item.rawCompanion?.url {
                Button("Open RAW") { NSWorkspace.shared.open(rawURL) }
            }
            Button("Reveal in Finder") { reveal(item.primary.url) }
            // Delete manages the NAS archive only — never the card (its originals
            // are protected until the verified offload wipes them).
            if model.source == .nas {
                Divider()
                if model.selection.contains(item.id) && model.selectedCount > 1 {
                    Button("Delete \(model.selectedCount) Photos…", role: .destructive) { bulkConfirm = true }
                } else if item.isRawJpegPair {
                    Menu("Delete") {
                        Button("JPEG + RAW…", role: .destructive) { pendingScope = .all; pendingDelete = item }
                        Button("RAW only…", role: .destructive) { pendingScope = .rawOnly; pendingDelete = item }
                        Button("JPEG only…", role: .destructive) { pendingScope = .jpegOnly; pendingDelete = item }
                    }
                } else {
                    Button("Delete…", role: .destructive) { pendingScope = .all; pendingDelete = item }
                }
            }
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var emptyTitle: String { model.isSearching ? "No matches" : "Nothing here" }
    private var emptyDetail: String {
        if model.isSearching { return "No analyzed photos match “\(model.searchText)”. Try Analyze first, or a different word." }
        return model.loading ? "Loading…" : "This folder has no photos or subfolders."
    }

    private func open(_ item: DisplayItem) {
        if item.isFolder { model.enter(item.primary) }
        else { openViewer(item) }
    }
}

private struct LibraryTile: View {
    let item: DisplayItem
    var tags: [String] = []
    var selected: Bool = false
    @State private var thumb: NSImage?
    @State private var exif: ExifInfo?

    private var entry: LibraryEntry { item.primary }
    private var isVideo: Bool { if case .media(.video) = entry.kind { return true }; return false }
    private var isRawOnly: Bool { if case .media(.raw) = entry.kind { return true }; return false }

    var body: some View {
        VStack(spacing: 6) {
            // A definite SQUARE tile: aspectRatio(1) sizes the box from the cell
            // width, the image is overlaid INTO that fixed box and scaled to fill,
            // then everything is clipped to the box. (A .frame(maxWidth:.infinity)
            // would propose infinite width to a fill-scaled image and it overflows
            // into the neighbouring cells — the bug this replaces.)
            RoundedRectangle(cornerRadius: DS.Radius.m)
                .fill(DS.Palette.surfaceRaised)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if item.isFolder {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(DS.safe.opacity(0.85))
                    } else if let thumb {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: placeholderSymbol)
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
                .overlay(alignment: .topTrailing) { formatBadge }
                .overlay(alignment: .bottomLeading) { tagBadge }
                .overlay(alignment: .topLeading) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m)
                    .strokeBorder(selected ? Color.accentColor : DS.Palette.hairline,
                                  lineWidth: selected ? 3 : 1))

            VStack(spacing: 1) {
                Text(titleText)
                    .font(.system(size: 11))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                if let info = infoLine {
                    Text(info)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)                       // wrap so aperture/shutter never get cut off
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .monospacedDigit()
                }
            }
        }
        .task(id: entry.id) {
            guard !item.isFolder else { return }
            thumb = await ThumbnailLoader.shared.thumbnail(url: entry.url, size: entry.size,
                                                           mtime: entry.modified, side: 220)
        }
        .task(id: entry.id) {
            guard !item.isFolder, !isVideo else { return }
            exif = await ExifCache.shared.info(url: entry.url, mtime: entry.modified)
        }
    }

    /// The tiny line under the name: format + basic EXIF ("JPG+RAW · ISO 400 · ƒ2.8").
    private var infoLine: String? {
        guard !item.isFolder else { return nil }
        let format: String = isVideo ? "VIDEO" : (item.raw != nil ? "JPG+RAW" : (isRawOnly ? "RAW" : "JPG"))
        if let exif, exif.hasAny { return "\(format) · \(exif.caption)" }
        return format
    }

    // When a RAW is attached, title the card by its base name (no extension) so
    // it reads as one photo, and flag both formats.
    private var titleText: String {
        item.raw != nil ? (entry.name as NSString).deletingPathExtension : entry.name
    }

    // Format now lives in the info line under the tile; only flag video on the
    // image itself (a play marker reads faster than text there).
    @ViewBuilder private var formatBadge: some View {
        if isVideo { badge("▶") }
    }

    @ViewBuilder private var tagBadge: some View {
        if let top = tags.first {
            Text(top.lowercased())
                .font(.system(size: 8, weight: .medium))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(.black.opacity(0.4), in: Capsule())
                .foregroundStyle(.white.opacity(0.8))
                .padding(4)
        }
    }

    private var placeholderSymbol: String {
        switch entry.kind {
        case .media(.video): "film"
        case .media(.raw): "camera.aperture"
        default: "photo"
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .foregroundStyle(.white)
            .padding(5)
    }
}

/// A large folder card: a 2×2 collage of photos sampled from inside, with a
/// humanized date caption ("Jul 4" · "Saturday") over a bottom scrim.
private struct FolderTile: View {
    let item: DisplayItem
    let rootPath: String?
    @State private var thumbs: [NSImage] = []
    @State private var loaded = false

    private var entry: LibraryEntry { item.primary }
    private var caption: DateFolders.Caption {
        DateFolders.caption(folderPath: entry.id, rootPath: rootPath ?? "", rawName: entry.name)
    }

    // The folder body silhouette: a square top-left corner so the tab flows into
    // it, the other three corners rounded — so the tile reads unmistakably as a
    // folder holding the photos, not as a group of photos.
    private var bodyShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: DS.Radius.m,
                               bottomTrailingRadius: DS.Radius.m, topTrailingRadius: DS.Radius.m)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Folder tab — the silhouette cue. Same fill as the body, flush on top.
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 6)
                .fill(DS.Palette.surfaceRaised)
                .frame(width: 78, height: 15)
                .padding(.leading, 12)

            VStack(spacing: 0) {
                // Contents preview, inset so the folder chrome frames it — the
                // photos clearly sit *inside* the folder.
                Color.clear
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay { collage }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s))
                    .padding(5)
                labelBar
            }
            .background(DS.Palette.surfaceRaised, in: bodyShape)
            .overlay(bodyShape.strokeBorder(DS.Palette.hairline, lineWidth: 1))
            .clipShape(bodyShape)
        }
        .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
        .contentShape(Rectangle())
        .task(id: entry.id) {
            thumbs = await FolderPreviewLoader.shared.preview(folder: entry.url, mtime: entry.modified)
            loaded = true
        }
    }

    @ViewBuilder private var collage: some View {
        if thumbs.isEmpty {
            ZStack {
                DS.Palette.ink
                if loaded {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(DS.safe.opacity(0.7))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            CollageGrid(images: thumbs)
        }
    }

    // A solid label bar (folder chrome), not a gradient over the photos — the date
    // reads as the folder's name, and the chevron signals "open".
    private var labelBar: some View {
        let c = caption
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(DS.safe)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let sub = c.subtitle {
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

/// Lays 1–4 thumbnails into a folder card: full-bleed for one, split for two,
/// big-plus-stack for three, a 2×2 grid for four. Each cell fills and clips.
private struct CollageGrid: View {
    let images: [NSImage]
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let halfW = (w - gap) / 2, halfH = (h - gap) / 2
            switch min(images.count, 4) {
            case 1:
                cell(images[0], w, h)
            case 2:
                HStack(spacing: gap) { cell(images[0], halfW, h); cell(images[1], halfW, h) }
            case 3:
                HStack(spacing: gap) {
                    cell(images[0], halfW, h)
                    VStack(spacing: gap) { cell(images[1], halfW, halfH); cell(images[2], halfW, halfH) }
                }
            default:
                VStack(spacing: gap) {
                    HStack(spacing: gap) { cell(images[0], halfW, halfH); cell(images[1], halfW, halfH) }
                    HStack(spacing: gap) { cell(images[2], halfW, halfH); cell(images[3], halfW, halfH) }
                }
            }
        }
    }

    private func cell(_ img: NSImage, _ w: CGFloat, _ h: CGFloat) -> some View {
        Image(nsImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: max(0, w), height: max(0, h))
            .clipped()
    }
}
