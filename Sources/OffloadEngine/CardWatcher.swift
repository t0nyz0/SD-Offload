import Foundation
import DiskArbitration
import AppKit
import IOKit
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
    public let isDiskImage: Bool

    public init(info: CardInfo, isRemovable: Bool, isEjectable: Bool,
                isInternal: Bool, isNetwork: Bool, isDiskImage: Bool = false) {
        self.info = info
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isNetwork = isNetwork
        self.isDiskImage = isDiskImage
    }
}

/// DASession on a private serial queue. DiskAppeared replays existing disks at
/// registration (how a card already inserted at launch gets picked up);
/// DescriptionChanged on kDADiskDescriptionVolumePathKey is the mount signal.
/// Verified on this machine: the built-in reader enumerates as Protocol "USB",
/// so USB is never excluded by protocol. Disk images are identified separately:
/// simulator runtimes also report removable/ejectable but must not raise the tray.
public final class CardWatcher: @unchecked Sendable {
    private var daSession: DASession?
    private let daQueue = DispatchQueue(label: "offload.diskarb")
    private var continuation: AsyncStream<RawCardEvent>.Continuation!
    public let events: AsyncStream<RawCardEvent>

    /// bsdName → volumeUUID, for disappear lookup after the description is gone.
    /// Guarded by daQueue.
    private var probes = CardProbeState()

    /// Debounce for the DescriptionChanged path-nil branch. An exFAT/FSKit volume
    /// can momentarily drop kDADiskDescriptionVolumePathKey and get it back (a
    /// "flap"), which otherwise looks like unmount→remount and makes the app
    /// re-scan a card that never actually left. We defer treating a path loss as an
    /// unmount; if the path returns first (handlePossibleMount) or the device is
    /// really removed (diskDisappeared), the pending timer is cancelled. Guarded by
    /// daQueue. The work item does NO filesystem access — it must not block daQueue.
    private var pendingUnmounts: [String: DispatchWorkItem] = [:]
    private let pathFlapGrace: DispatchTimeInterval = .milliseconds(750)

    /// Ground-truth reconciliation. DiskArbitration's event stream can miss a card's
    /// removal (a busy volume held open by the Library; a reader that keeps its disk
    /// object across card swaps), leaving insertion state stale so a genuine re-insert is
    /// mistaken for a duplicate and swallowed. A low-rate poll compares insertion state
    /// against the live kernel mount table and emits the unmount the event stream never
    /// delivered — so re-insertion re-detects on its own, no matter how the reader
    /// behaves. Guarded by daQueue (the timer fires there). `absentPolls` requires a
    /// volume to be gone for a few consecutive polls before we believe it, so a
    /// sub-second FSKit path-flap can't be mistaken for a real removal.
    private var reconcileTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var mountObservers: [NSObjectProtocol] = []
    private let onDetected: @Sendable (CardInfo) -> Void
    private let onProbeFinished: @Sendable (String, Bool) -> Void
    private let onRemoved: @Sendable (String) -> Void
    private var absentPolls: [String: Int] = [:]
    private let reconcileInterval: TimeInterval = 1.5
    private let absentPollsBeforeUnmount = 2          // ~3 s gone ⇒ real removal, not a flap

    public init(onDetected: @escaping @Sendable (CardInfo) -> Void = { _ in },
                onProbeFinished: @escaping @Sendable (String, Bool) -> Void = { _, _ in },
                onRemoved: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onDetected = onDetected
        self.onProbeFinished = onProbeFinished
        self.onRemoved = onRemoved
        var cont: AsyncStream<RawCardEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    static func isMounted(_ card: CardInfo) -> Bool {
        mountedVolumes()[card.bsdName]?.path == card.mountPath
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

        let watchKeys = [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeUUIDKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(session, nil, watchKeys, { disk, _, ctx in
            guard let ctx else { return }
            Unmanaged<CardWatcher>.fromOpaque(ctx).takeUnretainedValue().diskDescriptionChanged(disk)
        }, ctx)

        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            Unmanaged<CardWatcher>.fromOpaque(ctx).takeUnretainedValue().diskDisappeared(disk)
        }, ctx)

        // Self-healing backstop for removals the callbacks above never deliver.
        let timer = DispatchSource.makeTimerSource(queue: daQueue)
        timer.schedule(deadline: .now() + reconcileInterval, repeating: reconcileInterval)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        reconcileTimer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.daQueue.async { [weak self] in self?.reconcile() }
        }
        let center = NSWorkspace.shared.notificationCenter
        mountObservers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] _ in
            self?.daQueue.async { [weak self] in self?.reconcile() }
        })
        mountObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] note in
            guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path else { return }
            self?.daQueue.async { [weak self] in
                guard let self else { return }
                for removed in self.probes.remove(path: path) {
                    self.pendingUnmounts.removeValue(forKey: removed.device)?.cancel()
                    self.absentPolls.removeValue(forKey: removed.device)
                    self.onRemoved(removed.device)
                    if let uuid = removed.uuid {
                        self.continuation.yield(.volumeUnmounted(volumeUUID: uuid, bsdName: removed.device))
                    }
                }
            }
        })
    }

    /// Force a re-check of every currently-mounted volume, dropping the dedup state
    /// that normally suppresses repeat signals. The recovery path when a genuine
    /// re-insert was mistaken for a flap (or its unmount event never landed) and
    /// swallowed — e.g. the card sat busy in the Library while it was pulled and put
    /// back. Runs on daQueue like the real callbacks, so it's safe with insertion state.
    public func rescan() {
        daQueue.async { [weak self] in
            guard let self, let session = self.daSession else { return }
            self.pendingUnmounts.values.forEach { $0.cancel() }
            self.pendingUnmounts.removeAll()
            self.probes.reset()                     // forget dedup so every mount re-emits
            self.absentPolls.removeAll()
            for bsdName in Self.mountedVolumes().keys {
                if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
                    self.handlePossibleMount(disk)
                }
            }
        }
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
        pendingUnmounts.removeValue(forKey: bsdName)?.cancel()   // real removal supersedes a pending flap
        absentPolls.removeValue(forKey: bsdName)
        onRemoved(bsdName)
        if let uuid = probes.remove(device: bsdName) {
            continuation.yield(.volumeUnmounted(volumeUUID: uuid, bsdName: bsdName))
        }
    }

    /// Poll the live mount table (ground truth) and emit the unmount for any volume we
    /// still think is mounted but that has actually gone — the self-heal for a removal
    /// event the callbacks never delivered. Only after `absentPollsBeforeUnmount`
    /// consecutive misses, so a sub-second FSKit path-flap isn't mistaken for removal.
    private func reconcile() {
        guard let session = daSession else { return }
        let mounted = Self.mountedVolumes()
        // Reconcile BOTH directions: a missed insertion must be discovered even
        // when we currently know about no cards at all.
        for bsdName in probes.devices where mounted[bsdName] == nil {
            let misses = (absentPolls[bsdName] ?? 0) + 1
            absentPolls[bsdName] = misses
            guard misses >= absentPollsBeforeUnmount else { continue }
            absentPolls.removeValue(forKey: bsdName)
            pendingUnmounts.removeValue(forKey: bsdName)?.cancel()
            onRemoved(bsdName)
            if let uuid = probes.remove(device: bsdName) {
                continuation.yield(.volumeUnmounted(volumeUUID: uuid, bsdName: bsdName))
            }
        }
        for bsdName in mounted.keys {
            absentPolls.removeValue(forKey: bsdName)
            if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) {
                handlePossibleMount(disk)
            }
        }
    }

    /// BSD names ("disk4s1") of every currently-mounted LOCAL volume, read straight
    /// from the kernel mount table. Network mounts (f_mntfromname like
    /// "//user@host/share", no "/dev/" prefix) are skipped — they're never cards.
    /// MNT_NOWAIT reads cached kernel metadata without asking a slow device to
    /// respond. Never call statfs(path) on the DiskArbitration event queue.
    private static func mountedVolumes() -> [String: CardMountSnapshot] {
        var out: [String: CardMountSnapshot] = [:]
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let buf else { return out }
        for i in 0..<Int(count) {
            var fs = buf[i]
            let from = withUnsafePointer(to: &fs.f_mntfromname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            let path = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
            }
            if let mount = CardMountSnapshot(source: from, path: path,
                                             mountID: "\(fs.f_fsid.val.0):\(fs.f_fsid.val.1)",
                                             capacityBytes: Int64(fs.f_blocks) * Int64(fs.f_bsize),
                                             freeBytes: Int64(fs.f_bavail) * Int64(fs.f_bsize)) {
                out[mount.device] = mount
            }
        }
        return out
    }

    private func handlePossibleMount(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [CFString: Any] else { return }
        guard let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }) else { return }

        guard let mountedVolume = Self.mountedVolumes()[bsdName] else {
            // No kernel mount remains, even if DiskArbitration still reports a
            // path. Confirm after a short
            // grace period. A real removal arrives via diskDisappeared (which
            // cancels this); if the path returns first, the follow-up
            // handlePossibleMount cancels this timer. (insertion state is cleared only
            // inside the work item, so a returning path still hits the alreadyKnown
            // dedup below and no phantom remount is emitted.)
            guard probes.devices.contains(bsdName), pendingUnmounts[bsdName] == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingUnmounts.removeValue(forKey: bsdName)
                guard Self.mountedVolumes()[bsdName] == nil else { return }
                self.onRemoved(bsdName)
                guard let uuid = self.probes.remove(device: bsdName) else { return }
                self.continuation.yield(.volumeUnmounted(volumeUUID: uuid, bsdName: bsdName))
            }
            pendingUnmounts[bsdName] = item
            daQueue.asyncAfter(deadline: .now() + pathFlapGrace, execute: item)
            return
        }

        let pathURL = URL(fileURLWithPath: mountedVolume.path, isDirectory: true)
        let name = desc[kDADiskDescriptionVolumeNameKey] as? String ?? "Untitled"
        let removable = (desc[kDADiskDescriptionMediaRemovableKey] as? Bool) ?? false
        let ejectable = (desc[kDADiskDescriptionMediaEjectableKey] as? Bool) ?? false
        let internalDevice = (desc[kDADiskDescriptionDeviceInternalKey] as? Bool) ?? false
        let network = (desc[kDADiskDescriptionVolumeNetworkKey] as? Bool) ?? false
        let isDiskImage = CardClassifier.isDiskImage(
            deviceProtocol: desc[kDADiskDescriptionDeviceProtocolKey] as? String,
            deviceModel: desc[kDADiskDescriptionDeviceModelKey] as? String)
        // Never inspect network shares or fixed internal disks for camera media.
        guard !network, removable || ejectable || !internalDevice else { return }
        let mediaSize = (desc[kDADiskDescriptionMediaSizeKey] as? Int64) ?? 0

        let uuid: String
        if let cfUUID = desc[kDADiskDescriptionVolumeUUIDKey] {
            // swiftlint:disable:next force_cast
            uuid = CFUUIDCreateString(kCFAllocatorDefault, (cfUUID as! CFUUID)) as String
        } else {
            // Some FAT32 cards surface no UUID — synthesize a stable identity.
            uuid = "\(name)#\(mediaSize)"
        }

        pendingUnmounts.removeValue(forKey: bsdName)?.cancel()   // path is back — cancel any pending flap unmount
        absentPolls.removeValue(forKey: bsdName)
        // A reader can reuse BSD name, UUID and filesystem ID after a card swap.
        // IOMedia's registry generation still distinguishes a new physical media object.
        var mediaID: UInt64 = 0
        let media = DADiskCopyIOMedia(disk)
        if media != 0 {
            _ = IORegistryEntryGetRegistryEntryID(media, &mediaID)
            IOObjectRelease(media)
        }
        let identity = mountedVolume.probeIdentity(uuid: uuid, mediaID: mediaID)
        let observation = probes.begin(device: bsdName, identity: identity)
        if let removed = observation.removed {
            continuation.yield(.volumeUnmounted(volumeUUID: removed, bsdName: bsdName))
        }
        guard let probe = observation.probe else { return }
        if observation.detected && !isDiskImage {
            // Acknowledge the mounted device before any potentially blocking
            // filesystem/media-root probe. This bypasses the coordinator backlog.
            onDetected(CardInfo(volumeUUID: uuid, bsdName: bsdName, mountPath: pathURL.path,
                volumeName: name, capacityBytes: mountedVolume.capacityBytes > 0 ? mountedVolume.capacityBytes : mediaSize,
                freeBytes: mountedVolume.freeBytes, hasMediaRoot: false))
        }

        // Probe off the event queue. Completion is serialized and generation-
        // checked, so a removed/replaced card cannot reappear from stale work.
        Task.detached(priority: .userInitiated) { [weak self] in
            let mountPath = pathURL.path
            // A camera card if it carries ANY known media root (not just DCIM —
            // some bodies use PRIVATE/AVCHD/CLIP/MP_ROOT).
            let hasMediaRoot = (try? await ChunkedIO.blocking {
                IngestPlanner.mediaRoots.contains { root in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: mountPath + "/" + root, isDirectory: &isDir) && isDir.boolValue
                }
            }) ?? false
            let info = CardInfo(volumeUUID: uuid, bsdName: bsdName, mountPath: mountPath,
                                volumeName: name,
                                capacityBytes: mountedVolume.capacityBytes > 0 ? mountedVolume.capacityBytes : mediaSize,
                                freeBytes: mountedVolume.freeBytes,
                                hasMediaRoot: hasMediaRoot)
            let candidate = CandidateVolume(info: info, isRemovable: removable,
                                            isEjectable: ejectable, isInternal: internalDevice,
                                            isNetwork: network, isDiskImage: isDiskImage)
            self?.daQueue.async { [weak self] in
                guard let self else { return }
                let stillMounted = Self.mountedVolumes()[bsdName] == mountedVolume
                let current = self.probes.isCurrent(device: bsdName, probe: probe)
                if self.probes.complete(device: bsdName, probe: probe,
                                        ready: hasMediaRoot && stillMounted) {
                    self.continuation.yield(.volumeMounted(candidate))
                }
                if current { self.onProbeFinished(bsdName, hasMediaRoot && stillMounted) }
            }
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
