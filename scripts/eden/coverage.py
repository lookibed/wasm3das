#!/usr/bin/env python3
"""
Gate 2 of the Eden port: every upstream test has an Eden counterpart.

For each module whose STATE.json status is "porting", "verify" or "done", the upstream
test file .upstream/tests/integration/<upstream_tests> is read and every
`[test] def test_x` in it must appear in tests/eden/<eden_tests> either as

    def test_x(

or as a header line

    // dropped: test_x -- <reason>

The reason must name a capability the editor sandbox lacks (file system,
unsafe, macros, threads, network, the spec corpus); the words "hard",
"complex", "later" or "todo" in a reason fail the check.

Also checks that tests/eden/all_tests.das requires the module's test file and
lists @@run_tests_<module> in all_test_modules(), and that the test file
defines run_tests_<module>.

Usage: coverage.py <repo> [module ...]   (default: every done/verify module)
Exit: 0 when everything is covered.
"""
import json
import os
import re
import sys

WEAK_REASONS = re.compile(r"\b(hard|complex|complicated|later|todo|tbd|skip for now)\b", re.I)


def main(argv):
    repo = argv[0]
    state = json.load(open(os.path.join(repo, "docs", "eden-port", "STATE.json")))
    wanted = argv[1:]
    # every module that has work in the tree is checked: porting, verify, done
    # (a module still in porting whose test file is missing fails loudly, which
    # is the point when gate.sh runs during a verification)
    modules = [m for m in state["modules"] if (not wanted and m["status"] in ("porting", "verify", "done")) or m["name"] in wanted]
    all_tests = open(os.path.join(repo, "tests", "eden", "all_tests.das")).read()
    failures = 0
    checked = 0
    for m in modules:
        name = m["name"]
        eden_tests = m.get("eden_tests")
        if not eden_tests:
            print("coverage: %-18s no tests expected (%s)" % (name, m.get("note", "")))
            continue
        eden_path = os.path.join(repo, "tests", "eden", eden_tests)
        if not os.path.exists(eden_path):
            print("coverage: %-18s FAIL missing %s" % (name, eden_tests))
            failures += 1
            continue
        eden_src = open(eden_path).read()
        defined = set(re.findall(r"^\s*def\s+(?:public\s+)?(test_\w+)\s*\(", eden_src, re.M))
        dropped = dict(re.findall(r"^\s*//\s*dropped:\s*(test_\w+)\s*--\s*(.*)$", eden_src, re.M))
        upstream_names = []
        for up in m.get("upstream_tests", []):
            up_path = os.path.join(repo, ".upstream", "tests", "integration", up)
            if not os.path.exists(up_path):
                print("coverage: %-18s FAIL upstream file missing %s" % (name, up))
                failures += 1
                continue
            up_src = open(up_path).read()
            upstream_names += re.findall(r"^\[test\]\s*\n\s*def\s+(test_\w+)", up_src, re.M)
        missing = []
        weak = []
        for t in upstream_names:
            if t in defined:
                continue
            if t in dropped:
                if WEAK_REASONS.search(dropped[t]) or len(dropped[t].strip()) < 12:
                    weak.append((t, dropped[t]))
                continue
            missing.append(t)
        runner = "run_tests_%s" % name
        problems = []
        if ("def public %s(" % runner) not in eden_src and ("def %s(" % runner) not in eden_src:
            problems.append("no %s in %s" % (runner, eden_tests))
        req = "require modules/wasm3das/tests/eden/%s" % eden_tests[:-4]
        if not re.search(r"^\s*" + re.escape(req) + r"\s*$", all_tests, re.M):
            problems.append("all_tests.das lacks `%s`" % req)
        if not re.search(r"^\s*push\(mods, @@%s\)" % runner, all_tests, re.M):
            problems.append("all_tests.das all_test_modules() does not list @@%s" % runner)
        checked += len(upstream_names)
        if missing or weak or problems:
            failures += 1
            print("coverage: %-18s FAIL" % name)
            for t in missing:
                print("    missing counterpart of upstream %s (define it or add `// dropped: %s -- <reason>`)" % (t, t))
            for t, r in weak:
                print("    weak drop reason for %s: %r" % (t, r))
            for p in problems:
                print("    " + p)
        else:
            print("coverage: %-18s ok  (%d upstream tests: %d ported, %d dropped)" % (
                name, len(upstream_names), len([t for t in upstream_names if t in defined]), len([t for t in upstream_names if t in dropped])))
    print("coverage: %s (%d upstream tests checked)" % ("OK" if failures == 0 else "FAILED", checked))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
