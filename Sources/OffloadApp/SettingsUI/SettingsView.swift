import SwiftUI
import AppKit
import OffloadCore
import OffloadEngine

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage(ThumbnailQuality.storageKey) private var thumbQuality = ThumbnailQuality.balanced.rawValue

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
                Picker("Copy", selection: $settings.config.ingestScope) {
                    Text("Camera folders only (DCIM & video)").tag(IngestScope.mediaRootsOnly)
                    Text("Entire card").tag(IngestScope.wholeCard)
                }
                if !settings.config.cardPolicies.isEmpty {
                    CardRulesList()
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
            }

            Section("Library") {
                Picker("Thumbnail quality", selection: $thumbQuality) {
                    ForEach(ThumbnailQuality.allCases, id: \.rawValue) { q in
                        Text(q.label).tag(q.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("Higher quality decodes the full photo for sharper thumbnails; lower is faster, especially over a slow NAS connection. Applies to newly generated thumbnails.")
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
        .onAppear { app.refreshNASGlance() }
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

/// Remembered per-card rules.
struct CardRulesList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        ForEach(settings.config.cardPolicies.keys.sorted(), id: \.self) { uuid in
            HStack {
                Text(settings.config.cardNames[uuid] ?? String(uuid.prefix(12)))
                    .lineLimit(1)
                Spacer()
                Picker("", selection: Binding(
                    get: { settings.config.cardPolicies[uuid] ?? .ask },
                    set: { settings.config.cardPolicies[uuid] = $0 }
                )) {
                    Text("Always offload").tag(CardPolicy.alwaysIngest)
                    Text("Ask").tag(CardPolicy.ask)
                    Text("Ignore").tag(CardPolicy.ignore)
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    settings.config.cardPolicies.removeValue(forKey: uuid)
                    settings.config.cardNames.removeValue(forKey: uuid)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
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
