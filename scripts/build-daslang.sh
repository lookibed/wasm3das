#!/usr/bin/env bash
# Build the daslang checkout at $1 (already cloned and checked out at the
# commit pinned in scripts/daslang_pin) in place. daScript's CMake writes its
# outputs into the source tree itself, so the checkout is the install:
#
#   <root>/bin/daslang, <root>/lib/liblibDaScript*.a, <root>/include/,
#   <root>/daslib/, <root>/utils/, <root>/dastest,
#   <root>/modules/dasHV/dasModuleHV.shared_module ...
#
# There is deliberately no `cmake --install`: it copies the tree onto itself
# and, because it installs every module the configure step enabled, fails on
# a library this script never builds (liblibDasModuleClipboard.a on a runner
# with X11 headers). The generated headers the SDK needs
# (include/daScript/builtin/ast_gen.inc, debugapi_gen.inc) are tracked
# upstream and present in the checkout before any build.
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
# Environment:
#   JOBS                  parallel compile jobs (default: nproc)
#   DASLANG_HV_DISABLED   ON skips the dasHV module (release.yml sets it: a
#                         shipped bundle carries no modules, and on MSVC the
#                         module builds OpenSSL from source); default OFF
set -euo pipefail

if [[ $# -ne 1 || ! -d "${1:-}" ]]; then
    echo "usage: $0 <daslang-root>   (an existing daScript checkout at the pinned commit)" >&2
    exit 2
fi
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
       -DDAS_HV_DISABLED="${DASLANG_HV_DISABLED:-OFF}"   # dashv: required by the MCP server (utils/mcp/tools/live)
       -DDAS_STDDLG_DISABLED=ON
       -DDAS_STBIMAGE_DISABLED=ON
       -DDAS_METAL_DISABLED=ON
       -DDAS_ACCELERATE_DISABLED=ON
       -DDAS_AOT_EXAMPLES_DISABLED=ON
       -DDAS_TUTORIAL_DISABLED=ON
       -DDAS_TESTS_DISABLED=ON
       -DDAS_BUILD_DOCUMENTATION=OFF)
# Not disabled on purpose: tree-sitter. bin/daslang at the pin links
# lib/libdasTreeSitterRuntime.a, and the LSP and the outline tools were
# smoke-tested with it present; the CI flag set once switched it off and
# that saving was never measured.
targets=(daslang libDaScript libDaScript_runtime libUriParser)
if [[ "${DASLANG_HV_DISABLED:-OFF}" != "ON" ]]; then
    targets+=(dasModuleHV)
fi

# The root must be the top of a checkout: a clone (.git directory) or a
# worktree (.git file), not a directory that merely sits inside some other
# repository.
top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$top" || ! "$top" -ef "$root" ]]; then
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
cmake --build "$root/build" -j "$JOBS" --config Release --target "${targets[@]}"

# The binary: bin/daslang for single-config generators, bin/Release/ for
# multi-config ones (MSVC); it has to run, or the build is not a build.
bin=""
for candidate in bin/daslang bin/Release/daslang bin/daslang.exe bin/Release/daslang.exe; do
    if [[ -f "$root/$candidate" ]]; then bin="$root/$candidate"; break; fi
done
if [[ -z "$bin" ]]; then
    echo "build-daslang: no daslang binary under $root/bin after the build" >&2
    exit 2
fi
if ! version="$("$bin" --version 2>&1)"; then
    echo "build-daslang: $bin does not run:" >&2
    echo "  $version" >&2
    exit 2
fi

# The marker verify_daslang.sh reads when the root is not a git checkout
# (a copied or unpacked tree); a checkout answers through git itself.
printf '%s\n' "$head" > "$root/.daslang-commit"
echo "build-daslang: $root ready (daslang $version, $bin)"
