# wasm3das

Manual port of the Wasm3 WebAssembly interpreter from C to Daslang, including
the plain WASI host layer of `m3_api_wasi.c`. `AGENTS.md` is the complete
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
- Open pull requests as drafts and mark them ready only after the last push
  is confirmed on the remote (`git status -sb`, `gh pr view --json commits`);
  never push to the branch of a merged PR. Details in
  `docs/development-pipeline.md`, stage 5.

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
environment/runtime, compiler, executor, the host modules (spectest, libc,
WASI) and the app are in revision (reviewed against C, awaiting code-owner
sign-off). End-to-end execution works: `scripts/wasm3` runs every
`wasm3c/test/lang` fixture, the original `wasm3c/test/run-spec-test.py`
passes its whole default list (`notes/spec_test_status.md`) and
`wasm3c/test/run-wasi-test.py` passes 12/12 (`notes/wasi_test_status.md`).
The executor dispatches through `RunLoop` instead of nested calls
(`notes/exec_trampoline_design.md`), and `scripts/build_native.sh` produces
an AOT-compiled native binary that passes the same suites
(`notes/native_aot_status.md`); `notes/benchmark_2026-09-07.md` and
`tests/manual/fixture_report.md` hold the measurements against wasmtime and
the C wasm3. `m3_info`, the tracer and the full public `wasm3.h` API are
not started. `wasm3c/` is the reference C source tree. The latest session
handoff is `notes/handoff_claude_code_2026-09-07.md`.

## Layout

| Path | Purpose |
|---|---|
| `source/` | Daslang port |
| `tests/integration/` | Component tests (dastest); the suite `scripts/gate.sh` and CI run |
| `tests/manual/` | Manual fixture sets and the `run_fixtures.py` benchmark harness with its `fixture_report.md`; never run by the gate |
| `tests/host_test/` | Daslang counterparts of `wasm3c/host_test` (embedding through the public API); compiled and linted by the gate, not dastest files |
| `app/` | Port of `platforms/app/main.c` (REPL and `--func` runner), run through `scripts/wasm3` |
| `native/` | C++ host for the AOT build (`scripts/build_native.sh`, `scripts/wasm3-native`); the port itself stays Daslang |
| `wasm3c/` | Reference Wasm3 C sources |
| `docs/` | Design decisions that outlive a single session |
| `notes/` | Dated working notes and handoffs |
| `.lint_config` | Repo lint policy; exported as `DAS_LINT_CONFIG_PATH` by CI, the hook and the MCP server |
| `scripts/gate.sh` | The verification gate, shared by CI and the pre-push hook |
| `.githooks/` | Pre-push hook that runs the gate (`git config core.hooksPath .githooks`) |
| `tmp/` | Local toolchain, ignored by Git |
| `tools/` | Local development tools, ignored by Git |
