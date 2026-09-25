#!/usr/bin/env bash
# The goal condition of an ABI case, for `/goal` and for humans:
#
#   scripts/abi/goal_check.sh <case> exits 0
#
# means: every item of the case in docs/eden-abi/STATE.json is "done" (items
# the owner deferred carry "deferred": true and do not count), the working
# tree is committed, and scripts/abi/gate.sh is green.
#
# Usage: scripts/abi/goal_check.sh <case> [--quick]
#   --quick  ledger and git only, no gate (a progress report)
set -uo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
case_name="${1:-}"
quick=0
[[ "${2:-}" == "--quick" ]] && quick=1
if [[ -z "$case_name" ]]; then
    echo "usage: scripts/abi/goal_check.sh <case> [--quick]" >&2
    exit 2
fi

cd "$repo"
missing=0

echo "==== goal: ledger ($case_name) ===="
python3 - "$repo/docs/eden-abi/STATE.json" "$case_name" <<'EOF' || missing=1
import json, sys
s = json.load(open(sys.argv[1]))
case = next((c for c in s["cases"] if c["name"] == sys.argv[2]), None)
if case is None:
    print("goal: no case %s in STATE.json (cases: %s)" % (sys.argv[2], ", ".join(c["name"] for c in s["cases"])))
    sys.exit(1)
open_items = []
for it in case["items"]:
    tag = " (deferred)" if it.get("deferred") else ""
    print("  %-60s %s%s" % (it["name"][:60], it["status"], tag))
    if it["status"] != "done" and not it.get("deferred"):
        open_items.append(it["name"])
if open_items:
    print("goal: open items: " + "; ".join(open_items))
    sys.exit(1)
EOF

echo "==== goal: git ===="
if [[ -n "$(git status --porcelain)" ]]; then
    echo "goal: uncommitted changes:"
    git status --short | head -20
    missing=1
else
    echo "clean"
fi

if [[ $quick == 0 ]]; then
    echo "==== goal: gate ===="
    scripts/abi/gate.sh || missing=1
fi

if [[ $missing == 0 ]]; then
    echo "goal: REACHED ($case_name)"
    exit 0
fi
echo "goal: not reached ($case_name)"
exit 1
