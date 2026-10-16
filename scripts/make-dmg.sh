#!/bin/bash
# Build a drag-to-Applications DMG for MenuMonitor.
# Usage: ./scripts/make-dmg.sh [path/to/MenuMonitor.app] [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:-}"
VERSION="${2:-1.0.0}"

if [[ -z "$APP" ]]; then
  if [[ -d "/Applications/MenuMonitor.app" ]]; then
    APP="/Applications/MenuMonitor.app"
  elif [[ -d "$ROOT/MenuMonitor.app" ]]; then
    APP="$ROOT/MenuMonitor.app"
  else
    echo "MenuMonitor.app not found. Run ./build.sh first, or pass the .app path." >&2
    exit 1
  fi
fi

if [[ ! -d "$APP" ]]; then
  echo "Not an app bundle: $APP" >&2
  exit 1
fi

BIN="$APP/Contents/MacOS/MenuMonitor"
if [[ ! -f "$BIN" ]]; then
  echo "Missing executable: $BIN" >&2
  exit 1
fi

ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
if echo "$ARCHS" | grep -q 'x86_64' && echo "$ARCHS" | grep -q 'arm64'; then
  SUFFIX="macOS-universal"
elif echo "$ARCHS" | grep -q 'arm64'; then
  SUFFIX="macOS-arm64"
elif echo "$ARCHS" | grep -q 'x86_64'; then
  SUFFIX="macOS-x86_64"
else
  SUFFIX="macOS-$(uname -m)"
fi

DMG_NAME="MenuMonitor-v${VERSION}-${SUFFIX}.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/MenuMonitor-dmg.XXXXXX")"
RW_DMG="$STAGE/MenuMonitor-rw.dmg"
VOL_NAME="MenuMonitor"
MNT="$STAGE/mnt"

cleanup() {
  if [[ -d "$MNT" ]] && mount | grep -q "$MNT"; then
    hdiutil detach "$MNT" -quiet -force 2>/dev/null || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

mkdir -p "$MNT" "$ROOT/dist"
# Staging folder that becomes the volume root
CONTENT="$STAGE/content"
mkdir -p "$CONTENT"
cp -R "$APP" "$CONTENT/MenuMonitor.app"
ln -s /Applications "$CONTENT/Applications"

# Create RW image, copy content, convert to UDZO
hdiutil create -volname "$VOL_NAME" -srcfolder "$CONTENT" -ov -format UDRW -fs HFS+ "$RW_DMG"
# Optional: leave room; srcfolder sizing is usually enough
OUT="$ROOT/dist/$DMG_NAME"
rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT"

SHA="$(shasum -a 256 "$OUT" | awk '{print $1}')"
echo "$SHA  $DMG_NAME" | tee "$OUT.sha256"
echo "Wrote $OUT"
echo "SHA256 $SHA"
echo "ARCHS $ARCHS"
