#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
SOURCE="$SCRIPT_DIR/RubyOverlayMac.swift"
BINARY="$BUILD_DIR/RubyOverlayMac"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc was not found. Install Xcode Command Line Tools with: xcode-select --install" >&2
  exit 1
fi

if [ ! -x "$BINARY" ] || [ "$SOURCE" -nt "$BINARY" ]; then
  mkdir -p "$BUILD_DIR"
  swiftc "$SOURCE" -o "$BINARY" -framework AppKit
fi

exec "$BINARY" --project-root "$PROJECT_ROOT" "$@"
