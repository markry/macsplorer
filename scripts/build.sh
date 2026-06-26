#!/usr/bin/env bash
#
# build.sh — compile MacSplorer with SwiftPM and assemble a runnable .app bundle.
#
# Needs only the Command Line Tools (Swift + the macOS SDK); no full Xcode.
# Produces build/MacSplorer.app, ad-hoc signed so it launches locally. Developer
# ID signing + notarization (for public releases) get layered on later, reusing
# the same pipeline as meeting-notifier.
#
# Usage:
#   bash scripts/build.sh            # release build
#   bash scripts/build.sh debug      # debug build
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
APP="build/MacSplorer.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/MacSplorerApp"
if [ ! -f "$BIN" ]; then
    echo "ERROR: build product not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacSplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> ad-hoc signing for local run"
codesign --force --sign - "$APP"

echo "==> done."
echo "    Launch with:  open \"$APP\""
