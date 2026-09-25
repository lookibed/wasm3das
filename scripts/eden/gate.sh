#!/usr/bin/env bash
# The verification gate of the Eden port: what a module must pass before its
# STATE.json status becomes "done", and what the goal condition re-runs.
#
# Stages, in order (docs/eden-port/DESIGN.md 5.3):
#   compile   scripts/eden/compile.sh   every file, every local compiler, sandbox rules
#   coverage  scripts/eden/coverage.sh  every upstream test has an Eden counterpart
#   test      scripts/eden/test.sh      the local runner: fail=0
#   host      scripts/eden/install_host.sh --check   the installed host is current
#   eden      scripts/eden/eden_gate.sh the editor compiles and its run agrees with the local one
#   spec      scripts/eden/spec.sh      (only when STATE says module "app" is verify/done)
#   wasi      scripts/eden/wasi.sh --fast (same condition)
#
# Usage: scripts/eden/gate.sh [stage ...]      default: every applicable stage
#        scripts/eden/gate.sh --local          compile coverage test (no editor)
# Exit: 0 when every stage run is green. The first failing stage stops the run.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

stages=("$@")
if [[ ${#stages[@]} == 1 && "${stages[0]}" == "--local" ]]; then
    stages=(compile coverage test)
fi
if [[ ${#stages[@]} == 0 ]]; then
    stages=(compile coverage test host eden)
    app_status=$(state_get "[m for m in s['modules'] if m['name']=='app'][0]['status']")
    if [[ "$app_status" == "verify" || "$app_status" == "done" ]]; then
        stages+=(spec wasi)
    fi
fi

start=$SECONDS
for st in "${stages[@]}"; do
    case "$st" in
        compile)  "$repo/scripts/eden/compile.sh" ;;
        coverage) "$repo/scripts/eden/coverage.sh" ;;
        test)     "$repo/scripts/eden/test.sh" ;;
        host)     banner "host: installed host is current"; "$repo/scripts/eden/install_host.sh" --check ;;
        eden)     "$repo/scripts/eden/eden_gate.sh" ;;
        spec)     "$repo/scripts/eden/spec.sh" ;;
        wasi)     "$repo/scripts/eden/wasi.sh" --fast ;;
        *) echo "gate: unknown stage $st" >&2; exit 2 ;;
    esac || { echo; echo "gate: FAILED at stage '$st' after $((SECONDS - start))s"; exit 1; }
done
echo
echo "gate: GREEN (${stages[*]}) in $((SECONDS - start))s"
