import SwiftUI
import AppKit
import OffloadCore
import OffloadEngine

/// Settings organized like modern macOS System Settings — a sidebar of grouped
/// panes on the left, one pane at a time on the right. Every setting from the
/// old single scroll survives, just clustered so nothing is a mile-long list.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(ThumbnailQuality.storageKey) private var thumbQuality = ThumbnailQuality.defaultQuality.rawValue
    // Changing quality is confirmed first (it rebuilds the thumbnail cache); the
    // picked value is held here and only committed on confirm, so Cancel reverts.
    @State private var pendingThumbQuality: Int?
    @State private var confirmRecache = false
    @State private var apiKey = ""              // mirrors the Keychain-stored Anthropic key
    @State private var pane: Pane = .general
    @State private var showCustomDateLayout = false
    @State private var customDatePattern = "{YYYY}/{MM}/{DD}"
    @State private var showLibraryMigration = false

    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case general, destination, offload, library, notifications
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:       return "General"
            case .destination:   return "Destination"
            case .offload:       return "Card & Offload"
            case .library:       return "Library"
            case .notifications: return "Notifications"
            }
        }
        var icon: String {
            switch self {
            case .general:       return "gearshape"
            case .destination:   return "externaldrive.connected.to.line.below"
            case .offload:       return "sdcard"
            case .library:       return "photo.stack"
            case .notifications: return "bell"
            }
        }
    }

    var body: some View {
        @Bindable var settings = app.settings
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.label, systemImage: p.icon).tag(p)
            }
            .listStyle(.sidebar)
            .frame(width: 200)
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text(pane.label).font(.title2.bold())
                    Spacer()
                    Button("Close Settings") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w", modifiers: .command)
                }
                .padding(20)
                Divider()
                Group {
                    switch pane {
                    case .general:       generalPane(settings: settings)
                    case .destination:   destinationPane(settings: settings)
                    case .offload:       offloadPane(settings: settings)
                    case .library:       libraryPane(settings: settings)
                    case .notifications: notificationsPane(settings: settings)
                    }
                }
                .id(pane) // Each pane starts at its own scroll origin.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .onAppear { app.refreshNASGlance(); apiKey = Keychain.get(service: Keychain.aiAPIKeyService) ?? "" }
        .confirmationDialog("Rebuild thumbnails?", isPresented: $confirmRecache, presenting: pendingThumbQuality) { newQ in
            Button("Rebuild at \(ThumbnailQuality(rawValue: newQ)?.label ?? "New") quality") {
                thumbQuality = newQ                       // commit the change
                ThumbnailLoader.shared.clearCaches()      // regenerate at the new quality
            }
            Button("Cancel", role: .cancel) { pendingThumbQuality = nil }
        } message: { newQ in
            Text("Existing thumbnails are cleared and rebuilt at \(ThumbnailQuality(rawValue: newQ)?.label ?? "the new") quality. Photos you're viewing update right away; the rest rebuild as you browse. For a large library over the NAS this can take a while.")
        }
        .sheet(isPresented: $showCustomDateLayout) { customDateLayoutSheet(settings: settings) }
        .sheet(isPresented: $showLibraryMigration) {
            LibraryMigrationSheet(settings: settings)
                .environment(app)
        }
    }

    // MARK: - General

    @ViewBuilder
    private func generalPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        SettingsPaneForm {
            SettingsSection("Startup") {
                LoginItemToggle()
                Toggle("Pop open the tray when a card is inserted", isOn: $s.config.autoOpenTrayOnInsert)
                Toggle("Reveal uploaded photos in the Library when an offload finishes", isOn: $s.config.autoShowLibrary)
            }

            SettingsSection("Sound") {
                Toggle("Play a sound when an offload finishes", isOn: $s.config.playSounds)
                if s.config.playSounds {
                    HStack {
                        Picker("Completion sound", selection: $s.config.completionSoundName) {
                            ForEach(Sounds.all, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: s.config.completionSoundName) { _, name in
                            Sounds.play(name)   // preview on select
                        }
                        Button { Sounds.play(s.config.completionSoundName) } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Preview this sound")
                    }
                }
            }

            SettingsSection("About") {
                LabeledContent("Version", value: AppInfo.versionString)
            }
        }
    }

    // MARK: - Destination

    @ViewBuilder
    private func destinationPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        SettingsPaneForm {
            SettingsSection {
                LabeledContent("NAS folder") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(app.nasGlance.healthy ? Theme.safe : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(s.config.nasRootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") {
                            pickFolder {
                                s.config.nasRootPath = $0
                                s.config.nasExpectedMntFromName = nil
                                s.config.nasSMBURL = nil
                                app.refreshNASGlance()
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Text("Photos are organized into your selected date-folder layout using capture metadata.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Primary")
            }

            SettingsSection {
                Picker("Folder organization", selection: Binding(
                    get: { s.config.dateFolderLayout.pattern },
                    set: { pattern in
                        guard let layout = DateFolderLayout.presets.first(where: { $0.pattern == pattern }) else { return }
                        applyDateLayout(layout, settings: s)
                    }
                )) {
                    ForEach(DateFolderLayout.presets) { layout in
                        Text(layout.name).tag(layout.pattern)
                    }
                    if !s.config.dateFolderLayout.isPreset {
                        Text("Custom").tag(s.config.dateFolderLayout.pattern)
                    }
                }
                LabeledContent("Preview") {
                    Text(dateLayoutPreview(s.config.dateFolderLayout))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Custom…") {
                        customDatePattern = s.config.dateFolderLayout.pattern
                        showCustomDateLayout = true
                    }
                    Button("Reorganize Existing Library…") { showLibraryMigration = true }
                        .disabled(app.session != nil)
                }
                Text("Changing the layout affects new imports immediately. Reorganize Existing Library safely renames recognized date folders, updates saved Library data, and can resume or roll back after interruption.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Date folders")
            }

            SettingsSection {
                LabeledContent("Second drive") {
                    HStack(spacing: 8) {
                        Text(s.config.secondaryDestPath ?? "Off")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(s.config.secondaryDestPath == nil ? .secondary : .primary)
                        Button("Change…") { pickFolder { s.config.secondaryDestPath = $0 } }
                            .controlSize(.small)
                        if s.config.secondaryDestPath != nil {
                            Button("Off") { s.config.secondaryDestPath = nil }
                                .controlSize(.small)
                        }
                    }
                }
                Text("When set, each photo is verified on this drive too, and the card isn't erased until it's confirmed on BOTH here and the NAS — so a wipe never leaves a single copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Second copy (optional)")
            }
        }
    }

    // MARK: - Card & Offload

    @ViewBuilder
    private func offloadPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        SettingsPaneForm {
            SettingsSection("When a card is inserted") {
                Picker("Action", selection: $s.config.defaultCardAction) {
                    Text("Offload automatically").tag(CardPolicy.alwaysIngest)
                    Text("Ask each time").tag(CardPolicy.ask)
                    Text("Do nothing").tag(CardPolicy.ignore)
                }
                Picker("Files to copy", selection: $s.config.ingestScope) {
                    Text("Camera folders only (DCIM & video)").tag(IngestScope.mediaRootsOnly)
                    Text("Entire card").tag(IngestScope.wholeCard)
                }
            }

            SettingsSection("Erase the card") {
                Picker("Wipe policy", selection: $s.config.wipePolicy) {
                    Text("Ask every time (recommended)").tag(WipePolicy.askEachTime)
                    Text("Automatically, after NAS verification").tag(WipePolicy.afterNASVerify)
                }
                .pickerStyle(.radioGroup)
                Toggle("Eject card automatically when done", isOn: $s.config.autoEject)
            }

            SettingsSection {
                LabeledContent("Local staging") {
                    HStack(spacing: 8) {
                        Text(s.config.stagingRootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { pickFolder { s.config.stagingRootPath = $0 } }
                            .controlSize(.small)
                    }
                }
                Picker("Keep staged copies", selection: $s.config.keepStagedDays) {
                    Text("Until the next transfer (NAS rechecked)").tag(0)
                    Text("For 7 days").tag(7)
                    Text("For 30 days").tag(30)
                }
            } header: {
                Text("Staging")
            }

            SettingsSection {
                Stepper("Parallel NAS uploads: \(s.config.hop2Workers)",
                        value: $s.config.hop2Workers, in: 1...8)
                Text("Each uploaded file is read back from the NAS uncached and checksummed against the card before the card can be wiped — always. More parallel uploads can help on fast links; a single spinning-disk NAS may prefer fewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Warm up the NAS when a card is inserted", isOn: $s.config.prewarmNAS)
                Text("Starts checking and waking the NAS the moment a card is detected, so the first upload doesn't stall while the connection and drives spin up. Read-only — it never writes to the NAS until your files are verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Performance")
            }
        }
    }

    // MARK: - Library

    @ViewBuilder
    private func libraryPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        SettingsPaneForm {
            SettingsSection {
                Picker("Thumbnail quality", selection: Binding(
                    get: { thumbQuality },
                    set: { newValue in
                        guard newValue != thumbQuality else { return }
                        pendingThumbQuality = newValue        // hold; commit in the confirm dialog
                        confirmRecache = true
                    }
                )) {
                    ForEach(ThumbnailQuality.allCases, id: \.rawValue) { q in
                        Text(q.label).tag(q.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Higher quality decodes the full photo for sharper thumbnails; lower is faster, especially over a slow NAS connection. Changing this rebuilds the thumbnail cache.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Thumbnails")
            }

            SettingsSection {
                Picker("Provider", selection: $s.config.aiProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if s.config.aiProvider == .api {
                    SecureField("Anthropic API key", text: $apiKey)
                        .onChange(of: apiKey) { _, v in
                            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                            if t.isEmpty { Keychain.delete(service: Keychain.aiAPIKeyService) }
                            else { Keychain.set(t, service: Keychain.aiAPIKeyService) }
                        }
                    TextField("Model", text: $s.config.aiModel,
                              prompt: Text("e.g. claude-opus-4-5 — leave blank for default"))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Powers the viewer's “Identify” and the library “Analyze”. **CLI** uses your logged-in Claude session (no key, no extra billing). **API** uses your Anthropic key and is billed to your account. Your key is stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("AI photo analysis")
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private func notificationsPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        SettingsPaneForm {
            SettingsSection {
                Toggle("Card detected", isOn: $s.config.notifyCardDetected)
                Toggle("Transfer complete (safe to remove)", isOn: $s.config.notifyComplete)
                Toggle("Problems", isOn: $s.config.notifyProblems)
            } header: {
                Text("Show a notification for")
            } footer: {
                Text("Notifications appear even when the app is in the background. Turn any of them off if the tray icon is enough.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pickFolder(_ apply: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            apply(url.path)
        }
    }

    private func applyDateLayout(_ layout: DateFolderLayout, settings: SettingsStore) {
        let old = settings.config.dateFolderLayout
        if !settings.config.recognizedDateFolderLayouts.contains(old) {
            settings.config.recognizedDateFolderLayouts.append(old)
        }
        settings.config.dateFolderLayout = layout
        if !settings.config.recognizedDateFolderLayouts.contains(layout) {
            settings.config.recognizedDateFolderLayouts.append(layout)
        }
    }

    private func dateLayoutPreview(_ layout: DateFolderLayout) -> String {
        var dc = DateComponents(); dc.year = 2026; dc.month = 7; dc.day = 4
        let sample = Calendar.current.date(from: dc) ?? Date()
        return layout.destinationRelPath(fileName: "IMG_1234.RAF", captureDate: sample)
    }

    @ViewBuilder
    private func customDateLayoutSheet(settings: SettingsStore) -> some View {
        let candidate = DateFolderLayout(id: "custom", name: "Custom", pattern: customDatePattern)
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Date Layout").font(.title2.bold())
            Text("Use {YYYY}, {MM}, {MMM}, {MMMM}, and {DD}. A slash creates another folder level.")
                .foregroundStyle(.secondary)
            TextField("Pattern", text: $customDatePattern)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            LabeledContent("Preview", value: dateLayoutPreview(candidate))
                .font(.system(.body, design: .monospaced))
            if let error = candidate.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { showCustomDateLayout = false }
                Button("Use Layout") {
                    let selected = DateFolderLayout.presets.first { $0.pattern == candidate.pattern } ?? candidate
                    applyDateLayout(selected, settings: settings)
                    showCustomDateLayout = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(candidate.validationError != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct LibraryMigrationSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: SettingsStore
    @State private var plan: LibraryMigrationPlan?
    @State private var state: LibraryMigrationState?
    @State private var busy = false
    @State private var error: String?
    private let migrator = LibraryMigrator()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reorganize Existing Library").font(.title2.bold())
            Text("Convert recognized date folders to **\(settings.config.dateFolderLayout.name)** without rewriting photo data.")
                .foregroundStyle(.secondary)

            if let state {
                migrationStateView(state)
            } else if let plan {
                planView(plan)
            } else {
                Text("SD Offload will perform a read-only scan first. Unrecognized folders are left untouched, existing files are never overwritten, and a configured second destination must match.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Scan Library") { scan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || app.session != nil)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy { ProgressView().controlSize(.small) }
            Spacer()
            HStack {
                Spacer()
                Button(state?.status == .completed || state?.status == .rolledBack ? "Done" : "Close") {
                    if state?.status == .completed || state?.status == .rolledBack {
                        Task { await migrator.acknowledge() }
                    }
                    dismiss()
                }
                .disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 590, height: 460)
        .task { await loadPending() }
    }

    @ViewBuilder
    private func planView(_ plan: LibraryMigrationPlan) -> some View {
        GroupBox("Preflight Summary") {
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("Files", value: plan.moves.count.formatted())
                LabeledContent("Data", value: ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
                LabeledContent("Date folders", value: plan.folders.count.formatted())
                LabeledContent("Filename conflicts preserved with suffixes", value: plan.collisionCount.formatted())
                LabeledContent("Unrecognized top-level folders left untouched", value: plan.ignoredFolderCount.formatted())
                LabeledContent("Second destination", value: plan.secondaryRoot == nil ? "Not configured" : "Included")
            }.padding(6)
        }
        HStack {
            Button("Scan Again") { self.plan = nil; scan() }
            Spacer()
            Button("Convert \(plan.moves.count) Files") { start(plan) }
                .buttonStyle(.borderedProminent)
                .disabled(busy || app.session != nil)
        }
    }

    @ViewBuilder
    private func migrationStateView(_ state: LibraryMigrationState) -> some View {
        let total = max(1, state.plan.moves.count)
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Text(statusTitle(state.status)).font(.headline)
                ProgressView(value: Double(state.completedMoves), total: Double(total))
                Text("\(state.completedMoves.formatted()) of \(state.plan.moves.count.formatted()) files")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = state.lastError { Text(last).font(.caption).foregroundStyle(.orange) }
            }.padding(6)
        }
        if state.status == .rollingBack {
            HStack {
                Spacer()
                Button("Continue Rollback") { resume() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || app.session != nil)
            }
        } else if state.status == .planned || state.status == .failed
                    || state.status == .moving || state.status == .updatingMetadata {
            HStack {
                Button("Roll Back", role: .destructive) { rollback() }
                    .disabled(busy || app.session != nil)
                Spacer()
                Button("Resume") { resume() }.buttonStyle(.borderedProminent)
                    .disabled(busy || app.session != nil)
            }
        } else if state.status == .completed {
            Label("Library converted successfully. Saved paths and both destinations are synchronized.",
                  systemImage: "checkmark.circle.fill").foregroundStyle(Theme.safe)
        } else if state.status == .rolledBack {
            Label("The original folder layout and saved Library data were restored.",
                  systemImage: "arrow.uturn.backward.circle.fill")
        }
    }

    private func statusTitle(_ status: LibraryMigrationState.Status) -> String {
        switch status {
        case .planned: "Ready to resume"
        case .moving: "Moving folders safely…"
        case .updatingMetadata: "Updating saved Library paths…"
        case .completed: "Conversion complete"
        case .rollingBack: "Restoring the original layout…"
        case .rolledBack: "Rollback complete"
        case .failed: "Conversion interrupted"
        }
    }

    private func scan() {
        busy = true; error = nil
        let config = settings.config, target = config.dateFolderLayout
        Task {
            do { plan = try await migrator.makePlan(config: config, target: target) }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            busy = false
        }
    }

    private func start(_ plan: LibraryMigrationPlan) {
        busy = true; error = nil
        NotificationCenter.default.post(name: .offloadLibraryMigrationStarted, object: nil)
        Task {
            do {
                try await migrator.start(plan, onProgress: progressHandler)
                await finishedFilesystemChange()
            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            busy = false
        }
    }

    private func resume() {
        busy = true; error = nil
        NotificationCenter.default.post(name: .offloadLibraryMigrationStarted, object: nil)
        Task {
            do { try await migrator.resume(onProgress: progressHandler); await finishedFilesystemChange() }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            busy = false
        }
    }

    private func rollback() {
        busy = true; error = nil
        Task {
            do { try await migrator.rollback(onProgress: progressHandler); await finishedFilesystemChange() }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            busy = false
        }
    }

    private var progressHandler: @Sendable (LibraryMigrationState) -> Void {
        { update in Task { @MainActor in self.state = update } }
    }

    private func loadPending() async {
        if let pending = await migrator.pendingState() { state = pending }
    }

    @MainActor
    private func finishedFilesystemChange() async {
        settings.reload()
        LibraryIndex.invalidate()
        FolderStatsLoader.shared.invalidateAll()
        ThumbnailLoader.shared.clearCaches()
        NotificationCenter.default.post(name: .offloadLibraryMigrated, object: nil)
        app.rescanTapped()
        state = await migrator.pendingState()
    }
}

extension Notification.Name {
    static let offloadLibraryMigrationStarted = Notification.Name("offload.libraryMigrationStarted")
    static let offloadLibraryMigrated = Notification.Name("offload.libraryMigrated")
}

enum AppInfo {
    static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// A single scroll surface with bounded, leading-aligned content. Avoid the
/// grouped Form's implicit scrolling/sizing inside an AppKit-hosted split view.
private struct SettingsPaneForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toggleStyle(.switch)
    }
}

private struct SettingsSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer

    init(_ title: String, @ViewBuilder content: () -> Content)
        where Header == Text, Footer == EmptyView {
        self.content = content()
        self.header = Text(title)
        self.footer = EmptyView()
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header)
        where Footer == EmptyView {
        self.content = content()
        self.header = header()
        self.footer = EmptyView()
    }

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            footer
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
