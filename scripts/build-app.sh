#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcrun swift build -c release
BIN="$(xcrun swift build -c release --show-bin-path)"
APP="$ROOT/dist/OhMyLimit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OhMyLimit" "$APP/Contents/MacOS/OhMyLimit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ThirdPartyNotices.md" "$APP/Contents/Resources/ThirdPartyNotices.md"
ICONSET="$ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
xcrun swift "$ROOT/scripts/generate-icon.swift" "$ICONSET"
xcrun iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# Signs with the "Oh My Limit Dev" identity when present, else ad-hoc. Without an Apple
# Team ID the login keychain binds each item to the build's cdhash, so either way a new
# build asks once per item; only Developer ID signing (teamid partition) avoids that.
# Without -v so an untrusted self-signed identity still counts; find-identity
# only lists certificates whose private key is present. Sign by SHA-1 hash so
# duplicate certificates with the same name do not make codesign ambiguous.
IDENTITY="$(security find-identity -p codesigning 2>/dev/null \
    | awk -v name='"Oh My Limit Dev"' 'index($0, name) && $2 ~ /^[0-9A-F]{40}$/ { print $2; exit }' \
    || true)"
IDENTITY="${IDENTITY:--}"
/usr/bin/codesign --force --sign "$IDENTITY" "$APP"
printf 'Built %s\n' "$APP"
