# Changelog

All notable changes to SD Offload. Format loosely follows [Keep a Changelog];
the app version lives in `VERSION`, the build number is the git commit count.

## [Unreleased]

### Renamed
- **The app is now "SD Offload"** (was "Offload") — repo `t0nyz0/sd-offload`, bundle id
  `com.t0nyz0.sdoffload`. Internal Swift module names (OffloadCore/Engine/App) are unchanged.

### Changed (public-release hardening)
- **Card wipe now defaults to "Ask every time."** A new user opts in to unattended
  wipes rather than discovering them; existing configs keep their setting. The
  Settings copy no longer labels an automatic-erase option as "recommended."
- **Library delete goes to the Trash** (recoverable) instead of a hard unlink.
- **Broader card detection.** A volume is recognized as a camera card if it carries
  *any* known media root (DCIM, PRIVATE, AVCHD, CLIP, MP_ROOT), not just DCIM.
- **NAS credentials are stored device-only** (`ThisDeviceOnly` Keychain) so they
  never sync to iCloud Keychain or restore onto another device.
- **Accessibility labels** added to the destructive controls (wipe countdown +
  Cancel, pause/cancel) so the irreversible path is unambiguous under VoiceOver.
- Repo: added `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`, and a CI workflow
  (`swift build` + `swift test`); scrubbed personal identifiers; added an as-is /
  no-warranty disclaimer.

### Added
- **Viewer info inspector + delete.** The in-app viewer gained a **Delete** button
  (⌦, NAS only, with confirmation — card originals stay protected) that removes the
  photo and its RAW/sidecars and advances to the next shot. An **Info** toggle (the
  ⓘ button or the `i` key) opens a right-side inspector packed with everything we
  know: format + total size, capture date/time, camera + lens, full exposure,
  pixel dimensions + megapixels, GPS coordinates (with "Open in Maps"), and the
  content tags from Analyze.
- **Photo GPS (phase 1 of location)**: Analyze now reads each photo's EXIF GPS
  coordinate (fully on-device, header-only — no network, no place lookup yet) and
  stores it in the index. Photos analyzed before this are back-filled cheaply on
  the next Analyze without re-running Vision. The Library header shows coverage —
  "N of M photos have GPS" — so we can see how much of the library is geotagged
  before deciding whether reverse-geocoding to city names (e.g. "Fairhope,
  Alabama") is worth adding. (Heads-up: dedicated cameras like Fuji usually don't
  record GPS unless geotagged via the phone app, so coverage may be low.)
- **Folder cards with photo previews**: date folders in the Library now render as
  large cards showing a 2×4 collage of photos sampled from inside (cached), so you
  can see what a day holds at a glance instead of a bland folder glyph. Folders get
  their own larger grid, separate from the photo thumbnails.
- **Human-readable dates**: a `YYYY/MM/DD` folder is labelled by what it means —
  the open folder shows "Saturday, July 4th, 2026" next to the breadcrumb, and each
  day/month/year card is captioned ("Jul 4 · Saturday", "July · 2026", "2026")
  instead of a bare number.
- **Adjustable thumbnail size**: a slider in the Library toolbar scales the grid
  tiles up or down (remembered across launches).
- **Per-photo info line** under each thumbnail: format (JPG+RAW / RAW / VIDEO)
  plus basic EXIF — ISO, aperture, shutter, focal length — read cheaply from the
  file header (no full decode) and cached.
- **In-app image viewer**: double-click a photo (or right-click → Open) to view
  it instantly in a built-in viewer showing the JPEG — no more launching
  Preview. Arrow keys move between photos, Escape/Space closes, scroll/pinch
  zooms, double-click toggles zoom. "Open RAW" and "Open in Preview" remain in
  the right-click menu for the external app.
- **Multi-select in the Library**: click to select, ⌘-click to toggle, ⇧-click to
  select a range, ⌘A to select all. A selection bar shows the count with Delete /
  Clear, and ⌦ or right-click → "Delete N Photos" removes them all at once (each
  with its RAW/sidecars), with a single confirmation.

### Changed
- **Faster NAS upload start.** The slow-then-ramp start was mostly per-file SMB
  overhead that's fully exposed before upload concurrency builds up. Three safe
  wins cut it: each `YYYY/MM/DD` destination dir is now created once per session
  (not re-`mkdir`'d per file); the per-file NAS health check honors a 5-second
  cache instead of forcing a `statfs` round-trip before every file (the wipe gate
  and post-error path still force a fresh check); and SMB write chunks are 16 MiB
  (was 8), halving write syscalls. None of these touch verification.
- **Clearer "uploading to NAS" status.** The active-transfer popover now names the
  real phase — "copying from card" → "uploading to NAS" → "verifying on NAS" —
  instead of the old "card read — uploading" (and it no longer shows "complete"
  while the card is still being read). Each transfer row (CARD → MAC, MAC → NAS)
  now shows its own percentage, so upload progress is visible at a glance.

### Fixed
- **Data-safety: the wipe-gating NAS read-back is now always uncached.** The
  end-to-end verify (and the collision/dedup hash) previously defaulted to a
  *cached* read of the just-uploaded file. Over SMB, `fsync` flushes our bytes to
  the server but does **not** invalidate the client read cache — so the "verify"
  could re-hash the very bytes we just wrote out of local page cache and pass
  without ever reading the server's stored copy, yet still clear the card for
  wiping. Both read-backs now force `F_NOCACHE` unconditionally, so a match proves
  the server truly holds the bytes. The now-redundant "Thorough NAS verification"
  setting has been removed (verification is always thorough). Validated across all
  five harness modes (happy path, NAS-drop, one-failure-blocks-wipe, crash-resume,
  wrong-card). Verification can now only make the wipe gate *more* conservative.
- **ETAs no longer flash absurd values** (e.g. "Card free in ~53446:21:00"). The
  pipeline estimate used to fold the NAS-verify stage into its `max()` and divide
  by that stage's live rate — but verification runs in bursts, so between bursts
  the rate decays toward zero and `bytes ÷ ~0` exploded into a multi-thousand-hour
  number, appearing intermittently depending on where the sampler landed in a
  burst. The estimate is now driven by the two continuously-active stages (card
  read + NAS write); the read-back tail is figured from the write rate; and a
  final sanity clamp shows "estimating…" instead of any non-finite or wildly
  out-of-range value.
- **Library thumbnails no longer overflow into each other** (for real this time).
  Tiles are now uniform squares sized from the cell width, with the image
  overlaid into that definite box and clipped — the previous `maxWidth:.infinity`
  proposed infinite width to a fill-scaled image, so landscape photos bled into
  neighbouring cells.
- **RAW+JPEG pairing is now unmistakable**: a paired shot is one card titled by
  its base name (no extension) with a "JPG+RAW" badge; RAW-only shows "RAW",
  video shows "VIDEO". (Pairing already collapsed the files; the overflow bug
  was hiding it.)

### Fixed (QA pass — adversarial full-app review)
- **Delete no longer destroys un-warned files.** It only removes the photo, its
  RAW, and known sidecars (XMP/THM/…) — never a same-name video or unrelated
  file — and the confirmation lists exactly what will go. Delete is limited to
  the NAS archive; card originals are never deletable from the Library.
- **Thumbnails no longer stall the app.** The QuickLook fallback was blocking
  Swift-concurrency threads (up to 20 s each); it's now a proper async bridge.
  Directory listings for delete/RAW-lookup moved off the main thread.
- Bounded resource use: on-disk thumbnail cache is capped and evicts oldest;
  History directory is trimmed; the speed timeline is sampled at 1 Hz in memory;
  the photo index prunes entries for files deleted outside the app.
- Staging-budget accounting is now keyed per file (no release-without-reserve on
  resume, no double-reserve), and workers parked awaiting budget are woken on
  cancel / card removal instead of leaking.
- Restarting Analyze no longer lets a stale run flip the UI out of "analyzing";
  photos Vision can't label are recorded so they aren't re-scanned every run.
- Content-search path scoping is boundary-aware (no leaking between folders that
  share a name prefix).
- Wired up the previously-inert "Eject now" notification action and the
  "Card detected" notification toggle.

## [0.9.0] — 2026-07-04

First feature-complete build. Insert an SD card → it copies to local staging,
then to the NAS (date folders), verifies SHA-256 end-to-end, and wipes the card
only when everything is provably safe.

### Added
- **Ingest engine**: DiskArbitration card detection with a DCIM heuristic and
  per-card policy (always / ask / ignore); two-hop pipelined transfer
  (card → staging → NAS) with inline SHA-256 and read-back verification at both
  hops; EXIF-dated `YYYY/MM/DD` routing; collision suffixing; content-verified
  dedup so an already-offloaded photo is skipped, not re-uploaded.
- **Wipe safety**: a strict all-or-nothing gate (every file NAS-verified, card
  re-stat'd unchanged, NAS healthy, journal flushed) before any delete; empty
  DCIM subfolders pruned; auto-eject; a cancellable countdown.
- **Crash / close resilience**: a crash-safe JSON journal resumes an interrupted
  session exactly where it left off; per-card session token defeats
  synthesized-UUID collisions; interrupted work resumes regardless of policy.
- **Menu bar UI**: waiting → live-percentage icon; popover with a filling
  SD-card gauge, dual progress bars, two ETAs (card-free / all-safe), and a
  120-second throughput sparkline.
- **Library**: browse the NAS and an inserted card; storage gauge; progressive
  photo count; date-folder navigation; fast cached thumbnails (embedded
  previews, memory + disk cache, bounded concurrency).
- **Photo search (on-device AI)**: Apple Vision content analysis (scene/object +
  animal recognition) builds a searchable metadata index — find photos by what's
  in them ("dog", "beach"), with suggestion chips and per-tile content tags. No
  cloud, no API, no tokens.
- **RAW + JPEG pairing**: a shot with both shows one tile (the JPEG); the RAW
  opens via right-click and is deleted together with the JPEG.
- **Delete** photos from the Library (removes the RAW and sidecars too), with
  confirmation.
- **Settings**: destination, ingest scope, wipe policy, staging + purge policy,
  parallel-upload count, Standard/Thorough NAS verification, notifications,
  launch-at-login, and a completion sound picker (14 system sounds with preview).
- **Test harness**: `offload-harness` proves the pipeline on a fake card + NAS —
  happy path, NAS-drops-out, one-failure-blocks-the-wipe, crash-resume, and
  wrong-card-not-wiped. Plus 52 unit tests.

### Fixed
- NAS upload throughput (~1 MB/s → usable): the end-to-end verify no longer uses
  uncached reads that choked the SMB connection; Standard verify reads through
  the cache and still checksums each file; I/O runs at user-initiated priority.
- Library storage gauge used an APFS-only API that reads 0 on network shares
  ("Zero kB free"); now uses `statfs`, which is accurate over SMB.
- Library thumbnails no longer overflow their tiles into the next row.
- Four resume bugs found by an adversarial audit: `.ignore` cards were orphaned;
  a colliding synthesized UUID could wipe the wrong card; already-safe files
  could get stuck; a transient failure froze across relaunch.
