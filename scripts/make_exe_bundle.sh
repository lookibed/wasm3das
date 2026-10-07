#!/usr/bin/env bash
# Assemble a release bundle of the exe tier: the binary scripts/build_port.sh
# exe produced (the port compiled by daslang's LLVM backend, relinked against
# the static daslang runtime), the example modules, the licences and a README.
#
# Usage: scripts/make_exe_bundle.sh <binary> <out-dir> <tag> <daslang-root> [extra-file...]
#   binary        the built executable (wasm3das.exe on every platform; on
#                 Windows the statically relinked wasm3.exe)
#   out-dir       bundle root to create (removed first if it exists); its name
#                 is what the archive unpacks to
#   tag           the release tag, written into the README
#   daslang-root  the daslang checkout the binary was built with (its LICENSE
#                 and commit go into the bundle)
#   extra-file    copied next to the binary (the Visual C++ runtime DLLs of
#                 the Windows build)
#
# The binary is installed as wasm3 (wasm3.exe on Windows) and stripped where
# strip exists. It takes Wasm3's command line directly (app/wasm3.das reads
# its own argv when daslang's `--` is absent).
set -euo pipefail

if [[ $# -lt 4 ]]; then
    echo "usage: $0 <binary> <out-dir> <tag> <daslang-root> [extra-file...]" >&2
    exit 2
fi
binary="$1"
out="$2"
tag="$3"
daslang_root="$4"
shift 4
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$binary" ]]; then
    echo "exe bundle: missing binary $binary (run scripts/build_port.sh exe)" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out/examples"

windows=0
if file "$binary" 2>/dev/null | grep -q "PE32"; then
    windows=1
fi
if (( windows )); then
    exe="wasm3.exe"
    cp "$binary" "$out/$exe"
else
    exe="wasm3"
    cp "$binary" "$out/$exe"
    chmod +x "$out/$exe"
    if command -v strip >/dev/null 2>&1; then
        strip "$out/$exe" || true
    fi
fi
for f in "$@"; do
    cp "$f" "$out/"
done

cp "$repo_root"/wasm3c/test/lang/*.wasm "$out/examples/"
cp "$repo_root/LICENSE" "$out/LICENSE.txt"
cp "$repo_root/wasm3c/LICENSE" "$out/LICENSE-wasm3.txt"
if [[ -f "$daslang_root/LICENSE" ]]; then
    cp "$daslang_root/LICENSE" "$out/LICENSE-daslang.txt"
fi

commit="$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
das_commit="$(git -C "$daslang_root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
{
    echo "wasm3das $tag"
    echo
    echo "The Daslang port of the Wasm3 WebAssembly interpreter, compiled ahead of time"
    echo "by daslang's LLVM backend into one executable: no daslang inside, nothing"
    echo "compiled at startup. The command line is Wasm3's:"
    echo
    echo "  ./$exe examples/fib32.wasm --func fib 25"
    echo "  ./$exe --repl"
    echo "  ./$exe program.wasm arg1 arg2      # a WASI program (_start)"
    echo
    echo "Built from commit $commit with daslang $das_commit."
    echo "Sources, the EdenSpark version and the other bundles:"
    echo "https://github.com/lookibed/wasm3das/releases/tag/$tag"
} > "$out/README.txt"

echo "exe bundle: $out"
du -sh "$out"
