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
| `m3_math_utils.h` | `source/m3_math_utils.das` | Accepted | Integer and bit-manipulation helpers; libm-faithful `fabsf`/`fabs`/`floorf`/`ceilf`/`rintf`/`rint` (musl formulations, bit-exact for signed zero, infinities, NaN and half-to-even) added 2026-09-06 with tests, awaiting code-owner review |
| `m3_core.c` | `source/m3_core.das` | Accepted | Binary readers, LEB128, UTF-8 reads, type normalization, host allocator pair `m3_Malloc_Impl`/`m3_Free_Impl` |
| `m3_code.c` | `source/m3_code.das` | Accepted | Code pages and word emission |
| `m3_function.c` | `source/m3_function.das` | Accepted | Function types, metadata, ownership and release operations |
| `m3_bind.c` | `source/m3_bind.das` | Revision | Complete: `ConvertTypeCharToTypeId` and `SignatureToFuncType` are accepted; `ValidateSignature`, `FindAndLinkFunction`, `m3_LinkRawFunction` and `m3_LinkRawFunctionEx` were added 2026-09-06 and await code-owner review. Documented deviations: `cstr_t` is a Daslang string, so C's `NULL` import name is the empty string and C's optional `i_signature == NULL` (skip validation) is spelled as `""`; the two `m3log (module)` lines printing `SPrintFuncTypeSignature` on a mismatch are compiled out (`m3_info` is not ported). `tests/test_m3_bind.das` covers signature parsing plus, on a hand-assembled module that imports `spectest.print_i32`, the link-before-load rejection, unknown field/module names, signature mismatch, the `"*"` wildcard module, `m3_LinkRawFunctionEx` userdata reaching `M3ImportContext`, the call into the host function through `op_CallRawFunction`, and a host trap propagating out of `m3_CallV` |
| structures from `m3_env.h`, `m3_compile.h`, `m3_function.h` | `source/m3_types.das` | Accepted | Shared type hub (`M3Environment`, `M3Runtime`, `M3Module`, `M3Function`, `M3Compilation`, `M3Memory`, ...). It exists because Daslang cannot express the C header cycle; every other layer depends on it |
| `m3_module.c` | `source/m3_module.das` | Accepted | `Module_GetFunction`, simple accessors, module release |
| `m3_parse.c` | `source/m3_parse.das` | Revision | Reviewed section by section against C (2026-09-06): all thirteen `ParseSection_*`/`ParseType_*` functions, `Parse_InitExpr`, the `ParseModuleSection` dispatch (C `s_parsers`, with `NULL` at 4 and 12 meaning "skip the section") and `m3_ParseModule`'s magic/version checks and `sectionsOrder` loop. Restored: `ParseSection_Memory` discards the `ParseType_Memory` result, which is the one call site in C without the `_` error-propagating macro; propagating it made the port stricter than C on three `assert_malformed` modules. Documented deviations: C `FreeUtf8String`/`m3_Free(name)` of unadopted names are no-ops because `cstr_t` is a Daslang string; handler cursors are local `bytes_t` copies because the readers need a mutable cursor; `m3_AllocArray` is expanded at the call site. Behaviour is byte-for-byte identical to C over the whole wasm core testsuite (see Known gaps). Depends on the `m3_env` and `m3_compile` drafts |
| `m3_exception.h` | `source/m3_exception.das` | Draft | Documentation of the C try/catch macro layer over `M3Result`; the macros are expanded inline at call sites, so no module requires it. No dedicated test |
| `m3_exec_defs.h` | `source/m3_exec_defs.das` | Draft | Threaded-interpreter ABI signature; no dedicated test |
| `m3_env.c` | `source/m3_env.das` | Revision | Reviewed function by function against C (2026-09-06); the seven code-page functions live in `m3_code.das` with C-origin comments. `CompileFunctionHook`/`ResizeMemoryHook` replace the C include cycle. Documented deviations: typed `m3_CallVL` also checks the argument count; `m3_GetMemory`/`m3_GetMemorySize` guard a null `mallocated`; `m3Error` receives an interpolated message without file/line. `tests/test_m3_env.das` covers hook wiring and the public API on fib32; the lifecycle is covered by the fib32 regression |
| `m3_compile.c` | `source/m3_compile.das` | Revision | Reviewed function by function and the operation table row by row against C (2026-09-06). Restored: the release table has no DEBUG-only rows after 0xc4 (0xc5..0xfb are empty, 0xfc dispatches extended opcodes); `Compile_Operator` reports "no operation found for opcode" for empty entries; negative `i32.const` values keep C's sign-extended slot search; C error strings. Documented deviations: `c_opNull`/`c_noCompiler` sentinels stand for C `NULL` table entries; `d_m3Assert` is always on (C: DEBUG only); `ErrorCompile` drops file/line. `tests/test_m3_compile.das` covers the table and hand-written bodies; end-to-end compilation is covered by the fib32 regression |
| `m3_exec.h`, `m3_exec.c` | `source/m3_exec.das` | Revision | Reviewed 2026-09-06: the 509 `op_*` names match the expansion of the C macro families exactly (tracing-only `op_DumpStack`/`debugOp` removed), operand order of every generated binary/unary op checked, hand-written ops compared line by line. Restored: `op_CallIndirect` reads `compiled` after the lazy compile; `op_Loop` compares the loop id as a pointer (C `m3ret_t` is `void *`); `OP_CLZ_32`/`OP_CTZ_32`/`OP_CLZ_64`/`OP_CTZ_64` guard zero as C does (the Daslang builtin `clz(0u)` is 31). Documented deviations: loop ids travel inside `M3Result`; `M3_BSWAP` is a no-op (little-endian hosts only); backtrace layer absent (`d_m3RecordBacktraces == false`). `tests/test_m3_exec.das` runs hand-written bodies: operand order, shift masking, rotl, clz/ctz/popcnt, i64 extend/wrap, division traps and the `rem_s` quirk, loop/br_if, if/else, select, unreachable, float unary ops with signed zero. Restored 2026-09-06 from the spec suite: `CopyStackTopToSlot` narrows the polymorphic-stack index to `u16` as C's cast does; `f32.abs/ceil/floor/nearest` and `f64.abs/nearest` use the libm-faithful helpers in `m3_math_utils.das` (the Daslang `math` module rounds through an integer conversion). `tests/test_spec_core.das` runs the assertions of 56 core spec files through `m3_Call` (16 503 assertions, zero failures) |
| `platforms/app/main.c` (REPL subset) | `app/wasm3.das`, `scripts/wasm3` | Revision | `repl_*`, `split_argv` and `main` ported 2026-09-06 with C's output text, so the original `wasm3c/test/run-spec-test.py` drives the port unchanged: 17 863 of 17 863 default-list assertions pass, 0 crashes (`notes/spec_test_status.md`). `link_all` binds only `m3_LinkSpecTest`; libc/WASI/gas metering are out of scope. `options stack = 64 MiB` and `ulimit -s` in the wrapper stand in for `M3_MUSTTAIL` so `assert_exhaustion` traps instead of killing the process |
| `m3_info.c` | — | Not started | Diagnostic and formatting helpers |
| public `wasm3.h` API | — | Not started | Complete public runtime API (partial entry points live in `m3_env.das`) |
| `m3_api_libc.c` (spectest half) | `source/m3_api_libc.das` | Revision | `SuppressLookupFailure`, `m3_spectest_dummy` and `m3_LinkSpecTest` ported 2026-09-06, awaiting code-owner review. The C macro expansions are spelled out at the site: `m3ApiRawFunction(NAME)` becomes the `M3RawCall` parameter list, `m3ApiSuccess()` becomes `return m3Err_none`. This wasm3 revision's `m3_LinkSpecTest` links only the seven `spectest.print*` names; it has no `spectest.global_*`, `spectest.memory` or `spectest.table`, because wasm3 has no host-global and no host-memory/table import mechanism at all. `tests/test_m3_api_libc.das` covers the bound and unbound imports, `m3Err_moduleNotLinked` before `m3_LoadModule`, and calling the dummy from wasm |
| `m3_api_libc.c` (libc half), tracer APIs | — | Not started | `m3_libc_abort/exit/memset/memmove/print/printf/clock_ms` and `m3_LinkLibC` need the `m3ApiGetArgMem`/`m3ApiCheckMem` memory-argument macro family, which no layer expands yet |
| `m3_api_wasi.c`, `m3_api_uvwasi.c`, `m3_api_meta_wasi.c` | — | Excluded | WASI layer is not part of the current port |

## Known gaps

Each gap is closed by a pull request of the type given in
`docs/development-pipeline.md`.

- `tests/test_fib32_regression.das` covers parse, load, lazy compile,
  execution (fib(25) = 75025) and teardown of `wasm3c/test/lang/fib32.wasm`.
  `tests/test_lang_modules.das` extends the same lifecycle to every fixture in
  `wasm3c/test/lang`: `fib32.wasm`, `fib64.wasm` (i64 in and out), `fib.c.wasm`
  (emcc output with memory, a global and a data segment) and `fib32_tail.wasm`
  (the `return_call` proposal, which C maps onto `Compile_Call`). All four
  return fib(25) = 75025. The drafts below still lack per-layer review.
- `tests/test_spec_modules_load.das` parses and loads every module of the
  WebAssembly core testsuite (2706 `.wasm` files) in a fresh runtime, links
  `spectest` and frees. Nothing crashes; 820 of the 853 modules the suite marks
  valid load. The 33 that do not hit two C wasm3 limitations reproduced from
  the C source: 28 import their linear memory (`InitMemory` sizes memory only
  when `not memoryImported`, so `InitDataSegments` throws "unallocated linear
  memory") and 5 carry an element segment of zero elements while the table is
  still empty (`InitElements` runs `_throwifnull (table0)` outside the block
  that grows it). A driver built from `wasm3c/source` returned the identical
  `M3Result` for all 2706 modules, so parse and load are byte-for-byte
  faithful to C. The suite is a local download under `tmp/`, so the test skips
  when it is absent, as it is in CI.
- Imported linear memory, imported tables and host globals are not supported,
  exactly as in C wasm3. Linking is limited to functions
  (`m3_LinkRawFunction`).
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
