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
    VERSION="$VERSION" "$DIR/build.sh" >/dev/null
    APP="$DIR/build/ClaudeResetBar.app"
    ZIP="$DIST/ClaudeResetBar-$VERSION-macos-arm64.zip"
    # ditto preserves bundle attributes that a plain zip drops. We pack the .app alone —
    # without --sequesterRsrc, which adds a __MACOSX folder, and with the parent named
    # explicitly so extraction yields the app itself, not the staging directory.
    ditto -c -k --keepParent "$APP" "$ZIP"

    # Notarization. Apple inspects the signed bundle and issues a ticket; stapling writes
    # that ticket into the app, so the first launch is an ordinary double-click even on a
    # machine that cannot reach Apple's service. The app is submitted as a zip: notarytool
    # mounts a .dmg to inspect it, and a mount left behind by an interrupted run wedges
    # every attempt after it.
    #
    # Credentials come either from an App Store Connect API key — the route the other
    # projects here use, and the one that survives an Apple ID password change:
    #   APPLE_API_KEY_ID=XXXXXXXXXX APPLE_API_ISSUER=<uuid> ./release.sh v1.0.0
    # (the key itself is looked up in ~/private_keys and ~/.appstoreconnect/private_keys,
    # or named with APPLE_API_KEY_PATH) — or from a stored notarytool profile:
    #   xcrun notarytool store-credentials claude-reset-bar \
    #     --apple-id you@example.com --team-id TEAMID --password app-specific-password
    # With neither, the release still ships, signed but unnotarized.
    NOTARY_ARGS=""
    if [ -n "${APPLE_API_ISSUER:-}" ] && [ -n "${APPLE_API_KEY_ID:-}" ]; then
        KEY="${APPLE_API_KEY_PATH:-$HOME/private_keys/AuthKey_$APPLE_API_KEY_ID.p8}"
        [ -f "$KEY" ] || KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$APPLE_API_KEY_ID.p8"
        NOTARY_ARGS="--key $KEY --key-id $APPLE_API_KEY_ID --issuer $APPLE_API_ISSUER"
    elif xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-claude-reset-bar}" >/dev/null 2>&1; then
        NOTARY_ARGS="--keychain-profile ${NOTARY_PROFILE:-claude-reset-bar}"
    fi

    if [ -n "$NOTARY_ARGS" ]; then
        echo "── notarization ─────────────────────────────────────"
        xcrun notarytool submit "$ZIP" $NOTARY_ARGS --wait --timeout 30m
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        spctl -a -vvv "$APP"
    else
        echo "── notarization skipped (no App Store Connect key, no notarytool profile) ──"
    fi
else
    echo "── macOS package skipped (only builds on macOS) ─────"
fi

echo
ls -la "$DIST"
