# Porting manifest

Status meanings:

- **Accepted** — reviewed against C and covered by the current test gate.
- **Revision** — implemented, but a known review issue remains.
- **Draft** — present in `source/`, compiles and is lint-clean under the gate,
  but not reviewed against C line by line and without a dedicated test file.
  Drafts are not accepted code; other layers may depend on them only because
  Daslang requires an acyclic module graph.
- **Not started** — no production port accepted yet.
- **Excluded** — intentionally outside this project's current scope.

| C source | Daslang source | Status | Scope / remaining work |
|---|---|---|---|
| `m3_config.h` | `source/m3_config.das` | Accepted | Active build configuration |
| `wasm3_defs.h` | `source/wasm3_defs.das` | Accepted | Core Wasm constants and definitions |
| `m3_math_utils.h` | `source/m3_math_utils.das` | Accepted | Integer and bit-manipulation helpers |
| `m3_core.c` | `source/m3_core.das` | Accepted | Binary readers, LEB128, UTF-8 reads, type normalization, host allocator pair `m3_Malloc_Impl`/`m3_Free_Impl` |
| `m3_code.c` | `source/m3_code.das` | Accepted | Code pages and word emission |
| `m3_function.c` | `source/m3_function.das` | Accepted | Function types, metadata, ownership and release operations |
| `m3_bind.c` | `source/m3_bind.das` | Accepted | Signature conversion/parsing; validation and linking remain dependent on later compiler/runtime stages |
| structures from `m3_env.h`, `m3_compile.h`, `m3_function.h` | `source/m3_types.das` | Accepted | Shared type hub (`M3Environment`, `M3Runtime`, `M3Module`, `M3Function`, `M3Compilation`, `M3Memory`, ...). It exists because Daslang cannot express the C header cycle; every other layer depends on it |
| `m3_module.c` | `source/m3_module.das` | Accepted | `Module_GetFunction`, simple accessors, module release |
| `m3_parse.c` | `source/m3_parse.das` | Revision | The reviewed increment covers table/memory types plus start and element sections. The file also carries the mechanically expanded remainder of the parser (see AGENTS.md, high-risk areas), which has not been reviewed section by section. Depends on the `m3_env` and `m3_compile` drafts |
| `m3_exception.h` | `source/m3_exception.das` | Draft | Documentation of the C try/catch macro layer over `M3Result`; the macros are expanded inline at call sites, so no module requires it. No dedicated test |
| `m3_exec_defs.h` | `source/m3_exec_defs.das` | Draft | Threaded-interpreter ABI signature; no dedicated test |
| `m3_env.c` | `source/m3_env.das` | Revision | Reviewed function by function against C (2026-09-06); the seven code-page functions live in `m3_code.das` with C-origin comments. `CompileFunctionHook`/`ResizeMemoryHook` replace the C include cycle. Documented deviations: typed `m3_CallVL` also checks the argument count; `m3_GetMemory`/`m3_GetMemorySize` guard a null `mallocated`; `m3Error` receives an interpolated message without file/line. `tests/test_m3_env.das` covers hook wiring and the public API on fib32; the lifecycle is covered by the fib32 regression |
| `m3_compile.c` | `source/m3_compile.das` | Revision | Reviewed function by function and the operation table row by row against C (2026-09-06). Restored: the release table has no DEBUG-only rows after 0xc4 (0xc5..0xfb are empty, 0xfc dispatches extended opcodes); `Compile_Operator` reports "no operation found for opcode" for empty entries; negative `i32.const` values keep C's sign-extended slot search; C error strings. Documented deviations: `c_opNull`/`c_noCompiler` sentinels stand for C `NULL` table entries; `d_m3Assert` is always on (C: DEBUG only); `ErrorCompile` drops file/line. `tests/test_m3_compile.das` covers the table and hand-written bodies; end-to-end compilation is covered by the fib32 regression |
| `m3_exec.h`, `m3_exec.c` | `source/m3_exec.das` | Revision | Reviewed 2026-09-06: the 509 `op_*` names match the expansion of the C macro families exactly (tracing-only `op_DumpStack`/`debugOp` removed), operand order of every generated binary/unary op checked, hand-written ops compared line by line. Restored: `op_CallIndirect` reads `compiled` after the lazy compile; `op_Loop` compares the loop id as a pointer (C `m3ret_t` is `void *`); `OP_CLZ_32`/`OP_CTZ_32`/`OP_CLZ_64`/`OP_CTZ_64` guard zero as C does (the Daslang builtin `clz(0u)` is 31). Documented deviations: loop ids travel inside `M3Result`; `M3_BSWAP` is a no-op (little-endian hosts only); backtrace layer absent (`d_m3RecordBacktraces == false`). `tests/test_m3_exec.das` runs hand-written bodies: operand order, shift masking, rotl, clz/ctz/popcnt, i64 extend/wrap, division traps and the `rem_s` quirk, loop/br_if, if/else, select, unreachable. Memory ops and `call_indirect` are untested (fib32 has no memory or table) |
| `m3_info.c` | — | Not started | Diagnostic and formatting helpers |
| public `wasm3.h` API | — | Not started | Complete public runtime API (partial entry points live in `m3_env.das`) |
| `m3_api_libc.c`, tracer APIs | — | Not started | Optional host APIs, after core runtime |
| `m3_api_wasi.c`, `m3_api_uvwasi.c`, `m3_api_meta_wasi.c` | — | Excluded | WASI layer is not part of the current port |

## Known gaps

Each gap is closed by a pull request of the type given in
`docs/development-pipeline.md`.

- `tests/test_fib32_regression.das` covers parse, load, lazy compile,
  execution (fib(25) = 75025) and teardown of `wasm3c/test/lang/fib32.wasm`.
  It is the only end-to-end test; the drafts below still lack per-layer
  review and tests.
- Names (`cstr_t`) are Daslang strings stored inside host-allocated structs.
  This is safe only while the string heap is never collected during a
  runtime's lifetime (`docs/memory-ownership.md`, "Strings stay Daslang
  strings").

## Acceptance boundary

Passing CI means the submitted tree compiles, is lint-clean under
`.lint_config`, and passes the available component tests. It does not by
itself promote a **Draft** or **Revision** item to **Accepted**: structural
correspondence, memory layout, ownership, naming, and C control-flow fidelity
still require code-owner review.

The final project milestone requires parsing, compiling, linking, and executing
representative non-WASI `.wasm` modules end to end.
