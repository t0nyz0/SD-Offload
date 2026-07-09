import SwiftUI
import AppKit
import OffloadCore
import OffloadEngine

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(ThumbnailQuality.storageKey) private var thumbQuality = ThumbnailQuality.defaultQuality.rawValue
    // Changing quality is confirmed first (it rebuilds the thumbnail cache); the
    // picked value is held here and only committed on confirm, so Cancel reverts.
    @State private var pendingThumbQuality: Int?
    @State private var confirmRecache = false
    @State private var apiKey = ""   // mirrors the Keychain-stored Anthropic key

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Destination") {
                LabeledContent("NAS folder") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(app.nasGlance.healthy ? Theme.safe : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                        Text(settings.config.nasRootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { pickFolder { settings.config.nasRootPath = $0; settings.config.nasExpectedMntFromName = nil; settings.config.nasSMBURL = nil; app.refreshNASGlance() } }
                            .controlSize(.small)
                    }
                }
                Text("Photos are organized into YYYY/MM/DD folders by capture date.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Second copy (optional)") {
                LabeledContent("Second drive") {
                    HStack(spacing: 8) {
                        Text(settings.config.secondaryDestPath ?? "Off")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(settings.config.secondaryDestPath == nil ? .secondary : .primary)
                        Button("Change…") { pickFolder { settings.config.secondaryDestPath = $0 } }
                            .controlSize(.small)
                        if settings.config.secondaryDestPath != nil {
                            Button("Off") { settings.config.secondaryDestPath = nil }
                                .controlSize(.small)
                        }
                    }
                }
                Text("When set, each photo is verified on this drive too, and the card isn't erased until it's confirmed on BOTH here and the NAS — so a wipe never leaves a single copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Ingest") {
                Picker("When a card is inserted", selection: $settings.config.defaultCardAction) {
                    Text("Offload automatically").tag(CardPolicy.alwaysIngest)
                    Text("Ask each time").tag(CardPolicy.ask)
                    Text("Do nothing").tag(CardPolicy.ignore)
                }
                Picker("Copy", selection: $settings.config.ingestScope) {
                    Text("Camera folders only (DCIM & video)").tag(IngestScope.mediaRootsOnly)
                    Text("Entire card").tag(IngestScope.wholeCard)
                }
            }

            Section("Card wipe") {
                Picker("Erase the card", selection: $settings.config.wipePolicy) {
                    Text("Ask every time (recommended)").tag(WipePolicy.askEachTime)
                    Text("Automatically, after NAS verification").tag(WipePolicy.afterNASVerify)
                    Text("Automatically, after local staging verification").tag(WipePolicy.afterStagingVerify)
                }
                .pickerStyle(.radioGroup)
                Toggle("Eject card automatically when done", isOn: $settings.config.autoEject)
            }

            Section("Staging") {
                LabeledContent("Local staging") {
                    HStack(spacing: 8) {
                        Text(settings.config.stagingRootPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { pickFolder { settings.config.stagingRootPath = $0 } }
                            .controlSize(.small)
                    }
                }
                Picker("Keep staged copies", selection: $settings.config.keepStagedDays) {
                    Text("Until NAS verified").tag(0)
                    Text("For 7 days").tag(7)
                    Text("For 30 days").tag(30)
                }
            }

            Section("Performance") {
                Stepper("Parallel NAS uploads: \(settings.config.hop2Workers)",
                        value: $settings.config.hop2Workers, in: 1...8)
                Text("Each uploaded file is read back from the NAS uncached and checksummed against the card before the card can be wiped — always. More parallel uploads can help on fast links; a single spinning-disk NAS may prefer fewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Warm up the NAS when a card is inserted", isOn: $settings.config.prewarmNAS)
                Text("Starts checking and waking the NAS the moment a card is detected, so the first upload doesn't stall while the connection and drives spin up. Read-only — it never writes to the NAS until your files are verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Library") {
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
            }

            Section("AI photo analysis") {
                Picker("Provider", selection: $settings.config.aiProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if settings.config.aiProvider == .api {
                    SecureField("Anthropic API key", text: $apiKey)
                        .onChange(of: apiKey) { _, v in
                            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                            if t.isEmpty { Keychain.delete(service: Keychain.aiAPIKeyService) }
                            else { Keychain.set(t, service: Keychain.aiAPIKeyService) }
                        }
                    TextField("Model", text: $settings.config.aiModel, prompt: Text("claude-opus-4-8"))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Powers the viewer's “Identify” and the library “Analyze”. **CLI** uses your logged-in Claude session (no key, no extra billing). **API** uses your Anthropic key and is billed to your account. Your key is stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Card detected", isOn: $settings.config.notifyCardDetected)
                Toggle("Transfer complete (safe to remove)", isOn: $settings.config.notifyComplete)
                Toggle("Problems", isOn: $settings.config.notifyProblems)
            }

            Section("General") {
                LoginItemToggle()
                Toggle("Pop open the tray when a card is inserted", isOn: $settings.config.autoOpenTrayOnInsert)
                Toggle("Reveal uploaded photos in the Library when an offload finishes", isOn: $settings.config.autoShowLibrary)
                Toggle("Play a sound when an offload finishes", isOn: $settings.config.playSounds)
                if settings.config.playSounds {
                    HStack {
                        Picker("Completion sound", selection: $settings.config.completionSoundName) {
                            ForEach(Sounds.all, id: \.self) { Text($0).tag($0) }
                        }
                        .onChange(of: settings.config.completionSoundName) { _, name in
                            Sounds.play(name)   // preview on select
                        }
                        Button { Sounds.play(settings.config.completionSoundName) } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Preview this sound")
                    }
                }
                LabeledContent("Version", value: AppInfo.versionString)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
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
