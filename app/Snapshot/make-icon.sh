#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Render the app icon (dark stage + printer) into app/Resources/AppIcon.icns.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SET="$ROOT/build/AppIcon.iconset"
mkdir -p "$ROOT/build"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" \
  -o "$ROOT/build/snapshot" "$ROOT/app/Panel.swift" "$ROOT/app/Snapshot/Snapshot.swift"
PANEL_ART="$ROOT/app/Resources/printer-large.png" "$ROOT/build/snapshot" --icon "$ROOT/build/icon-1024.png"
rm -rf "$SET"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ROOT/build/icon-1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$ROOT/build/icon-1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns -o "$ROOT/app/Resources/AppIcon.icns" "$SET"
echo "$ROOT/app/Resources/AppIcon.icns"
