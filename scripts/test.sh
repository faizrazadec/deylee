#!/bin/bash
# `swift test` with Command Line Tools (no Xcode): Testing.framework and its
# lib_TestingInterop.dylib ship with the CLT but are not on SwiftPM's default
# search paths, so they have to be passed explicitly.
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
