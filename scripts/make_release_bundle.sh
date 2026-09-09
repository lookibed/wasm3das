#!/usr/bin/env bash
# Assemble a self-contained wasm3das bundle: the daslang interpreter built
# from the pinned commit, its daslib, the port sources and the launchers.
#
# Usage: scripts/make_release_bundle.sh <daslang-root> <daslang-binary> <out-dir>
#   daslang-root    a built daslang checkout (its own daslang version) at the
#                   commit pinned in scripts/daslang_pin; holds daslib/ and lib/
#   daslang-binary  the daslang executable to ship (daslang, daslang.exe);
#                   it is installed as bin/daslang[.exe]
#   out-dir         bundle root to create (removed first if it exists)
#
# daslang locates daslib/ relative to its executable: <root>/bin/daslang
# implies <root>/daslib, so the layout below is fixed by the interpreter.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <daslang-root> <daslang-binary> <out-dir>" >&2
    exit 2
fi

daslang_root="$1"
daslang_binary="$2"
out="$3"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "$daslang_root/daslib" ]]; then
    echo "bundle: $daslang_root has no daslib/" >&2
    exit 1
fi
if [[ ! -f "$daslang_binary" ]]; then
    echo "bundle: missing daslang binary $daslang_binary" >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out/bin"

case "$daslang_binary" in
    *.exe)
        cp "$daslang_binary" "$out/bin/daslang.exe"
        # The Windows release links libDaScriptDyn*.dll beside the executable.
        cp "$(dirname "$daslang_binary")"/*DaScript*.dll "$out/bin/"
        ;;
    *)
        cp "$daslang_binary" "$out/bin/daslang"
        chmod +x "$out/bin/daslang"
        if command -v strip >/dev/null 2>&1; then
            strip "$out/bin/daslang" || true
        fi
        ;;
esac

# The Linux/macOS release binary finds libDaScriptDyn* through rpath
# $ORIGIN/../lib, so the shared objects travel in lib/ beside bin/; the static
# archives of the bundle are not needed at run time.
if command -v ldd >/dev/null 2>&1 && ldd "$daslang_binary" 2>/dev/null | grep -q libDaScript; then
    mkdir -p "$out/lib"
    cp "$daslang_root"/lib/*libDaScript*.so* "$out/lib/"
fi

cp -R "$daslang_root/daslib" "$out/daslib"
cp -R "$repo_root/app" "$out/app"
cp -R "$repo_root/source" "$out/source"
mkdir -p "$out/scripts" "$out/examples"
cp "$repo_root/scripts/wasm3" "$out/scripts/wasm3"
cp "$repo_root/scripts/bundle/wasm3" "$out/wasm3"
cp "$repo_root/scripts/bundle/wasm3.cmd" "$out/wasm3.cmd"
chmod +x "$out/scripts/wasm3" "$out/wasm3"
cp "$repo_root"/wasm3c/test/lang/*.wasm "$out/examples/"
cp "$repo_root/README.md" "$out/README.md"
cp "$repo_root/wasm3c/LICENSE" "$out/LICENSE-wasm3.txt"
if [[ -f "$daslang_root/LICENSE" ]]; then
    cp "$daslang_root/LICENSE" "$out/LICENSE-daslang.txt"
fi

echo "bundle: $out"
du -sh "$out"
