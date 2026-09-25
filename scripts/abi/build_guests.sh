#!/usr/bin/env bash
# Builds the ABI guests (guests/<name>) into guests/build/<name>.wasm with the
# pinned toolchain and records their sha256 in guests/build/SHA256SUMS.
#
# Toolchain: the clang of wasi-sdk 24.0 (LLVM 18.1.2), the compiler of the
# binjgb reference fixture. It is a Windows executable, so paths are passed
# through wslpath. Override with WASI_SDK=/path/to/wasi-sdk.
#
# Every guest links guests/common/eden_libc.c (compiled -ffreestanding) and
# the generated headers in guests/include. Target: wasm32 MVP plus sign-ext
# and mutable-globals (LLVM 18 generic), no WASI, no --export-all: the only
# exports are the world's (export_name attributes) and the memory.
#
# Usage: scripts/abi/build_guests.sh [--check] [guest ...]
#   --check  build into a temporary folder and fail if a result differs from
#            the committed guests/build/<name>.wasm
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
WASI_SDK="${WASI_SDK:-/mnt/d/Backups/WASI/wasi-sdk-24.0}"
CLANG="$WASI_SDK/bin/clang.exe"
if [[ ! -x "$CLANG" ]]; then
    echo "build_guests: clang not found at $CLANG (set WASI_SDK)" >&2
    exit 2
fi

check=0
guests=()
for a in "$@"; do
    case "$a" in
        --check) check=1 ;;
        *) guests+=("$a") ;;
    esac
done
if [[ ${#guests[@]} == 0 ]]; then
    guests=(abi_selftest binjgb)
fi

win() { wslpath -w "$1"; }

common_flags=(--target=wasm32 -O2 -nostdlib -std=gnu11 -Wall -Wno-unused-function
    "-I$(win "$repo/guests/common/include")" "-I$(win "$repo/guests/include")")
link_flags=(-Wl,--no-entry -Wl,-z,stack-size=262144 -Wl,--strip-debug)

out_dir="$repo/guests/build"
if [[ $check == 1 ]]; then
    out_dir="$(mktemp -d)"
fi
mkdir -p "$out_dir"
obj_dir="$(mktemp -d)"
trap 'rm -rf "$obj_dir"' EXIT

compile() {   # compile <out.o> <src.c> [extra flags...]
    local out="$1" src="$2"
    shift 2
    "$CLANG" "${common_flags[@]}" "$@" -c "$(win "$src")" -o "$(win "$out")"
}

build_guest() {
    local name="$1"
    local objs=()
    compile "$obj_dir/$name.libc.o" "$repo/guests/common/eden_libc.c" -ffreestanding -fno-builtin
    objs+=("$obj_dir/$name.libc.o")
    case "$name" in
        abi_selftest)
            compile "$obj_dir/selftest.o" "$repo/guests/abi_selftest/selftest.c"
            objs+=("$obj_dir/selftest.o")
            ;;
        binjgb)
            local up="$repo/guests/binjgb/upstream"
            for src in common emulator joypad; do
                compile "$obj_dir/bj_$src.o" "$up/$src.c" "-I$(win "$up")" -Wno-unused-variable -Wno-unused-but-set-variable
                objs+=("$obj_dir/bj_$src.o")
            done
            compile "$obj_dir/eden_binjgb.o" "$repo/guests/binjgb/eden_binjgb.c" "-I$(win "$up")"
            objs+=("$obj_dir/eden_binjgb.o")
            ;;
        *)
            echo "build_guests: unknown guest $name" >&2
            exit 2
            ;;
    esac
    local winobjs=()
    for o in "${objs[@]}"; do winobjs+=("$(win "$o")"); done
    "$CLANG" --target=wasm32 -nostdlib "${link_flags[@]}" "${winobjs[@]}" -o "$(win "$out_dir/$name.wasm")"
    echo "built $name.wasm ($(stat -c %s "$out_dir/$name.wasm") bytes)"
}

for g in "${guests[@]}"; do
    build_guest "$g"
done

if [[ $check == 1 ]]; then
    rc=0
    for g in "${guests[@]}"; do
        if ! cmp -s "$out_dir/$g.wasm" "$repo/guests/build/$g.wasm"; then
            echo "build_guests: guests/build/$g.wasm differs from a fresh build (rebuild and commit it)"
            rc=1
        fi
    done
    rm -rf "$out_dir"
    [[ $rc == 0 ]] && echo "build_guests: committed guests match the sources"
    exit $rc
fi

(cd "$repo/guests/build" && sha256sum ./*.wasm > SHA256SUMS)
echo "build_guests: guests/build/SHA256SUMS updated"
