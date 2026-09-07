# Native AOT build of the Daslang port — status

Date: 2026-09-06. Toolchain: pinned `tmp/daslang-toolchain/bin/daslang`,
Daslang 0.6.4 (`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`).

The port is still Daslang source; nothing was rewritten in C++. What changed is
*how* it executes: `daslang -aot` turns every module of `source/` and
`app/wasm3.das` into one C++ translation unit, those units are compiled and
linked with the static `libDaScript` into a single native binary, and at
startup daslang swaps the interpreter nodes for the native functions. The
result runs the same `.das` files, so the interpreter path stays the
authoritative gate and the two must agree on every test.

## Build

```sh
scripts/build_native.sh                 # -> tmp/native/bin/wasm3das
JOBS=2 scripts/build_native.sh          # limit the parallel C++ compiles
EXTRA_CXXFLAGS="-g -O1 -fsanitize=address -fno-omit-frame-pointer" \
EXTRA_LDFLAGS="-fsanitize=address" scripts/build_native.sh tmp/native-asan
```

The script AOTs `app/wasm3.das` and every `source/*.das` into `<out>/aot/*.cpp`,
compiles them with the exact flags `libDaScript` itself is built with
(`-O3 -fno-rtti -fwrapv -std=gnu++17`, `DAS_FUSION=2`), links them with
`native/wasm3das_main.cpp` and `liblibDaScript.a`, and copies `daslib/`,
`app/` and `source/` beside the binary. Full build: about six minutes on four
cores; the AOT step is content-cached, so only changed modules are re-emitted.

`native/wasm3das_main.cpp` is the host, modelled on the toolchain's
`utils/mcp/cpp_mcp_main.cpp`. It compiles `<root>/app/wasm3.das` with
`CodeOfPolicies::aot = true` and calls its `main()`. Options, consumed by the
host and not forwarded: `-dasroot <dir>` (bundle root; by default resolved from
the executable, `<root>/bin/wasm3das` -> `<root>/app`, `<root>/daslib`),
`-no-aot` (run interpreted — the diagnostic control), `-aot-strict`
(`fail_on_no_aot`, report any function that has no AOT body). Everything else
is forwarded to the app.

`scripts/wasm3-native` is the drop-in front end, the exact counterpart of
`scripts/wasm3`: it raises `ulimit -s` for the deep native recursion the
missing `M3_MUSTTAIL` causes and forwards every argument unchanged. Both
runners accept it in place of `scripts/wasm3`:

```sh
cd tmp/spec/run && python3 ./run-spec-test.py \
    --exec "/home/andry/wasm3das/scripts/wasm3-native --repl" --timeout 120
cd tmp/wasi/run && python3 -u ./run-wasi-test.py \
    --exec "/home/andry/wasm3das/scripts/wasm3-native" --fast --timeout 900
```

`-aot-strict` is silent for the whole port: **every** function of `app/` and
`source/` gets a native body, nothing falls back to the interpreter.

## Results

Identical to the interpreter, through the original unmodified drivers:

| suite | native AOT | interpreter |
|---|---|---|
| `run-spec-test.py` (default list) | 17863 / 17863, 0 fail, 0 crash, 0 timeout, 235 skipped | same |
| `run-wasi-test.py --fast` | 7 / 7, 0 fail, 0 crash, 0 timeout | same |

Wall clock for the whole suite, back to back on an idle machine:

| suite | native AOT | interpreter |
|---|---|---|
| `run-spec-test.py` | 5.8 s | 10.5 s |
| `run-wasi-test.py --fast` | 20.0 s | ~139 s |

The spec suite gains only 1.8x because `--repl` keeps one process alive for
the whole run and its 17863 assertions are single tiny calls: the run is
dominated by REPL line parsing and module loading, not by wasm execution. The
WASI list, which is real compute, gains 7x end to end and far more once
startup is subtracted (see below).

## AOT lowering findings

Three findings, all the same shape: a Daslang construct whose *AOT* lowering
differs from its *interpreter* lowering. None is a bug in the port's C
fidelity, and none was fixed by touching generated C++ or toolchain headers —
the fix is always in the `.das` source, and it keeps the interpreter path
identical. A fourth section records what turned out **not** to need a change.

### 1. An enum of another module is only declared where a value is used

`daslang -aot` emits the declaration of an enum imported from another module
into a translation unit only when that unit's own code mentions one of its
values. `source/m3_types.das` defines `M3TaggedValue`, whose `_type` field is
an `M3ValueType`, but no code in that module named an `M3ValueType` value, so
the generated `m3_types.das.cpp` used an undeclared enum and did not compile.

Fix: `m3_TaggedValueNone()` in `source/m3_types.das`, which spells out the
zero-initialised `M3TaggedValue` C describes and thereby names
`M3ValueType.c_m3Type_none`.

### 2. `array<void const?>` has no instantiated builtins

The AOT emitter renders `array<void const?>` as `TArray<void const *>`, but
the array builtins (`push`, `reserve`, indexing) are instantiated only for
`TArray<void *>`, so the unit fails to link.

Fix: use `array<void?>` — `m3_Call` in `source/m3_env.das` and its caller
`repl_invoke` in `app/wasm3.das`. The deviation from C's
`const void * i_argptrs[]` is documented at `m3_Call`.

### 3. `reinterpret<pointer>(function value)` yields the address of the value

This is the one that mattered. `das_cast<TT*>` (`aot.h`) resolves a non-pointer
argument through

```cpp
template <typename QQ>
static TT * cast ( const QQ & expr ) { return reinterpret_cast<const TT*>(&expr); }
```

so `reinterpret<void?>(f)` of a *function* value compiles to the **address of
the function handle**, i.e. a pointer into the current stack frame, while the
interpreter yields the handle's own bits. A `Func` is
`struct Func { SimFunction * PTR; }`, so the correct 64-bit value is one
`reinterpret<u64>` away, and `das_cast<TT*>::cast(uint64_t)` is a plain
`(TT*)value`. Reading back is already correct in both backends:
`das_cast<Func>::cast(void*&)` reinterprets the *slot*, not its address.

Every write of a function value into a code page therefore has to go through
`u64`:

```das
reinterpret<void?>(reinterpret<u64>(f))     // both backends: f's bits
```

Three call sites in the port write a function value into a code page. Two are
fixed; the third is the one-line proposal below.

* `EmitWord` in `source/m3_code.das` — the generic
  `#define EmitWord(page, val) EmitWord_impl((page), (const void *)(val))`.
  This covers the whole opcode table (`EmitOp`, `op_Branch`, the
  `c_preserveSetSlot`/`c_setSlot`/`c_setGlobal`/`c_setRegister` tables, …).
  Symptom before the fix: AddressSanitizer reported
  `stack-use-after-return` and the binary jumped to a stack address.

* `FindAndLinkFunction` in `source/m3_bind.das` — the `M3RawCall` handed to
  `CompileRawFunction`, which `EmitWord_impl`s it into the code page for
  `op_CallRawFunction`. It reached `CompileRawFunction` as
  `reinterpret<void const?>(i_function)`, i.e. the address of
  `FindAndLinkFunction`'s own parameter, which dies when that function
  returns. Symptom: **every** raw import — all of WASI and the spec suite's
  `spectest.*` — jumped through a dangling frame pointer. Fixed the same way.

* `op_Compile` in `source/m3_exec.das` — see "Open proposal" below.

The whole port has exactly these three; the generated tree was swept for
`das_cast<…*>::cast(<Func-typed expression>)` and no other site exists.

### 4. Nothing else needed a change

No stack-size change was required. `app/wasm3.das`'s
`options stack = 67_108_864` and `scripts/wasm3-native`'s
`ulimit -s 262144` are both carried over from the interpreter runner
unchanged, and the spec suite's `assert_exhaustion` cases still report
`[trap] stack overflow` rather than dying. The "stack overflow while calling
<garbage name>" seen during the earlier module-by-module bisect was very
likely not a stack problem at all but finding 3 corrupting the dispatch word —
a garbage callee name is what a `Func` built from a stack address looks like.
It was not reproduced again after the three fixes, and no stack knob was
touched to make the suites pass.

## The `op_Compile` site in `source/m3_exec.das` (applied)

`op_Compile` patches the code page at run time with the `op_Call` handler,
which is C's `* ((void **) _pc) = (void *) (op_Call)`. It is finding 3, and it
was the reason the first native binary segfaulted on any wasm call
(`fib 0` and `fib 1` returned, `fib 2` crashed at a stack address). The line
below is now in the tree:

```das
// source/m3_exec.das, in op_Compile (line 3043 before the dispatch rewrite
// that landed during this session, line 3057 after it; the statement itself
// is unchanged by that rewrite)
-        rewrite[0] = unsafe(reinterpret<code_t>(@@op_Call))
+        rewrite[0] = unsafe(reinterpret<code_t>(reinterpret<u64>(@@op_Call)))
```

Generated before: `das_cast<void*>::cast(Func(__context__->fnByMangledName(…)))`
— the address of a temporary. Generated after:
`das_cast<void*>::cast(das_cast<uint64_t>::cast(Func(…)))` — the handle's bits.

The measurements in the next section were taken with this line applied on
top of the tree *before* the RunLoop dispatch rewrite of `m3_exec` /
`m3_exec_defs` (`notes/exec_trampoline_design.md`), built into a scratch
copy. On the final tree (dispatch rewrite included) a plain
`scripts/build_native.sh` reproduces the binary at `tmp/native/bin/wasm3das`,
which `scripts/wasm3-native` uses by default; that binary passes the original
spec suite 17863/17863 and the WASI `--fast` list 7/7 as well, and its
numbers are in `notes/benchmark_2026-09-07.md` (final table).

## Measurements

Wall clock, `date +%s.%N` around the command, on an otherwise idle four-core
machine. "native" is the AOT binary, "interp" is `scripts/wasm3` (daslang
interpreter), "C" is `tools/bin/wasm3` (the reference C wasm3), "wasmtime" is
`tools/bin/wasmtime` (a JIT, listed for scale).

### Startup

A run of `fib 1` is startup and nothing else.

| engine | fib 1 |
|---|---|
| native | 1.83 s |
| interp | 1.88 s |
| C | 0.004 s |
| wasmtime | 0.009 s |

**AOT does not change startup.** The host still parses and type-checks
`app/wasm3.das` and all of `source/` at every launch; AOT only replaces the
function bodies during `simulate`, and linking them costs nothing measurable.
Removing this 1.8 s needs a standalone/serialised context, which the pinned
toolchain does not offer for this code base — it is the largest remaining
item and it is untouched by this work.

### fib32.wasm

`--func fib N` on `wasm3c/test/lang/fib32.wasm`.

| N | native | interp | C | wasmtime |
|---|---|---|---|---|
| 1 | 1.829 | 1.882 | 0.004 | 0.009 |
| 25 | 1.814 | 2.490 | 0.008 | 0.010 |
| 30 | 2.029 | 9.589 | 0.059 | 0.018 |
| 35 | 4.703 | 90.108 | 0.598 | 0.104 |

Startup subtracted (each engine's own `fib 1`), i.e. execution only:

| N | native | interp | C | wasmtime |
|---|---|---|---|---|
| 30 | 0.20 | 7.71 | 0.055 | 0.009 |
| 35 | 2.87 | 88.23 | 0.594 | 0.095 |

On `fib(35)` execution the AOT binary is **31x faster than the interpreter**,
**4.8x slower than the C wasm3**, and **30x slower than wasmtime**. The
remaining gap to C is the daslang calling convention that survives AOT (the
`Context *` parameter, `das_invoke_function` through the function table for
every threaded-interpreter hop) plus the missing `M3_MUSTTAIL`, which turns
each wasm operation into a real, non-eliminated C++ frame.

### WASI, the `--fast` list

Per test, wall clock, same commands the driver issues.

| test | native | interp | C | wasmtime |
|---|---|---|---|---|
| Simple WASI test | 1.844 | 2.311 | 0.007 | 0.092 |
| mandelbrot | 2.024 | 8.951 | 0.047 | 0.056 |
| C-Ray | 1.934 | 2.844 | 0.012 | 0.057 |
| smallpt | 2.983 | 22.318 | 0.141 | 0.066 |
| smallpt multi-value | 4.294 | 47.182 | 0.345 | 0.084 |
| mal | 2.260 | 4.385 | 0.028 | n/a |
| Brotli | 3.726 | 50.894 | 0.259 | 0.303 |
| **sum** | **19.07** | **138.89** | **0.839** | — |

`wasmtime` could not run `mal`, which opens `./wasi/mal/test-fib.mal` through
the preopen; that is a wasmtime invocation detail, not a result about the port.

The whole `--fast` list through the driver takes **20.0 s** natively against
about **139 s** interpreted. The benchmarks' own timers agree: the "Simple
WASI test" reports `fib(20) = 6765 [8.552 ms]` natively against
`[1232.459 ms]` interpreted, a 144x difference on a measurement that excludes
startup entirely.

Each test pays the 1.8 s startup once, so on the short cases (`simple`,
`C-Ray`) almost the whole native number *is* startup.

## What is not done

* `source/m3_exec.das:3043` — the proposal above; the repository tree still
  segfaults natively on any wasm call without it.
* Startup: 1.8 s of daslang front end at every launch, unchanged by AOT.
* Execution is still 4.8x off the C wasm3. The two structural causes are the
  daslang calling convention in the AOT output and the missing `M3_MUSTTAIL`
  tail-call dispatch; neither is addressed here.
* The ASan variant (`tmp/native-asan`) was built against the tree *before*
  the `EmitWord` fix. It is what first proved finding 3; it has not been
  rebuilt since, because the remaining two sites of that finding
  (`m3_bind.das` and the `m3_exec.das` proposal) were located by reading the
  generated C++ instead, which is faster and exhaustive.
* The non-`--fast` WASI list (12 tests, ~80 minutes interpreted) was not run
  natively.
