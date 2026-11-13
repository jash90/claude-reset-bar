#!/bin/bash
# Builds Claude Reset Bar for the current system, or for all three with --all.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
mkdir -p build

# The hourglass is deliberately absent: the exhausted-window title spells out the
# remaining time instead, which stays legible where the glyph does not render.
if grep -n '⏳' "$DIR"/src/*.rs "$DIR"/../README.md 2>/dev/null; then
    echo "Hourglass character found in the sources listed above." >&2
    exit 1
fi

# Self-check of the reset logic and icon generation — the build fails if an assertion trips.
cargo build --release
./target/release/claude-reset-bar --test

case "$(uname -s)" in
    Darwin) HOST_OS=darwin ;;
    Linux)  HOST_OS=linux ;;
    *)      HOST_OS=windows ;;
esac
case "$(uname -m)" in
    arm64|aarch64) HOST_ARCH=arm64 ;;
    *)             HOST_ARCH=amd64 ;;
esac

if [ "${1:-}" = "--all" ]; then
    # Windows and Linux are cross-compiled with zig as the linker, so no Windows SDK and
    # no Linux sysroot is needed: brew install zig && cargo install cargo-zigbuild.
    # macOS only builds natively, for this machine's architecture.
    for tool in zig cargo-zigbuild; do
        command -v "$tool" >/dev/null || { echo "$tool is required for --all." >&2; exit 1; }
    done
    TARGETS="x86_64-pc-windows-gnu x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu"
    if command -v rustup >/dev/null; then
        rustup target add $TARGETS >/dev/null
    fi
    for target in $TARGETS; do
        cargo zigbuild --release --target "$target"
    done
    cp target/release/claude-reset-bar "build/claude-reset-bar-$HOST_OS-$HOST_ARCH"
    cp target/x86_64-pc-windows-gnu/release/claude-reset-bar.exe build/claude-reset-bar.exe
    cp target/x86_64-unknown-linux-gnu/release/claude-reset-bar build/claude-reset-bar-linux-amd64
    cp target/aarch64-unknown-linux-gnu/release/claude-reset-bar build/claude-reset-bar-linux-arm64
else
    cp target/release/claude-reset-bar build/claude-reset-bar
fi

ls -la build/
