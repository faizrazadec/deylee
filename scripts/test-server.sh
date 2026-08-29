#!/bin/bash
# The sync API's suite. Same Command Line Tools workaround as the app's
# apps/macos/scripts/test.sh — Testing.framework ships with the CLT but is not on
# SwiftPM's search paths. Run from server/, which is its own package so that the app
# keeps building without a resolution step.
set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test \
  -Xswiftc -F"$FW" \
  -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" \
  "$@"
