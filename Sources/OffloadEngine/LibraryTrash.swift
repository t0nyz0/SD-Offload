import Foundation
import Darwin

/// Recoverable Library deletion. SMB shares commonly have no macOS Trash;
/// keep those originals in a hidden folder on the same archive instead.
public enum LibraryTrash {
    public static let folderName = ".offload-trash"

    public struct Failure: Sendable {
        public let url: URL
        public let detail: String
    }

    public struct Result: Sendable {
        public var removed: Set<URL> = []
        public var recovered: Set<URL> = []
        public var failures: [Failure] = []
        public var recoveryFolder: URL?
    }

    public static func folder(under root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func move(_ targets: Set<URL>, archiveRoot: URL) async -> Result {
        // Network filesystem calls must not occupy the UI or cooperative pool.
        do {
            return try await ChunkedIO.blocking {
                perform(targets, archiveRoot: archiveRoot) { url in
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
        } catch {
            var result = Result()
            result.failures = targets.map { Failure(url: $0, detail: describe(error)) }
            return result
        }
    }

    public static func openRecoveryFolder(archiveRoot: URL) async throws -> URL {
        try await ChunkedIO.blocking { try prepareFolder(under: archiveRoot.resolvingSymlinksInPath()) }
    }

    static func perform(_ targets: Set<URL>, archiveRoot: URL,
                        nativeTrash: (URL) throws -> Void) -> Result {
        let fm = FileManager.default
        let root = archiveRoot.resolvingSymlinksInPath().standardizedFileURL
        let recovery = folder(under: root)
        var result = Result()
        var batch: URL?
        var unavailableTrash: NSError?
        for original in targets.sorted(by: { $0.path < $1.path }) {
            let source = original.resolvingSymlinksInPath().standardizedFileURL
            do {
                // Only regular archive files may be deleted. Never follow a
                // symlink to another volume or sweep the recovery folder itself.
                guard source.path.hasPrefix(root.path + "/"),
                      !source.path.hasPrefix(recovery.path + "/"), source != recovery else {
                    throw TrashError("File is outside the photo archive or inside Deleted Photos")
                }
                var info = stat()
                guard lstat(original.path, &info) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard info.st_mode & S_IFMT == S_IFREG else {
                    throw TrashError("Only regular photo files can be deleted")
                }
                do {
                    if let unavailableTrash { throw unavailableTrash }
                    try nativeTrash(original)
                    result.removed.insert(original)
                } catch {
                    let nativeError = describe(error)
                    let native = error as NSError
                    if native.domain == NSCocoaErrorDomain && native.code == CocoaError.featureUnsupported.rawValue {
                        unavailableTrash = native // One unsupported-volume probe per batch.
                    }
                    do {
                        if batch == nil {
                            let parent = try prepareFolder(under: root)
                            let candidate = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
                            // A private, exclusively-created batch prevents
                            // concurrent deletes or repeated names overwriting.
                            guard mkdir(candidate.path, 0o700) == 0 else {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                            let instructions = """
                            Deleted Photos — SD Offload

                            These files were moved here because macOS Trash was unavailable.
                            To restore a photo, move it from this folder back into the matching
                            year/month/day folder under:
                            \(root.path)

                            Original relative folder paths and filenames are preserved below.
                            Nothing here is automatically erased. Keep any existing destination
                            file when Finder reports a name conflict.
                            """
                            try Data(instructions.utf8).write(to: candidate.appendingPathComponent("Restore Instructions.txt"),
                                                              options: .withoutOverwriting)
                            batch = candidate
                        }
                        let relative = String(source.path.dropFirst(root.path.count + 1))
                        let destination = batch!.appendingPathComponent(relative, isDirectory: false)
                        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        guard !fm.fileExists(atPath: destination.path) else {
                            throw TrashError("A recovery file already exists; nothing was replaced")
                        }
                        // Plain rename works on SMB. Never use exclusive-rename
                        // extensions, copy large files, or unlink the source.
                        // EXDEV/permissions/locks fail with the original intact.
                        guard rename(original.path, destination.path) == 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        result.removed.insert(original)
                        result.recovered.insert(original)
                        result.recoveryFolder = recovery
                    } catch {
                        result.failures.append(Failure(url: original,
                            detail: "macOS Trash: \(nativeError). Deleted Photos: \(describe(error))"))
                    }
                }
            } catch {
                result.failures.append(Failure(url: original, detail: describe(error)))
            }
        }
        return result
    }

    private static func prepareFolder(under root: URL) throws -> URL {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw TrashError("The photo archive is unavailable")
        }
        let directory = folder(under: root)
        if mkdir(directory.path, 0o700) != 0 {
            let code = errno
            guard code == EEXIST, lstat(directory.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        return directory
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.localizedDescription) (\(error.domain) \(error.code))"
    }

    private struct TrashError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
