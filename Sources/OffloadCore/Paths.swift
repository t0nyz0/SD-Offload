import Foundation

public enum Paths {
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Offload", isDirectory: true)
    }

    public static var configFile: URL { appSupport.appendingPathComponent("config.json") }
    public static var journalDir: URL { appSupport.appendingPathComponent("Journal", isDirectory: true) }
    public static var historyDir: URL { appSupport.appendingPathComponent("History", isDirectory: true) }
    public static var stagingRoot: URL { appSupport.appendingPathComponent("Staging", isDirectory: true) }
    public static var libraryIndexFile: URL { appSupport.appendingPathComponent("library-index.json") }

    /// Hidden marker file written to a card to tie it to a session (per-card
    /// identity that survives synthesized-UUID collisions). Hidden, so the
    /// scanner skips it and it is never ingested or wiped as content.
    public static let cardSessionMarkerName = ".offload-session"

    public static func ensureAll() {
        for dir in [appSupport, journalDir, historyDir, stagingRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
