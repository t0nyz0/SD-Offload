import SwiftUI
import AppKit
import OffloadCore
import OffloadEngine

enum WindowID {
    static let history = "history"
    static let library = "library"
}

enum Activate {
    /// LSUIElement apps must explicitly grab focus before showing a window.
    static func front() {
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Makes bare `swift run` behave like the LSUIElement bundle: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            NotificationManager.shared.install()
        }
    }
}

@main
struct OffloadMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        // Declared first so nothing auto-opens at launch.
        MenuBarExtra {
            PopoverRootView()
                .environment(app)
        } label: {
            MenuBarLabel(app: app)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(app)
        }

        Window("SD Offload History", id: WindowID.history) {
            HistoryWindow()
                .environment(app)
        }
        .defaultSize(width: 760, height: 500)

        Window("Library", id: WindowID.library) {
            LibraryWindow()
                .environment(app)
        }
        .defaultSize(width: 920, height: 620)
    }
}
