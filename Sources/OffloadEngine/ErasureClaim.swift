import Foundation
import OffloadCore

/// A recovery name on filesystems with exclusive rename, or a freshly created
/// private directory on filesystems (including FSKit exFAT) without it.
struct ErasureClaim: Sendable {
    let directory: Int32
    let name: String
    let container: String?

    var relativePath: String { container.map { $0 + "/" + name } ?? name }

    func closeDirectory() { if container != nil { close(directory) } }

    func removeEmptyContainer(parent: Int32) {
        if let container { _ = unlinkat(parent, container, AT_REMOVEDIR) }
    }

    static func acquire(parent: Int32, name: String, recovery: String,
                        exclusiveRename: Wiper.ExclusiveRename) throws -> ErasureClaim? {
        let code = exclusiveRename(parent, name, parent, recovery)
        if code == 0 { return ErasureClaim(directory: parent, name: recovery, container: nil) }
        if code == ENOENT { return nil }
        guard code == ENOTSUP || code == ENOSYS else {
            throw OffloadError.posix(code, stage: "claim source for erasure")
        }

        // mkdir is exclusive: an existing recovery file/directory is never used
        // or replaced. The rename target is inside this newly owned namespace.
        guard mkdirat(parent, recovery, 0o700) == 0 else {
            throw OffloadError.posix(errno, stage: "create erasure recovery directory")
        }
        let fd = openat(parent, recovery, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            let error = errno; _ = unlinkat(parent, recovery, AT_REMOVEDIR)
            throw OffloadError.posix(error, stage: "open erasure recovery directory")
        }
        var owned = stat(), named = stat(), target = stat()
        guard fstat(fd, &owned) == 0,
              fstatat(parent, recovery, &named, AT_SYMLINK_NOFOLLOW) == 0,
              owned.st_dev == named.st_dev, owned.st_ino == named.st_ino,
              fstatat(fd, "source", &target, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
            close(fd)
            throw OffloadError(.internalError("Recovery directory changed; card files were preserved."))
        }
        if renameat(parent, name, fd, "source") != 0 {
            let error = errno; close(fd); _ = unlinkat(parent, recovery, AT_REMOVEDIR)
            if error == ENOENT { return nil }
            throw OffloadError.posix(error, stage: "claim source in recovery directory")
        }
        return ErasureClaim(directory: fd, name: "source", container: recovery)
    }

    static func find(parent: Int32, recovery: String) throws -> ErasureClaim? {
        var st = stat()
        if fstatat(parent, recovery, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw OffloadError.posix(errno, stage: "inspect interrupted erasure")
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return ErasureClaim(directory: parent, name: recovery, container: nil)
        }
        let fd = openat(parent, recovery, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw OffloadError.posix(errno, stage: "open interrupted erasure") }
        if fstatat(fd, "source", &st, AT_SYMLINK_NOFOLLOW) != 0 {
            let error = errno; close(fd)
            if error == ENOENT && unlinkat(parent, recovery, AT_REMOVEDIR) == 0 { return nil }
            throw OffloadError.posix(error, stage: "inspect recovery directory contents")
        }
        return ErasureClaim(directory: fd, name: "source", container: recovery)
    }
}
