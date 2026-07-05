#!/bin/bash
# Build "SD Offload.app" and install it into /Applications, replacing any existing
# copy (quitting a running instance first). It's a local ad-hoc-signed build, so
# there's no Gatekeeper quarantine to clear — this is the fast "update the app I
# actually use" path, separate from Scripts/release.sh (which packages a zip).
set -euo pipefail
cd "$(dirname "$0")/.."

bash Scripts/build-app.sh

APP="build/SD Offload.app"
DEST="/Applications/SD Offload.app"

# Quit a running instance so the bundle isn't in use while we replace it.
pkill -9 -f "SD Offload.app" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$APP" "$DEST"
# Strip any quarantine inherited from a previously downloaded copy at this path.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
echo
echo "==> installed SD Offload $VERSION (build $BUILD) → $DEST"
echo "    launch:  open \"$DEST\""
