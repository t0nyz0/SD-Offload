import Foundation

/// Crash-safe session journal. One JSON file per active session under
/// `Journal/`, moved to `History/` on completion.
///
/// Write discipline: state transitions set a dirty flag flushed at most once
/// per second; milestones (begin, session-state change, source hash recorded)
/// flush immediately; the wipe path AWAITS `flushNow` before the first unlink.
public actor Journal {
    private let dir: URL
    private let historyDir: URL
    private var active: [UUID: SessionRecord] = [:]
    private var dirty: Set<UUID> = []
    private var flushScheduled = false

    public init(directory: URL = Paths.journalDir, historyDir: URL = Paths.historyDir) {
        self.dir = directory
        self.historyDir = historyDir
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
    }

    private func fileURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("session-\(id.uuidString).json")
    }

    // MARK: - Lifecycle

    /// Durable flush before any IO on the card starts.
    public func begin(_ session: SessionRecord) throws {
        active[session.id] = session
        try JSONIO.saveDurable(session, to: fileURL(session.id))
    }

    public func session(id: UUID) -> SessionRecord? { active[id] }

    /// Find an incomplete session for this card on disk (after crash/relaunch or
    /// re-insert), apply the crash remap, and adopt it as active.
    public func openIncompleteSession(cardUUID: String) -> SessionRecord? {
        // Prefer an already-active session (card yanked and re-inserted mid-run).
        if var found = active.values.first(where: { $0.cardVolumeUUID == cardUUID && $0.isIncomplete }) {
            found = Self.applyingCrashRemap(found)
            active[found.id] = found
            return found
        }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for url in entries where url.pathExtension == "json" {
            guard var record = JSONIO.loadGuarded(SessionRecord.self, from: url) else { continue }
            if record.cardVolumeUUID == cardUUID && record.isIncomplete {
                record = Self.applyingCrashRemap(record)
                active[record.id] = record
                dirty.insert(record.id)
                return record
            }
        }
        return nil
    }

    public static func applyingCrashRemap(_ record: SessionRecord) -> SessionRecord {
        var r = record
        for i in r.files.indices {
            r.files[i].state = FileState.crashRemap(r.files[i].state)
        }
        return r
    }

    /// Move a finished session to History.
    public func complete(_ id: UUID) throws {
        guard let record = active[id] else { return }
        try JSONIO.saveDurable(record, to: historyDir.appendingPathComponent("session-\(id.uuidString).json"))
        try? FileManager.default.removeItem(at: fileURL(id))
        active.removeValue(forKey: id)
        dirty.remove(id)
    }

    /// Recent finished sessions, newest first.
    public func loadHistory(limit: Int = 50) -> [SessionRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let records = entries
            .filter { $0.pathExtension == "json" }
            .compactMap { JSONIO.loadGuarded(SessionRecord.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
        return Array(records.prefix(limit))
    }

    /// Any incomplete sessions on disk (app relaunch surface).
    public func loadIncompleteSessions() -> [SessionRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { JSONIO.loadGuarded(SessionRecord.self, from: $0) }
            .filter(\.isIncomplete)
    }

    // MARK: - Mutation

    public func transition(file fileID: UUID, to newState: FileState, in sessionID: UUID) {
        guard var record = active[sessionID],
              let idx = record.files.firstIndex(where: { $0.id == fileID }) else { return }
        let old = record.files[idx].state
        guard FileState.isLegal(from: old, to: newState) else {
            // Never crash mid-transfer: coerce to failed (which blocks the wipe)
            // and leave the evidence in the journal.
            print("[journal] ILLEGAL transition \(old) → \(newState) for \(record.files[idx].relPath)")
            record.files[idx].state = .failed(.internalError("illegal transition \(old) → \(newState)"))
            record.files[idx].stateChangedAt = Date()
            active[sessionID] = record
            markDirty(sessionID)
            return
        }
        record.files[idx].state = newState
        record.files[idx].stateChangedAt = Date()
        if case .failed = newState { record.stats.filesFailed += 1 }
        if newState == .nasVerified { record.stats.filesNASVerified += 1 }
        if newState == .skippedDuplicate { record.stats.filesSkippedDuplicate += 1 }
        if newState == .wiped { record.stats.filesWiped += 1 }
        active[sessionID] = record
        markDirty(sessionID)
    }

    public func bumpAttempts(file fileID: UUID, in sessionID: UUID) {
        mutate(sessionID) { record in
            if let idx = record.files.firstIndex(where: { $0.id == fileID }) {
                record.files[idx].attempts += 1
            }
        }
    }

    public func setSourceHash(file fileID: UUID, hex: String, in sessionID: UUID) {
        mutate(sessionID) { record in
            if let idx = record.files.firstIndex(where: { $0.id == fileID }) {
                record.files[idx].sourceHashHex = hex
            }
        }
        // The hash is the end-to-end verification reference — milestone flush.
        try? flushNow(sessionID)
    }

    public func setDestRelPath(file fileID: UUID, rel: String, in sessionID: UUID) {
        mutate(sessionID) { record in
            if let idx = record.files.firstIndex(where: { $0.id == fileID }) {
                record.files[idx].destRelPath = rel
            }
        }
    }

    public func setSessionState(_ state: SessionState, in sessionID: UUID) {
        mutate(sessionID) { $0.state = state }
        try? flushNow(sessionID)
    }

    public func setWipeReport(_ report: WipeReport, in sessionID: UUID) {
        mutate(sessionID) { $0.wipeReport = report }
        try? flushNow(sessionID)
    }

    public func updateStats(in sessionID: UUID, _ body: @Sendable (inout SessionStats) -> Void) {
        mutate(sessionID) { body(&$0.stats) }
    }

    public func replaceFiles(_ files: [FileRecord], in sessionID: UUID) {
        mutate(sessionID) { record in
            record.files = files
            record.stats.filesPlanned = files.count
            record.stats.bytesPlanned = files.reduce(0) { $0 + $1.size }
        }
        try? flushNow(sessionID)
    }

    public func setEnded(in sessionID: UUID) {
        mutate(sessionID) { $0.endedAt = Date() }
    }

    private func mutate(_ sessionID: UUID, _ body: (inout SessionRecord) -> Void) {
        guard var record = active[sessionID] else { return }
        body(&record)
        active[sessionID] = record
        markDirty(sessionID)
    }

    // MARK: - Flushing

    public func flushNow(_ id: UUID) throws {
        guard let record = active[id] else { return }
        try JSONIO.saveDurable(record, to: fileURL(id))
        dirty.remove(id)
    }

    private func markDirty(_ id: UUID) {
        dirty.insert(id)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushDirty()
        }
    }

    private func flushDirty() {
        flushScheduled = false
        for id in dirty {
            try? flushNow(id)
        }
    }
}
