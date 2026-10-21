#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""One-line summary of a UFR II LT job file: jobs, pages, paper, resolution, copies, special mode."""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cpca import packets
from ufrpdl import pdl_stream, tokens
b = open(sys.argv[1], "rb").read()
jobs = copies = imp = res = spm = None
jobs = 0
for off, ver, kind, op, one, ln, ff, pad, pl in packets(b):
    if op == 0x6b: jobs += 1
    if op == 0x15 and pl[:2] == b"\x07\xd7": copies = struct.unpack(">H", pl[2:4])[0]
    if op == 0x12 and pl[:2] == b"\x01\x13": imp = struct.unpack(">I", pl[2:6])[0]
    if op == 0x18 and pl[:2] == b"\x00\x3a": res = struct.unpack(">HH", pl[3:7])
    if op == 0x18 and pl[:2] == b"\x09\x71": spm = pl[2]
s = pdl_stream(b)
pages = papers = 0; paper = set(); mult = set(); dims = set()
last = None
for t in tokens(s):
    if t[0] == "op":
        last = t[2]; pages += t[2] == 0x03
    elif t[0] == "attr":
        if last == 0x02 and t[2] == 0xc3: paper.add(t[3])
        if last == 0x61 and t[2] == 0xe6: mult.add(t[3])
        if last == 0x03 and t[2] == 0xe7: dims.add(t[3])
print(f"jobs={jobs} pages={pages} paper-codes={sorted(paper)} dims={sorted(dims)} xmult={sorted(mult)} res={res} binder-copies={copies} impressions/job={imp} special-mode={spm}")
