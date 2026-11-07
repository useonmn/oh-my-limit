#!/bin/bash
# Builds the app and publishes it as GitHub release v<CFBundleShortVersionString>.
# The zip name has no version so install.sh can use releases/latest/download.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/OhMyLimit.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/OhMyLimit")"
ZIP="$ROOT/dist/OhMyLimit-macOS-$ARCH.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
TAG="v$VERSION"
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --clobber
else
    gh release create "$TAG" "$ZIP" --title "Oh My Limit $VERSION" --generate-notes
fi
printf 'Published %s\n' "$TAG"
