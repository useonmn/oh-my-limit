#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SWIFTC="$(xcrun --find swiftc)"
PLUGIN="$(dirname "$SWIFTC")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$PLUGIN" ]]; then
    xcrun swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
else
    xcrun swift test "$@"
fi
