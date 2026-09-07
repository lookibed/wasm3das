# Engine benchmark: wasmtime, C wasm3, the port interpreted, `-jit`, native

Measured 2026-09-06 on the working tree at `7d73328` plus the uncommitted
changes of the three parallel sessions. Everything below is reproducible with
`scripts/bench.sh`.

## Summary

Running the port under the daslang LLVM JIT makes the interpreter loop **17x
faster** and brings it to **7.3x of C wasm3** on `fib(35)`, against 127x
interpreted. That is the good news, and it is the number the JIT question was
asked about.

The bad news is equally definite: **`daslang -jit` does not execute the port
correctly today.** The four `wasm3c/test/lang` fib fixtures give the right
answer, but the WASI `--fast` suite goes from 7/7 interpreted to 0/7 under
`-jit`. Three separate defects had to be fixed before `-jit` produced a running
program at all, two of them in daslang itself. The JIT figures in this note are
therefore an upper bound on what a correct JIT run would cost, not a validated
result.

Two further costs decide where the JIT can be used at all:

- `-jit` adds a **fixed ~7.5 s to every process start**, even for a six-line
  script, because the LLVM JIT daslib is compiled from source on each run.
- The port's own code generation is 9.0 s (904 functions) on a cold cache and
  0.2 s on a warm one, so a warm JIT start is 9.8 s against 2.3 s interpreted.

Nothing that spawns one short-lived `wasm3` process per case - the spec suite,
the WASI driver, `scripts/gate.sh` - can pay 9.8 s per process. The JIT is a
long-run tool: it wins from roughly `fib(31)` upward, and it would win
immediately in a persistent process, which is what an AOT/native build
(`tmp/native/`) is really after.

## Machine

- Intel(R) Core(TM) i5-6200U CPU @ 2.30GHz, 4 threads
- Linux 6.12.107+deb13-amd64, 8 GB RAM
- Nothing else was running during the measured rows.

## Engines

| name in `bench.sh` | what it is |
|---|---|
| `wasmtime` | `tools/bin/wasmtime`, wasmtime 48.0.1 (LLVM AOT) |
| `wasm3-c` | `tools/bin/wasm3`, the C reference built from `wasm3c/` |
| `wasm3das-interp` | the port through `scripts/wasm3` on the pinned `tmp/daslang-toolchain/bin/daslang` |
| `wasm3das-jit` | the port through `scripts/wasm3` with `WASM3DAS_JIT=1` on `tmp/daslang-jit/bin/daslang`, warm DLL cache |
| `wasm3das-jit-nocache` | the same with `-jit-no-cache`: full LLVM code generation on every process start |
| `wasm3das-native` | `tmp/native/bin/wasm3das` through `scripts/wasm3-native` |

`tmp/daslang-jit` is a worktree of the same pinned commit
`1524b3bf62e7decbfe530dc5f2e794b296fa1e68` as the gate toolchain, built with
`-DDAS_LLVM_DISABLED=OFF` and clang/Ninja. It is a **dynamic** build
(`bin/daslang` is 87 KB against `lib/liblibDaScriptDyn*.so` and `lib/LLVM.dll`,
the prebuilt LLVM 22.1.5 that cmake downloads from the daScript release
`llvm-v22.1.5`); the DLL cache below only works in a dynamic build, because
`llvm_jit_run.das` gates it on `das_is_dll_build()`.

## Final tree: RunLoop dispatch, AOT fixes, native build

Re-measured on the idle machine after the three parallel sessions landed
(`notes/exec_trampoline_design.md`, `notes/native_aot_status.md`), same
`scripts/bench.sh`, median of 3, wall clock from process start to exit:

| engine | fib 1 (start-up) | fib 25 | fib 30 | fib 35 |
|---|---:|---:|---:|---:|
| wasmtime 48 | 0.009 | 0.009 | 0.017 | 0.109 |
| wasm3, C reference | 0.004 | 0.009 | 0.060 | 0.656 |
| wasm3das, daslang interpreter (RunLoop) | 2.364 | 2.967 | 9.437 | 71.494 |
| wasm3das, daslang `-jit` (cached DLL) | 9.693 | 9.819 | 12.566 | 16.878 |
| wasm3das, native build | 2.182 | 2.239 | 2.532 | 5.646 |

Execution only (each cell minus that engine's own start-up) and the ratio
to C wasm3 on fib(35):

| engine | fib 25 | fib 30 | fib 35 | fib 35 vs C |
|---|---:|---:|---:|---:|
| wasmtime 48 | 0.000 | 0.008 | 0.100 | 0.2x |
| wasm3, C reference | 0.005 | 0.056 | 0.652 | 1.0x |
| wasm3das, daslang interpreter (RunLoop) | 0.603 | 7.073 | 69.130 | 106x |
| wasm3das, daslang `-jit` (cached DLL) | 0.126 | 2.873 | 7.185 | 11.0x |
| wasm3das, native build | 0.057 | 0.350 | 3.464 | 5.3x |

Every engine returned the C reference's values. The native build passes the
original spec suite 17863/17863 and the WASI `--fast` list 7/7 on this tree;
the `-jit` row is still the upper bound described below (WASI wrong under
`-jit`). The RunLoop dispatch took the interpreter from 88 s to 69 s of
execution on fib(35); the native build's 2.2 s start-up is the daslang
compile of the sources, unchanged by AOT.

## First run, before the RunLoop dispatch and the op_Compile fix

Wall clock, median of 3 runs, seconds (process start to exit):

| engine | fib 1 (start-up) | fib 25 | fib 30 | fib 35 |
|---|---:|---:|---:|---:|
| wasmtime 48 | 0.011 | 0.010 | 0.017 | 0.113 |
| wasm3, C reference | 0.004 | 0.009 | 0.060 | 0.636 |
| wasm3das, daslang interpreter | 2.317 | 2.994 | 9.929 | 82.348 |
| wasm3das, daslang `-jit` (cached DLL) | 9.843 | 9.751 | 10.304 | 14.478 |
| wasm3das, daslang `-jit -jit-no-cache` | 18.418 | - | - | - |
| wasm3das, native build | 1.732 | fail (exit 139) | fail (exit 139) | fail (exit 139) |

All engines agreed with the C reference where they produced a result:
fib(1) = 1, fib(25) = 75025, fib(30) = 832040, fib(35) = 9227465.

`-jit-no-cache` is measured only in the start-up column: its cost is the fixed
price of regenerating the whole module, which does not depend on N.

## Execution only (cell minus that engine's own start-up)

| engine | fib 25 | fib 30 | fib 35 |
|---|---:|---:|---:|
| wasmtime 48 | 0.000 | 0.006 | 0.102 |
| wasm3, C reference | 0.005 | 0.056 | 0.632 |
| wasm3das, daslang interpreter | 0.677 | 7.612 | 80.031 |
| wasm3das, daslang `-jit` | 0.000 | 0.461 | 4.635 |

## Ratios to C wasm3

Whole process:

| engine | fib 1 | fib 25 | fib 30 | fib 35 |
|---|---:|---:|---:|---:|
| wasmtime 48 | 2.8x | 1.1x | 0.3x | 0.2x |
| wasm3das interpreter | 579.2x | 332.7x | 165.5x | 129.5x |
| wasm3das `-jit` | 2460.8x | 1083.4x | 171.7x | 22.8x |
| wasm3das `-jit -jit-no-cache` | 4604.5x | - | - | - |
| wasm3das native (fib 1 only) | 433.0x | - | - | - |

Execution only:

| engine | fib 25 | fib 30 | fib 35 |
|---|---:|---:|---:|
| wasmtime 48 | 0.0x | 0.1x | 0.2x |
| wasm3das interpreter | 135.4x | 135.9x | 126.6x |
| wasm3das `-jit` | 0.0x | 8.2x | 7.3x |

The interpreter is a steady ~130x of C. The JIT is ~7.3x of C, i.e. **17.3x
faster than the interpreter** on the same code (80.031 s vs 4.635 s on
fib(35)). C wasm3 itself is 6x slower than wasmtime here, which is the expected
gap between a threaded-code interpreter and an LLVM AOT compiler.

## Exact commands

```sh
# the whole table
scripts/bench.sh > /tmp/bench.md

# one engine at a time
tools/bin/wasmtime run --invoke fib wasm3c/test/lang/fib32.wasm 35
tools/bin/wasm3 --func fib wasm3c/test/lang/fib32.wasm 35        # C parses options first
scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 35
DASLANG=$PWD/tmp/daslang-jit/bin/daslang WASM3DAS_JIT=1 \
    scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 35
DASLANG=$PWD/tmp/daslang-jit/bin/daslang WASM3DAS_JIT=1 WASM3DAS_JIT_ARGS=-jit-no-cache \
    scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 35
scripts/wasm3-native wasm3c/test/lang/fib32.wasm --func fib 35
```

`scripts/wasm3` gained exactly one opt-in for this: `WASM3DAS_JIT=1` appends
`-jit` to the daslang command line, `WASM3DAS_JIT_ARGS` appends further JIT
switches, and `WASM3DAS_APP` selects a different app entry point. With none of
them set the command line is byte-identical to what it was before.

The `-jit` rows above were actually produced with
`WASM3DAS_APP=tmp/jit_port/app/wasm3.das`, a copy of `source/` and `app/` that
differs from the tree in exactly one declaration (see "Blocker 3"). That is
what `JIT_APP` in `scripts/bench.sh` is for, and it can be dropped as soon as
the tree carries that one-word change.

## What the JIT switches are and what the cache does

From `tmp/daslang-jit/utils/daScript/main.cpp` and
`modules/dasLLVM/daslib/llvm_jit_run.das`:

| switch | effect |
|---|---|
| `-jit` | `policies.jit_enabled`, pulls in `daslib/just_in_time.das` which requires `llvm/daslib/llvm_macro`; every used function is code-generated |
| `-jit-no-cache` | clears `policies.jit_dll_mode`: code generation happens in memory on every run, no DLL is written or read |
| `-jit-stack` | `policies.jit_emit_prologue`: every generated call keeps a logical daslang stack frame (needed for daslang-level stack traces, costs frame set-up) |
| `-exe`, `-output <path>` | compile to a standalone executable / pin the artifact path |

Script-argument flags parsed by `daslib/clargs` (so they must reach the program's
own argv): `--jit-opt-level` (0..3, default 3), `--jit-size-level`,
`--jit-debug`/`-g`, `--jit-dump`/`-d`, `--jit-compile-only`, `--jit-target`.

The cache:

- Path is `.jitted_scripts/<program namespace>/<content hash>.dll` plus the
  matching `.o`, **relative to the process working directory**, not to
  `das_root` as `include/daScript/ast/ast.h` claims. Running the port from the
  repository root creates `/.jitted_scripts/`, which `.gitignore` already
  covers.
- The basename is a content hash over the function set, opt level, size level,
  prologue flag, debug-info flag and target triple, so any edit under `source/`
  produces a new file and the old one is garbage-collected on the next run
  (`LLVM JIT: GC stale artifact ...`).
- Cold (cache removed): 18.4 s total, of which **9.0 s is code generation for
  904 functions**, the rest the DLL write, link and load. The artifact is
  3.4 MB.
- Warm (cache hit): 9.8 s total, of which 0.2 s is loading the DLL
  (`LLVM JIT: 904 functions in 0.196987 sec (cache)`).
- `-jit-no-cache`: 18.4 s on every run - it pays the code generation each time
  and is only useful when a cached DLL is stale or unwanted.

The remaining ~7.5 s of the warm 9.8 s is not the port at all. A six-line
script costs 0.122 s interpreted and 7.5 s with `-jit`: the JIT support daslib
(`llvm_jit.das` and friends, tens of thousands of lines) is compiled by the
daslang front end at every process start. That is the single largest lever on
JIT start-up and it is entirely on the daslang side.

## What the JIT could not compile

The DisableJitVisitor in `llvm_jit_run.das` **declined nothing** in the port:
no `LLVM JIT: disabled <fn>` and no `falling back to interpreter` line was ever
printed, and all 904 used functions were generated. So the well-behaved
per-function fallback path was never exercised.

Instead, three hard failures had to be removed before `-jit` ran at all. None
of them falls back: the first is a segmentation fault inside code generation,
the second aborts the simulate pass, the third silently produces a wrong
program.

### Blocker 1 - `math::sqrt` segfaults the LLVM JIT (daslang bug, fixed locally)

`source/m3_exec.das` `op_f32_Sqrt_r` writes

```das
_fp0 = f64((math::sqrt(f32(_fp0))))
```

`llvm_jit_intrin.das` maps `"math::sqrt"` to `intrinsic_math_float_op1`, which
builds the LLVM intrinsic name out of `expr.name`. For a call written with its
module qualifier, `expr.name` **is** `math::sqrt`, so the name becomes
`llvm.math::sqrt.f32`; `LLVMLookupIntrinsicID` answers 0, and
`LLVMGetIntrinsicDeclaration(module, 0, ...)` dereferences it - SIGSEGV during
code generation, with no diagnostic. Written unqualified as `sqrt(x)` the same
call yields `llvm.sqrt.f32`, id `0x15c`, and compiles.

The whole table entry family is affected: `log`, `exp2`, `log2`, `sqrt`, `sin`,
`cos`, `round`, `floor`, `ceil`, `floori`, `ceili`. The port only escapes the
others because `op_f32_Ceil_r`/`Floor_r` call the C-named `ceilf`/`floorf` and
`math::trunc` has no intrinsic table entry.

Six-line reproducer, kept at `tmp/jitprobe/p_sqrt3.das`:

```das
options gen2
require math
var g_f = 4.0f
[export]
def main {
    print("{math::sqrt(g_f)}\n")     // interpreter prints 2; -jit segfaults
}
```

Fixed in the `tmp/daslang-jit` worktree by stripping the namespace from the
name before building the intrinsic, and by refusing id 0 instead of passing it
to LLVM. **This is an upstream daslang fix worth a PR.**

### Blocker 2 - `reinterpret<u64>(@@fn)` emits invalid IR (daslang bug, fixed locally)

`source/m3_exec.das` `op_Compile` rewrites the code page with

```das
rewrite[0] = unsafe(reinterpret<code_t>(reinterpret<u64>(@@op_Call)))
```

A daslang function value is the aggregate `{ ptr }` (`g_t_function`), and
`visitExprCast` reached its "same size, so bitcast" branch, emitting
`bitcast { ptr } %4 to i64`. LLVM rejects aggregate-to-scalar bitcasts, so the
module verifier failed and the simulate pass panicked:

```
Invalid bitcast
  %cast_r = bitcast { ptr } %4 to i64
Internal jit error. Failed to get IR of 'op_Compile implementation'
```

Fixed in the worktree with an `extractvalue` + `ptrtoint` branch. **Also an
upstream daslang fix worth a PR.**

### Blocker 3 - the RunLoop sentinel loses its identity (port change needed)

`source/m3_exec_defs.das`:

```das
let public m3Ret_nextOp : M3Result = "m3: dispatch the operation at _pc"
...
let nextOpId = reinterpret<void?>(m3Ret_nextOp)
r = operation(_pc, _sp, _mem, _r0, _fp0)
if (reinterpret<void?>(r) != nextOpId) { break }
```

A `let` string global is constant-folded, and the JIT materialises its own LLVM
constant for it, at a different address from the one the interpreter hands out.
Every operation then looks like a real error to `RunLoop`, and the sentinel
escapes to the top as `Error: m3: dispatch the operation at _pc`.

Verified minimal behaviour (`tmp/jitprobe/p_strid.das`, `p_strid2.das`,
`p_strid3.das`):

| declaration | interpreter | `-jit`, both sides jitted | `-jit`, across the jit/interpreter boundary |
|---|---|---|---|
| `let g : string = "..."` | identity holds | identity holds | **identity breaks** |
| `var g : string = "..."` | identity holds | identity holds | identity holds |

Changing that one declaration to `var` is enough to make the whole port run
under `-jit`; that is the only difference between the tree and
`tmp/jit_port/`, and `diff -r` confirms it. The C original relies on the same
guarantee - one static `const char *` object with one address - so `var` is the
faithful daslang spelling of it, not a workaround.

**Proposed change to `source/m3_exec_defs.das:92` (a file this session does not
own):**

```das
// C relies on a string literal being one static object with one address. A
// daslang `let` string global is constant-folded, and daslang -jit then
// materialises a second copy of it, so the identity test below fails. A `var`
// is one object loaded from the globals area on both sides.
var public m3Ret_nextOp : M3Result = "m3: dispatch the operation at _pc"
```

Any other place in the port that compares an `M3Result` or a loop id **by
pointer** against a `let` global has the same exposure and should be audited
together with this one.

## Correctness under `-jit`: fib passes, WASI does not

With all three blockers removed, `fib32.wasm`, `fib32_tail.wasm`,
`fib64.wasm` and `fib.c.wasm` all return `Result: 75025` under `-jit`.

The WASI suite does not survive it.

```sh
cd tmp/wasi/run
DASLANG=$PWD/../../daslang-jit/bin/daslang WASM3DAS_JIT=1 \
    WASM3DAS_APP=$PWD/../../jit_port/app/wasm3.das \
    python3 -u ./run-wasi-test.py --exec "/home/andry/wasm3das/scripts/wasm3" --fast --timeout 900
```

| configuration | result | wall clock |
|---|---|---|
| interpreter, repository tree (`notes/wasi_test_status.md`) | 7 / 7 | a few minutes |
| interpreter, `tmp/jit_port` tree | **7 / 7** | 138.5 s |
| `-jit`, default `-O3` | **0 / 7**, 5 of them traps | 78.2 s |
| `-jit`, `--jit-opt-level=0` | **0 / 7**, no traps, every digest wrong | 88.1 s |

The interpreted run of the same scratch tree passing 7/7 rules out the tree and
the `var` change: the JIT is what breaks it.

At `-O3` the failures are wasm-level traps raised by the port's own checks:

```
mandelbrot      Error: [trap] out of bounds memory access
C-Ray           Error: [trap] undefined element
smallpt         Error: [trap] undefined element
smallpt-mv      Error: [trap] out of bounds memory access
Brotli          Error: [trap] indirect call type mismatch
```

At `--jit-opt-level=0` nothing traps and every program runs to completion, but
every output digest differs from the reference, so the JIT is computing wrong
values rather than merely tripping a check. `undefined element` and
`indirect call type mismatch` both come from the `call_indirect` path, which is
the same reinterpreted-function-pointer machinery as Blocker 2, so that is the
first place to look; unaligned loads out of wasm linear memory are the second.

Two smaller observations from the same runs:

- The daslang JIT writes its `[I] LLVM JIT: ...` progress to **stdout**, which
  the WASI driver compares byte for byte. Even a correct JIT run would fail
  tests 1 and 6 on that alone. A quiet mode, or routing those lines to stderr,
  is needed before `-jit` can be driven by the existing test harnesses.
- The wasm programs themselves are fast under the JIT even at `-O0`: smallpt
  reports 2148 ms against 19101 ms interpreted, mandelbrot 730 ms - consistent
  with the 17x of the fib measurement.

## The native build

`tmp/native/bin/wasm3das` (another session's work, `scripts/build_native.sh`,
`scripts/wasm3-native`, `notes/native_aot_status.md`) starts in 1.73 s and
answers `fib(1)` correctly, then dies on the first wasm-level call:

```
$ tmp/native/bin/wasm3das --func fib wasm3c/test/lang/fib32.wasm 1
Result: 1
$ tmp/native/bin/wasm3das --func fib wasm3c/test/lang/fib32.wasm 2
CRASH: SIGSEGV (Segmentation fault) (signal 11) at address 0x40
```

`fib(1)` returns without recursing, `fib(2)` is the first input that executes a
wasm `call`, so the fault is on the call path, at a small fixed offset (0x40)
that reads like a field of a null struct pointer. Both argument orders and a
raised stack limit behave identically. `bench.sh` therefore reports the native
engine's start-up row and `fail (exit 139)` for the rest; it will fill in on
its own once that crash is fixed.

## Reproducing and extending

`scripts/bench.sh` takes `RUNS`, `NS`, `ENGINES`, `BASELINE`, `WASM`, `FUNC`,
per-engine binary overrides and `JIT_APP`. It gives every engine one un-timed
warm-up run, skips an engine whose binary is missing or which fails the
cheapest workload (saying so in the output), reports the median of `RUNS`, and
checks every engine's answer against the C reference.

```sh
RUNS=1 NS="1 25" ENGINES="wasm3-c wasm3das-interp" scripts/bench.sh
```

## Open work

- Land the two daslang JIT fixes upstream (`tmp/daslang-jit` worktree,
  `git diff` is 29 lines across `llvm_jit.das` and `llvm_jit_intrin.das`).
- Land the `var m3Ret_nextOp` change and audit the port for other
  pointer-identity comparisons against `let` globals.
- Find why `-jit` computes wrong values for the WASI programs; start at
  `call_indirect` and at unaligned linear-memory access.
- Get the JIT's progress log off stdout so the existing drivers can run it.
- The 7.5 s fixed JIT start-up is the blocker for using `-jit` anywhere in CI;
  a persistent process or the native build is the answer, not a faster cache.
