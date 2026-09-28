# SD Offload code audit — September 28, 2026

Audited revision: `d53223cacb0a7be2c5a06fbed1f444710108ff76` (v1.7.12).

## Fix status

All eight findings and the five actionable performance follow-ups are addressed in v1.7.13. See [fix validation](FIX-VALIDATION.md) for regression evidence and remaining hardware-validation boundaries. The findings and original line references below describe the **pre-fix** v1.7.12 baseline.

## Original audit result

Six issues reproduced with disposable fixtures. Two affect file preservation. Two additional concurrency/recovery issues identified by source inspection. Existing passing tests do not cover these failure scenarios. No production source, settings, installed application, GitHub release, real card, or personal photo was modified. This is an audit report, not a fix release or an exhaustive guarantee.

## Reproduced findings

### 1. P1 — Different contents on the second destination are silently overwritten

`Sources/OffloadEngine/SessionRunner.swift:492–513`.

`copyToSecondary` accepts an existing hash match, but a mismatch or different size falls through to ordinary `rename`, which replaces the existing destination. This can destroy a unique older backup with the same date/name. A full SessionRunner fixture seeded an existing 22-byte second-destination file; the run replaced it with the incoming 16-byte file. This affects resume backfill as well as normal mirroring.

Fix direction: reserve a collision-free path across both destinations or block the transfer with an explicit collision error. Promotion must refuse replacement atomically; a prior file-exists check alone is not enough.

### 2. P1 — A source replaced after wipe approval can be deleted without being copied

`Sources/OffloadEngine/Wiper.swift:21–43`; `WipeGate.swift:31–34`.

The gate checks size and modification time, but the deletion plan carries only an ID and path. The final unlink loop rechecks only whether the path is a regular file. It does not compare the planned file's identity, size, or modification time. The loop also suspends for journal operations between files. If a file changes between approval and unlink, the replacement is removed although only the old contents were verified elsewhere. A fixture approved an 8-byte original, replaced it with longer new content, and confirmed the replacement was deleted.

Fix direction: carry and revalidate file identity/metadata immediately before removal; protect parent/card identity and fail closed on unexpected stat failures. Distinguish ENOENT from permission/I/O errors. Close remaining path races with a carefully designed deletion protocol rather than claiming an extra stat alone makes deletion atomic.

### 3. P2 — An unavailable or partial library scan can erase saved face assignments

`Sources/OffloadApp/Library/LibraryModel.swift:1030–1033`; `Sources/OffloadEngine/LibraryBrowser.swift:46–60`.

`allMedia` returns an empty/partial array on enumeration failure without indicating completeness. `findFaces` immediately uses that list to prune all missing face records. A disconnected NAS or unreadable subtree is therefore interpreted as deleted photos. Reproduced the same scan/prune sequence against an unavailable fixture root: an existing face-scan record was removed. Face assignments and rejections are stored in those records. This deletes metadata, not photo files.

Fix direction: return completion/error status and prune only after a successful complete scan. Forward cancellation into the enumeration and check it before pruning.

### 4. P2 — Failed index writes are treated as saved and are not retried

`Sources/OffloadCore/PhotoIndex.swift:171–174`; equivalent pattern in `FaceIndex.save` and `IdentityIndex.save`.

A failed JSON save is swallowed and `dirty` becomes false. A subsequent save after storage recovers returns without writing. Reproduced with a parent path temporarily blocked by a regular file, then repaired: the second save produced no index. AI results or identity edits may appear saved in memory and disappear on relaunch. Manual tag editing uses a separate throwing, transactional save and did not exhibit this failure.

Fix direction: clear dirty only after successful persistence, retain retryable changes, and report failures to the caller/UI.

### 5. P2 — Description search does not search descriptions

`Sources/OffloadCore/PhotoIndex.swift:60–61`.

`PhotoRecord.searchText` includes tags and filename, but omits `aiDescription`. README/UI advertise description search. An indexed description containing “lighthouse”, with a different filename and tags, returned no result for “lighthouse”.

Fix direction: include normalized description text in the search haystack and keep the cache invalidation already used by `setAI`.

### 6. P2 — Cancelling a queue consumer does not release its suspended task

`Sources/OffloadEngine/Pipeline.swift:29–32`; `Sources/OffloadEngine/SessionRunner.swift:145–149,979–990`.

`AsyncQueue.receive` parks an uncancellable continuation. Session cancellation cancels task handles and drains the pause/budget gates, but does not finish the three work queues. A worker waiting on an empty queue remains suspended; dropping its handle does not stop it. The fixture cancelled a queue waiter and it remained blocked until the test explicitly finished the queue. This can retain worker/session state across cancelled transfers. The primitive behavior is reproduced; whole-app retained-memory growth has not been measured.

Fix direction: cancellation-aware receiver registration/removal, or explicit queue shutdown plus joining workers during cancellation. Account for card reinsertion, which intentionally keeps parts of a session alive.

## Additional source-confirmed issues

### 7. P2 — Low staging space can leave a transfer waiting indefinitely

`Sources/OffloadEngine/Pipeline.swift:78–93,116–123`; `SessionRunner.swift:469–473`.

A reservation blocked by the free-space/headroom check waits only for another reservation release or drain. If no outstanding reservation remains, freeing disk space externally never wakes it. Retaining all staged copies increases the chance that a card larger than available staging space reaches this state. No timer, free-space notification, or visible disk-space wait is wired to this continuation. Not reproduced by exhausting this Mac's disk.

Fix direction: cancellable periodic free-space rechecks with an explicit waiting/error state; reconcile retention requirements with admission of large cards. Do not delete the only recovery copy as a shortcut.

### 8. P2 — Rapid favorites, ratings, and pinned-folder changes can persist out of order

`Sources/OffloadApp/Library/LibraryModel.swift:313–315,386–388,478–481`; related pattern in `FolderStatsLoader.swift:88`.

Each update starts an independent detached task with a full snapshot. Older snapshots may finish after newer snapshots and atomically replace them. Atomicity avoids a partial JSON file, but does not preserve update order. UI state can be correct until relaunch. Scheduling-dependent; no deterministic live-user-data stress test performed.

Fix direction: one serialized persistence owner per store, coalescing/debouncing and generation checks, plus a flush on termination where appropriate.

## Performance review follow-ups

- `LibraryModel` constructs three index actors synchronously on the main actor; their initializers perform full JSON loads and backup writes. Large indexes can block opening the Library. Measure 10k/100k-record startup and move disk hydration off-main.
- `AsyncQueue` drains an Array with `removeFirst`, shifting remaining elements for every item. Large manifests incur quadratic queue movement; use a head cursor/deque.
- `Journal.transition` searches and rewrites a value-type session/file array on each transition; the 10 Hz sampler also walks the full manifest. Profile large transfers before promising scale.
- Folder AI enumeration is launched in an untracked task before `analyzing` is set; repeated Analyze clicks can queue full scans, and Stop cannot cancel the initial enumeration.
- Thumbnail disk-cache trimming runs at initialization only; a long browsing session can grow beyond the advertised 500 MiB target until a later launch.
- Native video wrapper fix remains present. This audit did not reproduce the historical SwiftUI video crash on the current build.

These code patterns are review findings, not measured whole-app performance regressions. No new real SD-reader/SMB throughput, codec matrix, VoiceOver, sleep/wake, permission-dialog, login-item, or live provider/API tests were run in this audit.

## Verification and reproduction

- Standard suite: **124 passed, one opt-in live test skipped, zero failures** (125 discovered).
- Transfer harness: **all ten modes passed** using disposable directory fixtures; disk-image attachment was unavailable to the harness.
- Targeted audit suite: **six tests, six expected failures**, demonstrating the six reproduced findings above.
- No real removable device was erased. Secondary/wipe reproductions use only uniquely named temporary directories.

The test source is intentionally stored as `AuditReproductionTests.swift.txt` outside the normal test target so the unchanged production suite is not left broken. To reproduce from the repo root, copy it into `Tests/OffloadTests/AuditReproductionTests.swift`, run `swift test --filter AuditReproductionTests`, then remove that copied test file. Preserve it as regression coverage while fixing the underlying issues. Full captured output is in `reproduction-results.txt`.

Prioritize findings 1 and 2 before another release; then metadata integrity (3/4/8), transfer recovery (6/7), and search (5).
