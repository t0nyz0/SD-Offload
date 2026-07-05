import Foundation
import OffloadCore

/// The real engine: owns the CardWatcher, classifies volumes, runs one
/// SessionRunner at a time, and handles resume-on-reinsert.
public final class EngineController: EngineControlling, @unchecked Sendable {
    private let coordinator: Coordinator
    public let events: AsyncStream<EngineEvent>

    public init(configProvider: @escaping ConfigProvider,
                configMutator: @escaping ConfigMutator,
                journal: Journal) {
        var cont: AsyncStream<EngineEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        let continuation = cont!
        self.coordinator = Coordinator(configProvider: configProvider,
                                       configMutator: configMutator,
                                       journal: journal,
                                       emit: { continuation.yield($0) })
    }

    public func start() { Task { await coordinator.start() } }
    public func consentToIngest(cardUUID: String, remember: CardPolicy?) {
        Task { await coordinator.consent(cardUUID: cardUUID, remember: remember) }
    }
    public func declineIngest(cardUUID: String, remember: CardPolicy?) {
        Task { await coordinator.decline(cardUUID: cardUUID, remember: remember) }
    }
    public func pause() { Task { await coordinator.runner?.pause() } }
    public func resume() { Task { await coordinator.runner?.resume() } }
    public func cancel() { Task { await coordinator.runner?.cancel() } }
    public func confirmWipe() { Task { await coordinator.runner?.confirmWipe() } }
    public func cancelWipe() { Task { await coordinator.runner?.cancelWipe() } }
    public func eject() { Task { await coordinator.eject() } }
    public func retry() { Task { await coordinator.retry() } }
    public func refreshNASGlance() { Task { await coordinator.emitGlance() } }
}

private actor Coordinator {
    let configProvider: ConfigProvider
    let configMutator: ConfigMutator
    let journal: Journal
    let emit: @Sendable (EngineEvent) -> Void
    let watcher = CardWatcher()
    let planner = IngestPlanner()
    let nas: NASLocator

    private(set) var runner: SessionRunner?
    private var pendingCandidates: [String: CandidateVolume] = [:]
    // Cards inserted while a session is running — offloaded in turn, FIFO, so you
    // can stack several readers and walk away.
    private var queue: [CandidateVolume] = []
    private var lastVolume: CandidateVolume?
    private var eventsTask: Task<Void, Never>?

    init(configProvider: @escaping ConfigProvider,
         configMutator: @escaping ConfigMutator,
         journal: Journal,
         emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.configProvider = configProvider
        self.configMutator = configMutator
        self.journal = journal
        self.emit = emit
        self.nas = NASLocator(configProvider: configProvider)
    }

    func start() async {
        await emitGlance()
        let config = await configProvider()
        StagingStore(rootPath: config.stagingRootPath).sweep(keepDays: max(config.keepStagedDays, 1))

        watcher.start()
        eventsTask = Task { [weak self] in
            guard let events = self?.watcher.events else { return }
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    func emitGlance() async {
        let config = await configProvider()
        emit(.nasGlance(EngineGlance.quickNASGlance(config: config)))
    }

    // Per-card session marker (hidden file on the card). See Paths.cardSessionMarkerName.
    private func markerURL(_ mountPath: String) -> URL {
        URL(fileURLWithPath: mountPath).appendingPathComponent(Paths.cardSessionMarkerName)
    }
    private func readCardToken(_ mountPath: String) -> String? {
        (try? String(contentsOf: markerURL(mountPath), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func writeCardToken(_ token: String, to mountPath: String) {
        try? Data(token.utf8).write(to: markerURL(mountPath))
    }

    // MARK: - Card events

    private func handle(_ event: RawCardEvent) async {
        switch event {
        case .volumeMounted(let volume):
            let config = await configProvider()
            // Same card back mid-session → resume, regardless of policy.
            if let runner, runner.card.volumeUUID == volume.info.volumeUUID {
                await resumeAfterReinsert(volume)
                return
            }
            // Unfinished work for this card resumes even if its policy is now
            // "ignore"/"ask" — otherwise an interrupted session would be
            // stranded forever, its card never wiped.
            if runner == nil, await journal.hasIncompleteSession(cardUUID: volume.info.volumeUUID) {
                await startSession(volume)
                return
            }
            switch CardClassifier.classify(volume, config: config) {
            case .ignore:
                break
            case .ask:
                pendingCandidates[volume.info.volumeUUID] = volume
                await configMutator { [name = volume.info.volumeName, uuid = volume.info.volumeUUID] in
                    $0.cardNames[uuid] = name
                }
                emit(.cardAwaitingConsent(volume.info))
            case .ingest:
                await startSession(volume)
            }

        case .volumeUnmounted(let uuid, _):
            pendingCandidates.removeValue(forKey: uuid)
            queue.removeAll { $0.info.volumeUUID == uuid }   // a queued card pulled before its turn
            if let runner, runner.card.volumeUUID == uuid {
                await runner.cardGone()
            } else {
                emit(.cardGone)
            }
        }
    }

    func consent(cardUUID: String, remember: CardPolicy?) async {
        guard let volume = pendingCandidates.removeValue(forKey: cardUUID) else { return }
        if let remember {
            await configMutator { $0.cardPolicies[cardUUID] = remember }
        }
        await startSession(volume)
    }

    func decline(cardUUID: String, remember: CardPolicy?) async {
        pendingCandidates.removeValue(forKey: cardUUID)
        if let remember {
            await configMutator { $0.cardPolicies[cardUUID] = remember }
        }
        emit(.cardGone)
    }

    // MARK: - Session lifecycle

    private func startSession(_ volume: CandidateVolume) async {
        guard runner == nil else {
            // Busy — queue this card and start it automatically when the current
            // one finishes (skip the card already running and any dup already queued).
            if runner?.card.volumeUUID != volume.info.volumeUUID,
               !queue.contains(where: { $0.info.volumeUUID == volume.info.volumeUUID }) {
                queue.append(volume)
                emit(.attention(AttentionItem(severity: .info,
                                              title: "Card queued",
                                              detail: "\(volume.info.volumeName) will start automatically when the current card finishes.")))
            }
            return
        }
        lastVolume = volume
        let config = await configProvider()
        emit(.cardMounted(volume.info))
        let staging = StagingStore(rootPath: config.stagingRootPath)
        let cardRoot = URL(fileURLWithPath: volume.info.mountPath, isDirectory: true)

        if let incomplete = await journal.openIncompleteSession(cardUUID: volume.info.volumeUUID),
           incomplete.cardSessionToken == nil || incomplete.cardSessionToken == readCardToken(volume.info.mountPath) {
            // Resume only when the card in the slot really is this session's card
            // (token match), or the session predates tokens (legacy). A mismatch
            // means a different physical card collided on a synthesized UUID —
            // fall through and start a fresh session for it instead.
            emit(.sessionStarted(sessionID: incomplete.id, card: volume.info, resumed: true))
            emit(.phase(.scanning))
            staging.removePartials(incomplete.id)
            let planner = self.planner
            let scope = config.ingestScope
            let scanned = await Task.detached(priority: .userInitiated) {
                planner.scan(cardRoot: cardRoot, scope: scope)
            }.value
            let plan = await planner.merge(scanned: scanned, into: incomplete.files)
            await journal.replaceFiles(plan.files, in: incomplete.id)
            let bytes = plan.files.reduce(Int64(0)) { $0 + $1.size }
            emit(.planned(files: plan.files.count, bytes: bytes))
            launchRunner(sessionID: incomplete.id, card: volume.info, config: config, staging: staging)
            return
        }

        let sessionID = UUID()
        emit(.sessionStarted(sessionID: sessionID, card: volume.info, resumed: false))
        emit(.phase(.scanning))
        let planner = self.planner
        let scope = config.ingestScope
        let scanned = await Task.detached(priority: .userInitiated) {
            planner.scan(cardRoot: cardRoot, scope: scope)
        }.value
        guard !scanned.isEmpty else {
            emit(.attention(AttentionItem(severity: .info,
                                          title: "Nothing to offload",
                                          detail: "\(volume.info.volumeName) has no photos or videos in its camera folders.")))
            emit(.phase(.idle))
            return
        }
        let plan = await planner.plan(scanned: scanned)
        // Stamp this physical card with a unique token so a same-size/same-name
        // card can never be mistaken for it at wipe time.
        let token = UUID().uuidString
        writeCardToken(token, to: volume.info.mountPath)
        var record = SessionRecord(id: sessionID,
                                   cardVolumeUUID: volume.info.volumeUUID,
                                   cardVolumeName: volume.info.volumeName,
                                   cardCapacityBytes: volume.info.capacityBytes,
                                   cardSessionToken: token)
        record.nasMntFromName = config.nasExpectedMntFromName
        record.files = plan.files
        record.stats.filesPlanned = plan.files.count
        record.stats.bytesPlanned = plan.files.reduce(0) { $0 + $1.size }
        do {
            try await journal.begin(record)
        } catch {
            emit(.attention(AttentionItem(severity: .error, title: "Couldn't start the session",
                                          detail: "Journal write failed: \(error)")))
            emit(.phase(.failed))
            return
        }
        emit(.planned(files: record.stats.filesPlanned, bytes: record.stats.bytesPlanned))
        launchRunner(sessionID: sessionID, card: volume.info, config: config, staging: staging)
    }

    private func launchRunner(sessionID: UUID, card: CardInfo, config: AppConfig, staging: StagingStore) {
        let runner = SessionRunner(sessionID: sessionID, card: card, config: config,
                                   journal: journal, staging: staging, nas: nas,
                                   cardWatcher: watcher, emit: emit)
        self.runner = runner
        Task { [weak self] in
            await runner.run()
            await self?.runnerFinished(runner)
        }
    }

    private func runnerFinished(_ finished: SessionRunner) async {
        if runner === finished { runner = nil }
        await emitGlance()
        // Auto-start the next queued card (still-mounted, pre-approved).
        if runner == nil, !queue.isEmpty {
            let next = queue.removeFirst()
            emit(.attention(AttentionItem(severity: .info,
                                          title: "Starting queued card",
                                          detail: "Offloading \(next.info.volumeName).")))
            await startSession(next)
        }
    }

    private func resumeAfterReinsert(_ volume: CandidateVolume) async {
        guard let runner else { return }
        let config = await configProvider()
        emit(.phase(.scanning))
        guard let record = await journal.session(id: runner.sessionID) else { return }
        let planner = self.planner
        let scope = config.ingestScope
        let cardRoot = URL(fileURLWithPath: volume.info.mountPath, isDirectory: true)
        let scanned = await Task.detached(priority: .userInitiated) {
            planner.scan(cardRoot: cardRoot, scope: scope)
        }.value
        let plan = await planner.merge(scanned: scanned, into: record.files)
        await journal.replaceFiles(plan.files, in: runner.sessionID)
        await runner.cardReturned()
    }

    // MARK: - Misc intents

    func eject() async {
        if let runner {
            await runner.ejectCard()
        } else if let lastVolume {
            try? await watcher.unmountAndEject(bsdName: lastVolume.info.bsdName)
        }
    }

    func retry() async {
        guard runner == nil, let lastVolume else { return }
        // Fresh session over the same card: files already on the NAS settle as
        // hash-proven skippedDuplicate, so a retry only pays a card re-read.
        await startSession(lastVolume)
    }
}
