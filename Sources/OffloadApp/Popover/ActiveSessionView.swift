import SwiftUI

struct ActiveSessionView: View {
    @Environment(AppState.self) private var app
    var vm: SessionViewModel

    private var isPaused: Bool {
        vm.phase == .pausedByUser || vm.phase == .pausedCardGone
    }

    var body: some View {
        VStack(spacing: 12) {
            header

            HStack(spacing: 18) {
                CardProgressView(progress: vm.overallFraction)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.percentInt)%")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(statusWord)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)

            VStack(spacing: 2) {
                if vm.phase == .pausedCardGone {
                    Text("Card removed — re-insert to finish")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    etaLine("Card free in", vm.etaCardFreeText)
                    etaLine("All on NAS in", vm.etaAllSafeText)
                }
            }

            VStack(spacing: 6) {
                StageProgressRow(label: "CARD → MAC", fraction: vm.hop1Fraction,
                                 speedText: vm.hop1SpeedText, tint: Theme.accent)
                StageProgressRow(label: "MAC → NAS", fraction: vm.hop2Fraction,
                                 speedText: vm.hop2SpeedText, tint: Theme.safe)
            }
            .padding(.horizontal, 16)

            if vm.samples.count >= 2 {
                ThroughputSparkline(samples: vm.samples)
                    .frame(height: 56)
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 1) {
                if !vm.filesText.isEmpty {
                    Text("\(vm.filesText) · \(vm.bytesText)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let name = vm.currentFileName {
                    Text(name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(height: 26)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack {
            Text(vm.cardTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if vm.resumed {
                Text("RESUMED")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 4).padding(.vertical, 1.5)
                    .background(Theme.accent.opacity(0.2), in: Capsule())
            }
            Spacer()
            if vm.phase == .transferring || isPaused {
                Button {
                    isPaused ? app.resumeTapped() : app.pauseTapped()
                } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(isPaused ? "Resume" : "Pause")
                Button {
                    app.cancelTapped()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Cancel — nothing is deleted")
            }
        }
        .padding(.horizontal, 16)
    }

    private var statusWord: String {
        switch vm.phase {
        case .scanning: "scanning card"
        case .waitingForNAS: "waiting for NAS"
        case .pausedByUser: "paused"
        case .pausedCardGone: "card removed"
        case .wiping: "wiping card"
        case .ejecting: "ejecting"
        default:
            // Name the phase the user is actually in. The card read (hop1)
            // finishes well before the NAS upload (hop2); once it's done the
            // work is uploading, then verifying — never "complete" mid-transfer.
            if vm.hop1Fraction < 1 { "copying from card" }
            else if vm.hop2Fraction < 1 { "uploading to NAS" }
            else { "verifying on NAS" }
        }
    }

    private func etaLine(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 5) {
            Text(label)
            Text(value ?? "estimating…")
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary)
        }
        .font(.system(size: 14, weight: .semibold))
    }
}
