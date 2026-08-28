#!/bin/bash
# Builds RecBar.app via Swift Package Manager (no Xcode.app required — this machine only
# has the Command Line Tools) and assembles a proper .app bundle by hand.
#
# Usage:
#   ./build.sh              build dist/RecBar.app
#   ./build.sh --install    also copy it into /Applications, replacing any existing copy

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

APP_NAME="RecBar"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
if [ ! -f "$BIN_PATH" ]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> ad-hoc code signing"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> built: $APP_BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> installing to /Applications/$APP_NAME.app"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    # Don't leave the staging copy behind — a second .app named RecBar sitting under dist/
    # shows up alongside the installed one in Spotlight/Launchpad, which is confusing.
    rm -rf "$APP_BUNDLE"
    echo "==> installed: /Applications/$APP_NAME.app"
fi
