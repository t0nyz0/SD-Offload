import SwiftUI
import OffloadCore

struct DoneView: View {
    @Environment(AppState.self) private var app
    var vm: SessionViewModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.safe)
                .symbolEffect(.bounce, value: vm.phase)
                .padding(.top, 8)

            Text("Card offloaded")
                .font(.system(size: 17, weight: .semibold))

            if let record = vm.completed {
                statsLines(record)
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Theme.safe)
                Text("Safe to remove the card.")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Theme.safe.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)

            if !app.settings.config.autoEject {
                Button("Eject") { app.ejectTapped() }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 14)
    }

    private func statsLines(_ record: SessionRecord) -> some View {
        VStack(spacing: 2) {
            let duration = record.endedAt.map { $0.timeIntervalSince(record.startedAt) }
            Text("\(record.stats.filesNASVerified + record.stats.filesSkippedDuplicate) files · \(Fmt.bytes(record.stats.bytesPlanned))\(duration.map { " · \(Fmt.duration($0))" } ?? "")")
                .font(.system(size: 12))
                .monospacedDigit()
            Text("avg \(Fmt.speed(record.stats.avgNASWriteBps)) to NAS · checksums verified end-to-end")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
