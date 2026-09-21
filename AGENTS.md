# AGENTS.md

Instructions for AI coding agents working in this repository. Read this file
before writing or reviewing any code here.

## What this project is

This repository is a manual, incremental port of
[Wasm3](https://github.com/wasm3/wasm3), a WebAssembly interpreter, from C to
Daslang. `wasm3c/source/` is the vendored, read-only C reference. The goal is
**structural and semantic fidelity**: the Daslang tree must mirror the C tree,
not merely produce similar output.

The plain WASI host layer (`m3_api_wasi.c`, `extra/wasi_core.h`) is part of
the port; the uvwasi and meta-WASI variants are excluded
(`PORTING_MANIFEST.md`).

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

## Provenance of `source/`

The environment, compiler and executor layers were first produced in August
2026 by sessions that applied mechanical C-to-Daslang passes: Python/regex
rewrites of `m3_parse.das` and `m3_module.das`, an `m3log(...)` stripper that
once truncated the starts of both files, pointer-typedef rewrites that could
turn a pointer alias into pointer-to-pointer semantics, generic emulations of
`m3_Free`/`m3_ReallocArray` (since replaced by explicit macro expansion) and
function moves between `m3_env` and `m3_module` that briefly produced
duplicate definitions. Most of that damage was repaired and every layer has
since been reviewed against C (`PORTING_MANIFEST.md`), so do not assume the
tree is corrupt; but when a hunk looks strange, establish its provenance
through Git and the C source before adding a workaround. The checkpoints of
that recovery live on `origin/wip/runtime-layer` (`7c25b78` magic byte order
and module deallocation, `9a2058e` hook wiring, `5fb3c38` phase 1 outcome),
squashed into `main` as `3104b5f`; `7c25b78` is a clean comparison point,
not semantic truth.

Facts that still drive priorities:

- `tests/integration/test_fib32_regression.das` runs `fib32.wasm` through
  parse, load, lazy compile, execution (`fib(25) = 75025`) and teardown. It is
  the regression every runtime change must keep green.
- The teardown `SIGSEGV` is closed (2026-09-06): its cause was Daslang
  `delete` walking the pointer fields of `new`-allocated runtime objects
  (`docs/memory-ownership.md`, "Allocation and pointer semantics" below).
- The missing `M3_MUSTTAIL` is answered by the `RunLoop` dispatcher
  (`docs/execution-design.md`); speed beyond the interpreter comes from the
  native tiers (`docs/native-build.md`).

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
| Read / edit / create any file | `Read` / `Edit` / `Write` tools | `cat`, `sed`, heredocs, Python I/O |
| Symbol / definition lookup | `mcp__daslang__find_symbol`, `goto_definition`, `outline`; LSP `documentSymbol`, `goToDefinition`, `hover` | grep over `source/` |
| Usages / references | `mcp__daslang__grep_usage`, `find_references`; LSP `findReferences` | grep over `source/` |
| Types / module API | `mcp__daslang__list_types`, `describe_type` (daslib types), `list_module_api`, `list_functions`, `list_requires`, `discover` | ad-hoc stdlib reading |
| Compile check | `mcp__daslang__compile_check`; the LSP diagnostics after every edit | ad-hoc CLI during editing |
| Lint | `mcp__daslang__lint` | manual pattern greps |
| Format | `mcp__daslang__format_file` | any other rewrite |
| Tests / execution | `mcp__daslang__run_test`, `run_script`, `eval_expression` | new scratch runners |
| Introspection | `mcp__daslang__program_log`, `ast_dump`, `type_of`, `aot` | guesswork |
| C reference | `mcp__daslang__cpp_grep_usage`, `cpp_outline`, `cpp_find_symbol`, `cpp_goto_definition` over `wasm3c/source` (needs the root `sgconfig.yml`) | rewriting the C |
| Runtime investigation | the `mcp__daslang-dap__*` tools (contract below) | ad-hoc DAP harnesses |

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

- **Claude Code** reads `.mcp.json` (servers `daslang` and `daslang-dap`) and
  the skills under `.claude/skills/`; the LSP plugin lives in
  `.claude/skills/daslang-lsp/`. Start the client from the repository root and
  restart it after any change to `.mcp.json` or the plugin manifest; skills
  reload on the fly. Smoke: `mcp__daslang__compile_check` on
  `source/m3_core.das` answers `Compilation OK.`, LSP `documentSymbol` on it
  lists its functions, and a `debug_launch` of
  `/root/daScript/utils/dap/_fixture.das` reaches `terminated`.
- All three servers use the daslang checkout at `/root/daScript`, built in
  place with the `stddlg` and `dasHV` modules (README "Install and run").
  `.mcp.json` runs the MCP server through that checkout's `bin/watchdog`
  stdio front (`--cwd` = this repository, so relative tool paths resolve
  here; the child respawns after a crash or the `shutdown` tool) and the
  `daslang-dap` server the same way over `utils/dap/main.das`; the LSP
  plugin (`.claude/skills/daslang-lsp/.claude-plugin/plugin.json`) runs
  `bin/watchdog --lsp`. All three carry `DAS_LINT_CONFIG_PATH` pointing at
  `.lint_config`. The shell side (`scripts/`, the gate, the hook) reads
  `DASLANG_ROOT` from the environment: `.env` (untracked) holds it for the
  shell profile and `.claude/settings.local.json` (untracked) carries the
  same `"env"` block for Claude Code. Restart the client after changing
  `.mcp.json` or the plugin manifest.
- `sgconfig.yml` in the repository root (untracked, machine-local like
  `.mcp.json`) maps `*.h`, `*.hpp` and `*.c` to ast-grep's C++ grammar; without
  it the `cpp_*` MCP tools skip every header and every `.c` file of `wasm3c/`.
- Tool scope in this repository: `list_functions`, `aot`, `program_log` and
  `find_symbol` with `file=` see only the main module of the program they
  compile, so for a `module m3_* shared public` source pass the integration
  test that requires it (`tests/integration/test_m3_<name>.das`) as the
  file; `describe_type` cannot name a project file as its module, use
  `list_types` on the file instead. `find_dupe`/`judge_duplicates` need the
  `anthropic/anthropic` daspkg and an API key; `live_*` need a GLFW window;
  neither is used here.
- daslang is built from the pinned upstream source and never hand-patched
  for this project: a compiler bug is reported upstream with a reproducer,
  and the pin moves only through a deliberate bump recorded in
  `scripts/daslang_pin`.
- Before writing any new daslang tool (bridge, wrapper, script), check the open
  pull requests of `GaijinEntertainment/daScript`: the owner maintains the
  tooling there.

If configuration or bridge schemas change, restart the session; an existing
session does not reload MCP schemas.

## Runtime-debugging policy

Use only the configured `daslang-dap` tools. Do not write or revive ad-hoc DAP
harnesses (`tools/dapdrive.py`, `tools/dasdap_mcp.py`, `logs/probe*.py` and
similar historical scripts).

Do not use the wasm3 runtime itself as the smoke-test debuggee. Use
`$DASLANG_ROOT/utils/dap/_fixture.das` for connection smoke tests and the
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

When a new layer is in scope:

1. Read `PORTING_MANIFEST.md` and `git log --oneline -15`.
2. Read the complete C source and header before writing Daslang.
3. Create `source/<c_file_stem>.das` with the same names, function order,
   control flow, edge cases, and intentional quirks where Daslang permits.
4. Document every necessary semantic deviation from C at the adapted site.
5. Add `tests/integration/test_<c_file_stem>.das` following the one-test-file-per-source
   convention.
6. Run the full verification gate and compare the final diff against C again.

Files marked **Draft** (`m3_exception`, `m3_exec_defs`, `m3_exec_expand`) or
**Revision** (`m3_bind`, `m3_parse`, `m3_env`, `m3_compile`, `m3_exec`, the
host modules, the app) in the manifest are not accepted code. Promoting one
means reviewing it against C section by section and giving it a test file,
not reformatting it; only the code owner sets Accepted.

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
pre-push hook: `-compile-only` on every file under `source/`,
`tests/integration/`, `app/` and `tests/host_test/`; the three lint profiles
with zero findings under `.lint_config` (which disables only the rules whose
findings are the faithful spelling of the C source); the full dastest suite;
the repository invariants (`scripts/check_repo_invariants.sh`: formatter
verify, test discovery, manifest consistency, file headers).
`scripts/gate.sh <stage>` runs one stage (`compile`, `lint-paranoid`,
`lint-perf`, `lint-style`, `test`, `invariants`).

Also run the focused test for the changed layer. Runtime/lifecycle changes
must additionally keep `tests/integration/test_fib32_regression.das` green
through result retrieval **and teardown without a crash**, and, before they
land, the original spec and WASI drivers (`docs/test-suites.md`); an AOT-facing
change also rebuilds the native tiers and runs the same drivers through them
(`docs/native-build.md`).

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

## C constructs and their Daslang spellings

Recurring translations, each proven in the accepted layers; reuse them instead
of inventing another:

- C keywords that are Daslang keywords: `_type`, `_module`, `_function`,
  `_block`; a `label` parameter becomes `stage`. `else if` is `elif`.
- Functions are not nullable: a C `NULL` function pointer is a sentinel
  (`c_opNull`, `c_noCompiler`) compared with `==`; a function value is `@@fn`.
- `let` is const and const flows through pointers; every mutated binding and
  every parameter the callee writes through is `var` (also what the JIT needs,
  `docs/upstream-status.md` #3991). `reinterpret<T>(x)` and `unsafe { }`
  strip it where C casts.
- No arithmetic on `u8`/`u16`: compiler scalars are `int` (documented in
  `m3_types.das`), fields are cast at the use site. Hex literals are `uint`.
- `unsafe(...)` on an expression does not cover indexing; pointer indexing
  needs an `unsafe { }` block. `addr(ptr[i])` yields a reference-qualified
  value; bind it through an explicit type or `reinterpret`.
- Strings are not nullable: `empty(s)` for `== NULL`, `""` for `NULL`; C
  `m3_Free(name)` is a no-op with a comment (`docs/memory-ownership.md`).
- C macros (`m3_Free`, `m3_ReallocArray`, `m3_AllocArray`, `_try`/`_throwif`,
  `m3ApiRawFunction`, `m3log`) are expanded at the call site, never wrapped in
  a generic helper with `auto&` (it conflicts with string fields).
- C include cycles are broken by the shared type hub `m3_types.das` and by
  function-valued globals (`CompileFunctionHook`, `ResizeMemoryHook`) wired
  in `m3_NewEnvironment`; `require` edges follow the C includes, `public`
  only where the header itself includes the dependency.
- A void helper whose only effect is a write through a raw pointer needs
  `[sideeffects]`, or the optimizer drops the call.
- Leading `__` identifiers are reserved: `__WASI_X` is `WASI_X`.
- Under the lint profiles (`no_infer_time_folding`) an enum-indexed fixed
  array size such as `IM3FuncType[int(M3ValueType.c_m3Type_unknown)]` stops
  folding; spell the literal with a comment.

## Pitfalls

Collected from the session handoffs; each cost a session time once.

- `Result:` goes to stderr in both app modes, as in C `main.c`: capture with
  `2>&1`. `grep -q` on REPL output under `pipefail` gives SIGPIPE: capture
  into a variable first.
- Tests that write under `tmp/` must `mkdir("tmp")`: CI has no such directory.
- Never run the WASI driver or a measurement while `source/` is being edited
  or while another gate or build runs; measure on a quiet machine.
- `pgrep -f`/`pkill -f` with a pattern that matches your own command line
  kills the shell; anchor the pattern or exclude `$$`. Never `pkill daslang`
  broadly: other sessions' MCP and LSP servers are daslang processes.
- Background Bash commands longer than ten minutes die with the wait; run a
  build in the background and poll its log.
- Git Bash on Windows: `[[ -f daslang_static ]]` is true for
  `daslang_static.exe`; try `.exe` candidates first, give `editbin` a native
  path through `cygpath -w` and `-STACK:` options.
- `main` is protected: no direct push, squash merges only, the `Daslang
  quality gate` check required. Before pushing, `gh pr list`: a branch with
  the same commits may already sit in an open PR. `origin` is HTTPS with the
  `gh` credential helper; the Windows credential manager in `~/.gitconfig`
  does not run from WSL.
- A PR merged before the branch's last commit was pushed leaves that commit
  local and the branch deleted; re-home it on a fresh branch from `main`.
- `detect_duplicates`/`find_dupe` write temp files into the daslang checkout
  root and `live_status` writes `libhv.<date>.log` into the working
  directory; neither tool is needed here.
- The debuggee prints `[daslang atexit] FATAL: g_envTotal=1` on exit; it is
  upstream noise, not a crash.

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
| `docs/execution-design.md` | the RunLoop dispatcher that replaces `M3_MUSTTAIL`, the operand-reader expansion pass, and what an operation costs |
| `docs/native-build.md` | the aot, standalone-context and JIT tiers, AOT lowering findings, measurements, open performance items |
| `docs/test-suites.md` | running Wasm3's original spec and WASI drivers against the port, with the results |
| `notes/handoff_2026-09-18.md` | the current session handoff: state of `main`, open decisions, next units, pitfalls of the last session |
| `notes/upstream_cases/` | reproducer tests for the daslang defects filed upstream, with their run log |
| `wasm3c/source/` | read-only C semantic reference |
| `source/`, `tests/integration/` | the Daslang port and the component tests the gate runs |
| `tests/manual/` | manual fixture sets, `run_fixtures.py`, `fixture_report.md`, `ATTRIBUTION.md`; outside the gate |
| `tests/host_test/` | Daslang counterparts of `wasm3c/host_test` (embedding through the public API); compiled and linted by the gate |
| `app/`, `scripts/wasm3` | the command line front end (port of `platforms/app/main.c`) and its interpreted launcher |
| `native/`, `scripts/build_port.sh`, `scripts/wasm3-native`, `scripts/wasm3-ctx` | AOT and standalone builds: C++ hosts, build script and launchers |
| `scripts/bench.sh` | cross-engine fib32 benchmark; results in `docs/native-build.md` |
| `scripts/gate.sh`, `scripts/check_repo_invariants.sh` | the gate shared by CI and the pre-push hook |
