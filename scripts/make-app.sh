#!/bin/bash
# Assemble Deylee.app from the SwiftPM build output. SwiftPM alone produces a bare
# binary; a menu-bar app needs a bundle so LSUIElement and the bundle id apply.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Deylee"
APP="dist/Deylee.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Deylee"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: build AppIcon.icns from the 1024px master.
ICON_SRC="Resources/AppIcon.png"
if [[ -f "$ICON_SRC" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc signature so local Gatekeeper/TCC treat the bundle as a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP"
