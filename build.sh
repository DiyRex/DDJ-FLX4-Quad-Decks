#!/bin/bash
# Builds dist/FLX4 4Deck.app and dist/FLX4-4Deck.dmg.  Usage: ./build.sh [--test]
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FLX4 4Deck"
VERSION="1.0.0"
APP="dist/$APP_NAME.app"
RB_CSV="/Applications/rekordbox 7/rekordbox.app/Contents/Resources/MidiMappings/DDJ-FLX4.midi.csv"

echo "==> mappings"
# Regenerate from the installed rekordbox's own FLX4 default when available.
if [ -f "$RB_CSV" ]; then
  python3 -I tools/gen_mappings.py "$RB_CSV" Resources/mappings
else
  echo "    rekordbox 7 not found; using the committed Resources/mappings"
fi

echo "==> compile"
swift build -c release
BIN=".build/release/FLX4Deck"
"$BIN" --selftest > /dev/null || { "$BIN" --selftest; exit 1; }
echo "    self-test passed"

if [ "${1:-}" = "--test" ]; then
  echo "==> CoreMIDI end-to-end test"
  if pgrep -f "FLX4 4Deck.app/Contents/MacOS" >/dev/null; then
    echo "    quit FLX4 4Deck first (it owns the FLX4-4DECK device the test needs)"; exit 1
  fi
  swiftc -O tests/e2e.swift -o .build/e2e
  .build/e2e "$PWD/$BIN"
fi

echo "==> icon"
mkdir -p .build/icon
swiftc -O tools/make_icon.swift -o .build/make_icon
rm -rf .build/icon/AppIcon.iconset
.build/make_icon .build/icon/AppIcon.iconset
iconutil -c icns .build/icon/AppIcon.iconset -o .build/icon/AppIcon.icns

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mappings"
cp "$BIN" "$APP/Contents/MacOS/FLX4Deck"
cp Resources/mappings/*.csv "$APP/Contents/Resources/mappings/"
cp .build/icon/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>local.flx4-4deck</string>
  <key>CFBundleExecutable</key><string>FLX4Deck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"

echo "==> dmg"
STAGE=".build/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp README.md "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f dist/FLX4-4Deck.dmg
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO dist/FLX4-4Deck.dmg

echo "==> done"
ls -lh dist/
