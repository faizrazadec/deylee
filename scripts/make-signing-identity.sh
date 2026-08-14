#!/bin/bash
# Create the code-signing identity that scripts/make-app.sh signs Deylee with.
#
# Ad-hoc signing (`codesign -s -`) gives the app a designated requirement of
# `cdhash H"..."` — the hash of one exact binary. Every build is therefore a different
# program as far as macOS is concerned, which is why the Keychain asks for a password
# and Screen Recording asks for permission again after every single update: the new
# version genuinely is not the program that was granted them.
#
# Signing with a certificate pins the *certificate* instead:
#
#   identifier "me.faizraza.deylee" and certificate root = H"..."
#
# Every future build satisfies that, so the grants survive updates and the questions
# stop being asked.
#
# This certificate is self-signed, which fixes the prompts and nothing else. It does
# NOT make Gatekeeper trust the app on somebody else's Mac — that needs a Developer ID
# issued by Apple, because only Apple's root is preinstalled in macOS. A fresh install
# still needs Open Anyway either way, exactly as it does today.
#
# The key lives in its own keychain rather than the login one on purpose: a key
# imported into the login keychain makes codesign ask for the login password on every
# build, which would trade one prompt for another.
#
# Idempotent — running it twice keeps the existing identity rather than minting a
# second one, because a new certificate is a new identity and would cost every
# installed copy one more prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

KEYCHAIN="${DEYLEE_SIGN_KEYCHAIN:-$HOME/Library/Keychains/deylee-signing.keychain-db}"
PASS_FILE="${DEYLEE_SIGN_PASSWORD_FILE:-$HOME/.deylee-signing-password}"
IDENTITY="${DEYLEE_SIGN_IDENTITY:-Deylee Signing}"
BACKUP="$HOME/deylee-signing-backup"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "The identity already exists in $KEYCHAIN — keeping it."
  echo "Minting a new one would change the app's identity and cost every installed"
  echo "copy one more Keychain prompt. Delete the keychain first if that is intended."
  exit 0
fi

# The keychain's own password. Written to a file rather than typed, because make-app.sh
# has to unlock the keychain unattended on every build.
if [[ ! -f "$PASS_FILE" ]]; then
  umask 077
  openssl rand -base64 24 > "$PASS_FILE"
  chmod 600 "$PASS_FILE"
fi
PASSWORD=$(cat "$PASS_FILE")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# codeSigning extended key usage is not optional; codesign refuses a certificate
# without it. Ten years, because the identity expiring is the identity changing.
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=$IDENTITY/O=Deylee" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/identity.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -passout "pass:$PASSWORD" 2>/dev/null

if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
fi
# No timeout and no lock on sleep: a locked keychain mid-build is a prompt.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"

# -T /usr/bin/codesign is what lets codesign use the key without asking. Without it
# every build raises the same dialog this script exists to remove.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" \
  -T /usr/bin/codesign >/dev/null

# And this is what actually stops the dialog. -T puts codesign on the key's access
# list; the partition list is a second, newer gate that -T does not touch, and a key
# imported from the command line lands with one that excludes codesign entirely. The
# symptom is a prompt reading "codesign wants to access key" and asking for this
# keychain's password — which nobody knows, because it was generated above rather than
# chosen. Setting it here is possible without any dialog only because we hold the
# password already.
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" \
  >/dev/null 2>&1

# Losing this key means every installed copy is asked once more when a new one signs a
# release, so it is backed up beside the release itself. The passphrase is the
# keychain's, kept in a sibling file rather than printed anywhere.
umask 077
mkdir -p "$BACKUP"
cp "$WORK/identity.p12" "$BACKUP/deylee-signing.p12"
cp "$PASS_FILE" "$BACKUP/passphrase.txt"
chmod 600 "$BACKUP"/*
chmod 700 "$BACKUP"

echo "Created the identity \"$IDENTITY\" in:"
echo "  $KEYCHAIN"
echo "Backed up to:"
echo "  $BACKUP/deylee-signing.p12   (passphrase in passphrase.txt beside it)"
echo
echo "Move that backup somewhere off this Mac. Without it, a new Mac cannot sign an"
echo "update that the installs already out there recognise as the same application."
