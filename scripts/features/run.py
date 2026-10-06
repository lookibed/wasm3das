#!/usr/bin/env python3
"""Runs the WebAssembly test suite against the Eden port, per feature group.

docs/wasm-features/PLAN.md: the corpus is the pinned WebAssembly/testsuite
converted by scripts/features/corpus.sh; this driver plays every command of
every file through the port's command-line front end (scripts/eden/wasm3
--repl, the REPL of .local/app/wasm3_eden.das) and classifies it:

  pass         the port did what the specification requires
  fail         it did not (wrong value, wrong or missing trap, a module that
               loads although invalid, a crash or a timeout)
  unsupported  the command needs something the pipeline or the port does
               not have yet; the reason names the phase that adds it
  skip         not the runtime's business (text-format modules of
               assert_malformed / *_custom: the port reads binaries only)

The process protocol and the result format follow wasm3c/test/run-spec-test.py
(the upstream driver the opam gate runs unmodified): one process per test
file, `:init` + `:load-hex` per module, `:invoke <field> <args>` with the
values as unsigned decimal bits, "Result: <bits>:<type>, ..." back, traps as
"Error: [trap] <text> (...)".

Usage: scripts/features/run.py [--group G]... [--file PATH]... [--jobs N]
                                [--timeout S] [--out results.json] [--show F]
Exit: 0 always (the numbers are the result); 2 on a pipeline error.
"""
import argparse
import json
import math
import os
import queue
import struct
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STATE = os.path.join(REPO, "docs", "wasm-features", "STATE.json")
WASM3 = os.path.join(REPO, "scripts", "eden", "wasm3")

SCALAR = {"i32": 32, "i64": 64, "f32": 32, "f64": 64}

# the specification's trap texts the port spells differently (as in
# run-spec-test.py's trapmap)
TRAP_MAP = {"unreachable": "unreachable executed"}


# ---------------------------------------------------------------- process

class Wasm3:
    """The REPL of the front end, one process (run-spec-test.py's Wasm3)."""

    def __init__(self, timeout):
        self.timeout = timeout
        self.p = None
        self.start()

    def start(self):
        self.p = subprocess.Popen([WASM3, "--repl"], bufsize=0, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.q = queue.Queue()

        def pump(out, q):
            for data in iter(lambda: out.read(4096), b""):
                q.put(data)
            q.put(None)

        threading.Thread(target=pump, args=(self.p.stdout, self.q), daemon=True).start()
        self.read_until("wasm3> ")

    def alive(self):
        return self.p is not None and self.p.poll() is None

    def stop(self):
        if self.p is not None:
            try:
                self.p.stdin.close()
            except OSError:
                pass
            self.p.kill()
            self.p.wait()
            self.p = None

    def read_until(self, token):
        buf = b""
        deadline = time.time() + self.timeout
        while time.time() < deadline:
            try:
                data = self.q.get(timeout=0.1)
            except queue.Empty:
                continue
            if data is None:
                self.stop()
                raise RuntimeError("Crashed")
            buf += data
            idx = buf.rfind(token.encode())
            if idx >= 0:
                return buf[:idx].decode("utf-8", "replace").strip()
        self.stop()
        raise RuntimeError("Timeout")

    def cmd(self, text):
        if not self.alive():
            self.start()
        while not self.q.empty():
            self.q.get()
        self.p.stdin.write(text.encode("utf-8"))
        self.p.stdin.flush()
        return self.read_until("wasm3> ")

    def load(self, path):
        with open(path, "rb") as f:
            wasm = f.read()
        self.cmd(":init\n")
        return self.cmd(f":load-hex {len(wasm)}\n{wasm.hex()}\n")

    def compile(self):
        return self.cmd(":compile\n")


# ---------------------------------------------------------------- values

def bits(value, t):
    """an argument or expected scalar as unsigned decimal bits"""
    n = int(value)
    return n & ((1 << SCALAR[t]) - 1)


def is_nan(b, t):
    if t == "f32":
        return (b & 0x7f800000) == 0x7f800000 and (b & 0x007fffff) != 0
    return (b & 0x7ff0000000000000) == 0x7ff0000000000000 and (b & 0x000fffffffffffff) != 0


def nan_matches(b, t, kind):
    if not is_nan(b, t):
        return False
    if kind == "nan:canonical":
        mag = b & (0x7fffffff if t == "f32" else 0x7fffffffffffffff)
        return mag == (0x7fc00000 if t == "f32" else 0x7ff8000000000000)
    # nan:arithmetic: the quiet bit set
    return (b & (0x00400000 if t == "f32" else 0x0008000000000000)) != 0


def unsupported_value(v):
    t = v["type"]
    if t == "v128":
        return "v128 values (F6 simd)"
    if t in ("funcref", "externref", "nullfuncref", "nullexternref"):
        return "reference values (F3 reference-types)"
    if t in ("exnref", "nullexnref"):
        return "exnref values (F8 exceptions)"
    if t == "either":
        return "either-of results (F6 relaxed results)"
    if t not in SCALAR:
        return f"{t} values (F11 gc)"
    return None


def parse_results(output):
    """the last 'Result:' line as [(bits, type)]; None without one"""
    lines = [l for l in output.splitlines() if l.startswith("Result: ")]
    if not lines:
        return None
    text = lines[-1][len("Result: "):].strip()
    if text == "<Empty Stack>":
        return []
    out = []
    for part in text.split(", "):
        v, t = part.rsplit(":", 1)
        out.append((int(v), t))
    return out


def parse_error(output):
    """('trap', text) or ('error', text) of an 'Error:' line, else None"""
    for line in output.splitlines():
        if line.startswith("Error: [trap] "):
            rest = line[len("Error: [trap] "):]
            return ("trap", rest.rsplit(" (", 1)[0] if " (" in rest else rest)
        if line.startswith("Error: "):
            return ("error", line[len("Error: "):])
    return None


# ---------------------------------------------------------------- one file

def run_file(entry, json_root, timeout):
    path = entry["path"]
    group = entry["group"]
    jfile = os.path.join(json_root, path, os.path.basename(path) + ".json")
    results = []

    def record(c, outcome, reason=""):
        results.append({"line": c.get("line", 0), "type": c["type"], "outcome": outcome, "reason": reason})

    if not os.path.isfile(jfile):
        return {"path": path, "group": group, "results": [], "missing": True}
    data = json.load(open(jfile, encoding="utf-8"))
    base = os.path.dirname(jfile)
    w = None
    current = None          # (name or None, filename) of the module the actions run in
    current_ok = False
    try:
        w = Wasm3(timeout)
        for c in data["commands"]:
            t = c["type"]
            if t == "module":
                if c.get("module_type") != "binary":
                    record(c, "skip", "text module")
                    current, current_ok = None, False
                    continue
                try:
                    out = w.load(os.path.join(base, c["filename"]))
                    err = parse_error(out)
                except RuntimeError as e:
                    err = ("error", str(e))
                current = (c.get("name"), c["filename"])
                current_ok = err is None
                record(c, "pass" if current_ok else "fail", "" if current_ok else f"load: {err[1]}")
            elif t in ("module_definition", "module_instance"):
                record(c, "unsupported", "module definitions and instances (F1 linking)")
            elif t == "register":
                record(c, "unsupported", "register (F1 linking)")
            elif t in ("assert_invalid", "assert_malformed", "assert_unlinkable", "assert_uninstantiable",
                       "assert_invalid_custom", "assert_malformed_custom"):
                if c.get("module_type") != "binary":
                    record(c, "skip", "text module")
                    continue
                try:
                    out = w.load(os.path.join(base, c["filename"]))
                    err = parse_error(out)
                    if err is None:
                        err = parse_error(w.compile())
                except RuntimeError as e:
                    err = ("error", str(e))
                current, current_ok = None, False
                if err is not None:
                    record(c, "pass")
                elif t in ("assert_invalid", "assert_invalid_custom"):
                    record(c, "fail", f"accepted an invalid module ({c.get('text', '')}) (V validation)")
                elif t == "assert_unlinkable":
                    record(c, "fail", f"linked ({c.get('text', '')}) (F1 linking)")
                else:
                    record(c, "fail", f"accepted ({c.get('text', '')})")
            elif t in ("action", "assert_return", "assert_trap", "assert_exhaustion", "assert_exception"):
                a = c["action"]
                if t == "assert_exception":
                    record(c, "unsupported", "assert_exception (F8 exceptions)")
                    continue
                if a["type"] != "invoke":
                    record(c, "unsupported", f"{a['type']} actions (F1 linking: :get-global by module)")
                    continue
                if a.get("module") is not None and (current is None or a["module"] != current[0]):
                    record(c, "unsupported", "action on a named module (F1 linking)")
                    continue
                if not current_ok:
                    record(c, "fail", "the module did not load")
                    continue
                vals = list(a.get("args", [])) + list(c.get("expected", []))
                reason = next((r for r in (unsupported_value(v) for v in vals) if r), None)
                if reason:
                    record(c, "unsupported", reason)
                    continue
                field = a["field"]
                if field == "":
                    arg_field = r"\x00"
                elif all(ord(ch) < 128 and ch.isprintable() and ch not in " \n\r\t\\" for ch in field):
                    arg_field = field
                else:
                    arg_field = "\\x" + "\\x".join("{0:02x}".format(x) for x in field.encode("utf-8"))
                args = " ".join(str(bits(v["value"], v["type"])) for v in a.get("args", []))
                try:
                    out = w.cmd(f":invoke {arg_field} {args}\n".replace("  ", " "))
                except RuntimeError as e:
                    record(c, "fail", str(e))
                    current_ok = False
                    w = Wasm3(timeout)
                    if current is not None:
                        try:
                            current_ok = parse_error(w.load(os.path.join(base, current[1]))) is None
                        except RuntimeError:
                            current_ok = False
                    continue
                got = parse_results(out)
                err = parse_error(out)
                if t == "action":
                    record(c, "pass" if got is not None or err is None else "fail", "" if got is not None or err is None else err[1])
                elif t == "assert_return":
                    want = c.get("expected", [])
                    if got is None:
                        record(c, "fail", f"no result ({err[1] if err else 'nothing'})")
                    elif len(got) != len(want):
                        record(c, "fail", f"{len(got)} results, want {len(want)}")
                    else:
                        ok = True
                        for (gb, gt), wv in zip(got, want):
                            if gt != wv["type"]:
                                ok = False
                            elif str(wv["value"]).startswith("nan:"):
                                ok = ok and nan_matches(gb, gt, wv["value"])
                            else:
                                ok = ok and gb == bits(wv["value"], wv["type"])
                        record(c, "pass" if ok else "fail", "" if ok else f"got {got}, want {[(w_['type'], w_['value']) for w_ in want]}")
                else:
                    want_text = TRAP_MAP.get(c.get("text", ""), c.get("text", ""))
                    if err is not None and err[0] == "trap":
                        if t == "assert_exhaustion" or err[1] == want_text:
                            record(c, "pass")
                        else:
                            record(c, "fail", f"trap '{err[1]}', want '{want_text}'")
                    elif err is not None and t == "assert_exhaustion":
                        record(c, "pass")
                    else:
                        record(c, "fail", f"no trap ({err[1] if err else 'returned'}), want '{want_text}'")
            else:
                record(c, "unsupported", f"command {t}")
    except RuntimeError as e:
        results.append({"line": 0, "type": "driver", "outcome": "fail", "reason": str(e)})
    finally:
        if w is not None:
            w.stop()
    return {"path": path, "group": group, "results": results}


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", action="append", default=[])
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--out", default="")
    ap.add_argument("--show", default="", help="print the failures of this group (or 'all')")
    ap.add_argument("--check", action="store_true", help="exit 1 when a command of docs/wasm-features/passing.json no longer passes")
    ap.add_argument("--update", action="store_true", help="write the passing commands of the files run into passing.json")
    a = ap.parse_args()

    st = json.load(open(STATE))
    corpus = os.environ.get("WASM3DAS_CORPUS", "/root/.cache/wasm3das")
    json_root = os.path.join(corpus, "json", st["corpus"]["commit"])
    index_path = os.path.join(json_root, "index.json")
    if not os.path.isfile(index_path):
        print(f"run: no corpus at {json_root}; run scripts/features/corpus.sh", file=sys.stderr)
        sys.exit(2)
    files = json.load(open(index_path))["files"]
    unconverted = {u["path"]: u for u in st["corpus"].get("unconverted", [])}
    if a.group:
        files = [f for f in files if f["group"] in a.group]
    if a.file:
        files = [f for f in files if f["path"] in a.file]

    t0 = time.time()
    done = []
    todo = [f for f in files if f["path"] not in unconverted]
    with ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for r in ex.map(lambda f: run_file(f, json_root, a.timeout), todo):
            done.append(r)
            print(f"run: {len(done)}/{len(todo)} {r['path']}", file=sys.stderr, flush=True)

    summary = {}
    for r in done:
        s = summary.setdefault(r["group"], {"files": 0, "pass": 0, "fail": 0, "unsupported": 0, "skip": 0, "reasons": {}})
        s["files"] += 1
        for x in r["results"]:
            s[x["outcome"]] += 1
            if x["outcome"] in ("fail", "unsupported") and x["reason"]:
                key = x["reason"] if x["outcome"] == "unsupported" else x["reason"].split(" (")[0][:60]
                k = f"{x['outcome']}: {key}"
                s["reasons"][k] = s["reasons"].get(k, 0) + 1
    for path, u in unconverted.items():
        if not a.file or path in a.file:
            g = next((f["group"] for f in json.load(open(index_path))["files"] if f["path"] == path), "?")
            if not a.group or g in a.group:
                summary.setdefault(g, {"files": 0, "pass": 0, "fail": 0, "unsupported": 0, "skip": 0, "reasons": {}})
                summary[g]["reasons"][f"not converted: {path} ({u['phase']})"] = 1

    print(f"run: {len(todo)} files in {time.time() - t0:.0f} s")
    print(f"{'group':24} {'files':>5} {'pass':>7} {'fail':>7} {'unsupp':>7} {'skip':>6}  pass%")
    tot = {"files": 0, "pass": 0, "fail": 0, "unsupported": 0, "skip": 0}
    for g in sorted(summary):
        s = summary[g]
        for k in tot:
            tot[k] += s[k]
        run_n = s["pass"] + s["fail"] + s["unsupported"]
        print(f"{g:24} {s['files']:>5} {s['pass']:>7} {s['fail']:>7} {s['unsupported']:>7} {s['skip']:>6}  {100.0 * s['pass'] / max(run_n, 1):5.1f}")
    run_n = tot["pass"] + tot["fail"] + tot["unsupported"]
    print(f"{'total':24} {tot['files']:>5} {tot['pass']:>7} {tot['fail']:>7} {tot['unsupported']:>7} {tot['skip']:>6}  {100.0 * tot['pass'] / max(run_n, 1):5.1f}")
    for g in sorted(summary):
        if a.show and (a.show == "all" or a.show == g):
            print(f"\n== {g}")
            for k, n in sorted(summary[g]["reasons"].items(), key=lambda kv: -kv[1])[:40]:
                print(f"{n:>7}  {k}")

    if a.out:
        json.dump({"commit": st["corpus"]["commit"], "summary": summary, "files": done}, open(a.out, "w"), indent=1)

    # the per-command baseline: for every file the "line:type" keys that pass
    passing_path = os.path.join(REPO, "docs", "wasm-features", "passing.json")
    now = {r["path"]: sorted({f"{x['line']}:{x['type']}" for x in r["results"] if x["outcome"] == "pass"}) for r in done}
    rc = 0
    if a.check:
        old = json.load(open(passing_path))["files"] if os.path.isfile(passing_path) else {}
        lost = 0
        for path, keys in old.items():
            if path not in now:
                continue
            gone = sorted(set(keys) - set(now[path]))
            for k in gone:
                print(f"REGRESSION {path}:{k}")
            lost += len(gone)
        print(f"run: {lost} regressions against passing.json")
        rc = 1 if lost else 0
    if a.update:
        old = json.load(open(passing_path))["files"] if os.path.isfile(passing_path) else {}
        old.update(now)
        json.dump({"_doc": "Commands of the pinned corpus that pass (scripts/features/run.py --update); "
                           "--check fails when one of them stops passing. Keys are line:type.",
                   "commit": st["corpus"]["commit"], "files": dict(sorted(old.items()))},
                  open(passing_path, "w"), indent=0, separators=(",", ":"))
        print(f"run: passing.json updated ({sum(len(v) for v in old.values())} commands)")
    sys.exit(rc)


if __name__ == "__main__":
    main()
