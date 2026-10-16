import SwiftUI
import OffloadCore

struct CardDetectionState {
    let card: CardInfo
    var hasMediaRoot: Bool?
    var detail: String {
        guard let hasMediaRoot else { return "Checking card access…" }
        return hasMediaRoot ? "Camera files found."
            : "No camera folders found yet. Check that the card is readable, then choose Look for a card."
    }
}

struct CardDetectedView: View {
    @Environment(AppState.self) private var app
    let state: CardDetectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(state.card.volumeName) · \(Fmt.bytes(state.card.capacityBytes))")
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Label("Card detected", systemImage: "sdcard.fill")
                .font(.system(size: 20, weight: .semibold))
            HStack {
                if state.hasMediaRoot == nil { ProgressView().controlSize(.small) }
                Text(state.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.hasMediaRoot == false {
                Button("Look for a card") { app.rescanTapped() }.controlSize(.small)
            }
        }
        .padding(16)
    }
}
