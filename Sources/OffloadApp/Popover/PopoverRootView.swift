import SwiftUI

struct PopoverRootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let detection = app.cardDetection {
                    CardDetectedView(state: detection)
                } else if let vm = app.session {
                    switch vm.phase {
                    case .done:
                        DoneView(vm: vm)
                    case .failed, .doneWipeBlocked:
                        AttentionView(vm: vm)
                    case .wipeCountdown, .awaitingWipeConsent:
                        WipePromptView(vm: vm)
                    case .cancelled, .idle:
                        IdleView()
                    case .scanning:
                        PreparationView(vm: vm)
                    default:
                        ActiveSessionView(vm: vm)
                    }
                } else if let card = app.pendingConsent {
                    ConsentView(card: card)
                } else {
                    IdleView()
                }
            }
            Divider()
            FooterView()
        }
        .frame(width: 360)
        .onAppear { app.popoverVisible = true }
        .onDisappear { app.popoverVisible = false }
    }
}
