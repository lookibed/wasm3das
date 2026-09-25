#!/usr/bin/env python3
"""
The upstream benchmark (.upstream/tests/manual/run_fixtures.py) run inside
the EdenSpark editor.

Every check of docs/eden-port/bench_plan.json (fixture, export, args,
wasmtime baseline, exported from run_fixtures.py's table T) is sent to the
running editor as the cheat `wasm3_bench manual/<wasm> <func> <args>`, and
the line `WASM3 BENCH ... result=... load_ms=... call_ms=... total_ms=...`
is read back from the editor console. The fixtures must be installed
(scripts/eden/install_host.sh, fixtures.txt lists them under manual/) and
the game running.

Usage (from the repository): python3 scripts/eden/bench_editor.py [--filter substr] [--out file.md]
Exit 0 when every check with a baseline matches it.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
EDENMCP = os.path.join(HERE, "edenmcp")
LINE = re.compile(r"WASM3 BENCH (\S+) (\S+) result=(\S+) load_ms=([\d.e+-]+) call_ms=([\d.e+-]+) total_ms=([\d.e+-]+)")


def mcp(*args):
    r = subprocess.run([EDENMCP] + list(args), capture_output=True, text=True)
    return r.returncode, r.stdout


def run_one(wasm, func, args, timeout):
    mcp("get_logs")    # drop earlier lines
    cmd = {"cmd": "wasm3_bench", "arg1": "manual/" + wasm, "arg2": func}
    for i, a in enumerate(args):
        cmd["arg%d" % (i + 3)] = a
    mcp("exec_cheat", json.dumps(cmd))
    deadline = time.time() + timeout
    log = ""
    while time.time() < deadline:
        time.sleep(0.5)
        _, out = mcp("get_logs")
        if out.strip() and out.strip() != "No logs":
            log += out + "\n"
        for m in LINE.finditer(log):
            if m.group(1) == "manual/" + wasm and m.group(2) == func:
                return m.group(3), float(m.group(4)), float(m.group(5)), float(m.group(6))
    return "timeout", 0.0, 0.0, 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--timeout", type=float, default=300.0)
    ns = ap.parse_args()
    rc, status = mcp("get_game_status")
    if rc != 0 or not status.startswith("Running"):
        print("bench_editor: the game is not running in the editor: " + status.strip())
        return 2
    plan = json.load(open(os.path.join(REPO, "docs", "eden-port", "bench_plan.json")))
    rows = []
    bad = 0
    for t in plan:
        if ns.filter and ns.filter not in t["name"]:
            continue
        value, load_ms, call_ms, total_ms = run_one(t["wasm"], t["func"], t["args"], ns.timeout)
        base = t["baseline"]
        if base is None:
            match = "n/a"
        else:
            match = "ok" if value == str(base) else "MISMATCH"
            if match != "ok":
                bad += 1
        rows.append((t["name"], t["func"], " ".join(t["args"]), value, base, load_ms, call_ms, total_ms, match))
        print("%-34s %14s  load %8.1f ms  call %10.1f ms  %s" % (t["name"], value, load_ms, call_ms, match), flush=True)
    tl = sum(r[5] for r in rows)
    tc = sum(r[6] for r in rows)
    print("total: %d checks, load %.1f s, call %.1f s, baseline mismatches %d" % (len(rows), tl / 1000.0, tc / 1000.0, bad))
    if ns.out:
        with open(ns.out, "w", encoding="utf-8") as f:
            f.write("| test | export | args | result | baseline | load ms | call ms | total ms | match |\n")
            f.write("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |\n")
            for r in rows:
                f.write("| %s | %s | %s | %s | %s | %.1f | %.1f | %.1f | %s |\n" % r)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
