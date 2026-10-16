import Foundation

/// Kernel mount identity, independent of delayed DiskArbitration descriptions.
struct CardMountSnapshot: Equatable, Sendable {
    let device: String
    let path: String
    let mountID: String
    let capacityBytes: Int64
    let freeBytes: Int64

    init?(source: String, path: String, mountID: String, capacityBytes: Int64 = 0, freeBytes: Int64 = 0) {
        guard source.hasPrefix("/dev/"), !source.dropFirst(5).isEmpty,
              path.hasPrefix("/") else { return nil }
        self.device = String(source.dropFirst(5))
        self.path = path
        self.mountID = mountID
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device && lhs.path == rhs.path && lhs.mountID == rhs.mountID
    }

    func probeIdentity(uuid: String, mediaID: UInt64) -> CardProbeState.Identity {
        .init(uuid: uuid, path: path, mountID: "\(mountID):\(mediaID)")
    }
}
