#!/bin/bash
# Buduje ClaudeResetBar.app. Bez zależności — wystarczy Xcode Command Line Tools.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/ClaudeResetBar.app"

# Self-check logiki wykrywania resetu — build nie przechodzi, jeśli assert padnie.
swiftc -Onone "$DIR/src/main.swift" -o "$DIR/build/.selfcheck" -module-name ClaudeResetBar 2>/dev/null \
  || { mkdir -p "$DIR/build"; swiftc -Onone "$DIR/src/main.swift" -o "$DIR/build/.selfcheck" -module-name ClaudeResetBar; }
"$DIR/build/.selfcheck" --test

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O "$DIR/src/main.swift" -o "$APP/Contents/MacOS/ClaudeResetBar" -module-name ClaudeResetBar

# Ikona aplikacji. Zestaw PNG-ów generuje `cross/claude-reset-bar --icons assets`;
# iconutil składa z nich .icns, którego wymaga Finder i Dock.
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

echo "Zbudowano: $APP"
