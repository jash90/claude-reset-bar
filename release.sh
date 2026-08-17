#!/bin/bash
# Składa paczki do wydania w dist/. Wersję podaje się argumentem, np. ./release.sh v1.0.0
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${1:-dev}"
DIST="$DIR/dist"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "── ikony ────────────────────────────────────────────"
(cd "$DIR/cross" && go build -o build/.icons . && ./build/.icons --icons "$DIR/assets" && rm -f build/.icons)

echo "── binarki przenośne ────────────────────────────────"
(cd "$DIR/cross" && ./build.sh --all)

echo "── paczka Windows ───────────────────────────────────"
WIN="$DIST/win/claude-reset-bar"
mkdir -p "$WIN"
cp "$DIR/cross/build/claude-reset-bar.exe" "$WIN/"
cp "$DIR/assets/icon.ico" "$DIR/README.md" "$DIR/LICENSE" "$WIN/"
# Zawartość w podkatalogu, żeby rozpakowanie nie rozsypało plików po katalogu docelowym.
(cd "$DIST/win" && zip -qr "$DIST/claude-reset-bar-$VERSION-windows-amd64.zip" claude-reset-bar)
rm -rf "$DIST/win"

echo "── paczki Linux ─────────────────────────────────────"
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
Comment=Limity Claude w zasobniku systemowym
Exec=claude-reset-bar
Icon=claude-reset-bar
Terminal=false
Categories=Utility;
DESKTOP
    (cd "$DIST/linux-$arch" && tar czf "$DIST/claude-reset-bar-$VERSION-linux-$arch.tar.gz" claude-reset-bar)
    rm -rf "$DIST/linux-$arch"
done

# macOS buduje się tylko na macOS — AppKit wymaga CGO i lokalnego SDK.
if [ "$(uname)" = "Darwin" ]; then
    echo "── paczka macOS ─────────────────────────────────────"
    "$DIR/build.sh" >/dev/null
    # ditto zachowuje atrybuty bundla, których zwykły zip gubi. Pakujemy sam .app —
    # bez --sequesterRsrc, bo dokłada katalog __MACOSX, i z parentem wskazanym wprost,
    # żeby po rozpakowaniu na wierzchu leżała aplikacja, a nie katalog roboczy.
    ditto -c -k --keepParent "$DIR/build/ClaudeResetBar.app" \
        "$DIST/ClaudeResetBar-$VERSION-macos-arm64.zip"
else
    echo "── paczka macOS pominięta (buduje się tylko na macOS) ─"
fi

echo
ls -la "$DIST"
