#!/bin/sh
# Builds a debug Berth signed with the release certificate, then relaunches it.
#
# A plain Xcode build is signed ad-hoc, so macOS sees every rebuild as a new app and asks again for
# network volume and Keychain access. With the release certificate those answers carry over, and are
# shared with the installed release.
#
# Needs ./signing/ from scripts/make-signing-cert.sh. The key goes into a temporary keychain, which is
# deleted on exit; the login keychain isn't touched.
set -eu
cd "$(dirname "$0")/.."

for f in signing/berth-signing.p12 signing/password.txt signing/cert.pem; do
    [ -e "$f" ] || { echo "Missing $f: run scripts/make-signing-cert.sh first." >&2; exit 1; }
done

xcodebuild -project Berth.xcodeproj -scheme Berth -configuration Debug -derivedDataPath build build \
    | grep -E 'error:|BUILD ' | sort -u
APP="build/Build/Products/Debug/Berth.app"
[ -d "$APP" ] || { echo "Build produced no app." >&2; exit 1; }

WORK="$(mktemp -d)"
KC="$WORK/signing.keychain-db"
cleanup() {
    security delete-keychain "$KC" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

KC_PASS="$(uuidgen)"
security create-keychain -p "$KC_PASS" "$KC"
security unlock-keychain -p "$KC_PASS" "$KC"
security import signing/berth-signing.p12 -k "$KC" -P "$(cat signing/password.txt)" -T /usr/bin/codesign > /dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" > /dev/null

# By hash: a self-signed certificate never counts as a "valid" identity to look up by name.
HASH="$(/usr/bin/openssl x509 -in signing/cert.pem -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"

# Inside out, keeping each piece's identifier and the entitlements from the build.
sign() { codesign --force --sign "$HASH" --keychain "$KC" --timestamp=none --preserve-metadata=identifier,entitlements,flags "$1"; }
for nested in "$APP"/Contents/MacOS/*.dylib "$APP"/Contents/Helpers/berth; do
    [ -e "$nested" ] && sign "$nested"
done
sign "$APP"
codesign --verify --strict --deep "$APP"
codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf" || { echo "Signing did not take." >&2; exit 1; }

# Only a Berth running from this build; never the installed one, which would need quitting by hand.
if pgrep -f "$PWD/$APP/Contents/MacOS/Berth" > /dev/null; then
    osascript -e 'tell application id "app.berth.Berth" to quit'
    i=0
    while pgrep -f "$PWD/$APP/Contents/MacOS/Berth" > /dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
fi
if pgrep -f 'Berth.app/Contents/MacOS/Berth' > /dev/null; then
    echo "Another Berth is still running. Quit it, then run: open $APP" >&2
    exit 1
fi
open "$APP"
