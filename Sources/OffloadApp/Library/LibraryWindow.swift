import SwiftUI
import OffloadCore
import OffloadEngine

/// M5 delivers the full browser (thumbnail grid, date-folder navigation,
/// SD-card pane). This shell already shows the NAS at a glance.
struct LibraryWindow: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            let glance = app.nasGlance
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 28))
                    .foregroundStyle(glance.healthy ? Theme.safe : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(glance.mounted ? "NAS · Photos" : "NAS not mounted")
                        .font(.title3.bold())
                    if glance.mounted {
                        Text("\(Fmt.bytes(glance.freeBytes)) free of \(Fmt.bytes(glance.totalBytes))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Spacer()
            }
            .padding(16)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

            ContentUnavailableView("Library browser coming up",
                                   systemImage: "photo.on.rectangle.angled",
                                   description: Text("Browse the NAS by date, see photo counts, and peek at an inserted card — landing in this window shortly."))
            Spacer()
        }
        .padding(20)
        .onAppear { app.refreshNASGlance() }
    }
}
