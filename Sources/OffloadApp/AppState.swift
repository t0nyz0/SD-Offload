import SwiftUI
import Observation
import OffloadCore
import OffloadEngine

@MainActor @Observable
final class AppState {
    // Coarse — the ONLY property MenuBarLabel reads. Changes ≤ ~1/s.
    private(set) var menuBar: MenuBarState = .idle
    // Fine — popover-only. nil == idle.
    private(set) var session: SessionViewModel?
    private(set) var recent: [SessionRecord] = []
    private(set) var nasGlance = NASGlance()
    private(set) var pendingConsent: CardInfo?
    /// Mount path of a currently-inserted card (for the Library window). Set on
    /// detect/consent/session start, cleared when the card leaves or is ejected.
    private(set) var cardMountPath: String?

    var popoverVisible = false {
        didSet { if popoverVisible && !oldValue { refreshNASGlance(); refreshRecent() } }
    }

    let settings: SettingsStore
    @ObservationIgnored let journal: Journal
    @ObservationIgnored private(set) var engine: any EngineControlling
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var doneResetTask: Task<Void, Never>?

    init() {
        Paths.ensureAll()
        let settings = SettingsStore()
        self.settings = settings
        let journal = Journal()
        self.journal = journal
        self.engine = Self.makeEngine(settings: settings, journal: journal)
        startPump()
        engine.start()
        refreshNASGlance()
        refreshRecent()
    }

    private static func makeEngine(settings: SettingsStore, journal: Journal) -> any EngineControlling {
        if ProcessInfo.processInfo.environment["OFFLOAD_DEMO"] == "1" {
            return DemoEngine()
        }
        return EngineController(
            configProvider: { await MainActor.run { settings.config } },
            configMutator: { mutate in
                await MainActor.run {
                    var config = settings.config
                    mutate(&config)
                    settings.config = config
                }
            },
            journal: journal
        )
    }

    // MARK: - Event pump

    private func startPump() {
        pumpTask = Task { [weak self] in
            guard let stream = self?.engine.events else { return }
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: EngineEvent) {
        switch event {
        case .cardMounted(let card):
            cardMountPath = card.mountPath

        case .cardAwaitingConsent(let card):
            pendingConsent = card
            cardMountPath = card.mountPath
            recomputeMenuBar()

        case .cardGone:
            pendingConsent = nil
            cardMountPath = nil
            recomputeMenuBar()

        case .sessionStarted(let id, let card, let resumed):
            pendingConsent = nil
            cardMountPath = card.mountPath
            doneResetTask?.cancel()
            session = SessionViewModel(sessionID: id, card: card, resumed: resumed)
            startTick()
            recomputeMenuBar()

        case .planned(let files, let bytes):
            session?.plannedFiles = files
            session?.plannedBytes = bytes

        case .phase(let phase):
            session?.phase = phase
            recomputeMenuBar()
            if phase == .done || phase == .doneWipeBlocked || phase == .cancelled || phase == .failed {
                scheduleIdleReset(after: phase == .done ? 6 : 60)
                refreshRecent()
                refreshNASGlance()
            }

        case .progress(let snapshot):
            session?.scratch = snapshot

        case .speedSample(let sample):
            session?.appendSample(sample)

        case .wipeCountdown(let seconds):
            session?.wipeCountdown = seconds

        case .attention(let item):
            session?.failure = item
            if settings.config.notifyProblems {
                NotificationManager.shared.notifyProblem(item)
            }

        case .safeToRemove(let cardName):
            if settings.config.notifyComplete {
                NotificationManager.shared.notifySafeToRemove(cardName: cardName, sound: settings.config.playSounds)
            }

        case .completed(let record):
            session?.completed = record
            refreshRecent()

        case .sessionFailed(let record, let item):
            session?.completed = record
            session?.failure = item

        case .nasGlance(let glance):
            nasGlance = glance
            learnNASIdentityIfNeeded(glance)
        }
    }

    // MARK: - Display tick (4 Hz while a session is live)

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let vm = self.session else { return }
                vm.applyScratchTick()
                self.recomputeMenuBar()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func recomputeMenuBar() {
        let newState: MenuBarState
        if let vm = session {
            switch vm.phase {
            case .idle, .cancelled:
                newState = .idle
            case .awaitingConsent, .scanning:
                newState = .scanning
            case .transferring:
                newState = vm.hop1Fraction >= 1.0 ? .uploading(vm.percentInt) : .transferring(vm.percentInt)
            case .waitingForNAS:
                newState = .uploading(vm.percentInt)
            case .wipeCountdown, .awaitingWipeConsent, .wiping, .ejecting:
                newState = .verifying(vm.percentInt)
            case .done:
                newState = .doneFlash
            case .doneWipeBlocked, .failed:
                newState = .attention
            case .pausedByUser, .pausedCardGone:
                newState = .paused(vm.percentInt)
            }
        } else if pendingConsent != nil {
            newState = .scanning
        } else {
            newState = .idle
        }
        if menuBar != newState { menuBar = newState }
    }

    private func scheduleIdleReset(after seconds: TimeInterval) {
        doneResetTask?.cancel()
        doneResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.session = nil
            self.tickTask?.cancel()
            self.recomputeMenuBar()
        }
    }

    // MARK: - Glance + history

    func refreshNASGlance() {
        let config = settings.config
        Task.detached { [weak self] in
            let glance = EngineGlance.quickNASGlance(config: config)
            await MainActor.run { [weak self] in
                self?.nasGlance = glance
                self?.learnNASIdentityIfNeeded(glance)
            }
        }
    }

    private func learnNASIdentityIfNeeded(_ glance: NASGlance) {
        guard glance.healthy, let mnt = glance.mntFromName,
              settings.config.nasExpectedMntFromName == nil else { return }
        settings.config.nasExpectedMntFromName = mnt
        // "//user@host/Share" → "smb://user@host/Share" for NetFS remount.
        if settings.config.nasSMBURL == nil, mnt.hasPrefix("//") {
            settings.config.nasSMBURL = "smb:" + mnt
        }
    }

    func refreshRecent() {
        Task { [weak self] in
            guard let self else { return }
            let history = await self.journal.loadHistory(limit: 10)
            self.recent = history
        }
    }

    // MARK: - User intents

    func consentTapped(remember: CardPolicy?) {
        guard let card = pendingConsent else { return }
        settings.config.cardNames[card.volumeUUID] = card.volumeName
        engine.consentToIngest(cardUUID: card.volumeUUID, remember: remember)
        pendingConsent = nil
    }

    func declineTapped(remember: CardPolicy?) {
        guard let card = pendingConsent else { return }
        engine.declineIngest(cardUUID: card.volumeUUID, remember: remember)
        pendingConsent = nil
        recomputeMenuBar()
    }

    func pauseTapped() { engine.pause() }
    func resumeTapped() { engine.resume() }
    func cancelTapped() { engine.cancel() }
    func retryTapped() { engine.retry() }
    func confirmWipeTapped() { engine.confirmWipe() }
    func cancelWipeTapped() { engine.cancelWipe() }
    func ejectTapped() { engine.eject() }
}
