# FSKit exFAT erasure regression — October 6, 2026

## Cause and fix

The affected card was mounted as writable exFAT through macOS FSKit. Version 1.7.17's
`renameatx_np(..., RENAME_EXCL)` failed with `ENOTSUP` (errno 45) while claiming the first
approved source for erasure. The saved report recorded zero files deleted. Copies had
passed NAS verification; the unsupported operation stopped source removal.

Version 1.7.18 retains exclusive rename when supported. Only unsupported-operation errors
enable the fallback: create a new recovery directory exclusively, move the source into it,
then check the original pinned descriptor, metadata, named identity, and complete uncached
SHA-256 before unlinking. The source is opened and checked before claiming it, so replacing
the original name does not turn a new photo into the approved source. Renaming on exFAT can
change a directory-derived inode; post-rename identity is compared with the pinned descriptor.

Interrupted claims are restored without replacing an occupied original name. If exclusive
rename is unsupported, restoration uses exclusive creation, data copy, flush, and hash
read-back. Cancellation does not cancel that restoration. Recovery data stays intact on
collision or restoration failure. Cleanup removes only empty recovery directories.

## Verification

| Check | Result |
| --- | --- |
| Red regression against the old algorithm | Reproduced errno 45, zero files deleted |
| Unsupported rename fallback | PASS: approved photo removed; unrelated file preserved; no recovery directory left |
| Other rename errors | PASS: no fallback or deletion |
| Existing recovery directory | PASS: original and recovery source preserved |
| Changed bytes with original size and timestamp | PASS: hash mismatch stops deletion and restores the changed source |
| Interrupted directory claim, occupied original | PASS: neither overwritten; recovery succeeds after the collision is removed |
| Legacy recovery file on unsupported rename | PASS: exclusive copy restores the source |
| Replacement between opening and claiming | PASS: replacement preserved; zero files deleted |
| Cancellation after claim | PASS: source restored; zero files deleted |
| Full unit suite | PASS: 166 passed, one opt-in live AI-provider test skipped, zero failures |
| All ten integration harness modes | PASS with disposable local directory fixtures |
| Release app compilation | PASS |

The host could not create disposable exFAT images, so directory-based integration modes
alone do not establish exFAT compatibility. The user then explicitly authorized testing
the real mounted card, overriding the repository's default prohibition on physical erasure
during development.

## Authorized physical-card result

The physical test used the updated production `SessionRunner` and `Wiper` through a
temporary local driver. Before beginning, it checked the volume UUID, writable exFAT
filesystem, existing session token, exact 168-file media manifest, and configured healthy
SMB NAS. It used the failed session's verified destination paths and source hashes.
The normal production final NAS read-back, wipe gate, and per-file source validation
ran without bypasses. The old app was stopped to prevent concurrent sessions. Automatic
ejection was disabled only in the test's in-memory configuration to inspect the result;
persistent preferences were unchanged.

- **PASS:** all 168 destination copies passed fresh uncached SHA-256 verification before erasure.
- **PASS:** all 168 approved source files, totaling 6,220,774,443 bytes, were erased.
- **PASS:** completed journal report recorded `ran: true`, `filesDeleted: 168`, and no blockers.
- **PASS:** a new media scan found no remaining files; DCIM was empty.
- **PASS:** all 168 NAS files were still present with their expected sizes after erasure.
- **PASS:** the camera database's SHA-256 matched its pre-test checksum.
- **Timing:** 121.8 seconds including the 10-second countdown, NAS read-back, and source validation/erasure. No new photo upload was performed in this test.

This validates the happy path on the affected physical FSKit exFAT card. Collision,
changed-source, cancellation, and interrupted-restoration branches were exercised with
disposable fixtures and injected unsupported-operation responses, not by altering the
user's real photos. It does not certify every reader, card, OS version, or NAS.
