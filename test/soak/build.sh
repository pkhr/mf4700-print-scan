#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build the soak-test app (app/*.swift with -D SOAK) into build/soak/: its own name,
# bundle id, port and folders, so it runs beside the real app.
#   test/soak/build.sh [--tsan]     --tsan: with Thread Sanitizer, into build/soak-tsan/
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NAME="MF4700 Soak Test"
OUT="$ROOT/build/soak"
SAN=""
if [ "${1:-}" = "--tsan" ]; then SAN="-sanitize=thread"; OUT="$ROOT/build/soak-tsan"; fi
APP="$OUT/$NAME.app"

make -C "$ROOT" rastertoufr2lt mfnpscan >/dev/null
[ -x "$ROOT/tools/mkraster" ] || clang -O2 -o "$ROOT/tools/mkraster" "$ROOT/tools/mkraster.c" -lcups
mkdir -p "$OUT"
clang -O2 -Wall -o "$OUT/procstat" "$ROOT/test/soak/procstat.c"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -g -swift-version 5 -parse-as-library -D SOAK $SAN -target "$(uname -m)-apple-macos14" \
  -o "$APP/Contents/MacOS/$NAME" "$ROOT"/app/*.swift
cp "$ROOT/rastertoufr2lt" "$ROOT/mfnpscan" "$APP/Contents/MacOS/"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
for kv in "CFBundleIdentifier local.mf4700-airprint.soak" "CFBundleExecutable $NAME" "CFBundleName $NAME" "CFBundleDisplayName $NAME"; do
  plutil -replace "${kv%% *}" -string "${kv#* }" "$APP/Contents/Info.plist"
done
cp "$ROOT/app/Resources/AppIcon.icns" "$ROOT/app/Resources/printer.png" "$ROOT/app/Resources/printer-large.png" \
   "$ROOT/app/Resources/mf4700.conf" "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/MacOS/rastertoufr2lt" "$APP/Contents/MacOS/mfnpscan"
codesign --force --sign - "$APP"
echo "$APP"
