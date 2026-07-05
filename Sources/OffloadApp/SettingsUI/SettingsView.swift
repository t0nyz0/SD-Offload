import SwiftUI
import AppKit
import OffloadCore
import OffloadEngine

struct SettingsView: View {
    @Environment(AppState.self) private var app

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
                    Text("After NAS verification (recommended)").tag(WipePolicy.afterNASVerify)
                    Text("After local staging verification").tag(WipePolicy.afterStagingVerify)
                    Text("Ask every time").tag(WipePolicy.askEachTime)
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
                Toggle("Thorough NAS verification (slower)", isOn: $settings.config.thoroughNASVerify)
                Text("Standard reads each uploaded file back through the SMB cache and checksums it end-to-end. Thorough forces uncached reads straight off the server — safest, but much slower over a network share.")
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
                    Picker("Completion sound", selection: $settings.config.completionSoundName) {
                        ForEach(Sounds.all, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: settings.config.completionSoundName) { _, name in
                        Sounds.play(name)   // preview on select
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
