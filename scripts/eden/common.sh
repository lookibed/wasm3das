#!/usr/bin/env bash
# Shared definitions of the Eden port scripts. Source it, do not run it.
#
#   repo        this repository (modules/wasm3das)
#   eden_root   the Eden project root: the folder with manifest.blk, two levels
#               above the repository. The editor resolves `require` paths from
#               there, so every local compile runs from there too.
#   DASLANG_064 the local daslang nearest to the editor's 0.6.4 (EdenSpark
#               1.0; default /root/daScript/bin/daslang). The editor's 0.6.3
#               (EdenSpark 0.9) is no longer a target: the port uses
#               0.6.4-only constructs such as [inline]
#   SANDBOX     scripts/eden/sandbox.das_project, the model of the editor's rules
#   EDENMCP     the command-line client of the editor's MCP server
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
eden_root="$(cd -- "$repo/../.." && pwd)"
if [[ ! -f "$eden_root/manifest.blk" ]]; then
    echo "eden: $eden_root is not an Eden project root (no manifest.blk); the repository must live at <project>/modules/wasm3das" >&2
    exit 2
fi

DASLANG_064="${DASLANG_064:-/root/daScript/bin/daslang}"
SANDBOX="$repo/scripts/eden/sandbox.das_project"
EDENMCP="$repo/scripts/eden/edenmcp"
STATE="$repo/docs/eden-port/STATE.json"
FIXTURES="$repo/docs/eden-port/fixtures.txt"

# daslang invocation under the sandbox; usage: das_sandbox <daslang> <args...>
das_sandbox() {
    local bin="$1"
    shift
    "$bin" -no-dynamic-modules -project "$SANDBOX" "$@"
}

compilers() {
    # prints the available compilers (the 0.6.4 build)
    if [[ -x "$DASLANG_064" ]]; then
        echo "$DASLANG_064"
    else
        echo "eden: no daslang binary found (DASLANG_064=$DASLANG_064)" >&2
        return 1
    fi
}

state_get() {
    # state_get <python expression over `s` (the parsed STATE.json)>
    python3 - "$STATE" "$1" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))
EOF
}

banner() {
    echo
    echo "==== $* ===="
}
