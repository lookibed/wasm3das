#!/usr/bin/env bash
# The WebAssembly test-suite corpus of the feature-coverage pipeline
# (docs/wasm-features/PLAN.md section 1).
#
#   - checks out WebAssembly/testsuite at STATE.json corpus.commit into
#     $WASM3DAS_CORPUS/testsuite (default /root/.cache/wasm3das): outside the
#     Eden project, whose editor imports every text file of its tree
#   - converts every .wast with `wasm-tools json-from-wast` into
#     $WASM3DAS_CORPUS/json/<commit>/<path>/<name>.json plus its modules
#   - assigns every file to a group of docs/wasm-features/groups.json and
#     writes the list to $WASM3DAS_CORPUS/json/<commit>/index.json; a file no
#     group claims, or a conversion failure, fails the script
#
# Network is needed for the first checkout only. Idempotent: converted files
# are kept unless --force.
#
# Usage: scripts/features/corpus.sh [--force]
# Exit: 0 when every file is converted and grouped.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
corpus="${WASM3DAS_CORPUS:-/root/.cache/wasm3das}"
wasm_tools="${WASM_TOOLS:-$(command -v wasm-tools || echo /root/.cargo/bin/wasm-tools)}"
state="$repo/docs/wasm-features/STATE.json"
force=0
[[ "${1:-}" == "--force" ]] && force=1

commit="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['corpus']['commit'])" "$state")"
want_tools="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['corpus']['wasm_tools'])" "$state")"
have_tools="$("$wasm_tools" --version | awk '{print $2}')"
if [[ "$have_tools" != "$want_tools" ]]; then
    echo "corpus: wasm-tools $have_tools, STATE.json pins $want_tools" >&2
    exit 2
fi

mkdir -p "$corpus"
if [[ ! -d "$corpus/testsuite/.git" ]]; then
    git clone -q https://github.com/WebAssembly/testsuite "$corpus/testsuite"
fi
git -C "$corpus/testsuite" fetch -q origin 2>/dev/null || true
git -C "$corpus/testsuite" checkout -q "$commit"

out="$corpus/json/$commit"
mkdir -p "$out"
python3 "$repo/scripts/features/corpus_index.py" "$corpus/testsuite" "$repo/docs/wasm-features/groups.json" "$out/index.json"

fail=0
n=0
# files STATE.json corpus.unconverted lists, with the phase that converts them
mapfile -t unconverted < <(python3 -c "import json,sys; [print(u['path']) for u in json.load(open(sys.argv[1]))['corpus'].get('unconverted', [])]" "$state")
is_unconverted() {
    local u
    for u in "${unconverted[@]}"; do
        [[ "$u" == "$1" ]] && return 0
    done
    return 1
}
while IFS= read -r rel; do
    if is_unconverted "$rel"; then
        echo "corpus: not converted (STATE.json corpus.unconverted): $rel"
        continue
    fi
    dir="$out/$rel"
    json="$dir/$(basename "$rel").json"
    n=$((n + 1))
    if [[ $force == 0 && -f "$json" ]]; then
        continue
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    if ! "$wasm_tools" json-from-wast "$corpus/testsuite/$rel.wast" -o "$json" --wasm-dir "$dir" 2> "$dir/convert.err"; then
        echo "corpus: conversion failed: $rel ($(head -1 "$dir/convert.err"))"
        fail=1
    fi
done < <(python3 -c "import json,sys; [print(e['path']) for e in json.load(open(sys.argv[1]))['files']]" "$out/index.json")

echo "corpus: $n files at $commit in $out"
exit $fail
