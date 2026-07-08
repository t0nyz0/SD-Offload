import SwiftUI
import OffloadCore

struct FooterView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !app.recent.isEmpty {
                Text("RECENT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                ForEach(app.recent.prefix(3)) { record in
                    Button { app.router?.openHistory(selecting: record.id) } label: { sessionRow(record) }
                        .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                Button { app.router?.openLibrary(folder: nil) } label: {
                    Label("Library", systemImage: "photo.stack")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Button { app.router?.openHistory(selecting: nil) } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Menu {
                    Button("Settings…") { app.router?.openSettings() }
                    Divider()
                    Button("Quit SD Offload") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Settings & Quit")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            Text("\(record.fileCount) file\(record.fileCount == 1 ? "" : "s") · \(Fmt.bytes(record.stats.bytesPlanned))")
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
