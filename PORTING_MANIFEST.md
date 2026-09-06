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
| `m3_env.c` | `source/m3_env.das` | Draft | Environment, runtime, memory, globals, module loading and calls are present. `CompileFunctionHook`/`ResizeMemoryHook` replace the C include cycle. Teardown `SIGSEGV` unresolved; tests cover only hook wiring |
| `m3_compile.c` | `source/m3_compile.das` | Draft | Wasm-to-Wasm3 compiler. `tests/test_m3_compile.das` covers only the operation table (filled by `[init]` and, for hosts that skip it, by `m3_NewEnvironment`); the compiler itself is exercised end to end by the fib32 regression |
| `m3_exec.h`, `m3_exec.c` | `source/m3_exec.das` | Draft | 510 `op_*` functions hand-expanded from the C macros; backtrace layer absent; no dedicated test |
| `m3_info.c` | — | Not started | Diagnostic and formatting helpers |
| public `wasm3.h` API | — | Not started | Complete public runtime API (partial entry points live in `m3_env.das`) |
| `m3_api_libc.c`, tracer APIs | — | Not started | Optional host APIs, after core runtime |
| `m3_api_wasi.c`, `m3_api_uvwasi.c`, `m3_api_meta_wasi.c` | — | Excluded | WASI layer is not part of the current port |

## Known gaps

Each gap is closed by a pull request of the type given in
`docs/development-pipeline.md`.

- `tests/test_fib32_regression.das` covers parse, load, lazy compile and
  execution of `wasm3c/test/lang/fib32.wasm` (fib(25) = 75025). Its teardown
  half is skipped: `m3_FreeRuntime` still ends in `SIGSEGV` after a
  successful run. Un-skipping it is the acceptance test for the memory
  ownership migration below.
- The compiler's operation table is filled by an `[init]` function in
  `m3_compile.das`. Under dastest that `[init]` does not run when the test
  file declares a `module` name (daslang 0.6.4 @ 1524b3bf), so the table
  stays zeroed and compilation invokes a null function. Test files that reach
  the compiler must not declare a module; a robust fix (initialising the
  table from `m3_NewEnvironment`, like the hooks) is a separate `fix/` PR.
- Environment, runtime and module objects are `new`-allocated while every
  other C-owned object is `m3_Malloc_Impl`-allocated. The decision to move to
  a single host-allocator regime and its migration order are recorded in
  `docs/memory-ownership.md`.

## Acceptance boundary

Passing CI means the submitted tree compiles, is lint-clean under
`.lint_config`, and passes the available component tests. It does not by
itself promote a **Draft** or **Revision** item to **Accepted**: structural
correspondence, memory layout, ownership, naming, and C control-flow fidelity
still require code-owner review.

The final project milestone requires parsing, compiling, linking, and executing
representative non-WASI `.wasm` modules end to end.
