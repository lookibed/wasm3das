# AGENTS.md

Instructions for AI coding agents working in this repository. Read this file
before writing or reviewing any code here.

## What this project is

This repository is a manual, incremental port of
[Wasm3](https://github.com/wasm3/wasm3), a WebAssembly interpreter, from C to
Daslang. `wasm3c/source/` is the vendored, read-only C reference. The goal is
**structural and semantic fidelity**: the Daslang tree must mirror the C tree,
not merely produce similar output.

The WASI layer (`m3_api_wasi.c` and related files) is intentionally out of
scope.

## Working principles

Resolve uncertainty with these principles, in order:

1. **Fidelity over cleverness.** Preserve C file ownership, function and
   variable names, ordering, control flow, edge cases, and quirks. Do not
   replace an algorithm with a prettier equivalent.
2. **Proof over assumption.** Compare with the actual C source and prove
   pointer, ownership, and allocator semantics. Compilation and existing unit
   tests alone do not prove that a port is correct.
3. **Preserve evidence.** The working tree may contain important uncommitted
   post-Qwen fixes. Never discard or overwrite it before identifying and
   saving the current diff.
4. **One invariant at a time.** For runtime bugs, move from observation to one
   ownership/control-flow invariant, prove it with DAP and the C source, make
   the smallest patch, and rerun the real regression.
5. **Green tree at every accepted step.** Do not stack unrelated work on an
   unverified runtime fix or an unavailable module.
6. **The manifest is a contract.** `PORTING_MANIFEST.md` is the source of
   truth for accepted, in-revision, and unstarted coverage. Only a code owner
   may mark work Accepted.

## Current recovery context — read before touching `source/`

The current `source/` tree has a complicated provenance. Before Qwen, GLM
performed large mechanical C-to-Daslang merge/fix passes, including:

- Python/regex rewrites of `m3_parse.das` and `m3_module.das`;
- an `m3log(...)` stripper that once truncated the starts of both files;
- pointer-typedef rewrites that could turn an existing pointer alias into
  effective pointer-to-pointer semantics;
- generic emulations of `m3_Free` and `m3_ReallocArray`, later replaced with
  explicit C-macro expansion;
- function moves between `m3_env` and `m3_module` that temporarily produced
  duplicate definitions.

Many of those defects were subsequently fixed. Do **not** assume that the
current tree is corrupt, and do **not** assume that it is canonical merely
because it compiles. When code looks suspicious, establish its provenance
before adding another workaround.

Useful committed checkpoints are:

```text
7c25b78  Fix wasm magic byte order and module deallocation found via DAP stepping
9a2058e  Phase 2: wire CompileFunctionHook/ResizeMemoryHook at m3_NewEnvironment
5fb3c38  Record phase 1 outcome and lint findings distribution
```

`7c25b78` is a useful clean comparison point, not absolute semantic truth.
Important fixes discovered after it may still be uncommitted.

### Confirmed runtime state

A real `fib32.wasm` run has already completed parse, load, compile, export
lookup, execution, and result retrieval with these results:

```text
fib(2)  = 1
fib(10) = 55
fib(25) = 75025
```

Do not restart investigation at the parser/compiler without new evidence of a
regression. The main unresolved issue is a teardown `SIGSEGV`, with the known
path:

```text
m3_FreeRuntime
    -> Runtime_Release
        -> ForEachModule
            -> _FreeModule
                -> m3_FreeModule
```

The current priority is:

```text
real wasm correctness -> teardown correctness -> regression -> cleanup
```

The larger Daslang stack used by the temporary fib runner compensates for the
absence of a C `M3_MUSTTAIL` equivalent. Trampoline/tail-call architecture is
a separate future task and must not be mixed with teardown repair.

## Preserve the working tree before source changes

Before any edit to `source/`, capture the starting state:

```bash
git status --short
git diff --stat
git diff > /tmp/codex-onboard-start.patch
git log --oneline --decorate --graph -12
```

Do not use any of the following at startup or as a shortcut:

```bash
git reset --hard
git checkout -- source/
git restore source/
```

Before replacing even one suspicious hunk, compare all three sources of
evidence:

```text
current Daslang
    <-> relevant Git commit
    <-> wasm3c/source/*.c
```

For example:

```bash
git log --oneline -- source/m3_module.das
git diff 7c25b78 -- source/m3_module.das
git show 7c25b78:source/m3_module.das > /tmp/m3_module.7c25b78.das
diff -u /tmp/m3_module.7c25b78.das source/m3_module.das
```

Use Git to recover previously tracked Daslang text and the C source to prove
semantic ownership, pointer layout, and allocator pairing. If a hunk is proven
to be mechanical damage, restore only that hunk (or a carefully selected
file), then reapply independently proven later fixes. Never repair suspicious
code from memory.

## Tooling policy for `.das` — mandatory

All work on `.das` files in `source/` and `tests/` goes through Daslang-aware
tools. Shell text munging (`grep`/`sed`/`awk` plus redirection, Python I/O,
or `cat`-based rewrite scripts) is forbidden for `.das`: it bypasses
diagnostics and obscures fidelity review.

| Task | Use | Never |
|---|---|---|
| Read / edit / create `.das` | `read` / `edit` / `write` tools | shell or Python I/O |
| Symbol / definition lookup | `daslang_find_symbol`, `daslang_goto_definition`, `daslang_outline` | grep over `source/` |
| Usages / references | `daslang_grep_usage`, `daslang_find_references` | grep over `source/` |
| Types / module API | `daslang_describe_type`, `daslang_list_types`, `daslang_list_module_api`, `daslang_list_functions`, `daslang_list_requires` | ad-hoc stdlib reading |
| Compile check | `daslang_compile_check` | ad-hoc CLI during editing |
| Lint | `daslang_lint` | manual pattern greps |
| Format | `daslang_format_file` | any other rewrite |
| Tests / execution | `daslang_run_test`, `daslang_run_script`, `daslang_eval_expression` | new scratch runners |
| Introspection | `daslang_program_log`, `daslang_ast_dump`, `daslang_type_of`, `daslang_aot` | guesswork |

- Load the `daslang` skill before writing or reviewing `.das`. Load the
  formatting and testing skills when those tasks apply.
- Treat every new compiler/LSP `ERROR` after an edit as stop-ship.
- Bash is allowed for Git operations and the pinned verification commands
  below. Non-`.das` files and the C reference may be searched with normal
  text tools. Use `daslang_cpp_*` tools for C++ elsewhere.
- Lint and formatting during development must use Daslang tools, not a
  shell-invoked system compiler.

### Codex MCP/LSP/DAP configuration

Codex uses the project-local `.codex/config.toml`, provided the project is
trusted in `/root/.codex/config.toml`. It should expose three required STDIO
servers:

| Server | Purpose |
|---|---|
| `daslang` | compiler, navigation, lint, execution, introspection |
| `daslang-lsp` | native LSP diagnostics and navigation |
| `daslang-dap` | stateful DAP client |

The `daslang` and `daslang-lsp` servers must use the project-pinned compiler at
`tmp/daslang-toolchain/bin/daslang`. The `daslang-dap` server currently uses
the bridge and executable from the live `/root/daScript` checkout because that
binary contains the repaired statement-stepping lifecycle. Do not silently
switch DAP back to the older pinned binary until the fix is present in the
pinned toolchain. The pinned compiler remains authoritative for the project
verification gate.

If configuration or bridge schemas change, restart the Codex session; an
existing session does not reload MCP schemas. Follow
`notes/codex_tooling_smoke_test.md` to verify the connection and
`notes/dap_tooling_update_2026-09-04.md` for the current DAP contract.

`opencode.json` remains relevant to clients that consume it, but it is not a
substitute for Codex's `.codex/config.toml` layers.

## Runtime-debugging policy

Use only the configured `daslang-dap` tools. Do not restore, extend, or replace
them with Qwen's custom harnesses such as:

```text
tools/dapdrive.py
tools/dasdap_mcp.py
logs/mcp_probe*.py
logs/probe*.py
```

Do not use the wasm3 runtime itself as the smoke-test debuggee. Use
`/root/daScript/utils/dap/_fixture.das` for connection smoke tests and the real
wasm runner only for scoped runtime investigation.

### DAP session contract

`daslang-dap` is stateful: one MCP bridge owns one DAP connection and the
debuggee created by `debug_launch`. For a local launch, use this order:

```text
debug_launch(file=..., stepping_debugger=true|false; omit port)
    -> debug_set_breakpoints (optional, repeat once per source file)
    -> debug_threads
    -> debug_configuration_done
    -> debug_wait_event(event="stopped" or "terminated")
```

`debug_launch` already connects, initializes DAP, sends `launch`, and waits for
the `initialized` event. Do not call `debug_connect` or `debug_initialize`
after it. `debug_threads` is the required daScript startup gate and must happen
before `debug_configuration_done`. In default instrumentation mode a source
breakpoint may initially be reported as unverified; do not diagnose that as a
failure before `configurationDone` has instrumented the available contexts and
the subsequent breakpoint events have been observed.

At a stop, inspect state in this order:

```text
debug_stack_trace
    -> debug_scopes for the selected frame
    -> debug_variables for every relevant scope/object
    -> debug_evaluate when a focused expression is needed
```

Inspect every scope returned by `debug_scopes`, not only locals, arguments, and
globals. Modules can add debugger-macro scopes through `report_context_state`;
for example OpenGL state and DECS state appear as normal expandable scopes.

Resume with `debug_continue`, `debug_step_in`, `debug_step_over`, or
`debug_step_out`, then consume `continued`, `stopped`, or `terminated` through
`debug_wait_event`. Use default instrumentation mode for ordinary breakpoint
investigation. Pass `stepping_debugger=true` when statement-level stepping is
required; the live `/root/daScript/bin/daslang` contains the stepping-race fix.

Omit `port` on `debug_launch`; the bridge allocates an available local port.
Specify a port only when an external process must know it in advance. Never
solve a failed session by repeatedly launching listeners on new hard-coded
ports. First call `debug_disconnect`, which is idempotent, and inspect its
`session` snapshot: `connected`, `pid`, `return_code`, `close_reason`,
`last_dap_termination`, and `process_output_tail`. An already closed peer is a
successful cleanup with `already_disconnected=true`, not a tool failure. Start
a new launch only after the previous session is disconnected and its owned
process has exited.

For attach, use the separate sequence:

```text
debug_connect -> debug_initialize -> debug_attach
    -> debug_threads -> debug_configuration_done
```

The first teardown invariant to prove is:

> `runtime.modules` is the same valid `IM3Module` created by `m3_ParseModule`
> and loaded into the runtime.

At relevant breakpoints record `runtime.modules`, `_module`, `next`,
`i_module`, and the call stack. For every released object record:

```text
pointer
allocated by
owned by
freed by
expected allocator pair
```

Follow linked-list teardown carefully, especially:

```text
runtime.modules
module.next
environment.funcTypes
funcType.next
pagesOpen
pagesFull
pagesReleased
```

Save `next` before freeing the current node and prove that callbacks/visitors
do not touch a freed container or link. Do not patch teardown from a hypothesis
without breakpoint evidence.

Use this investigation loop:

```text
observation
    -> one invariant
    -> DAP plus comparison with C
    -> minimal patch
    -> real fib regression
    -> focused/unit regression
    -> final gate
    -> focused commit
```

Do not build many competing hypotheses or combine runtime work with mass
lint/style cleanup.

## Allocation and pointer semantics

Never select a deallocator from an object's type or function name. Establish
the allocation provenance of that exact pointer:

```text
Daslang new T()      <-> delete
m3_Malloc_Impl(...)  <-> m3_Free_Impl(...)
```

Known historical mistakes occurred in both directions: using `m3_Free_Impl`
for `new M3Module()`, and using `delete` for an `M3FuncType` returned by
`AllocFuncType`/`m3_Malloc_Impl`.

For C arrays, first determine whether the array stores structs or pointer
values. Never transfer the `addr(array[i])` idiom between those cases. In
particular, `funcTypes` stores pointer values:

```das
unsafe {
    var ft : IM3FuncType = io_module.funcTypes[i_typeIndex]
}
```

Using `reinterpret<IM3FuncType>(addr(io_module.funcTypes[i_typeIndex]))`
produces pointer-to-pointer semantics and is incorrect.

## Required post-Qwen checks

Before starting a new runtime hypothesis, independently verify these current
working-tree fixes against their C allocation/pointer provenance:

1. `Module_AddFunction` reads `funcTypes[i_typeIndex]` as the stored pointer
   value, without `addr(slot)`. This preserves `function -> funcType ->
   numArgs/numRets` and avoids false `local index out of bounds` failures.
2. `Environment_Release` releases an `M3FuncType` allocated through
   `m3_Malloc_Impl` with `m3_Free_Impl`, not `delete`. Trace
   `AllocFuncType`, `Environment_AddFuncType`, and `Environment_Release`
   against C `m3_env.c`.

Do not assume these fixes are correct merely because they are present; verify
them once, preserve them, and avoid overwriting them during restoration.

## High-risk source areas

- **`m3_module.das` — highest audit priority.** Verify pointer-array indexing,
  string/null semantics, explicit macro expansion, and allocator ownership.
- **`m3_env.das`.** Keep `Module_FreeFunctions` and `m3_FreeModule` owned by
  `m3_module`, as in C. Never reintroduce duplicate implementations to silence
  a compile error. Check every allocator pair.
- **`m3_core.das`.** Do not reintroduce generic `m3_Free(auto&)` or
  `m3_ReallocArray(auto)` helpers without a proof that typed-pointer semantics
  remain identical. Prefer explicit C-macro expansion at call sites.
- **`m3_parse.das`.** It was mechanically expanded to a full parser and had
  logging stripped. Compare strange structure with Git and
  `wasm3c/source/m3_parse.c`; do not write another parser on top of it.

## Porting workflow for a new C layer

Runtime recovery takes priority until teardown correctness is proven. When a
new layer is explicitly in scope:

1. Read `PORTING_MANIFEST.md` and `git log --oneline -15`.
2. Read the complete C source and header before writing Daslang.
3. Create `source/<c_file_stem>.das` with the same names, function order,
   control flow, edge cases, and intentional quirks where Daslang permits.
4. Document every necessary semantic deviation from C at the adapted site.
5. Add `tests/test_<c_file_stem>.das` following the one-test-file-per-source
   convention.
6. Run the full verification gate and compare the final diff against C again.

Existing work-in-progress drafts such as `source/m3_compile.das` and
`source/m3_exec.das` may depend on modules that are not yet ported. Treat them
as drafts, not accepted code, and do not casually reformat them.

## Verification policy

During teardown investigation, lint is not a blocker for the short
observation/patch/regression loop. The historical lint backlog must not pull
the task into an unrelated mass cleanup. However, before claiming any source
change complete, the full pinned gate remains mandatory.

All authoritative verification uses Daslang 0.6.4, commit
`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`, at
`tmp/daslang-toolchain/bin/daslang`. Never silently substitute another
compiler. If the pinned toolchain is missing, follow `README.md` or report the
blocker.

Run:

```sh
DASLANG="$PWD/tmp/daslang-toolchain/bin/daslang"

# 1. Compiler diagnostics on every source and test
for file in source/*.das tests/*.das; do
    "$DASLANG" -compile-only "$file" || exit 1
done

# 2. All three lint profiles, zero findings
for profile in paranoid-only perf-only style-only; do
    "$DASLANG" tmp/daslang-toolchain/utils/lint/main.das -- --"$profile" source tests || exit 1
done

# 3. Full component test suite
"$DASLANG" tmp/daslang-toolchain/dastest/dastest.das -- --test tests
```

Also run the focused test for the changed layer. Runtime/lifecycle changes
must additionally pass the established real `fib32.wasm` regression through
result retrieval **and teardown without a crash**. If the runner is absent or
cannot reproduce that lifecycle, report the missing verification rather than
claiming completion.

The MCP compiler, LSP, lint, and test tools are development aids. The pinned
CLI gate is authoritative even if the server is bound to another tree.

## Code conventions

- Use Gen2 syntax: start every `.das` with `options gen2` and follow existing
  sources with `options indenting = 4`.
- Use `module <name> shared public`, relative local requires, and re-export
  dependencies exposed by the corresponding C header.
- Add a top-of-file C-origin comment, for example
  `// Conservative Gen2 port of m3_exec.h.`
- Keep lint suppressions narrow and on the offending line when C fidelity
  requires the flagged shape.
- Do not rename ported identifiers; C names are part of the contract.
- Do not apply mass regex/Python transformations to pointer types, ownership,
  `unsafe`, allocator semantics, or C-macro adaptations. Prove a mechanical
  change at one call site, compile and regress it, then consider expansion.

## Scratch cleanup

After preserving useful evidence, inspect and remove obsolete Qwen scratch if
it still exists:

```text
tools/dapdrive.py
tools/dasdap_mcp.py
logs/mcp_probe*.py
logs/probe*.py
logs/run*.json
logs/dasdap_*
logs/cc*.das
logs/callcount.das
logs/free_probe.das
```

Remove a stale Qwen DAP MCP registration from `opencode.json` if present.
For `tools/teardown_test.das`, either delete it or convert it into one normal
regression test in the standard suite. Because ignored scratch is not
recoverable from Git, first prove that it is not the only copy of important
evidence. Do not delete user logs or active processes broadly.

## Git workflow and commit discipline

- Work on feature branches and open PRs into `main`; do not push directly to
  `main`.
- Make every proven runtime fix a separate commit. Keep separate commits for
  mechanical restoration, the pointer-value fix, allocator-pair fix, teardown
  root cause, and regression test when those are distinct changes.
- Commit messages must state the proven invariant or C comparison, not only
  describe the edit.
- Do not mix runtime fixes with lint/style cleanup.
- One bounded port layer or focused fix per PR. State what was changed and
  intentionally deferred.
- CI passing does not promote a manifest entry to Accepted; code-owner review
  is required.
- Do not commit anything from `tmp/` or `tools/`, and do not create new
  `*:Zone.Identifier` artifacts.

## Key files

| File | Purpose |
|---|---|
| `README.md` | project overview and local verification recipes |
| `PORTING_MANIFEST.md` | per-file status and acceptance boundary |
| `CLAUDE.md` | Claude-specific pointer to repository rules |
| `.codex/config.toml` | project-local Codex MCP/LSP/DAP configuration |
| `opencode.json` | project overrides for clients that consume it |
| `notes/codex_tooling_smoke_test.md` | Codex tool connection smoke test |
| `notes/dap_tooling_update_2026-09-04.md` | current DAP lifecycle, fixes, and failure triage |
| `notes/codex_onboard_after_shit.md` | GLM/Qwen recovery history and runtime context |
| `wasm3c/source/` | read-only C semantic reference |
| `source/`, `tests/` | the Daslang port and component tests |
| `main.das`, `lib/`, `demo_*.das` | unrelated Daslang sandbox demos |
| `.githooks/pre-push` | local form of the CI quality gate |
