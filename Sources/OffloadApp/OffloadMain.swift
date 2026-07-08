import SwiftUI
import AppKit
import OffloadCore
import OffloadEngine

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

// The app owns its menu-bar item with AppKit (NSStatusItem + NSPopover) rather than
// SwiftUI's MenuBarExtra, because MenuBarExtra has no API to open its window in code
// and we want inserting a card to pop the tray window open. AppState lives here (one
// instance) and is injected into the surviving Settings scene; the WindowCoordinator
// owns the status item, popover, and the Library/History AppKit windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppState()
    private var coordinator: WindowCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)          // menu-bar only; no Dock icon
        let coordinator = WindowCoordinator(app: app)
        self.coordinator = coordinator
        app.router = coordinator                         // set before any engine event is processed
        coordinator.installStatusItem()
        NotificationManager.shared.install()
    }

    // The status item keeps the process alive; closing the last aux window must not quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct OffloadMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Settings is the one window kept as a SwiftUI scene (opened from AppKit via
        // the standard showSettingsWindow: selector). The Library/History windows are
        // AppKit-managed by the WindowCoordinator, and the tray is an NSPopover.
        Settings {
            SettingsView()
                .environment(delegate.app)
        }
    }
}
