#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Decode a UFR II LT job into PBM pages (needs jbigkit's jbgtopbm).
Usage: ufrdecode.py job.ufr out-prefix   -> out-prefix-1.pbm ...; prints page info."""
import sys, os, struct, subprocess, shutil, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ufrpdl import pdl_stream, tokens

JBGTOPBM = shutil.which("jbgtopbm") or "/opt/homebrew/opt/jbigkit/bin/jbgtopbm"

def decode(path, prefix):
    s = pdl_stream(open(path, "rb").read())
    pages, cur, paper, mult, last_op = [], None, None, 1, None
    for tok in tokens(s):
        if tok[0] == "op":
            last_op = tok[2]
            if last_op == 0x03:
                cur = {"bands": [], "paper": paper}; pages.append(cur)
        elif tok[0] == "attr":
            tag, val = tok[2], tok[3]
            if last_op == 0x02 and tag == 0xc3: paper = val
            if last_op == 0x03 and tag == 0xe7: cur["size"] = val
            if last_op == 0x61 and tag == 0xe6: cur["mult"] = val
        elif tok[0] == "data":
            cur["bands"].append(tok[2])
    out = []
    for n, pg in enumerate(pages, 1):
        bih = pg["bands"][0][:20]
        bie = bih + pg["bands"][0][20:] + b"".join(pg["bands"][1:])
        with tempfile.NamedTemporaryFile(suffix=".jbg", delete=False) as f:
            f.write(bie)
        pbm = f"{prefix}-{n}.pbm"
        subprocess.run([JBGTOPBM, f.name, pbm], check=True)
        os.unlink(f.name)
        xd, yd = struct.unpack(">II", bih[4:12])
        out.append((pbm, pg["paper"], pg.get("mult", 1), xd, yd))
        print(f"page {n}: paper-code={pg['paper']} mult={pg.get('mult', 1)} size={pg.get('size')} bitmap={xd}x{yd} -> {pbm}")
    return out

if __name__ == "__main__":
    decode(sys.argv[1], sys.argv[2])
