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

# Which API this bundle talks to, decided here rather than by whatever the plist was
# last edited to say. One committed file served both purposes, so the value depended on
# who touched it most recently: for a while every release pointed at loopback and would
# have shipped an app that silently never synced, and after that was corrected every
# development build pointed at production instead — which is how test accounts end up in
# a real database.
#
# Override for anything unusual; the default follows the configuration.
if [[ -z "${DEYLEE_API_BASE_URL:-}" ]]; then
  if [[ "$CONFIG" == "debug" ]]; then
    DEYLEE_API_BASE_URL="http://127.0.0.1:8081"   # the dev container
  else
    DEYLEE_API_BASE_URL="https://api.faizraza.me"
  fi
fi
/usr/libexec/PlistBuddy -c "Set :DeyleeAPIBaseURL $DEYLEE_API_BASE_URL" \
  "$APP/Contents/Info.plist"

# The plaintext-HTTP exemption is a development affordance and has no business in a
# bundle that leaves this machine. It covers more than loopback — `.local` and any
# unqualified name on the local link — so leaving it in a release would quietly widen
# what the app is willing to talk to in clear text.
if [[ "$CONFIG" != "debug" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" \
    "$APP/Contents/Info.plist" 2>/dev/null || true
fi

echo "API base URL: $DEYLEE_API_BASE_URL ($CONFIG)"

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

# Sparkle, which is how a release updates itself.
#
# Copied in rather than linked from the build directory: the binary looks for it at
# `@rpath/Sparkle.framework`, and outside the bundle that path does not exist on
# anybody else's machine. The framework carries its own helpers — an XPC service, the
# Updater and Autoupdate apps — so the whole thing travels, not just the dylib.
mkdir -p "$APP/Contents/Frameworks"
cp -R Vendor/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/"

# Teach the binary where that is. SwiftPM builds a bare executable and adds no rpath
# for a bundle layout it knows nothing about, so dyld looks beside the binary in
# Contents/MacOS, does not find the framework, and the app dies at launch with
# "Library not loaded: @rpath/Sparkle.framework". Before signing, because editing a
# Mach-O invalidates any signature already over it.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Deylee" 2>/dev/null || true

# The update feed is a property of the build, exactly like the API address above. A
# release asks Deylee's own appcast; a development build is given no feed at all, so it
# reports having none instead of checking production from somebody's laptop.
if [[ "$CONFIG" == "debug" ]]; then
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
else
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $DEYLEE_API_BASE_URL/updates/appcast.xml" \
    "$APP/Contents/Info.plist"
fi

# Ad-hoc signature so local Gatekeeper/TCC treat the bundle as a stable identity.
#
# Inside out, and that order is not optional: signing the app seals a hash of every
# nested bundle, so a framework signed afterwards invalidates the signature that was
# taken over it. Sparkle's own helpers are nested bundles in their own right and have
# to be sealed before the framework that contains them.
sign() { codesign --force --sign - "$1"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
sign "$SPARKLE/Versions/B/Autoupdate" 2>/dev/null || true
sign "$SPARKLE/Versions/B/Updater.app" 2>/dev/null || true
sign "$SPARKLE"
sign "$APP"

echo "Built $APP"
