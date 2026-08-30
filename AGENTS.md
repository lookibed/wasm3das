# AGENTS.md

Instructions for AI coding agents working in this repository. Read this file
before writing or reviewing any code here.

## What this project is

A manual, incremental port of the [Wasm3](https://github.com/wasm3/wasm3)
WebAssembly interpreter from C to Daslang. `wasm3c/source/` is the vendored C
reference — it is read-only ground truth. The goal is **structural fidelity**:
the daslang tree must mirror the C tree, not merely reproduce its output.

The WASI layer (`m3_api_wasi.c` and friends) is intentionally out of scope.

## The spirit

When in doubt, resolve questions with these principles, in order:

1. **Fidelity over cleverness.** Preserve the C file layout, function and
   variable names, ordering, and control flow. Use idiomatic Daslang only
   where a literal C construct cannot be represented safely (pointers, unions,
   manual ownership). Never swap in a different algorithm because it "produces
   similar results" — a prettier rewrite is a bug in this repo.
2. **Proof over assumption.** An increment is done only when it passes
   compiler diagnostics, all three lint profiles, its focused test, and the
   full suite — not when it "looks right". Verify against the actual C source,
   line by line, not against your memory of how wasm3 works.
3. **Green tree at every step.** Port one bounded layer at a time. Every
   commit leaves `source/` and `tests/` compiling and all tests passing. Do
   not stack a new layer on top of a module that does not exist yet.
4. **The manifest is a contract.** `PORTING_MANIFEST.md` is the single source
   of truth for what is accepted, in revision, or not started. Read it before
   planning; update it in the same PR that changes coverage. Never mark
   something Accepted on the agent's own authority — acceptance is a
   code-owner review decision.

## Tooling policy — interacting with .das (MANDATORY)

All work on `.das` code in `source/` and `tests/` goes through daslang
tooling. Editing `.das` with shell text munging (`grep`/`sed`/`awk` +
redirects, python one-liners, `cat`-based scripts) is forbidden — it bypasses
LSP diagnostics and breaks C-fidelity review.

| Task | Use | Never |
|---|---|---|
| Read / edit / create `.das` | `read` / `edit` / `write` tools | bash `sed`, `awk`, python I/O |
| Symbol / definition lookup | `daslang_find_symbol`, `daslang_goto_definition`, `daslang_outline` | grep over `source/` |
| Usages / references | `daslang_grep_usage`, `daslang_find_references` | grep over `source/` |
| Types / module API | `daslang_describe_type`, `daslang_list_types`, `daslang_list_module_api`, `daslang_list_functions`, `daslang_list_requires` | reading stdlib ad hoc |
| Compile check | `daslang_compile_check` (globs supported) | ad-hoc CLI during editing |
| Lint | `daslang_lint` | manual greps for patterns |
| Format | `daslang_format_file` | any other rewrite |
| Tests / running code | `daslang_run_test`, `daslang_run_script`, `daslang_eval_expression` | scratch scripts |
| Program introspection | `daslang_program_log`, `daslang_ast_dump`, `daslang_type_of`, `daslang_aot` | — |

- **LSP is native** (`opencode.json` → `lsp.daslang` → `lsp_supervisor.py`).
  Diagnostics auto-push on the result of every `read`/`edit`/`write`; treat a
  new `ERROR` there as a stop-ship before continuing. The project
  `opencode.json` pins `initialization.compiler` to
  `tmp/daslang-toolchain/bin/daslang` so LSP diagnostics match the CI gate —
  rationale and details: `notes/2026-08-30-lsp-toolchain-override.md`.
- **Bash is allowed only for**: git operations, and the pinned-toolchain
  verification gate commands below. The daslang MCP server binds its own
  binary (check `opencode.json`); its results are development aids — the
  gate below is authoritative regardless of which tree an MCP/LSP tool ran on.
- **Search exceptions**: the C reference tree `wasm3c/` and non-`.das` files
  (CMake, README, `tests/` fixtures) may be searched with plain `grep`/`glob`
  — daslang tooling does not parse C. For C++ elsewhere use the `daslang_cpp_*`
  tools.
- **Skills**: load the `daslang` skill before writing or reviewing any `.das`;
  load formatting/testing skills (`das_formatting`, `writing_tests`) when
  those tasks come up. Lint/format always go through the MCP tools, not
  shell-invoked `daslang` binaries.

## Porting workflow

For a new C layer (e.g. `m3_env.c`):

1. Read `PORTING_MANIFEST.md` and `git log --oneline -15` to see where the
   port currently stands and what unblocks what.
2. Read the C source **and** its header completely before writing any daslang.
3. Create `source/<c_file_stem>.das` mirroring the C file: same names, same
   function order where daslang allows, same edge cases and quirks (including
   intentional parser quirks — do not "fix" them).
4. Adapt C constructs explicitly and document each deviation with a comment
   referencing the C construct it replaces.
5. Add `tests/test_<c_file_stem>.das` covering the behavior of that layer
   (one test file per ported source file is the existing convention).
6. Run the full verification gate (below) and review the diff against the C
   source one more time.

Existing work-in-progress drafts (`source/m3_compile.das`,
`source/m3_exec.das`, untracked) do not compile because they require modules
that are not yet ported. Treat them as drafts to unblock, not as accepted
code; do not reformat them casually.

## Verification gate

All verification must use the pinned toolchain (daslang 0.6.4, commit
`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`). Locally that lives in
`tmp/daslang-toolchain/bin/daslang` (the same toolchain the `pre-push` hook
enforces). If it is missing, set it up per `README.md` or ask — never silently
verify against a different daslang version. CI (`daslang-quality.yml`) builds
the same pinned commit.

Before claiming any change is done, run:

```sh
DASLANG="$PWD/tmp/daslang-toolchain/bin/daslang"

# 1. Compiler diagnostics on every file
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

If the daslang MCP server and LSP are available in your session, use them for
navigation, diagnostics, and lint during development — the gate above is still
required regardless.

## Code conventions

- Gen2 syntax only: start every `.das` file with `options gen2`; add
  `options indenting = 4` like the existing sources do.
- Module header: `module <name> shared public`, local requires with relative
  paths (`require ./m3_types.das public`), re-exporting dependencies the C
  header would expose.
- Top-of-file comment naming the C origin, e.g.
  `// Conservative Gen2 port of m3_exec.h.`
- Lint suppressions (`// nolint:XXX`) must be narrow and sit on the offending
  line; they exist where the C structure demands the flagged pattern.
- Do not rename existing ported identifiers; the C name is the contract.

## Git workflow

- Work in feature branches; open pull requests into `main`. Direct pushes to
  `main` are blocked by the `pre-push` hook and are not part of this project's
  workflow.
- One bounded layer (or focused fix) per PR; the PR description should state
  which C files were ported and what was intentionally deferred.
- A PR is accepted only after the CI quality gate passes and the code owner
  approves. CI passing does not by itself promote a manifest entry to
  Accepted.
- Do not commit anything from `tmp/` or `tools/` (gitignored local workspace),
  and do not create new `*:Zone.Identifier` files (Windows artifacts
  accidentally tracked in history).

## Key files

| File | Purpose |
|---|---|
| `README.md` | Project overview and local verification recipes |
| `PORTING_MANIFEST.md` | Per-file port status, acceptance boundary, milestone |
| `CLAUDE.md` | Claude-specific pointer to the same rules |
| `opencode.json` | Project overrides for native LSP / MCP (pinned compiler) |
| `notes/` | Session journals and tooling decisions |
| `wasm3c/source/` | C reference tree (read-only) |
| `source/`, `tests/` | The port and its component tests |
| `main.das`, `lib/`, `demo_*.das` | Daslang sandbox demos, unrelated to the port |
| `.githooks/pre-push` | The local form of the CI quality gate |
