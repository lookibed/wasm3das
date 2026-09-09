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
3. **Preserve evidence.** The working tree may contain uncommitted fixes.
   Never discard or overwrite it before identifying and saving the current
   diff.
4. **One invariant at a time.** For runtime bugs, move from observation to one
   ownership/control-flow invariant, prove it with DAP and the C source, make
   the smallest patch, and rerun the real regression.
5. **Green tree at every accepted step.** Do not stack unrelated work on an
   unverified runtime fix or an unavailable module.
6. **The manifest is a contract.** `PORTING_MANIFEST.md` is the source of
   truth for accepted, in-revision, draft, and unstarted coverage. Only a code
   owner may mark work Accepted.

## Runtime recovery context

`source/` carries drafts of the environment, compiler and executor whose
provenance includes mechanical rewrites; see
`notes/runtime_recovery_context_2026-09.md` for the history, the checkpoint
commits on `origin/wip/runtime-layer`, and the fixes verified so far. The
facts that still drive priorities:

- `tests/integration/test_fib32_regression.das` runs `fib32.wasm` through parse, load,
  lazy compile, execution (`fib(25) = 75025`) and teardown. It is the
  regression every runtime change must keep green.
- The teardown `SIGSEGV` is closed: its cause was Daslang `delete` walking
  the pointer fields of `new`-allocated runtime objects (see "Allocation and
  pointer semantics").
- Priority now: review of the drafts against C (`m3_env`, `m3_compile`,
  `m3_exec`), then the remaining layers. Trampoline/tail-call architecture
  (the missing `M3_MUSTTAIL`) is a separate future task.

## Preserve the working tree before source changes

Before any edit to `source/`, capture the starting state:

```bash
git status --short
git diff --stat
git diff > "$SCRATCH/start.patch"
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
git diff <commit> -- source/m3_module.das
git show <commit>:source/m3_module.das > "$SCRATCH/m3_module.<commit>.das"
diff -u "$SCRATCH/m3_module.<commit>.das" source/m3_module.das
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

### Agent client configuration

Three servers are required, whichever client is used:

| Server | Purpose |
|---|---|
| `daslang` | compiler, navigation, lint, execution, introspection |
| `daslang-lsp` | native LSP diagnostics and navigation |
| `daslang-dap` | stateful DAP client |

- **Claude Code** reads `.mcp.json` (servers `daslang` and `daslang-dap`,
  relative paths, `DAS_LINT_CONFIG_PATH=.lint_config`) and the skills under
  `.claude/skills/`; the LSP plugin lives in `.claude/skills/daslang-lsp/`.
  Start the client from the repository root and restart it after any change
  to `.mcp.json` or the plugin manifest; skills reload on the fly. Setup and
  smoke checklist: `notes/claude_code_tooling_setup_2026-09-04.md`.
- **Codex** uses a project-local `.codex/config.toml` that is not tracked
  here; `notes/codex_tooling_smoke_test.md` describes its smoke test.
- All three servers use the daslang checkout pointed to by the `DASLANG_ROOT`
  environment variable, at the commit pinned in `scripts/daslang_pin` and
  built in place (README "Install and run"). `.mcp.json` runs
  `$DASLANG_ROOT/utils/mcp/mcp_supervisor.py` with
  `DASLANG_MCP_BIN=$DASLANG_ROOT/bin/daslang`; the LSP plugin runs
  `$DASLANG_ROOT/utils/lsp/lsp_supervisor.py`; restart the client after
  changing `DASLANG_ROOT`.
- The `daslang-dap` server runs the bridge `utils/dap/mcp_bridge.py` from the
  same `$DASLANG_ROOT` checkout — the DAP bridge and `utils/dap` are merged
  upstream (PR #3937) and the pin commit carries them.
- daslang is built from the pinned upstream source and never hand-patched
  for this project: a compiler bug is reported upstream with a reproducer,
  and the pin moves only through a deliberate bump recorded in
  `scripts/daslang_pin`.
- Before writing any new daslang tool (bridge, wrapper, script), check the open
  pull requests of `GaijinEntertainment/daScript`: the owner maintains the
  tooling there.

If configuration or bridge schemas change, restart the session; an existing
session does not reload MCP schemas. `notes/dap_tooling_update_2026-09-04.md`
records the current DAP contract.

## Runtime-debugging policy

Use only the configured `daslang-dap` tools. Do not write or revive ad-hoc DAP
harnesses (`tools/dapdrive.py`, `tools/dasdap_mcp.py`, `logs/probe*.py` and
similar historical scripts).

Do not use the wasm3 runtime itself as the smoke-test debuggee. Use
$DASLANG_ROOT/utils/dap/_fixture.das for connection smoke tests and the
real wasm runner only for scoped runtime investigation.

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
required; the stepping-race fix is in upstream, carried by the pin.

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

Do not build many competing hypotheses or combine runtime work with lint/style
cleanup.

## Allocation and pointer semantics

Every C-owned object (`M3Environment`, `M3Runtime`, `M3Module`, function
types, function and global arrays, code pages, stacks, linear memory) is a
host allocation, exactly as in C: obtained with `m3_Malloc_Impl` (zeroed,
like `m3_AllocStruct`/`m3_AllocArray`) and released with `m3_Free_Impl`.
`new`/`delete` are not used for `M3*` structs anywhere in `source/` or
`tests/`; the decision and its history are in `docs/memory-ownership.md`.

The reason is not style: a Daslang `delete` on a struct pointer finalizes
every pointer field, freeing the pointees and following cycles.
`M3Runtime.compilation.runtime` and `M3Runtime.error.runtime` point back at
the runtime, `M3Function._module` at the module, `M3Module.wasmStart` into
the caller's byte buffer, so `delete` on any of these overflows the stack or
frees foreign memory. That was the teardown `SIGSEGV`. Never reintroduce
`new` for an `M3*` object, and never `delete` one; a borrowed pointer field
needs no annotation because nothing walks it.

Two invariants verified during recovery must be preserved:
`Module_AddFunction` reads `funcTypes[i_typeIndex]` as a stored pointer
value, and `Environment_Release` frees `M3FuncType` nodes with
`m3_Free_Impl`.

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

Every change, of any type, goes through the stages in
`docs/development-pipeline.md`; that document defines the PR types, the
definition of done per stage and what CI enforces. The layer-specific steps
below are its "Reference" and "Implement" stages spelled out for a port.

Runtime recovery takes priority until teardown correctness is proven. When a
new layer is explicitly in scope:

1. Read `PORTING_MANIFEST.md` and `git log --oneline -15`.
2. Read the complete C source and header before writing Daslang.
3. Create `source/<c_file_stem>.das` with the same names, function order,
   control flow, edge cases, and intentional quirks where Daslang permits.
4. Document every necessary semantic deviation from C at the adapted site.
5. Add `tests/integration/test_<c_file_stem>.das` following the one-test-file-per-source
   convention.
6. Run the full verification gate and compare the final diff against C again.

Files marked **Draft** in the manifest (`m3_env`, `m3_compile`, `m3_exec`,
`m3_exec_defs`, `m3_exception`) are not accepted code. Promoting one means
reviewing it against C section by section and giving it a test file, not
reformatting it.

## Verification policy

The tree is lint-clean under `.lint_config`; keep it that way. Do not mix
lint/style changes with runtime fixes in one commit, and do not silence a
fixable finding by adding a rule to `.lint_config`.

All authoritative verification uses one daslang: the upstream source commit
pinned in `scripts/daslang_pin`, checked out from
GaijinEntertainment/daScript and built locally by whoever uses this
repository (see README "Install and run" and `scripts/build-daslang.sh`).
The checkout path goes into `DASLANG_ROOT`; `scripts/verify_daslang.sh`
compares the checkout HEAD (or its `.daslang-commit` marker) against the pin
and refuses anything else. Never hand-patch daslang: a compiler bug is
reported upstream with a reproducer, and the pin moves only through a
deliberate bump (build the new commit, full gate, land the port
adaptations, commit the new sha). A local experiment with a different
checkout must set `DASLANG_ALLOW_UNPINNED=1` and cannot claim a green gate.

Run:

```sh
scripts/gate.sh
```

It is the single definition of the gate, used unchanged by CI and the
pre-push hook: `-compile-only` on every file under `source/` and
`tests/integration/`; the
three lint profiles with zero findings under `.lint_config` (which disables
only the rules whose findings are the faithful spelling of the C source); the
full dastest suite. `scripts/gate.sh <stage>` runs one stage (`compile`,
`lint-paranoid`, `lint-perf`, `lint-style`, `test`).

Also run the focused test for the changed layer. Runtime/lifecycle changes
must additionally pass the real `fib32.wasm` regression through result
retrieval **and teardown without a crash**. That regression is not yet in
`tests/integration/`; if the runner is absent or cannot reproduce that lifecycle, report
the missing verification rather than claiming completion.

The MCP compiler, LSP, lint, and test tools are development aids. The pinned
CLI gate is authoritative even if the server is bound to another tree.

## Code conventions

- Use Gen2 syntax: start every `.das` with `options gen2` and
  `options indenting = 4`.
- Use `module <name> shared public`, relative local requires
  (`require ./m3_core.das`), and re-export (`public`) only the dependencies
  that the corresponding C header itself includes.
- Add a top-of-file C-origin comment, for example
  `// Conservative Gen2 port of m3_exec.h.`
- Keep lint suppressions narrow and on the offending line when C fidelity
  requires the flagged shape. Repo-wide exceptions live only in
  `.lint_config`, each with its reason.
- Do not rename ported identifiers; C names are part of the contract. Where a
  C name is a Daslang keyword, use the established `_type`, `_module`,
  `_function`, `_block` spelling.
- Do not apply mass regex/Python transformations to pointer types, ownership,
  `unsafe`, allocator semantics, or C-macro adaptations. Prove a mechanical
  change at one call site, compile and regress it, then consider expansion.

## Scratch and session artefacts

`tmp/`, `tools/` and `logs/` are ignored and machine-local. Agent transcripts
and raw model logs never go into the tree; dated working notes go into
`notes/` only when a later session needs them.

## Git workflow and commit discipline

- Work on feature branches and open PRs into `main`; do not push directly to
  `main`. Enable the local gate once per clone:
  `git config core.hooksPath .githooks`. The hook runs the gate only when
  the pushed commits touch its inputs (the CI path filter) and never for a
  branch deletion.
- Open every PR as a draft (`gh pr create --draft`) and mark it ready
  (`gh pr ready`) only after the last push is confirmed on the remote; the
  owner merges ready PRs only. Never push to the branch of a merged PR (the
  push recreates the deleted branch); commits that missed a merge go on a
  fresh branch from `main` in a new PR.
- Confirm a push from git, not from a wrapper's exit code: `git status -sb`
  shows no `[ahead N]` and `gh pr view <N> --json commits` lists the commit.
  `origin` is HTTPS with the `gh` credential helper (`gh auth setup-git`).
- After a merge, and at the end of every session, run
  `scripts/prune_merged_branches.sh` (then `--delete`): it removes local
  branches whose content is already in `main`, including the
  `worktree-agent-*` branches left by agents once their commits were taken.
  Leave no untracked files behind: commit, ignore with a reason, or delete.
- Make every proven runtime fix a separate commit. Keep separate commits for
  mechanical restoration, the pointer-value fix, allocator-pair fix, teardown
  root cause, and regression test when those are distinct changes.
- `main` receives one squash commit per PR, so the PR title and body are the
  commit message that survives: the title must state the proven invariant or
  C comparison, the body the verification. Individual branch commits stay
  focused but need not repeat this.
- Do not mix runtime fixes with lint/style cleanup.
- One bounded port layer or focused fix per PR. State what was changed and
  intentionally deferred.
- CI passing does not promote a manifest entry to Accepted; code-owner review
  is required. `main` requires the `Daslang quality gate` check through
  branch protection; review stays the owner's discipline because owner and
  agents share one GitHub account.
- Do not commit anything from `tmp/` or `tools/`, and do not create new
  `*:Zone.Identifier` artifacts.

## Key files

| File | Purpose |
|---|---|
| `README.md` | user-facing overview: capabilities, usage, toolchain install |
| `PORTING_MANIFEST.md` | per-file status and acceptance boundary |
| `CLAUDE.md` | short entry point for Claude Code; defers to this file |
| `.mcp.json`, `.claude/skills/` | Claude Code MCP servers, LSP plugin and skills |
| `.lint_config` | repo lint policy and the reason for every disabled rule |
| `docs/development-pipeline.md` | stages, PR types and definition of done for every change |
| `docs/memory-ownership.md` | allocation-regime decision and migration order |
| `.github/pull_request_template.md` | PR skeleton: scope, C references, verification, manifest transition, C checklist |
| `.githooks/pre-push` | local form of the CI quality gate |
| `scripts/daslang_pin`, `scripts/verify_daslang.sh` | the pinned daslang source commit and the checkout/build verifier |
| `docs/upstream-status.md` | daslang issues/PRs the pin carries, verified per issue |
| `notes/handoff_claude_code_2026-09-07.md` | latest session handoff (state of `main` and the open PR, pipeline order, pitfalls); older handoffs are dated the same way |
| `notes/runtime_recovery_context_2026-09.md` | provenance of `source/`, checkpoint commits, teardown state |
| `notes/dap_tooling_update_2026-09-04.md` | current DAP lifecycle, fixes, and failure triage |
| `wasm3c/source/` | read-only C semantic reference |
| `source/`, `tests/integration/` | the Daslang port and the component tests the gate runs |
| `tests/manual/` | manual fixture sets and `run_fixtures.py`; outside the gate |
| `tests/host_test/` | Daslang counterparts of `wasm3c/host_test` (embedding through the public API); compiled and linted by the gate |
| `app/`, `scripts/wasm3` | the command line front end (port of `platforms/app/main.c`) and its interpreted launcher |
| `native/`, `scripts/build_port.sh`, `scripts/wasm3-native` | AOT build: C++ host, build script and native launcher (`notes/native_aot_status.md`) |
| `scripts/bench.sh`, `notes/benchmark_2026-09-07.md` | cross-engine fib32 benchmark and its results |
| `scripts/gate.sh`, `scripts/check_repo_invariants.sh` | the gate shared by CI and the pre-push hook |
