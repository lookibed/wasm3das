# Porting manifest

Status meanings:

- **Accepted** — reviewed against C and covered by the current test gate.
- **Revision** — implemented, but a known review issue remains.
- **Not started** — no production port accepted yet.
- **Excluded** — intentionally outside this project's current scope.

| C source | Daslang source | Status | Scope / remaining work |
|---|---|---|---|
| `m3_config.h` | `source/m3_config.das` | Accepted | Active build configuration |
| `wasm3_defs.h` | `source/wasm3_defs.das` | Accepted | Core Wasm constants and definitions |
| `m3_math_utils.h` | `source/m3_math_utils.das` | Accepted | Integer and bit-manipulation helpers |
| `m3_core.c` | `source/m3_core.das` | Accepted | Binary readers, LEB128, UTF-8 reads, type normalization |
| `m3_code.c` | `source/m3_code.das` | Accepted | Code pages and word emission |
| `m3_function.c` | `source/m3_function.das` | Accepted | Function types, metadata, ownership and release operations |
| `m3_bind.c` | `source/m3_bind.das` | Accepted | Signature conversion/parsing; validation and linking remain dependent on later compiler/runtime stages |
| `m3_module.c`, structures from `m3_env.h` | `source/m3_module.das`, `source/m3_types.das` | Accepted | Canonical module/function type graph, global value views, `Module_GetFunction`, and simple accessors |
| `m3_parse.c` | `source/m3_parse.das` | Accepted | Initial stage: table/memory types plus start and element sections; remaining parser sections are not started |
| `m3_env.c` | — | Not started | Environment, runtime, memory, globals and calls |
| `m3_compile.c` | — | Not started | Wasm-to-Wasm3 compiler |
| `m3_info.c` | — | Not started | Diagnostic and formatting helpers |
| `m3_exec.c` and execution definitions | — | Not started | Interpreter execution layer |
| public `wasm3.h` API | — | Not started | Complete public runtime API |
| `m3_api_libc.c`, tracer APIs | — | Not started | Optional host APIs, after core runtime |
| `m3_api_wasi.c`, `m3_api_uvwasi.c`, `m3_api_meta_wasi.c` | — | Excluded | WASI layer is not part of the current port |

## Acceptance boundary

Passing CI means the submitted tree compiles, is lint-clean, and passes the
available component tests. It does not by itself promote a **Revision** item to
**Accepted**: structural correspondence, memory layout, ownership, naming, and
C control-flow fidelity still require code-owner review.

The final project milestone requires parsing, compiling, linking, and executing
representative non-WASI `.wasm` modules end to end.
