#!/bin/sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
OUTPUT="$REPO_ROOT/dist/server/hako-server-linux-amd64"
mkdir -p "$REPO_ROOT/dist/server"
cd "$ROOT"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$OUTPUT" ./cmd/hako-server
printf 'Published: %s\n' "$OUTPUT"
