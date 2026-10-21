#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Render the panel states to PNG (default: build/snapshots).
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/build/snapshots}
mkdir -p "$OUT"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" \
  -o "$ROOT/build/snapshot" "$ROOT/app/Panel.swift" "$ROOT/app/Snapshot/Snapshot.swift"
PANEL_ART="$ROOT/app/Resources/printer-large.png" "$ROOT/build/snapshot" "$OUT"
