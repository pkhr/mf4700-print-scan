#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Send a printer-ready job to a raw (port 9100) printer and watch SNMP until it finishes.
Usage: sendjob.py HOST job.ufr [--no-wait]"""
import socket, subprocess, sys, time

def snmp(host, *oids):
    r = subprocess.run(["snmpget", "-v1", "-c", "public", "-t", "2", "-r", "1", "-Oqv", host, *oids],
                       capture_output=True, text=True)
    return r.stdout.split("\n")[:len(oids)] if r.returncode == 0 else ["?"] * len(oids)

OIDS = ("1.3.6.1.2.1.43.10.2.1.4.1.1",   # prtMarkerLifeCount (pages)
        "1.3.6.1.2.1.25.3.5.1.1.1",      # hrPrinterStatus
        "1.3.6.1.2.1.25.3.5.1.2.1",      # hrPrinterDetectedErrorState
        "1.3.6.1.2.1.25.3.2.1.5.1")      # hrDeviceStatus

def status(host):
    c, ps, err, ds = snmp(host, *OIDS)
    return c.strip(), ps.strip(), err.strip(), ds.strip()

host, path = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
before = status(host)
print(f"before: pages={before[0]} printer={before[1]} errors={before[2]} device={before[3]}")
t0 = time.time()
with socket.create_connection((host, 9100), timeout=30) as s:
    s.sendall(data)
    s.shutdown(socket.SHUT_WR)
    s.settimeout(10)
    reply = b""
    try:
        while chunk := s.recv(4096):
            reply += chunk
    except socket.timeout:
        pass
print(f"sent {len(data)} bytes in {time.time() - t0:.1f}s; printer replied {len(reply)} bytes {reply[:64].hex(' ')}")
if "--no-wait" in sys.argv:
    sys.exit(0)
start = int(before[0]) if before[0].isdigit() else None
for _ in range(45):
    time.sleep(2)
    now = status(host)
    print(f"  t+{time.time() - t0:4.0f}s pages={now[0]} printer={now[1]} errors={now[2]} device={now[3]}")
    if start is not None and now[0].isdigit() and int(now[0]) > start and now[1] in ("idle", "3"):
        print(f"DONE: counter advanced by {int(now[0]) - start}")
        break
