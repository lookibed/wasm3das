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
# CMakeCommon.txt, Release on unix: -O3 -fno-rtti -fomit-frame-pointer
# -fno-stack-protector -DNDEBUG=1 -std=gnu++17 -fPIC -fwrapv
# -fno-strict-aliasing under gcc, DAS_FUSION=2, DAS_NO_ASSERTIONS), plus the
# standalone-executable flags of the ctx variant below.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo_root/scripts/verify_daslang.sh" >/dev/null
# MSVC: Git bash on a Windows runner with the Visual Studio environment
# loaded (cl on PATH). daScript's multi-config build puts its outputs under
# bin/Release and lib/Release, and the object and link commands differ.
msvc=0
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) if command -v cl >/dev/null 2>&1; then msvc=1; fi ;;
esac
if (( msvc )); then
    DASLANG="${DASLANG:-$DASLANG_ROOT/bin/Release/daslang.exe}"
    CXX=cl
else
    DASLANG="${DASLANG:-$DASLANG_ROOT/bin/daslang}"
    CXX="${CXX:-$(command -v clang++ || command -v g++)}"
fi
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

ldflags=()
if (( msvc )); then
    # The same defines as the gcc/clang set; /MD matches daScript's default
    # DAS_USE_STATIC_STD_LIBS=OFF; /bigobj because the ctx translation unit is
    # one file with the whole port in it; /EHsc as daScript's own targets.
    cxxflags=(/nologo /std:c++17 /O2 /Ob2 /EHsc /GR- /MD /bigobj /W0
              /DNDEBUG=1 /DDAS_ENABLE_DYN_INCLUDES=1 /DDAS_FUSION=2 /DDAS_NO_ASSERTIONS /DSIZE_OF_VOID_P=8
              /DURIPARSER_BUILD_CHAR /DURI_STATIC_BUILD /D_CRT_SECURE_NO_WARNINGS
              "/I$(cygpath -w "$DASLANG_ROOT/include")")
else
    # The per-variant flags (-fPIC for aot, the standalone set for ctx) are
    # added below, after the variant is known.
    cxxflags=(-std=gnu++17 -O3 -fno-rtti -fomit-frame-pointer -fno-stack-protector -fwrapv
              -DNDEBUG=1 -DDAS_ENABLE_DYN_INCLUDES=1 -DDAS_FUSION=2 -DDAS_NO_ASSERTIONS -DSIZE_OF_VOID_P=8
              -DURIPARSER_BUILD_CHAR -DURI_STATIC_BUILD
              -Wno-invalid-offsetof -Wno-unused-parameter -Wno-unused-variable -Wno-unused-but-set-variable
              -I"$DASLANG_ROOT/include")
fi
# A source checkout keeps the fmt and uriparser headers under 3rdparty/ and
# generated headers under build/; the built-in-place checkout exports
# everything under include/, so these are optional.
for inc in "$DASLANG_ROOT/3rdparty/fmt/include" "$DASLANG_ROOT/3rdparty/uriparser/include" "$DASLANG_ROOT/build/include"; do
    if [[ -d "$inc" ]]; then
        if (( msvc )); then cxxflags+=("/I$(cygpath -w "$inc")"); else cxxflags+=(-I"$inc"); fi
    fi
done

# Per-variant flags. Everything below the aot line was measured on the release
# stand (Ryzen 7 7435HS, gcc 11.4, daslang master 388691eb1): every variant
# passes the spec suite 17863/17863 and fib32; the timings are the aot_ctx
# "Итого" of tests/manual/run_fixtures.py (98 checks), four runs per variant,
# baseline 7.41 s total / 29 ms start. See
# notes/release_squeeze_plan_2026-09-10.md, B1-B3. gcc/clang only; the MSVC
# arm keeps cl's own set (the equivalents were not measured there).
if (( msvc )); then variant_flags=skip; else variant_flags="$variant"; fi
case "$variant_flags" in
aot)
    # Unchanged: this variant compiles one TU per module and was not part of
    # the B1 measurement, so it keeps the flag set it was validated with.
    cxxflags+=(-fPIC)
    ;;
ctx)
    # -fno-pic/-no-pie: the standalone binary is an executable that is never
    #   dlopen'ed, so the PIE indirection buys nothing. It deletes the 7 MB
    #   .rela.dyn: 52.8 -> 45.9 MB, 37.5 -> 30.6 MB stripped, and the process
    #   start drops 29 -> 25 ms (-13 %), which is 0.3 s of the fixture total.
    #   The cost is ASLR of the image itself (stack, heap and the shared libc
    #   stay randomized); drop these two flags to get it back.
    # -ffunction-sections -fdata-sections + --gc-sections: -137 KB (0.3 %).
    #   Small because the two TUs of this build are already whole-program and
    #   the daslang archives are not compiled with section splitting; free at
    #   runtime (7.36 s vs 7.41 s, inside the noise).
    # -fno-strict-aliasing: what daScript compiles its own sources with under
    #   gcc (CMakeCommon.txt SETUP_COMPILER, "GNU uses strict aliasing
    #   optimizations too hard, which breaks our code"). The emitted context
    #   is generated code over the same headers and the same vec4f punning, so
    #   the build now states the assumption instead of inheriting the default.
    #   Measured neutral: 7.41 s standalone against a 7.41 s baseline.
    # -fcf-protection=none (x86-64 only): removes the endbr64 landing pad in
    #   front of every indirect branch target. The RunLoop dispatch is one
    #   indirect call per wasm operation, so this is the only flag here that
    #   touches execution: 7.35 s vs 7.41 s (-0.9 %). It gives up the CET
    #   indirect-branch tracking the distro gcc enables by default.
    cxxflags+=(-fno-pic -ffunction-sections -fdata-sections -fno-strict-aliasing)
    ldflags+=(-no-pie -Wl,--gc-sections)
    if [[ "$(uname -m)" == "x86_64" ]]; then
        cxxflags+=(-fcf-protection=none)
    fi
    # Together: 45.8 MB / 30.5 MB stripped and 7.06 s against the baseline's
    # 52.8 MB / 37.5 MB and 7.41 s (-13 % size, -19 % stripped, -4.8 % total,
    # execution itself unchanged).
    #
    # Measured and rejected: -flto (no size change, 7.49 s), -march=x86-64-v3
    # (7.13 s against 7.13 s for the same set without it, B2). Dropping
    # liblibDaScript.a from the link fails on one symbol, register_Module_Ast,
    # which the emitted module table of the standalone context references.
    ;;
esac

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

if (( msvc )); then
    # One compile at a time (the ctx variant has one unit plus the stub);
    # objects are .obj, paths are Windows paths for cl and link.
    if [[ "$variant" != "ctx" ]]; then
        echo "build_port: the aot variant has no MSVC arm; use ctx" >&2
        exit 2
    fi
    rm -f "$out"/obj/*.obj
    # cl.exe and link.exe by their full names: Git bash puts coreutils' `link`
    # (the hard-link tool) ahead of MSVC's on PATH.
    cl.exe "${cxxflags[@]}" "/I$(cygpath -w "$out/ctx")" /c "$(cygpath -w "$repo_root/native/standalone_main.cpp")" \
        "/Fo$(cygpath -w "$out/obj/standalone_main.cpp.obj")"
    for src in "${sources[@]}"; do
        cl.exe "${cxxflags[@]}" /c "$(cygpath -w "$src")" "/Fo$(cygpath -w "$out/obj/$(basename "$src").obj")"
    done
    echo "build_port [$variant]: link (MSVC)"
    objs=()
    for o in "$out"/obj/*.obj; do objs+=("$(cygpath -w "$o")"); done
    libdir="$DASLANG_ROOT/lib/Release"
    # The system libraries are the set daScript's CMake links into every
    # library target on Windows (dbghelp ws2_32 mswsock advapi32 rpcrt4).
    link.exe /nologo "/OUT:$(cygpath -w "$out/bin/wasm3das.exe")" "${objs[@]}" \
        "$(cygpath -w "$libdir/libDaScript.lib")" "$(cygpath -w "$libdir/libDaScript_runtime.lib")" \
        "$(cygpath -w "$libdir/libUriParser.lib")" \
        dbghelp.lib ws2_32.lib mswsock.lib advapi32.lib rpcrt4.lib
    binary="$out/bin/wasm3das.exe"
else
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
    "$CXX" ${ldflags[@]+"${ldflags[@]}"} ${extra_ldflags[@]+"${extra_ldflags[@]}"} \
        -o "$out/bin/wasm3das" "$out"/obj/*.o \
        "$DASLANG_ROOT/lib/liblibDaScript.a" "$DASLANG_ROOT/lib/liblibDaScript_runtime.a" \
        "$DASLANG_ROOT/lib/liblibUriParser.a" \
        -lpthread -ldl -lm
    binary="$out/bin/wasm3das"
fi

# Runtime layout beside the binary: daslib for the compiler, app and source
# for the startup compile (the ctx variant runs no startup compile; the
# layout costs nothing and keeps both binaries in the same shape).
rm -rf "$out/daslib" "$out/app" "$out/source"
cp -R "$DASLANG_ROOT/daslib" "$out/daslib"
cp -R "$repo_root/app" "$out/app"
cp -R "$repo_root/source" "$out/source"
ls -la "$binary"
echo "build_port [$variant]: $binary"
