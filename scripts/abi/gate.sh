#!/usr/bin/env bash
# The gate of the Eden guest ABI (docs/eden-abi/PIPELINE.md). Stages, in
# order; the first red one stops the gate:
#
#   local
#     idl        scripts/abi/abigen.py --check: bindings, headers and the
#                reference are exactly what the IDL produces
#     guests     scripts/abi/build_guests.sh --check: the committed
#                guests/build/*.wasm are what the sources build to
#     compile    scripts/eden/compile.sh: every Eden-visible file under the
#                sandbox rules (includes source/abi, tests/eden)
#     test       scripts/eden/test.sh: the whole suite, ABI tests included
#     golden     .local/run_abi_golden.das: binjgb 16 frames x 3 variants
#                against the wasmtime baselines
#   editor (skipped with --local)
#     host       scripts/eden/install_host.sh --check
#     eden       scripts/eden/eden_gate.sh: the editor compiles, its suite
#                passes with the local count
#     golden     cheat abi_binjgb_golden: the golden checks in the editor
#     engine     cheat abi_host_check: the Eden host's video/audio paths
#     input      MCP input: X and A held -> cheat abi_input_probe reads
#                pad=257 key30=1
#     reload     cheat abi_play, a forced script reload while it plays: the
#                player relinks and keeps presenting frames
#
# Usage: scripts/abi/gate.sh [--local]
# Exit 0 when every stage run is green; 2 when the editor is unreachable.
set -uo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
eden_root="$(cd -- "$repo/../.." && pwd)"
M="$repo/scripts/eden/edenmcp"
DASLANG="${DASLANG_063:-/root/daScript-0.6.3/bin/daslang}"
local_only=0
[[ "${1:-}" == "--local" ]] && local_only=1

stage() { echo; echo "==== abi gate: $* ===="; }
fail() { echo "abi gate: FAILED at $1"; exit "${2:-1}"; }

cd "$repo"

stage "idl"
python3 scripts/abi/abigen.py --check || fail idl

stage "guests"
scripts/abi/build_guests.sh --check || fail guests
python3 scripts/abi/make_battery_rom.py --check || fail "guests (battery_test.gb)"

stage "compile"
scripts/eden/compile.sh > tmp/eden/abi_gate_compile.log 2>&1
tail -3 tmp/eden/abi_gate_compile.log
grep -q "compile: OK" tmp/eden/abi_gate_compile.log || { grep -E "FAIL|error" tmp/eden/abi_gate_compile.log | head -20; fail compile; }

stage "test"
scripts/eden/test.sh > tmp/eden/abi_gate_test.log 2>&1
grep -E "FAIL|WASM3 TESTS|test:" tmp/eden/abi_gate_test.log | tail -12
grep -q "test: OK" tmp/eden/abi_gate_test.log || fail test

stage "golden (local)"
(cd "$eden_root" && "$DASLANG" -no-dynamic-modules -project modules/wasm3das/scripts/eden/sandbox.das_project \
    modules/wasm3das/.local/run_abi_golden.das) > tmp/eden/abi_gate_golden.log 2>&1
grep -E "abi_golden\]|FAIL|WASM3 TESTS" tmp/eden/abi_gate_golden.log
grep -q "WASM3 TESTS pass=[0-9]* fail=0" tmp/eden/abi_gate_golden.log || fail golden

if [[ $local_only == 1 ]]; then
    echo; echo "abi gate: local stages OK (editor stages skipped)"
    exit 0
fi

stage "editor reachable"
status=$("$M" get_game_status 2>&1) || { echo "$status"; fail "editor (not reachable)" 2; }
echo "$status"

stage "host"
scripts/eden/install_host.sh --check || fail "host (run scripts/eden/install_host.sh)"

stage "eden"
scripts/eden/eden_gate.sh > tmp/eden/abi_gate_eden.log 2>&1
tail -4 tmp/eden/abi_gate_eden.log
grep -q "eden_gate: OK" tmp/eden/abi_gate_eden.log || fail eden

# runs a cheat that prints "WASM3 TESTS pass=N fail=M"; prints the report
cheat_suite() {
    local cmd="$1" log="" tries=0
    "$M" get_logs > /dev/null
    "$M" exec_cheat "{\"cmd\":\"$cmd\"}" > /dev/null
    until grep -q "WASM3 TESTS pass=" <<< "$log"; do
        sleep 3
        log="$log$("$M" get_logs)"
        tries=$((tries + 1))
        if [[ $tries -gt 200 ]]; then
            echo "abi gate: no summary from $cmd after 10 minutes"
            return 1
        fi
    done
    echo "$log" | grep -E "FAIL|abi_golden\]|abi_host_check\]|WASM3 TESTS" | grep -v "^modules/"
    grep -q "WASM3 TESTS pass=[0-9]* fail=0" <<< "$log"
}

stage "float environment (information)"
# EdenSpark flushes denormal floats to zero (since 1.0 in every script
# context; docs/eden-abi/PIPELINE.md 7). Printed so a change of the engine
# shows up here
"$M" get_logs > /dev/null
"$M" exec_cheat '{"cmd":"abi_denormal_probe"}' > /dev/null
sleep 3
"$M" get_logs | grep "ABI DENORMAL" || echo "abi gate: no denormal probe output"

stage "golden (editor)"
cheat_suite abi_binjgb_golden || fail "golden (editor)"

stage "engine"
cheat_suite abi_host_check || fail engine

stage "input"
"$M" set_active_tab '{"tab":"Game"}' > /dev/null
"$M" input_sequence '{"commands":"clear\nkey_down 45\nkey_down 30\ndelay 6\nkey_up 45\nkey_up 30"}' > /dev/null
sleep 2
"$M" get_logs > /dev/null
"$M" exec_cheat '{"cmd":"abi_input_probe"}' > /dev/null
line=""
for i in $(seq 1 10); do
    sleep 1
    line=$("$M" get_logs | grep "ABI INPUT" | tail -1)
    [[ -n "$line" ]] && break
done
echo "$line"
[[ "$line" == *"pad=257 key30=1"* ]] || fail "input (expected pad=257 key30=1 while X and A are held)"

# frames the running player reports ("ABI PLAYER frames=N ...")
player_frames() {
    "$M" exec_cheat '{"cmd":"abi_player_digest"}' > /dev/null
    local n=""
    for i in $(seq 1 10); do
        sleep 1
        n=$("$M" get_logs | grep -oE "ABI PLAYER frames=[0-9]+" | tail -1 | grep -oE "[0-9]+$")
        [[ -n "$n" ]] && break
    done
    echo "${n:-0}"
}

stage "reload"
"$M" get_logs > /dev/null
"$M" exec_cheat '{"cmd":"abi_play"}' > /dev/null
before=0
for i in $(seq 1 60); do
    before=$(player_frames)
    [[ $before -ge 2 ]] && break
    sleep 2
done
[[ $before -ge 2 ]] || fail "reload (the player did not start presenting frames)"
# a new file in the tree makes the editor rescan and reload the scripts; its
# file watcher sometimes misses one, so up to three attempts
log=""
for attempt in 1 2 3; do
    probe="$repo/tmp/eden/rescan_probe_$$_$attempt.das"
    printf '// abi gate reload probe\n' > "$probe"
    sleep 4
    rm -f "$probe"
    for i in $(seq 1 15); do
        sleep 2
        log="$log$("$M" get_logs)"
        grep -q "Reload scripts ended" <<< "$log" && break
    done
    grep -q "Reload scripts ended" <<< "$log" && break
    echo "abi gate: reload attempt $attempt not picked up by the editor"
done
grep -q "Reload scripts ended" <<< "$log" || fail "reload (the editor did not reload the scripts)"
after=$before
for i in $(seq 1 60); do
    after=$(player_frames)
    [[ $after -ge $((before + 2)) ]] && break
    sleep 2
done
log="$log$("$M" get_logs)"
echo "$log" | grep -E "relinked|stopped" | head -4
echo "frames: $before before the reload, $after after"
"$M" exec_cheat '{"cmd":"abi_stop"}' > /dev/null
grep -q "stopped" <<< "$log" && fail "reload (the player stopped)"
grep -q "relinked after a hot reload" <<< "$log" || fail "reload (no relink reported)"
[[ $after -ge $((before + 2)) ]] || fail "reload (no frames after the relink)"

echo
echo "abi gate: OK"
