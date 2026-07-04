# Offload

Insert an SD card. Walk away.

Offload is a macOS menu bar app that automatically moves photos from an SD card to the NAS —
fast, verified, and only wiping the card when every file is provably safe.

## Safety model

1. **Hop 1** — card → local staging SSD: chunked copy with SHA-256 computed inline, then a
   read-back verify (`F_NOCACHE`, so we check the disk, not the page cache).
2. **Hop 2** — staging → NAS (`/Volumes/Photos/YYYY/MM/DD/`): pipelined per-file as soon as
   staging verifies, then a NAS read-back hash compared against the *original card-read hash*
   (end-to-end integrity).
3. **Wipe gate** — the card is erased only when every manifest file is NAS-verified, nothing
   failed, and each card file is re-stat'ed unchanged. Then eject + "Safe to remove".

Crash, yanked card, or unmounted NAS mid-transfer? The JSON journal resumes exactly where it
left off. A hash mismatch re-copies once, then fails that file — and a failed file means the
card is never wiped.

## Requirements

macOS 14+, Apple Silicon, Swift 6 toolchain. No dependencies.

## Quick start

```bash
swift run OffloadApp          # dev
bash Scripts/build-app.sh     # build/Offload.app
```

Settings: destination folder, DCIM-only vs whole card, wipe policy (after-NAS-verify default),
staging purge policy, notifications, launch at login.

Personal project — not distributed.
