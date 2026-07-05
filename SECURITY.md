# Security Policy

SD Offload copies files off SD cards, verifies them, and **erases the card** once every
file is confirmed on the NAS. Because it deletes data, security and correctness reports
are taken seriously.

## Reporting a vulnerability

Please report security issues **privately**, not in public issues:

- Use GitHub's **[Report a vulnerability](https://github.com/t0nyz0/sd-offload/security/advisories/new)**
  (the repo's Security → Advisories tab), or
- open a normal issue **only** for non-sensitive, non-exploitable bugs.

Include repro steps and the affected version (`VERSION` / the build number).

## Areas of particular interest

- Anything that could let the wipe gate erase a card whose files are **not** provably on
  the NAS (`Sources/OffloadEngine/WipeGate.swift`, `SessionRunner.swift`).
- Anything that could delete or overwrite data outside the intended card/NAS paths.
- Handling of NAS credentials (Keychain) and, once shipped, locally-stored photo
  face/pet data.

## Build & inspect

The app is ad-hoc signed and distributed as source — build it yourself and inspect the
destructive path before trusting it with a real card. No prebuilt binaries are published;
if any are ever offered they will be Developer ID-signed and notarized.
