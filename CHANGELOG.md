# Changelog

All notable changes to Offload. Format loosely follows [Keep a Changelog];
the app version lives in `VERSION`, the build number is the git commit count.

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
