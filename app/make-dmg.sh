#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Package the app as an installer disk image: build/Canon MF4780w Print & Scan <version>.dmg
# — a Finder window with the app, an arrow and the Applications folder on a designed
# background, the volume wearing the app icon. Needs dmgbuild (installed into
# build/.venv on first use).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME="Canon MF4780w Print & Scan"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$ROOT/app/Info.plist")
ART="$ROOT/build/dmg-art"
DMG="$ROOT/build/$NAME $VERSION.dmg"
VENV="$ROOT/build/.venv"

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q dmgbuild
fi

# With a Developer ID, the app and then the disk image are notarized by Apple and
# the tickets stapled, so Gatekeeper accepts them on first launch, even offline.
# The credentials live in the keychain profile $NOTARY_PROFILE, made once with
#   xcrun notarytool store-credentials mf4700-print-scan --apple-id … --team-id …
# NOTARIZE=0 skips it.
IDENTITY=$("$ROOT/app/identity.sh")
NOTARY_PROFILE=${NOTARY_PROFILE:-mf4700-print-scan}
notarize() {
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || true
  status=$(printf '%s' "$out" | plutil -extract status raw - 2>/dev/null) || status="failed"
  if [ "$status" != "Accepted" ]; then
    echo "notarization of $(basename "$1"): $status" >&2
    printf '%s\n' "$out" >&2
    id=$(printf '%s' "$out" | plutil -extract id raw - 2>/dev/null) && \
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

"$ROOT/app/build.sh" >/dev/null
APP="$ROOT/build/$NAME.app"
if [ -n "$IDENTITY" ] && [ "${NOTARIZE:-1}" != 0 ]; then
  ditto -c -k --keepParent "$APP" "$ROOT/build/notarize.zip"
  notarize "$ROOT/build/notarize.zip"
  rm -f "$ROOT/build/notarize.zip"
  xcrun stapler staple -q "$APP"
fi
mkdir -p "$ART"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" \
  -o "$ROOT/build/snapshot" "$ROOT/app/Panel.swift" "$ROOT/app/Snapshot/Snapshot.swift"
PANEL_ART="$ROOT/app/Resources/printer-large.png" "$ROOT/build/snapshot" --dmg-background "$ART" >/dev/null

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/app/dmg-settings.py" \
  -D app="$APP" -D background="$ART/background.png" -D icon="$ROOT/app/Resources/AppIcon.icns" \
  "$NAME" "$DMG" >/dev/null
if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if [ "${NOTARIZE:-1}" != 0 ]; then
    notarize "$DMG"
    xcrun stapler staple -q "$DMG"
    spctl --assess --type open --context context:primary-signature "$DMG"   # Gatekeeper's verdict
  fi
else
  codesign --force --sign - "$DMG"
fi
echo "$DMG"
