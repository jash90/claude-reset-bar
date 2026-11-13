#!/bin/bash
# Builds "Claude Reset Bar.app" from the Rust sources in rust/. Needs a Rust toolchain and the
# Xcode Command Line Tools.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/Claude Reset Bar.app"

# The hourglass is deliberately absent: the exhausted-window title spells out the
# remaining time instead, which stays legible where the glyph does not render.
if grep -n '⏳' "$DIR"/rust/src/*.rs "$DIR"/README.md 2>/dev/null; then
    echo "Hourglass character found in the sources listed above." >&2
    exit 1
fi

# The program is the Rust build. Its self-check runs first — the build fails if an
# assertion trips. With both Apple targets installed the binary is universal; otherwise it
# is built for this machine's processor only.
BIN_NAME="claude-reset-bar"
( cd "$DIR/rust" && cargo build --release --locked && ./target/release/$BIN_NAME --test )

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TARGETS="$(rustup target list --installed 2>/dev/null | grep -E '^(aarch64|x86_64)-apple-darwin$' || true)"
if [ "$(printf '%s\n' "$TARGETS" | grep -c .)" = 2 ]; then
    SLICES=()
    for target in $TARGETS; do
        ( cd "$DIR/rust" && cargo build --release --locked --target "$target" )
        SLICES+=("$DIR/rust/target/$target/release/$BIN_NAME")
    done
    lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/ClaudeResetBar"
else
    cp "$DIR/rust/target/release/$BIN_NAME" "$APP/Contents/MacOS/ClaudeResetBar"
fi

# Application icon. The PNG set comes from `rust/build/claude-reset-bar --icons assets`;
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

# The bundle carries the release number when one is given: VERSION=v1.4.1 ./build.sh
BUNDLE_VERSION="$(printf '%s' "${VERSION:-1.0}" | sed 's/^v//')"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Reset Bar</string>
  <key>CFBundleDisplayName</key><string>Claude Reset Bar</string>
  <key>CFBundleExecutable</key><string>ClaudeResetBar</string>
  <key>CFBundleIdentifier</key><string>local.claude-reset-bar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>${BUNDLE_VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${BUNDLE_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Signature. With a Developer ID certificate on the machine the download carries a real
# developer name and passes Gatekeeper's signature check; without one the ad-hoc signature
# still lets the app run locally. Set CODESIGN_IDENTITY to pick a specific certificate.
# The certificate is named by its SHA-1 hash, not its common name — a machine that has
# renewed the certificate holds two with the same name, and codesign refuses that as
# ambiguous.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application/ { print $2; exit }')}"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    echo "Signed: $IDENTITY"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "Signed ad-hoc — no Developer ID certificate on this machine."
fi
codesign --verify --strict --verbose=1 "$APP"

echo "Built: $APP"
