# Offload — Agents Guide

Offload is a personal macOS menu bar app (a single machine): insert an SD card → it copies
everything to local staging, then to the NAS (`/Volumes/Photos`, date folders `YYYY/MM/DD`),
verifies SHA-256 end-to-end, and only then wipes + ejects the card. Menu bar icon shows live
progress; popover shows speeds, dual ETAs, history; Library window browses NAS + card.

## Targets

| Target | Owns |
| --- | --- |
| `OffloadCore` | Codable models, settings, journal types, JSON store (atomic + `.bak`), paths |
| `OffloadEngine` | ALL disk/network IO: DiskArbitration watcher, copy pipeline, verify, wipe, NAS locator, speed meter, library indexer |
| `OffloadApp` | SwiftUI menu bar app. Never touches files directly — consumes `EngineEvent`s, calls `EngineControlling` intents |

## Hard rules

1. **The wipe path is destructive.** Never exercise it against a real mounted card during
   development. Use `OFFLOAD_DEMO=1` (scripted DemoEngine) or the DMG test harness
   (`Tests/` + `hdiutil`). Any change near deletion must keep the UI's "card has NOT been
   wiped" reassurance truthful.
2. **Commit early, commit often, always push** (`t0nyz0/offload`, branch `main`). The repo owner is the
   sole author of every commit — never add a `Co-Authored-By` trailer.
3. **No cron, no launchd.** The one sanctioned persistence is the `SMAppService` launch-at-login
   login item.
4. **Zero external dependencies.** System frameworks only.
5. Bump `VERSION` once per meaningful session and **add a `CHANGELOG.md` entry
   for every user-visible change** (Added / Fixed / Changed). Build number = git
   commit count (build-app.sh).

## Build / run / verify

```bash
swift build                      # compile check
swift test                       # unit tests (safety-critical logic lives here)
swift run OffloadApp             # dev run — menu bar icon appears; NO Dock icon
bash Scripts/build-app.sh        # assemble build/Offload.app (LSUIElement, icon, ad-hoc signed)
pkill -9 -f Offload; open build/Offload.app   # relaunch ritual
```

Caveats under bare `swift run` (no .app bundle): `UNUserNotificationCenter` would crash and
`SMAppService` fails — both are bundle-guarded in code and only testable via `build-app.sh`
builds. First bundled run prompts for Removable Volumes + Network Volumes TCC; ad-hoc signing
re-prompts after rebuilds.

## v1.1 seam (do not build in MVP)

AI photo sorting will subprocess the logged-in `claude` CLI (`claude -p`, like
a companion app's `ClaudeCLIClient`) with output streamed into an in-app console. The seam is
the `EngineControlling` boundary + a post-verify phase hook. No Anthropic API key, ever.
