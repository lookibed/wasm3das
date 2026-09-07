#!/usr/bin/env bash
# Wall-clock benchmark of every WebAssembly engine available in this checkout,
# on the same workload: fib32.wasm `fib(N)`.
#
# Measured quantity: process start to process exit, from `date +%s.%N` around
# the whole command line (there is no `time` binary here). That deliberately
# includes each engine's own start-up cost - for the Daslang port it is the
# compilation of app/wasm3.das and source/*.das, which is the honest cost of
# running the port. The `fib 1` column isolates that start-up: it is the same
# lifecycle (parse, load, compile, call, teardown) on a workload whose actual
# execution is nothing.
#
# Every engine is given one un-timed warm-up run before it is measured, so the
# reported numbers are warm-page, warm-JIT-cache numbers for all of them.
#
# Environment:
#   DASLANG       daslang used for the interpreter row (default:
#                 tmp/daslang/bin/daslang, the release bundle installed by
#                 scripts/install_daslang.sh)
#   DASLANG_JIT   daslang used for the JIT rows (default: the same release
#                 binary, which ships the LLVM JIT)
#   RUNS          timed runs per cell, the median is reported (default 3)
#   NS            fib arguments, first one is the start-up column (default "1 25 30 35")
#   ENGINES       subset of engine names to run (default: all known ones)
#   BASELINE      engine the ratio table is relative to (default wasm3-c)
#   JIT_APP       app entry point for the two JIT rows, when it must differ from
#                 app/wasm3.das (a scratch tree). Normally unset: the dispatcher
#                 sentinel m3Ret_nextOp is a `var` string precisely so that the
#                 JIT shares its address with the interpreter.
#
# Usage: scripts/bench.sh [> notes/benchmark.md]

set -uo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

WASM="${WASM:-$repo_root/wasm3c/test/lang/fib32.wasm}"
FUNC="${FUNC:-fib}"
RUNS="${RUNS:-3}"
NS="${NS:-1 25 30 35}"
BASELINE="${BASELINE:-wasm3-c}"

WASMTIME="${WASMTIME:-$repo_root/tools/bin/wasmtime}"
WASM3C="${WASM3C:-$repo_root/tools/bin/wasm3}"
NATIVE="${NATIVE:-$repo_root/tmp/native/bin/wasm3das}"
DASLANG="${DASLANG:-$repo_root/tmp/daslang/bin/daslang}"
DASLANG_JIT="${DASLANG_JIT:-$DASLANG}"
JIT_APP="${JIT_APP:-}"

ALL_ENGINES="wasmtime wasm3-c wasm3das-interp wasm3das-jit wasm3das-jit-nocache wasm3das-native"
ENGINES="${ENGINES:-$ALL_ENGINES}"

# Engines whose cost does not depend on N: only the start-up column is measured
# for them. `-jit-no-cache` re-runs the whole LLVM code generation on every
# process start, so its interesting number is exactly that fixed price.
STARTUP_ONLY=" wasm3das-jit-nocache "

first_n="${NS%% *}"

# ---------------------------------------------------------------- engine table

engine_binary() {
    case "$1" in
        wasmtime)                        echo "$WASMTIME" ;;
        wasm3-c)                         echo "$WASM3C" ;;
        wasm3das-interp)                 echo "$DASLANG" ;;
        wasm3das-jit|wasm3das-jit-nocache) echo "$DASLANG_JIT" ;;
        wasm3das-native)                 echo "$NATIVE" ;;
        *)                               echo "" ;;
    esac
}

engine_label() {
    case "$1" in
        wasmtime)             echo "wasmtime 48 (LLVM AOT/JIT)" ;;
        wasm3-c)              echo "wasm3, C reference" ;;
        wasm3das-interp)      echo "wasm3das, daslang interpreter" ;;
        wasm3das-jit)         echo "wasm3das, daslang -jit (cached DLL)" ;;
        wasm3das-jit-nocache) echo "wasm3das, daslang -jit -jit-no-cache" ;;
        wasm3das-native)      echo "wasm3das, native build" ;;
        *)                    echo "$1" ;;
    esac
}

# Fills the global CMD array with the full command line for engine $1 at N=$2,
# `env` prefix included where the engine is selected through the environment.
engine_cmd() {
    local engine="$1" n="$2"
    case "$engine" in
        wasmtime)
            CMD=("$WASMTIME" run --invoke "$FUNC" "$WASM" "$n") ;;
        wasm3-c)
            # The C front end parses its options before the file name.
            CMD=("$WASM3C" --func "$FUNC" "$WASM" "$n") ;;
        wasm3das-interp)
            CMD=(env "DASLANG=$DASLANG" "$repo_root/scripts/wasm3" "$WASM" --func "$FUNC" "$n") ;;
        wasm3das-jit)
            CMD=(env "DASLANG=$DASLANG_JIT" WASM3DAS_JIT=1 ${JIT_APP:+"WASM3DAS_APP=$JIT_APP"} \
                 "$repo_root/scripts/wasm3" "$WASM" --func "$FUNC" "$n") ;;
        wasm3das-jit-nocache)
            CMD=(env "DASLANG=$DASLANG_JIT" WASM3DAS_JIT=1 WASM3DAS_JIT_ARGS=-jit-no-cache \
                 ${JIT_APP:+"WASM3DAS_APP=$JIT_APP"} \
                 "$repo_root/scripts/wasm3" "$WASM" --func "$FUNC" "$n") ;;
        wasm3das-native)
            # scripts/wasm3-native raises the stack limit and points the binary
            # at its bundle root; fall back to the bare binary if it is absent.
            if [[ -x "$repo_root/scripts/wasm3-native" ]]; then
                CMD=(env "WASM3DAS_NATIVE=$NATIVE" "$repo_root/scripts/wasm3-native" \
                     "$WASM" --func "$FUNC" "$n")
            else
                CMD=("$NATIVE" --func "$FUNC" "$WASM" "$n")
            fi ;;
        *)
            CMD=() ;;
    esac
}

# ------------------------------------------------------------------- utilities

# Prints the printable command line of the CMD array, so the report can be
# reproduced by copy and paste.
quote_cmd() {
    local part out=""
    for part in "$@"; do
        case "$part" in
            *[[:space:]]*) out+=" '$part'" ;;
            *)             out+=" $part" ;;
        esac
    done
    echo "${out# }"
}

# The last integer printed by the engine. wasm3 (C and port) writes
# "Result: <n>" to stderr, wasmtime writes the bare number to stdout after two
# experimental-feature warnings, so both are covered by taking the last
# stand-alone integer of the combined output.
extract_result() {
    printf '%s\n' "$1" | grep -oE '(^|[^0-9-])[0-9]+$' | tail -n 1 | grep -oE '[0-9]+$'
}

LAST_OUT=""
LAST_RC=0
LAST_TIME=0
# Runs the CMD array once and leaves the elapsed seconds in LAST_TIME, the
# combined output in LAST_OUT and the exit status in LAST_RC. It must not be
# called through a command substitution: that would run it in a subshell and
# throw the three results away.
time_once() {
    local t0 t1
    t0="$(date +%s.%N)"
    LAST_OUT="$("${CMD[@]}" 2>&1)"
    LAST_RC=$?
    t1="$(date +%s.%N)"
    LAST_TIME="$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.3f", b - a }')"
}

median() {
    printf '%s\n' "$@" | sort -g | awk -v n="$#" 'NR == int(n / 2) + 1 { print }'
}

fmt_ratio() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (b + 0 == 0) { print "-" } else { printf "%.1f", a / b }
    }'
}

# ------------------------------------------------------------------ discovery

declare -A MED RESULT
available=()
skipped=()

for engine in $ENGINES; do
    bin="$(engine_binary "$engine")"
    if [[ -z "$bin" ]]; then
        skipped+=("$engine: unknown engine name")
        continue
    fi
    if [[ ! -x "$bin" ]]; then
        skipped+=("$engine: \`$bin\` is not present")
        continue
    fi
    # Warm-up and smoke test in one: an engine that cannot produce a result on
    # the cheapest workload is not benchmarked.
    engine_cmd "$engine" "$first_n"
    time_once
    smoke_time="$LAST_TIME"
    if [[ $LAST_RC -ne 0 || -z "$(extract_result "$LAST_OUT")" ]]; then
        detail="$(printf '%s' "$LAST_OUT" | tr '\n' ' ' | cut -c1-120)"
        skipped+=("$engine: \`$bin\` runs but failed the fib($first_n) smoke test (exit $LAST_RC): $detail")
        continue
    fi
    available+=("$engine")
    echo "# warm-up $engine fib($first_n): ${smoke_time}s -> $(extract_result "$LAST_OUT")" >&2
done

# ------------------------------------------------------------------- measuring

# The engine every other engine's result is compared against: prefer the C
# reference, then wasmtime, then whatever ran.
oracle=""
for cand in wasm3-c wasmtime "${available[@]}"; do
    for engine in "${available[@]}"; do
        if [[ -n "$cand" && "$engine" == "$cand" ]]; then
            oracle="$cand"
            break 2
        fi
    done
done

for engine in "${available[@]}"; do
    for n in $NS; do
        if [[ "$STARTUP_ONLY" == *" $engine "* && "$n" != "$first_n" ]]; then
            MED["$engine,$n"]="-"
            continue
        fi
        engine_cmd "$engine" "$n"
        times=()
        for ((run = 0; run < RUNS; run++)); do
            time_once
            t="$LAST_TIME"
            if [[ $LAST_RC -ne 0 ]]; then
                MED["$engine,$n"]="fail"
                RESULT["$engine,$n"]="exit $LAST_RC"
                times=()
                break
            fi
            times+=("$t")
            RESULT["$engine,$n"]="$(extract_result "$LAST_OUT")"
        done
        if [[ ${#times[@]} -gt 0 ]]; then
            MED["$engine,$n"]="$(median "${times[@]}")"
        fi
        echo "# $engine fib($n): ${MED[$engine,$n]}s (${times[*]:-}) -> ${RESULT[$engine,$n]}" >&2
    done
done

# ------------------------------------------------------------------- reporting

echo
echo "### Wall clock, median of $RUNS runs, seconds (process start to exit)"
echo

header="| engine |"
sep="|---|"
for n in $NS; do
    if [[ "$n" == "$first_n" ]]; then
        header+=" fib $n (start-up) |"
    else
        header+=" fib $n |"
    fi
    sep+="---:|"
done
echo "$header"
echo "$sep"

for engine in "${available[@]}"; do
    row="| $(engine_label "$engine") |"
    for n in $NS; do
        cell="${MED[$engine,$n]:--}"
        if [[ "$cell" == "fail" ]]; then
            cell="fail (${RESULT[$engine,$n]:-?})"
        elif [[ -n "$oracle" && "$engine" != "$oracle" && -n "${RESULT[$engine,$n]:-}" \
              && -n "${RESULT[$oracle,$n]:-}" && "${RESULT[$engine,$n]}" != "${RESULT[$oracle,$n]}" ]]; then
            # Flag any engine that disagrees with the reference result.
            cell+=" (wrong result ${RESULT[$engine,$n]})"
        fi
        row+=" $cell |"
    done
    echo "$row"
done

if [[ -n "$oracle" ]]; then
    echo
    echo "Results checked against \`$oracle\`:"
    for n in $NS; do
        echo "- fib($n) = ${RESULT[$oracle,$n]:-?}"
    done
fi

# Execution only: each cell minus that engine's own start-up column. This is
# the number that describes the interpreter loop rather than the front end, and
# it is the only fair way to compare engines whose start-up costs differ by
# three orders of magnitude.
exec_only() {
    local engine="$1" n="$2"
    local a="${MED[$engine,$n]:--}" b="${MED[$engine,$first_n]:--}"
    if [[ "$a" =~ ^[0-9.]+$ && "$b" =~ ^[0-9.]+$ ]]; then
        awk -v a="$a" -v b="$b" 'BEGIN { d = a - b; printf "%.3f", d < 0 ? 0 : d }'
    else
        echo "-"
    fi
}

echo
echo "### Execution only, seconds (cell minus that engine's own start-up)"
echo
echo "$header"
echo "$sep"
for engine in "${available[@]}"; do
    row="| $(engine_label "$engine") |"
    for n in $NS; do
        if [[ "$n" == "$first_n" ]]; then
            row+=" (start-up ${MED[$engine,$n]:--}) |"
        else
            row+=" $(exec_only "$engine" "$n") |"
        fi
    done
    echo "$row"
done

# Ratios against the baseline engine, if it ran.
baseline_ran=""
for engine in "${available[@]}"; do
    [[ "$engine" == "$BASELINE" ]] && baseline_ran=yes
done
if [[ -n "$baseline_ran" ]]; then
    echo
    echo "### Ratio to \`$(engine_label "$BASELINE")\` (x slower)"
    echo
    echo "$header"
    echo "$sep"
    for engine in "${available[@]}"; do
        row="| $(engine_label "$engine") |"
        for n in $NS; do
            a="${MED[$engine,$n]:--}"
            b="${MED[$BASELINE,$n]:--}"
            if [[ "$a" =~ ^[0-9.]+$ && "$b" =~ ^[0-9.]+$ ]]; then
                row+=" $(fmt_ratio "$a" "$b")x |"
            else
                row+=" - |"
            fi
        done
        echo "$row"
    done

    echo
    echo "### Ratio to \`$(engine_label "$BASELINE")\`, execution only (x slower)"
    echo
    echo "$header"
    echo "$sep"
    for engine in "${available[@]}"; do
        row="| $(engine_label "$engine") |"
        for n in $NS; do
            if [[ "$n" == "$first_n" ]]; then
                row+=" - |"
                continue
            fi
            a="$(exec_only "$engine" "$n")"
            b="$(exec_only "$BASELINE" "$n")"
            if [[ "$a" =~ ^[0-9.]+$ && "$b" =~ ^[0-9.]+$ ]]; then
                row+=" $(fmt_ratio "$a" "$b")x |"
            else
                row+=" - |"
            fi
        done
        echo "$row"
    done
fi

if [[ ${#skipped[@]} -gt 0 ]]; then
    echo
    echo "### Engines not measured"
    echo
    for line in "${skipped[@]}"; do
        echo "- $line"
    done
fi

echo
echo "### Exact commands"
echo
echo '```'
for engine in "${available[@]}"; do
    engine_cmd "$engine" N
    echo "# $engine"
    echo "$(quote_cmd "${CMD[@]}")"
done
echo '```'

echo
echo "### Machine"
echo
echo "- $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//'), $(nproc) threads"
echo "- $(uname -sr)"
echo "- workload: \`$WASM\`, function \`$FUNC\`"
