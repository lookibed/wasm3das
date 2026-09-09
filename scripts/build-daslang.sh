#!/usr/bin/env bash
# Build the daslang checkout at $1 (already cloned and checked out at the
# commit pinned in scripts/daslang_pin) and install it in place:
#
#   <root>/bin/daslang, <root>/lib/liblibDaScript*.a, <root>/include/,
#   <root>/daslib/, <root>/utils/, <root>/dastest ...
#
# The same fixed flag set as README "Install and run": Release, the headless
# module set (no LLVM/GUI/media) plus the dasHV dynamic module, which is
# everything the wasm3das port, its gate and the editor tooling need: the
# MCP server of utils/mcp requires dashv (tools/live), so a build without
# dasModuleHV.shared_module starts the LSP and the DAP bridge but not the
# daslang MCP server. Single-config (gcc/clang) and multi-config (MSVC)
# generators are both handled.
#
# Usage: scripts/build-daslang.sh <daslang-root>
# Environment: JOBS parallel compile jobs (default: nproc)
set -euo pipefail

root="$(cd -- "$1" && pwd)"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
pin_file="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/scripts/daslang_pin"
if [[ -n "${DASLANG_PIN:-}" ]]; then
    pin="$DASLANG_PIN"
else
    pin="$(sed -n 's/^\([0-9a-f]\{40\}\)$/\1/p' "$pin_file" | head -n 1)"
fi
if [[ -z "$pin" ]]; then
    echo "build-daslang: $pin_file carries no 40-hex commit" >&2
    exit 2
fi

flags=(-DCMAKE_BUILD_TYPE=Release
       -DDAS_LLVM_DISABLED=ON    # -jit needs dasLLVM; opt-in build, not the gate default
       -DDAS_GLFW_DISABLED=ON
       -DDAS_IMGUI_DISABLED=ON
       -DDAS_VULKAN_DISABLED=ON
       -DDAS_AUDIO_DISABLED=ON
       -DDAS_HV_DISABLED=OFF     # dashv: required by the MCP server (utils/mcp/tools/live)
       -DDAS_STDDLG_DISABLED=ON
       -DDAS_STBIMAGE_DISABLED=ON
       -DDAS_METAL_DISABLED=ON
       -DDAS_ACCELERATE_DISABLED=ON
       -DDAS_AOT_EXAMPLES_DISABLED=ON
       -DDAS_TUTORIAL_DISABLED=ON
       -DDAS_TESTS_DISABLED=ON
       -DDAS_BUILD_DOCUMENTATION=OFF)

# A clone (.git directory) or a worktree (.git file): git resolves both.
if ! git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "build-daslang: $root is not a git checkout of daScript" >&2
    echo "  git clone https://github.com/GaijinEntertainment/daScript.git $root" >&2
    echo "  git -C $root checkout $pin" >&2
    exit 2
fi
head="$(git -C "$root" rev-parse HEAD)"
if [[ "$head" != "$pin" ]]; then
    echo "build-daslang: $root is at $head, the pin is $pin" >&2
    echo "  git -C $root checkout $pin" >&2
    exit 2
fi

echo "build-daslang: configure ($root, HEAD ${head:0:9})"
cmake -S "$root" -B "$root/build" "${flags[@]}"

echo "build-daslang: compile ($JOBS jobs)"
cmake --build "$root/build" -j "$JOBS" --config Release --target \
      daslang libDaScript libDaScript_runtime libUriParser dasModuleHV

echo "build-daslang: install"
cmake --install "$root/build" --config Release --prefix "$root"

printf '%s\n' "$head" > "$root/.daslang-commit"
echo "build-daslang: $root ready ($("$root/bin/daslang" --version 2>/dev/null || true))"
