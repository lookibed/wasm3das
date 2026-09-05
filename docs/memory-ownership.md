# Memory ownership in the Daslang port

Status: **decided 2026-09-05, not yet implemented.** Implementation is a
runtime change and must follow the migration order below, one step per commit,
with the `fib32.wasm` regression in place first.

## The problem

C Wasm3 has one allocation regime: every runtime object comes from
`m3_AllocStruct`/`m3_AllocArray` (zeroed `malloc`) and goes back through
`m3_Free`. The port currently has three:

| Object | C | Port allocates with | Port frees with |
|---|---|---|---|
| `M3Environment` | `m3_AllocStruct` | `new M3Environment()` (`m3_env.das`, `m3_NewEnvironment`) | `delete` |
| `M3Runtime` | `m3_AllocStruct` | `new M3Runtime()` (`m3_NewRuntime`) | `delete` |
| `M3Module` | `m3_AllocStruct` | `new M3Module()` (`m3_parse.das`, `m3_ParseModule`) | `delete` (`m3_module.das`, `m3_FreeModule`) |
| `M3FuncType` nodes | `m3_Malloc` | `m3_Malloc_Impl` (`AllocFuncType`) | `m3_Free_Impl` |
| `functions`, `globals`, `dataSegments`, `funcTypes` arrays | `m3_AllocArray`/`m3_ReallocArray` | `m3_Malloc_Impl`/`m3_Realloc_Impl` | `m3_Free_Impl` |
| code pages, `originStack`, linear memory | `m3_Malloc`/`m3_Realloc` | `m3_Malloc_Impl`/`m3_Realloc_Impl` | `m3_Free_Impl` |
| names (`cstr_t`) | `m3_Malloc` via `Read_utf8` | Daslang `string` from `Read_utf8` | never (C `m3_Free(name)` sites are no-ops) |

The three objects that use `new` are exactly the containers whose teardown
walks the `malloc`-owned graph. Every release function therefore has to know,
per pointer, which regime created it; `m3_FreeModule` deletes the module but
`m3_Free_Impl`s its arrays. Both historical crashes came from crossing the
boundary: `m3_Free_Impl` on a `new M3Module()` (glibc `free(): invalid
pointer`) and `delete` on an `M3FuncType` from `m3_Malloc_Impl`. Tests inherit
the same burden: `tests/test_m3_code.das` and `tests/test_m3_module.das`
construct runtimes with `new` and must delete them themselves. The unresolved
teardown `SIGSEGV` lives on this boundary.

## Decision

**One regime: the host allocator pair for every C-owned object.** Any `M3*`
struct that C obtains from `m3_AllocStruct`/`m3_AllocArray` is obtained in the
port from `m3_Malloc_Impl(typeinfo sizeof(type<T>))` and released with
`m3_Free_Impl`. `new`/`delete` are not used for `M3*` structs anywhere in
`source/` or `tests/`.

Why this option:

- It is the C model, so `m3_Free` sites map one to one and the fidelity
  principle in `AGENTS.md` is served rather than fought.
- Zeroed memory is a valid initial state: none of the structs in
  `m3_types.das` carries a Daslang field initialiser, and C relies on the same
  zeroing.
- Four of the five object kinds already live there. The change touches three
  constructors, three destructors and seven test sites.
- Ownership becomes a property of the type, not of the call site, so the
  release code no longer needs per-pointer comments explaining which
  deallocator applies.

Rejected: managed allocation everywhere (`new`/`delete` for all `M3*`
objects). Contiguous struct arrays with `realloc` growth (`functions`,
`globals`, linear memory pages) have no `new`-based equivalent that keeps the
C pointer arithmetic, so the port would diverge from C in more places, not
fewer.

## Strings stay Daslang strings

`cstr_t` is `string`. Names from `Read_utf8` are Daslang string-heap values
stored inside `malloc`-owned structs. Two consequences must be kept explicit at
the adapted sites:

1. C `m3_Free(name)` has no port equivalent; the site keeps a comment saying
   the string is heap-managed.
2. The Daslang string heap is never collected while a runtime is alive
   (`collect_string_heap` and relatives are not called anywhere in `source/`).
   If that ever changes, names inside `malloc`-owned memory become invisible
   roots and must move to `bytes_t` buffers owned through `m3_Malloc_Impl`.

## Migration order

Each step is one commit and must pass the full gate. Steps 2 to 4 are
runtime/lifecycle changes and additionally require step 1's regression to
reach result retrieval and teardown without a crash; use `daslang-dap` per the
`AGENTS.md` contract when it does not.

1. Add `tests/test_fib32_regression.das`: parse `wasm3c/test/lang/fib32.wasm`,
   load, call `fib(25)`, expect `75025`, free runtime and environment.
2. `m3_NewEnvironment` / `m3_FreeEnvironment`: `m3_Malloc_Impl` /
   `m3_Free_Impl`; drop the detach-before-delete workaround in
   `Environment_Release` only if the regression proves it unnecessary.
3. `m3_NewRuntime` (including the `originStack` failure path) /
   `m3_FreeRuntime`.
4. `m3_ParseModule` / `m3_FreeModule`; remove the ownership comment that
   explains the `new` exception.
5. Tests that build runtimes or modules by hand (`test_m3_code.das`,
   `test_m3_module.das`, `test_m3_env.das`) construct them through the port
   API or through `m3_Malloc_Impl`, never through `new`.
6. `AGENTS.md`, "Allocation and pointer semantics": replace the two-pair rule
   with the single-regime rule and keep the pointer-value versus
   `addr(array[i])` guidance.
