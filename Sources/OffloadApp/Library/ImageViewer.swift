import SwiftUI

/// A fast in-app image viewer — opens instantly instead of launching Preview.
/// Always shows the JPEG (the display copy); the RAW opens externally on demand.
/// Arrow keys move between photos, Escape/Space closes, scroll/pinch zooms.
struct ImageViewer: View {
    let items: [DisplayItem]
    @Binding var index: Int?
    @State private var exif: ExifInfo?

    private var current: DisplayItem? {
        guard let i = index, items.indices.contains(i) else { return nil }
        return items[i]
    }

    var body: some View {
        if let i = index, let item = current {
            ZStack {
                Color.black.opacity(0.985).ignoresSafeArea()
                    .onTapGesture { index = nil }

                ZoomableImage(url: item.primary.url)
                    .id(item.id)
                    .padding(.top, 44)

                VStack {
                    topBar(item: item, position: i)
                    Spacer()
                }

                // Prev / next chevrons
                HStack {
                    navButton("chevron.left", enabled: i > 0) { step(-1) }
                    Spacer()
                    navButton("chevron.right", enabled: i < items.count - 1) { step(1) }
                }
                .padding(.horizontal, 12)
            }
            .background(shortcuts)
            .transition(.opacity)
            .task(id: item.id) {
                exif = await ExifCache.shared.info(url: item.primary.url, mtime: item.primary.modified)
            }
        }
    }

    private func topBar(item: DisplayItem, position: Int) -> some View {
        HStack(spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text((item.primary.name as NSString).deletingPathExtension)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(position + 1) of \(items.count)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if let exif, exif.hasAny {
                Text(exif.caption)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.trailing, DS.Space.s)
            }
            if let raw = item.raw?.url {
                Button { NSWorkspace.shared.open(raw) } label: { Label("Open RAW", systemImage: "camera.aperture") }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.primary.url]) } label: {
                Label("Reveal", systemImage: "folder")
            }
            Button { index = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
    }

    private func navButton(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }

    private var shortcuts: some View {
        Group {
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { index = nil }.keyboardShortcut(.cancelAction)
            Button("") { index = nil }.keyboardShortcut(KeyEquivalent(" "), modifiers: [])
        }
        .opacity(0)
    }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let next = i + delta
        if items.indices.contains(next) { index = next }
    }
}

/// Loads the full image off-main (NAS reads can be slow → spinner), then allows
/// pinch/scroll zoom and drag-to-pan, double-click to toggle 1×/2×.
private struct ZoomableImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { zoom = min(8, max(1, committedZoom * $0)) }
                            .onEnded { _ in committedZoom = zoom; if zoom <= 1 { resetPan() } }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { g in
                                guard zoom > 1 else { return }
                                offset = CGSize(width: committedOffset.width + g.translation.width,
                                                height: committedOffset.height + g.translation.height)
                            }
                            .onEnded { _ in committedOffset = offset }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if zoom > 1 { zoom = 1; committedZoom = 1; resetPan() }
                            else { zoom = 2; committedZoom = 2 }
                        }
                    }
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 28))
                    Text("Couldn't load this image").font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task(id: url) { await load() }
    }

    private func resetPan() { offset = .zero; committedOffset = .zero }

    private func load() async {
        image = nil; failed = false; zoom = 1; committedZoom = 1; resetPan()
        let u = url
        let loaded = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: u) }.value
        if let loaded { image = loaded } else { failed = true }
    }
}
