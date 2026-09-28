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
    private var fileOffsets: [UUID: [UUID: Int]] = [:]
    private var workCache: [UUID: RemainingWork] = [:]

    public struct RemainingWork: Sendable {
        public var sdBytes: Int64 = 0, verifyBytes: Int64 = 0, nasBytes: Int64 = 0
        public var sdFiles = 0, verifyFiles = 0, nasFiles = 0
        fileprivate mutating func adjust(state: FileState, bytes: Int64, direction: Int) {
            let delta = bytes * Int64(direction)
            switch state {
            case .pending, .copying:
                sdBytes += delta; sdFiles += direction
                fallthrough
            case .staged:
                verifyBytes += delta; verifyFiles += direction
                fallthrough
            case .stagedVerified, .uploading:
                nasBytes += delta; nasFiles += direction
            default: break
            }
        }
    }

    public func remainingWork(in id: UUID) -> RemainingWork {
        if let cached = workCache[id] { return cached }
        var result = RemainingWork()
        for file in active[id]?.files ?? [] {
            result.adjust(state: file.state, bytes: file.size, direction: 1)
        }
        workCache[id] = result
        return result
    }

    private func indexFiles(_ id: UUID) {
        fileOffsets[id] = Dictionary((active[id]?.files ?? []).enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        workCache[id] = nil
    }
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
        indexFiles(session.id)
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
            indexFiles(found.id)
            return found
        }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for url in entries where url.pathExtension == "json" {
            guard var record = JSONIO.loadGuarded(SessionRecord.self, from: url) else { continue }
            if record.cardVolumeUUID == cardUUID && record.isIncomplete {
                record = Self.applyingCrashRemap(record)
                active[record.id] = record
                indexFiles(record.id)
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
        fileOffsets[id] = nil
        workCache[id] = nil
        dirty.remove(id)
        trimHistory(keepLast: 300)
    }

    /// Keep History bounded — prune the oldest session files beyond `keepLast`.
    private func trimHistory(keepLast: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: historyDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = entries.filter { $0.pathExtension == "json" }
        guard files.count > keepLast else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b   // oldest first
        }
        for url in sorted.prefix(files.count - keepLast) { try? fm.removeItem(at: url) }
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

    /// Is there unfinished work for this card (active or on disk)? Used so the
    /// engine resumes an interrupted card even if its policy is now "ignore".
    public func hasIncompleteSession(cardUUID: String) -> Bool {
        if active.values.contains(where: { $0.cardVolumeUUID == cardUUID && $0.isIncomplete }) { return true }
        return loadIncompleteSessions().contains { $0.cardVolumeUUID == cardUUID }
    }

    // MARK: - Mutation

    public func transition(file fileID: UUID, to newState: FileState, in sessionID: UUID) {
        guard let idx = fileOffsets[sessionID]?[fileID],
              let old = active[sessionID]?.files[idx].state else { return }
        if old == newState { return }
        mutate(sessionID) { record in
            guard FileState.isLegal(from: old, to: newState) else {
                record.files[idx].state = .failed(.internalError("illegal transition \(old) → \(newState)"))
                record.files[idx].stateChangedAt = Date()
                return
            }
            record.files[idx].state = newState
            record.files[idx].stateChangedAt = Date()
            if case .failed = newState { record.stats.filesFailed += 1 }
            if newState == .nasVerified { record.stats.filesNASVerified += 1 }
            if newState == .skippedDuplicate { record.stats.filesSkippedDuplicate += 1 }
            if newState == .wiped { record.stats.filesWiped += 1 }
        }
        if var cached = workCache[sessionID], let file = active[sessionID]?.files[idx] {
            cached.adjust(state: old, bytes: file.size, direction: -1)
            cached.adjust(state: file.state, bytes: file.size, direction: 1)
            workCache[sessionID] = cached
        }
    }

    public func bumpAttempts(file fileID: UUID, in sessionID: UUID) {
        let offset = fileOffsets[sessionID]?[fileID]
        mutate(sessionID) { record in
            if let idx = offset {
                record.files[idx].attempts += 1
            }
        }
    }

    public func setSourceHash(file fileID: UUID, hex: String, in sessionID: UUID) {
        let offset = fileOffsets[sessionID]?[fileID]
        mutate(sessionID) { record in
            if let idx = offset {
                record.files[idx].sourceHashHex = hex
            }
        }
        // The hash is the end-to-end verification reference — milestone flush.
        try? flushNow(sessionID)
    }

    public func setDestRelPath(file fileID: UUID, rel: String, in sessionID: UUID) {
        let offset = fileOffsets[sessionID]?[fileID]
        mutate(sessionID) { record in
            if let idx = offset {
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
        indexFiles(sessionID)
        try? flushNow(sessionID)
    }

    public func setEnded(in sessionID: UUID) {
        mutate(sessionID) { $0.endedAt = Date() }
    }

    private func mutate(_ sessionID: UUID, _ body: (inout SessionRecord) -> Void) {
        guard active[sessionID] != nil else { return }
        body(&active[sessionID]!)
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
