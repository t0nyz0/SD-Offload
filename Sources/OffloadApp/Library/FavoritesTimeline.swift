import SwiftUI
import AppKit
import OffloadCore

/// A chronological timeline of favorited photos — month sections (oldest → newest)
/// with sticky headers and a year strip to jump around, evoking Apple Photos' Months
/// view. Tap a photo to open it in the viewer.
struct FavoritesTimeline: View {
    let model: LibraryModel
    let openViewer: (DisplayItem) -> Void
    @AppStorage("offload.library.tileSize") private var tileSize = 150.0

    private struct MonthSection: Identifiable {
        let id: Int            // year*100 + month
        let title: String      // "June 2026"
        let year: Int
        var items: [DisplayItem]
    }

    private var sections: [MonthSection] {
        let cal = Calendar.current
        var out: [MonthSection] = []
        for item in model.favoriteItems {
            let d = model.timelineDate(item)
            let c = cal.dateComponents([.year, .month], from: d)
            let year = c.year ?? 0, month = c.month ?? 0
            let key = year * 100 + month
            if out.last?.id == key {
                out[out.count - 1].items.append(item)
            } else {
                out.append(MonthSection(id: key, title: Self.title(d), year: year, items: [item]))
            }
        }
        return out
    }

    private var years: [Int] {
        var seen = Set<Int>(); var out: [Int] = []
        for s in sections where !seen.contains(s.year) { seen.insert(s.year); out.append(s.year) }
        return out
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileSize, maximum: tileSize + 60), spacing: 12)]
    }

    var body: some View {
        if model.favoriteItems.isEmpty {
            ContentUnavailableView("No favorites yet", systemImage: "heart",
                                   description: Text("Open a photo and tap the heart (or press F) to add it here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if years.count > 1 {
                        yearStrip(proxy)
                        Divider()
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.l, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    LazyVGrid(columns: columns, spacing: 12) {
                                        ForEach(section.items) { item in
                                            LibraryTile(item: item, tags: model.tags(for: item.primary),
                                                        isFavorite: true)
                                                .onTapGesture { openViewer(item) }
                                                .contextMenu {
                                                    Button("Open") { openViewer(item) }
                                                    Button("Remove from Favorites") { model.toggleFavorite(item) }
                                                    Button("Reveal in Finder") {
                                                        NSWorkspace.shared.activateFileViewerSelecting([item.primary.url])
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.horizontal, DS.Space.l)
                                } header: {
                                    Text(section.title)
                                        .font(.system(size: 15, weight: .bold))
                                        .padding(.horizontal, DS.Space.l)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.ultraThinMaterial)
                                        .id(section.id)
                                }
                            }
                        }
                        .padding(.vertical, DS.Space.m)
                    }
                }
            }
        }
    }

    private func yearStrip(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(years, id: \.self) { year in
                    Button("\(year)") {
                        if let first = sections.first(where: { $0.year == year }) {
                            withAnimation { proxy.scrollTo(first.id, anchor: .top) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, 7)
        }
    }

    private static func title(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("yyyyLLLL")   // e.g. "June 2026"
        return f.string(from: date)
    }
}
