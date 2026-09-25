#!/usr/bin/env bash
# Gate 4 of the Eden port: the editor itself compiles the project and runs
# the Eden test suite.
#
# Talks to the running editor through scripts/eden/edenmcp (the MCP client on
# the Windows side). Steps:
#   1. restart the game (a full stop + start, so hot-reload state is not
#      trusted) and wait until get_game_status says Running; a status with
#      "compilation failed" or "internal error" fails the gate and is printed
#   2. run the cheat wasm3_tests and collect the console log until the line
#      "WASM3 TESTS pass=N fail=M" appears (get_logs clears the buffer, so
#      lines are accumulated here)
#   3. fail when M != 0, or when N differs from the local run recorded by
#      scripts/eden/test.sh (tmp/eden/last_local_pass) unless --no-compare
#
# Usage: scripts/eden/eden_gate.sh [--no-compare] [--timeout <s>]
# Exit: 0 = green; 1 = compile or test failure; 2 = editor unreachable.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

compare=1
timeout_s=180
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-compare) compare=0 ;;
        --timeout) timeout_s="$2"; shift ;;
        *) echo "eden_gate: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

mcp() { "$EDENMCP" "$@"; }

banner "eden_gate: editor status"
if ! status=$(mcp get_game_status 2>&1); then
    echo "eden_gate: editor not reachable: $status"
    echo "eden_gate: start the Eden editor from the launcher with this project open, then retry"
    exit 2
fi
echo "before: $status"

banner "eden_gate: full restart (stop + start)"
# The first compile after new files appeared in the project tree sometimes
# ends in a bare "internal error" although every file is fine on the second
# attempt (the editor's file scan lags one cycle); one retry covers that.
attempt=0
status=""
while true; do
    attempt=$((attempt + 1))
    mcp game_play '{"play": false}' >/dev/null || true
    sleep 1
    mcp get_logs >/dev/null || true       # drop stale lines
    start_out=$(mcp game_play '{"play": true}' 2>&1 || true)
    echo "$start_out"
    deadline=$((SECONDS + timeout_s))
    status=""
    while (( SECONDS < deadline )); do
        status=$(mcp get_game_status 2>&1 || true)
        case "$status" in
            *"compilation failed"*|*"internal error"*|Running*) break ;;
        esac
        sleep 1
    done
    case "$status" in
        *"internal error"*)
            if (( attempt < 2 )); then
                echo "eden_gate: 'internal error' on attempt $attempt, retrying once after a rescan pause"
                sleep 3
                continue
            fi ;;
    esac
    break
done
case "$status" in
    *"compilation failed"*|*"internal error"*)
        echo "eden_gate: COMPILE FAILED in the editor:"
        echo "$status" | sed 's/^/    /'
        echo "eden_gate: hint: the editor reports one error; with several broken files it says only 'internal error' (bisect with scripts/eden/compile.sh)"
        exit 1 ;;
esac
case "$status" in
    Running*) echo "status: $status" ;;
    *) echo "eden_gate: the game did not reach Running within ${timeout_s}s: $status"; exit 1 ;;
esac

banner "eden_gate: running cheat wasm3_tests"
sleep 2      # let request_text of the fixtures settle after the start
mcp exec_cheat '{"cmd": "wasm3_tests"}' >/dev/null
log=""
summary=""
deadline=$((SECONDS + timeout_s))
while (( SECONDS < deadline )); do
    sleep 1
    chunk=$(mcp get_logs 2>/dev/null || true)
    if [[ -n "$chunk" && "$chunk" != "No logs" ]]; then
        log+="$chunk"$'\n'
    fi
    summary=$(echo "$log" | grep -E '^WASM3 TESTS pass=' | tail -1 || true)
    if [[ -n "$summary" ]]; then
        break
    fi
    status=$(mcp get_game_status 2>&1 || true)
    case "$status" in
        *"error"*|*"Error"*|*"panic"*)
            echo "eden_gate: runtime error while testing:"
            echo "$status" | sed 's/^/    /'
            echo "$log" | grep -vE '^\s*$' | tail -40 | sed 's/^/    /'
            exit 1 ;;
    esac
done
echo "$log" | grep -E '^(FAILED|  FAIL|\[wasm3das\]|\[run_tests\])' | sed 's/^/    /' || true
if [[ -z "$summary" ]]; then
    echo "eden_gate: no summary line within ${timeout_s}s; last log lines:"
    echo "$log" | grep -vE '^\s*$' | tail -30 | sed 's/^/    /'
    exit 1
fi
echo "$summary"
pass=$(echo "$summary" | sed -E 's/.*pass=([0-9]+).*/\1/')
failc=$(echo "$summary" | sed -E 's/.*fail=([0-9]+).*/\1/')
rc=0
if [[ "$failc" != 0 ]]; then
    echo "eden_gate: $failc failing check(s) in the editor"
    rc=1
fi
if [[ $compare == 1 && -f "$repo/tmp/eden/last_local_pass" ]]; then
    local_pass=$(cat "$repo/tmp/eden/last_local_pass")
    if [[ "$local_pass" != "$pass" ]]; then
        echo "eden_gate: the editor passed $pass checks but the local run passed $local_pass (a test was skipped or a fixture is missing in the editor)"
        rc=1
    else
        echo "eden_gate: editor and local runs agree ($pass checks)"
    fi
fi
if [[ $rc == 0 ]]; then echo "eden_gate: OK"; else echo "eden_gate: FAILED"; fi
exit $rc
