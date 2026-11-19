#!/usr/bin/env python3
"""
Operator dashboard for the FPGA miner (DE1-SoC virtual-wire firmware).

Starts the JTAG bridge (bridge.tcl under quartus_stp), feeds the FPGA work,
checks every golden nonce it reports in software, raises alarms, and serves
a live dashboard at http://127.0.0.1:8080 (local only).

Usage:
    python dashboard.py [--port 8080] [--expected-mhs 25] [--demo]

--demo runs without hardware, simulating the FPGA (for trying the UI).
Standard library only.
"""
import argparse
import glob
import json
import os
import queue
import random
import socket
import struct
import subprocess
import sys
import threading
import time
from collections import deque
from hashlib import sha256
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "test"))
from test_vectors import GENESIS_HEADER, VECTORS, getwork_from_header, reverse_hex, swap32_bytes  # noqa: E402

TEST_SHARE_HEADER = swap32_bytes(bytes.fromhex(VECTORS[0][1]))
# Valid nonces for TEST_SHARE_HEADER; the last two were found by the FPGA itself
TEST_SHARE_NONCES = (0x0E33337A, 0x9CCDEF20, 0xACBBA77F)

LINK_TIMEOUT_S = 3.0
STALL_TIMEOUT_S = 3.0
RATE_TOLERANCE = 0.05
HISTORY_SECONDS = 600
WORK_HISTORY = 4  # nonces can arrive just after new work, so keep recent work


def find_quartus_stp():
    candidates = []
    root = os.environ.get("QUARTUS_ROOTDIR")
    if root:
        candidates.append(os.path.join(root, "bin64", "quartus_stp.exe"))
    for base in ("D:\\intelFPGA_lite", "D:\\altera_lite", "C:\\intelFPGA_lite", "C:\\altera_lite"):
        candidates += sorted(glob.glob(os.path.join(base, "*", "quartus", "bin64", "quartus_stp.exe")), reverse=True)
    for c in candidates:
        # The standalone Programmer has quartus_stp but not the source/probe API we need alongside quartus_sh
        if os.path.exists(c) and os.path.exists(os.path.join(os.path.dirname(c), "quartus_sh.exe")):
            return c
    return None


class Work:
    """One unit of work: an 80-byte header whose nonce field the FPGA searches."""

    def __init__(self, work_id, label, header):
        self.id = work_id
        self.label = label
        self.header = header
        midstate, data = getwork_from_header(header)
        self.stat = reverse_hex(midstate)
        self.dat2 = reverse_hex(data)[64:128]
        self.sent_at = time.time()

    def check(self, nonce):
        """Double SHA-256 with the FPGA's nonce; valid if the top 32 bits are zero."""
        header = self.header[:76] + struct.pack(">I", nonce)
        digest = sha256(sha256(header).digest()).digest()
        return digest[28:] == b"\0\0\0\0", digest[::-1].hex()

    @staticmethod
    def random(work_id):
        header = (struct.pack("<I", 0x20000000) + os.urandom(32) + os.urandom(32)
                  + struct.pack("<I", int(time.time())) + struct.pack("<I", 0x1D00FFFF) + b"\0\0\0\0")
        return Work(work_id, "Random header", header)

    @staticmethod
    def genesis(work_id):
        return Work(work_id, "Bitcoin genesis block", GENESIS_HEADER)

    @staticmethod
    def test_share(work_id):
        return Work(work_id, "Test share (testbench vector)", TEST_SHARE_HEADER)


class Monitor:
    def __init__(self, expected_mhs):
        self.lock = threading.Lock()
        self.expected_mhs = expected_mhs
        self.started = time.time()
        self.connected = False
        self.board_name = ""
        self.has_status = False
        self.last_sample_wall = 0.0
        self.last_error = ""
        self.samples = deque(maxlen=50)          # (t_s, nonce) for the rate estimate
        self.history = deque(maxlen=HISTORY_SECONDS)  # (unix_s, MH/s), one per second
        self.last_history_s = 0
        self.nonce = None
        self.last_advance_wall = time.time()
        self.gnon_baseline = None
        self.status = -1
        self.found = []
        self.events = deque(maxlen=200)
        self.work = deque(maxlen=WORK_HISTORY)
        self.next_work_id = 1
        self.pending_work = queue.Queue()
        self.active_alarms = {}
        self.invalid_acked = 0  # failed checks already acknowledged by the operator
        self.event("info", "Dashboard started")

    # Events and alarms -------------------------------------------------

    def event(self, level, message):
        self.events.appendleft({"t": time.time(), "level": level, "message": message})

    def set_alarm(self, key, active, level, message):
        if active and key not in self.active_alarms:
            self.active_alarms[key] = {"level": level, "message": message, "since": time.time(), "acked": False}
            self.event(level, message)
        elif active:
            self.active_alarms[key]["message"] = message
        elif not active and key in self.active_alarms:
            del self.active_alarms[key]
            self.event("good", f"Cleared: {message}")

    def acknowledge(self):
        """Operator acknowledge: marks active alarms acknowledged and releases
        the latched failed-check alarm (it re-raises on the next failure)."""
        with self.lock:
            self.invalid_acked = sum(1 for f in self.found if not f["valid"])
            for a in self.active_alarms.values():
                a["acked"] = True
            self.event("info", "Alarms acknowledged by operator")

    # Work --------------------------------------------------------------

    def queue_work(self, kind):
        with self.lock:
            wid = self.next_work_id
            self.next_work_id += 1
        make = {"genesis": Work.genesis, "test_share": Work.test_share}.get(kind, Work.random)
        work = make(wid)
        self.pending_work.put(work)
        return work

    def work_sent(self, work):
        with self.lock:
            work.sent_at = time.time()
            self.work.appendleft(work)
            self.event("info", f"Work #{work.id} sent to FPGA ({work.label})")

    # Samples from the bridge ------------------------------------------

    def on_connected(self, name, has_status):
        with self.lock:
            self.connected = True
            self.board_name = name
            self.has_status = has_status
            self.gnon_baseline = None
            self.samples.clear()
            self.event("good", f"Connected to {name}")
            if not has_status:
                self.event("info", "Firmware has no STUS probe; halt and switch status unavailable")

    def on_error(self, message):
        with self.lock:
            self.last_error = message
            if self.connected:
                self.event("critical", message)
            self.connected = False

    def on_sample(self, nonce, gnon, status):
        now = time.time()
        with self.lock:
            self.last_sample_wall = now
            self.status = status
            if self.nonce is None or nonce != self.nonce:
                self.last_advance_wall = now
            self.nonce = nonce
            self.samples.append((now, nonce))

            if self.gnon_baseline is None:
                self.gnon_baseline = gnon  # left over from before we connected
            elif gnon != self.gnon_baseline:
                self.gnon_baseline = gnon
                self.record_found(gnon, now)

            sec = int(now)
            if sec != self.last_history_s and len(self.samples) >= 2:
                self.last_history_s = sec
                self.history.append((sec, round(self.rate_mhs(), 3)))

    def record_found(self, nonce, now):
        valid, block_hash, work_id = False, "", None
        for work in self.work:
            ok, h = work.check(nonce)
            if ok:
                valid, block_hash, work_id = True, h, work.id
                break
        if not valid and self.work:
            _, block_hash = self.work[0].check(nonce)
            work_id = self.work[0].id
        self.found.insert(0, {"t": now, "nonce": f"{nonce:08x}", "hash": block_hash,
                              "valid": valid, "work_id": work_id})
        del self.found[100:]
        if valid:
            self.event("good", f"Golden nonce 0x{nonce:08x} found and verified")
        else:
            self.event("critical", f"Golden nonce 0x{nonce:08x} FAILED software verification")

    def rate_mhs(self):
        recent = [s for s in self.samples if s[0] >= self.samples[-1][0] - 2.0] if self.samples else []
        if len(recent) < 2:
            return 0.0
        (t0, n0), (t1, n1) = recent[0], recent[-1]
        if t1 <= t0:
            return 0.0
        return ((n1 - n0) & 0xFFFFFFFF) / (t1 - t0) / 1e6

    # Snapshot for the UI -------------------------------------------------

    def snapshot(self):
        now = time.time()
        with self.lock:
            link_ok = self.connected and now - self.last_sample_wall < LINK_TIMEOUT_S
            halted = self.has_status and self.status >= 0 and bool(self.status >> 31)
            rate = self.rate_mhs() if link_ok else 0.0
            stalled = link_ok and not halted and now - self.last_advance_wall > STALL_TIMEOUT_S
            deviation = abs(rate - self.expected_mhs) / self.expected_mhs if self.expected_mhs else 0
            invalid = sum(1 for f in self.found if not f["valid"])
            unacked_invalid = invalid - self.invalid_acked

            self.set_alarm("link", not link_ok, "critical",
                           "Board not connected" if not self.last_error else f"Board not connected: {self.last_error}")
            self.set_alarm("halt", link_ok and halted, "warning", "Halted by operator (SW9 up)")
            self.set_alarm("stall", stalled, "critical", "Nonce counter stalled: hash clock or pipeline fault")
            self.set_alarm("rate", link_ok and not halted and not stalled and len(self.samples) > 10
                           and deviation > RATE_TOLERANCE, "serious",
                           f"Hash rate {rate:.2f} MH/s is outside {self.expected_mhs:g} MH/s ±{RATE_TOLERANCE:.0%}")
            self.set_alarm("invalid", unacked_invalid > 0, "critical",
                           f"{unacked_invalid} reported nonce(s) failed verification")

            switches = (self.status >> 16) & 0x3FF if self.status >= 0 else None
            work = self.work[0] if self.work else None
            return {
                "now": now,
                "uptime_s": now - self.started,
                "link_ok": link_ok,
                "board": self.board_name,
                "has_status": self.has_status,
                "halted": halted,
                "switches": switches,
                "fpga_found_count": (self.status & 0xFFFF) if self.status >= 0 else None,
                "rate_mhs": rate,
                "expected_mhs": self.expected_mhs,
                "nonce": f"{self.nonce:08x}" if self.nonce is not None else None,
                "sweep_pct": (self.nonce / 2**32 * 100) if self.nonce is not None else None,
                "history": list(self.history),
                "found": self.found[:50],
                "found_valid": sum(1 for f in self.found if f["valid"]),
                "found_invalid": invalid,
                "alarms": sorted(self.active_alarms.values(),
                                 key=lambda a: (a["acked"], ["critical", "serious", "warning"].index(a["level"]))),
                "events": list(self.events)[:60],
                "work": {"id": work.id, "label": work.label, "sent_at": work.sent_at} if work else None,
            }


class Bridge(threading.Thread):
    """Runs bridge.tcl under quartus_stp and pumps its JSON lines into the Monitor."""

    def __init__(self, monitor, quartus_stp):
        super().__init__(daemon=True)
        self.monitor = monitor
        self.quartus_stp = quartus_stp

    def run(self):
        while True:
            try:
                self.run_once()
            except Exception as exc:  # keep the dashboard alive whatever happens
                self.monitor.on_error(f"Bridge error: {exc}")
            time.sleep(2)

    def run_once(self):
        # The bridge connects back to us over localhost TCP: quartus_stp
        # block-buffers stdout pipes, which would deliver samples in bursts.
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        listener.settimeout(90)  # quartus_stp takes several seconds to start
        port = listener.getsockname()[1]
        proc = subprocess.Popen(
            [self.quartus_stp, "-t", os.path.join(HERE, "bridge.tcl"), str(port)],
            cwd=HERE, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            conn, _ = listener.accept()
        except socket.timeout:
            proc.kill()
            self.monitor.on_error("JTAG bridge did not start (quartus_stp)")
            return
        finally:
            listener.close()

        stream = conn.makefile("rw", encoding="utf-8", newline="\n")
        sender = threading.Thread(target=self.send_work, args=(proc, stream), daemon=True)
        sender.start()
        try:
            for line in stream:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                kind = msg.get("type")
                if kind == "sample":
                    self.monitor.on_sample(msg["nonce"], msg["gnon"], msg["status"])
                elif kind == "connected":
                    self.monitor.on_connected(msg["name"], bool(msg["has_status"]))
                    if not self.monitor.work:
                        self.monitor.queue_work("random")
                    else:
                        self.monitor.pending_work.put(self.monitor.work[0])  # re-send after reconnect
                elif kind == "error":
                    self.monitor.on_error(msg["message"])
        except OSError:
            pass
        finally:
            conn.close()
            proc.kill()
        self.monitor.on_error("JTAG bridge exited")

    def send_work(self, proc, stream):
        while proc.poll() is None:
            try:
                work = self.monitor.pending_work.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                stream.write(f"WORK {work.stat} {work.dat2}\n")
                stream.flush()
                self.monitor.work_sent(work)
            except OSError:
                self.monitor.pending_work.put(work)
                return


class DemoBridge(threading.Thread):
    """Simulated FPGA for --demo: ~25 MH/s on the test-share header, reporting its
    known valid nonces at a sped-up rate, plus an occasional bad one so the
    verification alarm can be seen."""

    def __init__(self, monitor):
        super().__init__(daemon=True)
        self.monitor = monitor

    def run(self):
        m = self.monitor
        m.on_connected("Demo board (simulated)", True)
        m.queue_work("test_share")
        nonce, gnon, found, last, i = random.getrandbits(32), 0, 0, time.time(), 0
        while True:
            time.sleep(0.2)
            while not m.pending_work.empty():
                m.work_sent(m.pending_work.get())
            now = time.time()
            nonce = (nonce + int((now - last) * m.expected_mhs * 1e6 * random.uniform(0.999, 1.001))) & 0xFFFFFFFF
            last = now
            if random.random() < 0.02 and m.work:
                label = m.work[0].label
                known = TEST_SHARE_NONCES if label.startswith("Test") else (0x1DAC2B7C,) if label.startswith("Bitcoin") else ()
                if known and random.random() < 0.9:
                    gnon = known[i % len(known)]
                    i += 1
                elif random.random() < 0.3:
                    gnon = random.getrandbits(32)  # a bad report, to exercise the alarm
                found += 1
            m.on_sample(nonce, gnon, found & 0xFFFF)


def make_handler(monitor):
    page = open(os.path.join(HERE, "dashboard.html"), "rb").read()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, body, ctype):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self.send(200, page, "text/html; charset=utf-8")
            elif self.path == "/api/state":
                self.send(200, json.dumps(monitor.snapshot()).encode(), "application/json")
            else:
                self.send(404, b"not found", "text/plain")

        def do_POST(self):
            if self.path == "/api/ack":
                monitor.acknowledge()
                self.send(200, b"{}", "application/json")
            elif self.path == "/api/work":
                length = int(self.headers.get("Content-Length", 0))
                try:
                    kind = json.loads(self.rfile.read(length) or b"{}").get("kind", "random")
                except ValueError:
                    kind = "random"
                work = monitor.queue_work(kind if kind in ("genesis", "test_share") else "random")
                self.send(200, json.dumps({"queued": work.id}).encode(), "application/json")
            else:
                self.send(404, b"not found", "text/plain")

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--expected-mhs", type=float, default=25.0, help="expected hash rate for the rate alarm")
    ap.add_argument("--demo", action="store_true", help="simulate the FPGA (no hardware needed)")
    args = ap.parse_args()

    monitor = Monitor(args.expected_mhs)
    if args.demo:
        DemoBridge(monitor).start()
    else:
        stp = find_quartus_stp()
        if not stp:
            sys.exit("Quartus (quartus_stp.exe) not found. Set QUARTUS_ROOTDIR or install to D:\\altera_lite.")
        Bridge(monitor, stp).start()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(monitor))
    print(f"Dashboard: http://127.0.0.1:{args.port}  (Ctrl+C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
