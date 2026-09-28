# v1.7.13 audit fix validation

## Scope and results

All eight audit findings were fixed. The original six reproductions failed against v1.7.12 and now pass as permanent regression tests. Low-space recovery and ordered persistence also have direct regression coverage. The five actionable performance follow-ups were implemented; the historical native-video crash fix remains intact.

- Automated suite: **143 passed, one optional live-provider test skipped, zero failures** (144 discovered).
- Transfer integration: ten disposable-directory harness modes, including secondary-drive failures, crash resume, wrong card, and final destination damage.
- Release build succeeded. Isolated native UI smoke test verified Library browsing, labeled viewer controls, editing/searching a fixture tag, and favorite/rating persistence after graceful quit and relaunch.
- No real card erasure, personal photo edits, or live AI submissions were used.

## Coverage by finding

| Finding | Fix and verification |
| --- | --- |
| Backup collision | Exclusive promotion on both destinations. Different secondary contents stop the transfer with an actionable error. Fixture verifies both existing backup and source remain unchanged. Matching secondary copies pass the transfer harness. |
| Changed source before erasure | Directory-descriptor anchored exclusive claim; inode/device, size, timestamp, and SHA-256 validation before unlink. Tests cover unchanged deletion, same-size/same-timestamp edits, symlink replacement, and interrupted recovery with an occupied original name. Unexpected stat errors fail closed. |
| Incomplete face scan | Throwing, cancellable inventory; prune only on completion. Offline root preserves metadata; complete scan removes only missing entries. macOS /var versus /private/var aliases remain equivalent for preservation. |
| Failed index save | Dirty state clears only on success. Photo, face, and identity indexes retry after storage recovery. Library displays save errors and a Retry Save action. |
| Description search | Description included in normalized search text. Description-only query regression passes. |
| Cancelled worker leak | Cancellation-aware queue/pause continuations; session joins stopped workers. Cancelled wait tests pass. |
| Low-space stall | Cancellable periodic free-space checks and visible wait notice. Test simulates external space recovery without releasing another reservation; oversized files respect physical headroom. |
| Out-of-order snapshots | Serial writer for favorites, ratings, pins, and folder statistics; latest failed operation retained for retry. Tests exercise rapid saves, recovery, and save-then-remove ordering. Quit flushes pending snapshots, migration waits for pending edits. |

## Performance

- Actor construction no longer reads metadata synchronously on the UI thread.
- A local debug-build fixture with 100,000 photo records measured approximately **0.015 ms** constructor time and **316 ms** background hydration.
- With a 100,000-file manifest, **20,000 state transitions plus 10,000 progress reads took about 26 ms**. Journal file lookup is indexed, mutations avoid repeated value copies, and remaining-work totals update incrementally.
- A 20,000-item queue verifies FIFO order through cursor-based compaction rather than per-item array shifting.
- Initial folder AI scans are tracked immediately, reject duplicate starts, and propagate cancellation.
- Thumbnail cache maintenance runs on a serial background queue every 32 writes, as well as at launch. A byte-budget eviction test passes; the cache may exceed its target between trims.

Measurements are local synthetic checks, not SD-reader or network throughput claims. Durable journal serialization and disk I/O still have costs beyond the measured transition loop.

## Validation boundaries

The physical SD-reader/SMB transport matrix, external-volume disconnect timing, and live-provider/API behavior were not revalidated here. Harness disk-image attachment was unavailable, so all ten modes used disposable directories. Exclusive rename must be supported by the destination filesystem; unsupported promotion fails safely. The additional source SHA-256 check costs one card read before erasure.

The original audit source and expected-failure output remain alongside this report for comparison. Current regression sources live in `Tests/OffloadTests/AuditReproductionTests.swift` and `AuditFixRegressionTests.swift`. No test suite can guarantee the absence of all bugs.
