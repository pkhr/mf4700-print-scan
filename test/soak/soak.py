#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Soak test: runs the SOAK build of the app (test/soak/build.sh) against a fake
MF4700 (fakeprinter.py) for a while. It prints and scans continuously, injects
faults (AirPrint server and scan listener crashes, printer, SNMP and scanner
outages, paper jams, refused registrations), checks every job and scan against
the app's log, and samples the resource use of the whole process tree.
  python3 test/soak/soak.py [--minutes 60] [--leaks] [--out DIR]
Exit status 0 when every check passed."""
import argparse, bisect, os, random, re, signal, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from fakeprinter import Printer  # noqa: E402

NAME = "MF4700 Soak Test"
SUPPORT = os.path.expanduser(f"~/Library/Application Support/{NAME}")
LOG = os.path.expanduser(f"~/Library/Logs/{NAME}.log")
MKRASTER = os.path.join(ROOT, "tools", "mkraster")
IPPTEST = os.path.join(HERE, "print-job.test")


def now():
    return time.time()


class LogWatch:
    """Tails the app's log; workload threads wait for lines matching a pattern."""
    def __init__(self, path):
        self.path, self.lines, self.times, self.cond = path, [], [], threading.Condition()
        self.heartbeats, self.stop = [], False

    def run(self):
        while not os.path.exists(self.path) and not self.stop:
            time.sleep(0.2)
        f = open(self.path, "r", errors="replace")
        buf = ""
        while not self.stop:
            chunk = f.read()
            if not chunk:
                if os.path.getsize(self.path) < f.tell():   # rotated or truncated
                    f.close()
                    f = open(self.path, "r", errors="replace")
                time.sleep(0.2)
                continue
            buf += chunk
            *done, buf = buf.split("\n")
            t = now()
            with self.cond:
                for line in done:
                    if line.startswith("soak: heartbeat "):
                        self.heartbeats.append((t, line))
                    else:
                        self.lines.append((t, line))
                        self.times.append(t)
                self.cond.notify_all()

    def wait(self, pattern, since, timeout):
        rx = re.compile(pattern)
        end = now() + timeout
        with self.cond:
            start = bisect.bisect_left(self.times, since)
            while True:
                for t, line in self.lines[start:]:
                    if rx.search(line):
                        return t, line
                start = len(self.lines)
                left = end - now()
                if left <= 0:
                    return None
                self.cond.wait(min(left, 1))

    def count(self, pattern):
        rx = re.compile(pattern)
        with self.cond:
            return sum(1 for _, line in self.lines if rx.search(line))


class Soak:
    def __init__(self, args):
        self.args = args
        self.out = args.out
        self.app_bin = os.path.join(args.build, NAME + ".app", "Contents", "MacOS", NAME)
        self.procstat = os.path.join(args.build, "procstat")
        os.makedirs(self.out, exist_ok=True)
        self.p = Printer()
        self.log = LogWatch(LOG)
        self.stop = False
        self.lock = threading.Lock()
        self.results = {"jobs": [], "scans": [], "faults": [], "problems": []}
        self.job_in_flight = False
        self.scan_in_flight = False
        self.samples = []
        self.longlived = {}           # pid -> (first seen, name) for transient helpers
        self.zombies = {}             # pid -> first seen as a zombie
        self.app = None

    # --------------------------------------------------------------- setup --
    def problem(self, text):
        with self.lock:
            self.results["problems"].append((now() - self.t0, text))
        print(f"[{now() - self.t0:7.1f}] PROBLEM: {text}", flush=True)

    def say(self, text):
        print(f"[{now() - self.t0:7.1f}] {text}", flush=True)

    def make_rasters(self):
        d = os.path.join(self.out, "rasters")
        os.makedirs(d, exist_ok=True)
        pgm = os.path.join(d, "page.pgm")
        w, h = 600, 800
        with open(pgm, "wb") as f:
            f.write(b"P5\n%d %d\n255\n" % (w, h))
            f.write(bytes(((x // 25 + y // 25) % 2) * 255 for y in range(h) for x in range(w)))
        self.rasters = {}
        for name, media, pages in (("card1", "na_index-3x5_3x5in", 1), ("card3", "na_index-3x5_3x5in", 3),
                                   ("a4", "iso_a4_210x297mm", 1), ("letter2", "na_letter_8.5x11in", 2)):
            path = os.path.join(d, name + ".pwg")
            subprocess.run([MKRASTER, "pwg", media, path] + [pgm] * pages, check=True, capture_output=True)
            self.rasters[name] = (path, pages)

    def clean(self):
        subprocess.run(["pkill", "-f", f"{NAME}.app/Contents/MacOS/"], capture_output=True)
        time.sleep(1)
        subprocess.run(["rm", "-rf", SUPPORT, LOG], check=True)
        subprocess.run(["defaults", "delete", "local.mf4700-airprint.soak"], capture_output=True)

    def launch(self):
        env = dict(os.environ, UFR2LT_SNMP_PORT="16161", MFNPSCAN_TIME_SCALE="0.01", UFR2LT_RETRY="45",
                   TSAN_OPTIONS="halt_on_error=0 second_deadlock_stack=1")
        self.stderr = open(os.path.join(self.out, "app-stderr.txt"), "w")
        self.app = subprocess.Popen([self.app_bin, "-PrinterURI", "socket://127.0.0.1:19100", "-ScanComputerName", "Soak-Mac",
                                     "-SoakPanelToggle", str(self.args.panel_toggle)],
                                    env=env, stdout=self.stderr, stderr=subprocess.STDOUT)
        self.say(f"app pid {self.app.pid}")

    def server_port(self):
        for row in self.tree():
            if row["name"] == "ippeveprinter":
                args = subprocess.run(["ps", "-o", "args=", "-p", str(row["pid"])], capture_output=True, text=True).stdout
                m = re.search(r" -p (\d+)", args)
                if m:
                    return int(m.group(1))
        return None

    # ------------------------------------------------------------- metrics --
    def tree(self):
        if not self.app or self.app.poll() is not None:
            return []
        out = subprocess.run([self.procstat, str(self.app.pid)], capture_output=True, text=True).stdout
        rows = []
        for line in out.splitlines():
            f = line.split(" ", 10)
            rows.append({"pid": int(f[0]), "ppid": int(f[1]), "depth": int(f[2]), "fp": int(f[3]), "rss": int(f[4]),
                         "threads": int(f[5]), "cpu": float(f[6]), "fds": int(f[7]), "zombie": int(f[8]),
                         "peak": int(f[9]), "name": f[10]})
        return rows

    def sampler(self):
        while not self.stop:
            t = now()
            rows = self.tree()
            if rows:
                app = rows[0]
                ipp = next((r for r in rows if r["name"] == "ippeveprinter"), None)
                scan = next((r for r in rows if r["name"] == "mfnpscan" and r["depth"] == 1), None)
                s = {"t": t - self.t0, "app_fp": app["fp"], "app_peak": app["peak"], "app_rss": app["rss"],
                     "app_threads": app["threads"],
                     "app_cpu": app["cpu"], "app_fds": app["fds"], "ipp_fp": ipp and ipp["fp"], "ipp_fds": ipp and ipp["fds"],
                     "scan_fp": scan and scan["fp"], "scan_fds": scan and scan["fds"], "procs": len(rows),
                     "zombies": sum(r["zombie"] for r in rows),
                     "log_kb": os.path.getsize(LOG) // 1024 if os.path.exists(LOG) else 0,
                     "tmp_scan_dirs": len([d for d in os.listdir(os.environ.get("TMPDIR", "/tmp")) if d.startswith("scan-")]),
                     "heartbeat_age": t - self.log.heartbeats[-1][0] if self.log.heartbeats else -1}
                self.samples.append(s)
                seen = set()
                for r in rows[1:]:
                    if r["name"] in ("ippeveprinter", "mfnpscan") and r["depth"] == 1:
                        continue
                    seen.add(r["pid"])
                    first = self.longlived.setdefault(r["pid"], (t, r["name"]))[0]
                    if t - first > 240 and not r.get("reported"):
                        self.problem(f"helper {r['name']} pid {r['pid']} alive for {t - first:.0f} s")
                        self.longlived[r["pid"]] = (float("inf"), r["name"])
                for pid in [p for p in self.longlived if p not in seen]:
                    del self.longlived[pid]
                for r in rows:                   # a zombie that stays is a child nobody reaps
                    if r["zombie"]:
                        first = self.zombies.setdefault(r["pid"], t)
                        if t - first > 15:
                            self.problem(f"zombie {r['name']} pid {r['pid']} (parent {r['ppid']}) for {t - first:.0f} s")
                            self.zombies[r["pid"]] = float("inf")
                for pid in [p for p in self.zombies if p not in {r["pid"] for r in rows if r["zombie"]}]:
                    del self.zombies[pid]
            time.sleep(5)

    # ------------------------------------------------------------ workload --
    def submit(self, k):
        name = random.choice(["card1", "card1", "card3", "letter2", "a4"])
        path, pages = self.rasters[name]
        copies = random.choice([1, 1, 1, 2, 3])
        jobname = f"soak-{k}"
        port = self.server_port() or 18631
        t = now()
        r = subprocess.run(["ipptool", "-q", "-d", f"jobname={jobname}", "-d", f"copies={copies}", "-f", path,
                            f"ipp://localhost:{port}/ipp/print", IPPTEST], capture_output=True, text=True)
        if r.returncode:
            return {"name": jobname, "ok": False, "why": "ipptool: " + (r.stdout + r.stderr).strip()[-200:]}
        start = self.log.wait(r"Job (\d+): printing “" + re.escape(jobname) + "”", t, 120)
        if not start:
            return {"name": jobname, "ok": False, "why": "never started"}
        jid = re.search(r"Job (\d+):", start[1]).group(1)
        end = self.log.wait(rf"Job {jid}: (done|failed)", start[0], 240)
        if not end:
            return {"name": jobname, "ok": False, "why": "never finished"}
        ok = end[1].endswith("done")
        return {"name": jobname, "ok": ok, "why": "" if ok else "failed", "secs": end[0] - t,
                "impressions": pages * copies}

    def printer_loop(self):
        k = 0
        while not self.stop:
            time.sleep(random.uniform(2, 10))
            if self.stop:
                break
            k += 1
            jobs_before = len(self.p.jobs)
            with self.lock:
                self.job_in_flight = True
            res = self.submit(k)
            with self.lock:
                self.job_in_flight = False
                self.results["jobs"].append(res)
            if not res["ok"] and not self.recent_fault(("kill_server", "data_drop"), 90):
                self.problem(f"job {res['name']}: {res['why']}")
            elif res["ok"]:
                got = sum(j["impressions"] for j in self.p.jobs[jobs_before:] if j["valid"])
                if got < res["impressions"]:
                    self.problem(f"job {res['name']}: printer got {got} of {res['impressions']} impressions")

    def scan_loop(self):
        k = 0
        while not self.stop:
            time.sleep(random.uniform(6, 18))
            if self.stop:
                break
            k += 1
            pages = random.choice([1, 1, 2, 3, 4])
            big = random.random() < 0.12
            if big:
                pages = random.choice([3, 6])
            fault = random.choices([None, "jam", "freeze", "drop", "cancel"], [70, 8, 8, 6, 8])[0]
            key = random.choice([1, 2])
            with self.lock:
                self.scan_in_flight = True
            t = now()
            self.p.request_scan(pages=pages, key=key, fault="slow" if fault == "cancel" else fault, big=big and fault != "cancel")
            if fault == "cancel":
                if self.log.wait(r"Scanning from the", t, 30):
                    time.sleep(0.05)
                    for r in self.tree():
                        if r["name"] == "mfnpscan" and r["depth"] == 1:
                            os.kill(r["pid"], signal.SIGTERM)
            end = self.log.wait(r"app: (Saved “|The printer stopped the scan|Scan cancelled|Scan failed|"
                                r"The printer did not start the scan|The scanner sent no pages)", t, 90)
            with self.lock:
                self.scan_in_flight = False
            res = {"pages": pages, "big": big, "fault": fault, "key": key, "secs": end and end[0] - t,
                   "line": end and end[1]}
            self.results["scans"].append(res)
            if not end:
                self.problem(f"scan {k} ({pages} p, fault {fault}): no outcome in the log")
                continue
            saved = self.log.wait(r"app: Saved “.*” \((\d+) page", t, 2)
            got = int(re.search(r"\((\d+) page", saved[1]).group(1)) if saved else 0
            if fault is None and got != pages:
                self.problem(f"scan {k}: expected {pages} pages, saved {got} ({end[1][-80:]})")
            if fault in ("jam", "freeze", "drop") and got != pages - 1:
                self.problem(f"scan {k} ({fault}): expected {pages - 1} saved pages, got {got}")

    # -------------------------------------------------------------- faults --
    def recent_fault(self, kinds, secs):
        return any(k in kinds and now() - t < secs for t, k in self.results["faults"])

    def fault(self, kind):
        with self.lock:
            self.results["faults"].append((now(), kind))
        self.say(f"fault: {kind}")

    def wait_idle(self, timeout=60):
        end = now() + timeout
        while now() < end:
            with self.lock:
                if not self.job_in_flight and not self.scan_in_flight:
                    return True
            time.sleep(0.5)
        return False

    def fault_loop(self):
        schedule = [  # (first at, every, kind)
            (90, self.args.kill_every, "kill_server"), (150, 420, "kill_listener"), (210, 360, "snmp_outage"),
            (270, 540, "scanner_outage"), (330, 480, "data_offline"), (390, 600, "jam"),
            (60, 240, "reject"), (120, 240, "throttle"), (450, 660, "paper_out"), (500, 720, "data_drop")]
        due = {kind: first for first, _, kind in schedule}
        every = {kind: per for _, per, kind in schedule}
        while not self.stop:
            time.sleep(1)
            el = now() - self.t0
            for kind in list(due):
                if el < due[kind] or self.stop:
                    continue
                due[kind] = el + every[kind]
                try:
                    getattr(self, "f_" + kind)()
                except Exception as e:
                    self.problem(f"fault {kind} raised {e!r}")

    def child(self, name):
        return next((r for r in self.tree() if r["name"] == name and r["depth"] == 1), None)

    def f_kill_server(self):
        if not self.wait_idle():
            return
        r = self.child("ippeveprinter")
        if not r:
            return self.problem("no ippeveprinter to kill")
        self.fault("kill_server")
        t = now()
        os.kill(r["pid"], signal.SIGKILL)
        if not self.log.wait(r"AirPrint server stopped \(exit", t, 15):
            self.problem("server death not noticed")
        if not self.log.wait(r"AirPrint printer “.*” is available", t, 30):
            self.problem("AirPrint server not back within 30 s")
        if not self.advertised():
            self.problem("the AirPrint printer is not advertised (Bonjour) after the restart")

    def advertised(self):
        """Ground truth: the local-only Bonjour service resolves to the server's port."""
        r = subprocess.run(["sh", "-c", 'dns-sd -L "MF4700 Soak" _ipp._tcp local. & p=$!; sleep 3; kill $p'],
                           capture_output=True, text=True)
        port = self.server_port()
        return bool(port) and f":{port} " in r.stdout

    def f_kill_listener(self):
        if not self.wait_idle():
            return
        r = self.child("mfnpscan")
        if not r:
            return
        self.fault("kill_listener")
        t, regs = now(), self.p.registrations
        os.kill(r["pid"], signal.SIGKILL)
        end = now() + 30
        while now() < end and self.p.registrations == regs:
            time.sleep(0.5)
        if self.p.registrations == regs:
            self.problem("scan listener not back within 30 s")

    def f_snmp_outage(self):
        self.fault("snmp_outage")
        t = now()
        self.p.snmp_silent_until = t + 20
        if not self.log.wait(r"Printer not found", t, 40):
            self.problem("SNMP outage not noticed")
        if not self.log.wait(r"Printer found at", t + 20, 40):
            self.problem("printer not found again after the SNMP outage")

    def f_scanner_outage(self):
        if not self.wait_idle():
            return
        self.fault("scanner_outage")
        t = now()
        self.p.mfnp_silent_until = t + 8
        regs = self.p.registrations
        end = now() + 45
        while now() < end and self.p.registrations == regs:
            time.sleep(0.5)
        if self.p.registrations == regs:
            self.problem("not registered again after the scanner outage")

    def f_data_offline(self):
        self.fault("data_offline")
        self.p.data_offline_until = now() + 20

    def f_data_drop(self):
        self.fault("data_drop")
        self.p.drop_next_job = True

    def f_jam(self):
        self.fault("jam")
        self.p.stall_next_job = 8

    def f_reject(self):
        self.fault("reject")
        with self.p.lock:
            self.p.next_status.append(1)

    def f_throttle(self):
        self.fault("throttle")
        with self.p.lock:
            self.p.next_status.append(3)

    def f_paper_out(self):
        self.fault("paper_out")
        t = now()
        with self.p.lock:
            self.p.errors |= 0x4000
        if not self.log.wait(r"Printer: Out of paper", t, 30):
            self.problem("paper out not noticed")
        time.sleep(12)
        with self.p.lock:
            self.p.errors &= ~0x4000
        if not self.log.wait(r"Printer: problem cleared", now(), 30):
            self.problem("paper out not cleared")

    # --------------------------------------------------------------- leaks --
    def leaks(self, label):
        if not self.args.leaks or not self.app or self.app.poll() is not None:
            return
        r = subprocess.run(["leaks", str(self.app.pid)], capture_output=True, text=True)
        m = re.search(r"(\d+) leaks? for (\d+) total leaked bytes", r.stdout)
        text = m.group(0) if m else (r.stdout + r.stderr).strip().splitlines()[-1:]
        with open(os.path.join(self.out, f"leaks-{label}.txt"), "w") as f:
            f.write(r.stdout + r.stderr)
        self.say(f"leaks ({label}): {text}")
        self.results.setdefault("leaks", []).append((label, m and int(m.group(1)), m and int(m.group(2))))

    # ---------------------------------------------------------------- main --
    def run(self):
        self.t0 = now()
        self.make_rasters()
        self.clean()
        self.p.start()
        threading.Thread(target=self.log.run, daemon=True).start()
        self.launch()
        if not self.log.wait(r"AirPrint printer “.*” is available", self.t0, 60):
            self.problem("the app's AirPrint server never came up")
        if not self.log.wait(r"Printer found at", self.t0, 60):
            self.problem("the app never found the fake printer")
        if not self.advertised():
            self.problem("the AirPrint printer is not advertised (Bonjour) at start")
        threads = [threading.Thread(target=f, daemon=True)
                   for f in (self.sampler, self.printer_loop, self.scan_loop, self.fault_loop)]
        for th in threads:
            th.start()
        end = self.t0 + self.args.minutes * 60
        next_leaks = self.t0 + 300
        while now() < end:
            time.sleep(5)
            if self.app.poll() is not None:
                self.problem(f"the app exited ({self.app.returncode})")
                break
            if now() >= next_leaks:
                self.leaks(f"{(now() - self.t0) / 60:.0f}min")
                next_leaks += 900
        self.stop = True
        self.wait_idle(120)
        time.sleep(10)
        self.leaks("end")
        self.shutdown()
        self.report()

    def shutdown(self):
        if not self.app or self.app.poll() is not None:
            return
        pids = [r["pid"] for r in self.tree()]
        regs_cancel = self.p.cancels
        self.app.send_signal(signal.SIGTERM)
        try:
            self.app.wait(20)
        except subprocess.TimeoutExpired:
            self.problem("the app did not quit within 20 s of SIGTERM")
            self.app.kill()
        time.sleep(3)
        left = [p for p in pids[1:] if subprocess.run(["kill", "-0", str(p)], capture_output=True).returncode == 0]
        if left:
            self.problem(f"processes left after quit: {left}")
        if self.p.cancels == regs_cancel:
            self.problem("the scan listener did not unregister at quit")

    def report(self):
        s = self.samples
        warm = [x for x in s if x["t"] > 300] or s
        def trend(key):
            pts = [(x["t"], x[key]) for x in warm if x.get(key) is not None]
            if len(pts) < 3:
                return "n/a"
            n = len(pts)
            mx, my = sum(t for t, _ in pts) / n, sum(v for _, v in pts) / n
            var = sum((t - mx) ** 2 for t, _ in pts) or 1
            slope = sum((t - mx) * (v - my) for t, v in pts) / var * 3600
            vals = [v for _, v in pts]
            head, tail = vals[: max(1, n // 10)], vals[-max(1, n // 10):]
            return (f"min {min(vals)} max {max(vals)} first10% {sum(head) / len(head):.0f} "
                    f"last10% {sum(tail) / len(tail):.0f} slope {slope:+.1f}/h")
        cpu = [(b["t"] - a["t"], b["app_cpu"] - a["app_cpu"]) for a, b in zip(s, s[1:]) if b["app_cpu"] >= a["app_cpu"]]
        cpu_pct = [100 * c / 1000 / dt for dt, c in cpu if dt > 0]
        hb = [b[0] - a[0] for a, b in zip(self.log.heartbeats, self.log.heartbeats[1:])]
        jobs, scans = self.results["jobs"], self.results["scans"]
        lines = [
            f"soak: {(s[-1]['t'] if s else 0) / 60:.1f} min, {len(s)} samples",
            f"jobs: {len(jobs)} submitted, {sum(j['ok'] for j in jobs)} done, printer got {len(self.p.jobs)} "
            f"({sum(j['valid'] for j in self.p.jobs)} valid, {sum(j['impressions'] for j in self.p.jobs)} impressions)",
            f"scans: {len(scans)} requested; outcomes: "
            + ", ".join(f"{k}={sum(1 for x in scans if (x['fault'] or 'ok') == k)}" for k in ("ok", "jam", "freeze", "drop", "cancel")),
            f"scanner: {self.p.polls} polls, {self.p.registrations} registrations, {self.p.events_sent} events, "
            f"{self.p.sessions} sessions, {self.p.pages_sent} pages",
            "faults: " + ", ".join(f"{k}×{sum(1 for _, x in self.results['faults'] if x == k)}"
                                   for k in sorted({x for _, x in self.results['faults']})),
            f"app footprint KB: {trend('app_fp')}   lifetime peak {max((x['app_peak'] for x in s), default=0)}",
            f"app resident KB:  {trend('app_rss')}",
            f"app threads:      {trend('app_threads')}",
            f"app fds:          {trend('app_fds')}",
            f"ippeveprinter footprint KB: {trend('ipp_fp')}   fds: {trend('ipp_fds')}",
            f"mfnpscan footprint KB:      {trend('scan_fp')}   fds: {trend('scan_fds')}",
            f"processes in tree: {trend('procs')}   zombies max {max((x['zombies'] for x in s), default=0)}",
            f"log KB: {trend('log_kb')}   leftover scan temp dirs max {max((x['tmp_scan_dirs'] for x in s), default=0)}",
            f"app CPU %: mean {statistics_mean(cpu_pct):.2f}, p95 {pct(cpu_pct, 95):.1f}, max {max(cpu_pct, default=0):.1f}",
            f"main-thread heartbeat gap s: max {max(hb, default=0):.2f}, p99 {pct(hb, 99):.2f} ({len(hb)} beats)",
        ]
        for label, n, b in self.results.get("leaks", []):
            lines.append(f"leaks {label}: {n} leaks, {b} bytes")
        tsan = open(os.path.join(self.out, "app-stderr.txt"), errors="replace").read().count("WARNING: ThreadSanitizer")
        lines.append(f"ThreadSanitizer reports: {tsan}")
        lines.append(f"problems: {len(self.results['problems'])}")
        lines += [f"  [{t:7.1f}] {p}" for t, p in self.results["problems"]]
        text = "\n".join(lines)
        print("\n" + text, flush=True)
        with open(os.path.join(self.out, "report.txt"), "w") as f:
            f.write(text + "\n")
        with open(os.path.join(self.out, "samples.csv"), "w") as f:
            keys = list(s[0]) if s else []
            f.write(",".join(keys) + "\n")
            for x in s:
                f.write(",".join("" if x[k] is None else str(x[k]) for k in keys) + "\n")
        self.failed = bool(self.results["problems"]) or tsan > 0


def statistics_mean(v):
    return sum(v) / len(v) if v else 0.0


def pct(v, p):
    if not v:
        return 0.0
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p / 100))]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=60)
    ap.add_argument("--leaks", action="store_true", help="run leaks(1) on the app every 15 minutes")
    ap.add_argument("--panel-toggle", type=float, default=120, help="open/close the hidden panel every N s")
    ap.add_argument("--kill-every", type=float, default=300, help="kill the AirPrint server every N s")
    ap.add_argument("--build", default=os.path.join(ROOT, "build", "soak"), help="where test/soak/build.sh put the app")
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "soak", "run"))
    args = ap.parse_args()
    soak = Soak(args)
    try:
        soak.run()
    finally:
        soak.stop = True
        if soak.app and soak.app.poll() is None:
            soak.app.kill()
    sys.exit(1 if getattr(soak, "failed", True) else 0)
