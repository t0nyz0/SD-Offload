# Changelog

All notable changes to Offload. Format loosely follows [Keep a Changelog];
the app version lives in `VERSION`, the build number is the git commit count.

## [Unreleased]

### Added
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

### Fixed
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
