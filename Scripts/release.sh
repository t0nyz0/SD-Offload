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
DMG="build/SD-Offload-$VERSION.dmg"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Also build a drag-to-Applications .dmg (the friendlier download). A staging dir
# holds the app + an /Applications alias, compressed into a read-only image.
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SD Offload" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo
echo "==> packaged for release $VERSION"
for F in "$DMG" "$ZIP"; do
    echo "    $F"
    echo "      size:   $(du -h "$F" | cut -f1 | tr -d ' ')"
    echo "      sha256: $(shasum -a 256 "$F" | cut -d' ' -f1)"
done
echo
echo "    gh release create v$VERSION \"$DMG\" \"$ZIP\" --title \"SD Offload $VERSION\" --notes-file <notes>"
