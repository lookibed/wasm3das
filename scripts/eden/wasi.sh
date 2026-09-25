#!/usr/bin/env bash
# Gate 6b of the Eden port: the WASI test set through the Eden port's
# command-line front end, driven by the unmodified
# wasm3c/test/run-wasi-test.py (layout as docs/test-suites.md, in
# tmp/eden/.wasi).
#
# Usage: scripts/eden/wasi.sh [--fast] [--timeout <s>]
#   --fast   the 7-test fast list (the gate's choice); without it the full
#            12-test run, which takes over an hour on the pointer port
# Exit: 0 when every test of the run passes.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

fast=""
timeout_s=900
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) fast="--fast" ;;
        --timeout) timeout_s="$2"; shift ;;
        *) echo "wasi: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

run="$repo/tmp/eden/.wasi/run"
mkdir -p "$run"
ln -sfn "$repo/wasm3c/test/run-wasi-test.py" "$run/run-wasi-test.py"
ln -sfn "$repo/wasm3c/extra" "$repo/tmp/eden/.wasi/extra"
ln -sfn "$repo/wasm3c/test/wasi" "$run/wasi"
ln -sfn "$repo/wasm3c/test/self-hosting" "$run/self-hosting"
cd "$run"
banner "wasi: run-wasi-test.py ${fast:-(full)}"
set +e
python3 -u ./run-wasi-test.py --exec "$repo/scripts/eden/wasm3" $fast --timeout "$timeout_s" 2>&1 | tee "$repo/tmp/eden/.wasi/last.log" | tail -30
r=${PIPESTATUS[0]}
set -e
line=$(grep -iE 'passed|fail' "$repo/tmp/eden/.wasi/last.log" | tail -1)
echo "wasi: $line"
failed=$(grep -ciE '^\s*(FAIL|failed)' "$repo/tmp/eden/.wasi/last.log" || true)
if [[ $r == 0 && "${failed:-0}" == 0 ]]; then
    echo "wasi: OK"
    exit 0
fi
echo "wasi: FAILED (driver exit $r, $failed failure line(s))"
exit 1
