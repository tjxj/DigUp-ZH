#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  swift test "$@"
else
  # CLT 6.2 ships Testing as a framework but omits its optional Foundation overlay.
  FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
  swift test --disable-xctest -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
fi
