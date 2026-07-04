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
                Text("\(Fmt.bytes(card.usedBytes)) used of \(Fmt.bytes(card.capacityBytes))\(card.hasDCIM ? " · camera card" : "")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            VStack(spacing: 6) {
                Button {
                    app.consentTapped(remember: .alwaysIngest)
                } label: {
                    Text("Always offload this card").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)

                Button {
                    app.consentTapped(remember: nil)
                } label: {
                    Text("Just this once").frame(maxWidth: .infinity)
                }

                Button {
                    app.declineTapped(remember: .ignore)
                } label: {
                    Text("Ignore this card").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .controlSize(.small)
            }
            .padding(.horizontal, 40)
        }
        .padding(.vertical, 18)
    }
}
