import SwiftUI
import Charts
import OffloadCore

struct HistoryWindow: View {
    @Environment(AppState.self) private var app
    @State private var sessions: [SessionRecord] = []
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(sessions, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: record.state == .done ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(record.state == .done ? Theme.safe : .orange)
                            .font(.system(size: 10))
                        Text(record.cardVolumeName)
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text("\(record.fileCount) file\(record.fileCount == 1 ? "" : "s") · \(Fmt.bytes(record.stats.bytesPlanned))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .tag(record.id)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            if let record = sessions.first(where: { $0.id == selection }) {
                SessionDetailView(record: record)
            } else {
                ContentUnavailableView("No session selected", systemImage: "sdcard",
                                       description: Text(sessions.isEmpty ? "Offload a card and it shows up here." : "Pick a session on the left."))
            }
        }
        .task {
            sessions = await app.journal.loadHistory(limit: 100)
            if selection == nil { selection = sessions.first?.id }
        }
    }
}

struct SessionDetailView: View {
    let record: SessionRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.cardVolumeName)
                        .font(.title2.bold())
                    Text(record.startedAt.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)
                    Text(statusLine)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(record.state == .done ? Theme.safe : .orange)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    stat("Files", "\(record.stats.filesNASVerified + record.stats.filesSkippedDuplicate) of \(record.stats.filesPlanned)")
                    stat("Data", Fmt.bytes(record.stats.bytesPlanned))
                    stat("Duration", record.endedAt.map { Fmt.duration($0.timeIntervalSince(record.startedAt)) } ?? "—")
                    stat("Avg to NAS", Fmt.speed(record.stats.avgNASWriteBps))
                    stat("Avg card read", Fmt.speed(record.stats.avgSDReadBps))
                    stat("Wiped", record.wipeReport?.ran == true ? "\(record.wipeReport?.filesDeleted ?? 0) files" : "no")
                }

                if !record.stats.phases.isEmpty {
                    PhaseTimelineView(phases: record.stats.phases)
                }

                if record.stats.timeline.count >= 2 {
                    Text("Throughput")
                        .font(.headline)
                    Chart {
                        ForEach(Array(record.stats.timeline.enumerated()), id: \.offset) { _, s in
                            LineMark(x: .value("s", s.t), y: .value("MB/s", s.sdReadBps / 1_000_000),
                                     series: .value("series", "Card read"))
                                .foregroundStyle(Theme.accent)
                            LineMark(x: .value("s", s.t), y: .value("MB/s", s.nasWriteBps / 1_000_000),
                                     series: .value("series", "NAS write"))
                                .foregroundStyle(Theme.safe)
                        }
                    }
                    .frame(height: 160)
                }

                if let report = record.wipeReport, !report.blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why the card wasn't wiped")
                            .font(.headline)
                        ForEach(report.blockers, id: \.self) { blocker in
                            Label(blocker, systemImage: "exclamationmark.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusLine: String {
        switch record.state {
        case .done: "Completed — card wiped and ejected"
        case .doneWipeBlocked: "Files safe on NAS — card NOT wiped"
        case .cancelled: "Cancelled — nothing deleted"
        case .failed: "Failed — card NOT wiped"
        default: "In progress"
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhaseTimelineView: View {
    let phases: [PhaseSpan]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Timeline")
                .font(.headline)
                .padding(.bottom, 6)
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        Image(systemName: phase.end != nil ? "checkmark.circle.fill" : "circle.dotted")
                            .font(.system(size: 11))
                            .foregroundStyle(phase.end != nil ? Theme.safe : .secondary)
                        if index < phases.count - 1 {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 1, height: 14)
                        }
                    }
                    HStack {
                        Text(phase.name.capitalized)
                            .font(.system(size: 12))
                        Spacer()
                        if let duration = phase.duration {
                            Text(Fmt.duration(duration))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
