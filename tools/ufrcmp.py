#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Compare two UFR II LT jobs packet by packet, ignoring what legitimately varies:
the job timestamp (attr 0x0009), the total-size attribute (0x07d6) and empty data
packets (Canon's writer emits them on internal flushes).
Usage: ufrcmp.py reference.ufr candidate.ufr"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cpca import packets

def norm(path):
    out = []
    for off, ver, kind, op, one, ln, ff, pad, pl in packets(open(path, "rb").read()):
        if kind == 2 and pl == b"\x01":
            continue
        if op == 0x6b:
            i = pl.find(b"\x00\x09\x00\x08")
            if i >= 0: pl = pl[:i + 4] + b"<TS>" + pl[i + 12:]
        if op == 0x12 and pl[:2] == b"\x07\xd6":
            pl = pl[:2] + b"<SIZE>"
        out.append((kind, op, pl))
    return out

a, b = norm(sys.argv[1]), norm(sys.argv[2])
if a == b:
    print(f"IDENTICAL ({len(a)} packets)")
    sys.exit(0)
for k, (x, y) in enumerate(zip(a, b)):
    if x != y:
        print(f"packet {k}: ref kind={x[0]} op={x[1]:#x} len={len(x[2])} | cand kind={y[0]} op={y[1]:#x} len={len(y[2])}")
        print("  ref :", x[2][:64].hex(" "))
        print("  cand:", y[2][:64].hex(" "))
        break
else:
    print(f"length differs: ref {len(a)} packets, cand {len(b)} packets")
sys.exit(1)
