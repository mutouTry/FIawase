#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2025-2026 the FIawase authors
"""Run FIawase campaigns on an FPGA board and classify every trial (written for the example board).

usage:
  board_campaign.py parse    <raw.hex>
      parse a saved line (hex bytes, one per line) the way the board's stream is parsed
  board_campaign.py listen   [--uart /dev/ttyUSB2] [--seconds 10]
      print the host stream: one record per DUT run (press CPU RESET to see the power-on run)
  board_campaign.py run      [--uart /dev/ttyUSB2] --end-newlines N --golden-from <fi_obs.log> <camp.json> [...]
                             [--out results.jsonl] [--vcs-obs <dir with <camp>/fi_obs.log>]
      load each campaign over JTAG (OpenOCD, fi_board.cfg), let the wrapper run it, read every
      trial's output from the UART and classify it

The board's UART carries fi_board_uart's stream: a record C0 'T' <trial:2> <cycles:4> <flags:1> in
front of every DUT run (trial = DUT reset releases since the board reset, cycles = length of the
previous run, flags bit 0 = it was ended by a full undo log (DUE), bit 1 = bytes lost), then the
DUT's bytes; C0/DB in the data are sent as DB DC / DB DD. The bytes are those a simulation observer
logs: the DUT's UART TX decoded by the same receiver, inside the trial's output window.

Classification, by the workload's end marker, the --end-newlines-th '\n': Masked = the output up to the
marker equals the golden's; SDC = the marker arrived, the output before it differs; DUE = no marker, or flags
bit 0, or a --crash text (a crash report of the workload's runtime) or a restart (the golden's first line
printed again) before the marker. Output after the marker is not compared. A trial whose
own record or the one before it has flags bit 1 (bytes lost) is LOST: its bytes are incomplete or start with the
previous trial's, so it is not classified.

Campaign files: {"scan_len", "w_idx", "to_thr", "trials": [[FI_Cycle, [FI_Index, ...]], ...]}. The golden
output is --golden-text, or trial 0's bytes in a simulation observer's log (fi_obs.log: one line per output byte,
"<event> <trial> <.> <.> <byte hex>", and "A <trial>" for a trial a memory ended).
"""
import argparse
import glob
import json
import os
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIAWASE_HOST = os.path.normpath(os.path.join(HERE, "..", "..", "host"))   # the FI procs
OPENOCD = os.environ.get("OPENOCD", "openocd")
OPENOCD_LIB = os.environ.get("OPENOCD_LIB", "")      # LD_LIBRARY_PATH, for an OpenOCD build that needs one
EOT = b"\x1a"
CLK_HZ = 12.5e6                                      # the example's functional clock
# fi_campaign's steps (inject_and_run_dmi.tcl): the cutover and table pointer, one fi_pattern per trial
# (one DMI write per FI Table entry), the configuration writes that arm the loop
PROFILE_TCL = """
set ::fi_prof_steps {fi_mode_and_loader fi_pattern fi_config_and_arm}
foreach p $::fi_prof_steps {
    if {[info procs _prof_$p] eq ""} { rename $p _prof_$p }
    set ::fi_prof($p) 0
    proc $p args [string map [list @P@ $p] {
        set t [clock microseconds]
        set r [uplevel 1 [list _prof_@P@ {*}$args]]
        set ::fi_prof(@P@) [expr {$::fi_prof(@P@) + [clock microseconds] - $t}]
        return $r
    }]
}
"""


class Stream:
    """Reads the board's UART in a thread and splits it into runs."""

    def __init__(self, port, baud):
        self.runs = []          # [{"trial", "cycles_prev", "flags_prev", "t", "data": bytearray}]
        self.lock = threading.Lock()
        self.stop = False
        self.esc = False
        self.rec = None
        if port is None:                      # parse: bytes come from feed()
            return
        import serial
        self.ser = serial.Serial(port, baud, timeout=0.05)
        self.ser.reset_input_buffer()
        self.th = threading.Thread(target=self._loop, daemon=True)
        self.th.start()

    def feed(self, data):
        for x in data:
            self._byte(x, 0.0)

    def _loop(self):
        while not self.stop:
            chunk = self.ser.read(max(1, self.ser.in_waiting))
            now = time.time()
            for x in chunk:
                self._byte(x, now)

    def _byte(self, x, now):
        if x == 0xC0:
            self.rec, self.esc = [], False
            return
        if x == 0xDB:
            self.esc = True
            return
        if self.esc:
            x = 0xC0 if x == 0xDC else 0xDB
            self.esc = False
        if self.rec is not None:
            self.rec.append(x)
            if len(self.rec) == 8:
                r = self.rec
                self.rec = None
                with self.lock:
                    self.runs.append({"trial": (r[1] << 8) | r[2],
                                      "cycles_prev": int.from_bytes(bytes(r[3:7]), "big"),
                                      "flags_prev": r[7], "t": now, "data": bytearray()})
            return
        with self.lock:
            if self.runs:
                self.runs[-1]["data"].append(x)

    def snapshot(self):
        with self.lock:
            return [dict(r, data=bytes(r["data"])) for r in self.runs]

    def close(self):
        self.stop = True
        self.th.join(timeout=1)
        self.ser.close()


class OpenOCD:
    def __init__(self, args, log):
        env = dict(os.environ, **({"LD_LIBRARY_PATH": args.openocd_lib} if args.openocd_lib else {}))
        pre = ["-c", f"set FIAWASE_HOST {{{FIAWASE_HOST}}}",
               "-c", f"set FI_FTDI_CHANNEL {args.channel}", "-c", f"set CPUTAPID {args.cputapid}",
               "-c", f"set FI_ADAPTER_KHZ {args.adapter_khz}"]
        self.logf = open(log, "w")
        self.p = subprocess.Popen([args.openocd, "-c", "gdb_port disabled", "-c", "telnet_port disabled",
                                   "-c", f"tcl_port {args.tcl_port}"] + pre + ["-f", args.cfg],
                                  stdout=self.logf, stderr=subprocess.STDOUT, env=env)
        t0 = time.time()
        self.sock = None
        while self.sock is None:
            if self.p.poll() is not None:
                sys.exit(f"OpenOCD exited ({self.p.returncode}); see {log}")
            try:
                self.sock = socket.create_connection(("127.0.0.1", args.tcl_port), timeout=5)
            except OSError:
                if time.time() - t0 > 30:
                    sys.exit(f"OpenOCD's Tcl port never opened; see {log}")
                time.sleep(0.5)
        while "fi_campaign" not in self.rpc("info procs fi_campaign"):
            if self.p.poll() is not None:
                sys.exit(f"OpenOCD exited ({self.p.returncode}); see {log}")
            time.sleep(0.5)
        if args.profile:
            # wrap the steps of fi_campaign with a timer, in this session only
            self.rpc(PROFILE_TCL)

    def profile(self):
        """{step: microseconds} since the last call"""
        r = self.rpc("set r {}; foreach p $::fi_prof_steps { lappend r $p $::fi_prof($p); set ::fi_prof($p) 0 }; "
                     "set r")
        v = r.split()
        return {v[i]: int(v[i + 1]) for i in range(0, len(v) - 1, 2)}

    def rpc(self, cmd, timeout=600):
        self.sock.settimeout(timeout)
        self.sock.sendall(cmd.encode() + EOT)
        buf = b""
        while not buf.endswith(EOT):
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("OpenOCD closed the Tcl connection")
            buf += chunk
        return buf[:-1].decode(errors="ignore")

    def close(self):
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill()
        self.logf.close()


def golden_from(path, ev):
    out = bytearray()
    for ln in open(path, errors="ignore"):
        f = ln.split()
        if f and f[0] == ev and f[1] == "0":
            out.append(int(f[4], 16))
    if not out:
        sys.exit(f"{path}: no {ev} lines of trial 0")
    return bytes(out)


def upto_marker(bs, n_end):
    """(the bytes up to and including the n_end-th newline, whether there are that many)."""
    k = 0
    for i, b in enumerate(bs):
        if b == 0x0A:
            k += 1
            if k == n_end:
                return bytes(bs[:i + 1]), True
    return bytes(bs), False


def classify(data, golden, aborted, n_end, crash):
    if aborted:
        return "DUE"
    dm, done = upto_marker(data, n_end)
    gm, gdone = upto_marker(golden, n_end)
    if not gdone:
        sys.exit(f"the golden output has fewer than {n_end} newlines")
    if not done:
        return "DUE"
    first = gm[:gm.index(0x0A) + 1]
    if any(c.encode() in dm for c in crash) or dm.count(first) > 1:
        return "DUE"
    return "Masked" if dm == gm else "SDC"


def obs_bytes(path, ev):
    by = {}
    for ln in open(path, errors="ignore"):
        f = ln.split()
        if f and f[0] == ev:
            by.setdefault(int(f[1]), bytearray()).append(int(f[4], 16))
        if f and f[0] == "A":
            by.setdefault(("A", int(f[1])), True)
    return by


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", choices=["parse", "listen", "run"])
    ap.add_argument("campaigns", nargs="*")
    ap.add_argument("--uart", help="the board's USB UART; default: the one /dev/serial/by-id/*FT232R* entry")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=10)
    ap.add_argument("--golden-from", help="a fault-free run's fi_obs.log (trial 0's bytes)")
    ap.add_argument("--obs-event", default="V",
                    help="the observer log's byte event that matches the host stream")
    ap.add_argument("--golden-text", help="the golden output as text, \\n allowed")
    ap.add_argument("--end-newlines", type=int,
                    help="run: the workload's end marker, its output is complete at this many newlines; no default")
    ap.add_argument("--crash", action="append", default=[],
                    help="run: a crash report text of the workload's runtime, repeatable")
    ap.add_argument("--out", default="board_results.jsonl")
    ap.add_argument("--vcs-obs", help="directory with <camp>/fi_obs.log of the same campaigns in simulation")
    ap.add_argument("--openocd", default=OPENOCD)
    ap.add_argument("--openocd-lib", default=OPENOCD_LIB)
    ap.add_argument("--cfg", default=os.path.join(HERE, "fi_board.cfg"))
    ap.add_argument("--channel", type=int, default=0, help="FT2232H port of the host JTAG")
    ap.add_argument("--cputapid", default="0", help="the DUT TAP's IDCODE; 0 accepts any")
    ap.add_argument("--tcl-port", type=int, default=16666)
    ap.add_argument("--timeout", type=float, default=120, help="seconds to wait for a campaign's trials")
    ap.add_argument("--adapter-khz", type=int, default=1000,
                    help="TCK of the host JTAG (the XDC constrains it to 10 MHz)")
    ap.add_argument("--profile", action="store_true",
                    help="time fi_campaign's steps (cutover, FI Table, configuration) inside OpenOCD")
    args = ap.parse_intermixed_args()      # campaign files may follow the options

    if args.what == "parse":
        st = Stream(None, 0)
        st.feed(bytes(int(x, 16) for x in open(args.campaigns[0]).read().split()))
        for r in st.snapshot():
            print(f"R {r['trial']} {r['cycles_prev']} {r['flags_prev']}")
            for x in r["data"]:
                print(f"B {r['trial']} {x:02x}")
        return
    if not args.uart:
        ports = glob.glob("/dev/serial/by-id/*FT232R*")
        if len(ports) != 1:
            sys.exit(f"--uart is needed (FT232R ports found: {ports})")
        args.uart = ports[0]
    st = Stream(args.uart, args.baud)
    try:
        if args.what == "listen":
            t0 = time.time()
            shown = 0
            while time.time() - t0 < args.seconds:
                time.sleep(0.2)
                runs = st.snapshot()
                for r in runs[shown:-1] if len(runs) > 1 else []:
                    print(f"run {r['trial']}: {len(r['data'])} bytes {r['data']!r}")
                shown = max(shown, len(runs) - 1)
            runs = st.snapshot()
            for r in runs[shown:]:
                print(f"run {r['trial']} (still open): {len(r['data'])} bytes {r['data']!r}; "
                      f"previous run {r['cycles_prev']} cycles, flags {r['flags_prev']}")
            return

        if args.golden_from:
            golden = golden_from(args.golden_from, args.obs_event)
        elif args.golden_text is not None:
            golden = args.golden_text.encode().decode("unicode_escape").encode("latin-1")
        else:
            sys.exit("run needs --golden-from or --golden-text")
        if args.end_newlines is None:
            sys.exit("run needs --end-newlines")
        if not upto_marker(golden, args.end_newlines)[1]:
            sys.exit(f"the golden output has fewer than {args.end_newlines} newlines")
        ocd = OpenOCD(args, os.path.abspath(args.out) + ".openocd.log")
        out = open(args.out, "a")
        try:
            for path in args.campaigns:
                camp = json.load(open(path))
                n = len(camp["trials"])
                ocd.rpc(f"set FI_SCAN_LEN {camp['scan_len']}")
                ocd.rpc(f"set FI_W_IDX {camp['w_idx']}")
                # After a campaign the wrapper keeps ending the DUT's (fault-free) runs at TO_Thr, one
                # record each. Stop that first (CFG_TO_THR = 0: no timeout), wait until the stream is
                # quiet, then arm: the next record is then this campaign's first trial. (Before any
                # campaign CFG_TO_THR is still 0 and the wrapper ignores this write.)
                t_pause = time.time()
                ocd.rpc("fi_dmi_write 0x66 0; fi_dmi_flush")
                # quiet = no record for two trial lengths plus the time the host FIFO (1024 bytes at
                # 115,741 baud) takes to drain
                trial_s = (camp["to_thr"] + 2 * camp["scan_len"]) / CLK_HZ
                quiet = max(0.15, 2 * trial_s + 1024 * 10 / 115741)
                n_last, t_quiet = len(st.snapshot()), time.time()
                t_stop = t_quiet
                while time.time() - t_quiet < quiet:
                    time.sleep(0.05)
                    if len(st.snapshot()) != n_last:
                        n_last, t_quiet = len(st.snapshot()), time.time()
                    if time.time() - t_stop > 10:
                        sys.exit(f"{path}: the DUT keeps being restarted after CFG_TO_THR = 0 was written, so "
                                 "the write did not reach the wrapper. If the OpenOCD log shows a second TAP "
                                 "(auto0), OpenOCD was started after an earlier session's cutover and misread "
                                 "the wrapper's IDCODE; press CPU RESET (or reprogram) and run again.")
                before = len(st.snapshot())
                trials = " ".join("{%d {%s}}" % (c, " ".join(map(str, f))) for c, f in camp["trials"])
                t_load = time.time()
                r = ocd.rpc(f"fi_campaign {{{trials}}} {camp['to_thr']}")
                t_armed = time.time()
                prof = ocd.profile() if args.profile else None
                if "error" in r.lower():
                    sys.exit(f"{path}: fi_campaign failed: {r}")
                # trial j of the campaign is run before+j-1 of the stream; the record after the last
                # trial (the DUT's next run) carries its length and flags
                while len(st.snapshot()) < before + n + 1:
                    if time.time() - t_armed > args.timeout:
                        print(f"{path}: timeout, {len(st.snapshot()) - before} of {n + 1} records")
                        break
                    time.sleep(0.05)
                runs = st.snapshot()
                vlog = os.path.join(args.vcs_obs or "", os.path.basename(path)[:-5], "fi_obs.log")
                vcs = obs_bytes(vlog, args.obs_event) if args.vcs_obs and os.path.exists(vlog) else None
                counts = {}
                same = 0
                for j in range(1, n + 1):
                    k = before + j - 1
                    if k + 1 >= len(runs):
                        break
                    run, nxt = runs[k], runs[k + 1]
                    aborted = bool(nxt["flags_prev"] & 1)
                    lost = bool((nxt["flags_prev"] | run["flags_prev"]) & 2)
                    cls = "LOST" if lost else classify(run["data"], golden, aborted, args.end_newlines, args.crash)
                    counts[cls] = counts.get(cls, 0) + 1
                    rec = {"campaign": path, "trial": j, "fi_cycle": camp["trials"][j - 1][0],
                           "F": camp["trials"][j - 1][1], "run": run["trial"], "class": cls,
                           "bytes": run["data"].hex(), "cycles": nxt["cycles_prev"], "flags": nxt["flags_prev"],
                           "t_record": run["t"]}
                    if vcs is not None:
                        vb = bytes(vcs.get(j, b""))
                        vcls = classify(vb, golden, ("A", j) in vcs, args.end_newlines, args.crash)
                        rec["vcs_class"], rec["vcs_same_bytes"] = vcls, vb == run["data"]
                        same += (vcls == cls)
                    out.write(json.dumps(rec) + "\n")
                cyc = sum(runs[before + j]["cycles_prev"] for j in range(1, n + 1) if before + j < len(runs))
                wall = (runs[min(before + n, len(runs) - 1)]["t"] - runs[before]["t"]) if len(runs) > before else 0
                t_done = time.time()
                print(f"{path}: {n} trials {counts}; load {t_armed - t_load:.3f} s; run {cyc} cycles = "
                      f"{cyc / CLK_HZ:.3f} s at 12.5 MHz, {wall:.3f} s between the first and the last record"
                      + (f"; same class as VCS {same}/{n}" if vcs is not None else ""), flush=True)
                if prof is not None:
                    nent = sum(len(set(f)) for c, f in camp["trials"])
                    # the last trial ends with the record of the run after it (host timestamp)
                    t_last = runs[before + n]["t"] if before + n < len(runs) else None
                    step = {"campaign": path, "trials": n, "entries": nent, "pause_s": t_load - t_pause,
                            "fi_campaign_s": t_armed - t_load,
                            "armed_to_last_record_s": (t_last - t_armed) if t_last else None,
                            "armed_to_done_s": t_done - t_armed,
                            "onchip_s": cyc / CLK_HZ, **{k + "_us": v for k, v in prof.items()}}
                    print("  profile " + json.dumps(step), flush=True)
                out.flush()
        finally:
            out.close()
            ocd.close()
    finally:
        st.close()


if __name__ == "__main__":
    main()
