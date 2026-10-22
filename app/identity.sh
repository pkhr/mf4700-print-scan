#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# The code-signing identity for build.sh and make-dmg.sh: $SIGN_IDENTITY if set
# (empty = ad hoc), else the keychain's first "Developer ID Application" identity,
# else nothing (ad hoc: the app then runs only on the Mac that built it).
if [ "${SIGN_IDENTITY+set}" = set ]; then
  echo "$SIGN_IDENTITY"
else
  security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -n 1
fi
