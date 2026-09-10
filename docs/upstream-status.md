# Upstream daslang status carried by the pin

The port runs on the daslang upstream commit pinned in `scripts/daslang_pin`
(see that file for the commit and what it carries). This document is the
per-issue record: what each upstream defect meant for wasm3das, which fix the
pin carries, and how the port verifies it. Re-verify the whole table after
every pin bump; update the statuses there as upstream moves.

Checked against the pin: 2026-09-09, commit `46c4715`; issue #3991 added
2026-09-10 (reproduced on the pin and on master `388691eb1`).

| Issue / area | What it meant for the port | Fix in the pin | How the port verifies |
|---|---|---|---|
| #3967 standalone `-ctx` | zero-startup native binaries unusable: a required module's initialized global failed emission, the emitted `InitGlobalVar` did not link, and a linking context never ran its initializers | PR #3838 (merged 2026-08-24); standalone emits every used function of every module (`25cd2cd6`) and runs `[init]` in run order (`8f4d87ca`) | `scripts/build_port.sh ctx` builds a standalone binary that passes the full fixture parity run (`tests/manual/fixture_report.md`, `wasm3das(aot_ctx)` column) |
| #3968 LLVM JIT: SIGSEGV on a module-qualified `math::` float intrinsic | the port called qualified `math::` builtins; codegen of the port with `-jit` crashed | PR #3974 | `run_tests_jit` (dastest of `tests/` under `-jit`) once a daslang build with LLVM exists; not part of the default gate |
| #3969 LLVM JIT: function ↔ int `reinterpret` invalid bitcast | the port's code-page dispatch writes function handles as bits (`EmitWord`) | PR #3974 | same as #3968 |
| #3970 interpreter: `reinterpret<uint64>(@@fn)` yields 0 in store contexts | the interpreter dropped the bits exactly like #3969 | PR #3974 | the spec suite (`17863/17863` through `scripts/wasm3 --repl`) covers this pattern; re-run after every bump |
| `ast_gen.inc` / `debugapi_gen.inc` missing from the release bundles | `scripts/build_port.sh` failed to compile its AOT output against a shipped SDK (found on a fresh machine) | commit `29e2a1208` (2026-09-08) installs both generated headers and adds `ci/smoke_test_bundle.sh` | `scripts/verify_daslang.sh` requires `include/daScript/builtin/ast_gen.inc` to exist in the build |
| [#3991](https://github.com/GaijinEntertainment/daScript/issues/3991) LLVM JIT: a `const` pointer/reference parameter the callee writes through gets LLVM `readonly`, so `--jit-opt-level >= 1` folds the caller's read | under `-jit` at the default O3 the port returned stale memory wherever a callee wrote through a `void?` out-parameter or a `const` pointer after `reinterpret`/`intptr`: six spec assertions (`elem`, `memory`, `memory_trap`) and 67 of 86 manual fixtures wrong; O0 correct | none yet (filed 2026-09-10; reproduces on the pin and on master `388691eb1`) — the port carries the `var` workaround instead (see the limitation bullet below) | the reusable case is `notes/upstream_cases/tests/jit_tests/test_const_arg_readonly.das`, run it under `-jit` at O3 after every bump: 8/8 means fixed. The port itself is verified at O3 by the spec suite (`17863/17863`), `run-wasi-test.py` (12/12) and the manual fixture parity run (86/86) |

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
  to its pre-call value. Until upstream answers, `-jit` runs at
  `--jit-opt-level=0` (`WASM3DAS_JIT_OPTS`, the fixture harness default) and
  stays opt-in and off the gate. The port-side workaround, if O3 is wanted
  before the fix, is to declare such out-parameters `var` (the JIT then
  emits no `readonly`); not applied.
- Deep wasm recursion without `M3_MUSTTAIL` costs native frames: the
  launchers raise `ulimit -s` for the spec suite's `assert_exhaustion`
  cases. Trampoline/tail-call architecture remains the future port task.

## Historical record

`notes/upstream_daslang_issues_2026-09-07.md` (issue drafts, reproducer
tests under `notes/upstream_cases/`) and
`notes/daslang_jit_fixes_2026-09-07.patch` (daslang-side fixes written before
PR #3974 landed) are kept as provenance; their content is superseded by this
table and the pin.
