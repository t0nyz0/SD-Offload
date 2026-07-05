import SwiftUI
import OffloadCore

/// Browse the NAS (and an inserted card) at a glance: storage gauge, live photo
/// count, and a date-folder thumbnail grid.
struct LibraryWindow: View {
    @Environment(AppState.self) private var app
    @State private var model: LibraryModel?

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
                LibraryGrid(model: model)
            }
            .background(DS.Palette.ink)
        }
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
                    Text(model.source == .nas ? "NAS · Photos" : "SD Card")
                        .font(.system(size: 17, weight: .bold))
                    countLine
                }
                Spacer()
                if model.totalVolumeBytes > 0 {
                    storageGauge
                }
            }
            Breadcrumb(model: model)
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
        HStack(spacing: 4) {
            ForEach(model.breadcrumb, id: \.index) { crumb in
                if crumb.index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Button(crumb.label) { model.navigate(toBreadcrumb: crumb.index) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: crumb.index == model.breadcrumb.count - 1 ? .semibold : .regular))
                    .foregroundStyle(crumb.index == model.breadcrumb.count - 1 ? .primary : .secondary)
            }
        }
    }
}

private struct SearchBar: View {
    @Bindable var model: LibraryModel

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
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
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
    @State private var pendingDelete: DisplayItem?
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            let items = model.displayedItems
            if items.isEmpty {
                ContentUnavailableView(emptyTitle,
                                       systemImage: model.isSearching ? "magnifyingglass" : "photo.on.rectangle",
                                       description: Text(emptyDetail))
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        LibraryTile(item: item, tags: model.tags(for: item.primary))
                            .onTapGesture(count: 2) { open(item) }
                            .contextMenu { menu(for: item) }
                    }
                }
                .padding(DS.Space.l)
            }
        }
        .confirmationDialog("Delete this photo?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) {
                let target = item
                pendingDelete = nil
                Task { await model.delete(target) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text(deleteMessage(item))
        }
    }

    private func deleteMessage(_ item: DisplayItem) -> String {
        let names = item.all.map { ($0.id as NSString).lastPathComponent }
        let listed = names.count <= 3 ? names.joined(separator: ", ")
            : names.prefix(2).joined(separator: ", ") + ", and \(names.count - 2) more"
        return "Permanently deletes \(listed) (plus any matching RAW/sidecar files) from your NAS. This can't be undone."
    }

    @ViewBuilder
    private func menu(for item: DisplayItem) -> some View {
        if item.isFolder {
            Button("Open") { model.enter(item.primary) }
            Button("Reveal in Finder") { reveal(item.primary.url) }
        } else {
            Button("Open") { NSWorkspace.shared.open(item.primary.url) }
            if let rawURL = item.raw?.url {
                Button("Open RAW") { NSWorkspace.shared.open(rawURL) }
            }
            Button("Reveal in Finder") { reveal(item.primary.url) }
            // Delete manages the NAS archive only — never the card (its originals
            // are protected until the verified offload wipes them).
            if model.source == .nas {
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = item }
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
        else { NSWorkspace.shared.open(item.primary.url) }
    }
}

private struct LibraryTile: View {
    let item: DisplayItem
    var tags: [String] = []
    @State private var thumb: NSImage?

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
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(DS.Palette.hairline, lineWidth: 1))

            Text(titleText)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .task(id: entry.id) {
            guard !item.isFolder else { return }
            thumb = await ThumbnailLoader.shared.thumbnail(url: entry.url, size: entry.size,
                                                           mtime: entry.modified, side: 220)
        }
    }

    // When a RAW is attached, title the card by its base name (no extension) so
    // it reads as one photo, and flag both formats.
    private var titleText: String {
        item.raw != nil ? (entry.name as NSString).deletingPathExtension : entry.name
    }

    @ViewBuilder private var formatBadge: some View {
        if isVideo { badge("VIDEO") }
        else if item.raw != nil { badge("JPG+RAW") }
        else if isRawOnly { badge("RAW") }
    }

    @ViewBuilder private var tagBadge: some View {
        if let top = tags.first {
            Text(top.capitalized)
                .font(.system(size: 8.5, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(DS.safe.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
                .padding(5)
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
