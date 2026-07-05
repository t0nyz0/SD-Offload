#!/bin/bash
# Builds "SD Offload.app" (release) and packages it as a distributable zip for a
# GitHub Release. Prints the size + SHA-256 so the release notes can list them.
#
# NOTE: the app is ad-hoc signed, not notarized — a downloaded copy is quarantined
# by Gatekeeper, so the release notes must tell users to clear the quarantine
# (`xattr -dr com.apple.quarantine`) or build from source. Notarization (Apple
# Developer Program) is the eventual fix; see the README's Status section.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION | tr -d '[:space:]')"
bash Scripts/build-app.sh

APP="build/SD Offload.app"
ZIP="build/SD-Offload-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "==> packaged $ZIP"
echo "    version: $VERSION"
echo "    size:    $(du -h "$ZIP" | cut -f1 | tr -d ' ')"
echo "    sha256:  $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
