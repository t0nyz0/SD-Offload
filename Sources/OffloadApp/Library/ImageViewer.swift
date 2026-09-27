import SwiftUI
import AppKit
import AVKit
import OffloadCore
import OffloadEngine

/// A fast in-app image viewer — opens instantly instead of launching Preview.
/// Photos show the JPEG; videos use native AVKit playback controls.
/// Arrow keys navigate, Escape closes, Space plays/pauses videos or closes photos,
/// "i" toggles the info inspector, ⌦ deletes (NAS only).
struct ImageViewer: View {
    let items: [DisplayItem]
    @Binding var index: Int?
    var model: LibraryModel
    @State private var meta: PhotoMeta?
    // Persisted + on by default, so the inspector stays open across photos and
    // launches until you close it.
    @AppStorage("offload.viewer.showInfo") private var showInfo = true
    // Culling: after you rate or flag a photo, jump to the next one — the fast
    // Lightroom-style flow. Persisted, on by default; toggled from the top bar.
    @AppStorage("offload.viewer.autoAdvance") private var autoAdvance = true
    @State private var confirmingDelete = false
    @State private var hoveredControlHint: String?
    @State private var manualRotation = 0
    @State private var videoPlayer = AVPlayer()
    @State private var videoLoading = false
    @State private var videoError: String?

    private var isVideo: Bool {
        guard let current else { return false }
        if case .media(.video) = current.primary.kind { return true }
        return false
    }

    private var current: DisplayItem? {
        guard let i = index, items.indices.contains(i) else { return nil }
        return items[i]
    }
    private var canDelete: Bool { model.source == .nas }

    var body: some View {
        if let i = index, let item = current {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                    .onTapGesture { index = nil }

                VStack(spacing: 0) {
                    topBar(item: item, position: i)

                    // Image and inspector sit SIDE BY SIDE, so the panel never covers
                    // the photo — the image fits into the width left of the panel.
                    HStack(spacing: 0) {
                        ZStack {
                            if isVideo {
                                videoPreview(item)
                            } else {
                                ZoomableImage(url: item.primary.url, mtime: item.primary.modified,
                                              quarterTurns: manualRotation)
                                    .id(item.id)
                            }
                            HStack {
                                navButton("chevron.left", enabled: i > 0) { step(-1) }
                                Spacer()
                                navButton("chevron.right", enabled: i < items.count - 1) { step(1) }
                            }
                            .padding(.horizontal, 12)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if showInfo {
                            InfoPanel(item: item, meta: meta, model: model)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    // Reserve space so our controls never cover video playback controls.
                    cullBar(item: item)
                        .padding(.vertical, DS.Space.s)
                }
            }
            .background(shortcuts)
            .transition(.opacity)
            .task(id: item.id) {
                manualRotation = 0
                videoPlayer.pause()
                videoPlayer.replaceCurrentItem(with: nil)
                videoError = nil
                meta = nil
                if isVideo {
                    videoLoading = true
                    let asset = AVURLAsset(url: item.primary.url)
                    do {
                        let playable = try await asset.load(.isPlayable)
                        try Task.checkCancellation()
                        if playable {
                            videoPlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                        } else {
                            videoError = "macOS cannot play this video's format."
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        videoError = "Couldn't load this video: \(error.localizedDescription)"
                    }
                    videoLoading = false
                } else {
                    videoLoading = false
                    meta = await PhotoMetaCache.shared.meta(url: item.primary.url, mtime: item.primary.modified)
                }
            }
            .onDisappear {
                videoPlayer.pause()
                videoPlayer.replaceCurrentItem(with: nil)
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete) {
                if item.isRawJpegPair {
                    Button("Delete JPEG + RAW", role: .destructive) { Task { await deleteCurrent(.all) } }
                    Button("Delete RAW only", role: .destructive) { Task { await deleteCurrent(.rawOnly) } }
                    Button("Delete JPEG only", role: .destructive) { Task { await deleteCurrent(.jpegOnly) } }
                } else {
                    Button("Delete", role: .destructive) { Task { await deleteCurrent(.all) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deleteMessage(item))
            }
        }
    }

    @ViewBuilder
    private func videoPreview(_ item: DisplayItem) -> some View {
        if let videoError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("Video unavailable").font(.headline)
                Text(videoError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open in Default Video App") { NSWorkspace.shared.open(item.primary.url) }
            }
            .padding(32)
        } else {
            NativeVideoPlayer(player: videoPlayer)
                .overlay {
                    if videoLoading { ProgressView("Loading video…") }
                }
        }
    }

    private func deleteCurrent(_ scope: DeleteScope) async {
        guard let i = index, items.indices.contains(i) else { return }
        await model.delete(items[i], scope: scope)
        // The model updates its entries synchronously, so re-anchor against the
        // fresh list: stay at the same slot (now the next photo) or clamp/close.
        let remaining = model.photoItems
        index = remaining.isEmpty ? nil : min(i, remaining.count - 1)
    }

    private func deleteMessage(_ item: DisplayItem) -> String {
        if item.isRawJpegPair, let jpeg = item.photo, let raw = item.rawCompanion {
            return "This photo has a JPEG (\(jpeg.name)) and a RAW (\(raw.name)). Choose what to move to Trash. If Trash is unavailable, the originals are kept."
        }
        let names = item.all.map { ($0.id as NSString).lastPathComponent }
        let listed = names.count <= 3 ? names.joined(separator: ", ")
            : names.prefix(2).joined(separator: ", ") + ", and \(names.count - 2) more"
        return "Moves to Trash: \(listed) (plus any matching RAW/sidecar files) from your NAS. If Trash is unavailable, the originals are kept."
    }

    private func topBar(item: DisplayItem, position: Int) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: DS.Space.m) {
                Button { index = nil } label: {
                    Label("Back to Library", systemImage: "chevron.left")
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .modifier(ViewerControlHint(text: "Back to Library — close the photo viewer (Esc)", activeHint: $hoveredControlHint))

                VStack(alignment: .leading, spacing: 1) {
                    Text((item.primary.name as NSString).deletingPathExtension)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(position + 1) of \(items.count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button { autoAdvance.toggle() } label: {
                    Label("Auto-advance", systemImage: autoAdvance ? "forward.fill" : "forward")
                }
                .tint(autoAdvance ? Color.accentColor : nil)
                .modifier(ViewerControlHint(text: "Auto-advance — move to the next photo after rating or marking Pick/Reject", activeHint: $hoveredControlHint))
                HStack(spacing: 2) {
                    Button { rotateView(-1) } label: {
                        Label("Rotate left", systemImage: "rotate.left")
                    }
                    .modifier(ViewerControlHint(text: "Rotate left — turn the view 90° counterclockwise ([)", activeHint: $hoveredControlHint))
                    Button { rotateView(1) } label: {
                        Label("Rotate right", systemImage: "rotate.right")
                    }
                    .modifier(ViewerControlHint(text: "Rotate right — turn the view 90° clockwise (])", activeHint: $hoveredControlHint))
                }
                .labelStyle(.iconOnly)
                .disabled(isVideo)
                Button { withAnimation(.snappy(duration: 0.2)) { showInfo.toggle() } } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .tint(showInfo ? Color.accentColor : nil)
                .modifier(ViewerControlHint(text: "Photo info — show or hide tags, camera details, and metadata (i)", activeHint: $hoveredControlHint))
                if let raw = item.rawCompanion?.url {
                    Button { NSWorkspace.shared.open(raw) } label: { Label("Open RAW", systemImage: "camera.aperture") }
                        .modifier(ViewerControlHint(text: "Open RAW — open the original camera file in its default app", activeHint: $hoveredControlHint))
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.primary.url]) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .modifier(ViewerControlHint(text: "Show in Finder — locate this photo in its folder", activeHint: $hoveredControlHint))
                if canDelete {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    .modifier(ViewerControlHint(text: "Move to Trash — review which photo files to remove (⌦)", activeHint: $hoveredControlHint))
                }
            }
            .labelStyle(.iconOnly)
            Text(hoveredControlHint ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(Color(white: 0.12))
        .foregroundStyle(.white)
    }

    // Favorites are the primary action; ratings and culling flags stay separate.
    private func cullBar(item: DisplayItem) -> some View {
        let stars = model.rating(for: item)
        let flag = model.flag(for: item)
        let favorite = model.isFavorite(item.primary.id)
        return HStack(spacing: DS.Space.m) {
            // Keep an exit beside the always-visible photo controls even when
            // macOS window tabs/titlebar obscure the viewer's content header.
            Button { index = nil } label: {
                Label("Back to Library", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .help("Back to Library (Esc)")
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.primary.url]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .help("Reveal this photo in Finder")
            Divider().frame(height: 18).overlay(.white.opacity(0.2))
            Button { model.toggleFavorite(item) } label: {
                Label(favorite ? "Favorited" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
                    .foregroundStyle(favorite ? Color.pink : .white)
            }
            .buttonStyle(.plain)
            .help(favorite ? "Remove from Favorites (F)" : "Add to Favorites (F)")
            .accessibilityValue(favorite ? "On" : "Off")
            Divider().frame(height: 18).overlay(.white.opacity(0.2))
            Text("Rating").foregroundStyle(.white.opacity(0.65))
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { n in
                    Button { rate(n == stars ? 0 : n, for: item) } label: {
                        Image(systemName: n <= stars ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(n <= stars ? Color.yellow : .white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(n) star\(n == 1 ? "" : "s")")
                    .help("\(n) star\(n == 1 ? "" : "s") (\(n))")
                }
            }
            Divider().frame(height: 18).overlay(.white.opacity(0.2))
            Menu {
                Button(flag == .pick ? "Clear Pick (P)" : "Mark as Pick (P)") { setFlag(.pick, for: item) }
                Button(flag == .reject ? "Clear Reject (X)" : "Mark as Reject (X)") { setFlag(.reject, for: item) }
            } label: {
                Text(flag == .pick ? "Picked" : flag == .reject ? "Rejected" : "Pick / Reject")
                    .foregroundStyle(flag == .pick ? Color.green : flag == .reject ? Color.red : .white.opacity(0.65))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Pick marks a photo to keep; Reject marks it for review. Neither changes Favorites or deletes the file.")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }

    private func rate(_ n: Int, for item: DisplayItem) {
        model.setRating(n, for: item)
        if autoAdvance && n > 0 { advanceAfterCull() }
    }
    private func setFlag(_ f: PhotoFlag, for item: DisplayItem) {
        let wasSet = model.flag(for: item) == f
        model.toggleFlag(f, for: item)
        if autoAdvance && !wasSet { advanceAfterCull() }
    }
    // Advance to the next photo, but stop at the end rather than wrapping or closing —
    // culling shouldn't dump you out of the viewer.
    private func advanceAfterCull() {
        guard let i = index, i < items.count - 1 else { return }
        step(1)
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
            Button("") {
                if isVideo {
                    if videoPlayer.rate == 0 { videoPlayer.play() } else { videoPlayer.pause() }
                } else { index = nil }
            }.keyboardShortcut(KeyEquivalent(" "), modifiers: [])
            Button("") { withAnimation(.snappy(duration: 0.2)) { showInfo.toggle() } }
                .keyboardShortcut("i", modifiers: [])
            Button("") { if canDelete { confirmingDelete = true } }
                .keyboardShortcut(.delete, modifiers: [])
            Button("") { if let c = current { model.toggleFavorite(c) } }
                .keyboardShortcut("f", modifiers: [])
            Button("") { rotateView(-1) }
                .keyboardShortcut("[", modifiers: [])
            Button("") { rotateView(1) }
                .keyboardShortcut("]", modifiers: [])
            // Culling keys: 0–5 rate, P pick, X reject (Lightroom-style).
            ForEach(0...5, id: \.self) { n in
                Button("") { if let c = current { rate(n, for: c) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
            }
            Button("") { if let c = current { setFlag(.pick, for: c) } }
                .keyboardShortcut("p", modifiers: [])
            Button("") { if let c = current { setFlag(.reject, for: c) } }
                .keyboardShortcut("x", modifiers: [])
        }
        .opacity(0)
    }

    private func step(_ delta: Int) {
        guard let i = index else { return }
        let next = i + delta
        if items.indices.contains(next) { index = next }
    }

    private func rotateView(_ delta: Int) {
        manualRotation = ((manualRotation + delta) % 4 + 4) % 4
    }
}

/// A tiny LRU of already-decoded full-resolution images, keyed by url + mtime.
/// Culling a shoot with arrow keys used to re-fetch every JPEG from SMB and then
/// re-decode it on the main thread on first draw — now the previous/next stay
/// warm in memory and re-visiting is instant.
@MainActor
final class FullImageCache {
    static let shared = FullImageCache()
    private struct Key: Hashable { let path: String; let mtime: TimeInterval; let rotation: Int }
    private var order: [Key] = []            // most-recent-last
    private var store: [Key: NSImage] = [:]
    private let capacity = 8
    private let byteLimit: Int
    private var costs: [Key: Int] = [:]
    private(set) var residentBytes = 0

    init(byteLimit: Int = 384 << 20) { self.byteLimit = byteLimit }

    func get(url: URL, mtime: Date, rotation: Int = 0) -> NSImage? {
        let k = Key(path: url.path, mtime: mtime.timeIntervalSinceReferenceDate, rotation: rotation)
        guard let img = store[k] else { return nil }
        if let i = order.firstIndex(of: k) { order.remove(at: i); order.append(k) }
        return img
    }
    func put(url: URL, mtime: Date, rotation: Int = 0, image: NSImage) {
        let k = Key(path: url.path, mtime: mtime.timeIntervalSinceReferenceDate, rotation: rotation)
        guard store[k] == nil else { return }
        let cost = image.representations.map { rep in
            if let bitmap = rep as? NSBitmapImageRep { return bitmap.bytesPerRow * bitmap.pixelsHigh }
            return rep.pixelsWide * rep.pixelsHigh * 8 // allow high-bit-depth decodes
        }.max() ?? Int(image.size.width * image.size.height * 8)
        guard cost <= byteLimit else { return } // the viewer still displays it; don't retain it
        order.append(k); store[k] = image; costs[k] = cost
        residentBytes += cost
        while order.count > capacity || residentBytes > byteLimit, let victim = order.first {
            order.removeFirst(); store.removeValue(forKey: victim)
            residentBytes -= costs.removeValue(forKey: victim) ?? 0
        }
    }
    func clear() { order.removeAll(); store.removeAll(); costs.removeAll(); residentBytes = 0 }
}

/// Loads the full image off-main and force-decodes it (NSImage(contentsOf:) is
/// lazy — actual decode happens on the main thread the first time it draws,
/// which stalls arrow-key nav). ImageIO with `kCGImageSourceShouldCacheImmediately`
/// pushes the decode to the background task. Result is cached in FullImageCache
/// so bouncing between photos doesn't re-fetch or re-decode.
private struct ZoomableImage: View {
    let url: URL
    let mtime: Date
    let quarterTurns: Int
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomPanSurface(image: image)
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
        .task(id: LoadID(url: url, rotation: quarterTurns)) { await load() }
    }

    private struct LoadID: Hashable { let url: URL; let rotation: Int }

    private static let decodeLimiter = ThumbLimiter(limit: 1)

    private func load() async {
        if let cached = FullImageCache.shared.get(url: url, mtime: mtime, rotation: quarterTurns) {
            image = cached; failed = false
            return
        }
        image = nil; failed = false
        let u = url
        let rotation = quarterTurns
        let base = FullImageCache.shared.get(url: url, mtime: mtime)
        await Self.decodeLimiter.acquire()
        defer { Task { await Self.decodeLimiter.release() } }
        guard !Task.isCancelled else { return }
        let loaded = await BackgroundWork.run(priority: .userInitiated) { () -> (NSImage, NSImage?)? in
            guard !Task.isCancelled else { return nil }
            let baseImage: NSImage
            if let base {
                baseImage = base
            } else {
                guard let cg = OrientedImageDecoder.decode(url: u) else { return nil }
                baseImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            guard rotation != 0 else { return (baseImage, nil) }
            guard let cg = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let rotated = OrientedImageDecoder.rotated(cg, quarterTurns: rotation) else { return nil }
            let display = NSImage(cgImage: rotated,
                                  size: NSSize(width: rotated.width, height: rotated.height))
            return (display, base == nil ? baseImage : nil)
        }
        guard !Task.isCancelled else { return }
        if let loaded {
            image = loaded.0
            if let decodedBase = loaded.1 {
                FullImageCache.shared.put(url: url, mtime: mtime, image: decodedBase)
            } else if rotation == 0 {
                FullImageCache.shared.put(url: url, mtime: mtime, image: loaded.0)
            }
            FullImageCache.shared.put(url: url, mtime: mtime, rotation: rotation, image: loaded.0)
        } else {
            failed = true
        }
    }
}

/// Bridges the loaded photo into `ZoomScrollView`. We drop to AppKit because
/// NSScrollView gives us native pinch magnification, trackpad two-finger pan (precise
/// scroll) and momentum for free — things SwiftUI's Magnification/Drag gestures can't
/// match — and we layer mouse-wheel zoom + a click-drag hand tool on top of it.
private struct ZoomPanSurface: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> ZoomScrollView { ZoomScrollView(image: image) }

    func updateNSView(_ nsView: ZoomScrollView, context: Context) {
        // `.id(item.id)` remounts us per photo. Manual rotation intentionally
        // replaces the image in place and returns zoom to fit.
        if nsView.pannableView.image !== image {
            nsView.pannableView.image = image
            nsView.magnification = nsView.minMagnification
        }
    }
}

/// The scroll view: owns magnification limits, a transparent background, and
/// mouse-wheel zoom. Trackpad/precise scrolling is deferred to `super` so native
/// two-finger pan and pinch keep their momentum and rubber-banding.
private final class ZoomScrollView: NSScrollView {
    let pannableView: PannableImageView

    init(image: NSImage) {
        pannableView = PannableImageView()
        super.init(frame: .zero)

        pannableView.image = image
        pannableView.imageScaling = .scaleProportionallyUpOrDown   // fit, never crop
        pannableView.imageAlignment = .alignCenter
        documentView = pannableView

        // 1× is fit-to-view (see `tile()`); 8× is the ceiling the task calls for.
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 8

        // Transparent so the surrounding SwiftUI black shows through the letterbox
        // margins; no scrollers — the hand tool and wheel are the whole interaction.
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Never in the responder chain: mouse/scroll/pinch are delivered by hit-testing the
    /// view under the cursor, not by focus, so staying out keeps the SwiftUI parent's
    /// Left/Right arrows, Escape, Space, i, f and ⌦ shortcuts working untouched.
    override var acceptsFirstResponder: Bool { false }

    /// Pin the document view to the *unmagnified* viewport size so magnification 1
    /// means fit-to-view. NSScrollView scales this frame by `magnification`, so the
    /// photo (scaleProportionallyUpOrDown, centered) letterboxes inside it at 1× and
    /// there is nothing to pan until you zoom past fit. `contentView.frame` is the
    /// viewport in scroll-view space (magnification-independent), so this tracks
    /// window resizes without fighting the zoom.
    override func tile() {
        super.tile()
        let size = contentView.frame.size
        if documentView?.frame.size != size {
            documentView?.frame = NSRect(origin: .zero, size: size)
        }
    }

    /// Let clicks in the transparent letterbox fall THROUGH to the SwiftUI layer — the
    /// black backdrop's tap-to-close and the nav chevrons layered above us — while still
    /// claiming clicks on the drawn photo for double-click and scroll-wheel zoom. Once
    /// zoomed, the photo fills the viewport, so every click/scroll is ours. Without this
    /// the representable's NSView would silently eat the parent's background tap.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)               // nil if the point is outside our bounds
        guard let hit, magnification <= minMagnification + 0.0001 else { return hit }
        let local = pannableView.convert(point, from: superview)
        return pannableView.fittedImageRect.contains(local) ? hit : nil
    }

    override func scrollWheel(with event: NSEvent) {
        // Precise deltas = trackpad two-finger scroll / Magic Mouse surface (and the
        // inertial momentum tail) → let NSScrollView pan and pinch-magnify natively.
        guard !event.hasPreciseScrollingDeltas, event.momentumPhase == [] else {
            super.scrollWheel(with: event)
            return
        }
        // Coarse, line-based deltas = a real scroll wheel → zoom about the cursor.
        // deltaY > 0 (wheel rolled up/away) zooms in; multiplicative so each notch is
        // an even step across 1×–8×. (Flip this sign if a user's "natural scrolling"
        // preference ever makes the wheel direction feel inverted.)
        let notches = event.deltaY
        guard notches != 0 else { return }
        let target = min(maxMagnification, max(minMagnification, magnification * pow(1.25, notches)))
        // setMagnification wants the anchor in content (clip) space.
        setMagnification(target, centeredAt: contentView.convert(event.locationInWindow, from: nil))
    }
}

/// The document view. Owns the click-drag "hand tool" pan and the double-click zoom.
/// We handle the mouse here rather than on the scroll view because, as the front-most
/// view under the cursor, it reliably receives mouseDown/Dragged — a control-derived
/// NSImageView won't necessarily bubble those up to the enclosing scroll view.
private final class PannableImageView: NSImageView {
    /// Anchor captured at mouseDown: cursor position in *window* space (stable while we
    /// scroll) and the clip's bounds origin at that instant. Recomputing an absolute
    /// origin from this fixed anchor each drag avoids the drift of summing per-event deltas.
    private var panStartInWindow: NSPoint?
    private var panStartOrigin: NSPoint = .zero

    /// Zoomed past fit → there is room to pan and the grab cursor makes sense.
    private var isZoomed: Bool {
        guard let sv = enclosingScrollView else { return false }
        return sv.magnification > sv.minMagnification + 0.0001
    }

    /// The rect the photo actually occupies inside this view — aspect-fit, centered
    /// (matching .scaleProportionallyUpOrDown + .alignCenter). The scroll view's hitTest
    /// uses it to tell "click on the photo" from "click in the transparent letterbox".
    var fittedImageRect: NSRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let w = image.size.width * scale, h = image.size.height * scale
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Let a click grab-and-pan even when the window isn't yet key — a viewer should
    /// feel immediate.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Show an open-hand cursor while hovering a zoomed (grabbable) photo.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .cursorUpdate, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }
    override func cursorUpdate(with event: NSEvent) {
        if isZoomed { NSCursor.openHand.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let sv = enclosingScrollView else { return }
        if event.clickCount == 2 {
            // Double-click toggles fit ↔ 2×, centered on the cursor, animated to match
            // the SwiftUI "snappy" feel the rest of the viewer uses.
            let anchor = sv.contentView.convert(event.locationInWindow, from: nil)
            let target: CGFloat = isZoomed ? sv.minMagnification : 2
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                sv.animator().setMagnification(target, centeredAt: anchor)
            }
            return
        }
        guard isZoomed else { return }   // at fit there is nothing to pan
        panStartInWindow = event.locationInWindow
        panStartOrigin = sv.contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sv = enclosingScrollView, let start = panStartInWindow else { return }
        let clip = sv.contentView
        let scale = sv.magnification
        let now = event.locationInWindow
        // Hand tool: shift the clip's bounds origin OPPOSITE the cursor's screen motion
        // so the photo tracks the pointer 1:1. Divide by magnification because one screen
        // point spans 1/scale document points when zoomed. Window coords are y-up and the
        // clip view is unflipped, so subtracting keeps "drag right → image right" and
        // "drag up → image up" (decreasing an unflipped clip's origin.y scrolls content up).
        let proposed = NSPoint(x: panStartOrigin.x - (now.x - start.x) / scale,
                               y: panStartOrigin.y - (now.y - start.y) / scale)
        let constrained = clip.constrainBoundsRect(NSRect(origin: proposed, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        sv.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if panStartInWindow != nil { NSCursor.openHand.set() }
        panStartInWindow = nil
    }
}

/// The right-side inspector: everything we know about the photo — format + size,
/// capture date, camera + lens, exposure, dimensions, GPS, and content tags.
private struct InfoPanel: View {
    let item: DisplayItem
    let meta: PhotoMeta?
    let model: LibraryModel
    @State private var detections: [Detection] = []
    @State private var reloadToken = 0
    @State private var ai: PhotoIdentifier.Identification?
    @State private var identifying = false
    @State private var aiError: String?
    @State private var runToken = UUID()   // guards a slow identify against a photo switch

    private func kindLabel(_ e: LibraryEntry) -> String {
        switch e.kind {
        case .media(.raw): return "RAW"
        case .media(.video): return "Video"
        default: return e.url.pathExtension.uppercased()
        }
    }
    // The File row: for a JPEG+RAW pair, show each file's own size rather than a
    // combined total; for a lone file, "<KIND> · <size>". (Uses the actual entries,
    // so a RAW-only item reads "RAW · …", not the old "JPEG + RAW".)
    private var fileLine: String {
        func rank(_ e: LibraryEntry) -> Int {
            switch e.kind { case .media(.photo): return 0; case .media(.raw): return 1; default: return 2 }
        }
        let parts = item.all.sorted { rank($0) < rank($1) }
        if parts.count <= 1 {
            let e = parts.first ?? item.primary
            return "\(kindLabel(e)) · \(Fmt.bytes(e.size))"
        }
        return parts.map { "\(kindLabel($0)) \(Fmt.bytes($0.size))" }.joined(separator: " · ")
    }
    private var sizeLine: String? {
        guard let dim = meta?.dimensions else { return nil }
        return meta?.megapixels.map { "\(dim) · \($0)" } ?? dim
    }
    // Where this photo lives, relative to the library root (e.g. "2026/07/04").
    private var folderText: String? {
        guard let root = model.rootURL?.path else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        let dir = (item.primary.id as NSString).deletingLastPathComponent
        if dir == base { return nil }                                   // in the root itself
        if dir.hasPrefix(base + "/") { return String(dir.dropFirst(base.count + 1)) }
        return (dir as NSString).lastPathComponent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Info")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                PhotoTagsSection(entry: item.primary, model: model).id(item.id)
                aiSection
                row("File", fileLine)
                if let d = meta?.dateText { row("Taken", d) }
                if let c = meta?.cameraName { row("Camera", c) }
                if let l = meta?.lens { row("Lens", l) }
                if let e = meta?.exif, e.hasAny { row("Exposure", e.caption) }
                if let f = meta?.focalLen35Text { row("35 mm equiv", f) }
                if let ev = meta?.exposureBiasText { row("Exposure comp", ev) }
                if let mode = meta?.exposureProgramText { row("Shooting mode", mode) }
                if let em = meta?.exposureModeText { row("Exposure mode", em) }
                if let mt = meta?.meteringText { row("Metering", mt) }
                if let wb = meta?.whiteBalanceText { row("White balance", wb) }
                if let sc = meta?.sceneTypeText { row("Scene", sc) }
                if let fl = meta?.flashText { row("Flash", fl) }
                if let s = sizeLine { row("Dimensions", s) }
                if let cp = meta?.colorProfileText { row("Color", cp) }
                if let sw = meta?.software { row("Software", sw) }
                if let sn = meta?.serialText { row("Serial", sn) }
                if let g = meta?.gpsText {
                    VStack(alignment: .leading, spacing: 3) {
                        label("Location")
                        Text(g).font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
                        if let alt = meta?.altitudeText {
                            Text("Altitude \(alt)")
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if let heading = meta?.headingText {
                            Text("Facing \(heading)")
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        if let url = meta?.mapsURL {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Open in Maps", systemImage: "map").font(.system(size: 11))
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                if let folder = folderText { row("Folder", folder) }
                if !detections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label("People & Pets")
                        ForEach(detections) { det in
                            FaceRow(detection: det, path: item.primary.id, mtime: item.primary.modified,
                                    model: model, onChanged: { reloadToken += 1 })
                        }
                    }
                }
                Spacer(minLength: DS.Space.s)
                HistogramView(url: item.primary.url)
            }
            .padding(DS.Space.l)
            .frame(width: 260, alignment: .leading)
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .foregroundStyle(.white)
        .task(id: "\(item.id)#\(reloadToken)") {
            detections = await model.detections(for: item.primary.id)
        }
    }

    // On-demand Claude identification: description + specific tags, or a button to run it.
    @ViewBuilder private var aiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Theme.accent)
                label("AI Identification")
            }
            if let ai {
                if !ai.description.isEmpty {
                    Text(ai.description)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            } else if identifying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Identifying photo…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Button { runIdentify() } label: {
                    Label("Identify with AI", systemImage: "sparkles").font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                Text("Uses the AI provider selected in Settings → Library to describe the subject and scene.")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                if let aiError {
                    Text(aiError).font(.system(size: 9)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: item.id) {
            runToken = UUID()
            ai = nil; aiError = nil; identifying = false
            ai = await model.existingIdentification(for: item)
        }
    }

    private func runIdentify() {
        let token = runToken
        identifying = true; aiError = nil
        Task {
            do {
                let result = try await model.identify(item)
                guard token == runToken else { return }   // user moved on; result stays saved
                ai = result
            } catch {
                guard token == runToken else { return }
                aiError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if token == runToken { identifying = false }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
            Text(value)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.4))
    }
}

/// One detected face/pet in the current photo — a crop plus controls to confirm a
/// suggestion, pick/enter a name, or reject. Suggest-only: nothing auto-labels.
private struct FaceRow: View {
    let detection: Detection
    let path: String
    let mtime: Date
    let model: LibraryModel
    let onChanged: () -> Void

    @State private var crop: NSImage?
    @State private var showNameAlert = false
    @State private var newName = ""

    private var assignedName: String? { model.identityName(detection.assignedID) }
    private var suggestedName: String? {
        detection.assignedID == nil ? model.identityName(detection.suggestedID) : nil
    }
    private var kindWord: String { detection.kind == .pet ? "pet" : "person" }
    private var sameKind: [Identity] { model.identities.filter { $0.kind == detection.identityKind } }

    var body: some View {
        HStack(spacing: 8) {
            thumb
            VStack(alignment: .leading, spacing: 2) {
                if let name = assignedName {
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                    Text(kindWord.capitalized).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                } else if let s = suggestedName {
                    Text("\(s)?").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    Text("suggested").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                } else {
                    Text("Unnamed \(kindWord)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .task(id: detection.id) {
            crop = await FaceCropLoader.shared.crop(url: URL(fileURLWithPath: path), bbox: detection.bbox, mtime: mtime)
        }
        .alert("Name this \(kindWord)", isPresented: $showNameAlert) {
            TextField("Name", text: $newName)
            Button("Save") { let n = newName; newName = ""; act { await model.nameDetection(detection, in: path, as: n) } }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }

    @ViewBuilder private var thumb: some View {
        Group {
            if let crop {
                Image(nsImage: crop).resizable().scaledToFill()
            } else {
                Image(systemName: detection.kind == .pet ? "pawprint.fill" : "person.crop.square.fill")
                    .resizable().scaledToFit().padding(9).foregroundStyle(.white.opacity(0.3))
            }
        }
        .frame(width: 40, height: 40)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 2) {
            if detection.assignedID == nil, detection.suggestedID != nil {
                Button { act { await model.confirmSuggestion(detection, in: path) } } label: { Image(systemName: "checkmark") }
                    .buttonStyle(.borderless).help("Confirm")
                Button { act { await model.rejectSuggestion(detection, in: path) } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Not this one")
            }
            Menu {
                ForEach(sameKind) { idn in
                    Button(idn.name) { act { await model.assignDetection(detection, in: path, to: idn.id) } }
                }
                if !sameKind.isEmpty { Divider() }
                Button("New name…") { newName = ""; showNameAlert = true }
                if detection.assignedID != nil {
                    Divider()
                    Button("Remove name", role: .destructive) { act { await model.unnameDetection(detection, in: path) } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.8))
    }

    private func act(_ work: @escaping () async -> Void) {
        Task { await work(); onChanged() }
    }
}

/// Minimal wrapping layout for the content-tag chips (macOS 14 Layout protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x - bounds.minX + sz.width > bounds.width, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowHeight = max(rowHeight, sz.height)
        }
    }
}

/// Use AppKit directly, avoiding the SwiftUI AVKit wrapper's runtime dependency.
private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Native tooltips plus an immediate, stable caption beneath the viewer toolbar.
private struct ViewerControlHint: ViewModifier {
    let text: String
    @Binding var activeHint: String?

    func body(content: Content) -> some View {
        content
            .help(text)
            .accessibilityHint(text)
            .onHover { hovering in
                if hovering { activeHint = text }
                else if activeHint == text { activeHint = nil }
            }
    }
}
