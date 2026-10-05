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
#   bash scripts/build.sh                 # release build: kills the running app,
#                                         # installs to /Applications, relaunches
#   bash scripts/build.sh debug           # debug build
#   NO_INSTALL=1 bash scripts/build.sh    # build + sign only: leaves /Applications,
#                                         # and any running MacSplorer, untouched
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

# The version lives in ONE place: `MacSplorer.version` in MacSplorerCore. Info.plist
# used to carry its own hard-coded copy, and the two drifted — the bundle said 0.9.0
# while the app was 0.11.0, so macOS, Finder's Get Info and update-from-onedrive.sh
# all reported a version that wasn't installed. Stamp the bundle from the constant.
VERSION="$(sed -nE 's/.*public static let version = "([^"]+)".*/\1/p' Sources/MacSplorerCore/MacSplorer.swift)"
if [ -z "$VERSION" ]; then
    echo "ERROR: couldn't read MacSplorer.version from Sources/MacSplorerCore/MacSplorer.swift" >&2
    exit 1
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
echo "==> version $VERSION"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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

# Packaging for another machine doesn't need to replace the app running on this one.
if [ "${NO_INSTALL:-}" = "1" ]; then
    echo "==> NO_INSTALL=1: /Applications and any running MacSplorer left untouched."
    echo "    Build copy: $APP"
    exit 0
fi

# Install to /Applications so it's easy to find/launch and lives at a stable
# path for Full Disk Access (with the Developer ID identity, that grant persists
# across rebuilds). The build/ copy remains as the artifact for releases.
echo "==> installing to /Applications"
pkill -f "MacSplorer.app/Contents/MacOS/MacSplorer" 2>/dev/null || true
sleep 0.5
rm -rf "/Applications/MacSplorer.app"
ditto "$APP" "/Applications/MacSplorer.app"

# Kill, reinstall, relaunch: a build ends with the new version running, so the
# app isn't left closed after an install.
echo "==> relaunching"
open "/Applications/MacSplorer.app"

echo "==> done."
echo "    Installed + relaunched: /Applications/MacSplorer.app"
echo "    Build copy:             $APP"
