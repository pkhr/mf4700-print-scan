#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build "Canon MF4780w Print & Scan.app" (universal, ad-hoc signed) into build/.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME="Canon MF4780w Print & Scan"
APP="$ROOT/build/$NAME.app"
TMP="$ROOT/build/obj"

make -C "$ROOT" rastertoufr2lt mfnpscan >/dev/null
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14" \
    -o "$TMP/app-$arch" "$ROOT"/app/*.swift
done
lipo -create "$TMP/app-arm64" "$TMP/app-x86_64" -output "$APP/Contents/MacOS/$NAME"
cp "$ROOT/rastertoufr2lt" "$ROOT/mfnpscan" "$APP/Contents/MacOS/"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/app/Resources/AppIcon.icns" "$ROOT/app/Resources/printer.png" "$ROOT/app/Resources/printer-large.png" \
   "$ROOT/app/Resources/mf4700.conf" "$ROOT/app/Resources/Credits.rtf" "$ROOT/LICENSE" "$APP/Contents/Resources/"
rm -rf "$TMP"

codesign --force --sign - "$APP/Contents/MacOS/rastertoufr2lt" "$APP/Contents/MacOS/mfnpscan"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "$APP"
