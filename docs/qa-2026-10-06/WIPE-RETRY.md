# Wipe-only retry — October 6, 2026

## Before and after

In 1.7.18, the generic Retry action called `startSession` for the same card. That rescanned
and replanned the media, copied it to staging, and reread the NAS to recognize duplicate
photos before attempting erasure again. Duplicate detection generally prevented another
upload, but this still repeated the transfer pipeline unnecessarily.

Version 1.7.19 labels the action **Retry wipe** when the saved failed-erasure session has
a card token and all files have verified states and recorded hashes. It sends a separate
engine intent bound to that session ID. The coordinator checks that the original card
is mounted and its token matches, then reopens the exact saved manifest. The runner skips
the scan, planner, staging, upload, and secondary-backup reconciliation stages.

The normal wipe countdown/consent policy, fresh uncached NAS and secondary read-back,
wipe gate, interrupted-claim restoration, and per-source identity/hash checks still run.
A missing or changed backup blocks erasure; this action never silently recopies it.
Already-wiped files are not erased again, new unplanned photos are preserved, and transfer
statistics and staged recovery data are retained. The failed-session panel remains visible
until the user acts instead of disappearing after 60 seconds; its display timer stops.

Incomplete transfers, or older records without sufficient saved identity/hash information,
offer **Retry transfer**. The saved failed session is updated in place when a wipe retry
finishes, retaining its file IDs, original destination names, and staging location.

## Tests

Ten new tests drive the coordinator's wipe-retry intent using generated temporary card,
NAS, and staging directories. The only injected physical dependency is card presence;
a separate test uses the production kernel mount check to reject an unmounted fixture.

| Regression | Result |
| --- | --- |
| Saved collision-resolved destination names reused; new photo preserved | PASS |
| No scanning/transferring phases or new staging files; NAS metadata unchanged | PASS |
| Original transfer statistics retained | PASS |
| Missing NAS copy blocks instead of recopying | PASS |
| Changed source survives | PASS |
| Partial wipe removes only remaining approved files | PASS |
| Different card token blocks before session startup | PASS |
| Unmounted card blocks before startup | PASS |
| Incomplete manifest cannot use the wipe-only intent | PASS |
| Newly required missing second backup blocks instead of backfilling | PASS |
| Repeated concurrent clicks start one attempt | PASS |
| UI label distinguishes Retry wipe from Retry transfer | PASS |

Full unit suite: **176 passed, one optional live AI-provider test skipped, zero failures**.
The normal ten-mode disposable integration harness checks the original transfer path as well.
The user card was already successfully erased by the prior physical exFAT validation; these
retry regressions do not modify it or claim a second physical-card erasure test.
