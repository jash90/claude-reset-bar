#!/bin/bash
# Builds ClaudeResetBar.app. No dependencies — Xcode Command Line Tools are enough.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/ClaudeResetBar.app"

# The hourglass is deliberately absent: the exhausted-window title spells out the
# remaining time instead, which stays legible where the glyph does not render.
if grep -n '⏳' "$DIR"/src/*.swift "$DIR"/cross/*.go "$DIR"/README.md 2>/dev/null; then
    echo "Hourglass character found in the sources listed above." >&2
    exit 1
fi

# Self-check of the reset-detection logic — the build fails if an assertion trips.
swiftc -Onone "$DIR/src/"*.swift -o "$DIR/build/.selfcheck" -module-name ClaudeResetBar 2>/dev/null \
  || { mkdir -p "$DIR/build"; swiftc -Onone "$DIR/src/"*.swift -o "$DIR/build/.selfcheck" -module-name ClaudeResetBar; }
"$DIR/build/.selfcheck" --test

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O "$DIR/src/"*.swift -o "$APP/Contents/MacOS/ClaudeResetBar" -module-name ClaudeResetBar

# Application icon. The PNG set comes from `cross/claude-reset-bar --icons assets`;
# iconutil assembles the .icns that Finder and the Dock require.
if [ -f "$DIR/assets/icon_1024.png" ]; then
    ICONSET="$DIR/build/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
                "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
                "512 512x512" "1024 512x512@2x"; do
        set -- $pair
        cp "$DIR/assets/icon_$1.png" "$ICONSET/icon_$2.png"
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeResetBar</string>
  <key>CFBundleExecutable</key><string>ClaudeResetBar</string>
  <key>CFBundleIdentifier</key><string>local.claude-reset-bar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
rm -f "$DIR/build/.selfcheck"

echo "Built: $APP"
