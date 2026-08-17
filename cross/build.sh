#!/bin/bash
# Builds ClaudeResetBar for the current system, or for all three with --all.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
mkdir -p build

# The interface is deliberately plain text. Fail the build if a pictographic character
# creeps back into the sources, where it would render inconsistently across fonts,
# terminals and screen readers.
if grep -n '[⚙⏳⚠●○️︎]' "$DIR"/../src/*.swift "$DIR"/*.go "$DIR"/../README.md 2>/dev/null; then
    echo "Pictographic characters found in the sources listed above." >&2
    exit 1
fi

# Self-check of the reset logic and icon generation — the build fails if an assertion trips.
go build -o build/.selfcheck . && ./build/.selfcheck --test && rm -f build/.selfcheck

if [ "${1:-}" = "--all" ]; then
    # macOS needs CGO (AppKit), so it only builds natively, for this machine's
    # architecture. Windows and Linux are pure Go — cross-compilation works.
    go build -o "build/claude-reset-bar-$(go env GOOS)-$(go env GOARCH)" .
    GOOS=windows GOARCH=amd64 go build -o build/claude-reset-bar.exe .
    GOOS=linux   GOARCH=amd64 go build -o build/claude-reset-bar-linux-amd64 .
    GOOS=linux   GOARCH=arm64 go build -o build/claude-reset-bar-linux-arm64 .
else
    go build -o build/claude-reset-bar .
fi

ls -la build/
