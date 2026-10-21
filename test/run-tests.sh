#!/bin/zsh
# SPDX-License-Identifier: GPL-2.0-or-later
# Byte-exact regression test: decode each Canon-driver reference job to bitmaps,
# re-encode with rastertoufr2lt using the same job metadata, compare packets.
set -u
cd "${0:A:h}/.."
TMP=$(mktemp -d); trap 'rm -rf $TMP' EXIT
pass=0; fail=0
check() {   # name paper extra-args...
  local name=$1 paper=$2; shift 2
  python3 -I tools/ufrdecode.py test/ref/$name.ufr $TMP/$name > /dev/null || { echo "FAIL $name (decode)"; ((fail++)); return; }
  ./rastertoufr2lt --pbm --paper $paper --title test --user "A. User" --host Example-MacBook-Pro "$@" \
      -o $TMP/$name.ufr $TMP/$name-*.pbm 2>/dev/null
  if out=$(python3 -I tools/ufrcmp.py test/ref/$name.ufr $TMP/$name.ufr); then
    echo "PASS $name: $out"; ((pass++))
  else
    echo "FAIL $name"; echo "$out" | sed 's/^/     /'; ((fail++))
  fi
}
check blank A4
check square A4
check full A4
check two A4
check rich A4
check noise A4
check ps_Letter Letter
check ps_Legal Legal
check ps_A5 A5
check ps_B5 B5
check ps_Executive Executive
check ps_Env10 Env10
check ps_EnvDL EnvDL
check ps_3x5 3x5
check res1200 A4 --hres 2
check copies3nc A4 --copies 3 --no-collate
echo "---- $pass passed, $fail failed"
[ $fail -eq 0 ]
