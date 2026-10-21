#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Split a Canon CPCA-framed stream into packets. Usage: cpca.py file [--pdl out.bin]"""
import sys, struct
def packets(b):
    i = 0
    while i < len(b):
        if b[i:i+2] != b"\xcd\xca":
            raise ValueError(f"bad magic at {i:#x}: {b[i:i+8].hex()}")
        ver, kind, op, one, ln, ff = struct.unpack(">BBHHHH", b[i+2:i+12])
        pad = b[i+12:i+20]
        yield i, ver, kind, op, one, ln, ff, pad, b[i+20:i+20+ln]
        i += 20 + ln
if __name__ == "__main__":
    b = open(sys.argv[1], "rb").read()
    pdl = bytearray()
    for off, ver, kind, op, one, ln, ff, pad, pl in packets(b):
        extra = "" if (one == 1 and ff == 0xffff and pad == bytes(8)) else f" one={one:#x} ff={ff:#x} pad={pad.hex()}"
        print(f"{off:6x} v{ver:02x} k{kind:02x} op={op:#06x} len={ln:5d}{extra}  {pl[:40].hex(' ')}{' …' if ln > 40 else ''}")
        if kind == 2: pdl += pl
    if "--pdl" in sys.argv:
        open(sys.argv[sys.argv.index("--pdl") + 1], "wb").write(pdl)
        print(f"# data payload total {len(pdl)} bytes")
