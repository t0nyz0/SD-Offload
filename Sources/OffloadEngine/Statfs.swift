import Foundation

/// Thin statfs(2) wrapper — the identity primitive behind the ghost-mount
/// guard: if `/Volumes/Photos` unmounts and something recreates the path as a
/// plain folder, statfs reports the ROOT volume ("apfs", mounted on "/"),
/// which is how we refuse to write into a ghost.
public struct StatfsInfo: Sendable, Equatable {
    public let fsTypeName: String     // "smbfs", "apfs", "exfat", …
    public let mntFromName: String    // "//user@NAS._smb._tcp.local/Photos"
    public let mntOnName: String      // "/Volumes/Photos"
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let isReadOnly: Bool
}

public func statfsInfo(path: String) -> StatfsInfo? {
    var st = statfs()
    guard statfs(path, &st) == 0 else { return nil }

    func tupleToString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let data = raw.prefix(while: { $0 != 0 })
            return String(decoding: data, as: UTF8.self)
        }
    }

    let blockSize = Int64(st.f_bsize)
    return StatfsInfo(
        fsTypeName: tupleToString(st.f_fstypename),
        mntFromName: tupleToString(st.f_mntfromname),
        mntOnName: tupleToString(st.f_mntonname),
        totalBytes: Int64(st.f_blocks) * blockSize,
        freeBytes: Int64(st.f_bavail) * blockSize,
        isReadOnly: (st.f_flags & UInt32(MNT_RDONLY)) != 0
    )
}
