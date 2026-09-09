#!/usr/bin/env bash
# Build the native wasm3das binaries. Two variants:
#
#   aot   every module of the port AOTs to C++, compiled and linked with
#         native/wasm3das_main.cpp and the static libDaScript of the
#         DASLANG_ROOT checkout. The native host still compiles app/wasm3.das
#         and source/ at every startup; only the execution is native.
#         -> default out: tmp/native (tmp/native/bin/wasm3das)
#
#   ctx   the standalone context: daslang emits the compiled program
#         (<out>/ctx/wasm3.das.cpp + .h), compiled and linked with
#         native/standalone_main.cpp the same way. The context is baked in
#         and the daslang front end never runs at startup.
#         -> default out: tmp/native-ctx (tmp/native-ctx/bin/wasm3das)
#
# Usage: scripts/build_port.sh [aot|ctx] [out]
#   out  the directory the binary tree lands in (default per variant above)
#
# Both variants need:
#   DASLANG_ROOT  the daslang checkout pinned in scripts/daslang_pin, built
#                 in place (verified through scripts/verify_daslang.sh)
#   CXX           C++ compiler (default: clang++, else g++)
#   JOBS          parallel compile jobs (default: nproc)
#   EXTRA_CXXFLAGS, EXTRA_LDFLAGS  appended to each compile and link line
#
# The C++ flags are the ones libDaScript itself is built with (daScript
# CMake: -O3 -fno-rtti -fwrapv -std=gnu++17, DAS_FUSION=2).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo_root/scripts/verify_daslang.sh" >/dev/null
DASLANG="${DASLANG:-$DASLANG_ROOT/bin/daslang}"
CXX="${CXX:-$(command -v clang++ || command -v g++)}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
cd "$repo_root"

variant="${1:-aot}"
out_base="${2:-}"
case "$variant" in
    aot) def_out="tmp/native" ;;
    ctx) def_out="tmp/native-ctx" ;;
    *) echo "build_port: unknown variant '$variant' (aot|ctx)" >&2; exit 2 ;;
esac
out="$repo_root/${out_base:-$def_out}"
mkdir -p "$out/aot" "$out/obj" "$out/bin"

cxxflags=(-std=gnu++17 -O3 -fno-rtti -fomit-frame-pointer -fno-stack-protector -fwrapv -fPIC
          -DNDEBUG=1 -DDAS_ENABLE_DYN_INCLUDES=1 -DDAS_FUSION=2 -DDAS_NO_ASSERTIONS -DSIZE_OF_VOID_P=8
          -DURIPARSER_BUILD_CHAR -DURI_STATIC_BUILD
          -Wno-invalid-offsetof -Wno-unused-parameter -Wno-unused-variable -Wno-unused-but-set-variable
          -I"$DASLANG_ROOT/include")
# A source checkout keeps the fmt and uriparser headers under 3rdparty/ and
# generated headers under build/; the built-in-place checkout exports
# everything under include/, so these are optional.
for inc in "$DASLANG_ROOT/3rdparty/fmt/include" "$DASLANG_ROOT/3rdparty/uriparser/include" "$DASLANG_ROOT/build/include"; do
    if [[ -d "$inc" ]]; then cxxflags+=(-I"$inc"); fi
done
extra_ldflags=()
if [[ -n "${EXTRA_CXXFLAGS:-}" ]]; then read -r -a extra_cxx <<< "$EXTRA_CXXFLAGS"; cxxflags+=("${extra_cxx[@]}"); fi
if [[ -n "${EXTRA_LDFLAGS:-}" ]]; then read -r -a extra_ldflags <<< "$EXTRA_LDFLAGS"; fi

case "$variant" in
aot)
    # 1. AOT: one C++ translation unit per module, inputs spelled relative to
    #    the repository root, exactly as the host compiles them at startup.
    echo "build_port [aot]: AOT"
    aot_args=()
    for f in app/wasm3.das source/*.das; do
        aot_args+=(-aot "$f" "$out/aot/$(basename "$f").cpp")
    done
    "$DASLANG" "$DASLANG_ROOT/utils/aot/main.das" -- "${aot_args[@]}" \
        | grep -v "shared_module\|failed to load\|^\s*$" || true

    # 2. Compile: the host of native/wasm3das_main.cpp plus the AOT units.
    echo "build_port [aot]: compile ($CXX, $JOBS jobs)"
    sources=("$repo_root/native/wasm3das_main.cpp" "$out"/aot/*.cpp)
    ;;
ctx)
    # 1. Emit: the compiled program as one standalone-context translation unit.
    echo "build_port [ctx]: emit the standalone context"
    mkdir -p "$out/ctx"
    "$DASLANG" "$DASLANG_ROOT/utils/aot/main.das" -- -ctx app/wasm3.das "$out/ctx" \
        | grep -v "shared_module\|failed to load\|^\s*$" || true
    if [[ ! -f "$out/ctx/wasm3.das.cpp" ]]; then
        echo "build_port [ctx]: the emission produced no context" >&2
        exit 1
    fi

    # 2. Compile: the emittedTU plus the host stub.
    echo "build_port [ctx]: compile"
    sources=("$out/ctx/wasm3.das.cpp")
    ;;
esac

rm -f "$out"/obj/*.o
if [[ "$variant" == "ctx" ]]; then
    "$CXX" "${cxxflags[@]}" -I"$out/ctx" -c "$repo_root/native/standalone_main.cpp" -o "$out/obj/standalone_main.cpp.o" &
    stub_pid=$!
    wait "$stub_pid"
fi
pids=()
for src in "${sources[@]}"; do
    "$CXX" "${cxxflags[@]}" -c "$src" -o "$out/obj/$(basename "$src").o" &
    pids+=($!)
    if (( ${#pids[@]} >= JOBS )); then
        wait "${pids[0]}" || true
        pids=("${pids[@]:1}")
    fi
done
wait
for src in "${sources[@]}"; do
    if [[ ! -f "$out/obj/$(basename "$src").o" ]]; then
        echo "build_port: compile failed for $src" >&2
        exit 1
    fi
done

echo "build_port [$variant]: link"
"$CXX" ${extra_ldflags[@]+"${extra_ldflags[@]}"} -o "$out/bin/wasm3das" "$out"/obj/*.o \
    "$DASLANG_ROOT/lib/liblibDaScript.a" "$DASLANG_ROOT/lib/liblibDaScript_runtime.a" \
    "$DASLANG_ROOT/lib/liblibUriParser.a" \
    -lpthread -ldl -lm

# Runtime layout beside the binary: daslib for the compiler, app and source
# for the startup compile (the ctx variant runs no startup compile; the
# layout costs nothing and keeps both binaries in the same shape).
rm -rf "$out/daslib" "$out/app" "$out/source"
cp -R "$DASLANG_ROOT/daslib" "$out/daslib"
cp -R "$repo_root/app" "$out/app"
cp -R "$repo_root/source" "$out/source"
ls -la "$out/bin/wasm3das"
echo "build_port [$variant]: $out/bin/wasm3das"
