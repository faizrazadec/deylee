#!/bin/bash
# Sign a release archive and write the appcast the Mac app reads.
#
#   ./scripts/publish-update.sh dist/Deylee-0.2.2.zip
#
# Produces, in dist/updates/:
#   Deylee-<version>.zip   the archive, copied
#   appcast.xml            the feed, rewritten with this version at the top
#
# Copy that directory to wherever the API serves DEYLEE_UPDATES_DIR from, and every
# installed copy of Deylee sees the new version on its next check.
#
# The EdDSA private key lives in the login Keychain of whoever ran `generate_keys`,
# and signing happens here rather than on a server for exactly that reason: the key
# never leaves this Mac, so nothing that is deployed can forge an update. Lose that
# Keychain item and no future release can be signed for the installs already out
# there — back it up with `bin/generate_keys -x <file>` and keep it somewhere safe.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIP="${1:-}"
if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  echo "usage: $0 <path-to-release-zip>" >&2
  exit 1
fi

# Vendored alongside the framework, so publishing works from a clean checkout with no
# network and no remembering where a tarball was unpacked. SPARKLE_BIN still overrides,
# for testing a newer Sparkle before vendoring it.
SIGN_UPDATE="${SPARKLE_BIN:-Vendor/sparkle-bin}/sign_update"
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "sign_update not found at $SIGN_UPDATE" >&2
  echo "It ships in the Sparkle release tarball, alongside generate_keys." >&2
  exit 1
fi

# The version the app compares against is CFBundleShortVersionString, and the one it
# *sorts* by is CFBundleVersion. Both are read from the built bundle rather than passed
# in, because a release whose appcast disagrees with its own Info.plist either offers an
# update that installs and changes nothing, or never offers one at all.
APP="dist/Deylee.app"
if [[ ! -d "$APP" ]]; then
  echo "dist/Deylee.app is missing — run ./scripts/make-app.sh release first." >&2
  exit 1
fi
SHORT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
MIN_SYSTEM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")

# Guard against publishing an appcast for a bundle that is not the one in the zip. They
# diverge the moment somebody rebuilds without re-zipping, and the symptom is an update
# that downloads and then declines to install itself.
ZIP_VERSION=$(basename "$ZIP" .zip | sed 's/^Deylee-//')
if [[ "$ZIP_VERSION" != "$SHORT_VERSION" ]]; then
  echo "The archive says $ZIP_VERSION and the bundle says $SHORT_VERSION." >&2
  echo "Rebuild or rename so they agree before publishing." >&2
  exit 1
fi

OUT="dist/updates"
mkdir -p "$OUT"

# Served under a name carrying the build number, so every publish is a URL that has
# never been requested before.
#
# Cloudflare sits in front of this and caches 404s for four hours. Fetch the public URL
# in the seconds between writing the appcast and copying the archive — which a release
# script naturally does, while checking its own work — and that 404 is served to every
# client for the rest of the afternoon. A fresh path cannot have a stale answer.
SERVED="Deylee-$SHORT_VERSION-$BUILD_VERSION.zip"
cp "$ZIP" "$OUT/$SERVED"

# Emits BOTH attributes ready to paste: sparkle:edSignature="…" length="…". Adding a
# length of our own alongside it produces a duplicate attribute, which is not a warning
# — it is malformed XML, and Sparkle rejects the whole feed rather than one item.
SIGNATURE_LINE=$("$SIGN_UPDATE" "$ZIP")
PUBLISHED=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
FEED_BASE="${DEYLEE_UPDATES_URL:-https://api.faizraza.me/updates}"

# Written whole each time rather than appended to. An appcast may carry several items
# and Sparkle picks the newest it can run; keeping only the current one is deliberate
# while releases are pre-1.0 and superseded builds are not worth offering anybody.
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Deylee</title>
    <link>$FEED_BASE/appcast.xml</link>
    <description>Updates for Deylee, a menu-bar time tracker for macOS.</description>
    <language>en</language>
    <item>
      <title>$SHORT_VERSION</title>
      <pubDate>$PUBLISHED</pubDate>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/faizrazadec/deylee-ios/releases/tag/v$SHORT_VERSION</sparkle:releaseNotesLink>
      <enclosure url="$FEED_BASE/$SERVED"
                 type="application/octet-stream"
                 $SIGNATURE_LINE />
    </item>
  </channel>
</rss>
XML

echo "Wrote $OUT/appcast.xml for $SHORT_VERSION (build $BUILD_VERSION)"
echo "Staged $OUT/$SERVED"
echo
echo "Copy both to the API's DEYLEE_UPDATES_DIR, then check LOCALLY first:"
echo "  curl -sI http://127.0.0.1:8080/updates/$SERVED | head -1"
echo
echo "Only fetch $FEED_BASE once the file is in place — a 404 through Cloudflare is"
echo "cached for four hours and would be served to every client."
