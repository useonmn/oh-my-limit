#!/bin/bash
# Installs the latest Oh My Limit release into /Applications:
#   curl -fsSL https://raw.githubusercontent.com/useonmn/oh-my-limit/main/scripts/install.sh | bash
# OHMYLIMIT_ZIP_URL overrides the download (any curl URL, including file://).
set -euo pipefail

URL="${OHMYLIMIT_ZIP_URL:-https://github.com/useonmn/oh-my-limit/releases/latest/download/OhMyLimit-macOS-arm64.zip}"
DEST="${OHMYLIMIT_APP:-/Applications/OhMyLimit.app}"
BUNDLE_ID="local.ohmylimit.app"

fail() { printf 'Oh My Limit 설치 실패: %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS에서만 설치할 수 있습니다."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon(arm64) Mac 전용 빌드입니다."
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MAJOR >= 14 )) || fail "macOS 14 이상이 필요합니다."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/OhMyLimit-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

printf '내려받는 중: %s\n' "$URL"
curl -fL --proto '=https,file' --retry 2 -o "$WORK/app.zip" "$URL" || fail "내려받지 못했습니다."
/usr/bin/ditto -x -k "$WORK/app.zip" "$WORK/unpacked" || fail "압축을 풀지 못했습니다."
APP="$WORK/unpacked/OhMyLimit.app"
[[ -d "$APP" ]] || fail "내려받은 파일에 OhMyLimit.app이 없습니다."
/usr/bin/codesign --verify --strict "$APP" 2>/dev/null || fail "앱 서명을 확인하지 못했습니다."

if pgrep -f "$DEST/Contents/MacOS/OhMyLimit" >/dev/null; then
    printf '실행 중인 Oh My Limit을 종료합니다.\n'
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -f "$DEST/Contents/MacOS/OhMyLimit" >/dev/null || break
        sleep 0.5
    done
fi

rm -rf "$DEST" || fail "$DEST 를 교체할 권한이 없습니다."
/usr/bin/ditto "$APP" "$DEST" || fail "$DEST 에 복사하지 못했습니다."
/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

printf '설치했습니다: %s\n' "$DEST"

# The release carries its own oml; older releases do not. Replace via rename so a running
# `oml update` keeps reading its old file.
if [[ -f "$DEST/Contents/Resources/oml" ]]; then
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
    /usr/bin/install -m 755 "$DEST/Contents/Resources/oml" "$BIN_DIR/.oml.new"
    mv -f "$BIN_DIR/.oml.new" "$BIN_DIR/oml"
    case ":$PATH:" in
        *":$BIN_DIR:"*) printf '업데이트와 제거는 oml update / oml uninstall 로 할 수 있습니다.\n' ;;
        *) printf 'oml 명령을 쓰려면 다음을 실행하세요: echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.zshrc\n' ;;
    esac
fi
open "$DEST"
