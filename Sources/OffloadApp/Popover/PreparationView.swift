import SwiftUI
import OffloadEngine

/// The file inventory has no known denominator. Show measured work and the
/// current step, rather than a frozen copy percentage or invented ETA.
struct PreparationPresentation {
    let progress: PreparationProgress

    var step: Int {
        switch progress.stage {
        case .findingFiles: 1
        case .readingDates, .matchingSavedProgress: 2
        case .checkingNAS, .checkingSavedCopies, .startingTransfer: 3
        }
    }
    var title: String {
        switch progress.stage {
        case .findingFiles: "Finding files"
        case .readingDates: "Reading photo dates"
        case .matchingSavedProgress: "Checking saved progress"
        case .checkingNAS: "Connecting to NAS"
        case .checkingSavedCopies: "Making room on your Mac"
        case .startingTransfer: "Preparing to copy"
        }
    }
    var explanation: String {
        switch progress.stage {
        case .findingFiles: "Building the file list before copying."
        case .readingDates: "Choosing date folders for your files."
        case .matchingSavedProgress: "Reusing verified work from the earlier transfer."
        case .checkingNAS: "Making sure the backup destination is available."
        case .checkingSavedCopies: "Your Mac needs more free space. Checking older backups before removing their local copies."
        case .startingTransfer: "Getting the transfer ready."
        }
    }
    var countText: String {
        let count = progress.filesFound
        return "\(count) file\(count == 1 ? "" : "s") found · \(Fmt.bytes(progress.bytesFound))"
    }
    var workText: String? {
        if let check = progress.savedCopyCheck {
            return "\(check.filesDone) / \(check.filesTotal) previous copies checked · \(Fmt.bytes(check.bytesDone)) read"
        }
        guard progress.itemsTotal > 0 else { return nil }
        let done = min(progress.itemsDone, progress.itemsTotal)
        return progress.stage == .readingDates
            ? "Dates read: \(done) / \(progress.itemsTotal)"
            : "Saved files checked: \(done) / \(progress.itemsTotal)"
    }
    var fraction: Double? {
        if let check = progress.savedCopyCheck { return check.fraction }
        guard progress.itemsTotal > 0 else { return nil }
        return min(1, Double(progress.itemsDone) / Double(progress.itemsTotal))
    }
    var waitMessage: String? {
        guard progress.secondsWithoutActivity >= 10 else { return nil }
        let target: String
        switch progress.stage {
        case .findingFiles, .readingDates: target = "card"
        case .checkingNAS, .checkingSavedCopies: target = "NAS"
        case .matchingSavedProgress, .startingTransfer: target = "preparation"
        }
        return "Waiting for \(target) response · \(Int(progress.secondsWithoutActivity))s since last update"
    }
    var waitHelp: String {
        switch progress.stage {
        case .findingFiles, .readingDates:
            "Check for a macOS access prompt and keep the card connected."
        case .checkingNAS, .checkingSavedCopies:
            "Check the NAS connection. Keep the card connected while preparation finishes."
        case .matchingSavedProgress, .startingTransfer:
            "Keep the card connected while preparation finishes."
        }
    }
}

struct PreparationView: View {
    var vm: SessionViewModel

    var body: some View {
        let p = PreparationPresentation(progress: vm.preparation)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(vm.cardTitle).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if vm.resumed {
                    Text("RECOVERED").font(.system(size: 8, weight: .bold))
                        .padding(4).background(Theme.accent.opacity(0.2), in: Capsule())
                        .help("Checking saved progress from an unfinished transfer before continuing.")
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 32)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Card detected").font(.system(size: 20, weight: .semibold))
                    Text(p.title)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Preparation in progress")
            }

            Text(p.countText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            VStack(alignment: .leading, spacing: 5) {
                Text(p.explanation).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let fraction = p.fraction { ProgressView(value: fraction).tint(Theme.accent) }
                if let work = p.workText { Text(work).monospacedDigit() }
                if let path = vm.preparation.currentPath {
                    Text(path).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                }
            }
            .font(.system(size: 11))

            if let wait = p.waitMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(wait, systemImage: "clock").foregroundStyle(.orange)
                    Text(p.waitHelp).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Keep your card connected")
                Spacer()
                Text("Elapsed \(Fmt.duration(vm.preparation.elapsed))").monospacedDigit()
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(16)
    }
}
