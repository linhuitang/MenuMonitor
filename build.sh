#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building MenuMonitor (release)..."
swift build -c release

BIN=".build/release/MenuMonitor"
APP="MenuMonitor.app"
APP_DIR="$APP/Contents"
MACOS_DIR="$APP_DIR/MacOS"

echo "==> Assembling $APP..."
rm -rf "$APP"
mkdir -p "$MACOS_DIR"
cp "$BIN" "$MACOS_DIR/MenuMonitor"

cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh-Hans</string>
	<key>CFBundleExecutable</key>
	<string>MenuMonitor</string>
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
rm -rf /Applications/MenuMonitor.app
cp -R "$APP" /Applications/MenuMonitor.app

echo "==> Launching..."
# Kill previous instance if any
pkill -x MenuMonitor 2>/dev/null || true
sleep 0.3
open /Applications/MenuMonitor.app

echo "Done. Look for the teal MEM badge in the menu bar."
