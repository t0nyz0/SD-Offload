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

    public static func ensureAll() {
        for dir in [appSupport, journalDir, historyDir, stagingRoot] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
