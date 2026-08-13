# wasm3das

Manual port of the Wasm3 WebAssembly interpreter from C to Daslang. The WASI
integration layer is outside the current scope.

## Porting approach

- Preserve the C source layout, function and variable names, and control flow.
- Use idiomatic Daslang only where a literal C construct cannot be represented.
- Avoid replacement algorithms that merely produce similar results.
- Review every increment against the C source and verify it with focused tests,
  the full test suite, compiler diagnostics, lint, LSP, and MCP tooling.

## Current status

Implemented foundations include configuration and Wasm3 definitions, math
utilities, binary and LEB128 readers, code-page management, function metadata,
and the first signature-parsing portion of `m3_bind`.

The complete module layer, WebAssembly parser, runtime/environment, native
linking, compiler, executor, public API, and end-to-end `.wasm` execution remain
to be ported. `wasm3c/` is the reference C source tree.

## Layout

| Path | Purpose |
|---|---|
| `source/` | Daslang port |
| `tests/` | Component tests |
| `wasm3c/` | Reference Wasm3 C sources |
| `tmp/` | Local toolchain, ignored by Git |
| `tools/` | Local development tools, ignored by Git |
