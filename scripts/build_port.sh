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
#         and the daslang front end never runs at startup. The emitter runs
#         from tmp/dasroot-ctx, an overlay of DASLANG_ROOT with the emitter
#         patches of notes/upstream_cases/ctx_*.patch that DASLANG_ROOT does
#         not carry yet applied to a copy of daslib/ (pending in the fork;
#         WASM3DAS_CTX_EMITTER=stock builds without them).
#         -> default out: tmp/native-ctx (tmp/native-ctx/bin/wasm3das)
#
#   exe   daslang's own standalone executable: `daslang -exe` runs the LLVM
#         JIT pipeline once, ahead of time, over app/wasm3.das and links the
#         result against the shared daslang runtime (lib/liblibDaScriptDyn*.so
#         of DASLANG_ROOT, found through the rpath the linker records). No C++
#         compiler is involved and no daslang front end runs at start. Needs a
#         DASLANG_ROOT built with dasLLVM (DAS_LLVM_DISABLED=OFF).
#         -> default out: tmp/native-exe (tmp/native-exe/bin/wasm3das.exe;
#            daslang names the output with the suffix on every platform)
#
# Usage: scripts/build_port.sh [aot|ctx|exe] [out]
#   out  the directory the binary tree lands in (default per variant above)
#
# All variants need:
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
    exe) def_out="tmp/native-exe" ;;
    *) echo "build_port: unknown variant '$variant' (aot|ctx|exe)" >&2; exit 2 ;;
esac
out="$repo_root/${out_base:-$def_out}"

if [[ "$variant" == "exe" ]]; then
    # The exe variant is daslang's job end to end: the JIT daslib compiles
    # the program, LLVM emits one object and daslang links it. The DLL cache
    # (.jitted_scripts/ under the working directory) is not involved; every
    # build regenerates the code, about ten seconds plus the codegen.
    mkdir -p "$out/bin"
    echo "build_port [exe]: daslang -exe"
    (cd "$out" && "$DASLANG" -exe "$repo_root/app/wasm3.das" -output "$out/bin/wasm3das") \
        | grep -v "shared_module\|failed to load\|^\s*$" || true
    binary="$out/bin/wasm3das.exe"
    if [[ ! -x "$binary" ]]; then
        echo "build_port [exe]: daslang -exe produced no executable at $binary" >&2
        exit 1
    fi
    rm -f "$out/bin/wasm3das.o"
    ls -la "$binary"
    echo "build_port [exe]: $binary"
    exit 0
fi

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
# docs/native-build.md, section 4. gcc/clang only; the MSVC
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
    # 0. The emitter patches (docs/upstream-status.md, the `-ctx` rows;
    #    docs/native-build.md, section 7). Two changes to daslang's `-ctx`
    #    emitter the port depends on, each a patch under notes/upstream_cases/
    #    with a marker string that says whether DASLANG_ROOT already carries it:
    #      ctx_direct_calls.patch  stock daslang emits every call into a
    #          required module as a Context::fnByMangledName lookup plus
    #          das_invoke_function although the context defines the callee
    #          inline in the same unit; the patch calls it directly
    #          (marker: directForeign)
    #      ctx_used_modules.patch  stock daslang registers every default C++
    #          module the compiler loaded, so the binary pays the constructors
    #          of rtti_core and ast_core (loaded for a compile-time macro) at
    #          every start; the patch registers the used modules and their
    #          dependencies only (marker: the comment line of the patch)
    #    Neither is accepted in the daslang fork yet (submitted 2026-09-21,
    #    review pending; the first is applied in the owner's working tree).
    #    A patch the dasroot lacks is applied to a private overlay under tmp/,
    #    DASLANG_ROOT itself is never written: every top-level entry of the
    #    overlay is a symlink into DASLANG_ROOT except daslib/, a copy with the
    #    patched files. Only the AOT tool reads daslib, so the binary is
    #    stock. Rollback is one variable: WASM3DAS_CTX_EMITTER=stock emits
    #    with the unpatched dasroot. A patch the fork has taken is skipped
    #    automatically through its marker.
    emit_root="$DASLANG_ROOT"
    if [[ "${WASM3DAS_CTX_EMITTER:-patched}" == "stock" ]]; then
        echo "build_port [ctx]: emitter: stock dasroot (WASM3DAS_CTX_EMITTER=stock)"
    else
        pending=()
        grep -q 'directForeign' "$DASLANG_ROOT/daslib/aot_cpp.das" \
            || pending+=(ctx_direct_calls.patch)
        grep -q 'a default C++ module the runtime program never reaches' "$DASLANG_ROOT/daslib/aot_cpp.das" \
            || pending+=(ctx_used_modules.patch)
        if (( ${#pending[@]} == 0 )); then
            echo "build_port [ctx]: emitter: dasroot already carries both emitter patches"
        else
            emit_root="$repo_root/tmp/dasroot-ctx"
            echo "build_port [ctx]: emitter: overlay $emit_root with ${pending[*]}"
            rm -rf "$emit_root"
            mkdir -p "$emit_root"
            for entry in "$DASLANG_ROOT"/* "$DASLANG_ROOT"/.[!.]*; do
                [[ -e "$entry" ]] || continue
                name="$(basename "$entry")"
                [[ "$name" == "daslib" ]] && continue
                ln -s "$entry" "$emit_root/$name"
            done
            cp -R "$DASLANG_ROOT/daslib" "$emit_root/daslib"
            for p in "${pending[@]}"; do
                if ! patch -p1 -s -d "$emit_root" < "$repo_root/notes/upstream_cases/$p"; then
                    echo "build_port [ctx]: $p does not apply to $DASLANG_ROOT/daslib; set WASM3DAS_CTX_EMITTER=stock or refresh the patch" >&2
                    exit 1
                fi
            done
        fi
    fi

    # 1. Emit: the compiled program as one standalone-context translation unit.
    echo "build_port [ctx]: emit the standalone context"
    mkdir -p "$out/ctx"
    DAS_ROOT="$emit_root" "$DASLANG" -dasroot "$emit_root" "$emit_root/utils/aot/main.das" -- -ctx app/wasm3.das "$out/ctx" \
        | grep -v "shared_module\|failed to load\|^\s*$" || true
    echo "build_port [ctx]: $(grep -c fnByMangledName "$out/ctx/wasm3.das.cpp" || true) Context lookups in the emitted unit (310 with the patch, 1734 stock)"
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
    # (the hard-link tool) ahead of MSVC's on PATH. And no MSYS path
    # conversion for their arguments: Git bash rewrites every `/flag` into
    # `C:/Program Files/Git/flag` (cl then warns D9024 per flag and link fails
    # with LNK1181 on nologo.obj); the paths here are already Windows paths.
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
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
    # Git ships /usr/bin/link.exe (coreutils) as well, so even link.exe by name
    # is the wrong tool; the MSVC linker is taken from the Visual Studio
    # environment (VCToolsInstallDir, set by vcvars / msvc-dev-cmd).
    if [[ -n "${VCToolsInstallDir:-}" ]]; then
        linker="$(cygpath -u "$VCToolsInstallDir")/bin/Hostx64/x64/link.exe"
    else
        linker="$(where.exe link.exe 2>/dev/null | tr -d '\r' | grep -i 'MSVC' | head -1 || true)"
        [[ -n "$linker" ]] && linker="$(cygpath -u "$linker")"
    fi
    if [[ -z "$linker" || ! -f "$linker" ]]; then
        echo "build_port: MSVC link.exe not found (VCToolsInstallDir='${VCToolsInstallDir:-}')" >&2
        exit 2
    fi
    "$linker" /nologo "/OUT:$(cygpath -w "$out/bin/wasm3das.exe")" "${objs[@]}" \
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
