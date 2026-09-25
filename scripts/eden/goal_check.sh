#!/usr/bin/env bash
# The goal condition of the Eden port, for `/goal` and for humans:
#
#   scripts/eden/goal_check.sh exits 0
#
# means: every module of docs/eden-port/STATE.json is "done", the working
# tree is committed, and scripts/eden/gate.sh is green including the spec
# and WASI suites. Anything else prints what is missing and exits 1.
#
# Usage: scripts/eden/goal_check.sh [--quick]
#   --quick  only the ledger and git checks, no gate run (a progress report)
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

quick=0
[[ "${1:-}" == "--quick" ]] && quick=1

banner "goal: ledger"
python3 - "$STATE" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
by = {}
for m in s["modules"]:
    by.setdefault(m["status"], []).append(m["name"])
    print("  %-16s %s" % (m["name"], m["status"]))
print("summary: " + ", ".join("%s=%d" % (k, len(v)) for k, v in sorted(by.items())))
EOF
not_done=$(state_get "[m['name'] for m in s['modules'] if m['status'] != 'done']")
missing=0
if [[ "$not_done" != "[]" ]]; then
    echo "goal: modules not done: $not_done"
    missing=1
fi

banner "goal: git"
cd "$repo"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "goal: uncommitted changes in the repository:"
    git status --short | head -20
    missing=1
else
    echo "clean: $(git rev-parse --abbrev-ref HEAD) @ $(git log -1 --format='%h %s')"
fi

if [[ $quick == 1 ]]; then
    [[ $missing == 0 ]] && echo "goal: ledger complete (gate not run, --quick)" || echo "goal: NOT reached"
    exit $missing
fi
if [[ $missing == 1 ]]; then
    echo "goal: NOT reached (ledger incomplete); the gate is not run"
    exit 1
fi

"$repo/scripts/eden/gate.sh" compile coverage test host eden spec wasi || { echo "goal: NOT reached (gate)"; exit 1; }
echo
echo "goal: REACHED - wasm3das runs in the Eden editor, every module done, tests green locally and in the editor, spec and WASI suites green"
