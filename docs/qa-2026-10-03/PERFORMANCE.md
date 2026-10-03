# NAS latency and card detection — 2026-10-03

## Observed

The running 1.7.14 app was transferring 50 files without recorded retries. A two-second
process sample found one NAS worker in `fsync` and another in `read`, rather than repeated
rename failures. Later observation showed 35 files verified or duplicate-verified, with
the remaining files still progressing and no retries.

A separate generated 16 MiB fixture on the configured SMB share measured:

| Operation | Seconds |
| --- | ---: |
| Exclusive file open | 5.78 |
| Buffered write call (not durable completion) | 0.005 |
| Durable flush | 10.42 |
| Uncached read, 1 MiB requests, first pass | 0.72 |
| Uncached read, 16 MiB requests, first pass | 0.28 |
| Uncached read, 16 MiB requests, second pass | 0.35 |
| Uncached read, 1 MiB requests, second pass | 21.30 |

Every read matched SHA-256. The unique fixture folder was removed. Read timings exclude
opening the file. The real transfer remained active, so these are contended observations,
not a controlled throughput benchmark. Large variance and expensive opens/flushes mean
the app changes alone cannot establish that NAS/network latency is resolved.

## Changes

- Restore 16 MiB sequential verification reads while retaining uncached SHA-256 checks.
- Run copy/verification opens off Swift's cooperative executor; expose slow metadata,
  open, and flush waits in both transfer views.
- Use cached kernel mount snapshots on the DiskArbitration queue instead of device
  `statfs` calls. Use kernel mount paths and identities even when description events lag.
- Reconcile on wake and allow one replacement for a probe pending over 30 seconds.
  Two blocked probes cannot create an unbounded task backlog. Stale probe completions
  cannot report a removed or replaced card.

## Validation

- 155 automated tests pass, one optional live-provider test skipped.
- All ten disposable transfer safety harness modes pass, including missing/corrupted
  final destinations blocking erasure.
- Two new regressions were demonstrated failing with the old small-read behavior and
  the old no-timeout probe behavior, then passing with the fixes.
- Coverage checks complete byte hashing across large read boundaries, flush phase
  ordering, cleared wait messages, bounded stuck-probe recovery, independent readers,
  and changed mount identities.
- Native demo UI smoke check confirmed the NAS flush-wait message is visible, readable,
  and exposed in the accessibility tree. The demo used isolated application data.
- Physical long-duration sleep/wake and repeated card insertion still require hardware
  validation. The user's real card was not used for destructive development tests.
