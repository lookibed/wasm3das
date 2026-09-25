#!/usr/bin/env bash
# Gate 1 of the Eden port: every Eden-visible file compiles under the editor's
# rules, with every available local compiler (the 0.6.3 build first: it has
# the editor's parser, which rejects 0.6.4 syntax such as `addr<T>`).
#
# Two checks per file:
#   1. textual: the constructs the editor refuses, found by grep so the
#      report names every site at once (the compilers stop at the first)
#   2. `daslang -compile-only` under scripts/eden/sandbox.das_project
#
# Files: source/*.das, tests/eden/*.das, .local/**/*.das (the last group is
# not Eden-visible but must compile; fio is allowed there by the sandbox).
#
# Usage: scripts/eden/compile.sh [file ...]     (default: all)
# Exit: 0 when every file passes with every compiler.
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

cd "$eden_root"
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    mapfile -t files < <(find modules/wasm3das/source modules/wasm3das/tests/eden modules/wasm3das/.local -type f -name '*.das' 2>/dev/null | sort)
fi
if [[ ${#files[@]} == 0 ]]; then
    echo "compile: no files"
    exit 0
fi

fail=0

banner "compile: textual rules of the editor sandbox"
for f in "${files[@]}"; do
    case "$f" in */.local/*) continue ;; esac
    # unsafe in any spelling; the comment form `// ... unsafe ...` is allowed
    if grep -nE '^[^/]*\bunsafe\b' "$f" | grep -vE '^\s*[0-9]+:\s*//' ; then
        echo "compile: $f: unsafe is forbidden in the editor" ; fail=1
    fi
    if grep -nE '^\s*require\s+(daslib/)?(fio|network|jobque_boost|jobque|ast|ast_boost|templates_boost|safe_addr|linked_list|constexpr)\b' "$f"; then
        echo "compile: $f: module refused by the editor" ; fail=1
    fi
    if grep -nE '^\s*options\s+(no_unsafe|remove_unused_symbols|unsafe_table_lookup)\b' "$f"; then
        echo "compile: $f: option refused by the editor" ; fail=1
    fi
    if grep -nE '^\s*\[\s*([a-z_]*macro[a-z_]*|init|finalize|unsafe_deref)\b' "$f"; then
        echo "compile: $f: annotation unavailable in the editor" ; fail=1
    fi
    if grep -nE '\baddr<' "$f"; then
        echo "compile: $f: typed addr<T> is 0.6.4 syntax, not in 0.6.3 (and unsafe anyway)" ; fail=1
    fi
    # two combined operand reads (immediate_*(rt), slot_*(rt), slot_index(rt),
    # set_slot_*(rt, v)) in one statement evaluate in unspecified order; the
    # upstream macro pass refused them, this grep does (DESIGN 4.4)
    if awk '
        /^[[:space:]]*\/\// { next }
        {
            line = $0
            n = gsub(/(immediate_[a-z0-9]+|slot_[a-z0-9]+|slot_index)\(rt\)/, "", line)
            n += gsub(/set_slot_[a-z0-9]+\(rt, /, "", line)
            if (n >= 2) { print FILENAME ":" NR ": " $0; found = 1 }
        }
        END { exit found ? 0 : 1 }' "$f"; then
        echo "compile: $f: two combined operand reads in one statement (order unspecified); split them" ; fail=1
    fi
done

for bin in $(compilers); do
    banner "compile: $bin ($("$bin" --version 2>/dev/null | head -1))"
    for f in "${files[@]}"; do
        if out=$(das_sandbox "$bin" -compile-only "$eden_root/$f" 2>&1); then
            echo "ok    $f"
        else
            echo "FAIL  $f"
            echo "$out" | grep -vE '^\s*$|atexit' | sed 's/^/      /'
            fail=1
        fi
    done
done

if [[ $fail == 0 ]]; then
    echo "compile: OK (${#files[@]} files)"
else
    echo "compile: FAILED"
fi
exit $fail
