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

/// A menu-bar (accessory) app has no Dock icon and can't be reached via ⌘-Tab —
/// which makes the Library/History windows hard to switch back to. While one of
/// them is open we switch to a regular app (Dock icon + app-switcher entry), then
/// back to accessory once the last window closes. The counter keeps it correct when
/// both windows are open at once.
@MainActor
enum DockPresence {
    private static var openCount = 0
    static func windowOpened() { openCount += 1; reconcile() }
    static func windowClosed() { openCount = max(0, openCount - 1); reconcile() }
    private static func reconcile() {
        let policy: NSApplication.ActivationPolicy = openCount > 0 ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
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
                .onAppear { DockPresence.windowOpened() }
                .onDisappear { DockPresence.windowClosed() }
        }
        .defaultSize(width: 760, height: 500)

        Window("Library", id: WindowID.library) {
            LibraryWindow()
                .environment(app)
                .onAppear { DockPresence.windowOpened() }
                .onDisappear { DockPresence.windowClosed() }
        }
        .defaultSize(width: 920, height: 620)
    }
}
