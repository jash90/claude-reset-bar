#!/bin/bash
# Buduje ClaudeResetBar dla bieżącego systemu, albo dla wszystkich trzech z flagą --all.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
mkdir -p build

# Self-check logiki resetu i ikony — build nie przechodzi, jeśli asercja padnie.
go build -o build/.selfcheck . && ./build/.selfcheck --test && rm -f build/.selfcheck

if [ "${1:-}" = "--all" ]; then
    # macOS wymaga CGO (AppKit), więc buduje się tylko natywnie, pod architekturę
    # tej maszyny. Windows i Linux idą przez czyste Go — kompilacja krzyżowa działa.
    go build -o "build/claude-reset-bar-$(go env GOOS)-$(go env GOARCH)" .
    GOOS=windows GOARCH=amd64 go build -o build/claude-reset-bar.exe .
    GOOS=linux   GOARCH=amd64 go build -o build/claude-reset-bar-linux-amd64 .
    GOOS=linux   GOARCH=arm64 go build -o build/claude-reset-bar-linux-arm64 .
else
    go build -o build/claude-reset-bar .
fi

ls -la build/
