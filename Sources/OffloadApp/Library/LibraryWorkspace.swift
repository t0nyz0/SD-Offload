import AppKit

/// LaunchServices can touch a file before handing it to Finder or another app.
/// Keep that work off the main thread and avoid queuing repeat clicks on a stalled volume.
@MainActor
enum LibraryWorkspace {
    private static let queue = DispatchQueue(label: "offload.library.workspace", qos: .userInitiated)
    private static var requestPending = false

    static func open(_ url: URL, onFailure: @escaping @MainActor () -> Void = { NSSound.beep() }) {
        request({ NSWorkspace.shared.open(url) }, onFailure: onFailure)
    }

    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        request({
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            return true
        }, onFailure: {})
    }

    private static func request(_ work: @escaping @Sendable () -> Bool,
                                onFailure: @escaping @MainActor () -> Void) {
        guard !requestPending else { NSSound.beep(); return }
        requestPending = true
        queue.async {
            let succeeded = work()
            Task { @MainActor in
                requestPending = false
                if !succeeded { onFailure() }
            }
        }
    }
}
