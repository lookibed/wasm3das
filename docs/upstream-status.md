# Upstream daslang status carried by the pin

The port runs on the daslang upstream commit pinned in `scripts/daslang_pin`
(see that file for the commit and what it carries). This document is the
per-issue record: what each upstream defect meant for wasm3das, which fix the
pin carries, and how the port verifies it. Re-verify the whole table after
every pin bump; update the statuses there as upstream moves.

Checked against the pin: 2026-09-09, commit `46c4715`.

| Issue / area | What it meant for the port | Fix in the pin | How the port verifies |
|---|---|---|---|
| #3967 standalone `-ctx` | zero-startup native binaries unusable: a required module's initialized global failed emission, the emitted `InitGlobalVar` did not link, and a linking context never ran its initializers | PR #3838 (merged 2026-08-24); standalone emits every used function of every module (`25cd2cd6`) and runs `[init]` in run order (`8f4d87ca`) | `scripts/build_port.sh ctx` builds a standalone binary that passes the full fixture parity run (`tests/manual/fixture_report.md`, `wasm3das(aot_ctx)` column) |
| #3968 LLVM JIT: SIGSEGV on a module-qualified `math::` float intrinsic | the port called qualified `math::` builtins; codegen of the port with `-jit` crashed | PR #3974 | `run_tests_jit` (dastest of `tests/` under `-jit`) once a daslang build with LLVM exists; not part of the default gate |
| #3969 LLVM JIT: function ↔ int `reinterpret` invalid bitcast | the port's code-page dispatch writes function handles as bits (`EmitWord`) | PR #3974 | same as #3968 |
| #3970 interpreter: `reinterpret<uint64>(@@fn)` yields 0 in store contexts | the interpreter dropped the bits exactly like #3969 | PR #3974 | the spec suite (`17863/17863` through `scripts/wasm3 --repl`) covers this pattern; re-run after every bump |
| `ast_gen.inc` / `debugapi_gen.inc` missing from the release bundles | `scripts/build_port.sh` failed to compile its AOT output against a shipped SDK (found on a fresh machine) | commit `29e2a1208` (2026-09-08) installs both generated headers and adds `ci/smoke_test_bundle.sh` | `scripts/verify_daslang.sh` requires `include/daScript/builtin/ast_gen.inc` to exist in the build |

## Known upstream limitations still live (not blockers)

- `[init]` functions of required modules cannot run in a standalone context
  (`daslib/aot_standalone.das`). The port moved the one such `[init]` it had
  (`m3_compile::init_compile_operation_tables`) to an explicit call from
  `m3_NewEnvironment` — semantically identical, and the fill is idempotent.
  If a new required-module `[init]` is ever introduced, the `-ctx` build will
  fail with `error[50503]` naming it; move it into the explicit call chain.
- LLVM JIT wrong results at `--jit-opt-level >= 1`, localized near
  `m3_env::EvaluateExpression` — reduced notes live in
  `notes/upstream_daslang_issues_2026-09-07.md` (item 5); not resolved
  upstream at the time of writing. `-jit` therefore stays opt-in and off the
  default gate.
- Deep wasm recursion without `M3_MUSTTAIL` costs native frames: the
  launchers raise `ulimit -s` for the spec suite's `assert_exhaustion`
  cases. Trampoline/tail-call architecture remains the future port task.

## Historical record

`notes/upstream_daslang_issues_2026-09-07.md` (issue drafts, reproducer
tests under `notes/upstream_cases/`) and
`notes/daslang_jit_fixes_2026-09-07.patch` (daslang-side fixes written before
PR #3974 landed) are kept as provenance; their content is superseded by this
table and the pin.
