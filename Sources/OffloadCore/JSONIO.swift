import Foundation

/// House JSON persistence: pretty, sorted keys, ISO-8601, human-diffable.
/// `save` = atomic write + `.bak` refresh.
/// `saveDurable` = temp + fsync + rename + parent-dir fsync — journal-grade
/// durability; the wipe decision depends on the journal being on disk.
public enum JSONIO {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: url))
    }

    /// Load with `.bak` fallback. A good main load refreshes `.bak`; a corrupt
    /// main file is preserved as `.damaged` and the backup is used instead.
    public static func loadGuarded<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let bak = url.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: url) {
            if let value = try? decoder.decode(type, from: data) {
                try? data.write(to: bak, options: .atomic)
                return value
            }
            // Main file exists but is corrupt — keep the evidence.
            let damaged = url.appendingPathExtension("damaged")
            try? FileManager.default.removeItem(at: damaged)
            try? FileManager.default.moveItem(at: url, to: damaged)
        }
        if let data = try? Data(contentsOf: bak),
           let value = try? decoder.decode(type, from: data) {
            return value
        }
        return nil
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Lock a file down as owner-only (0600) and exclude it from Time Machine /
    /// cloud backups — for locally-stored sensitive data (e.g. face embeddings)
    /// that must never sync or restore off this Mac. Best-effort.
    public static func harden(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// Durable save: `Data.write(.atomic)` renames but does not fsync. This does.
    public static func saveDurable<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")

        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw OffloadError.posix(errno, stage: "journal write (open)") }
        defer { close(fd) }
        var written = 0
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            while written < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: written), buf.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw OffloadError.posix(errno, stage: "journal write")
                }
                written += n
            }
        }
        guard fsync(fd) == 0 else { throw OffloadError.posix(errno, stage: "journal fsync") }

        guard rename(tmp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw OffloadError.posix(errno, stage: "journal rename")
        }
        // fsync the parent directory so the rename itself is durable.
        let dfd = open(dir.path, O_RDONLY)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }
}
