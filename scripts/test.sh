#!/usr/bin/env bash
# Runs the test suite. With Xcode installed this is plain `swift test`; with only the
# Command Line Tools, swift-testing lives in a framework folder that has to be passed in.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ "$(xcode-select -p 2>/dev/null)" == /Library/Developer/CommandLineTools* && -d "$CLT/Testing.framework" ]]; then
  # The CLT ship _Testing_Foundation without its module: skip that cross-import overlay.
  exec swift test -Xswiftc -F"$CLT" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F"$CLT" -Xlinker -rpath -Xlinker "$CLT" "$@"
fi
exec swift test "$@"
