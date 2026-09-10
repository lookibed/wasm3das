#!/usr/bin/env bash
# Assemble the standalone wasm3das bundle: the -ctx binary scripts/build_port.sh
# ctx produced (the whole port compiled into it, no daslang inside, no compile
# at startup), the example modules, the licences and a README.
#
# Usage: scripts/make_standalone_bundle.sh <ctx-binary> <out-dir> <tag> <daslang-root>
#   ctx-binary    tmp/native-ctx/bin/wasm3das (or wasm3das.exe)
#   out-dir       bundle root to create (removed first if it exists); the
#                 directory name is what the archive unpacks to
#   tag           the release tag, written into the README
#   daslang-root  the daslang checkout, for its LICENSE
#
# The binary is stripped on the platforms that have strip; on Windows the
# .exe is copied as is. The standalone binary reserves its own 256 MiB
# stack (native/standalone_main.cpp), so no launcher is needed and none is
# shipped: the archive holds wasm3[.exe] at its root.
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "usage: $0 <ctx-binary> <out-dir> <tag> <daslang-root>" >&2
    exit 2
fi
ctx_binary="$1"
out="$2"
tag="$3"
daslang_root="$4"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$ctx_binary" ]]; then
    echo "standalone bundle: missing ctx binary $ctx_binary (run scripts/build_port.sh ctx)" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out/examples"

case "$ctx_binary" in
    *.exe)
        cp "$ctx_binary" "$out/wasm3.exe"
        exe="wasm3.exe"
        ;;
    *)
        cp "$ctx_binary" "$out/wasm3"
        chmod +x "$out/wasm3"
        if command -v strip >/dev/null 2>&1; then
            strip "$out/wasm3" || true
        fi
        exe="wasm3"
        ;;
esac

cp "$repo_root"/wasm3c/test/lang/*.wasm "$out/examples/"
cp "$repo_root/wasm3c/LICENSE" "$out/LICENSE-wasm3.txt"
if [[ -f "$daslang_root/LICENSE" ]]; then
    cp "$daslang_root/LICENSE" "$out/LICENSE-daslang.txt"
fi

pin="$(sed -n 's/^\([0-9a-f]\{40\}\)$/\1/p' "$repo_root/scripts/daslang_pin" | head -n 1)"
commit="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
{
    echo "wasm3das $tag, standalone build"
    echo
    echo "The Daslang port of the Wasm3 WebAssembly interpreter compiled into one native"
    echo "binary through daslang's standalone-context emitter: no daslang inside, no"
    echo "compile at startup. Same command line as the interpreted launcher:"
    echo
    echo "  ./$exe examples/fib32.wasm --func fib 25"
    echo "  ./$exe --repl"
    echo "  ./$exe program.wasm arg1 arg2      # WASI _start"
    echo
    echo "The binary reserves its own 256 MiB stack, so a runaway wasm recursion ends in"
    echo "'[trap] stack overflow' without any ulimit or launcher."
    echo
    echo "Built from $tag (commit $commit) against daslang upstream commit ${pin:0:9}"
    echo "(scripts/daslang_pin). Sources and the other bundles:"
    echo "https://github.com/lookibed/wasm3das/releases/tag/$tag"
} > "$out/README.txt"

echo "standalone bundle: $out"
du -sh "$out"
