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
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.label, systemImage: p.icon).tag(p)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            Group {
                switch pane {
                case .general:       generalPane(settings: settings)
                case .destination:   destinationPane(settings: settings)
                case .offload:       offloadPane(settings: settings)
                case .library:       libraryPane(settings: settings)
                case .notifications: notificationsPane(settings: settings)
                }
            }
            .navigationTitle(pane.label)
            .navigationSplitViewColumnWidth(min: 480, ideal: 540)
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
    }

    // MARK: - General

    @ViewBuilder
    private func generalPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        Form {
            Section("Startup") {
                LoginItemToggle()
                Toggle("Pop open the tray when a card is inserted", isOn: $s.config.autoOpenTrayOnInsert)
                Toggle("Reveal uploaded photos in the Library when an offload finishes", isOn: $s.config.autoShowLibrary)
            }

            Section("Sound") {
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

            Section("About") {
                LabeledContent("Version", value: AppInfo.versionString)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Destination

    @ViewBuilder
    private func destinationPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        Form {
            Section {
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
                Text("Photos are organized into YYYY/MM/DD folders by capture date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Primary")
            }

            Section {
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
        .formStyle(.grouped)
    }

    // MARK: - Card & Offload

    @ViewBuilder
    private func offloadPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        Form {
            Section("When a card is inserted") {
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

            Section("Erase the card") {
                Picker("Wipe policy", selection: $s.config.wipePolicy) {
                    Text("Ask every time (recommended)").tag(WipePolicy.askEachTime)
                    Text("Automatically, after NAS verification").tag(WipePolicy.afterNASVerify)
                    Text("Automatically, after local staging verification").tag(WipePolicy.afterStagingVerify)
                }
                .pickerStyle(.radioGroup)
                Toggle("Eject card automatically when done", isOn: $s.config.autoEject)
            }

            Section {
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
                    Text("Until NAS verified").tag(0)
                    Text("For 7 days").tag(7)
                    Text("For 30 days").tag(30)
                }
            } header: {
                Text("Staging")
            }

            Section {
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
        .formStyle(.grouped)
    }

    // MARK: - Library

    @ViewBuilder
    private func libraryPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        Form {
            Section {
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

            Section {
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
        .formStyle(.grouped)
    }

    // MARK: - Notifications

    @ViewBuilder
    private func notificationsPane(settings: SettingsStore) -> some View {
        @Bindable var s = settings
        Form {
            Section {
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
        .formStyle(.grouped)
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
}

enum AppInfo {
    static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}
