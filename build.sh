#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building MenuMonitor (release)..."
swift build -c release

BIN=".build/release/MenuMonitor"
# Assemble in a temp dir (not the project folder) so Spotlight/Launchpad
# never index a second copy next to /Applications/MenuMonitor.app.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/MenuMonitor-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/MenuMonitor.app"
APP_DIR="$APP/Contents"
MACOS_DIR="$APP_DIR/MacOS"

echo "==> Assembling MenuMonitor.app..."
mkdir -p "$MACOS_DIR"
cp "$BIN" "$MACOS_DIR/MenuMonitor"
mkdir -p "$APP_DIR/Resources"
cp assets/AppIcon.icns "$APP_DIR/Resources/AppIcon.icns"
cp assets/AppIcon-1024.png "$APP_DIR/Resources/AppIcon-1024.png"

cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleExecutable</key>
	<string>MenuMonitor</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.ankii.menumonitor</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MenuMonitor</string>
	<key>CFBundleDisplayName</key>
	<string>MenuMonitor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesign..."
codesign --force --deep -s - "$APP"

echo "==> Installing to /Applications..."
# Quit the running copy before replacing it
pkill -x MenuMonitor 2>/dev/null || true
sleep 0.3
rm -rf /Applications/MenuMonitor.app
cp -R "$APP" /Applications/MenuMonitor.app

# Forget a stale in-project copy from older build.sh versions, if LaunchServices still has it
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$PWD/MenuMonitor.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -f /Applications/MenuMonitor.app >/dev/null 2>&1 || true
fi

echo "==> Launching..."
open /Applications/MenuMonitor.app

echo "Done. Look for the memory percent label in the menu bar."
