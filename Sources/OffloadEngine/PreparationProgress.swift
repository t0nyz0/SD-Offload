import Foundation
import OffloadCore

public enum PreparationStage: String, Sendable {
    case findingFiles, readingDates, matchingSavedProgress, checkingNAS, checkingSavedCopies, startingTransfer
}

/// Preparation has no honest overall percentage until the card inventory exists.
public struct PreparationProgress: Sendable, Equatable {
    public var stage: PreparationStage
    public var filesFound: Int
    public var bytesFound: Int64
    public var itemsDone: Int
    public var itemsTotal: Int
    public var currentPath: String?
    public var elapsed: TimeInterval
    public var secondsWithoutActivity: TimeInterval
    public var savedCopyCheck: VerificationProgress?

    public init(stage: PreparationStage = .findingFiles, filesFound: Int = 0, bytesFound: Int64 = 0,
                itemsDone: Int = 0, itemsTotal: Int = 0, currentPath: String? = nil,
                elapsed: TimeInterval = 0, secondsWithoutActivity: TimeInterval = 0,
                savedCopyCheck: VerificationProgress? = nil) {
        self.stage = stage; self.filesFound = filesFound; self.bytesFound = bytesFound
        self.itemsDone = itemsDone; self.itemsTotal = itemsTotal; self.currentPath = currentPath
        self.elapsed = elapsed; self.secondsWithoutActivity = secondsWithoutActivity
        self.savedCopyCheck = savedCopyCheck
    }
}

/// Workers update small counters only; one sampler emits at most four times per
/// second, including while a blocking card/NAS operation has stopped responding.
public final class PreparationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: PreparationStage = .findingFiles
    private var filesFound = 0, itemsDone = 0, itemsTotal = 0
    private var bytesFound: Int64 = 0
    private var currentPath: String?
    private var activeDates: [String: TimeInterval] = [:]
    private let started: TimeInterval
    private var lastActivity: TimeInterval
    private var checkingSavedCopy = false
    let savedCopyTracker = VerificationTracker()

    public init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        started = now; lastActivity = now
    }

    public func begin(_ stage: PreparationStage, total: Int = 0,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        self.stage = stage; itemsTotal = total; itemsDone = 0
        currentPath = nil; activeDates.removeAll(); lastActivity = now
        checkingSavedCopy = false
    }

    public func examining(_ path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        currentPath = path; lastActivity = now
    }

    public func foundFile(bytes: Int64, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        filesFound += 1; bytesFound += bytes; lastActivity = now
    }

    public func beginDate(_ path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        activeDates[path] = now; lastActivity = now
    }

    public func finishedItem(_ path: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        activeDates[path] = nil; itemsDone += 1; lastActivity = now
    }

    func beginSavedCopyCheck(_ files: [FileRecord]) {
        savedCopyTracker.reset(files: files, label: "Checking previous NAS copies")
        lock.lock(); defer { lock.unlock() }
        checkingSavedCopy = true; lastActivity = ProcessInfo.processInfo.systemUptime
    }

    public func snapshot(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PreparationProgress {
        lock.lock(); defer { lock.unlock() }
        let check = checkingSavedCopy ? savedCopyTracker.snapshot() : nil
        let wait = check.map { $0.secondsWithoutProgress } ?? max(0, now - lastActivity)
        return PreparationProgress(stage: stage, filesFound: filesFound, bytesFound: bytesFound,
            itemsDone: itemsDone, itemsTotal: itemsTotal,
            currentPath: check?.currentFile ?? activeDates.min(by: { $0.value < $1.value })?.key ?? currentPath,
            elapsed: max(0, now - started), secondsWithoutActivity: wait, savedCopyCheck: check)
    }
}
