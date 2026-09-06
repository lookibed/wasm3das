# wasm3das

Manual port of the Wasm3 WebAssembly interpreter from C to Daslang. The WASI
integration layer is outside the current scope. `AGENTS.md` is the complete
rulebook for agents and `docs/development-pipeline.md` the order in which its
rules apply to a change; this file is the short entry point.

## Tool discipline

Use the Edit tool for changing a file and Write for creating one. Never edit
source through sed, a shell heredoc, or a throwaway Python script. This
applies to every file in the repository, not only `.das`, and overrides any
harness preference for shell-based editing.

## Git discipline

- Never rewrite history: no `git commit --amend`, no rebase of existing
  commits, no force-push of any kind, even on your own branch. Fix a mistake
  with a new commit on top.
- Commit messages and pull request descriptions carry only the substantive
  description of the change. No session URLs, no "Generated with Claude Code"
  footers, no other agent metadata.

## Porting approach

- Preserve the C source layout, function and variable names, and control flow.
- Use idiomatic Daslang only where a literal C construct cannot be represented.
- Avoid replacement algorithms that merely produce similar results.
- Review every increment against the C source and verify it with focused tests,
  the full test suite, compiler diagnostics, lint, LSP, and MCP tooling.

## Current status

`PORTING_MANIFEST.md` is the source of truth. In short: configuration,
definitions, math utilities, core readers, code pages, function metadata,
the shared type hub and the module layer are accepted; parser, binding,
environment/runtime, compiler, executor, the spectest host module and the
REPL app are in revision (reviewed against C, awaiting code-owner sign-off).
End-to-end execution works: `scripts/wasm3` runs every `wasm3c/test/lang`
fixture, and the original `wasm3c/test/run-spec-test.py` passes its whole
default list against the port (`notes/spec_test_status.md`). `m3_info`, the
libc half of `m3_api_libc.c` and the full public `wasm3.h` API are not
started. `wasm3c/` is the reference C source tree.

## Layout

| Path | Purpose |
|---|---|
| `source/` | Daslang port |
| `tests/` | Component tests (dastest) |
| `app/` | Port of `platforms/app/main.c` (REPL and `--func` runner), run through `scripts/wasm3` |
| `wasm3c/` | Reference Wasm3 C sources |
| `docs/` | Design decisions that outlive a single session |
| `notes/` | Dated working notes and handoffs |
| `.lint_config` | Repo lint policy; exported as `DAS_LINT_CONFIG_PATH` by CI, the hook and the MCP server |
| `scripts/gate.sh` | The verification gate, shared by CI and the pre-push hook |
| `.githooks/` | Pre-push hook that runs the gate (`git config core.hooksPath .githooks`) |
| `tmp/` | Local toolchain, ignored by Git |
| `tools/` | Local development tools, ignored by Git |
