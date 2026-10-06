# Changelog

All notable changes to SD Offload. Format loosely follows [Keep a Changelog];
the app version lives in `VERSION`, the build number is the git commit count.

## [Unreleased]

## [1.7.18] — 2026-10-06

### Fixed
- Fix card erasure stopping with `errno 45: Operation not supported` on FSKit exFAT. When exclusive rename is unsupported, claim the approved source in a newly created recovery directory, then verify its pinned file descriptor, metadata, and complete SHA-256 before deletion.
- Restore interrupted or cancelled erasure through exclusive creation and verified read-back when the card cannot perform an exclusive rename. An occupied original name or recovery path preserves both files.

### Added
- Eight erasure regressions covering unsupported rename, other errors, recovery collisions, changed bytes, replacement files, interrupted claims, and cancellation.

## [1.7.17] — 2026-10-03

### Added
- Visible Delete button beside Pick / Reject in the photo viewer's bottom toolbar. It opens the existing confirmation with JPEG/RAW choices and uses the Library's move-to-Trash behavior; card browsing remains read-only.

## [1.7.16] — 2026-10-03

### Fixed
- Interrupted-transfer recovery and card reinsertion respect the current Ask / Ignore / Automatic insertion policy instead of bypassing consent.
- Preserve the operation and POSIX error code in wipe errors shown in the UI and saved in history, replacing the unhelpful generic error message.

### Changed
- Clarify the recovered-transfer badge with an explanation of saved progress.
- Add strict exFAT harness validation that refuses a local-directory fallback. The observed physical-card erasure failure remains undiagnosed; this release does not claim to fix it or weaken deletion safeguards.

## [1.7.15] — 2026-10-03

### Fixed
- Keep card detection responsive by replacing device filesystem calls on the DiskArbitration queue with cached kernel mount snapshots. Reconcile immediately after wake, recognize mount identity changes, and allow one bounded replacement for a probe stuck longer than 30 seconds.
- Restore large sequential verification reads to reduce SMB round trips while preserving uncached SHA-256 verification. Slow file opens now run off Swift's cooperative executor.

### Added
- Show when the NAS is taking time to open a file, return file information, or finish flushing saved data, with elapsed wait time in the popover and Library.
- Regression coverage for stuck probes, another reader remaining detectable, remount identity, large read boundaries, durable-flush phases, and cleared NAS wait messages.

## [1.7.14] — 2026-09-29

### Fixed
- Fix an SMB regression introduced in 1.7.13: network destinations use exclusive file creation because many SMB shares reject exclusive rename. Existing files remain protected, and copied files still require complete SHA-256 read-back verification.
- Stop retrying unsupported destination operations instead of repeatedly uploading the same file.
- Stop labeling upload retries as NAS verification or showing 100% overall completion before safety checks finish.

### Added
- Separate NAS verification progress with verified bytes, completed file count, current file, read speed, and a warning when an active read reports no progress for ten seconds.
- Visible, cancellable final destination checks with their own progress and estimated remaining time. Progress sampling continues through the final checks.
- Disposable SMB compatibility and full-session harness modes, plus verification/collision regression tests.

### Changed
- Report verification progress after each 1 MiB read instead of waiting for 16 MiB.
- Show failed files separately from verified files.

## [1.7.13] — 2026-09-28

### Fixed
- Never overwrite a conflicting backup when promoting a transfer on either destination; a second-drive conflict preserves the card and explains how to retry.
- Revalidate source identity and SHA-256 after exclusively claiming each file for erasure. Changed files are restored; interrupted claims are recoverable without overwriting another file.
- Preserve face metadata when a folder scan fails, is cancelled, or uses an equivalent macOS path alias.
- Retain failed photo, face, and identity saves for retry and show save errors in the Library.
- Persist favorites, ratings, pinned folders, and folder statistics in order; retry failed snapshots and flush queued writes on quit.
- Include AI descriptions in photo search.
- Release cancelled queue and pause waiters, join stopped workers, and recheck staging space after external disk cleanup. Oversized files also respect free-space headroom.
- Track and cancel the initial folder scan for AI analysis; repeated Analyze clicks no longer launch duplicate scans.

### Changed
- Load metadata on its background actor instead of during Library construction.
- Use amortized queue removal, indexed journal mutations, and incremental progress totals for large manifests.
- Trim the thumbnail disk cache during long browsing sessions, every 32 writes, as well as at launch.
- Add regression coverage for the audit findings, interrupted erasure, storage recovery, and 100,000-record performance.

## [1.7.12] — 2026-09-26

### Added
- Release packages include a SHA-256 checksum manifest; README covers provider setup, local tag storage, and performance validation.
- Select Codex or Claude Code sessions in Settings → Library → AI, alongside the existing Anthropic API option.
- Codex image analysis uses structured output, a read-only sandbox, and isolated temporary previews.

### Fixed
- Analysis uses the current provider immediately, even before the settings save debounce completes.
- Provider setup help and viewer/batch wording now reflect the available choices.
- Report failed photos in batch analysis and stop CLI processes that ignore timeout cancellation.
- CLI discovery avoids potentially hanging login-shell startup scripts; existing Claude settings remain compatible.

## [1.7.11] — 2026-09-26

### Changed
- Show an immediate explanatory caption when hovering over photo-viewer toolbar
  buttons, plus native tooltips and accessibility hints for every action.
- Clearly identify Open RAW, Show in Finder, rotation, auto-advance, photo info,
  and Move to Trash without shifting the photo as the pointer moves.

## [1.7.10] — 2026-09-26

### Added
- Edit Tags in the photo Info panel: add, rename, or remove searchable tags,
  including for photos without AI analysis. Tags are saved locally in SD Offload
  and manual corrections survive later AI analysis.
- Show all searchable tags together; update search, suggestions, and tile tags
  after saving, and display an error if the save fails.

## [1.7.9] — 2026-09-26

### Fixed
- Keep network volume lookups and search-result metadata reads off the UI thread;
  cancel obsolete folder work and prevent old results replacing the current folder.
- Do not cache failed or cancelled library counts as a complete empty library;
  show a retry message when enumeration fails and recheck legacy zero totals.
- Bound full-resolution viewer caching to 384 MiB and decode one image at a time
  so rapid paging does not launch overlapping full-resolution reads.
- Stop abandoned folder-preview/count work and skip queued metadata reads after cancellation.
- Preserve saved favorites when their volume is temporarily unavailable, and
  immediately re-sort highest-rated photos after a rating changes.

### Changed
- Default to Balanced thumbnails for responsive NAS browsing; explicitly chosen
  quality settings are preserved.
- Remove the continuously animated idle card to reduce idle work.
- Keep the viewer background opaque, hide the covered grid from accessibility,
  label rating controls, and show each photo’s actual filename extension.
- Give search its own row so Library controls stay readable in smaller windows,
  and require confirmation before deleting saved face data.
- Clarify erase-policy wording, AI analysis, search coverage, loading failures,
  and empty results caused by rating or pick/reject filters.

### Added
- Isolated demo data and idle mode for safe UI QA, regression coverage for library
  navigation, counts, cancellation and viewer memory, and a local performance baseline
  (`swift run -c release offload-harness benchmark`).

## [1.7.8] — 2026-09-26

### Fixed
- Preview videos with native AVKit playback, seeking, and volume controls instead
  of sending movies to the still-image decoder.
- Space plays/pauses videos; Escape and Back to Library exit. Stop playback and
  release the video when navigating away or closing the viewer.
- Keep Library controls below playback controls and show a useful loading/error state.

## [1.7.7] — 2026-09-26

### Fixed
- Keep a labeled Close Settings button in a fixed header above the scrolling pane.
- Remove the automatic floating sidebar toggle from Settings; category navigation
  remains visible beside the content.

## [1.7.6] — 2026-09-26

### Added
- Visible Show in Finder buttons for selected Library files and the photo viewer.
- Open Folder in Finder beside the current NAS or SD-card folder breadcrumb.

## [1.7.5] — 2026-09-26

### Fixed
- Give every Settings pane an explicit vertical scroll view, leading-aligned
  sections, and readable content width so all controls remain reachable when resized.
- Reset the scroll position when switching Settings categories.

## [1.7.4] — 2026-09-26

### Fixed
- Skip empty staging folders during next-run cleanup, avoiding unnecessary reads of
  historical NAS batches before a new transfer starts.
- Add Back to Library to the native window toolbar and the photo viewer's bottom
  controls, so exiting remains visible when window tabs obscure the content header.

## [1.7.3] — 2026-09-26

### Fixed
- Re-read and SHA-256 verify every destination immediately before card erasure;
  a missing or changed NAS/secondary file blocks erasure of the entire batch.
- Require verified NAS copies even for the legacy staging-only erasure setting.
- Retry SD-card discovery after delayed mount readiness, discover missed insertion
  notifications, and discard stale probes after removal or remount.
- Leave Library originals untouched when moving to Trash fails; remove the
  permanent-deletion fallback and correct confirmation text.

### Added
- Per-file transfer history with original names, destination paths, sizes,
  recorded outcomes, errors, and source SHA-256 details. Historical success is
  explicitly distinguished from current file availability.

### Changed
- Keep local recovery copies after completion, cancellation, and app restart.
  The next new transfer may clear completed batches only after fresh NAS hash
  verification; failed or unverifiable batches remain. Longer retention settings
  still apply.

## [1.7.2] — 2026-09-25

### Fixed
- Give the photo viewer a dedicated top bar with a labeled Back to Library button.

### Changed
- Put a labeled Favorite heart in the photo viewer's bottom controls, label star
  ratings, and move Pick / Reject into a separate menu with explanatory help.

## [1.7.1] — 2026-08-13

### Added
- **Non-destructive viewer rotation.** Rotate a photo left or right from compact
  viewer controls or the `[` / `]` shortcuts without modifying the original file.

### Fixed
- **Portrait photos display upright in the Library viewer.** Full-resolution
  decoding now applies mirrored and rotated EXIF orientation just like Library
  thumbnails already did, instead of showing the camera's raw landscape pixels.

## [1.7.0] — 2026-08-09

### Added
- **Flexible date-folder layouts.** Choose from seven reversible presets —
  nested numeric, ISO, compact, underscored, and named-month styles — or make a
  custom hierarchy with `{YYYY}`, `{MM}`, `{MMM}`, `{MMMM}`, and `{DD}`. A live
  preview shows the exact destination path before the next import.
- **Safe existing-library conversion.** A read-only preflight inventories every
  recognized day folder before moving anything. Conversion uses same-volume
  renames, preserves filename conflicts with suffixes, includes the configured
  second destination, updates favorites, pins, culling, face/photo indexes, and
  history, and never touches unrecognized folders or overwrites a file.
- **Resume and rollback for folder conversion.** Durable per-file migration state
  and local metadata backups let an interrupted conversion reconcile the real
  filesystem, resume, or restore the original folder names and saved Library data.

### Fixed
- **NAS recovery is now visible and repeatable.** After an interrupted upload
  reconnects, the session returns from “waiting for NAS” to its real phase,
  clears the stale warning, and can report/recover from another outage in the
  same run. Concurrent workers share one NetFS remount attempt.
- **The NAS Library reconnects while it is open.** The Library and menu popover
  check the configured destination every 15 seconds while visible, safely try
  the saved SMB mount when it is absent, show a specific unavailable state, and
  reload the current folder automatically when the expected share returns.

## [1.6.3] — 2026-07-15

### Added
- **Library opens to the current month.** The NAS view now lands in this
  month's `YYYY/MM` folder when it exists (where your most recent shoots are),
  falling back to the library root when it doesn't. Breadcrumbs, the library
  total, and search still key off the real root — only the folder you land on
  is deeper.

### Fixed
- **Clicking the Dock icon re-surfaces the app.** When a window is open the app
  shows a Dock icon; clicking it now reliably brings the window forward
  (deminiaturizing it if minimized), or pops the tray if nothing's open. This
  is the escape hatch for when the menu-bar item is hidden behind the camera
  notch and can't be clicked.

## [1.6.2] — 2026-07-14

### Changed
- **Settings redesigned.** The old page was a single ~10-section scroll —
  wipe policy, staging, thumbnails, AI, notifications, sound, login all in one
  column. Reorganized into a **macOS System Settings-style sidebar** with five
  grouped panes: **General** (startup / sound / about), **Destination**
  (NAS + optional second drive), **Card & Offload** (insert policy / files to
  copy / wipe / staging / parallel workers / NAS prewarm), **Library**
  (thumbnails + AI photo analysis), and **Notifications**. Window is wider so
  each pane breathes.

## [1.6.1] — 2026-07-14

### Performance
- **Image viewer no longer stalls on paging.** `NSImage(contentsOf:)` is lazy —
  actual JPEG decode was happening on the main thread the first time each photo
  drew, which made arrow-key nav feel sticky. It now force-decodes in a
  background task via `CGImageSourceCreateImageAtIndex` with
  `kCGImageSourceShouldCacheImmediately`, and the last 8 decoded images stay in
  memory so bouncing between recent photos is instant.
- **Search doesn't rebuild the haystack per keystroke.** `PhotoIndex.search`
  now caches the lowercased tag+filename haystack per record, invalidating only
  on record mutation. First keystroke is unchanged; every keystroke after is
  ~10× faster on a large library.
- **Faces gallery loads in one pass.** `identityCounts` now walks `byPath`
  once and tallies per identity (O(photos)) instead of a per-identity actor
  round-trip that was O(identities × photos). "All people" / "All pets"
  filters also go through a single-walk union.

### Fixed
- **History detail no longer lies about wiped-vs-kept.** The detail hard-coded
  "Completed — card wiped and ejected" for every `.done` session, but the
  ask-each-time "Keep contents" path also lands in `.done`. It now reads the
  actual `WipeReport.ran` and says "card kept (contents untouched)" when the
  user chose Keep.
- **NAS-unmounted copy fixed** — was "Insert happens anyway…" (parses as a
  noun-verb sentence about the act of insertion), now "You can still insert a
  card — uploads queue until it's back."
- **Real AI model ID placeholder** — the Settings API-mode Model field
  suggested `claude-opus-4-8`, which is not an Anthropic model ID and 404s.
  Placeholder is now `claude-opus-4-5` and the CLI default matches.

### Changed
- **`autoShowLibrary` defaults to `false`.** Auto-ingest was yanking the
  Library window to the front on every card completion, which fought the
  quiet-auto-offload preference. You can still open Library from the tray.

### Removed
- The unused on-device `PhotoAnalyzer` (Vision-based tagger) and its dead
  GPS-backfill pipeline (`setGPS`, `needsGPSCheck`, `geoStats`, the "N of M
  photos have GPS" badge that never rendered, and the `byYear` field on
  `LibraryIndex` that was persisted but never populated). Live AI tagging
  goes through `PhotoIdentifier` (CLI or API) as before; the viewer's info
  panel still displays EXIF GPS when present.

## [1.6.0] — 2026-07-11

### Added — Culling workflow
A Lightroom-style pass for picking keepers and clearing the rejects:

- **Star ratings (0–5) and Pick / Reject flags** on every photo, saved to disk
  (`cull.json`) and shown right on the tile — stars under the thumbnail, a green
  Pick flag or red Reject mark in the corner, and rejected shots dimmed.
- **The image viewer is the fast culling surface.** A floating rating + flag strip
  sits at the bottom, and keyboard keys do it all: **0–5** to rate, **P** to pick,
  **X** to reject, arrows to move. With **Auto-advance** on (default), rating or
  flagging jumps you straight to the next photo, so you can rip through a shoot.
- **Rate or flag a whole selection at once** from the selection bar, or a single
  photo from its right-click menu.
- **Sort** by name, date, size, or rating; **filter** to a minimum star rating and
  to Picks / hide-Rejected — all from the new **View** menu in the toolbar.
- **Delete all rejected** in one action (View menu) once you've flagged the throwaways
  — with a confirmation, NAS-only, RAW + sidecars included.

## [1.5.2] — 2026-07-09

### Performance
- **The library no longer re-counts the entire NAS folder on every open.** The
  "N items · X GB" header total was recursively walking the whole Photos tree over
  SMB each time you opened a folder — the spinner you saw — which starved thumbnail
  loading. It's now served from the cached total and only re-counted on **Refresh**
  or automatically **after an offload** adds photos (so the number stays accurate).

## [1.5.1] — 2026-07-09

### Performance
From a multi-lens performance audit of the Library:
- **No more thumbnail flash on folder re-open.** Tiles now read the in-memory cache
  synchronously and paint the cached image on the first frame instead of flashing a
  placeholder. The memory cache is also larger so scroll-back stays warm.
- **Folder card counts are cached to disk.** "N photos · X GB" no longer re-walks the
  whole subtree over the NAS every time you open a folder — it's persisted per folder
  and served instantly. (Refresh / ⌘R rebuilds them.)
- **AI Analyze writes the index far less often** (every ~10 photos instead of after
  every 2), and the `claude` CLI is located once per run instead of per photo.
- **Focus doesn't re-list the folder every time** — the on-activate refresh is
  throttled instead of re-scanning the NAS on every app switch.

## [1.5.0] — 2026-07-09

### Added
- **AI photo identification.** Real, specific recognition — species, models, scene
  types — where the on-device classifier only ever said "structure" or "plant".
  - In the viewer's Info panel, **Identify with AI** describes the photo and adds
    specific tags (e.g. *marble queen pothos, wood slat wall panel*).
  - The library **Analyze** button is now AI-powered: at a folder it asks **scan all
    vs the selected photos**, warns it uses your Claude usage, then runs in the
    background (cancellable, skips already-analyzed, saves as it goes).
  - **Settings → AI**: choose **Claude CLI** (your logged-in session, no key) or the
    **Anthropic API** (your key, stored in the Keychain) + an optional model.
  - AI tags fold into search + the "In your library" chips (specific tags first), and
    a **sparkles badge** marks photos that have a deep analysis.
- **Photo count + size on folder cards**, and **per-file sizes** (JPG and RAW listed
  separately) on photo tiles.

### Changed
- **Richer histogram** in the viewer: a luminance curve, tone-zone gridlines, a
  mean-tone marker, and bright edge bars when highlights/shadows clip, plus an
  always-on clip readout.
- **Dropped the local Vision tagging** (it could only produce generic labels).

### Fixed
- AI results no longer appear to vanish on revisit — browsing a folder reloads the
  saved tags + analysis state from the index.

## [1.4.1] — 2026-07-08

### Changed
- **Library grid fills the window width.** Bigger folder cards, and the content grows
  more columns as you widen the window instead of stranding a few cards or leaving
  empty side margins.
- **Sharper thumbnails.** Tiles now request a thumbnail scaled to their display size
  (so a large tile no longer upscales a fixed small one), and at High/Maximum quality
  NAS thumbnails fully decode the photo — skipping the tiny embedded JPEG thumbnail
  that made them look soft. RAW keeps using its (already large) embedded preview to
  avoid pulling whole RAW files per tile. Fast/Balanced stay quick over the NAS.

## [1.4.0] — 2026-07-08

### Added
- **Photo count and size on folder cards.** Each date-folder card in the Library now
  shows how many photos it holds and its total size, loaded lazily and cached so it
  doesn't slow down browsing.

### Changed
- **Changing thumbnail quality now rebuilds the cache — with a heads-up.** Picking a
  new quality asks to confirm ("Rebuild at <quality>?"), then clears the old cached
  thumbnails so photos regenerate at the new quality (the ones on screen update right
  away, the rest as you browse) instead of the setting only affecting new thumbnails.

### Note
- The Library already has a **Refresh** button (the ↻ icon in the header, ⌘R) that
  re-scans the current folder from the NAS and recounts the library.

## [1.3.0] — 2026-07-08

### Changed
- **One global rule for what happens on card insert — no per-card prompts.** Replaced
  the per-card "remember this card" model (and its "Always offload this card" /
  "Ignore this card" buttons) with a single setting: **Settings → Ingest → "When a
  card is inserted"** → **Offload automatically** / **Ask each time** / **Do nothing**.
  - Default is **Offload automatically**: insert a camera card and it ingests to the
    NAS with no prompt.
  - **Ask each time** shows a one-time Offload / Not now prompt on each insert (no
    per-card memory).
  - **Do nothing** ignores inserted cards.
  - Any stale per-card policy from earlier versions is dropped on upgrade.

## [1.2.4] — 2026-07-08

### Fixed
- **"SD Card" stayed in the Library sidebar after the card was ejected.** The Library
  tracked the card in an observation-ignored field, so `hasCard` never re-evaluated
  when the card left — the row only cleared if something else forced a redraw. It's
  now a proper observed value, so the "SD Card" entry appears and disappears in step
  with the card being mounted/removed.

## [1.2.3] — 2026-07-08

### Fixed
- **Re-inserted cards are now detected automatically and reliably.** The previous
  build leaned on a manual "Look for a card" button, which was the wrong answer.
  Root problem: detection trusted DiskArbitration's event stream to report when a
  card leaves, but on the built-in reader that removal event isn't always delivered
  (a card held busy by the Library, or a reader that keeps its disk object across
  swaps), which left a stale "already handled" marker so a genuine re-insert was
  swallowed. The watcher now **reconciles against ground truth**: a ~1.5 s poll
  compares what it thinks is mounted against the live kernel mount table and emits
  the missing removal on its own (after a short grace so a sub-second flap isn't
  mistaken for a removal). Re-insertion is picked up automatically, no button press.
  The "Look for a card" button stays as a harmless manual fallback.

## [1.2.2] — 2026-07-08

### Fixed
- **A re-inserted card sometimes wasn't detected (menu-bar icon stayed idle).** After
  a card had been handled once, the engine remembers it as "already handled this
  insertion" and only forgets that on a clean removal event. If that removal event
  never landed — e.g. the card sat busy in the Library window when it was pulled — a
  genuine re-insert got silently deduped, so nothing happened. Added a **"Look for a
  card"** button (in the tray's idle view and at the bottom of the Library sidebar)
  that force-re-checks every mounted volume, clearing the stale dedup markers so the
  card is picked up. It can't disturb an in-progress offload.

## [1.2.1] — 2026-07-08

### Changed
- **Ask for macOS volume permissions up front, not mid-transfer.** The first time
  the app touches your SD card or NAS, macOS prompts for removable-/network-volume
  access. Those prompts used to fire during the copy (the NAS one deep into the
  upload). Now, the moment a card is picked up, the app does a harmless read-only
  directory listing of the card and the NAS to trigger both prompts right then — so
  by the time an offload runs, access is already granted and nothing interrupts it.
  Read-only, so it never affects the wipe gate or the ghost-mount guard.
  - Note: because the app is ad-hoc signed (not yet notarized), macOS re-asks after
    each app update. Notarization with a Developer ID is the fix for that and is
    still on the list.

## [1.2.0] — 2026-07-08

### Added
- **Zoom and pan in the photo viewer.** Roll the mouse wheel to zoom in/out on the
  photo (centered on the cursor), then click-drag to pan around it. Trackpad pinch
  and two-finger scroll work too, and double-click toggles fit ↔ 2×. Zoom ranges
  from fit-to-view up to 8×. Built on AppKit's `NSScrollView` magnification so the
  gestures feel native (momentum, rubber-banding), with mouse-wheel zoom and a
  click-drag hand tool layered on top. Design + coordinate math were verified against
  the AppKit SDK headers before shipping.
  - The viewer's transparent letterbox still passes clicks through, so tapping the
    black margin closes the viewer and the arrow keys keep stepping between photos.

## [1.1.3] — 2026-07-08

### Changed
- **The tray popover now pops up on card insert even when the Library window is
  open.** 1.1.2 suppressed it (deferring to the Library's inline banner) because a
  transient popover can land behind a key window; it now raises the popover above
  that window and gives it focus, so you get the tray prompt AND the Library banner.

## [1.1.2] — 2026-07-08

### Fixed
- **Inserting a card while the Library window was open looked like nothing happened.**
  The offload prompt lived only in the menu-bar popover, which can't reliably present
  over an open (key) window — so with the Library up, an inserted card gave no way to
  start the offload. The Library now shows a "card ready" banner at the top (Always /
  Just once / Ignore) whenever a card is waiting, mirroring the popover prompt, and a
  card insert brings the Library forward instead of trying to pop a hidden popover
  over it. Detection itself was never the problem — the prompt just had nowhere to go.

## [1.1.1] — 2026-07-08

### Fixed
- **Settings… in the tray gear menu did nothing.** After the 1.1.0 AppKit rework,
  Settings was opened via the private `showSettingsWindow:` selector, which walks the
  responder chain — and an accessory app's status-item context has no key window
  there, so the action found no target. Settings is now an AppKit-managed window on
  the same path as Library and History, so it opens reliably. (⌘, still works too.)

## [1.1.0] — 2026-07-08

### Changed
- **Inserting a card now pops the tray open.** The menu-bar tray (the popover you
  used to click the icon for) opens on its own when a card goes in, so you see the
  consent prompt and live progress without hunting for the icon. Previously the
  Library window opened instead. Toggle in Settings → General → "Pop open the tray
  when a card is inserted" (default on).
- The Library still auto-reveals the uploaded batch when an offload finishes; that's
  now its own setting ("Reveal uploaded photos in the Library when an offload
  finishes"), separate from the tray behavior above.

### Internal
- Reworked the menu-bar layer from SwiftUI's `MenuBarExtra` to AppKit
  (`NSStatusItem` + `NSPopover`). `MenuBarExtra` has no API to open its window in
  code; the AppKit layer can, which is what makes the pop-on-insert behavior
  possible. The Library and History windows are now AppKit-managed as well; Settings
  remains a SwiftUI scene. No change to the offload/verify/wipe engine.

## [1.0.9] — 2026-07-06

### Added
- **Watch progress without opening the menu.** When a card is inserted, the Library
  window opens with a live offload banner at the top (card, %, card→Mac / Mac→NAS
  bars, ETA, pause/resume). Toggle in Settings → General → "Show the Library window
  during and after offload" (default on).
- **Reveal the uploaded batch.** When an offload finishes, the Library jumps to the
  folder that received the batch (the busiest YYYY/MM/DD day), with a full breadcrumb.
- **Opt-in NAS pre-warm** (Settings → Performance, default off): on card insert, a
  read-only check wakes the NAS connection and spins up the drives so the first
  upload doesn't stall for a few seconds. Never writes; independent of the wipe gate.

## [1.0.8] — 2026-07-06

### Added
- **Faces source.** A new **Faces** entry in the sidebar shows a gallery of every
  named person/pet (cover, name, photo count). Tap one to see all of their photos.
- **Pin folders to the sidebar.** Right-click any folder → **Pin to Sidebar** for
  quick access to your favorite or most-active folders; pinned folders open straight
  to that folder with a full breadcrumb. Unpin from the row's context menu. Pins
  persist locally.

### Changed
- Renamed the sidebar's "Sources" header to "Library"; the header hides folder/
  storage chrome for the Favorites and Faces sources.

## [1.0.7] — 2026-07-06

### Changed
- **Recognize many more RAW formats in the Library** — broadened from the mainstream
  brands to ~25 formats (Canon `crw`, Nikon `nrw`, Sony `sr2`/`srf`, Leica `rwl`,
  Sigma `x3f`, Phase One `iiq`/`cap`, Hasselblad `fff`, Mamiya `mef`, Minolta `mrw`,
  Kodak `dcr`/`kdc`/`k25`, Epson `erf`, GoPro `gpr`, and more). This affects Library
  recognition only (RAW+JPEG pairing, the RAW label, showing/counting tiles); the
  offload itself was already format-agnostic — every file under the camera folders is
  copied and verified regardless of extension, so no RAW is ever skipped.

## [1.0.6] — 2026-07-06

### Added
- **Jump to a session from the popover.** Clicking a recent session in the menu-bar
  popover opens the History window and selects + scrolls to that session.

### Fixed
- **Sidebar stays usable while viewing a photo.** The image viewer covered the whole
  window, so the sidebar toggle appeared to do nothing. The viewer now fills only the
  detail pane — the sidebar stays put and its toggle works (collapse for a near-full
  view, expand to switch sources). Switching source also closes the viewer.

## [1.0.5] — 2026-07-06

### Added
- **Favorites.** Heart a photo — in the viewer (heart button or the **F** key) or a
  grid tile's context menu — and it appears in a new **Favorites** source. Favorited
  tiles show a heart badge, and favorites persist locally.
- **Favorites timeline.** The Favorites source shows an Apple-Photos-style
  chronological view: month sections (oldest → newest) with sticky headers and a
  year strip to jump around; tap a photo to open it. Files removed on disk are
  pruned from favorites automatically.

## [1.0.4] — 2026-07-06

### Added
- **Dock icon while a window is open.** The Library/History windows now get a Dock
  icon and app-switcher (⌘-Tab) entry so you can flip back to them; the app returns
  to menu-bar-only once the last window closes.
- **Histogram in the photo viewer** — an additive RGB histogram at the bottom of the
  Info panel, computed off-main from a small embedded-preview decode (cheap over SMB).
- **Exposure read** under the histogram: a plain-English verdict (Well exposed /
  Underexposed / Overexposed / Low contrast) from the luminance distribution, with
  average brightness and shadow/highlight clipping. A guide, not a score.

### Fixed
- **Stop re-checking an idle card.** A card left in the reader with auto-eject off
  was re-scanned repeatedly, caused by an exFAT/FSKit volume-path "flap" that looked
  like unmount→remount. The watcher now debounces a path loss (a real removal via
  DiskDisappeared still fires instantly), and the engine ignores duplicate mount
  signals for a card it already handled this insertion — while still resuming an
  interrupted session and re-checking a genuinely re-inserted card.

## [1.0.3] — 2026-07-06

### Added
- **Refresh in the Library** — a Refresh button (⌘R) that re-scans the current
  folder and recounts the library, plus an automatic re-scan of the current folder
  when the app regains focus. Files changed on disk externally (e.g. deleted in
  Finder) now show up without relaunching.
- **Faces review queue + filtering.** The header's "N to review" is now a button
  that filters to photos still holding an unnamed face/pet to label. The Faces menu
  gains a People and a Pets submenu — pick any name (or "All people" / "All pets")
  to filter the grid to matching photos. An active filter shows a chip with the
  match count and a clear (✕) button. All on-device.

## [1.0.2] — 2026-07-05

A Library-focused release: sharper thumbnails, a much smoother/steadier grid over
the NAS, a packed photo inspector, and clearer navigation.

### Added
- **Thumbnail quality setting** (Settings → Library): Fast / Balanced / High /
  Maximum. Higher decodes the full photo for crisper thumbnails; default is High.
- **Per-file delete choices** for a JPEG+RAW pair — delete both, just the RAW, or
  just the JPEG — in the viewer and the grid context menu.
- **Much richer photo inspector**: per-file JPEG vs RAW sizes; 35 mm-equivalent
  focal length, exposure compensation, shooting mode, exposure mode, metering,
  white balance, scene type, flash, colour profile, camera software/firmware,
  camera & lens serials; GPS altitude and heading; and the photo's folder path.
  The inspector now stays open (persisted) and sits **beside** the image instead of
  over it, so the whole photo is visible.
- **Primary Library and History buttons** in the popover footer (previously hidden
  behind the gear menu, which now holds Settings and Quit).
- `Scripts/install-app.sh` — build and replace the /Applications copy in one step.

### Changed
- **Folder tiles now read as folders** — a tab, a framed photo-collage preview, and
  a label bar with the date and an open chevron, instead of a bare collage.
- **Larger, clearer breadcrumb** for the current folder path.

### Performance
- **Bounded thumbnail memory.** Caches now have a byte budget (not just a count),
  so browsing can't accumulate 1+ GB of decoded bitmaps.
- **Cheap thumbnails over SMB.** NAS thumbnails use the file's embedded preview
  instead of downloading the whole RAW/JPEG per tile; local card browsing still
  full-decodes. Same on-screen sharpness, far less wire traffic.
- **Cancellable, off-main decoding.** Scrolled-away tiles stop decoding and free
  their slot; cached tiles decode off the main thread so scroll-back doesn't hitch.
- Cached the grid's item grouping (was recomputed on every tap/render) and flattened
  the folder-tile shadow to avoid an offscreen render per card.

### Fixed
- RAW-only photos are no longer mislabeled "JPEG + RAW" in the inspector and grid.
- A failed delete now surfaces an alert instead of the file silently reappearing.

## [1.0.1] — 2026-07-05

Post-release QA hardening — a full adversarial review of the 1.0.0 code turned up
a set of reachable defects (concurrency, second-copy resume, faces-privacy, and a
viewer crash); all are fixed here. No data was lost in normal use, but a couple of
these could have, in specific interrupted-then-reconfigured scenarios.

### Fixed — data safety
- **Two sessions could start at once (critical).** The "one session at a time"
  guard was a check-then-act race across `await` points: a card event interleaving
  with user consent could launch a second `SessionRunner` that no control
  (pause/cancel/wipe) could reach — it would run to its own wipe uncontrolled. A
  start is now reserved synchronously before the first suspension.
- **Resume could wipe with only one copy when a second drive was enabled after the
  fact.** If files were NAS-verified with no second destination, the session was
  interrupted, and you *then* turned on a second drive, resume treated those files
  as settled and skipped the second copy — yet still wiped the card. Resume now
  backfills the second copy (sourcing from the NAS) before wiping, **and** the wipe
  gate now refuses to delete any card file that isn't present on the configured
  second drive. New harness mode `secondary-resume` proves it.
- A queued card pulled from the reader before its turn no longer starts a spurious
  session against a ghost mount.

### Fixed — privacy (faces)
- **"Delete all face data" now removes every sidecar.** A recovered-from-corruption
  `.damaged` copy of the face/identity index (full embeddings) was left behind by
  the wipe; it is now purged along with the main file and `.bak`.
- The `.bak` copy of the face/identity index is now hardened (owner-only,
  excluded from backups/sync) like the main file, instead of being written with
  default permissions and swept into Time Machine / iCloud.

### Fixed — viewer / library
- **A single photo with a malformed EXIF shutter (0, ∞, NaN) crashed the whole
  Library grid** via a trapping `Double`→`Int` conversion. Guarded, and such values
  are filtered at read time.
- A delete that fails on disk (read-only volume, locked file) is now surfaced with
  an alert instead of the photo silently vanishing and reappearing on reload.
- Date folders with an out-of-range day (e.g. `2026/02/31`) fall back to the raw
  name instead of rolling forward to the wrong day (Mar 3).
- The card-free ETA can no longer briefly exceed the 72 h sanity clamp.

## [1.0.0] — 2026-07-05

First public release (as **SD Offload**).

### Renamed
- **The app is now "SD Offload"** (was "Offload") — repo `t0nyz0/SD-Offload`, bundle id
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
- **Auto-queue for multiple cards.** Insert a card while one's already offloading and
  it's queued and started automatically when the current one finishes (FIFO) — stack
  several readers and walk away. A queued card pulled before its turn is dropped; the
  busy card is never interrupted. (Previously it just told you to re-insert later.)
- **Optional second verified copy, before any wipe.** Point SD Offload at a second
  local/external drive in Settings and every photo is mirrored there and read back
  **uncached** too — a file isn't wipe-eligible until it's confirmed on **both** the
  NAS and the second drive, so an auto-wipe never leaves a single copy standing. Off
  by default; a second-drive failure blocks the whole wipe (the wipe gate is
  unchanged — a file simply can't reach the safe state until both destinations
  verify). Validated by two new harness modes (`secondary`, `chaos-secondary`).
- **Named faces & pets (on-device, opt-in).** A "Find Faces" pass detects faces and
  pets with Apple Vision (on the Neural Engine); the photo viewer's info inspector
  lets you name them ("Elizabeth", "Hurley"), confirm/reject suggestions, and it
  learns from each label. Names become searchable alongside content tags. Everything
  is stored **locally only** — owner-only files, excluded from backups/cloud sync —
  behind a one-time consent, with a "Delete all face data" control. Honest limit: the
  v1 grouping is a starting point you confirm (it never auto-labels); a stronger
  bundled face model is planned for higher accuracy.
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
