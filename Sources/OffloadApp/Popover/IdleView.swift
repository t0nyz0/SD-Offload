import SwiftUI
import OffloadCore
import OffloadEngine

struct IdleView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation(minimumInterval: 1 / 20, paused: !app.popoverVisible)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let wave = sin(t / 2.4 * 2 * .pi)
                SDCardShape()
                    .stroke(.tertiary, lineWidth: 1.5)
                    .frame(width: 84, height: 104)
                    .opacity(0.55 + 0.2 * wave)
                    .scaleEffect(1 + 0.015 * wave)
            }
            .frame(height: 108)

            VStack(spacing: DS.Space.xs) {
                Text("Waiting for a card")
                    .font(DS.Typo.title)
                Text("Insert an SD card — Offload copies, verifies, and files it on your NAS, then clears the card.")
                    .font(DS.Typo.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Space.xl)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NASGlanceRow()
                .padding(.horizontal, 16)

            if let last = app.recent.first {
                lastSessionLine(last)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func lastSessionLine(_ record: SessionRecord) -> some View {
        HStack(spacing: 4) {
            Image(systemName: record.state == .done ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(record.state == .done ? Theme.safe : .orange)
                .font(.system(size: 10))
            Text("\(record.startedAt.formatted(.relative(presentation: .named))) · \(record.fileCount) file\(record.fileCount == 1 ? "" : "s") · \(Fmt.bytes(record.stats.bytesPlanned))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

/// Compact NAS overview: mount dot, free space, photo count, Browse.
struct NASGlanceRow: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let glance = app.nasGlance
        HStack(spacing: 8) {
            Circle()
                .fill(glance.healthy ? Theme.safe : (glance.mounted ? .orange : Color.secondary.opacity(0.4)))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(nasTitle(glance))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Text(nasSubtitle(glance))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Browse…") {
                dismiss()
                Activate.front()
                openWindow(id: WindowID.library)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func nasTitle(_ g: NASGlance) -> String {
        guard g.mounted else { return "NAS not mounted" }
        return "\(Fmt.bytes(g.freeBytes)) free of \(Fmt.bytes(g.totalBytes))"
    }

    private func nasSubtitle(_ g: NASGlance) -> String {
        guard g.mounted else { return "Insert happens anyway — uploads queue until it returns" }
        if let count = g.photoCount {
            var s = "\(count.formatted()) photos on the NAS"
            if let bytes = g.photoBytes { s += " · \(Fmt.bytes(bytes))" }
            return s
        }
        return g.healthy ? "Photos library" : "Mounted, but not the expected share"
    }
}
