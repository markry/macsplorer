#!/usr/bin/env bash
#
# release.sh — notarize, staple, and publish an already-built MacSplorer release.
#
# Finishes a release whose code is tagged and whose GitHub release exists as a
# draft. Run it while logged in at the desk, so any keychain-access prompt for
# the notary credential can be approved interactively.
#
# Prereqs:
#   - build/MacSplorer.app already built + Developer ID signed:  bash scripts/build.sh
#   - a  v<version>  git tag and a *draft* GitHub release for it already exist
#   - the notary keychain profile (default: MeetingNotifierNotary) is available
#
# Usage:
#   bash scripts/release.sh <version>          # e.g. bash scripts/release.sh 0.1.1
#   PROFILE=MyNotaryProfile bash scripts/release.sh 0.1.1
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:?usage: release.sh <version>}"
PROFILE="${PROFILE:-MeetingNotifierNotary}"
APP="build/MacSplorer.app"
TAG="v$VERSION"
ZIP="dist/MacSplorer-$VERSION.zip"
SUBMIT_ZIP="dist/MacSplorer-$VERSION-notarize.zip"
# gh config dir: honor an explicit GH_CONFIG_DIR if set; otherwise use the
# personal-account isolation dir when it exists (the Istari shared Mac), else
# fall back to gh's default (~/.config/gh on a single-user Mac). Lets this script
# run unchanged on either machine.
if [ -z "${GH_CONFIG_DIR:-}" ] && [ -d "$HOME/.config/gh-personal" ]; then
    export GH_CONFIG_DIR="$HOME/.config/gh-personal"
fi
echo "==> gh config dir: ${GH_CONFIG_DIR:-$HOME/.config/gh (default)}"

[ -d "$APP" ] || { echo "ERROR: $APP not found — run scripts/build.sh first." >&2; exit 1; }
mkdir -p dist
[ -f "$SUBMIT_ZIP" ] || ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> notarizing $SUBMIT_ZIP (profile: $PROFILE)"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling the ticket onto $APP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP"

echo "==> zipping the stapled app -> $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> uploading asset and publishing release $TAG"
gh release upload "$TAG" "$ZIP" --clobber
gh release edit "$TAG" --draft=false
echo "==> published: $(gh release view "$TAG" --json url -q .url)"
