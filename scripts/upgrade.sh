#!/usr/bin/env bash
#
# upgrade.sh — upgrade an installed MacSplorer.app in place.
#
# Quits the running app, verifies the new build is properly signed + notarized
# (so a tampered or mystery zip can't be installed), swaps it into /Applications,
# and relaunches. Your preferences (stored in macOS user defaults) are untouched.
#
# Usage:
#   1. From the project's Releases page, download this script and the latest
#      MacSplorer-X.Y.Z.zip into the same folder (e.g. ~/Downloads); no need to
#      unzip the .zip.
#   2. Run one of:
#        bash upgrade.sh                                   # newest zip in ~/Downloads
#        bash upgrade.sh ~/Downloads/MacSplorer-X.Y.Z.zip  # explicit path
#
set -euo pipefail

APP="/Applications/MacSplorer.app"
EXPECTED_TEAM="Q5A8FF5XXR"      # Developer ID: Mark Ryland

# ---- locate the release zip -------------------------------------------------
if [[ $# -ge 1 ]]; then
    ZIP="$1"
else
    ZIP="$(ls -t "$HOME"/Downloads/MacSplorer-*.zip 2>/dev/null | head -1 || true)"
fi
if [[ -z "${ZIP:-}" || ! -f "$ZIP" ]]; then
    echo "ERROR: couldn't find a MacSplorer-*.zip." >&2
    echo "Download the latest release, then drop it in ~/Downloads or pass its path:" >&2
    echo "  bash upgrade.sh /path/to/MacSplorer-X.Y.Z.zip" >&2
    exit 1
fi
echo "==> Upgrading from: $(basename "$ZIP")"

# ---- unzip to a temp dir ----------------------------------------------------
TMP="$(mktemp -d /tmp/macsplorer-upgrade.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
NEW_APP="$TMP/MacSplorer.app"
if [[ ! -d "$NEW_APP" ]]; then
    echo "ERROR: MacSplorer.app not found inside the zip." >&2
    exit 1
fi
NEW_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$NEW_APP/Contents/Info.plist" 2>/dev/null || echo '?')"

# ---- verify the new build BEFORE installing it ------------------------------
# Releases are Developer-ID signed and notarized; refuse anything that isn't.
echo "==> Verifying code signature (v$NEW_VER)"
if ! codesign --verify --deep --strict "$NEW_APP"; then
    echo "ERROR: code-signature verification failed — refusing to install." >&2
    exit 1
fi
TEAM="$(codesign -dv "$NEW_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ "$TEAM" != "$EXPECTED_TEAM" ]]; then
    echo "ERROR: unexpected signing team '$TEAM' (expected '$EXPECTED_TEAM')." >&2
    exit 1
fi
if ! spctl --assess --type exec "$NEW_APP" 2>/dev/null; then
    echo "ERROR: Gatekeeper rejected the app (not notarized?) — refusing to install." >&2
    exit 1
fi

# ---- quit the running app ---------------------------------------------------
echo "==> Quitting MacSplorer if it's running"
osascript -e 'quit app "MacSplorer"' 2>/dev/null || true
pkill -f "MacSplorer.app/Contents/MacOS/MacSplorer" 2>/dev/null || true
sleep 1

# ---- swap the app -----------------------------------------------------------
echo "==> Installing into /Applications"
rm -rf "$APP"
ditto "$NEW_APP" "$APP"
# Already validated signature + notarization above; clear any download quarantine.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# ---- relaunch ---------------------------------------------------------------
echo "==> Relaunching"
open "$APP"
echo
echo "==> Done. Upgraded to v$NEW_VER. Your preferences were preserved."
