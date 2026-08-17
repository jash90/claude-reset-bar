#!/bin/bash
# Assembles release packages into dist/. Pass the version as an argument, e.g. ./release.sh v1.0.0
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-dev}"
DIST="$DIR/dist"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "── icons ────────────────────────────────────────────"
(cd "$DIR/cross" && go build -o build/.icons . && ./build/.icons --icons "$DIR/assets" && rm -f build/.icons)

echo "── portable binaries ────────────────────────────────"
(cd "$DIR/cross" && ./build.sh --all)

echo "── Windows package ──────────────────────────────────"
WIN="$DIST/win/claude-reset-bar"
mkdir -p "$WIN"
cp "$DIR/cross/build/claude-reset-bar.exe" "$WIN/"
cp "$DIR/assets/icon.ico" "$DIR/README.md" "$DIR/LICENSE" "$WIN/"
# Contents nested in a folder so extracting does not scatter files into the target dir.
(cd "$DIST/win" && zip -qr "$DIST/claude-reset-bar-$VERSION-windows-amd64.zip" claude-reset-bar)
rm -rf "$DIST/win"

echo "── Linux packages ───────────────────────────────────"
for arch in amd64 arm64; do
    LIN="$DIST/linux-$arch/claude-reset-bar"
    mkdir -p "$LIN"
    cp "$DIR/cross/build/claude-reset-bar-linux-$arch" "$LIN/claude-reset-bar"
    cp "$DIR/assets/icon.png" "$LIN/claude-reset-bar.png"
    cp "$DIR/README.md" "$DIR/LICENSE" "$LIN/"
    cat > "$LIN/claude-reset-bar.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=ClaudeResetBar
Comment=Claude usage limits in the system tray
Exec=claude-reset-bar
Icon=claude-reset-bar
Terminal=false
Categories=Utility;
DESKTOP
    (cd "$DIST/linux-$arch" && tar czf "$DIST/claude-reset-bar-$VERSION-linux-$arch.tar.gz" claude-reset-bar)
    rm -rf "$DIST/linux-$arch"
done

# macOS only builds on macOS — AppKit needs CGO and the local SDK.
if [ "$(uname)" = "Darwin" ]; then
    echo "── macOS package ────────────────────────────────────"
    "$DIR/build.sh" >/dev/null
    # ditto preserves bundle attributes that a plain zip drops. We pack the .app alone —
    # without --sequesterRsrc, which adds a __MACOSX folder, and with the parent named
    # explicitly so extraction yields the app itself, not the staging directory.
    ditto -c -k --keepParent "$DIR/build/ClaudeResetBar.app" \
        "$DIST/ClaudeResetBar-$VERSION-macos-arm64.zip"
else
    echo "── macOS package skipped (only builds on macOS) ─────"
fi

echo
ls -la "$DIST"
