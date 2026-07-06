import SwiftUI
import AppKit
import OffloadCore

/// The Faces source: a gallery of every named person/pet. Tap a card to see all of
/// their photos (jumps to the NAS view with that identity filtered).
struct FacesGallery: View {
    let model: LibraryModel

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 16)] }

    var body: some View {
        if model.identities.isEmpty {
            ContentUnavailableView("No named faces yet",
                                   systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Run Find Faces & Pets from the Photos view, then name the people and pets you find. They'll show up here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.identities) { idn in
                        FaceCard(identity: idn, count: model.identityCounts[idn.id]) { model.showIdentity(idn.id) }
                    }
                }
                .padding(DS.Space.l)
            }
        }
    }
}

private struct FaceCard: View {
    let identity: Identity
    let count: Int?
    let onOpen: () -> Void
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.m).fill(DS.Palette.surfaceRaised)
                if let thumb {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Image(systemName: identity.kind == .pet ? "pawprint.fill" : "person.fill")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m).strokeBorder(DS.Palette.hairline, lineWidth: 1))

            VStack(spacing: 1) {
                Text(identity.name)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(countLabel)
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .help("Show \(identity.name)'s photos")
        .task(id: identity.coverPath ?? identity.id.uuidString) {
            guard let cover = identity.coverPath else { thumb = nil; return }
            thumb = await ThumbnailLoader.shared.thumbnail(
                url: URL(fileURLWithPath: cover), size: 0, mtime: .distantPast, side: 130)
        }
    }

    private var countLabel: String {
        let kind = identity.kind == .pet ? "pet" : "person"
        guard let c = count else { return kind }
        return "\(c) photo\(c == 1 ? "" : "s")"
    }
}
