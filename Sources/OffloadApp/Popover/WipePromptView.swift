import SwiftUI

/// Countdown mode (auto policies) or explicit consent (ask-each-time policy).
struct WipePromptView: View {
    @Environment(AppState.self) private var app
    var vm: SessionViewModel

    var body: some View {
        VStack(spacing: 12) {
            if vm.phase == .wipeCountdown, let seconds = vm.wipeCountdown {
                Label {
                    Text("Wiping card in \(seconds)s")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 17, weight: .semibold))
                .accessibilityLabel("Wiping card in \(seconds) seconds")

                subtitle

                Button {
                    app.cancelWipeTapped()
                } label: {
                    Text("Cancel wipe").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, 40)
                .accessibilityLabel("Cancel wipe — keep the card's contents")
            } else {
                Text("Wipe card now?")
                    .font(.system(size: 17, weight: .semibold))

                subtitle

                HStack(spacing: 8) {
                    Button {
                        app.confirmWipeTapped()
                    } label: {
                        Text("Wipe & eject").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.safe)

                    Button {
                        app.cancelWipeTapped()
                    } label: {
                        Text("Keep contents").frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 30)
            }
        }
        .padding(.vertical, 22)
    }

    private var subtitle: some View {
        Text("All \(vm.plannedFiles) files are checksum-verified on the NAS.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}
