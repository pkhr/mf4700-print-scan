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

"$ROOT/app/build.sh" >/dev/null
mkdir -p "$ART"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" \
  -o "$ROOT/build/snapshot" "$ROOT/app/Panel.swift" "$ROOT/app/Snapshot/Snapshot.swift"
PANEL_ART="$ROOT/app/Resources/printer-large.png" "$ROOT/build/snapshot" --dmg-background "$ART" >/dev/null

rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/app/dmg-settings.py" \
  -D app="$ROOT/build/$NAME.app" -D background="$ART/background.png" -D icon="$ROOT/app/Resources/AppIcon.icns" \
  "$NAME" "$DMG" >/dev/null
codesign --force --sign - "$DMG"
echo "$DMG"
