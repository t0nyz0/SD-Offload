import Foundation

/// Network filesystems may not implement Darwin's exclusive rename extension.
/// Write through O_EXCL instead; the journal and full read-back verification,
/// rather than the presence of a filename, determine whether a copy is safe.
enum DestinationWriter {
    static func requiresExclusiveCreate(at root: URL) -> Bool {
        usesExclusiveCreate(fileSystem: statfsInfo(path: root.path)?.fsTypeName ?? "unknown")
    }
    static func usesExclusiveCreate(fileSystem: String) -> Bool {
        !["apfs", "hfs", "exfat", "msdos"].contains(fileSystem)
    }
}
