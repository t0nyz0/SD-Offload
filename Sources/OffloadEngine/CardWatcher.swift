import Foundation
import DiskArbitration
import OffloadCore

/// Raw volume signals from DiskArbitration. Classification happens upstream
/// (EngineController + CardClassifier) where config is available.
public enum RawCardEvent: Sendable {
    case volumeMounted(CandidateVolume)
    case volumeUnmounted(volumeUUID: String, bsdName: String)
}

public struct CandidateVolume: Sendable {
    public let info: CardInfo
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isInternal: Bool
    public let isNetwork: Bool
}

/// DASession on a private serial queue. DiskAppeared replays existing disks at
/// registration (how a card already inserted at launch gets picked up);
/// DescriptionChanged on kDADiskDescriptionVolumePathKey is the mount signal.
/// Verified on this machine: the built-in reader enumerates as Protocol "USB",
/// so we never classify by protocol string — removable/ejectable + DCIM only.
public final class CardWatcher: @unchecked Sendable {
    private var daSession: DASession?
    private let daQueue = DispatchQueue(label: "offload.diskarb")
    private var continuation: AsyncStream<RawCardEvent>.Continuation!
    public let events: AsyncStream<RawCardEvent>

    /// bsdName → volumeUUID, for disappear lookup after the description is gone.
    /// Guarded by daQueue.
    private var knownVolumes: [String: String] = [:]

    public init() {
        var cont: AsyncStream<RawCardEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    public func start() {
        guard daSession == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        daSession = session
        DASessionSetDispatchQueue(session, daQueue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // Matching dicts deliberately nil: hdiutil test disks may report
        // MediaRemovable=false and the built-in reader shows Protocol=USB —
        // filter in Swift, not in the matcher.
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            Unmanaged<CardWatcher>.fromOpaque(ctx).takeUnretainedValue().diskAppeared(disk)
        }, ctx)

        let watchKeys = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watchKeys, { disk, _, ctx in
            guard let ctx else { return }
            Unmanaged<CardWatcher>.fromOpaque(ctx).takeUnretainedValue().diskDescriptionChanged(disk)
        }, ctx)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            Unmanaged<CardWatcher>.fromOpaque(ctx).takeUnretainedValue().diskDisappeared(disk)
        }, ctx)
    }

    // MARK: - Callbacks (on daQueue)

    private func diskAppeared(_ disk: DADisk) {
        // A disk that appears already mounted (e.g. card inserted before launch).
        handlePossibleMount(disk)
    }

    private func diskDescriptionChanged(_ disk: DADisk) {
        handlePossibleMount(disk)
    }

    private func diskDisappeared(_ disk: DADisk) {
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }
        if let uuid = knownVolumes.removeValue(forKey: bsdName) {
            continuation.yield(.volumeUnmounted(volumeUUID: uuid, bsdName: bsdName))
        }
    }

    private func handlePossibleMount(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return }
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }

        guard let pathURL = desc[kDADiskDescriptionVolumePathKey] as? URL else {
            // Path went away without a disappear (unmount but device present).
            if let uuid = knownVolumes.removeValue(forKey: bsdName) {
                continuation.yield(.volumeUnmounted(volumeUUID: uuid, bsdName: bsdName))
            }
            return
        }

        let name = desc[kDADiskDescriptionVolumeNameKey] as? String ?? "Untitled"
        let removable = (desc[kDADiskDescriptionMediaRemovableKey] as? Bool) ?? false
        let ejectable = (desc[kDADiskDescriptionMediaEjectableKey] as? Bool) ?? false
        let internalDevice = (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? false
        let network = (desc[kDADiskDescriptionVolumeNetworkKey] as? Bool) ?? false
        let mediaSize = (desc[kDADiskDescriptionMediaSizeKey] as? Int64) ?? 0

        let uuid: String
        if let cfUUID = desc[kDADiskDescriptionVolumeUUIDKey] {
            // swiftlint:disable:next force_cast
            uuid = CFUUIDCreateString(kCFAllocatorDefault, (cfUUID as! CFUUID)) as String
        } else {
            // Some FAT32 cards surface no UUID — synthesize a stable identity.
            uuid = "\(name)#\(mediaSize)"
        }

        let alreadyKnown = knownVolumes[bsdName] == uuid
        knownVolumes[bsdName] = uuid
        guard !alreadyKnown else { return }   // duplicate signal for the same mount

        // Never block the DA queue on filesystem access — inspect in a Task.
        let continuation = self.continuation!
        Task.detached(priority: .utility) {
            let mountPath = pathURL.path
            var isDir: ObjCBool = false
            let hasDCIM = FileManager.default.fileExists(atPath: mountPath + "/DCIM", isDirectory: &isDir) && isDir.boolValue
            let fs = statfsInfo(path: mountPath)
            let info = CardInfo(volumeUUID: uuid, bsdName: bsdName, mountPath: mountPath,
                                volumeName: name,
                                capacityBytes: fs?.totalBytes ?? mediaSize,
                                freeBytes: fs?.freeBytes ?? 0,
                                hasDCIM: hasDCIM)
            continuation.yield(.volumeMounted(CandidateVolume(
                info: info, isRemovable: removable, isEjectable: ejectable,
                isInternal: internalDevice, isNetwork: network)))
        }
    }

    // MARK: - Eject

    public enum EjectError: Error, CustomStringConvertible {
        case notRunning
        case dissented(stage: String, status: Int32, hint: String?)
        public var description: String {
            switch self {
            case .notRunning: return "disk watcher not running"
            case .dissented(let stage, let status, let hint):
                return "\(stage) refused (status \(status))\(hint.map { ": \($0)" } ?? "")"
            }
        }
    }

    private final class ContinuationBox {
        let continuation: CheckedContinuation<Void, Error>
        let stage: String
        init(_ continuation: CheckedContinuation<Void, Error>, stage: String) {
            self.continuation = continuation
            self.stage = stage
        }
    }

    /// Unmount the volume, then eject the whole disk. Called by the Wiper after
    /// a verified wipe, and by the manual Eject button.
    public func unmountAndEject(bsdName: String) async throws {
        guard let daSession else { throw EjectError.notRunning }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, daSession, bsdName) else {
            throw EjectError.notRunning
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = Unmanaged.passRetained(ContinuationBox(cont, stage: "Unmount"))
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { _, dissenter, ctx in
                let box = Unmanaged<ContinuationBox>.fromOpaque(ctx!).takeRetainedValue()
                if let dissenter {
                    let status = DADissenterGetStatus(dissenter)
                    let hint = DADissenterGetStatusString(dissenter) as String?
                    box.continuation.resume(throwing: EjectError.dissented(stage: box.stage, status: status, hint: hint))
                } else {
                    box.continuation.resume()
                }
            }, box.toOpaque())
        }

        guard let whole = DADiskCopyWholeDisk(disk) else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = Unmanaged.passRetained(ContinuationBox(cont, stage: "Eject"))
            DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, ctx in
                let box = Unmanaged<ContinuationBox>.fromOpaque(ctx!).takeRetainedValue()
                if let dissenter {
                    let status = DADissenterGetStatus(dissenter)
                    let hint = DADissenterGetStatusString(dissenter) as String?
                    box.continuation.resume(throwing: EjectError.dissented(stage: box.stage, status: status, hint: hint))
                } else {
                    box.continuation.resume()
                }
            }, box.toOpaque())
        }
    }
}
