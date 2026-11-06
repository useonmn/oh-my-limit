#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTPUT="${1:-"$ROOT/dist/previews"}"
mkdir -p "$OUTPUT"
xcrun swift build
BIN="$(xcrun swift build --show-bin-path)"
for ENTRY in normal:2 empty:1 error:2 loading:2 long:2 models:1 settings:1 settings-connected:1 settings-claude:1 claude-oauth:1 antigravity:1 antigravity-cli:1 antigravity-unknown:1 antigravity-error:1 antigravity-loading:1 antigravity-stale:1 mixed:3 antigravity-oauth:1 antigravity-oauth-login:1 antigravity-oauth-denied:1 antigravity-oauth-multiple:2 ring-boundaries:5 many-windows:1 codex-reserve:1 keychain-antigravity:1 keychain-codex:1 keychain-cached:1; do
    SCENARIO="${ENTRY%:*}"
    COUNT="${ENTRY##*:}"
    for ((INDEX=0; INDEX<COUNT; INDEX++)); do
        STEM="$SCENARIO"
        if ((INDEX > 0)); then STEM="$SCENARIO-selected-$INDEX"; fi
        for APPEARANCE in light dark; do
            "$BIN/OhMyLimit" --preview "$SCENARIO" --selected-account "$INDEX" --appearance "$APPEARANCE" \
                --capture "$OUTPUT/$STEM-$APPEARANCE.png"
        done
    done
done
for SCENARIO in many-windows; do
    for APPEARANCE in light dark; do
        "$BIN/OhMyLimit" --preview "$SCENARIO" --appearance "$APPEARANCE" \
            --capture-scroll-bottom --capture "$OUTPUT/$SCENARIO-bottom-$APPEARANCE.png"
    done
done
