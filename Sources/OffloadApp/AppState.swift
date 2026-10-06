import SwiftUI
import Observation
import OffloadCore
import OffloadEngine

@MainActor @Observable
final class AppState {
    // Coarse — the status-item label mirrors this. Changes ≤ ~1/s.
    private(set) var menuBar: MenuBarState = .idle
    // Fine — popover-only. nil == idle.
    private(set) var session: SessionViewModel?
    private(set) var recent: [SessionRecord] = []
    private(set) var nasGlance = NASGlance()
    private(set) var pendingConsent: CardInfo?
    /// Set when the user clicks a recent session in the popover: the History window
    /// selects and scrolls to it, then clears this.
    var pendingHistorySelection: UUID?
    /// Absolute NAS folder the Library should jump to once on screen. nil = just
    /// show live progress. Consumed (reset to nil) by LibraryWindow.
    var pendingLibraryFolder: String?
    /// Mount path of a currently-inserted card (for the Library window). Set on
    /// detect/consent/session start, cleared when the card leaves or is ejected.
    private(set) var cardMountPath: String?

    var popoverVisible = false {
        didSet {
            if popoverVisible && !oldValue { refreshNASGlance(); refreshRecent() }
            updateNASMonitoring()
        }
    }
    @ObservationIgnored private var libraryVisible = false

    /// The AppKit layer that fulfills window requests (status-item popover, Library,
    /// History, Settings). Set once at launch by the AppDelegate. Weak: the
    /// coordinator outlives AppState in practice, but AppState must never own it.
    @ObservationIgnored weak var router: (any WindowRouting)?

    let settings: SettingsStore
    @ObservationIgnored let journal: Journal
    @ObservationIgnored private(set) var engine: any EngineControlling
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var doneResetTask: Task<Void, Never>?
    @ObservationIgnored private var nasMonitorTask: Task<Void, Never>?

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
        // The notification "Eject now" action posts this; wire it to the engine.
        NotificationCenter.default.addObserver(forName: .offloadEjectRequested, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ejectTapped() }
        }
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
            if settings.config.notifyCardDetected {
                NotificationManager.shared.notifyCardDetected(cardName: card.volumeName)
            }

        case .cardAwaitingConsent(let card):
            pendingConsent = card
            cardMountPath = card.mountPath
            if settings.config.notifyCardDetected {
                NotificationManager.shared.notifyCardDetected(cardName: card.volumeName)
            }
            recomputeMenuBar()
            // Pop the tray so the consent prompt is right there (ask-first path).
            if settings.config.autoOpenTrayOnInsert { router?.showPopover() }

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
            // Pop the tray so progress is visible (auto-ingest / resume path, where
            // no consent prompt fired). showPopover is a no-op refocus if already up.
            if settings.config.autoOpenTrayOnInsert { router?.showPopover() }

        case .planned(let files, let bytes):
            session?.plannedFiles = files
            session?.plannedBytes = bytes

        case .phase(let phase):
            session?.phase = phase
            recomputeMenuBar()
            if phase == .done || phase == .doneWipeBlocked || phase == .cancelled || phase == .failed {
                session?.applyScratchTick()
                tickTask?.cancel()
                if phase == .doneWipeBlocked || phase == .failed {
                    // Keep the recovery action available until the user acts.
                    doneResetTask?.cancel()
                } else {
                    scheduleIdleReset(after: phase == .done ? 6 : 60)
                }
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
            // Play our chosen chime in-app; keep the banner itself silent so we
            // don't double up with the notification's own sound.
            if settings.config.playSounds {
                Sounds.play(settings.config.completionSoundName)
            }
            if settings.config.notifyComplete {
                NotificationManager.shared.notifySafeToRemove(cardName: cardName, sound: false)
            }

        case .completed(let record):
            session?.completed = record
            refreshRecent()
            // New photos just landed on the NAS — drop the cached library total so it
            // re-counts (accurate header without a manual Refresh).
            LibraryIndex.invalidate()
            if settings.config.autoShowLibrary,
               let folder = Self.uploadedFolder(from: record, nasRoot: settings.config.nasRootPath) {
                router?.openLibrary(folder: folder)   // reveal the just-uploaded batch
            }

        case .sessionFailed(let record, let item):
            session?.completed = record
            session?.failure = item

        case .nasGlance(let glance):
            nasGlance = glance
            learnNASIdentityIfNeeded(glance)

        case .nasRecovered:
            if session?.failure?.title == "Waiting for the NAS"
                || session?.failure?.title == "NAS path is a local folder" {
                session?.failure = nil
            }
            refreshNASGlance()
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
                newState = vm.hop1Fraction >= 1.0 ? .uploading(vm.headlinePercent) : .transferring(vm.headlinePercent)
            case .waitingForNAS:
                newState = .uploading(vm.headlinePercent)
            case .wipeCountdown, .awaitingWipeConsent, .verifyingDestination, .wiping, .ejecting:
                newState = .verifying(vm.headlinePercent)
            case .done:
                newState = .doneFlash
            case .doneWipeBlocked, .failed:
                newState = .attention
            case .pausedByUser, .pausedCardGone:
                newState = .paused(vm.headlinePercent)
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
        engine.refreshNASGlance()
    }

    /// Keep the configured destination live while either NAS-facing surface is
    /// visible. Closing both stops the idle polling; an active transfer has its
    /// own persistent retry loop in SessionRunner.
    func setLibraryVisible(_ visible: Bool) {
        guard libraryVisible != visible else { return }
        libraryVisible = visible
        updateNASMonitoring()
    }

    private func updateNASMonitoring() {
        let shouldMonitor = popoverVisible || libraryVisible
        guard shouldMonitor else {
            nasMonitorTask?.cancel()
            nasMonitorTask = nil
            return
        }
        refreshNASGlance()
        guard nasMonitorTask == nil else { return }
        nasMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard let self, self.popoverVisible || self.libraryVisible else { return }
                self.refreshNASGlance()
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

    func consentTapped() {
        guard let card = pendingConsent else { return }
        engine.consentToIngest(cardUUID: card.volumeUUID)
        pendingConsent = nil
    }

    func declineTapped() {
        guard let card = pendingConsent else { return }
        engine.declineIngest(cardUUID: card.volumeUUID)
        pendingConsent = nil
        recomputeMenuBar()
    }

    func pauseTapped() { engine.pause() }
    func resumeTapped() { engine.resume() }
    func cancelTapped() { engine.cancel() }
    func retryTapped() {
        if let record = session?.completed, record.canRetryWipe {
            engine.retryWipe(sessionID: record.id)
        } else {
            engine.retry()
        }
    }
    func confirmWipeTapped() { engine.confirmWipe() }
    func cancelWipeTapped() { engine.cancelWipe() }
    func ejectTapped() { engine.eject() }
    /// "Look for a card" — force the engine to re-check mounted volumes when an
    /// insert wasn't picked up automatically.
    func rescanTapped() { engine.rescan() }

    /// The NAS date-folder (absolute) that received the most files this
    /// session — a batch spanning several capture days reveals the busiest day.
    /// Counts only files that actually landed on the NAS (nasVerified / skipped /
    /// wiped), so it resolves for auto-wiped batches too.
    static func uploadedFolder(from record: SessionRecord, nasRoot: String) -> String? {
        var counts: [String: Int] = [:]
        for file in record.files where file.state.isWipeEligible {
            let folder = (file.destRelPath as NSString).deletingLastPathComponent
            guard folder != ".", !folder.isEmpty else { continue }
            counts[folder, default: 0] += 1
        }
        guard let best = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return URL(fileURLWithPath: nasRoot, isDirectory: true).appendingPathComponent(best).path
    }
}
