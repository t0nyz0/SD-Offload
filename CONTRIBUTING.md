# Contributing

Thanks for looking! SD Offload is a personal, open-source project — issues and PRs are
welcome, but it's maintained on a best-effort basis and not every PR will be merged.

## Ground rules

- **The wipe path is destructive.** Never exercise it against a real card in
  development — use `OFFLOAD_DEMO=1` or the test harness (`bash Scripts/harness.sh`).
  Any change near deletion must keep the "card is NOT wiped on failure" guarantee and
  the `WipeGate` preconditions intact, with the harness and unit tests passing.
- **Zero external dependencies.** System frameworks only (Foundation, SwiftUI, Vision,
  CryptoKit, ImageIO, DiskArbitration, NetFS, …). Please don't add packages.
- **Safety-critical logic is unit-tested.** Add or extend tests for anything touching the
  file state machine, wipe gate, or journal.

## Build, test, run

```bash
swift build                 # compile
swift test                  # unit tests
bash Scripts/harness.sh     # end-to-end wipe-path integration (fake card + NAS, no hardware)
bash Scripts/build-app.sh   # assemble build/SD Offload.app
```

macOS 14+ on Apple Silicon, Swift 6 toolchain. See `CLAUDE.md` for the architecture and
house rules.
