import Foundation

/// Enqueue synchronously at the mutation site, then serialize I/O off the UI thread.
/// The newest failed operation per file remains retryable; stale retries cannot
/// overwrite a later snapshot or resurrect an invalidated cache.
public final class OrderedJSONWriter: @unchecked Sendable {
    public static let shared = OrderedJSONWriter()
    private let queue = DispatchQueue(label: "offload.metadata-writer", qos: .utility)
    private var pending: [URL: () throws -> Void] = [:]
    private var retryScheduled = false
    public init() {}

    public func save<T: Encodable & Sendable>(_ value: T, to url: URL,
                                              onError: (@Sendable (String) -> Void)? = nil) {
        enqueue(url: url, operation: { try JSONIO.save(value, to: url) }, onError: onError)
    }
    public func remove(_ url: URL) {
        enqueue(url: url, operation: {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }, onError: nil)
    }
    private func enqueue(url: URL, operation: @escaping () throws -> Void,
                         onError: (@Sendable (String) -> Void)?) {
        queue.async {
            self.pending[url] = operation
            do { try operation(); self.pending[url] = nil }
            catch { onError?(error.localizedDescription); self.scheduleRetry() }
        }
    }
    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.retryPending()
            if !self.pending.isEmpty { self.scheduleRetry() }
        }
    }
    private func retryPending() {
        for (url, operation) in pending {
            do { try operation(); pending[url] = nil } catch { }
        }
    }
    /// Wait for queued saves and retry pending writes. Call off-main if the UI is active.
    @discardableResult public func flush() -> Bool {
        queue.sync { retryPending(); return pending.isEmpty }
    }
}
