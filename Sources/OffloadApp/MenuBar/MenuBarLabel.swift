import SwiftUI

struct MenuBarLabel: View {
    var app: AppState

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
    }
}
