#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
xcrun swift build -c release
BIN="$(xcrun swift build -c release --show-bin-path)"
APP="$ROOT/dist/OhMyLimit.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/OhMyLimit" "$APP/Contents/MacOS/OhMyLimit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/ThirdPartyNotices.md" "$APP/Contents/Resources/ThirdPartyNotices.md"
ICONSET="$ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
xcrun swift "$ROOT/scripts/generate-icon.swift" "$ICONSET"
xcrun iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# A stable self-signed identity keeps Keychain/TCC grants across rebuilds;
# ad-hoc signing makes macOS re-prompt on every access.
if security find-certificate -c "Oh My Limit Dev" >/dev/null 2>&1; then
    IDENTITY="Oh My Limit Dev"
else
    IDENTITY="-"
fi
/usr/bin/codesign --force --sign "$IDENTITY" "$APP"
printf 'Built %s\n' "$APP"
