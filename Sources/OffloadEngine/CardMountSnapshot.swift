import Foundation

/// Kernel mount identity, independent of delayed DiskArbitration descriptions.
struct CardMountSnapshot: Equatable, Sendable {
    let device: String
    let path: String
    let mountID: String

    init?(source: String, path: String, mountID: String) {
        guard source.hasPrefix("/dev/"), !source.dropFirst(5).isEmpty,
              path.hasPrefix("/") else { return nil }
        self.device = String(source.dropFirst(5))
        self.path = path
        self.mountID = mountID
    }
}
