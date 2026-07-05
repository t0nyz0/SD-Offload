import SwiftUI
import OffloadCore

/// A fast in-app image viewer — opens instantly instead of launching Preview.
/// Always shows the JPEG (the display copy); the RAW opens externally on demand.
/// Arrow keys move between photos, Escape/Space closes, scroll/pinch zooms,
/// "i" toggles the info inspector, ⌦ deletes (NAS only).
struct ImageViewer: View {
    let items: [DisplayItem]
    @Binding var index: Int?
    var model: LibraryModel
    @State private var meta: PhotoMeta?
    // Persisted + on by default, so the inspector stays open across photos and
    // launches until you close it.
    @AppStorage("offload.viewer.showInfo") private var showInfo = true
    @State private var confirmingDelete = false

    private var current: DisplayItem? {
        guard let i = index, items.indices.contains(i) else { return nil }
        return items[i]
    }
    private var canDelete: Bool { model.source == .nas }

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

                // Prev / next chevrons (hidden while the inspector is open so it
                // doesn't sit under the panel — arrow keys still navigate).
                if !showInfo {
                    HStack {
                        navButton("chevron.left", enabled: i > 0) { step(-1) }
                        Spacer()
                        navButton("chevron.right", enabled: i < items.count - 1) { step(1) }
                    }
                    .padding(.horizontal, 12)
                }

                if showInfo {
                    HStack(spacing: 0) {
                        Spacer()
                        InfoPanel(item: item, meta: meta, tags: model.tags(for: item.primary), model: model)
                    }
                    .padding(.top, 44)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(shortcuts)
            .transition(.opacity)
            .task(id: item.id) {
                meta = await PhotoMetaCache.shared.meta(url: item.primary.url, mtime: item.primary.modified)
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

    private func deleteCurrent(_ scope: DeleteScope) async {
        guard let i = index, items.indices.contains(i) else { return }
        await model.delete(items[i], scope: scope)
        // The model updates its entries synchronously, so re-anchor against the
        // fresh list: stay at the same slot (now the next photo) or clamp/close.
        let remaining = model.displayedItems.filter { !$0.isFolder }
        index = remaining.isEmpty ? nil : min(i, remaining.count - 1)
    }

    private func deleteMessage(_ item: DisplayItem) -> String {
        if item.isRawJpegPair, let jpeg = item.photo, let raw = item.rawCompanion {
            return "This photo has a JPEG (\(jpeg.name)) and a RAW (\(raw.name)). Choose what to delete from your NAS — this can't be undone."
        }
        let names = item.all.map { ($0.id as NSString).lastPathComponent }
        let listed = names.count <= 3 ? names.joined(separator: ", ")
            : names.prefix(2).joined(separator: ", ") + ", and \(names.count - 2) more"
        return "Permanently deletes \(listed) (plus any matching RAW/sidecar files) from your NAS. This can't be undone."
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
            if let exif = meta?.exif, exif.hasAny {
                Text(exif.caption)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.trailing, DS.Space.s)
            }
            Button { withAnimation(.snappy(duration: 0.2)) { showInfo.toggle() } } label: {
                Label("Info", systemImage: "info.circle")
            }
            .tint(showInfo ? Color.accentColor : nil)
            .help("Show photo info (i)")
            if let raw = item.rawCompanion?.url {
                Button { NSWorkspace.shared.open(raw) } label: { Label("Open RAW", systemImage: "camera.aperture") }
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.primary.url]) } label: {
                Label("Reveal", systemImage: "folder")
            }
            if canDelete {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .help("Delete from NAS (⌦)")
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
            Button("") { withAnimation(.snappy(duration: 0.2)) { showInfo.toggle() } }
                .keyboardShortcut("i", modifiers: [])
            Button("") { if canDelete { confirmingDelete = true } }
                .keyboardShortcut(.delete, modifiers: [])
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

/// The right-side inspector: everything we know about the photo — format + size,
/// capture date, camera + lens, exposure, dimensions, GPS, and content tags.
private struct InfoPanel: View {
    let item: DisplayItem
    let meta: PhotoMeta?
    let tags: [String]
    let model: LibraryModel
    @State private var detections: [Detection] = []
    @State private var reloadToken = 0

    private func kindLabel(_ e: LibraryEntry) -> String {
        switch e.kind {
        case .media(.raw): return "RAW"
        case .media(.video): return "Video"
        default: return "JPEG"
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
                row("File", fileLine)
                if let d = meta?.dateText { row("Taken", d) }
                if let c = meta?.cameraName { row("Camera", c) }
                if let l = meta?.lens { row("Lens", l) }
                if let e = meta?.exif, e.hasAny { row("Exposure", e.caption) }
                if let f = meta?.focalLen35Text { row("35 mm equiv", f) }
                if let ev = meta?.exposureBiasText { row("Exposure comp", ev) }
                if let mode = meta?.exposureProgramText { row("Shooting mode", mode) }
                if let mt = meta?.meteringText { row("Metering", mt) }
                if let wb = meta?.whiteBalanceText { row("White balance", wb) }
                if let fl = meta?.flashText { row("Flash", fl) }
                if let s = sizeLine { row("Dimensions", s) }
                if let cp = meta?.colorProfileText { row("Color", cp) }
                if let sw = meta?.software { row("Software", sw) }
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
                        if let url = meta?.mapsURL {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Open in Maps", systemImage: "map").font(.system(size: 11))
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                if let folder = folderText { row("Folder", folder) }
                if !tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label("Contents")
                        FlowLayout(spacing: 5) {
                            ForEach(tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(.white.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                }
                if !detections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        label("People & Pets")
                        ForEach(detections) { det in
                            FaceRow(detection: det, path: item.primary.id, mtime: item.primary.modified,
                                    model: model, onChanged: { reloadToken += 1 })
                        }
                    }
                }
                Spacer(minLength: 0)
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
private struct FlowLayout: Layout {
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
