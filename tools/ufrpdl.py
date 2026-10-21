#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Tokenizer/extractor for Canon UFR II LT ("BDL") page streams inside CPCA framing."""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cpca import packets

def pdl_stream(b):
    out = bytearray()
    for off, ver, kind, op, one, ln, ff, pad, pl in packets(b):
        if kind == 2:
            assert pl[0] == 1, f"data packet without 01 lead byte at {off:#x}"
            out += pl[1:]
    return bytes(out)

def typed_len(t):
    esize = 1 << ((t >> 2) & 3)
    count = (t & 3) + 1
    return esize, count

def tokens(s):
    i = 0
    while i < len(s):
        b = s[i]
        if b in (0x9c, 0x9d, 0x9e):
            n = {0x9c: 1, 0x9d: 2, 0x9e: 4}[b]
            ln = int.from_bytes(s[i+1:i+1+n], "big")
            yield ("data", i, s[i+1+n:i+1+n+ln])
            i += 1 + n + ln
        elif b >= 0xc0:
            t = s[i+1]
            if t < 0x80:
                yield ("attr", i, b, t, None)
                i += 2
            else:
                esize, count = typed_len(t)
                raw = s[i+2:i+2+esize*count]
                signed = bool(t & 0x20)
                vals = tuple(int.from_bytes(raw[k*esize:(k+1)*esize], "big", signed=signed) for k in range(count))
                yield ("attr", i, b, vals if count > 1 else vals[0], t)
                i += 2 + esize * count
        elif b < 0x80:
            yield ("op", i, b)
            i += 1
        else:
            raise ValueError(f"unexpected byte {b:#x} at {i}")

def pages(s):
    """Return list of pages: dict(attrs..., bands=[(attrs, data)])"""
    pages, cur, attrs, last_op = [], None, {}, None
    for tok in tokens(s):
        if tok[0] == "op":
            op = tok[2]
            if last_op is not None: pass
            if op == 0x03:
                cur = {"bands": [], "page_attrs": None}; pages.append(cur)
            last_op = op; attrs = {}
            if cur is not None and op == 0x03: cur["page_attrs"] = attrs
            if cur is not None and op == 0x61: cur["image_attrs"] = attrs
            if cur is not None and op == 0x62: cur["bands"].append([attrs, None])
        elif tok[0] == "attr":
            attrs[tok[2]] = (tok[3], tok[4])
        elif tok[0] == "data":
            cur["bands"][-1][1] = tok[2]
    return pages

if __name__ == "__main__":
    s = pdl_stream(open(sys.argv[1], "rb").read())
    for tok in tokens(s):
        if tok[0] == "op": print(f"\n{tok[1]:6d} OP {tok[2]:#04x}", end="")
        elif tok[0] == "attr":
            v = tok[3]; vs = (f"({', '.join(map(str, v))})" if isinstance(v, tuple) else str(v))
            print(f"  {tok[2]:#04x}={vs}" + (f"[t{tok[4]:02x}]" if tok[4] is not None else ""), end="")
        else: print(f"  DATA[{len(tok[2])}]", end="")
    print()
