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
#   1. DASLANG_ROOT is set and is itself the top of a git checkout of
#      daScript (a clone or a worktree) whose HEAD is the pinned commit, or
#      a tree built by build-daslang.sh that carries the .daslang-commit
#      marker. DASLANG_ALLOW_UNPINNED=1 skips the commit comparison (and
#      accepts a tree with neither git nor marker): local experiments only,
#      never a green gate.
#   2. The build outputs are present: bin/daslang, lib/liblibDaScript.a,
#      lib/liblibDaScript_runtime.a, lib/liblibUriParser.a and the dasHV
#      dynamic module (modules/dasHV/dasModuleHV.shared_module) the MCP
#      server requires; daslib/, utils/aot/main.das and the tracked
#      generated header include/daScript/builtin/ast_gen.inc identify the
#      tree as daScript.
#   3. bin/daslang runs (--version); its output is shown when it does not.
#
# Usage: scripts/verify_daslang.sh
# Environment: DASLANG_ROOT (required), DASLANG_ALLOW_UNPINNED (optional).
set -euo pipefail

# This script asks git about another repository (the daslang checkout). A
# git hook exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE for its own
# repository, and `git -C <other>` would keep answering about this one.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

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
    beside="$(cd -- "$repo_root/.." && pwd)/daScript"
    echo "    git clone https://github.com/GaijinEntertainment/daScript.git $beside   # beside, never inside, this repository" >&2
    echo "    git -C $beside checkout $pin" >&2
    echo "    $repo_root/scripts/build-daslang.sh $beside   # the fixed flag set; README, Install and run" >&2
    echo "    export DASLANG_ROOT=$beside" >&2
    exit 2
fi
root="$(cd -- "$DASLANG_ROOT" 2>/dev/null && pwd || true)"
if [[ -z "$root" ]]; then
    echo "verify_daslang: DASLANG_ROOT='$DASLANG_ROOT' does not exist" >&2
    exit 2
fi

# The root must itself be the top of a git checkout (a clone with a .git
# directory or a worktree with a .git file; --show-toplevel names the
# worktree itself). Asking merely whether git resolves a git-dir would accept
# any directory that happens to sit inside someone else's repository and
# report that repository's HEAD. A tree built by build-daslang.sh and copied
# elsewhere carries the .daslang-commit marker instead.
head=""
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$top" && "$top" -ef "$root" ]]; then
    head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
elif [[ -f "$root/.daslang-commit" ]]; then
    head="$(head -c 40 "$root/.daslang-commit" 2>/dev/null || true)"
elif [[ "${DASLANG_ALLOW_UNPINNED:-0}" != "1" ]]; then
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

# What the build produces (bin/, lib/, the dasHV module) plus two tracked
# paths that tell a daScript tree from any other directory; the generated
# headers such as include/daScript/builtin/ast_gen.inc are tracked upstream.
missing=()
required=(bin/daslang lib/liblibDaScript.a lib/liblibDaScript_runtime.a
          lib/liblibUriParser.a utils/aot/main.das include/daScript/builtin/ast_gen.inc)
# The dasHV module serves the MCP server; a tree built with
# DASLANG_HV_DISABLED=ON (release.yml, where the bundles ship no modules) is
# complete without it.
if [[ "${DASLANG_HV_DISABLED:-OFF}" != "ON" ]]; then
    required+=(modules/dasHV/dasModuleHV.shared_module)
fi
# Multi-config generators (MSVC) put the outputs under Release/.
if [[ -f "$root/bin/Release/daslang.exe" ]]; then
    required=(bin/Release/daslang.exe lib/Release/libDaScript.lib lib/Release/libDaScript_runtime.lib
              lib/Release/libUriParser.lib utils/aot/main.das include/daScript/builtin/ast_gen.inc)
fi
for f in "${required[@]}"; do
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
if ! version="$("$root/bin/daslang" --version 2>&1)"; then
    echo "verify_daslang: $root/bin/daslang does not run:" >&2
    echo "  $version" >&2
    exit 2
fi
echo "verify_daslang: $root at ${head:0:9}, version $version"
