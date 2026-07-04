import SwiftUI

struct AttentionView: View {
    @Environment(AppState.self) private var app
    var vm: SessionViewModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.orange)
                .padding(.top, 10)

            Text(vm.failure?.title ?? "Something needs attention")
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if let detail = vm.failure?.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // The reassurance callout — always present when the wipe didn't run.
            if !(vm.failure?.cardWiped ?? false) {
                VStack(spacing: 2) {
                    Text("Your card has NOT been wiped.")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Copied files are also safe in local staging.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                Button {
                    app.retryTapped()
                } label: {
                    Text("Retry").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Show staged…") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: app.settings.config.stagingRootPath))
                }
            }
            .padding(.horizontal, 30)
        }
        .padding(.vertical, 14)
    }
}
