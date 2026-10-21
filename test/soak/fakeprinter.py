#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""A fake Canon MF4700 on 127.0.0.1 for the soak test: the raw print port (19100),
an SNMP v1 agent (16161, the OIDs device.c asks for) and the MFNP scanner (8610:
Notify registration and polling over UDP, scan sessions over TCP). Faults are
switched on by the soak driver through the Printer object's methods."""
import os, socket, struct, sys, threading, time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
from cpca import packets  # noqa: E402

HOST = "127.0.0.1"


# ---------------------------------------------------------------- SNMP (BER) --

def _len(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b

def tlv(tag, val):
    return bytes([tag]) + _len(len(val)) + val

def ber_int(v, tag=0x02):
    n = max(1, (v.bit_length() + 8) // 8)
    return tlv(tag, v.to_bytes(n, "big", signed=True))

def ber_uint(v, tag):
    b = v.to_bytes(max(1, (v.bit_length() + 7) // 8), "big")
    return tlv(tag, (b"\x00" + b) if b[0] & 0x80 else b)

def parse(data, i):
    tag, l = data[i], data[i + 1]
    i += 2
    if l & 0x80:
        k = l & 0x7F
        l = int.from_bytes(data[i:i + k], "big")
        i += k
    return tag, data[i:i + l], i + l

def items(data):
    i, out = 0, []
    while i < len(data):
        tag, val, i = parse(data, i)
        out.append((tag, val))
    return out

def oid_str(b):
    parts, v = [b[0] // 40, b[0] % 40], 0
    for c in b[1:]:
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            parts.append(v)
            v = 0
    return ".".join(map(str, parts))


class Printer:
    def __init__(self):
        self.lock = threading.Lock()
        self.pages = 120000            # prtMarkerLifeCount
        self.status = 3                # hrPrinterStatus: 3 idle, 4 printing, 5 warmup
        self.errors = 0                # hrPrinterDetectedErrorState bits
        self.toner = 80
        self.snmp_silent_until = 0.0
        self.data_offline_until = 0.0  # nothing listens on the raw port: connections are refused
        self.drop_next_job = False     # accept the next job's connection, then drop it
        self.stall_next_job = 0.0      # seconds to stop reading (paper jam)
        self.page_time = 0.15          # seconds per printed page
        self.jobs = []                 # dicts: bytes, impressions, valid, error
        self.snmp_requests = 0
        # scanner
        self.mfnp_silent_until = 0.0
        self.registered = None         # computer name while listed
        self.polls = 0
        self.registrations = 0
        self.cancels = 0
        self.pending_scan = None       # dict: pages, key, fault, big
        self.active_scan = None
        self.next_status = []          # forced Notify statuses for coming polls (1 rejected, 3 throttling)
        self.events_sent = 0
        self.sessions = 0
        self.pages_sent = 0
        self.scans = []                # finished sessions: pages sent, fault
        self.stop = False

    # ------------------------------------------------------------ servers --
    def start(self):
        self.snmp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.snmp_sock.bind((HOST, 16161))
        self.raw_sock = socket.socket()
        self.raw_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.raw_sock.bind((HOST, 19100))
        self.raw_sock.listen(4)
        self.mfnp_udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.mfnp_udp.bind((HOST, 8610))
        self.mfnp_tcp = socket.socket()
        self.mfnp_tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.mfnp_tcp.bind((HOST, 8610))
        self.mfnp_tcp.listen(2)
        for target in (self.snmp_loop, self.raw_loop, self.mfnp_udp_loop, self.mfnp_tcp_loop):
            threading.Thread(target=target, daemon=True).start()

    # ---------------------------------------------------------------- SNMP --
    def snmp_value(self, oid):
        with self.lock:
            return {
                "1.3.6.1.2.1.1.1.0": tlv(0x04, b"Canon MF4700 Series /P"),
                "1.3.6.1.2.1.43.10.2.1.4.1.1": ber_uint(self.pages, 0x41),
                "1.3.6.1.2.1.25.3.5.1.1.1": ber_int(self.status),
                "1.3.6.1.2.1.25.3.5.1.2.1": tlv(0x04, self.errors.to_bytes(2, "big")),
                "1.3.6.1.2.1.43.11.1.1.8.1.1": ber_int(100),
                "1.3.6.1.2.1.43.11.1.1.9.1.1": ber_int(self.toner),
            }.get(oid)

    def snmp_loop(self):
        while not self.stop:
            try:
                data, addr = self.snmp_sock.recvfrom(4096)
                if time.time() < self.snmp_silent_until:
                    continue
                self.snmp_requests += 1
                (_, msg), = items(data)
                (_, version), (_, community), (pdu_tag, pdu) = items(msg)
                (_, reqid), (_, _), (_, _), (_, vbl) = items(pdu)
                out, err, index = [], 0, 0
                for n, (_, vb) in enumerate(items(vbl), 1):
                    (_, oid), _ = items(vb)
                    value = self.snmp_value(oid_str(oid))
                    if value is None and not err:
                        err, index = 2, n
                    out.append(tlv(0x30, tlv(0x06, oid) + (value or b"\x05\x00")))
                reply = tlv(0xA2, tlv(0x02, reqid) + ber_int(err) + ber_int(index) + tlv(0x30, b"".join(out)))
                self.snmp_sock.sendto(tlv(0x30, tlv(0x02, version) + tlv(0x04, community) + reply), addr)
            except Exception as e:  # keep serving
                print("snmp:", e, file=sys.stderr)

    # ----------------------------------------------------------- raw 9100 --
    def raw_loop(self):
        sock = self.raw_sock
        sock.settimeout(0.5)
        while not self.stop:
            if time.time() < self.data_offline_until:
                if sock:
                    sock.close()                 # switched off: connections are refused
                    sock = None
                time.sleep(0.2)
                continue
            if sock is None:
                sock = socket.socket()
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind((HOST, 19100))
                sock.listen(4)
                sock.settimeout(0.5)
            try:
                c, _ = sock.accept()
            except socket.timeout:
                continue
            c.settimeout(None)
            if self.drop_next_job:
                self.drop_next_job = False
                c.close()
                continue
            threading.Thread(target=self.raw_job, args=(c,), daemon=True).start()

    def raw_job(self, c):
        stall = self.stall_next_job
        self.stall_next_job = 0
        data = bytearray()
        try:
            if stall:                           # paper jam: the printer stops reading
                with self.lock:
                    self.errors |= 0x0400
                time.sleep(stall)
                with self.lock:
                    self.errors &= ~0x0400
            while True:
                b = c.recv(65536)
                if not b:
                    break
                data += b
        except OSError:
            pass
        job = {"bytes": len(data), "impressions": 0, "valid": False, "error": None, "time": time.time()}
        try:
            ops = [(op, pl) for _, _, _, op, _, _, _, _, pl in packets(bytes(data))]
            job["valid"] = bool(ops) and ops[0][0] == 0x6B and ops[-1][0] == 0x13
            for op, pl in ops:
                if op == 0x12 and pl[:2] == b"\x01\x13":
                    job["impressions"] += struct.unpack(">I", pl[2:6])[0]
        except Exception as e:
            job["error"] = str(e)
        if job["impressions"]:
            with self.lock:
                self.status = 4
            for _ in range(job["impressions"]):
                time.sleep(self.page_time)
                with self.lock:
                    self.pages += 1
            with self.lock:
                self.status = 3
        self.jobs.append(job)
        c.close()

    # ---------------------------------------------------------- MFNP / UDP --
    HDR = struct.Struct(">4sBBHHHI")

    def reply(self, cmd, seq, session, payload=b"", status=0):
        return self.HDR.pack(b"MFNP", 0x82, cmd, status, seq, session, len(payload)) + payload

    def mfnp_udp_loop(self):
        while not self.stop:
            try:
                d, a = self.mfnp_udp.recvfrom(4096)
                if time.time() < self.mfnp_silent_until or len(d) < 16:
                    continue
                _, _, cmd, _, seq, sess, n = self.HDR.unpack(d[:16])
                body = d[16:16 + n]
                if cmd == 0x32:
                    self.mfnp_udp.sendto(self.notify(seq, sess, body), a)
                elif cmd == 0x10:                # job details: open a session
                    self.sessions += 1
                    self.mfnp_udp.sendto(self.reply(0x10, seq, 0x2A, b"\x32\x6a\x7e\x7b"), a)
                else:                            # 0x11 close and anything else: ack
                    self.mfnp_udp.sendto(self.reply(cmd, seq, sess), a)
            except Exception as e:
                print("mfnp udp:", e, file=sys.stderr)

    def notify(self, seq, sess, body):
        kind = struct.unpack(">H", body[:2])[0]
        name = body[8:72].split(b"\0")[0].decode("latin-1")
        status, event, key = 0, 0, 0
        with self.lock:
            if kind == 1:
                self.registered = name
                self.registrations += 1
            elif kind == 4:
                self.registered = None
                self.cancels += 1
            elif kind == 2:
                self.polls += 1
                if self.registered != name:
                    status = 1                   # not listed (e.g. printer restarted): register again
                elif self.next_status:
                    status = self.next_status.pop(0)
                    if status == 1:
                        self.registered = None
                elif self.pending_scan:
                    status, event, key = 0x8000, self.events_sent + 1, self.pending_scan["key"]
                    self.active_scan, self.pending_scan = self.pending_scan, None
                    self.events_sent += 1
        payload = struct.pack(">HHIIIBI", 0, status, 0x579B2C32, 0, event, key, 0)
        return self.reply(0x32, seq, sess, payload)

    def request_scan(self, pages=1, key=1, fault=None, big=False):
        with self.lock:
            self.pending_scan = {"pages": pages, "key": key, "fault": fault, "big": big}

    # ---------------------------------------------------------- MFNP / TCP --
    def mfnp_tcp_loop(self):
        while not self.stop:
            c, _ = self.mfnp_tcp.accept()
            threading.Thread(target=self.scan_session, args=(c,), daemon=True).start()

    def scan_session(self, c):
        spec = self.active_scan or {"pages": 1, "key": 1, "fault": None, "big": False}
        pages, fault = spec["pages"], spec["fault"]
        blocks_per_page = 420 if spec["big"] else 40 if fault == "slow" else 3   # 64 KB blocks; 420 = A4 colour
        BLOCK = 0x10000
        pending, page, blocks, sent, frozen = b"", 0, 0, 0, False

        def recvn(n):
            b = b""
            while len(b) < n:
                x = c.recv(n - len(b))
                if not x:
                    raise EOFError
                b += x
            return b
        try:
            while True:
                h = recvn(16)
                _, _, cmd, _, seq, sess, n = self.HDR.unpack(h)
                body = recvn(n) if n else b""
                if frozen:
                    continue
                if cmd == 0x21:
                    c.sendall(self.reply(0x21, seq, sess, struct.pack(">I", n)))
                    op = struct.unpack(">H", body[:2])[0]
                    if op == 0xF320:            # status: paper in the feeder while pages remain
                        adf = page < pages and pages > 1
                        pending = b"\x06\x06\x03" + (b"\x00" if adf else b"\x01") + b"\x00\x41\x03\x00\x41\x00\x01\x00\x00\x76"
                    elif op == 0xD460:
                        if body[8] == 0:        # start of a page
                            page += 1
                            blocks = 0
                            pending = b"\x06\x06\x00\x00" + struct.pack(">I", 0)
                        else:
                            blocks += 1
                            if fault == "jam" and page == pages and blocks == 2:
                                pending = b"\x15\x15"
                            elif fault == "freeze" and page == pages and blocks == 2:
                                frozen = True
                                continue
                            elif fault == "drop" and page == pages and blocks == 2:
                                break
                            elif blocks <= blocks_per_page:
                                if fault == "slow":
                                    time.sleep(0.04)        # under mfnpscan's (scaled) reply timeout
                                pending = b"\x06\x06\x00\x00" + struct.pack(">I", BLOCK) + bytes([(page * 40) & 0xFF]) * BLOCK
                            else:
                                last = page >= pages
                                pending = bytes([6, 6, 0x38 if last else 0x28, 0]) + struct.pack(">I", 0)
                                sent += 1
                    elif op == 0xFF20:
                        pending = b"\x06\x06" + bytes(16)
                    else:
                        pending = b"\x06\x06"
                elif cmd == 0x20:
                    c.sendall(self.reply(0x20, seq, sess, pending))
                    pending = b""
        except (EOFError, OSError):
            pass
        finally:
            c.close()
            with self.lock:
                self.pages_sent += sent
                self.scans.append({"pages": sent, "fault": fault, "time": time.time()})
                self.active_scan = None


if __name__ == "__main__":
    p = Printer()
    p.start()
    print("fake MF4700 on 127.0.0.1: raw 19100, SNMP 16161, MFNP 8610")
    while True:
        time.sleep(5)
        print(f"jobs {len(p.jobs)} pages {p.pages} polls {p.polls} scans {len(p.scans)}", flush=True)
