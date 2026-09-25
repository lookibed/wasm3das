#!/usr/bin/env bash
# Gate 6a of the Eden port: the WebAssembly core spec suite through the Eden
# port's command-line front end, driven by the unmodified
# wasm3c/test/run-spec-test.py (the same layout docs/test-suites.md uses for
# the pointer port, in tmp/eden/.spec instead of tmp/spec).
#
# The driver downloads the corpus (opam-1.1.1 by default) on first use into
# its working directory; network is needed once.
#
# Usage: scripts/eden/spec.sh [--timeout <s>] [driver args, e.g. .spec-opam-1.1.1/core/i32.json]
# Exit: 0 when the driver reports fail=0 crash=0 and pass equals
#       STATE.json spec_expected.pass (when no driver args narrow the run).
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

timeout_s=120
extra=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) timeout_s="$2"; shift ;;
        *) extra+=("$1") ;;
    esac
    shift
done

run="$repo/tmp/eden/.spec/run"
mkdir -p "$run"
ln -sfn "$repo/wasm3c/test/run-spec-test.py" "$run/run-spec-test.py"
ln -sfn "$repo/wasm3c/extra" "$repo/tmp/eden/.spec/extra"
# the driver splits --exec on spaces and the repository path has spaces:
# the front end is reached through a symlink in the run directory
ln -sfn "$repo/scripts/eden/wasm3" "$run/wasm3"
cd "$run"
banner "spec: run-spec-test.py (${extra[*]:-default list})"
set +e
python3 ./run-spec-test.py --exec "./wasm3 --repl" --timeout "$timeout_s" "${extra[@]}" 2>&1 | tee "$repo/tmp/eden/.spec/last.log" | tail -25
r=${PIPESTATUS[0]}
set -e
# the driver's summary is a pprint'ed dict: {'crashed': C, 'failed': F,
# 'missing': M, 'skipped': S, 'success': P, 'timeout': T, 'total_run': N}
stat() {
    grep -oE "'$1': [0-9]+" "$repo/tmp/eden/.spec/last.log" | grep -oE '[0-9]+' | tail -1 || true
}
pass=$(stat success)
failc=$(stat failed)
crash=$(stat crashed)
tmo=$(stat timeout)
# (a crash or a timeout is counted in 'failed' as well)
echo "spec: pass=${pass:-?} fail=${failc:-?} crash=${crash:-?} timeout=${tmo:-?} total=$(stat total_run)"
rc=0
[[ -n "$pass" ]] || { echo "spec: no result line (driver failed, exit $r)"; exit 1; }
[[ "${failc:-0}" == 0 && "${crash:-0}" == 0 ]] || rc=1
if [[ ${#extra[@]} == 0 ]]; then
    want=$(state_get "s['spec_expected']['pass']")
    if [[ "$pass" != "$want" ]]; then
        echo "spec: passed $pass, expected $want"
        rc=1
    fi
fi
if [[ $rc == 0 ]]; then echo "spec: OK"; else echo "spec: FAILED"; fi
exit $rc
