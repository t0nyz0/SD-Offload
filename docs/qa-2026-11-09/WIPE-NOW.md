# Wipe Now verification

## Behavior

Version 1.7.28 adds **Wipe Now** beside **Cancel wipe** during the automatic countdown.
It pauses the countdown and names the card in an explicit destructive confirmation.
**Keep waiting** or closing the popover resumes the remaining countdown. A late
confirmation event arriving after the popover closes also resumes safely.

Confirming skips only the timer. The existing fresh NAS and configured second-copy
read-backs, card token, source identity, WipeGate, and Wiper checks remain intact.
The control cannot bypass Ask each time, target another session, or revive a cancelled
attempt. The final safety checks can still take time.

## Verified

- `swift build`: passed.
- `swift test`: 276 tests executed, 2 opt-in tests skipped, zero failures.
- `OFFLOAD_HARNESS_DIRECTORY_CARD=1 bash Scripts/harness.sh`: all ten modes passed.
- Sixteen added regressions cover the shortcut, pause/resume, normal expiry,
  session and wipe cancellation, repeated requests, stale session IDs, removal and
  reinsertion, missing/corrupt NAS data, changed originals/card tokens, a missing
  second backup, Ask each time, popover dismissal races, and native offscreen layout.
- Native SwiftUI renders at the actual 360-point popover width were inspected for
  the countdown and confirmation. Both buttons and all warning text fit.
- Independent source review found a popover-close race; it was fixed and covered
  before the final suite. No remaining actionable finding was reported.
- `git diff --check`: passed.

## Scope and limits

All erasure tests used generated disposable directories. No real card, footage,
NAS photos, or installed application was modified. No app was launched or relaunched.
Directory fixtures validate the engine, not physical SD/exFAT or live SMB compatibility.
The opt-in live-SMB recovery and signed-in AI-provider tests were not run.
No live GUI interaction was performed while the user was processing footage.
The supplied reference attachment could not be materialized; layout was grounded in
existing source and native offscreen rendering.
