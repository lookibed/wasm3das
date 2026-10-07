# Upstream daslang status carried by the pin

The port runs on the daslang upstream commit pinned in `scripts/daslang_pin`
(see that file for the commit and what it carries). This document is the
per-issue record: what each upstream defect meant for wasm3das, which fix the
pin carries, and how the port verifies it. Re-verify the whole table after
every pin bump; update the statuses there as upstream moves.

Checked against the pin: 2026-09-10, commit `388691eb1` (bumped from
`46c4715` the same day: PR #3982, the JIT's emitter-free cache hit, and PR
#3981, `--jit-debug`; the port needed no adaptation, the gate passed
unchanged). Issue #3991 reproduces on both commits.

| Issue / area | What it meant for the port | Fix in the pin | How the port verifies |
|---|---|---|---|
| #3967 standalone `-ctx` | zero-startup native binaries unusable: a required module's initialized global failed emission, the emitted `InitGlobalVar` did not link, and a linking context never ran its initializers | PR #3838 (merged 2026-08-24); standalone emits every used function of every module (`25cd2cd6`) and runs `[init]` in run order (`8f4d87ca`) | `scripts/build_port.sh ctx` builds a standalone binary that passes the full fixture parity run (`tests/manual/fixture_report.md`, `wasm3das(aot_ctx)` column) |
| #3968 LLVM JIT: SIGSEGV on a module-qualified `math::` float intrinsic | the port called qualified `math::` builtins; codegen of the port with `-jit` crashed | PR #3974 | `run_tests_jit` (dastest of `tests/` under `-jit`) once a daslang build with LLVM exists; not part of the default gate |
| #3969 LLVM JIT: function ↔ int `reinterpret` invalid bitcast | the port's code-page dispatch writes function handles as bits (`EmitWord`) | PR #3974 | same as #3968 |
| #3970 interpreter: `reinterpret<uint64>(@@fn)` yields 0 in store contexts | the interpreter dropped the bits exactly like #3969 | PR #3974 | the spec suite (`17863/17863` through `scripts/wasm3 --repl`) covers this pattern; re-run after every bump |
| `ast_gen.inc` / `debugapi_gen.inc` missing from the release bundles | `scripts/build_port.sh` failed to compile its AOT output against a shipped SDK (found on a fresh machine) | commit `29e2a1208` (2026-09-08) installs both generated headers and adds `ci/smoke_test_bundle.sh` | `scripts/verify_daslang.sh` requires `include/daScript/builtin/ast_gen.inc` to exist in the build |
| [#3991](https://github.com/GaijinEntertainment/daScript/issues/3991) LLVM JIT: a `const` pointer/reference parameter the callee writes through gets LLVM `readonly`, so `--jit-opt-level >= 1` folds the caller's read | under `-jit` at the default O3 the port returned stale memory wherever a callee wrote through a `void?` out-parameter or a `const` pointer after `reinterpret`/`intptr`: six spec assertions (`elem`, `memory`, `memory_trap`) and 67 of 86 manual fixtures wrong; O0 correct | none yet (filed 2026-09-10; reproduces on the pin and on master `388691eb1`) — the port carries the `var` workaround instead (see the limitation bullet below) | the reusable case is `notes/upstream_cases/tests/jit_tests/test_const_arg_readonly.das`, run it under `-jit` at O3 after every bump: 8/8 means fixed (still 6 failed on master `388691eb1`, 2026-09-10). The port itself is verified at O3 by the spec suite (`17863/17863`), `run-wasi-test.py` (12/12) and the manual fixture parity run (86/86) |
| standalone `-ctx`: every call into a required module is emitted as `Context::fnByMangledName` + `das_invoke_function` (`daslib/aot_cpp.das` `isHybridCall`, `func._module != program.getThisModule`) although the context defines the callee as an `inline` function in the same unit | 1734 lookup sites in the port's context, `RunLoop`, `nextOpImpl` and every helper an operation calls; no C++ inlining across them | **taken by the fork** on 2026-09-21, commit `d6dbcfd75` ("aot: a standalone context calls its foreign functions directly"), in its own form: `CppAot.emitsForeignBody`, a predicate `StandaloneContextGen` answers from the `foreignUsedFunctions` hashes, consulted by `isHybridCall` after the `noAot`/`aotHybrid`/`requestJit` tests; not upstream. Found the same day on master `1969ad4d4`; `notes/upstream_cases/ctx_direct_calls.patch` is the port's original three-line form and `ctx_direct_calls.md` the issue text. `scripts/build_port.sh ctx` recognises either spelling (`emitsForeignBody` or `directForeign`) and applies the patch to its overlay only on a checkout that has neither | the build prints the lookup count of the emitted unit: 310 with the patch, 1734 stock; `fib 35` on the ctx tier 1.65 s -> 1.15 s, spec 17863/17863, WASI 12/12 (`docs/native-build.md`, section 7) |
| standalone `-ctx`: `collectLinkedModules` (`daslib/aot_cpp.das`) registers every default C++ module the compiler loaded once the program reaches any C++ module beyond the builtin one, so the port's binary constructs `rtti_core` and `ast_core` at every start although only the compile-time macro module `m3_exec_expand` required them | 8 ms of a 20 ms process start (the module constructors: `$` 8 ms, `ast_core` 6 ms, `rtti_core` 2 ms, `math`/`strings`/`fio_core` 2.5 ms, `Module::Initialize` 2 ms, teardown 3 ms, measured with a timed copy of the host); 13 MB of binary | **not accepted** (found 2026-09-21; `notes/upstream_cases/ctx_used_modules.patch`, issue text `notes/upstream_cases/ctx_used_modules.md`): register the modules the runtime program uses plus their C++ dependencies, which is what the walk below that line already does. Applied through the same overlay | the emitted module table lists `$`, `math`, `strings`, `fio_core` only; the binary 44.8 MB -> 31.8 MB; spec 17863/17863, WASI 12/12 on the reduced set |

| LLVM JIT: `p++` / `p--` on a pointer lower to `$::i_das_ptr_inc` / `i_das_ptr_dec`, which have no intrinsic (`modules/dasLLVM/daslib/llvm_jit_intrin.das`, `g_intrin_lookup`), so the JIT emits a call through the builtin's function pointer with the pointer BY REFERENCE, spilled to the frame | every operand reader of `m3_exec` ended with `_pc++`: one runtime call per read, `_pc` in memory for the rest of the operation, and its address escaped, so LLVM could not tail-call the `return nextOpImpl(...)` that follows; the `-exe` tier ran fib(35) at 2.1 s | **not accepted** (found 2026-09-21 with objdump of the cached DLL; `notes/upstream_cases/jit_ptr_inc_intrinsic.md`). The port spells the readers `_pc += 1` (`i_das_ptr_set_add`, intrinsified), which is a GEP and leaves `_pc` in a register | the operation body in the DLL: 6 instructions and `jmp nextOpImpl` instead of 30 with a spilled `_pc` and `call`; exe fib(35) 2.1 s -> 1.2 s on the same (loaded) stand |
| LLVM JIT: every pointer dereference is preceded by a null test unless the function carries the `unsafeDeref` flag (`[unsafe_deref]`; `visitExprAt`, `visitExprPtr2Ref`) | three tests per executed operation (`_pc`, the slot pointer, the advanced `_pc`) that C does not have | not a defect, a facility, with one known hazard: the fork's issue lookibed/daScript#7 (2026-09-23, found by the c2das work) is a real miscompile under `[unsafe_deref]`, a nested void function whose only effect is a store through `reinterpret<uint8?>(uint64)` is dropped in every mode. The port's `m3_exec_expand` pass sets `fn.flags.unsafeDeref` on the operation path only (the `op_*` functions; `RunLoop`, `nextOpImpl`, `jumpOpImpl` and `RunCode` carry `[unsafe_deref]` in source), none of which has that shape, and the interpreter's deref nodes lose the test too; no spelling of the read avoids the test without the flag (checked in the IR, `docs/native-build.md` section 7, E11) | the DLL's operation body has no `jit_exception` branch left; the spec suite (17863/17863) and the fixture corpus (86/86) run with the flag on every tier; re-check the #7 reproducer against the operation path after every daslang bump |
| LLVM JIT: a call through a function value (`visitExprInvoke` -> `build_call_dispatch`) goes through the callee's generic wrapper `vec4f (Context *, vec4f *, void *)` and is never a tail call; a direct call of a matching signature in return position is | the C form's `return operation(_pc + 1, ...)` nests one LLVM frame per executed operation until the wasm function returns: 209 ns per step in the micro-model against 4 ns for the invoke itself and 1.3 ns for a tree of direct calls; the `-exe` and `-jit` tiers stay 2x behind `-ctx`, where g++ emits `jmp *%r9` | **not accepted** (2026-09-21; the request for the fork `notes/upstream_cases/jit_invoke_musttail_request.md`, the technical text `jit_invoke_musttail.md`, micro-model `tests/jit_tests/dispatch.das`): `SimFunction` gains the native entry `jitImpl`, an invoke of a simple function type calls it directly, `musttail` in return position when the signatures match. The port-side stand-in, an index word and a generated tree of direct calls, is measured on branch `perf/jit-dispatch-tree` (tail jumps through the tree, but a prologue and nine comparisons per operation; 1.7x slower on the ctx tier, so not merged) | the operation body in the DLL ends in `jmp nextOpImpl`; `nextOpImpl` itself still `call`s the wrapper; exe fib(35) 1.2 s against ctx 0.6 s on the same stand |

## Known upstream limitations still live (not blockers)

- `[init]` functions of required modules cannot run in a standalone context
  (`daslib/aot_standalone.das`). The port moved the one such `[init]` it had
  (`m3_compile::init_compile_operation_tables`) to an explicit call from
  `m3_NewEnvironment` — semantically identical, and the fill is idempotent.
  If a new required-module `[init]` is ever introduced, the `-ctx` build will
  fail with `error[50503]` naming it; move it into the explicit call chain.
- LLVM JIT wrong results at `--jit-opt-level >= 1`: reduced and filed as
  #3991 (table above). The cause is one rule in
  `modules/dasLLVM/daslib/llvm_jit.das` (`apply_impl_param_attrs`): every
  `const` pointer, reference or string parameter gets the LLVM `readonly`
  attribute from its spelling alone, while daslang lets the callee write
  through it after an `unsafe` `reinterpret` or `intptr`; from O1 the
  optimizer trusts the attribute and folds the caller's read of that memory
  to its pre-call value. The upstream defect is still open (the reusable case
  still fails 6 of its 10 checks under `-jit --jit-opt-level=3` on master
  `388691eb1`).

  **The port-side workaround is applied.** Every parameter the callee writes
  through is declared `var`, which is also what C declares it, so the JIT
  emits no `readonly` for it: the `M3RawCall` typedef (`_sp`, `_mem`) and
  every raw function of `m3_api_libc.das`, `m3_api_wasi.das` and
  `m3_api_wasi_fd.das`; `m3ApiReturn_*` and `m3ApiWriteMem*`
  (`m3_api_defs.das`); `libc_memset`/`libc_memcpy`/`libc_memmove`;
  `wasi_fd_seek_common`; `m3_zero_bytes`/`m3_copy_bytes` (`m3_core.das`);
  `EvaluateExpression` (`m3_env.das`); `c_memmove` and the `ResizeMemory` /
  `CompileFunction` hook bridges (`m3_exec.das`). Read-only pointer
  parameters keep their `const` spelling, because `readonly` is accurate for
  them. Each site carries a comment naming #3991.

  With the workaround the port is correct at O3. Measured 2026-09-10 on the
  stand (Ryzen 7 7435HS, 16 logical CPUs) against upstream master
  `388691eb1` built with dasLLVM, `WASM3DAS_JIT=1
  WASM3DAS_JIT_OPTS=--jit-opt-level=3`: the spec suite `17863/17863`
  (16.4 s), `run-wasi-test.py` 12/12 (2m52s, through a wrapper that strips
  the JIT's own `[I] ` lines from the stdout the driver hashes), and the
  manual fixture parity run 86/86 with the whole set in 1m02.8s — 8.7 s
  without process start, against 1m25.2s for the interpreter, 4.7 s for the
  standalone `ctx` binary and 2.9 s for the C wasm3. JIT start is 3.5 s of
  codegen cold, 0.15 s from the DLL cache (0.67 s of total process time).

  The `jit` runtime of `tests/manual/run_fixtures.py` records daslang's own
  default, `--jit-opt-level=3`, in the report header (`WASM3DAS_JIT_OPTS`);
  `--jit-opt-level=0` is the control for a JIT column that disagrees with
  the baseline. `-jit` stays opt-in and off the gate. Once #3991 is fixed
  upstream the `var` spellings can stay: they match the C declarations.
- Deep wasm recursion without `M3_MUSTTAIL` costs native frames: the
  interpreted and aot launchers raise `ulimit -s` for the spec suite's
  `assert_exhaustion` cases; the standalone binary reserves a 256 MiB
  thread stack itself (`native/standalone_main.cpp`) and needs no launcher.
  With the emitter patch of the table above and the C form of the operation
  ABI (PR #54) the ctx tier runs C's tail-jump chain; the LLVM JIT does not
  emit a tail call for `return f(args)` even with matching signatures, so the
  exe tier keeps its frames (`docs/execution-design.md`, section 6): the
  second ask to daslang.

## Historical record

The reproducer tests under `notes/upstream_cases/` (in the layout of the
upstream daScript test suite, with `RESULTS.md` as their run log) and
`notes/daslang_jit_fixes_2026-09-07.patch` (daslang-side fixes written before
PR #3974 landed) are kept as provenance; the issue texts were filed upstream
on 2026-09-08 (#3967, #3968, #3969, #3970) and 2026-09-10 (#3991) from the
owner's account, and PR #3974 (twelve files) fixes the three JIT/interpreter
defects plus the AOT `das_cast` of a `Func` that `docs/native-build.md`
section 2 works around. Checklist when the pin moves: rebuild, run
`scripts/gate.sh`, the spec and WASI drivers through `scripts/wasm3` and
`scripts/wasm3-native` (`docs/test-suites.md`), then
`tests/manual/run_fixtures.py`, and re-verify every row of the table above.
