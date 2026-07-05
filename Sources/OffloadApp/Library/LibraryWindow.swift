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

private struct LibraryGrid: View {
    let model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            if model.entries.isEmpty {
                ContentUnavailableView("Nothing here",
                                       systemImage: "photo.on.rectangle",
                                       description: Text(model.loading ? "Loading…" : "This folder has no photos or subfolders."))
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.entries) { entry in
                        LibraryTile(entry: entry)
                            .onTapGesture(count: 2) { open(entry) }
                    }
                }
                .padding(DS.Space.l)
            }
        }
    }

    private func open(_ entry: LibraryEntry) {
        if entry.isFolder {
            model.enter(entry)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }
}

private struct LibraryTile: View {
    let entry: LibraryEntry
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.m).fill(DS.Palette.surfaceRaised)
                if entry.isFolder {
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
            // Fix the reported size to the box BEFORE clipping, so an aspect-fill
            // thumbnail can't overflow and shove the next row.
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
            .overlay(alignment: .topTrailing) {
                if case .media(.raw) = entry.kind { badge("RAW") }
                else if case .media(.video) = entry.kind { badge("▶") }
            }
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(DS.Palette.hairline, lineWidth: 1))

            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
        .task(id: entry.id) {
            guard !entry.isFolder else { return }
            thumb = await ThumbnailLoader.shared.thumbnail(url: entry.url, size: entry.size,
                                                           mtime: entry.modified, side: 160)
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
