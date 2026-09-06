# Development pipeline

Every change to this repository travels through the same stages as one pull
request. Pull request types differ only in which checks are mandatory. The
rules referenced here live in `AGENTS.md` (porting rules, tooling policy, DAP
contract), `CLAUDE.md` (tool and git discipline) and `PORTING_MANIFEST.md`
(status of every C layer); the merge policy is stage 5 below. This document says in
which order they apply and what "done" means at each stage.

## Unit of work: one pull request

| Type | Branch prefix | Manifest effect | Extra mandatory checks |
|---|---|---|---|
| port (new C layer) | `port/<layer>` | new row → Draft | `tests/test_<layer>.das` |
| promote (review of a Draft or Revision) | `review/<layer>` | Draft → Revision; owner may set Accepted | C checklist table in the PR |
| runtime-fix (one invariant) | `fix/<invariant>` | none | fib32 regression through teardown; DAP evidence in the PR |
| policy / docs | `docs/<topic>` | none | gate only |
| tooling / CI | `ci/<topic>` | none | negative test of every new check |

A change that spans several PRs (for example the six steps in
`docs/memory-ownership.md`) is a **series**: every PR title names the document
and the step, "memory-ownership step 2/6: environment through m3_Malloc_Impl",
so the order stays visible in `main` after squash merges.

## Stages

### 0. Intake

- Pick the unit from `PORTING_MANIFEST.md` ("Known gaps" first) or the latest
  `notes/handoff_*.md`. Name its type from the table above.
- Check that every layer the unit depends on is at least Draft in the
  manifest. If not, the dependency is the unit.
- Branch from fresh `main` with the type's prefix.
- Done: the PR description skeleton (`.github/pull_request_template.md`) is
  filled in as far as it can be: scope, what is deferred, C references,
  intended manifest transition.

### 1. Reference

- Read the C source and header of the layer in `wasm3c/source/` completely
  before writing Daslang.
- List the C functions in their order; list the macros that must be expanded
  inline (`_try`, `_throwif`, `m3_AllocArray`, logging that is compiled out).
- For every object the change allocates or frees, write its allocator
  provenance (allocated by, owned by, freed by, expected pair) in the form
  used by `docs/memory-ownership.md`.
- Done: the top-of-file C-origin comment and the list of deviations exist,
  even if the code does not yet.

### 2. Implement

- Files change only through the Edit and Write tools (`CLAUDE.md`).
- Per changed file: `mcp__daslang__compile_check`, zero LSP errors,
  `mcp__daslang__lint` with zero findings under `.lint_config`,
  `mcp__daslang__format_file`.
- `require` edges follow the C includes of the same header; `public` only
  where the C header itself includes the dependency (`AGENTS.md`, code
  conventions).
- Every deviation from C is documented at the adapted site, not in the PR
  alone.
- Done: the changed files compile, are lint-clean and formatted.

### 3. Verify

- `tests/test_<layer>.das`: `[test]` functions, `require dastest/testing_boost`,
  C file and line cited wherever an expected value is not obvious. A test
  file without `[test]` is not a test (dastest never runs it).
- Fixtures come only from `wasm3c/test/` (for example
  `wasm3c/test/lang/fib32.wasm`), read relative to the repository root, which
  is dastest's working directory locally and in CI. No copies under `tests/`.
- Runtime and lifecycle changes additionally pass the fib32 regression
  through result retrieval and teardown without a crash. If it crashes, use
  the DAP loop from `AGENTS.md`: observation → one invariant → DAP plus the C
  source → minimal patch → regression. DAP runs only locally; its output goes
  into the PR body as text because CI cannot reproduce it.
- Done: the full pinned gate is green locally: `scripts/gate.sh` with the
  toolchain at `tmp/daslang-toolchain` (or `DASLANG_ROOT=/path/to/daScript
  DASLANG="$DASLANG_ROOT/bin/daslang" scripts/gate.sh`); a single stage runs
  by name, for example `scripts/gate.sh lint-style`. The pre-push hook runs
  the same gate once enabled with `git config core.hooksPath .githooks`; a
  push that fails the hook is not ready.

### 4. Self-review against C

Checklist, answered in the PR description with C line references:

- names, function order and control flow match the C source;
- allocator pairs are correct for every pointer (`AGENTS.md`, allocation and
  pointer semantics);
- pointer-array versus struct-array indexing is right for every `addr(...)`;
- every C macro is expanded, not called;
- every deviation is documented at the site;
- no mass regex or script rewrite happened;
- `.lint_config` gained nothing (a fixable finding is fixed in code; a new
  repo-wide exception is its own `docs/` PR with a reason per rule).

Update the manifest row in the same PR: Not started → Draft for a port,
Draft → Revision for a review. **Accepted** is set only by the code owner,
either by editing the row in the open PR before merge or by a separate
`docs/` PR, never by a direct commit to `main`.

Done: the checklist is in the PR and the manifest row matches the code.

### 5. Pull request and merge

- One unit per PR. The description states what changed, what was deferred and
  how it was verified (the gate summary line; the fib32 result when relevant).
  No session URLs, no agent footers (`CLAUDE.md`).
- Because `main` receives one squash commit per PR, **the PR title and body
  become the commit message**. The title states the proven invariant or the C
  comparison; the body carries the verification. Individual branch commits
  stay focused but are not required to repeat this.
- CI green and code-owner review are both required. Merge is squash; GitHub
  deletes the head branch.

### 6. Post-merge

- Locally: `git checkout main && git pull`, then `git branch -D <branch>`
  (squashed commits are not reachable from `main`, so `-d` refuses).
- When a session ends, update `notes/handoff_*.md` with the gate state, what
  is uncommitted and why, and the next unit.
- Durable decisions go to `docs/` and change only by a PR that states what
  evidence changed. Dated working notes go to `notes/`. Agent transcripts go
  nowhere in the tree.

## What is automated and what is not

| Check | Where | Enforced by |
|---|---|---|
| compile-only of every `source/` and `tests/` file | gate | CI, pre-push |
| paranoid / perf / style lint, zero findings under `.lint_config` | gate | CI, pre-push |
| dastest suite | gate | CI, pre-push |
| formatter verify, test discovery, manifest consistency, file header | gate (repository invariants) | CI, pre-push |
| fib32 regression through teardown | `tests/` once it exists | CI, pre-push |
| DAP evidence, line-by-line C review, allocator provenance | PR body | reviewer |
| manifest status Accepted | PR | code owner |

The invariant checks read `.das` files with shell tools. That is a CI and
hook mechanism only; the tooling policy in `AGENTS.md` (Daslang-aware tools
for reading and editing `.das`) is unchanged for agents.

## Mapping the current work onto the pipeline

- fib32 regression test: type `port` for `tests/` only, no `source/` change;
  unblocks every runtime-fix.
- memory-ownership migration: a `fix/` series of six PRs following
  `docs/memory-ownership.md`, each verified by the fib32 regression.
- review of `m3_env`, `m3_compile`, `m3_exec`: three `review/` PRs with the C
  checklist table, each adding the layer's test file and moving the row to
  Revision.
- remaining C layers (`m3_info`, public API): `port/` PRs.
