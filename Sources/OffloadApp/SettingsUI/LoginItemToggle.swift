import SwiftUI
import ServiceManagement

/// SMAppService requires a real .app bundle — it fails under bare `swift run`,
/// so the toggle is disabled in dev with a footnote.
struct LoginItemToggle: View {
    @State private var enabled = false
    @State private var error: String?

    private var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Launch at login", isOn: Binding(
                get: { enabled },
                set: { setEnabled($0) }
            ))
            .disabled(!available)
            if !available {
                Text("Available in the built app (Scripts/build-app.sh).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear {
            guard available else { return }
            enabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func setEnabled(_ on: Bool) {
        guard available else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            enabled = on
            error = nil
        } catch let err {
            error = err.localizedDescription
            enabled = SMAppService.mainApp.status == .enabled
        }
    }
}
