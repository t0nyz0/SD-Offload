import AppKit
import SwiftUI
import Observation

/// The AppKit surface AppState talks to when it needs a window shown. AppState holds
/// a weak reference (`router`) so the engine can pop the tray or reveal a folder
/// without importing any AppKit view code. Implemented by `WindowCoordinator`.
@MainActor
protocol WindowRouting: AnyObject {
    /// Show/focus the menu-bar popover (the "tray window"). Used on card insert.
    func showPopover()
    func closePopover()
    /// Open (or focus) the Library window; if `folder` is non-nil the Library jumps
    /// to that absolute NAS path once on screen.
    func openLibrary(folder: String?)
    /// Open (or focus) the History window; if `id` is non-nil it selects that session.
    func openHistory(selecting id: UUID?)
    func openSettings()
}

/// Owns the menu-bar item (NSStatusItem + NSPopover) and the Library/History windows.
///
/// We drive the menu bar with AppKit rather than SwiftUI's `MenuBarExtra` because
/// MenuBarExtra offers no API to open its window in code — and we want a card insert
/// to pop the tray open on its own. The label mirrors `AppState.menuBar` (the same
/// `MenuBarState` the old SwiftUI label used) via a re-arming Observation tracker.
@MainActor
final class WindowCoordinator: NSObject, WindowRouting, NSWindowDelegate {
    private let app: AppState
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    // Recreated per open, released on close (see windowWillClose).
    private var libraryWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?

    init(app: AppState) {
        self.app = app
        super.init()
    }

    // MARK: - Status item + popover

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageOnly
        }

        let host = NSHostingController(rootView: PopoverRootView().environment(app))
        host.sizingOptions = .preferredContentSize          // popover sizes to the SwiftUI content
        popover.contentViewController = host
        popover.behavior = .transient                        // click-away / Esc closes it

        armLabel()
    }

    @objc private func toggle() {
        popover.isShown ? closePopover() : presentPopover()
    }

    /// Auto-present on card insert (called by AppState). Always shows the tray
    /// popover — even when the Library window is open, presentPopover() forces it
    /// above that window so it isn't hidden behind it. (The Library ALSO shows its
    /// own inline "card ready" banner, so the prompt is reachable either way.)
    func showPopover() {
        presentPopover()
    }

    /// Show the popover anchored to the status item, then force its window above any
    /// open key window (e.g. the Library) and give it focus. A transient popover
    /// shown while another window is key can otherwise land behind that window or be
    /// dismissed before it's seen — raising the level + orderFrontRegardless fixes it.
    private func presentPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)              // LSUIElement apps must grab focus first
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if let pw = popover.contentViewController?.view.window {
            pw.level = .floating                             // above the Library's .normal window
            pw.orderFrontRegardless()
            pw.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    // MARK: - Menu-bar label (mirrors MenuBarState)

    /// Renders the current `MenuBarState`, then re-arms Observation so the next
    /// mutation of `app.menuBar` re-renders. `withObservationTracking` is one-shot,
    /// so we simply re-arm inside the change handler.
    private func armLabel() {
        withObservationTracking {
            render(app.menuBar)
        } onChange: { [weak self] in
            Task { @MainActor in self?.armLabel() }
        }
    }

    private func render(_ state: MenuBarState) {
        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: state.symbolName,
                            accessibilityDescription: state.accessibilityText)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true                             // tint follows the menu bar (light/dark)
        button.image = image
        button.alphaValue = state.isIdle ? 0.45 : 1.0        // greyed while waiting

        if let pct = state.percent {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.attributedTitle = NSAttributedString(
                string: " " + MenuBarState.percentText(pct),   // figure-space padded → no jitter
                attributes: [.font: font]
            )
            button.imagePosition = .imageLeading
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
        }
        button.toolTip = state.accessibilityText
    }

    // MARK: - Library / History windows

    func openLibrary(folder: String?) {
        app.pendingLibraryFolder = folder                    // consumed by LibraryWindow (.onChange/.onAppear)
        closePopover()
        if let window = libraryWindow {
            Activate.front()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            title: "Library",
            size: NSSize(width: 920, height: 620),
            autosaveName: "OffloadLibraryWindow",
            content: LibraryWindow().environment(app)
        )
        libraryWindow = window
        DockPresence.windowOpened()
        Activate.front()
        window.makeKeyAndOrderFront(nil)
    }

    func openHistory(selecting id: UUID?) {
        if let id { app.pendingHistorySelection = id }        // consumed by HistoryWindow (.onChange/.task)
        closePopover()
        if let window = historyWindow {
            Activate.front()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            title: "SD Offload History",
            size: NSSize(width: 760, height: 500),
            autosaveName: "OffloadHistoryWindow",
            content: HistoryWindow().environment(app)
        )
        historyWindow = window
        DockPresence.windowOpened()
        Activate.front()
        window.makeKeyAndOrderFront(nil)
    }

    func openSettings() {
        // Own the Settings window in AppKit too, rather than routing through the
        // private `showSettingsWindow:` selector — that selector walks the responder
        // chain, which has no key window in an accessory app's status-item context,
        // so `NSApp.sendAction` found no target and nothing opened. Same makeWindow
        // path as Library/History, so it's deterministic.
        closePopover()
        if let window = settingsWindow {
            Activate.front()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeWindow(
            title: "SD Offload Settings",
            size: NSSize(width: 760, height: 580),
            autosaveName: "OffloadSettingsWindow",
            content: SettingsView().environment(app)
        )
        settingsWindow = window
        DockPresence.windowOpened()
        Activate.front()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        autosaveName: String,
        content: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false                  // we manage lifetime; release in windowWillClose
        window.delegate = self
        window.setContentSize(size)
        window.setFrameAutosaveName(autosaveName)            // restores position/size across launches
        if window.frame.origin == .zero { window.center() }
        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === libraryWindow {
            libraryWindow = nil
            DockPresence.windowClosed()
        } else if window === historyWindow {
            historyWindow = nil
            DockPresence.windowClosed()
        } else if window === settingsWindow {
            settingsWindow = nil
            DockPresence.windowClosed()
        }
    }
}
