# wasm3das

Manual port of the Wasm3 WebAssembly interpreter from C to Daslang. The WASI
integration layer is outside the current scope. `AGENTS.md` is the complete
rulebook for agents; this file is the short entry point.

## Porting approach

- Preserve the C source layout, function and variable names, and control flow.
- Use idiomatic Daslang only where a literal C construct cannot be represented.
- Avoid replacement algorithms that merely produce similar results.
- Review every increment against the C source and verify it with focused tests,
  the full test suite, compiler diagnostics, lint, LSP, and MCP tooling.

## Current status

`PORTING_MANIFEST.md` is the source of truth. In short: configuration,
definitions, math utilities, core readers, code pages, function metadata,
signature parsing, the shared type hub and the module layer are accepted; the
parser is in revision; environment/runtime, compiler, executor and the
exception/ABI helpers exist as drafts that compile and pass the gate but are
not reviewed. `m3_info`, the public `wasm3.h` API and end-to-end `.wasm`
execution are not started. `wasm3c/` is the reference C source tree.

## Layout

| Path | Purpose |
|---|---|
| `source/` | Daslang port |
| `tests/` | Component tests (dastest) |
| `wasm3c/` | Reference Wasm3 C sources |
| `notes/` | Dated working notes and handoffs |
| `.lint_config` | Repo lint policy; exported as `DAS_LINT_CONFIG_PATH` by CI, the hook and the MCP server |
| `.githooks/` | Local pre-push copy of the CI gate (`git config core.hooksPath .githooks`) |
| `tmp/` | Local toolchain, ignored by Git |
| `tools/` | Local development tools, ignored by Git |
