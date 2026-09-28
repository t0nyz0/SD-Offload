import Foundation
import OffloadCore

public enum LibraryMigrationError: LocalizedError, Sendable {
    case invalidPattern(String)
    case destinationUnavailable(String)
    case incompleteSession
    case nothingToMove
    case secondaryMismatch(String)
    case conflict(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let message): message
        case .destinationUnavailable(let path): "The expected writable destination is unavailable at \(path)."
        case .incompleteSession: "Finish or cancel every incomplete offload before reorganizing the library."
        case .nothingToMove: "No folders need to be converted to the selected layout."
        case .secondaryMismatch(let path): "The second destination is missing \(path). Repair or disable it before converting."
        case .conflict(let message): message
        case .io(let message): message
        }
    }
}

public struct LibraryMigrationPlan: Codable, Sendable, Identifiable, Equatable {
    public struct Move: Codable, Sendable, Equatable, Identifiable {
        public var id: String { tempName }
        public let oldRelativePath: String
        public let newRelativePath: String
        public let tempName: String
        public let size: Int64
    }
    public struct FolderMap: Codable, Sendable, Equatable {
        public let oldRelativePath: String
        public let newRelativePath: String
    }

    public let id: UUID
    public let createdAt: Date
    public let primaryRoot: String
    public let secondaryRoot: String?
    public let sourceLayouts: [DateFolderLayout]
    public let targetLayout: DateFolderLayout
    public let moves: [Move]
    public let folders: [FolderMap]
    public let collisionCount: Int
    public let ignoredFolderCount: Int

    public var totalBytes: Int64 { moves.reduce(0) { $0 + $1.size } }
}

public struct LibraryMigrationState: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case planned, moving, updatingMetadata, completed, rollingBack, rolledBack, failed
    }
    public enum Location: String, Codable, Sendable { case original, staged, final }
    public struct MoveState: Codable, Sendable, Equatable {
        public var primary: Location = .original
        public var secondary: Location = .original
    }

    public var plan: LibraryMigrationPlan
    public var status: Status = .planned
    public var moves: [MoveState]
    public var completedMoves: Int = 0
    public var lastError: String?
    public var backedUpItems: [String] = []
}

/// Crash-safe same-volume library reorganization. Every source file is first
/// renamed into a hidden payload directory on its own destination, then placed
/// at its final path. The plan and phase boundaries are durable; after a quit,
/// power loss, or NAS outage, the three possible filesystem locations are
/// reconciled before resume or rollback. That avoids rewriting a huge plan after
/// every filename while retaining deterministic crash recovery.
public actor LibraryMigrator {
    private let stateFile: URL
    private let backupsRoot: URL
    private let supportRoot: URL
    private let fm = FileManager.default

    public init(supportRoot: URL = Paths.appSupport, stateFile: URL? = nil,
                backupsRoot: URL? = nil) {
        self.supportRoot = supportRoot
        self.stateFile = stateFile ?? supportRoot.appendingPathComponent("library-migration.json")
        self.backupsRoot = backupsRoot ?? supportRoot.appendingPathComponent("MigrationBackups", isDirectory: true)
    }

    public func pendingState() -> LibraryMigrationState? {
        JSONIO.loadGuarded(LibraryMigrationState.self, from: stateFile)
    }

    public func makePlan(config: AppConfig, target: DateFolderLayout) throws -> LibraryMigrationPlan {
        if let error = target.validationError { throw LibraryMigrationError.invalidPattern(error) }
        guard NASLocator.evaluate(config: config).isWritableNAS else {
            throw LibraryMigrationError.destinationUnavailable(config.nasRootPath)
        }
        if hasIncompleteSessions() { throw LibraryMigrationError.incompleteSession }

        let sourceLayouts = uniqueLayouts(config.recognizedDateFolderLayouts + [config.dateFolderLayout, .nestedNumeric])
        let primary = URL(fileURLWithPath: config.nasRootPath, isDirectory: true)
        let secondary = config.secondaryDestPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let secondary, statfsInfo(path: secondary.path) == nil {
            throw LibraryMigrationError.destinationUnavailable(secondary.path)
        }

        let inventory = try inventory(root: primary, layouts: sourceLayouts, target: target)
        guard !inventory.candidates.isEmpty else { throw LibraryMigrationError.nothingToMove }
        if let secondary {
            for candidate in inventory.candidates {
                let url = secondary.appendingPathComponent(candidate.old)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                    throw LibraryMigrationError.secondaryMismatch(candidate.old)
                }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                guard size == candidate.size else {
                    throw LibraryMigrationError.secondaryMismatch("\(candidate.old) (size differs)")
                }
            }
        }

        let movingSources = Set(inventory.candidates.map { normalized($0.old) })
        var occupied = try existingFilePaths(root: primary)
        if let secondary { occupied.formUnion(try existingFilePaths(root: secondary)) }
        occupied.subtract(movingSources)
        var chosen = Set<String>()
        var moves: [LibraryMigrationPlan.Move] = []
        var collisions = 0
        for (index, candidate) in inventory.candidates.sorted(by: { $0.old < $1.old }).enumerated() {
            var destination = candidate.desired
            var attempt = 2
            while occupied.contains(normalized(destination)) || chosen.contains(normalized(destination)) {
                destination = CollisionPolicy.suffixed(candidate.desired, attempt: attempt)
                attempt += 1
            }
            if destination != candidate.desired { collisions += 1 }
            chosen.insert(normalized(destination))
            moves.append(.init(oldRelativePath: candidate.old, newRelativePath: destination,
                               tempName: String(format: "%08d", index), size: candidate.size))
        }

        var folderMap: [String: String] = [:]
        for day in inventory.days where day.old != day.new { folderMap[day.old] = day.new }
        return LibraryMigrationPlan(
            id: UUID(), createdAt: Date(), primaryRoot: primary.path, secondaryRoot: secondary?.path,
            sourceLayouts: sourceLayouts, targetLayout: target, moves: moves,
            folders: folderMap.sorted(by: { $0.key < $1.key }).map {
                LibraryMigrationPlan.FolderMap(oldRelativePath: $0.key, newRelativePath: $0.value)
            },
            collisionCount: collisions, ignoredFolderCount: inventory.ignoredFolders)
    }

    public func start(_ plan: LibraryMigrationPlan,
                      onProgress: (@Sendable (LibraryMigrationState) -> Void)? = nil) async throws {
        guard pendingState() == nil else {
            throw LibraryMigrationError.conflict("Another library migration is awaiting resume or rollback.")
        }
        if hasIncompleteSessions() { throw LibraryMigrationError.incompleteSession }
        guard OrderedJSONWriter.shared.flush() else {
            throw LibraryMigrationError.io("Save pending library edits before reorganizing folders.")
        }
        var state = LibraryMigrationState(plan: plan, moves: Array(repeating: .init(), count: plan.moves.count))
        try backupMetadata(state: &state)
        try save(&state, notify: onProgress)
        // Close the small gap between preflight and the first durable migration
        // state: if a card began offloading during metadata backup, stop before
        // any destination file is renamed.
        if hasIncompleteSessions() {
            state.status = .failed
            state.lastError = LibraryMigrationError.incompleteSession.errorDescription
            try save(&state, notify: onProgress)
            throw LibraryMigrationError.incompleteSession
        }
        try await execute(state: &state, onProgress: onProgress)
    }

    public func resume(onProgress: (@Sendable (LibraryMigrationState) -> Void)? = nil) async throws {
        guard var state = pendingState() else { return }
        guard state.status != .completed, state.status != .rolledBack else { onProgress?(state); return }
        if state.status == .rollingBack {
            try await rollback(onProgress: onProgress)
            return
        }
        if hasIncompleteSessions() { throw LibraryMigrationError.incompleteSession }
        try await execute(state: &state, onProgress: onProgress)
    }

    public func rollback(onProgress: (@Sendable (LibraryMigrationState) -> Void)? = nil) async throws {
        guard var state = pendingState() else { return }
        if hasIncompleteSessions() { throw LibraryMigrationError.incompleteSession }
        state.status = .rollingBack; state.lastError = nil
        do {
            try reconcileFilesystem(&state)
            try save(&state, notify: onProgress)
            for index in state.plan.moves.indices.reversed() {
                try rollback(move: state.plan.moves[index], location: &state.moves[index].primary,
                             root: state.plan.primaryRoot, migrationID: state.plan.id)
                if let secondary = state.plan.secondaryRoot {
                    try rollback(move: state.plan.moves[index], location: &state.moves[index].secondary,
                                 root: secondary, migrationID: state.plan.id)
                }
                state.completedMoves = state.moves.filter { $0.primary == .original }.count
                notifyProgress(state, index: state.plan.moves.count - index, notify: onProgress)
            }
            try save(&state, notify: onProgress)
            try restoreMetadata(state)
            state.status = .rolledBack
            try save(&state, notify: onProgress)
        } catch {
            state.status = .failed; state.lastError = "\(error)"
            try? save(&state, notify: onProgress)
            throw error
        }
    }

    public func acknowledge() {
        guard let state = pendingState(), state.status == .completed || state.status == .rolledBack else { return }
        try? fm.removeItem(at: backupDir(state.plan.id))
        JSONIO.purge(stateFile)
        cleanupMigrationDir(root: state.plan.primaryRoot, id: state.plan.id)
        if let secondary = state.plan.secondaryRoot { cleanupMigrationDir(root: secondary, id: state.plan.id) }
    }

    // MARK: Planning

    private struct Candidate { let old: String; let desired: String; let size: Int64 }
    private struct Day { let old: String; let new: String }
    private struct Inventory { let candidates: [Candidate]; let days: [Day]; let ignoredFolders: Int }

    private func inventory(root: URL, layouts: [DateFolderLayout], target: DateFolderLayout) throws -> Inventory {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw LibraryMigrationError.io("Couldn’t enumerate \(root.path).")
        }
        var days: [(url: URL, rel: String, new: String)] = []
        var topLevelFolders = Set<String>()
        var recognizedTopLevelFolders = Set<String>()
        for case let url as URL in enumerator {
            let rel = relative(url, root: root)
            if rel.hasPrefix(".offload-migrations/") { enumerator.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let components = rel.split(separator: "/").map(String.init)
            if components.count == 1, let top = components.first { topLevelFolders.insert(top) }
            var matched: DateFolderLayout.Parsed?
            for layout in layouts {
                let requiredDepth = layout.pattern.split(separator: "/", omittingEmptySubsequences: false).count
                let actualDepth = components.count
                if actualDepth == requiredDepth, let parsed = layout.parse(folderPath: rel), parsed.precision == .day {
                    matched = parsed; break
                }
            }
            if let matched {
                if let top = components.first { recognizedTopLevelFolders.insert(top) }
                let new = target.folderPath(for: matched.date)
                if new != rel { days.append((url, rel, new)) }
                enumerator.skipDescendants()
            }
        }

        var candidates: [Candidate] = []
        for day in days {
            guard let items = fm.enumerator(at: day.url, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let item as URL in items {
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { continue }
                let old = relative(item, root: root)
                let tail = relative(item, root: day.url)
                candidates.append(Candidate(old: old, desired: day.new + "/" + tail,
                                            size: Int64(values?.fileSize ?? 0)))
            }
        }
        return Inventory(candidates: candidates, days: days.map { Day(old: $0.rel, new: $0.new) },
                         ignoredFolders: topLevelFolders.subtracting(recognizedTopLevelFolders).count)
    }

    private func existingFilePaths(root: URL) throws -> Set<String> {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            throw LibraryMigrationError.io("Couldn’t inspect existing paths at \(root.path).")
        }
        var result = Set<String>()
        for case let url as URL in enumerator {
            let rel = relative(url, root: root)
            if rel.hasPrefix(".offload-migrations/") { enumerator.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true {
                result.insert(normalized(rel))
            }
        }
        return result
    }

    // MARK: Execution

    private func execute(state: inout LibraryMigrationState,
                         onProgress: (@Sendable (LibraryMigrationState) -> Void)?) async throws {
        do {
            // A process can stop after `rename(2)` succeeds but before the next
            // durable state write. Reconcile the journal with the three possible
            // locations before either resuming or rolling back.
            try reconcileFilesystem(&state)
            state.status = .moving; state.lastError = nil
            try save(&state, notify: onProgress)
            for index in state.plan.moves.indices {
                try Task.checkCancellation()
                try advance(move: state.plan.moves[index], location: &state.moves[index].primary,
                            root: state.plan.primaryRoot, migrationID: state.plan.id, onlyStage: true)
                if let secondary = state.plan.secondaryRoot {
                    try advance(move: state.plan.moves[index], location: &state.moves[index].secondary,
                                root: secondary, migrationID: state.plan.id, onlyStage: true)
                } else { state.moves[index].secondary = .final }
                notifyProgress(state, index: index + 1, notify: onProgress)
            }
            // One durable checkpoint after the staging phase is enough: a crash
            // before it is reconciled from the actual old/staged/final paths.
            try save(&state, notify: onProgress)
            for index in state.plan.moves.indices {
                try Task.checkCancellation()
                try advance(move: state.plan.moves[index], location: &state.moves[index].primary,
                            root: state.plan.primaryRoot, migrationID: state.plan.id, onlyStage: false)
                if let secondary = state.plan.secondaryRoot {
                    try advance(move: state.plan.moves[index], location: &state.moves[index].secondary,
                                root: secondary, migrationID: state.plan.id, onlyStage: false)
                }
                state.completedMoves = state.moves.filter { $0.primary == .final && $0.secondary == .final }.count
                notifyProgress(state, index: index + 1, notify: onProgress)
            }
            try save(&state, notify: onProgress)

            state.status = .updatingMetadata
            try save(&state, notify: onProgress)
            try await updateMetadata(state.plan)
            cleanupOldFolders(state.plan)
            var config = JSONIO.loadGuarded(AppConfig.self, from: supportURL("config.json")) ?? AppConfig()
            config.dateFolderLayout = state.plan.targetLayout
            if !config.recognizedDateFolderLayouts.contains(state.plan.targetLayout) {
                config.recognizedDateFolderLayouts.append(state.plan.targetLayout)
            }
            try JSONIO.saveDurable(config, to: supportURL("config.json"))
            state.status = .completed
            try save(&state, notify: onProgress)
        } catch {
            state.status = .failed; state.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            try? save(&state, notify: onProgress)
            throw error
        }
    }

    private func advance(move: LibraryMigrationPlan.Move, location: inout LibraryMigrationState.Location,
                         root: String, migrationID: UUID, onlyStage: Bool) throws {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let old = rootURL.appendingPathComponent(move.oldRelativePath)
        let temp = payloadURL(root: root, id: migrationID).appendingPathComponent(move.tempName)
        let final = rootURL.appendingPathComponent(move.newRelativePath)
        if location == .original {
            if fm.fileExists(atPath: temp.path) { location = .staged }
            else if fm.fileExists(atPath: final.path), !fm.fileExists(atPath: old.path) { location = .final }
            else {
                guard fm.fileExists(atPath: old.path) else {
                    throw LibraryMigrationError.io("Source disappeared during migration: \(old.path)")
                }
                try fm.createDirectory(at: temp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try renameItem(old, temp)
                location = .staged
            }
        }
        guard !onlyStage, location == .staged else { return }
        guard !fm.fileExists(atPath: final.path) else {
            throw LibraryMigrationError.conflict("A file appeared at the planned destination: \(final.path)")
        }
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try renameItem(temp, final)
        location = .final
    }

    private func rollback(move: LibraryMigrationPlan.Move, location: inout LibraryMigrationState.Location,
                          root: String, migrationID: UUID) throws {
        guard location != .original else { return }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let old = rootURL.appendingPathComponent(move.oldRelativePath)
        let temp = payloadURL(root: root, id: migrationID).appendingPathComponent(move.tempName)
        let current = location == .final ? rootURL.appendingPathComponent(move.newRelativePath) : temp
        guard !fm.fileExists(atPath: old.path) else {
            throw LibraryMigrationError.conflict("Rollback can’t overwrite a new file at \(old.path)")
        }
        guard fm.fileExists(atPath: current.path) else {
            throw LibraryMigrationError.io("Rollback source is missing: \(current.path)")
        }
        try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try renameItem(current, old)
        location = .original
    }

    private func reconcileFilesystem(_ state: inout LibraryMigrationState) throws {
        for index in state.plan.moves.indices {
            state.moves[index].primary = try actualLocation(
                of: state.plan.moves[index], root: state.plan.primaryRoot, migrationID: state.plan.id)
            if let secondary = state.plan.secondaryRoot {
                state.moves[index].secondary = try actualLocation(
                    of: state.plan.moves[index], root: secondary, migrationID: state.plan.id)
            } else {
                state.moves[index].secondary = .final
            }
        }
        state.completedMoves = state.moves.filter { $0.primary == .final && $0.secondary == .final }.count
    }

    private func actualLocation(of move: LibraryMigrationPlan.Move, root: String,
                                migrationID: UUID) throws -> LibraryMigrationState.Location {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let candidates: [(LibraryMigrationState.Location, URL)] = [
            (.original, rootURL.appendingPathComponent(move.oldRelativePath)),
            (.staged, payloadURL(root: root, id: migrationID).appendingPathComponent(move.tempName)),
            (.final, rootURL.appendingPathComponent(move.newRelativePath)),
        ]
        let present = candidates.filter { fm.fileExists(atPath: $0.1.path) }
        guard present.count == 1, let location = present.first?.0 else {
            let paths = present.map { $0.1.path }.joined(separator: ", ")
            throw LibraryMigrationError.conflict(
                present.isEmpty
                    ? "A migration file is missing from every expected location: \(move.oldRelativePath)"
                    : "A migration file exists in more than one expected location: \(paths)")
        }
        return location
    }

    private func renameItem(_ source: URL, _ destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw LibraryMigrationError.io("Couldn’t rename \(source.path): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: Metadata

    private func updateMetadata(_ plan: LibraryMigrationPlan) async throws {
        let primary = URL(fileURLWithPath: plan.primaryRoot, isDirectory: true)
        let absolute = Dictionary(uniqueKeysWithValues: plan.moves.map {
            (primary.appendingPathComponent($0.oldRelativePath).path,
             primary.appendingPathComponent($0.newRelativePath).path)
        })
        let folderAbsolute = Dictionary(uniqueKeysWithValues: plan.folders.map {
            (primary.appendingPathComponent($0.oldRelativePath).path,
             primary.appendingPathComponent($0.newRelativePath).path)
        })

        let favoritesFile = supportURL("favorites.json")
        let pinsFile = supportURL("pinned-folders.json")
        let cullFile = supportURL("cull.json")
        if var favorites = JSONIO.loadGuarded([String].self, from: favoritesFile) {
            favorites = favorites.map { absolute[$0] ?? $0 }
            try JSONIO.saveDurable(favorites, to: favoritesFile)
        }
        if var pins = JSONIO.loadGuarded([String].self, from: pinsFile) {
            pins = pins.map { folderAbsolute[$0] ?? $0 }
            try JSONIO.saveDurable(pins, to: pinsFile)
        }
        if var cull = JSONIO.loadGuarded(CullData.self, from: cullFile) {
            cull.ratings = remapDictionary(cull.ratings, using: absolute)
            cull.flags = remapDictionary(cull.flags, using: absolute)
            try JSONIO.saveDurable(cull, to: cullFile)
        }

        let photos = PhotoIndex(file: supportURL("photo-index.json")); await photos.remapPaths(absolute); guard await photos.save() else { throw LibraryMigrationError.io("Couldn’t save photo index") }
        let faces = FaceIndex(file: supportURL("face-index.json")); await faces.remapPaths(absolute); guard await faces.save() else { throw LibraryMigrationError.io("Couldn’t save face index") }
        let identities = IdentityIndex(file: supportURL("identity-index.json")); await identities.remapPaths(absolute); guard await identities.save() else { throw LibraryMigrationError.io("Couldn’t save identity index") }

        let relative = Dictionary(uniqueKeysWithValues: plan.moves.map { ($0.oldRelativePath, $0.newRelativePath) })
        let historyFiles = (try? fm.contentsOfDirectory(at: supportURL("History", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
        for file in historyFiles where file.pathExtension == "json" {
            guard var record = JSONIO.loadGuarded(SessionRecord.self, from: file) else { continue }
            var changed = false
            for idx in record.files.indices {
                if let new = relative[record.files[idx].destRelPath] {
                    record.files[idx].destRelPath = new; changed = true
                }
            }
            if changed { try JSONIO.saveDurable(record, to: file) }
        }
        try? fm.removeItem(at: supportURL("library-index.json"))
    }

    private func backupMetadata(state: inout LibraryMigrationState) throws {
        let destination = backupDir(state.plan.id)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in metadataItems() where fm.fileExists(atPath: item.path) {
            let rel = relative(item, root: supportRoot)
            let target = destination.appendingPathComponent(rel)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: item, to: target)
            state.backedUpItems.append(rel)
        }
    }

    private func metadataItems() -> [URL] {
        [
            supportURL("config.json"), supportURL("favorites.json"), supportURL("pinned-folders.json"),
            supportURL("cull.json"), supportURL("photo-index.json"), supportURL("face-index.json"),
            supportURL("identity-index.json"), supportURL("library-index.json"),
            supportURL("folder-stats.json"), supportURL("History", isDirectory: true),
        ]
    }

    private func restoreMetadata(_ state: LibraryMigrationState) throws {
        let backup = backupDir(state.plan.id)
        let backedUp = Set(state.backedUpItems)
        // Exact snapshot semantics: a known metadata item that did not exist at
        // preflight must not be left behind if migration code created it.
        for item in metadataItems() {
            let rel = relative(item, root: supportRoot)
            if !backedUp.contains(rel), fm.fileExists(atPath: item.path) {
                try fm.removeItem(at: item)
            }
        }
        for rel in state.backedUpItems {
            let source = backup.appendingPathComponent(rel)
            let destination = supportRoot.appendingPathComponent(rel)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
        }
    }

    private func remapDictionary<T>(_ input: [String: T], using mapping: [String: String]) -> [String: T] {
        var result: [String: T] = [:]
        for (key, value) in input { result[mapping[key] ?? key] = value }
        return result
    }

    // MARK: Helpers

    private func save(_ state: inout LibraryMigrationState,
                      notify: (@Sendable (LibraryMigrationState) -> Void)?) throws {
        try JSONIO.saveDurable(state, to: stateFile)
        notify?(state)
    }

    private func notifyProgress(_ state: LibraryMigrationState, index: Int,
                                notify: (@Sendable (LibraryMigrationState) -> Void)?) {
        guard index == state.plan.moves.count || index.isMultiple(of: 25) else { return }
        notify?(state)
    }

    private func hasIncompleteSessions() -> Bool {
        let items = (try? fm.contentsOfDirectory(at: supportURL("Journal", isDirectory: true), includingPropertiesForKeys: nil)) ?? []
        return items.contains { $0.pathExtension == "json" }
    }

    private func uniqueLayouts(_ layouts: [DateFolderLayout]) -> [DateFolderLayout] {
        var seen = Set<String>(); var result: [DateFolderLayout] = []
        for layout in layouts where layout.validationError == nil {
            let key = layout.pattern
            if seen.insert(key).inserted { result.append(layout) }
        }
        return result
    }

    private func relative(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    private func normalized(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    private func payloadURL(root: String, id: UUID) -> URL {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".offload-migrations/\(id.uuidString)/payload", isDirectory: true)
    }
    private func backupDir(_ id: UUID) -> URL { backupsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func supportURL(_ name: String, isDirectory: Bool = false) -> URL {
        supportRoot.appendingPathComponent(name, isDirectory: isDirectory)
    }

    private func cleanupOldFolders(_ plan: LibraryMigrationPlan) {
        for root in [plan.primaryRoot, plan.secondaryRoot].compactMap({ $0 }) {
            let base = URL(fileURLWithPath: root, isDirectory: true)
            let paths = plan.folders.map { base.appendingPathComponent($0.oldRelativePath) }
                .sorted { $0.pathComponents.count > $1.pathComponents.count }
            for folder in paths { removeEmptyFolderAndParents(folder, stoppingAt: base) }
        }
    }

    /// `FileManager.removeItem` removes non-empty directories recursively, so
    /// explicitly prove each directory is empty before removing it. This keeps
    /// unrecognized files that happen to share an old date-folder ancestor safe.
    private func removeEmptyFolderAndParents(_ folder: URL, stoppingAt root: URL) {
        let rootPath = root.standardizedFileURL.path
        var candidate = folder.standardizedFileURL
        while candidate.path != rootPath, candidate.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fm.contentsOfDirectory(at: candidate,
                                                              includingPropertiesForKeys: nil),
                  contents.isEmpty else { return }
            do { try fm.removeItem(at: candidate) } catch { return }
            candidate.deleteLastPathComponent()
        }
    }

    private func cleanupMigrationDir(root: String, id: UUID) {
        let dir = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(".offload-migrations/\(id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: dir)
    }
}
