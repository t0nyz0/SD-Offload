import SwiftUI
import OffloadCore

/// Ask-mode: a card we don't have a remembered policy for.
struct ConsentView: View {
    @Environment(AppState.self) private var app
    let card: CardInfo

    var body: some View {
        VStack(spacing: 14) {
            SDCardShape()
                .stroke(Theme.accent, lineWidth: 1.5)
                .frame(width: 64, height: 80)
                .padding(.top, 8)

            VStack(spacing: 3) {
                Text("Offload \(card.volumeName)?")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(Fmt.bytes(card.usedBytes)) used of \(Fmt.bytes(card.capacityBytes))\(card.hasMediaRoot ? " · camera card" : "")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 6) {
                Button {
                    app.consentTapped()
                } label: {
                    Text("Offload now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    app.declineTapped()
                } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 40)

            Text("Asking because “When a card is inserted” is set to Ask in Settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(.vertical, 18)
    }
}
