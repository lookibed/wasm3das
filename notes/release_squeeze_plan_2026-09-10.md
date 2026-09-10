# Squeezing the release bundles: what was skipped, what it costs, what it gives

Date: 2026-09-10, after v0.3.0. The owner asked for everything the sources
allow on the shipped bundles, and for the standalone tier on every platform.
This note is the tracker: one row per item, the evidence behind it, and its
state. Update the state column in the PR that changes it.

Baseline (`tests/manual/fixture_report.md`, Ryzen 7 7435HS, 98 checks): wasm3 C
3.1 s; interpreter 1m45.7 s (start 0.18 s, 29x of C without startup); aot
2m07 s (0.65 s, 21x); aot_ctx 7.7 s (29 ms, 1.6x); jit at O0 1m42 s (0.86 s,
5.9x).

## A. Shipped and wrong or missing (fix first)

| # | Item | Evidence | Gain | Cost | State |
|---|---|---|---|---|---|
| A1 | The standalone binary has no stack protection when run without `scripts/wasm3-ctx`: the launcher raises `ulimit -s`, the release asset ships the bare binary, so an unbounded wasm recursion is a SIGSEGV instead of `[trap] stack overflow` | `scripts/wasm3-ctx` comment; `notes/native_aot_status.md`; the asset's README says "same command line" | correctness of the shipped asset on every platform | `native/standalone_main.cpp` runs `main` on a thread with an explicit 256 MiB stack (`pthread_attr_setstacksize`, `CreateThread dwStackSize`); no `ulimit`, no `editbin` | open |
| A2 | Standalone (`ctx`) exists for Linux x86_64 only, hand-built on the stand; Windows and arm64 bundles carry the interpreter tier only (29x, 0.2 s start) | release v0.3.0 assets | the best tier (1.6x, 29 ms) on every platform | arm64: `build_port.sh ctx` on the arm runner (daslang already built there). Windows: an MSVC arm in `build_port.sh` (`cl /O2 /EHsc /std:c++17`, link against `lib/Release/libDaScript*.lib`, `/STACK` if A1 is not done) | open |
| A3 | Release smoke is `fib` only | `release.yml` | catches a broken tier before it is published | spec suite on the ctx binary (20 s) and WASI (90 s) in `release.yml` for Linux x86_64; the interpreter bundle at least `fib64` REPL | open |
| A4 | The `aot` variant (not ctx) misses its AOT link on two ops (`op_Return`, `op_i32_Equal_rs`; `fastCall` decided per module, hash mismatch) and runs them interpreted, plus the front end at every start: 21x against ctx's 1.6x | `notes/native_aot_fastcall_2026-09-08.md`; agent run on the stand, `-aot-strict` error | an honest column, or one fewer variant | apply the one-line address workaround plus `-aot-strict` in `build_port.sh aot`, or retire the variant from scripts, harness and report | open |
| A5 | The interpreter bundle carries `lib/*.so` and an `LD_LIBRARY_PATH` launcher because the source-built `daslang` has an absolute RUNPATH | PR #38 | one binary, no library dance | a static `daslang` for the bundle, if daScript's CMake offers it (unverified) | open |
| A6 | Release builds have no cache: three cold daslang builds per tag (8–20 min each) | `release.yml` run for v0.3.0 | minutes instead of half an hour per release | `actions/cache` keyed like the gate's (pin + `build-daslang.sh` hash) | open |
| A7 | The pre-push hook gates the wrong tree from a git worktree: `core.hooksPath` is absolute, the hook derives `repo_root` from its own location and runs the gate over the main checkout (whatever state it is in) instead of the worktree being pushed; an agent had to push with `--no-verify` after running the gate by hand | B6 agent report | the hook means the same thing in a worktree as in the main checkout | `repo_root` from `git rev-parse --show-toplevel` in the hook's working directory (git runs hooks at the top of the worktree being pushed); `verify_daslang.sh` and `build-daslang.sh` unset the `GIT_DIR`/`GIT_WORK_TREE` a hook exports, which had made `git -C <daslang>` answer about this repository | done in the same PR as A1–A3, A6 |

## B. Speed on the same sources

| # | Item | Evidence | Gain (measured or hypothesis) | Cost | State |
|---|---|---|---|---|---|
| B1 | ctx links both `liblibDaScript.a` (the compiler) and `_runtime`, without `--gc-sections` or LTO: 52 MB, 37 MB stripped | `build_port.sh`, `ls -la` of the asset | **measured**: 52.8 → 45.8 MB, 37.5 → 30.5 MB stripped (−13 % / −19 %), process start 29 → 25 ms, fixture total 7.41 → 7.06 s (−4.8 %); execution itself unchanged | `-fno-pic -ffunction-sections -fdata-sections` + `-no-pie -Wl,--gc-sections` in `build_port.sh ctx` (with `-fcf-protection=none` on x86-64); LTO and a runtime-only link rejected, see the table under this section | done in PR #41 |
| B2 | ctx is generic x86-64 | `build_port.sh` flags | **measured: nothing**. `-march=x86-64-v3` on top of the B1 set: 7.13 s against 7.13 s without it; alone: 7.48 s against a 7.41 s baseline. No second asset | — | closed, not shipping |
| B3 | Strict aliasing not decided: the generated C++ and the port pun memory through pointer casts; all suites pass, but the flag set was copied without checking what daScript itself uses | `build_port.sh` cxxflags | daScript compiles **its own** sources with `-fno-strict-aliasing` under gcc (`CMakeCommon.txt` `SETUP_COMPILER`: "GNU uses strict aliasing optimizations too hard, which breaks our code"; `DAS_STRICT_ALIASING=OFF` in the stand's cache, and the pin's `compile_commands.json` shows it on every libDaScript TU). Adopted for ctx; measured neutral (7.41 s against 7.41 s) | — | done in PR #41 |
| B9 | The standalone binary links the whole compiler archive for one symbol: without `liblibDaScript.a` the link fails only on `register_Module_Ast`, which the emitted module table lists (`ast_core`, index 4) although nothing in the port requires `ast`; with an empty stub of that function the binary is 37.7 MB / 26.4 MB stripped and still passes the spec suite | B1 experiment on the stand | −15 MB more, faster load | a host-side stub in `native/` (measure spec, WASI, fixtures) or an upstream change so a standalone program registers only the modules it uses | open |
| B4 | Interpreter start (0.18–0.29 s) is the compile of `app/` + `source/` at every run; `-module-cache` parked on RC2 because it printed `deser: clean` to stdout; master after the pin carries startup work (#3960, #3971) | `notes/daslang_release_pin_2026-09-07.md` | interpreter start possibly several times lower, no port change | re-test `-module-cache` on the pin; check stdout hygiene with the WASI driver | open |
| B5 | Second expansion layer in the interpreter: the `OP_*` helpers of `m3_math_utils` and `m3MemData` in load/store ops through the same pre-infer macro | `notes/interp_node_cost_2026-09-08.md` (48 ns per function-value call) | 5–15 % on heavy rows (estimate from the first layer) | extend `m3_exec_expand.das`; gate, spec, fixtures | open |
| B6 | JIT runs at O0 because of #3991; the port-side workaround is `var` on every out-parameter and const pointer the callee writes through | `docs/upstream-status.md`, #3991 | measured at O3 on the stand (master `388691eb1`): the whole fixture set costs 8.7 s of exec against 85.2 s interpreted, 4.7 s ctx and 2.9 s C wasm3, i.e. 3.0x C and 1.8x ctx; warm JIT start 0.55 s per process, cold codegen 3.5 s | PR #40: `var` on the `M3RawCall` typedef (`_sp`, `_mem`) and every raw host function, on `m3ApiReturn_*`/`m3ApiWriteMem*`, `libc_mem*`, `wasi_fd_seek_common`, `m3_zero_bytes`/`m3_copy_bytes`, `EvaluateExpression`, `c_memmove`, the `ResizeMemory`/`CompileFunction` bridges; daslang only adds constness through a pointer, so the only ways to write through a non-`var` parameter are `reinterpret`/`intptr`/`addr`/`memcpy`, which bounded the audit | done in PR #40 (gate green; O3 spec 17863/17863, WASI 12/12, fixtures 86/86); the harness default stays O0 until #3991 is fixed upstream |
| B7 | JIT start 0.86 s per process; upstream PR #3982 (merged) cuts the warm start (hello world 240 → 90 ms) | agent runs; upstream PR | JIT full-time column comparable with ctx | pin bump to current master (105 commits), full gate and fixture rerun | pin bumped to `388691eb1` 2026-09-10 (gate green unchanged); JIT start to be re-measured |
| B8 | `-exe` never tried: the JIT's standalone executable, no compiler at start, cross-platform through LLVM | daslang docs, maintainer's advice | potentially the fastest tier on every platform | needs B6 (O3 correctness) first; then `daslang -exe -output <out> app/wasm3.das`, spec, WASI, fixtures | open |

### B1–B3 measurements (2026-09-10, stand, gcc 11.4, daslang master 388691eb1)

One `scripts/build_port.sh ctx tmp/native-ctx-<variant>` per row, driven by
`EXTRA_CXXFLAGS`/`EXTRA_LDFLAGS`. Every row prints `Result: 832040` for
`fib32.wasm --func fib 30` and passes the spec suite 17863/17863 through
`WASM3DAS_CTX=<binary> scripts/wasm3-ctx --repl`. Time is the aot_ctx "Итого"
of `tests/manual/run_fixtures.py --runtimes wasm3,aot_ctx` (98 checks),
arithmetic mean of four runs; the C wasm3 reference stayed at 3.02–3.09 s
across all of them.

| variant | flags | unstripped | stripped | total | start |
|---|---|---:|---:|---:|---:|
| base | as shipped | 52.83 MB | 37.54 MB | 7.41 s | 29 ms |
| gcs | `-ffunction-sections -fdata-sections -Wl,--gc-sections` | 52.70 MB | 37.44 MB | 7.36 s | 28 ms |
| nopie | `-fno-pic -no-pie` | 45.92 MB | 30.62 MB | 7.22 s | 25 ms |
| v3 | `-march=x86-64-v3` | 52.86 MB | 37.56 MB | 7.48 s | 28 ms |
| nsa | `-fno-strict-aliasing` | 52.84 MB | 37.54 MB | 7.41 s | 28 ms |
| cfnone | `-fcf-protection=none` | 52.81 MB | 37.52 MB | 7.35 s | 28 ms |
| lto | `-flto=2` | 52.82 MB | 37.51 MB | 7.49 s | 29 ms |
| combo1 | nopie + gcs + cfnone | 45.78 MB | 30.52 MB | 7.13 s | 25 ms |
| **combo2** | **combo1 + nsa (shipped)** | **45.79 MB** | **30.53 MB** | **7.06 s** | **25 ms** |
| combo3 | combo1 + `-march=x86-64-v3` | 45.80 MB | 30.54 MB | 7.13 s | 26 ms |

The shipped set was then rebuilt from the branch itself (no `EXTRA_*`
overrides): the same 45,785,904 bytes, `Result: 832040`, spec 17863/17863,
`run-wasi-test.py` 12/12 and 7.09 s / 7.02 s against 7.55 s / 7.42 s for two
interleaved baseline runs.

Run-to-run spread of the total is ±0.1 s, so only the ~0.35 s of the combined
set and the 4 ms of start are outside the noise. The "without startup" column
of the report moves the other way for `nopie` (4.75 s against 4.60 s) because
it is derived as `total − start × rows`: a smaller start pushes the same time
into the estimate. Execution proper is flat; the whole win is image size and
relocation processing, which is what a 98-process fixture set rewards.

Two negative results worth keeping: LTO buys nothing (two translation units
already, and the daslang archives are not built with IPO: `SETUP_LTO` is
applied to the shared library and the `daslang` binary, not to
`liblibDaScript*.a`); and the compiler archive cannot be dropped by a link
flag, see B9.

## C. Blind spots in the measurements

- No numbers from Windows or arm64 (only "fib works"); no `-exe`; no JIT O3;
  one stand. Add a per-platform fixture run to the release checklist once A2
  ships the tiers.

## Order

1. A1, A2, A3, A6 (repairs what is already shipped; one PR for the host stub
   and the workflow, the Windows arm may follow).
2. B6 then B8 (the only candidates to beat ctx), with B7 as the pin bump
   before B8.
3. B1, B4 (cheap, measurable).
4. B5.
5. A4, A5, B2, B3.
