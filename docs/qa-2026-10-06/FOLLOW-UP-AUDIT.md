# Follow-up code, UI, safety, and release QA — October 6, 2026

## Scope and findings

Reviewed the recent changes to transfer/verification progress, SMB writing and read-back,
card recognition and recovery policy, exFAT erasure, wipe-only retry, Library completion
navigation, manual tags, viewer deletion/tooltips, AI-provider routing, and metadata
persistence. Ran the full automated suite, integration modes, live provider checks,
native fixture UI checks, and performance probes. This is evidence for the flows below,
not a claim that every possible device, network, or user interaction is certified.

Two additional bugs were reproduced and fixed for **1.7.21**:

1. Removing/reinserting a card during **Retry wipe** took the transfer reinsertion path:
   it rescanned, expanded the saved manifest, and created staging work. The regression
   failed six assertions before the fix. Reinsertion now verifies the original mount and
   session token, keeps the approved manifest, and returns to the wipe phase without
   copying. New photos remain untouched; a different card cannot resume the attempt.
2. A configured root and Foundation's canonical filesystem spelling could differ, so
   edited tags saved correctly but produced **No matches** in the Library. This was
   reproduced in the native UI and a failing automated test. Search, suggestions, face
   filters, and unnamed counts now accept both root spellings in one index traversal.
   Root resolution is shared background work, cached until root/availability changes or
   refresh. Existing photo IDs remain unchanged. Prefix boundaries exclude sibling
   libraries. A superseded suggestion task cannot replace the current root's results.

## Automated and live checks

| Check | Result |
| --- | --- |
| Full default suite | **PASS:** 188 passed, one optional live-provider test skipped, zero failures |
| Six added regressions | **PASS:** wipe-retry reinsertion, wrong token, late NAS corruption, empty recovery/ENOSYS fallback, alias tag search/suggestions, alias face search/review |
| Ten integration harness modes | **PASS:** complete transfer/wipe, NAS outage, unreadable source, crash recovery, wrong card, secondary backup, failing secondary, secondary backfill, missing final NAS copy, corrupted final NAS copy |
| Live Claude and Codex | **PASS:** valid descriptions and tags from both signed-in CLIs; only the repository app icon was sent |
| Live SMB fixture probe | **PASS:** exclusive write, uncached SHA-256 read-back, and preserving a pre-existing collision on the configured share |
| Release-mode app build | **PASS** |

The host refused disposable exFAT image creation. Integration modes used disposable
directory fixtures; these are not physical exFAT compatibility tests. Unsupported-rename,
collision, changed/replaced-source, and interrupted-recovery branches also have explicit
injected-operation regressions. Existing tests cover missing/corrupted required backups,
out-of-order or failed saves, cancellation, stale card probes, recovery Ask/Ignore policy,
custom date layouts, and newest completed-day navigation.

## Native UI checks

Used a separate bundle ID, demo-idle engine, temporary state, and four copies of the
repository app icon. No personal library metadata or card was modified.

- **PASS:** readable idle status and Library navigation; photos load in the viewer.
- **PASS:** viewer controls expose descriptive accessibility labels/help; Delete has
  visible text and opens the existing NAS/Trash confirmation. Cancel retained the file.
- **PASS:** Edit Tags saves normalized tags, updates tile labels, survives relaunch,
  populates suggestions, and finds the edited photo through the alias root.
- **PASS:** Settings lists Claude, Codex, and Anthropic API; selecting Codex updates its
  setup guidance. Production settings were unchanged.
- **PASS:** automated completion-navigation checks load the newest verified capture day
  while an older folder is opening, including custom and legacy destination layouts.

## Performance measurements

| Measurement | Observed result |
| --- | --- |
| Local 256 MiB sequential copy/hash/flush, three release-mode trials | 1,638–1,755 MiB/s copy; 2,468–2,536 MiB/s uncached verification; 0.247–0.257 seconds total; hashes matched |
| Browse 2,000 local entries | 0.027 seconds |
| Lazy 100,000-record index hydration, final default test run | 0.364 seconds |
| 20,000 journal transitions plus 10,000 progress reads in a 100,000-file manifest | 0.045 seconds |
| Live SMB 4 MiB disposable probe | Write/flush 0.215 seconds; uncached read-back/hash 0.101 seconds |

Local SSD figures do not predict card or NAS speeds. The small SMB probe establishes
operation compatibility, not sustained throughput. Long-duration real insertion/sleep/wake
testing and sustained card-to-NAS benchmarking were not repeated in this follow-up.

## Physical erasure evidence

Re-read the authorized physical test log and completed history record. The production
erasure algorithm and wipe gate have not changed since that successful test.

- **PASS:** all **168 approved source photos, 6,220,774,443 bytes**, erased from the
  affected writable FSKit exFAT card after fresh uncached NAS verification.
- **PASS:** completed state, `filesDeleted: 168`, no wipe blockers, empty media/DCIM scan.
- **PASS:** NAS files remained present with expected sizes and the camera database hash
  matched its original value.
- **Timing:** 121.8 seconds including countdown, final NAS verification, source validation,
  and erasure; no new upload.

See [EXFAT-ERASURE.md](EXFAT-ERASURE.md) for the detailed cause, algorithm, and actual-card
result. Wiping intentionally remains blocked for damaged/missing backups, changed source
files, a wrong/read-only card, or an I/O failure. The successful affected-card test does
not establish a guarantee for every future card, reader, OS, or NAS.

## Release verification

The audit re-downloaded published **1.7.20** DMG/ZIP/checksums, verified both SHA-256 hashes
and the DMG's internal checksums, checked the app signature, and compared every bundle
file/link with the installed app. All matched the published release. Its GitHub tag,
`main` commit, and successful build/test/integration CI run also agreed.

**1.7.21** is the release containing this audit's fixes and six new regressions.
The release process builds from the committed source and requires successful CI,
versioned DMG and ZIP plus `SHA256SUMS.txt`, re-downloaded asset verification, and an
installed-bundle comparison before reporting the update ready. Published asset hashes
are available on the [1.7.21 release](https://github.com/t0nyz0/SD-Offload/releases/tag/v1.7.21).

Bundles remain Apple Silicon, ad-hoc signed, and **not notarized**. A rebuild can trigger
macOS volume-access prompts; a waiting permission prompt is not a passing live-card scan.
