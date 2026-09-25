#!/usr/bin/env bash
# Gate 3 of the Eden port: the Eden test modules pass locally.
#
# Runs .local/run_tests.das (fixtures read with fio) under the sandbox project
# with the 0.6.3 build when present, else the 0.6.4 pin. The summary line
# "WASM3 TESTS pass=N fail=M" is the contract; the pass count is written to
# tmp/eden/last_local_pass so scripts/eden/eden_gate.sh can compare the
# editor's run with it.
#
# Usage: scripts/eden/test.sh [--verbose] [--both]
#   --both  run with every available compiler, not only the first
# Exit: 0 when fail=0 with every compiler used.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

verbose=""
both=0
for a in "$@"; do
    case "$a" in
        --verbose) verbose="--verbose" ;;
        --both) both=1 ;;
        *) echo "test: unknown argument $a" >&2; exit 2 ;;
    esac
done

cd "$eden_root"
mkdir -p "$repo/tmp/eden"
rc=0
first=1
for bin in $(compilers); do
    banner "test: $bin ($("$bin" --version 2>/dev/null | head -1))"
    set +e
    out=$(das_sandbox "$bin" "$repo/.local/run_tests.das" -- $verbose 2>&1)
    r=$?
    set -e
    echo "$out" | grep -vE 'atexit'
    summary=$(echo "$out" | grep -E '^WASM3 TESTS pass=' | tail -1)
    if [[ -z "$summary" ]]; then
        echo "test: no summary line (runner crashed or did not compile)"
        rc=1
    else
        pass=$(echo "$summary" | sed -E 's/.*pass=([0-9]+).*/\1/')
        failc=$(echo "$summary" | sed -E 's/.*fail=([0-9]+).*/\1/')
        if [[ $first == 1 ]]; then
            echo "$pass" > "$repo/tmp/eden/last_local_pass"
        fi
        if [[ "$failc" != 0 || $r != 0 ]]; then
            rc=1
        fi
    fi
    first=0
    [[ $both == 1 ]] || break
done
if [[ $rc == 0 ]]; then echo "test: OK"; else echo "test: FAILED"; fi
exit $rc
