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

# Prefer a stable Developer ID identity so macOS TCC permissions (folder access,
# Full Disk Access) persist across rebuilds — ad-hoc signing gets a new code
# identity every build and loses them, which breaks watching/reading protected
# folders (Desktop, Documents, cloud folders…). Falls back to ad-hoc when no
# Developer ID cert is present (e.g. for contributors).
IDENTITY="${IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
                | grep -o 'Developer ID Application: [^"]*' | head -1)"
fi
if [ -n "$IDENTITY" ]; then
    echo "==> signing with: $IDENTITY"
    # Hardened runtime + secure timestamp so the build is notarization-ready.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "==> ad-hoc signing for local run (no Developer ID cert found)"
    codesign --force --sign - "$APP"
fi

# Install to /Applications so it's easy to find/launch and lives at a stable
# path for Full Disk Access (with the Developer ID identity, that grant persists
# across rebuilds). The build/ copy remains as the artifact for releases.
echo "==> installing to /Applications"
pkill -f "MacSplorer.app/Contents/MacOS/MacSplorer" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/MacSplorer.app"
ditto "$APP" "/Applications/MacSplorer.app"

echo "==> done."
echo "    Installed:  /Applications/MacSplorer.app"
echo "    Build copy: $APP"
echo "    Launch:     open -a MacSplorer"
