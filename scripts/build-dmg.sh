#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"
APP="$ROOT/dist/OhMyLimit.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(/usr/bin/lipo -archs "$APP/Contents/MacOS/OhMyLimit")"
DMG="$ROOT/dist/OhMyLimit-$VERSION-macOS-$ARCH.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/OhMyLimit.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/OhMyLimit.app"
ln -s /Applications "$STAGE/Applications"
/usr/bin/hdiutil create -volname 'Oh My Limit' -srcfolder "$STAGE" -format UDZO -ov "$DMG"
printf 'Built %s\n' "$DMG"
