import Foundation
import OffloadCore

/// One ingest session, end to end:
///
///   card ──[hop1 ×1]──▶ verifyQueue ──[verify ×2]──▶ uploadQueue ──[hop2 ×3]──▶ NAS
///          8 MiB chunks   SSD read-back              write+flush+rename+read-back
///          inline SHA-256 (F_NOCACHE)                 verify vs the SD-read hash
///
/// Wall-clock ≈ max(SD read, NAS write): every stage runs concurrently on a
/// different resource, and a file enters hop 2 the moment it staging-verifies.
/// Backpressure is byte-based (StagingBudget). The card is wiped only when the
/// WipeGate approves — strict all-or-nothing.
public actor SessionRunner {
    public let sessionID: UUID
    public let card: CardInfo
    let config: AppConfig
    let journal: Journal
    let staging: StagingStore
    let nas: NASLocator
    let cardWatcher: CardWatcher
    let emit: @Sendable (EngineEvent) -> Void
    let meter = SpeedMeter()
    let pauseGate = Gate()
    let budget: StagingBudget

    private var copyQueue = AsyncQueue<FileRecord>()
    private let verifyQueue = AsyncQueue<FileRecord>()
    private let uploadQueue = AsyncQueue<FileRecord>()

    private var totalFiles = 0
    private var settledFiles = 0
    private var hop1TotalBytes: Int64 = 0
    private var hop1BaseBytes: Int64 = 0      // past hop 1 at start (resume)
    private var hop2BaseBytes: Int64 = 0
    private var currentFileName: String?
    private var hop1Tasks: [Task<Void, Never>] = []
    private var otherTasks: [Task<Void, Never>] = []
    private var samplerTask: Task<Void, Never>?
    private var allSettledContinuation: CheckedContinuation<Void, Never>?
    private var wipeConsentContinuation: CheckedContinuation<Bool, Never>?
    private var power: PowerAssertion?
    private var cardPresent = true
    private var userPaused = false
    private var cancelled = false
    private var wipeCancelled = false
    private var waitingForNAS = false
    private var sessionStartedAt = Date()

    public init(sessionID: UUID, card: CardInfo, config: AppConfig, journal: Journal,
                staging: StagingStore, nas: NASLocator, cardWatcher: CardWatcher,
                emit: @escaping @Sendable (EngineEvent) -> Void) {
        self.sessionID = sessionID
        self.card = card
        self.config = config
        self.journal = journal
        self.staging = staging
        self.nas = nas
        self.cardWatcher = cardWatcher
        self.emit = emit
        self.budget = StagingBudget(stagingPath: config.stagingRootPath,
                                    capBytes: config.stagingBudgetCapBytes,
                                    headroomBytes: config.stagingHeadroomBytes)
    }

    // MARK: - Lifecycle

    public func run() async {
        guard let record = await journal.session(id: sessionID) else { return }
        sessionStartedAt = Date()
        power = PowerAssertion(reason: "Offloading \(card.volumeName)")
        defer { power?.end() }

        totalFiles = record.files.count
        hop1TotalBytes = record.files.reduce(0) { $0 + $1.size }
        for file in record.files {
            if file.state.isPastStaging { hop1BaseBytes += file.size }
            if file.state.isWipeEligible { hop2BaseBytes += file.size }
        }

        await markPhase("transfer")
        await journal.setSessionState(.transferring, in: sessionID)
        emit(.phase(.transferring))

        // Preload queues by journal state (fresh session: everything pending).
        for file in record.files {
            switch file.state {
            case .pending:
                await copyQueue.send(file)
            case .staged:
                await verifyQueue.send(file)
            case .stagedVerified, .uploaded:
                await uploadQueue.send(file)
            case .nasVerified, .skippedDuplicate, .wiped, .failed:
                settledFiles += 1
            case .copying, .uploading:
                // Journal crash-remap removes these; belt and braces.
                await copyQueue.send(file)
            }
        }

        startSampler()
        if settledFiles < totalFiles {
            spawnHop1Workers()
            spawnPipelineWorkers()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                allSettledContinuation = cont
            }
        }
        stopWorkers()
        samplerTask?.cancel()

        await markPhaseEnd("transfer")
        await wrapUp()
    }

    private func spawnHop1Workers() {
        for _ in 0..<max(1, config.hop1Workers) {
            hop1Tasks.append(Task { await self.hop1Worker() })
        }
    }

    private func spawnPipelineWorkers() {
        for _ in 0..<2 {
            otherTasks.append(Task { await self.verifyWorker() })
        }
        for _ in 0..<max(1, config.hop2Workers) {
            otherTasks.append(Task { await self.hop2Worker() })
        }
    }

    private func stopWorkers() {
        for task in hop1Tasks + otherTasks { task.cancel() }
        hop1Tasks.removeAll()
        otherTasks.removeAll()
    }

    private func settle() {
        settledFiles += 1
        if settledFiles >= totalFiles {
            let cont = allSettledContinuation
            allSettledContinuation = nil
            Task {
                await copyQueue.finish()
                await verifyQueue.finish()
                await uploadQueue.finish()
            }
            cont?.resume()
        }
    }

    private func setCurrentFile(_ name: String?) { currentFileName = name }

    // MARK: - Hop 1: card → staging

    private nonisolated func hop1Worker() async {
        while let file = await copyQueue.receive() {
            await pauseGate.whenOpen()
            if Task.isCancelled { return }
            do {
                try await stageOne(file)
            } catch is CancellationError {
                // Cancelled mid-file (user cancel or card gone): partial is
                // already unlinked by ChunkedIO; roll the state back.
                await journal.transition(file: file.id, to: .pending, in: sessionID)
                await budget.release(file.id)
                return
            } catch {
                await budget.release(file.id)
                await handleHop1Error(file, error)
            }
        }
    }

    private nonisolated func stageOne(_ file: FileRecord) async throws {
        let started = Date()
        await budget.reserve(file.id, file.size)
        await journal.transition(file: file.id, to: .copying, in: sessionID)
        await setCurrentFile(file.fileName)

        let src = URL(fileURLWithPath: card.mountPath).appendingPathComponent(file.relPath)
        try staging.ensureSessionDir(sessionID)
        let partial = staging.partialURL(session: sessionID, file: file)
        let stagedURL = staging.stagedURL(session: sessionID, file: file)

        var options = ChunkedIO.CopyOptions()
        // Staging durability is only safety-critical when the card is wiped
        // before the NAS leg (staged copy becomes the only copy).
        options.fullFsync = (config.wipePolicy == .afterStagingVerify)

        let meter = self.meter
        let result = try await ChunkedIO.copyAndHash(from: src, to: partial, options: options,
                                                     gate: pauseGate) { meter.addBytes($0, stage: .sdRead) }
        guard result.bytes == file.size else {
            try? FileManager.default.removeItem(at: partial)
            throw OffloadError(.sourceChangedDuringCopy)
        }
        guard rename(partial.path, stagedURL.path) == 0 else {
            let err = errno
            try? FileManager.default.removeItem(at: partial)
            throw OffloadError.posix(err, stage: "rename staged")
        }

        await journal.setSourceHash(file: file.id, hex: result.sha256Hex, in: sessionID)
        await journal.transition(file: file.id, to: .staged, in: sessionID)
        meter.fileCompleted(stage: .sdRead, wall: Date().timeIntervalSince(started), size: file.size)

        var updated = file
        updated.sourceHashHex = result.sha256Hex
        updated.state = .staged
        await verifyQueue.send(updated)
    }

    private func handleHop1Error(_ file: FileRecord, _ error: Error) async {
        let failure = (error as? OffloadError)?.failure ?? .internalError("\(error)")

        if case .ioError(let err, _) = failure, RetryPolicy.isSourceGone(err), !cardPresent {
            // Card was yanked: roll back and wait for re-insert (the controller
            // re-scans and calls cardReturned).
            await journal.transition(file: file.id, to: .pending, in: sessionID)
            return
        }

        let attempts = file.attempts + 1
        await journal.bumpAttempts(file: file.id, in: sessionID)

        var retryable = false
        if case .ioError(let err, _) = failure { retryable = RetryPolicy.isTransient(err) }
        if case .sourceChangedDuringCopy = failure { retryable = attempts < 2 }

        if retryable && attempts < RetryPolicy.maxAttempts {
            await journal.transition(file: file.id, to: .pending, in: sessionID)
            try? await Task.sleep(for: .seconds(RetryPolicy.backoffSeconds(attempt: attempts)))
            var updated = file
            updated.attempts = attempts
            updated.state = .pending
            await copyQueue.send(updated)
        } else {
            await journal.transition(file: file.id, to: .failed(failure), in: sessionID)
            emit(.attention(AttentionItem(severity: .warning,
                                          title: "Couldn't copy \(file.fileName)",
                                          detail: failure.summary)))
            settle()
        }
    }

    // MARK: - Staging verify

    private nonisolated func verifyWorker() async {
        while let file = await verifyQueue.receive() {
            await pauseGate.whenOpen()
            if Task.isCancelled { return }
            let stagedURL = staging.stagedURL(session: sessionID, file: file)
            do {
                let meter = self.meter
                let hash = try await ChunkedIO.hashFile(stagedURL, noCache: true, gate: pauseGate) {
                    meter.addBytes($0, stage: .stagingVerify)
                }
                if let source = file.sourceHashHex, hash == source {
                    await journal.transition(file: file.id, to: .stagedVerified, in: sessionID)
                    meter.fileCompleted(stage: .stagingVerify, wall: 0, size: file.size)
                    var updated = file
                    updated.state = .stagedVerified
                    await uploadQueue.send(updated)
                } else {
                    // Staged bytes don't match what we read from the card —
                    // purge and re-copy (attempts guard applies).
                    staging.purgeFile(session: sessionID, file: file)
                    await budget.release(file.id)
                    await journal.transition(file: file.id, to: .pending, in: sessionID)
                    await handleVerifyMismatch(file, stage: "staging verification")
                }
            } catch is CancellationError {
                return
            } catch {
                staging.purgeFile(session: sessionID, file: file)
                await budget.release(file.id)
                await journal.transition(file: file.id, to: .pending, in: sessionID)
                await handleVerifyMismatch(file, stage: "staging verification")
            }
        }
    }

    private func handleVerifyMismatch(_ file: FileRecord, stage: String) async {
        let attempts = file.attempts + 1
        await journal.bumpAttempts(file: file.id, in: sessionID)
        if attempts < RetryPolicy.maxAttempts {
            var updated = file
            updated.attempts = attempts
            updated.state = .pending
            await copyQueue.send(updated)
        } else {
            await journal.transition(file: file.id, to: .failed(.hashMismatch(stage: stage)), in: sessionID)
            emit(.attention(AttentionItem(severity: .error,
                                          title: "Checksum mismatch: \(file.fileName)",
                                          detail: "Re-copies kept failing \(stage). The card will NOT be wiped.")))
            settle()
        }
    }

    // MARK: - Hop 2: staging → NAS

    private nonisolated func hop2Worker() async {
        while let file = await uploadQueue.receive() {
            await pauseGate.whenOpen()
            if Task.isCancelled { return }
            do {
                try await uploadOne(file)
            } catch is CancellationError {
                if file.state == .stagedVerified {
                    // roll back a possible in-flight .uploading mark
                    await journal.transition(file: file.id, to: .stagedVerified, in: sessionID)
                }
                return
            } catch {
                await handleHop2Error(file, error)
            }
        }
    }

    private nonisolated func uploadOne(_ file: FileRecord) async throws {
        guard let sourceHash = file.sourceHashHex else {
            // Should not happen (hash is a milestone flush) — recover by re-copy.
            await budget.release(file.id)   // free this file's reservation; stageOne re-reserves
            await journal.transition(file: file.id, to: .pending, in: sessionID)
            await copyQueue.send(FileRecord(id: file.id, relPath: file.relPath, size: file.size,
                                            mtime: file.mtime, creationDate: file.creationDate,
                                            captureDate: file.captureDate, destRelPath: file.destRelPath,
                                            state: .pending, attempts: file.attempts, stateChangedAt: Date()))
            return
        }

        let nasRoot = try await waitForHealthyNAS()
        let started = Date()
        let stagedURL = staging.stagedURL(session: sessionID, file: file)
        var destRelPath = file.destRelPath
        var destURL = nasRoot.appendingPathComponent(destRelPath)
        let fm = FileManager.default

        if file.state != .uploaded {
            await journal.transition(file: file.id, to: .uploading, in: sessionID)
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Destination collision: same size ⇒ hash the existing NAS file
            // (that read IS a verify pass); equal ⇒ hash-proven duplicate.
            // Uncached: a match here marks the file skippedDuplicate → wipe-
            // eligible, so it must read the server's real bytes, not our cache.
            if fm.fileExists(atPath: destURL.path) {
                let existingSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                if existingSize == file.size {
                    let meter = self.meter
                    let existingHash = try await ChunkedIO.hashFile(destURL, noCache: true, gate: pauseGate) {
                        meter.addBytes($0, stage: .nasVerify)
                    }
                    if existingHash == sourceHash {
                        await journal.transition(file: file.id, to: .skippedDuplicate, in: sessionID)
                        await finishFile(file)
                        return
                    }
                }
                // Different content — find a free " (n)" name.
                var attempt = 2
                let base = file.destRelPath
                repeat {
                    destRelPath = CollisionPolicy.suffixed(base, attempt: attempt)
                    destURL = nasRoot.appendingPathComponent(destRelPath)
                    attempt += 1
                } while fm.fileExists(atPath: destURL.path)
                await journal.setDestRelPath(file: file.id, rel: destRelPath, in: sessionID)
            }

            // Data-fork-only write via a hidden partial, then atomic rename.
            let partialURL = destURL.deletingLastPathComponent()
                .appendingPathComponent(".offload-\(file.id.uuidString).partial")
            var options = ChunkedIO.CopyOptions()
            options.preallocate = false   // smbfs returns ENOTSUP; skip the wasted fcntl per file
            let meter = self.meter
            let result = try await ChunkedIO.copyAndHash(from: stagedURL, to: partialURL, options: options,
                                                         gate: pauseGate) { meter.addBytes($0, stage: .nasWrite) }
            // Bonus integrity: the bytes we just read from staging must still
            // hash to the SD-read hash. Staging rot ⇒ re-copy from the card.
            guard result.sha256Hex == sourceHash else {
                try? fm.removeItem(at: partialURL)
                staging.purgeFile(session: sessionID, file: file)
                await budget.release(file.id)
                await journal.transition(file: file.id, to: .pending, in: sessionID)
                await handleVerifyMismatch(file, stage: "staging re-read")
                return
            }
            guard rename(partialURL.path, destURL.path) == 0 else {
                let err = errno
                try? fm.removeItem(at: partialURL)
                throw OffloadError.posix(err, stage: "rename on NAS")
            }
            var values = URLResourceValues()
            values.contentModificationDate = file.mtime
            var mutableURL = destURL
            try? mutableURL.setResourceValues(values)

            await journal.transition(file: file.id, to: .uploaded, in: sessionID)
            meter.fileCompleted(stage: .nasWrite, wall: Date().timeIntervalSince(started), size: file.size)
        } else {
            destURL = nasRoot.appendingPathComponent(file.destRelPath)
        }

        // END-TO-END verify: read the uploaded file back and compare against the
        // ORIGINAL SD-read hash. This read is ALWAYS uncached (F_NOCACHE). fsync
        // flushes our dirty pages to the server, but it does NOT invalidate the
        // client read cache — a cached read here would re-hash the very bytes we
        // just wrote out of the SMB/OS page cache, "verifying" our own memory
        // instead of the server's stored copy. Since this verdict gates wiping
        // the card, it must be a genuine server read-back. (Uncached is the
        // correct, sufficient mechanism over smbfs; deeper on-platter durability
        // isn't reachable there — F_FULLFSYNC is ENOTSUP.)
        let verifyStarted = Date()
        let meter = self.meter
        let nasHash = try await ChunkedIO.hashFile(destURL, noCache: true, gate: pauseGate) {
            meter.addBytes($0, stage: .nasVerify)
        }
        if nasHash == sourceHash {
            await journal.transition(file: file.id, to: .nasVerified, in: sessionID)
            meter.fileCompleted(stage: .nasVerify, wall: Date().timeIntervalSince(verifyStarted), size: file.size)
            await finishFile(file)
        } else {
            // One re-upload from staging; if that fails again the file is
            // failed and the card is NEVER wiped.
            try? fm.removeItem(at: destURL)
            let attempts = file.attempts + 1
            await journal.bumpAttempts(file: file.id, in: sessionID)
            await journal.transition(file: file.id, to: .stagedVerified, in: sessionID)
            if attempts < RetryPolicy.maxAttempts {
                var updated = file
                updated.attempts = attempts
                updated.state = .stagedVerified
                await uploadQueue.send(updated)
            } else {
                await journal.transition(file: file.id, to: .failed(.hashMismatch(stage: "NAS verification")), in: sessionID)
                emit(.attention(AttentionItem(severity: .error,
                                              title: "NAS verification failed: \(file.fileName)",
                                              detail: "The NAS copy never matched the card. The card will NOT be wiped.")))
                await settle()
            }
        }
    }

    private func finishFile(_ file: FileRecord) {
        if config.keepStagedDays == 0 {
            staging.purgeFile(session: sessionID, file: file)
        }
        Task { await budget.release(file.id) }
        settle()
    }

    private nonisolated func waitForHealthyNAS() async throws -> URL {
        let emit = self.emit
        let runner = self
        return try await nas.ensureMountedAndHealthy { health in
            Task { await runner.noteWaitingForNAS(health) }
            _ = emit   // captured for the ghost attention below
        }
    }

    private func noteWaitingForNAS(_ health: NASHealth) async {
        guard !waitingForNAS else { return }
        waitingForNAS = true
        await journal.setSessionState(.waitingForNAS, in: sessionID)
        emit(.phase(.waitingForNAS))
        if case .ghostLocalFolder = health {
            emit(.attention(AttentionItem(severity: .error,
                                          title: "NAS path is a local folder",
                                          detail: "\(config.nasRootPath) exists but the share is not mounted — refusing to write. Remount the share and Offload resumes automatically.")))
        } else {
            emit(.attention(AttentionItem(severity: .info,
                                          title: "Waiting for the NAS",
                                          detail: "Copying off the card continues; uploads resume when \(config.nasRootPath) is back.")))
        }
    }

    private func handleHop2Error(_ file: FileRecord, _ error: Error) async {
        let failure = (error as? OffloadError)?.failure ?? .internalError("\(error)")
        if case .ioError(let err, _) = failure,
           RetryPolicy.isDestinationGone(err) || RetryPolicy.isOutOfSpace(err) {
            // Roll back and re-queue; the worker will park on NAS health.
            await journal.transition(file: file.id, to: .stagedVerified, in: sessionID)
            if RetryPolicy.isOutOfSpace(err) {
                emit(.attention(AttentionItem(severity: .error, title: "NAS is out of space",
                                              detail: "Uploads paused. Free space on the share to continue.")))
                try? await Task.sleep(for: .seconds(30))
            }
            var updated = file
            updated.state = .stagedVerified
            await uploadQueue.send(updated)
            return
        }

        let attempts = file.attempts + 1
        await journal.bumpAttempts(file: file.id, in: sessionID)
        if attempts < RetryPolicy.maxAttempts {
            await journal.transition(file: file.id, to: .stagedVerified, in: sessionID)
            try? await Task.sleep(for: .seconds(RetryPolicy.backoffSeconds(attempt: attempts)))
            var updated = file
            updated.attempts = attempts
            updated.state = .stagedVerified
            await uploadQueue.send(updated)
        } else {
            await journal.transition(file: file.id, to: .failed(failure), in: sessionID)
            emit(.attention(AttentionItem(severity: .error,
                                          title: "Couldn't upload \(file.fileName)",
                                          detail: failure.summary)))
            settle()
        }
    }

    // MARK: - Sampler (10 Hz)

    private func startSampler() {
        samplerTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleAndEmit(tick: tick)
                tick += 1
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sampleAndEmit(tick: Int) async {
        meter.sample()
        guard let record = await journal.session(id: sessionID) else { return }

        var snapshot = ProgressSnapshot()
        snapshot.hop1BytesTotal = hop1TotalBytes
        snapshot.hop2BytesTotal = hop1TotalBytes
        snapshot.hop1BytesDone = min(hop1TotalBytes, hop1BaseBytes + meter.bytesTotal(.sdRead))
        snapshot.hop2BytesDone = min(hop1TotalBytes, hop2BaseBytes + meter.bytesTotal(.nasWrite))
        snapshot.filesTotal = totalFiles
        snapshot.filesSettled = settledFiles
        snapshot.currentFileName = currentFileName
        snapshot.sdReadBps = meter.rate(.sdRead)
        snapshot.nasWriteBps = meter.rate(.nasWrite)

        // Remaining work per stage, from journal states.
        var sdRemaining: Int64 = 0, sdFiles = 0
        var svRemaining: Int64 = 0, svFiles = 0
        var nwRemaining: Int64 = 0, nwFiles = 0
        for file in record.files {
            switch file.state {
            case .pending, .copying:
                sdRemaining += file.size; sdFiles += 1
                svRemaining += file.size; svFiles += 1
                nwRemaining += file.size; nwFiles += 1
            case .staged:
                svRemaining += file.size; svFiles += 1
                nwRemaining += file.size; nwFiles += 1
            case .stagedVerified, .uploading:
                nwRemaining += file.size; nwFiles += 1
            case .uploaded, .nasVerified, .skippedDuplicate, .wiped, .failed:
                break
            }
        }
        // Subtract in-flight partial progress where the counters run ahead of states.
        sdRemaining = max(0, hop1TotalBytes - hop1BaseBytes - meter.bytesTotal(.sdRead))

        // The pipeline's wall-clock is governed by its two continuously-active,
        // throughput-bound stages — card read and NAS write. The verify stages
        // overlap their writes and are captured by the last-file tail below.
        // Do NOT fold a verify stage into this max(): verification runs in
        // bursts, so its EWMA rate decays toward zero between bursts, and
        // B/rate then explodes into a nonsense multi-thousand-hour ETA.
        let rSD = ETAMath.stageRemaining(bytesRemaining: sdRemaining, filesRemaining: sdFiles,
                                         rate: meter.rate(.sdRead), overheadSeconds: meter.overheadSeconds(.sdRead),
                                         workers: max(1, config.hop1Workers))
        let rSV = ETAMath.stageRemaining(bytesRemaining: svRemaining, filesRemaining: svFiles,
                                         rate: meter.rate(.stagingVerify), overheadSeconds: meter.overheadSeconds(.stagingVerify),
                                         workers: 2)
        let rNW = ETAMath.stageRemaining(bytesRemaining: nwRemaining, filesRemaining: nwFiles,
                                         rate: meter.rate(.nasWrite), overheadSeconds: meter.overheadSeconds(.nasWrite),
                                         workers: max(1, config.hop2Workers))

        // Last-file drain: after the final byte lands on the NAS it still has to
        // be read back and hashed. Approximate read-back throughput by the write
        // rate (SMB read-back is at least as fast as write) rather than the
        // bursty nasVerify EWMA, which is ~0 between bursts and would blow the
        // tail up the same way a verify max() term would.
        var tail: TimeInterval = 0
        if nwFiles > 0, let rw = meter.rate(.nasWrite), rw > 0 {
            let meanSize = Double(nwRemaining) / Double(max(1, nwFiles))
            tail = meter.overheadSeconds(.nasWrite) + meter.overheadSeconds(.nasVerify) + meanSize * (2 / rw)
        }

        let allSafeRaw = ETAMath.clampETA(ETAMath.pipelineETA(stages: [rSD, rNW], tail: tail))
        let wipeTime = Double(totalFiles) * 0.005 + Double(config.wipeCountdownSeconds)
        let cardFreeRaw: TimeInterval?
        switch config.wipePolicy {
        case .afterStagingVerify:
            if let rSD, let rSV {
                cardFreeRaw = ETAMath.clampETA(max(rSD, rSV) + wipeTime)
            } else {
                cardFreeRaw = nil
            }
        case .afterNASVerify, .askEachTime:
            cardFreeRaw = allSafeRaw.map { $0 + wipeTime }
        }
        let (cardFree, allSafe) = meter.smoothedETAs(cardFree: cardFreeRaw, allSafe: allSafeRaw, dt: 0.1)
        snapshot.etaCardFree = cardFree
        snapshot.etaAllSafe = allSafe

        emit(.progress(snapshot))
        if tick % 10 == 0, let sample = meter.latestSample() {
            emit(.speedSample(sample))
        }
    }

    // MARK: - Wrap-up + wipe

    private func wrapUp() async {
        guard let record = await journal.session(id: sessionID) else { return }

        if cancelled {
            staging.purgeSession(sessionID)
            await finalize(state: .cancelled, record: record)
            return
        }

        let failedFiles = record.files.filter { if case .failed = $0.state { return true }; return false }
        if !failedFiles.isEmpty {
            let blockers = failedFiles.map { file -> String in
                if case .failed(let why) = file.state { return "\(file.relPath): \(why.summary)" }
                return file.relPath
            }
            await journal.setWipeReport(WipeReport(ran: false, blockers: blockers, finishedAt: Date()), in: sessionID)
            emit(.attention(AttentionItem(severity: .error,
                                          title: "\(failedFiles.count) of \(totalFiles) files failed",
                                          detail: "Everything else is verified on the NAS. Your card has NOT been wiped.")))
            await finalize(state: .doneWipeBlocked, record: record)
            return
        }

        // Wipe consent per policy.
        var proceed = true
        switch config.wipePolicy {
        case .askEachTime:
            await journal.setSessionState(.awaitingWipeConsent, in: sessionID)
            emit(.phase(.awaitingWipeConsent))
            proceed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                wipeConsentContinuation = cont
            }
        case .afterNASVerify, .afterStagingVerify:
            if config.wipeCountdownSeconds > 0 {
                await journal.setSessionState(.wipeCountdown, in: sessionID)
                emit(.phase(.wipeCountdown))
                for second in stride(from: config.wipeCountdownSeconds, through: 1, by: -1) {
                    if wipeCancelled { proceed = false; break }
                    emit(.wipeCountdown(secondsRemaining: second))
                    try? await Task.sleep(for: .seconds(1))
                }
                if wipeCancelled { proceed = false }
            }
        }

        guard proceed else {
            await journal.setWipeReport(WipeReport(ran: false, blockers: ["declined by user"], finishedAt: Date()), in: sessionID)
            if let record = await journal.session(id: sessionID) {
                await finalize(state: .done, record: record)
            }
            return
        }

        await executeWipe()
    }

    private func executeWipe() async {
        await markPhase("wipe")
        try? await journal.flushNow(sessionID)
        guard let record = await journal.session(id: sessionID) else { return }

        let cardSnapshot: WipeGate.CardMountSnapshot? = {
            guard cardPresent, let fs = statfsInfo(path: card.mountPath) else { return nil }
            return WipeGate.CardMountSnapshot(volumeUUID: card.volumeUUID,
                                              rootPath: card.mountPath,
                                              isReadOnly: fs.isReadOnly)
        }()
        let nasHealth = await nas.validateNow(force: true)
        let markerURL = URL(fileURLWithPath: card.mountPath).appendingPathComponent(Paths.cardSessionMarkerName)
        let cardTokenOnCard = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let verdict = WipeGate.evaluate(session: record,
                                        policy: config.wipePolicy,
                                        cardMount: cardSnapshot,
                                        nasHealth: nasHealth,
                                        statOf: WipeGate.liveStat,
                                        journalFlushed: true,
                                        cardTokenOnCard: cardTokenOnCard)

        guard verdict.allowed else {
            let blockers = verdict.blockers.map(\.description)
            await journal.setWipeReport(WipeReport(ran: false, blockers: blockers, finishedAt: Date()), in: sessionID)
            emit(.attention(AttentionItem(severity: .warning,
                                          title: "Card not wiped",
                                          detail: blockers.first ?? "wipe preconditions not met")))
            await markPhaseEnd("wipe")
            if let record = await journal.session(id: sessionID) {
                await finalize(state: .doneWipeBlocked, record: record)
            }
            return
        }

        await journal.setSessionState(.wiping, in: sessionID)
        emit(.phase(.wiping))
        let result = await Wiper.execute(deletions: verdict.deletions, journal: journal,
                                         sessionID: sessionID, fileIDs: [:])

        if let stopped = result.stoppedEarly {
            await journal.setWipeReport(WipeReport(ran: true, filesDeleted: result.filesDeleted,
                                                   blockers: [stopped], finishedAt: Date()), in: sessionID)
            emit(.attention(AttentionItem(severity: .warning,
                                          title: "Wipe stopped early",
                                          detail: "\(result.filesDeleted) files removed, then: \(stopped). Everything is safe on the NAS.")))
            await markPhaseEnd("wipe")
            if let record = await journal.session(id: sessionID) {
                await finalize(state: .doneWipeBlocked, record: record)
            }
            return
        }

        Wiper.pruneEmptyDirectories(deletions: verdict.deletions, cardRoot: card.mountPath)
        try? FileManager.default.removeItem(at: markerURL)   // clean our session marker off the emptied card
        await journal.setWipeReport(WipeReport(ran: true, filesDeleted: result.filesDeleted,
                                               blockers: [], finishedAt: Date()), in: sessionID)
        await markPhaseEnd("wipe")

        if config.autoEject {
            await markPhase("eject")
            await journal.setSessionState(.ejecting, in: sessionID)
            emit(.phase(.ejecting))
            try? await cardWatcher.unmountAndEject(bsdName: card.bsdName)
            await markPhaseEnd("eject")
        }
        emit(.safeToRemove(cardName: card.volumeName))

        if let record = await journal.session(id: sessionID) {
            await finalize(state: .done, record: record)
        }
    }

    private func finalize(state: SessionState, record: SessionRecord) async {
        let finals = meter.finals()
        await journal.updateStats(in: sessionID) { stats in
            stats.avgSDReadBps = finals.avgSDReadBps
            stats.peakSDReadBps = finals.peakSDReadBps
            stats.avgNASWriteBps = finals.avgNASWriteBps
            stats.peakNASWriteBps = finals.peakNASWriteBps
            stats.timeline = finals.timeline
            stats.bytesRead = self.meter.bytesTotal(.sdRead)
            stats.bytesUploaded = self.meter.bytesTotal(.nasWrite)
        }
        await journal.setEnded(in: sessionID)
        await journal.setSessionState(state, in: sessionID)
        let finalRecord = await journal.session(id: sessionID) ?? record
        try? await journal.complete(sessionID)

        switch state {
        case .done:
            emit(.completed(finalRecord))
            emit(.phase(.done))
        case .doneWipeBlocked:
            emit(.completed(finalRecord))
            emit(.phase(.doneWipeBlocked))
        case .cancelled:
            emit(.phase(.cancelled))
        default:
            emit(.phase(.failed))
        }
    }

    private func markPhase(_ name: String) async {
        await journal.updateStats(in: sessionID) { stats in
            stats.phases.append(PhaseSpan(name: name))
        }
    }

    private func markPhaseEnd(_ name: String) async {
        await journal.updateStats(in: sessionID) { stats in
            if let idx = stats.phases.lastIndex(where: { $0.name == name && $0.end == nil }) {
                stats.phases[idx].end = Date()
            }
        }
    }

    // MARK: - External control (via EngineController)

    public func pause() async {
        guard !userPaused else { return }
        userPaused = true
        await pauseGate.close()
        await journal.setSessionState(.pausedByUser, in: sessionID)
        emit(.phase(.pausedByUser))
    }

    public func resume() async {
        guard userPaused else { return }
        userPaused = false
        await pauseGate.open()
        await journal.setSessionState(.transferring, in: sessionID)
        emit(.phase(.transferring))
    }

    public func cancel() async {
        cancelled = true
        wipeCancelled = true
        stopWorkers()
        wipeConsentContinuation?.resume(returning: false)
        wipeConsentContinuation = nil
        await pauseGate.open()   // let cancelled workers unwind
        await budget.drain()     // wake any worker parked in reserve()
        // Unblock run() if it is waiting on settlement.
        allSettledContinuation?.resume()
        allSettledContinuation = nil
    }

    public func cardGone() async {
        cardPresent = false
        for task in hop1Tasks { task.cancel() }
        hop1Tasks.removeAll()
        await budget.drain()     // wake hop-1 workers parked in reserve() so they exit
        await journal.setSessionState(.pausedCardGone, in: sessionID)
        emit(.phase(.pausedCardGone))
    }

    /// Card re-inserted: the controller has already re-scanned and merged the
    /// manifest into the journal. Rebuild the copy queue from journal state.
    public func cardReturned() async {
        cardPresent = true
        await budget.resumeReservations()
        guard let record = await journal.session(id: sessionID) else { return }
        totalFiles = record.files.count
        settledFiles = record.files.filter { $0.state.isTerminal }.count
        hop1TotalBytes = record.files.reduce(0) { $0 + $1.size }

        copyQueue = AsyncQueue<FileRecord>()
        for file in record.files where file.state == .pending {
            await copyQueue.send(file)
        }
        spawnHop1Workers()
        await journal.setSessionState(.transferring, in: sessionID)
        emit(.phase(.transferring))
        if settledFiles >= totalFiles {
            allSettledContinuation?.resume()
            allSettledContinuation = nil
        }
    }

    public func confirmWipe() {
        wipeConsentContinuation?.resume(returning: true)
        wipeConsentContinuation = nil
    }

    public func cancelWipe() {
        wipeCancelled = true
        wipeConsentContinuation?.resume(returning: false)
        wipeConsentContinuation = nil
    }

    public func ejectCard() async {
        try? await cardWatcher.unmountAndEject(bsdName: card.bsdName)
    }
}
