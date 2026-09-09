#!/usr/bin/env bash
# Verify that DASLANG_ROOT points at the pinned daslang source, built.
#
# wasm3das does not download or ship daslang. Whoever clones this repository
# checks out GaijinEntertainment/daScript at the commit pinned in
# scripts/daslang_pin, builds it in place (see README "Install and run") and
# exports DASLANG_ROOT to that checkout. Every authoritative entry point
# (scripts/gate.sh, key build scripts) verifies before it runs.
#
# Checks:
#   1. DASLANG_ROOT is set and resolves to a git checkout of daScript (a
#      clone or a worktree) whose HEAD is the pinned commit, or to a
#      build-daslang.sh install carrying the .daslang-commit marker (unless
#      DASLANG_ALLOW_UNPINNED=1, for local experiments only — never a green
#      gate).
#   2. The build is complete enough for this repository's use:
#      bin/daslang, lib/liblibDaScript.a, lib/liblibDaScript_runtime.a,
#      lib/liblibUriParser.a, include/daScript/builtin/ast_gen.inc,
#      daslib/, utils/aot/main.das, and the dasHV dynamic module
#      (modules/dasHV/dasModuleHV.shared_module) the MCP server requires.
#   3. bin/daslang runs (--version).
#
# Usage: scripts/verify_daslang.sh
# Environment: DASLANG_ROOT (required), DASLANG_ALLOW_UNPINNED (optional).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pin="$(sed -n 's/^\([0-9a-f]\{40\}\)$/\1/p' "$repo_root/scripts/daslang_pin" | head -n 1)"
if [[ -z "$pin" ]]; then
    echo "verify_daslang: scripts/daslang_pin carries no 40-hex commit" >&2
    exit 2
fi

if [[ -z "${DASLANG_ROOT:-}" ]]; then
    echo "verify_daslang: DASLANG_ROOT is not set." >&2
    echo "" >&2
    echo "  wasm3das runs daslang as an external project. Clone it at the pinned" >&2
    echo "  commit, build in place and point DASLANG_ROOT at the checkout:" >&2
    echo "" >&2
    echo "    git clone https://github.com/GaijinEntertainment/daScript.git ../daScript   # beside, never inside, this repository" >&2
    echo "    git -C ../daScript checkout $pin" >&2
    echo "    scripts/build-daslang.sh ../daScript   # the fixed flag set; README, Install and run" >&2
    echo "    export DASLANG_ROOT=\"\$(cd .. && pwd)/daScript\"" >&2
    exit 2
fi
root="$(cd -- "$DASLANG_ROOT" 2>/dev/null && pwd || true)"
if [[ -z "$root" ]]; then
    echo "verify_daslang: DASLANG_ROOT='$DASLANG_ROOT' does not exist" >&2
    exit 2
fi

# A clone has a .git directory, a worktree a .git file; git resolves both.
# An install made by build-daslang.sh outside a checkout carries the marker.
head=""
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
elif [[ -f "$root/.daslang-commit" ]]; then
    head="$(head -c 40 "$root/.daslang-commit" 2>/dev/null || true)"
else
    echo "verify_daslang: $root is neither a git checkout of daScript nor a build-daslang.sh install of one" >&2
    exit 2
fi
if [[ "${DASLANG_ALLOW_UNPINNED:-0}" == "1" ]]; then
    echo "verify_daslang: DASLANG_ALLOW_UNPINNED=1 — skipping the pin check" \
         "(HEAD ${head:-<unknown>}, pin $pin); experiments only, this is not a gate" >&2
elif [[ "$head" != "$pin" ]]; then
    echo "verify_daslang: $root is at $head, the pin is $pin" >&2
    echo "  check out the pinned commit: git -C '$root' checkout $pin" >&2
    exit 2
fi

missing=()
for f in bin/daslang lib/liblibDaScript.a lib/liblibDaScript_runtime.a \
         lib/liblibUriParser.a include/daScript/builtin/ast_gen.inc \
         utils/aot/main.das modules/dasHV/dasModuleHV.shared_module; do
    if [[ ! -e "$root/$f" ]]; then
        missing+=("$root/$f")
    fi
done
if [[ ! -d "$root/daslib" ]]; then
    missing+=("$root/daslib/")
fi
if (( ${#missing[@]} > 0 )); then
    echo "verify_daslang: incomplete daslang build in $root" >&2
    for f in "${missing[@]}"; do
        echo "  missing: $f" >&2
    done
    echo "  build it: scripts/build-daslang.sh $root" >&2
    exit 2
fi
if ! "$root/bin/daslang" --version >/dev/null 2>&1; then
    echo "verify_daslang: $root/bin/daslang does not run" >&2
    exit 2
fi
echo "verify_daslang: $root at ${head:0:9}, version $("$root/bin/daslang" --version)"
