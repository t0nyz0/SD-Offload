import SwiftUI

struct MenuBarLabel: View {
    var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = app.menuBar
        HStack(spacing: 3) {
            Image(systemName: state.symbolName)
                .symbolRenderingMode(.hierarchical)
                .opacity(state.isIdle ? 0.45 : 1.0)
            if let pct = state.percent {
                Text(MenuBarState.percentText(pct))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(state.accessibilityText)
        // The label is the only view alive when no window is open, so it hosts the
        // programmatic Library-window open (macOS 14 can't open the popover this way).
        .onChange(of: app.libraryOpenToken) {
            Activate.front()
            openWindow(id: WindowID.library)
        }
    }
}
