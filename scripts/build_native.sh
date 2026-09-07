#!/usr/bin/env bash
# Build the native wasm3das binary: AOT-compile every Daslang module of the
# port to C++ with the daslang release bundle, then compile and link them
# together with native/wasm3das_main.cpp and the bundle's static libDaScript.
#
# Usage: scripts/build_native.sh [out-dir]      (default: tmp/native)
# Environment:
#   DASLANG_ROOT  the installed release bundle with include/, lib/liblibDaScript.a
#                 and utils/aot/main.das (default: tmp/daslang, from
#                 scripts/install_daslang.sh)
#   DASLANG       the daslang binary (default: $DASLANG_ROOT/bin/daslang)
#   CXX           C++ compiler (default: clang++, else g++)
#   JOBS          parallel compile jobs (default: nproc)
#   EXTRA_CXXFLAGS, EXTRA_LDFLAGS  appended to the compile and link lines
#                 (for example -g -fsanitize=address for a crash trace)
#
# The result is <out-dir>/bin/wasm3das plus the daslib/, app/ and source/
# it needs beside it (daslang resolves daslib relative to the executable, and
# the host compiles app/wasm3.das at startup; only the execution is native).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DASLANG_ROOT="${DASLANG_ROOT:-$repo_root/tmp/daslang}"
DASLANG="${DASLANG:-$DASLANG_ROOT/bin/daslang}"
CXX="${CXX:-$(command -v clang++ || command -v g++)}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
out="${1:-$repo_root/tmp/native}"

for f in "$DASLANG" "$DASLANG_ROOT/utils/aot/main.das" "$DASLANG_ROOT/lib/liblibDaScript.a" \
         "$DASLANG_ROOT/lib/liblibDaScript_runtime.a" "$DASLANG_ROOT/lib/liblibUriParser.a"; do
    if [[ ! -e "$f" ]]; then
        echo "build_native: missing $f (run scripts/install_daslang.sh)" >&2
        exit 1
    fi
done

mkdir -p "$out/aot" "$out/obj" "$out/bin"
cd "$repo_root"

# 1. AOT: one C++ translation unit per module, inputs spelled relative to the
#    repository root, exactly as the host compiles them at startup.
echo "build_native: AOT"
aot_args=()
for f in app/wasm3.das source/*.das; do
    aot_args+=(-aot "$f" "$out/aot/$(basename "$f").cpp")
done
"$DASLANG" "$DASLANG_ROOT/utils/aot/main.das" -- "${aot_args[@]}" \
    | grep -v "shared_module\|failed to load\|^\s*$" || true

# 2. Compile, with the flags libDaScript itself is built with (see daScript's
#    CMake: -O3 -fno-rtti -fwrapv -std=gnu++17, DAS_FUSION=2).
echo "build_native: compile ($CXX, $JOBS jobs)"
cxxflags=(-std=gnu++17 -O3 -fno-rtti -fomit-frame-pointer -fno-stack-protector -fwrapv -fPIC
          -DNDEBUG=1 -DDAS_ENABLE_DYN_INCLUDES=1 -DDAS_FUSION=2 -DDAS_NO_ASSERTIONS -DSIZE_OF_VOID_P=8
          -DURIPARSER_BUILD_CHAR -DURI_STATIC_BUILD
          -Wno-invalid-offsetof -Wno-unused-parameter -Wno-unused-variable -Wno-unused-but-set-variable
          -I"$DASLANG_ROOT/include")
# A source checkout keeps the fmt and uriparser headers under 3rdparty/ and
# generated headers under build/; the release bundle installs everything it
# exports under include/, so these are optional.
for inc in "$DASLANG_ROOT/3rdparty/fmt/include" "$DASLANG_ROOT/3rdparty/uriparser/include" "$DASLANG_ROOT/build/include"; do
    if [[ -d "$inc" ]]; then cxxflags+=(-I"$inc"); fi
done
if [[ -n "${EXTRA_CXXFLAGS:-}" ]]; then read -r -a extra_cxx <<< "$EXTRA_CXXFLAGS"; cxxflags+=("${extra_cxx[@]}"); fi
ldflags=()
if [[ -n "${EXTRA_LDFLAGS:-}" ]]; then read -r -a ldflags <<< "$EXTRA_LDFLAGS"; fi

sources=("$repo_root/native/wasm3das_main.cpp" "$out"/aot/*.cpp)
rm -f "$out"/obj/*.o
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
        echo "build_native: compile failed for $src" >&2
        exit 1
    fi
done

# 3. Link.
echo "build_native: link"
"$CXX" ${ldflags[@]+"${ldflags[@]}"} -o "$out/bin/wasm3das" "$out"/obj/*.o \
    "$DASLANG_ROOT/lib/liblibDaScript.a" "$DASLANG_ROOT/lib/liblibDaScript_runtime.a" \
    "$DASLANG_ROOT/lib/liblibDaScript.a" "$DASLANG_ROOT/lib/liblibUriParser.a" \
    -lpthread -ldl -lm

# 4. Runtime layout beside the binary: daslib for the compiler, app and
#    source for the startup compile.
rm -rf "$out/daslib" "$out/app" "$out/source"
cp -R "$DASLANG_ROOT/daslib" "$out/daslib"
cp -R "$repo_root/app" "$out/app"
cp -R "$repo_root/source" "$out/source"
ls -la "$out/bin/wasm3das"
echo "build_native: $out/bin/wasm3das"
