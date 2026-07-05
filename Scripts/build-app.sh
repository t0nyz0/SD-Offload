#!/bin/bash
# Assembles "build/SD Offload.app" from the SPM build.
# Version = VERSION file; build number = git commit count.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="SD Offload"
BIN_NAME="OffloadApp"          # SPM executable target name (internal, unchanged)
BUNDLE_ID="com.t0nyz0.sdoffload"
VERSION="$(cat VERSION | tr -d '[:space:]')"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER) release…"
xcrun swift build -c release

BIN_PATH="$(xcrun swift build -c release --show-bin-path | grep -E '^/' | tail -1)"
APP="build/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/$BIN_NAME" "$APP/Contents/MacOS/$APP_NAME"

# SPM resource bundles (Resources/ of each target).
for bundle in "$BIN_PATH"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/" || true
done

# --- Icon: icon-1024.png → AppIcon.icns -------------------------------------
ICON_SRC="Sources/OffloadApp/Resources/icon-1024.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for SZ in 16 32 128 256 512; do
    sips -z $SZ $SZ "$ICON_SRC" --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
    DBL=$((SZ * 2))
    sips -z $DBL $DBL "$ICON_SRC" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# --- Info.plist --------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.photography</string>
	<key>NSRemovableVolumesUsageDescription</key>
	<string>SD Offload reads your SD card to copy photos to your NAS, and erases it only after every file is verified.</string>
	<key>NSNetworkVolumesUsageDescription</key>
	<string>SD Offload copies verified photos to your NAS share.</string>
	<key>NSHumanReadableCopyright</key>
	<string>© Tony Zolnoski</string>
</dict>
</plist>
PLIST

# Ad-hoc signing: unsigned bundles get flakier TCC treatment. Note: the cdhash
# changes on every rebuild, so macOS re-prompts Removable Volumes access after
# rebuilds. If that gets annoying, a stable self-signed identity is the upgrade.
codesign --force --deep -s - "$APP"

echo "==> Built $APP"
echo "    relaunch: pkill -9 -f 'SD Offload'; open \"$APP\""
