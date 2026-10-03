# Recovery consent and erasure diagnostics — 2026-10-03

## Confirmed behavior

Recovery previously bypassed the configured Ask and Ignore insertion policies. Both
unfinished-journal recovery and reinsertion into an active session now follow the
current insertion policy. Automatic still permits automatic recovery; no saved user
settings were changed. The recovered-progress badge now has an explanation.

The observed physical-card run verified all 50 files, then stopped erasure before
removing any file. Its saved error used NSError's generic description, losing the
underlying operation and POSIX code. OffloadError now conforms to LocalizedError and
includes both operation and numeric errno. The original error cannot be reconstructed
from the old generic text. The deletion algorithm is unchanged.

## Evidence and limits

- 158 automated tests passed, one optional live-provider test skipped.
- All ten disposable transfer safety modes passed using local-directory fixtures.
- New tests exercise Ask/Ignore with an unfinished journal, duplicate mount signals,
  declining, reinsertion, and error details surviving NSError bridging.
- Strict validation (`OFFLOAD_REQUIRE_EXFAT=1 swift run offload-harness run`) failed
  because this host could not create an exFAT disk image. It correctly refused a
  local-directory substitute. Both hdiutil and its documented diskutil replacement
  failed to create a disposable image.
- Physical-card wiping and long-duration insertion reliability remain unverified.
  No real card was erased or modified during development testing.

The physical-card erasure failure is still undiagnosed. This release improves consent
and diagnostics, and must not be described as a proven fix for that failure.
