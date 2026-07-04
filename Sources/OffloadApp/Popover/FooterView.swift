import SwiftUI
import OffloadCore

struct FooterView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !app.recent.isEmpty {
                Text("RECENT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                ForEach(app.recent.prefix(3)) { record in
                    sessionRow(record)
                }
            }
            HStack {
                Menu {
                    Button("Settings…") {
                        dismiss()
                        Activate.front()
                        openSettings()
                    }
                    Button("Library…") { openAux(WindowID.library) }
                    Button("History…") { openAux(WindowID.history) }
                    Divider()
                    Button("Quit Offload") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button("History…") { openAux(WindowID.history) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func openAux(_ id: String) {
        dismiss()
        Activate.front()
        openWindow(id: id)
    }

    private func sessionRow(_ record: SessionRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph(for: record.state))
                .font(.system(size: 9))
                .foregroundStyle(record.state == .done ? Theme.safe : .orange)
                .frame(width: 10)
            Text(record.startedAt.formatted(date: .abbreviated, time: .omitted))
                .frame(width: 54, alignment: .leading)
            Text(record.cardVolumeName)
                .lineLimit(1)
            Spacer()
            Text(Fmt.bytes(record.stats.bytesPlanned))
                .foregroundStyle(.secondary)
            if let end = record.endedAt {
                Text(Fmt.duration(end.timeIntervalSince(record.startedAt)))
                    .foregroundStyle(.tertiary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
    }

    private func glyph(for state: SessionState) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .doneWipeBlocked: "exclamationmark.circle.fill"
        case .cancelled: "slash.circle"
        case .failed: "xmark.circle.fill"
        default: "clock"
        }
    }
}
