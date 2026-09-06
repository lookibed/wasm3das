# Memory ownership in the Daslang port

Status: **decided 2026-09-05, implemented 2026-09-06.** The fib32 regression
(`tests/test_fib32_regression.das`) passes through teardown; the table below
describes the state before the migration and is kept as the record of why.

## The problem (before the migration)

C Wasm3 has one allocation regime: every runtime object comes from
`m3_AllocStruct`/`m3_AllocArray` (zeroed `malloc`) and goes back through
`m3_Free`. The port had three:

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
construct runtimes with `new` and must delete them themselves.

The teardown `SIGSEGV` itself was located with the DAP bridge on 2026-09-06:
the process died at the first stop after `m3_FreeModule` freed the module's
arrays, and a probe with two mutually linked `new` structs reproduced the
mechanism. A Daslang `delete` on a struct pointer runs the generated
finalizer, which finalizes and frees every pointer field and follows cycles.
`M3Runtime.compilation.runtime` and `M3Runtime.error.runtime` point back at
the runtime, `M3Function._module` at its module, and `M3Module.wasmStart`
into the caller's byte buffer, so `delete i_runtime` recursed until the stack
overflowed (the fault address was a stack page). The detach-before-delete
workarounds in the release functions only postponed it.

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

## Migration (done)

1. `tests/test_fib32_regression.das` (PR #10): parse, load, `fib(25)`,
   teardown; the teardown half was skipped until step 4.
2. `m3_NewEnvironment` / `m3_FreeEnvironment`: `m3_Malloc_Impl` /
   `m3_Free_Impl`; the detach-before-delete block in `Environment_Release`
   is gone, the function mirrors C again.
3. `m3_NewRuntime` (including the `originStack` failure path) /
   `m3_FreeRuntime`; `Runtime_Release` mirrors C, it no longer nulls the
   borrowed links because nothing walks them any more.
4. `m3_ParseModule` / `m3_FreeModule`; the detach block and the ownership
   comment that explained the `new` exception are gone.
5. `tests/test_m3_code.das`, `tests/test_m3_module.das`, `tests/test_m3_env.das`
   allocate hand-built runtimes and modules with `m3_Malloc_Impl` and release
   them with `m3_Free_Impl`.
6. `AGENTS.md`, "Allocation and pointer semantics", states the single regime
   and why `delete` on an `M3*` object is fatal.

The acceptance test is `test_fib32_teardown`, no longer skipped.
