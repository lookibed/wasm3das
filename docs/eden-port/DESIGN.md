# wasm3das on EdenSpark: target design

This document is the contract every agent of the Eden port follows. It fixes
what the editor allows (measured, not assumed), how the pointer-based port is
re-expressed without pointers, and what "done" means for one module. The
pipeline that applies it is `docs/eden-port/PIPELINE.md`; per-module progress
is `docs/eden-port/STATE.json`.

## 1. The target, measured

Measured on eden.exe 0.9.0.34 through its MCP server on 2026-09-25. Re-measure
with the probe cheats described in PIPELINE.md §7 when the editor updates.

| Fact | Value |
|---|---|
| Daslang in the editor | 0.6.3 (`get_das_version()`); docs bundled are 0.6.2; nearest local tag is `v0.6.3-RC3`, built at `/root/daScript-0.6.3` |
| Script discovery | the editor compiles **every non-hidden `.das` file** in the project tree; folders starting with `.` are skipped |
| Error reporting | only the first error of the first failing file; with several failing files the status says only `internal error`, so bisect one file at a time |
| `unsafe` | forbidden in every form (`unsafe function 'x'`); `options no_unsafe = false` refused |
| Refused modules | `daslib/fio`, `daslib/network`, `daslib/jobque_boost`, `daslib/ast`, `daslib/ast_boost`, `daslib/templates_boost`, `daslib/safe_addr`, `daslib/linked_list`; `require rtti` / `require ast` as bare names do not resolve |
| Accepted modules | `daslib/strings_boost`, `json`, `json_boost`, `regex`, `math_boost`, `math_bits`, `functional`, `algorithm`, `decs`, `decs_boost`, `random`, `sort_boost`, `array_boost`, `static_let`, `contracts`, `linq`, `apply`, `rtti`, `enum_trait`, `bitfield_trait`, `utf8_utils`, `archive`, `cuckoo_hash_table`, `flat_hash_table`, `match`, `defer`, `if_not_null`, `bool_array`, `base64` |
| Accepted options | `gen2`, `indenting`, `stack` (64 MiB accepted), `rtti`; `no_global_variables` and `never_inline` untested |
| 0.6.4 syntax that 0.6.3 rejects | typed `addr<T>(x)` (25 sites in `.upstream`); expect more, the local 0.6.3 build catches them |
| Binary data | `request_text("assets/x.data")` + `get_binary_asset(id) $(bytes : array<uint8>#)` (added in EdenSpark 0.9.0.16, "binary asset support"; 0.9.0.23 added `decompress` for gzip/zlib); imported by extension `.txt .json .xml .data`; a new file needs the editor to rescan (a game restart is enough). There is no general file API: no `fio`, no writing, no paths outside the project's assets |
| Output | `print` lines reach `get_logs` (MCP) with a `file:line (function)` line after each; `get_logs` clears the buffer |
| Entry points | `[export] on_initialize/on_update` and `[cheat]` functions in the project's `main.das`; cheats run asynchronously, results are read from the logs |
| Cheat registry | keeps names of cheats removed by hot reload until the editor restarts (cosmetic) |
| Float compare with NaN | **not IEEE in the editor** (probe cheat, f32 and f64 alike): `NaN == NaN` true, `NaN != NaN` false, `NaN == 1` true, `NaN != 1` false, `NaN < 1` true, `NaN <= 1` true, `NaN > 1` false, `NaN >= 1` false. Local 0.6.3/0.6.4 give the C/IEEE results. NaN bits round-trip through `math_bits`, `1/0 = +inf`, `sqrt(-1) = NaN`, `0 == -0` true. Every float comparison the port makes guards with `isnan` (a bit test, works in the editor): `eq` = `!isnan(a) && !isnan(b) && a == b`, `ne` = `isnan(a) \|\| isnan(b) \|\| a != b`, `lt/gt/le/ge` = `!isnan(a) && !isnan(b) && a < b` ...; `m3_math_utils` already tests `isnan` before every ordered compare; the tests carry a NaN row per comparison form |
| `try` / `recover` | works in the editor: a `panic` inside `try` is caught by `recover`, the game stays `Running` (measured with a probe cheat). Upstream tests that capture a `d_m3Assert` through `try/recover` port unchanged |

The local stand-in for these rules is `scripts/eden/sandbox.das_project`
(`daslang -no-dynamic-modules -project scripts/eden/sandbox.das_project`), run
by `scripts/eden/compile.sh` with both the pinned 0.6.4 and the 0.6.3 build.
It is a model of the editor; the editor itself (`scripts/eden/eden_gate.sh`)
stays the final gate.

## 2. Repository layout for the port

| Path | Purpose | Seen by the editor |
|---|---|---|
| `source/*.das` | the Eden modules, one per original module, same names | yes |
| `tests/eden/test_*.das` | Eden test modules, one per source module | yes |
| `tests/eden/all_tests.das` | aggregate: requires every test module, `run_all_tests` | yes |
| `.upstream/` | the pointer-based port and its tests, reference only, never edited | no |
| `wasm3c/` | the reference C sources and the fixtures | no `.das` inside |
| `.eden_host/main.das` | the project's `main.das` (installed to the project root by `scripts/eden/install_host.sh`) | after install |
| `.local/run_tests.das` | local test runner (reads fixtures with `fio`, allowed only under `.local/`) | no |
| `.local/app/wasm3_eden.das` | local command-line front end of the Eden port for `run-spec-test.py` / `run-wasi-test.py` | no |
| `scripts/eden/` | gates and tools, see PIPELINE.md | no `.das` inside |
| `docs/eden-port/` | this design, the pipeline manual, the state ledger | no |

The Eden project root (two levels up from the repository: `../../`) receives
`main.das` and `assets/wasm/**/*.data` from the install script. Nothing else
of the project is touched; the launcher regenerates `CLAUDE.md`, `.mcp.json`
and `.claude/` there on every open.

## 3. Module order

Dependency order of `.upstream/source` (a module requires only modules above
it). `m3_exec_expand` is a compile-time macro pass and has no Eden counterpart;
its job (operand readers) is done by plain helper functions in `m3_exec`.

| # | Module | Lines (upstream) | unsafe sites | Notes |
|---|---|---|---|---|
| 1 | `wasm3_defs` | 232 | 2 | endian probe becomes a constant (`M3_LITTLE_ENDIAN = true`, wasm is LE by definition) |
| 2 | `m3_config` | 246 | 0 | |
| 3 | `m3_exception` | 43 | 0 | |
| 4 | `m3_core` | 1186 | 15 | byte readers over `array<uint8>` + index cursor; allocator becomes arenas |
| 5 | `m3_types` | 554 | 9 | the type hub: structs with handles instead of pointers |
| 6 | `m3_math_utils` | 895 | 11 | bit casts via `daslib/math_bits` |
| 7 | `m3_code` | 441 | 9 | code words in one `array<uint64>` per runtime |
| 8 | `m3_function` | 317 | 10 | |
| 9 | `m3_module` | 196 | 11 | |
| 10 | `m3_exec_defs` | 133 | 2 | operand readers, `ExecState` accessors |
| 11 | `m3_exec` | 4541 | 240 | 509 ops, `RunLoop`, op table |
| 12 | `m3_compile` | 2465 | 41 | |
| 13 | `m3_env` | 1173 | 62 | environment, runtime, memory, call API |
| 14 | `m3_parse` | 727 | 37 | |
| 15 | `m3_bind` | 265 | 7 | host function linking |
| 16 | `m3_api_defs` | 259 | 22 | |
| 17 | `wasi_core` | 448 | 0 | |
| 18 | `m3_api_wasi_fd` | 780 | 15 | fd table over an in-memory stdio model |
| 19 | `m3_api_libc` | 535 | 15 | |
| 20 | `m3_api_wasi` | 689 | 25 | |
| 21 | `app` | `.local/app/wasm3_eden.das` + `.eden_host/main.das` | | the REPL for the spec driver, and the Eden host |

A module is ported only when every module above it is `done` in STATE.json.

## 4. From pointers to handles

The upstream port copies C's raw-pointer model. The Eden port keeps C's
function names, order and control flow but stores everything in arrays and
refers to it by index. The rules:

### 4.1 Ownership: the runtime owns the arenas

```das
struct M3Runtime {
    // arenas (index = handle, -1 = null)
    funcTypes  : array<M3FuncType>
    modules    : array<M3Module>
    functions  : array<M3Function>
    globals    : array<M3Global>
    rawCalls   : array<M3RawCall>    // linked host functions
    // execution state (see 4.4)
    code       : array<uint64>       // every compiled word of every function
    stack      : array<uint64>       // operand stack, one 64-bit word per slot
    mem        : array<uint8>        // linear memory, `length(mem)` = current size
    pc, sp     : int
    r0         : uint64
    fp0        : double
    trap       : string              // M3Result of the current trap ("" = none)
    // configuration, limits, error strings as in C
}
```

`M3Environment` keeps only configuration (what C keeps outside a runtime:
the stack-size hint, limits); the interned func-type list and the code
pages move into the runtime. Consequently **`m3_ParseModule` takes the
runtime** (`m3_ParseModule(var rt : M3Runtime; bytes : array<uint8>) :
tuple<M3Result; int>`, the module handle) and parses straight into the
runtime arenas; `m3_LoadModule(rt, moduleIdx)` then does what C's does
(memory, globals, data segments, table, start function) on an already
registered module. There is exactly one representation of every object:

| C | Eden |
|---|---|
| `module->functions[i]` (array of structs) | `rt.functions[module.functions[i]]`: the module keeps `functions : array<int>` of handles, in C order (imports first); `numFunctions = length(module.functions)` |
| `module->globals[i]` | `rt.globals[module.globals[i]]` |
| `module->funcTypes[i]`, interned in the environment | `rt.funcTypes[module.funcTypes[i]]`, interned in the runtime by structural equality (`Runtime_AddFuncType`, the C `Environment_AddFuncType`), so two equal types share one handle and `op_CallIndirect` compares handles |
| `module->table0[i]` (function pointers) | `module.table0 : array<int>` of function handles, -1 = null |
| `module->wasmStart/wasmEnd`, `function->wasm/wasmEnd` | the module owns `wasm : array<uint8>` (a copy of the binary); positions are indices into it |
| `function->compiled` (pc) | `int` index into `rt.code`, -1 = not compiled |
| `function->module`, `function->funcType`, `function->import.moduleUtf8/fieldUtf8` | `moduleIdx : int`, `funcTypeIdx : int`, strings |
| `runtime->memory.mallocated` | `rt.mem : array<uint8>` + `memory : M3Memory { numPages, maxPages, pageSize }` |
| `runtime->stack`, `originStack` | `rt.stack : array<uint64>`, `originStack : int` |
| `runtime->modules` (linked list) | `rt.modules : array<M3Module>`, `module.next` not needed |
| `runtime->environment->pagesOpen/Released`, code pages | `rt.code : array<uint64>`; `M3CodePage` (from `m3_core`) is a start index + length used by `m3_code`, `m3_compile` |

Decisions fixed by `m3_types` (the struct table is in its header):

- `IM3Runtime` handles: 0 = the owning runtime, -1 = null (a module's
  `runtime` is -1 until `m3_LoadModule`). `rt.environment` is an embedded
  copy of the environment; its `retFuncTypes` handles are interned per
  runtime by `m3_NewRuntime`.
- Code pages: `rt.codePages : array<M3CodePage>` is the page arena
  (`pagesOpen`, `pagesFull`, `M3CodePageHeader.next` are indices into it);
  a page's words live in `rt.code` from `page.code` on. `m3_code` owns the
  page functions.
- `M3Function.constants : array<u64>` and `M3Compilation.constants :
  u64[d_m3MaxConstantTableSize]`: one 64-bit word per **slot**, so a 64-bit
  constant still reserves two consecutive slots (the second unused) and the
  compiler's slot accounting is C's. `numConstantBytes` keeps its C name.
- `M3SectionHandler = function<(var rt : M3Runtime; i_module : IM3Module; i_name : cstr_t; i_start, i_end : cbytes_t) : M3Result>`,
  `M3Compiler = function<(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result>`:
  the compilation state is `rt.compilation`, so C's `IM3Compilation`
  argument is the runtime.
- `M3CompilationScope.outer : int` indexes a scope stack that `m3_compile`
  adds to `M3Compilation` (C keeps scopes on the native stack).
- `m3Error(i_result; var i_runtime : M3Runtime; ...)` always records
  (C's `if (i_runtime)` null guard has no counterpart).
- `M3ImportContext.userdata` / `M3Runtime.userdata` are `int` tokens.
- Func-type interning: `AllocFuncType` can only append to `rt.funcTypes`.
  C's `Environment_AddFuncType` (`m3_env.c`) and `ValidateSignature`
  (`m3_bind.c`) free the freshly built type when an equal one exists; the
  Eden port pops the just-appended last slot (or compares before
  appending) so the survivor is the existing handle, which
  `op_CallIndirect` compares by handle.
- `Module_AddFunction(var rt; m; i_typeIndex; i_importInfo : M3ImportInfo; i_isImport : bool)`:
  the explicit flag replaces C's `i_importInfo != NULL` test (an import
  field name may be `""`, `names.wast`). The parser passes `true` and the
  import for C's `&import`, `false` and `M3ImportInfo()` for C's `NULL`.
  The function slot's `moduleIdx` stays -1, exactly as C leaves
  `func->module` NULL: `ParseSection_Code` sets it for a local function
  with a body and `CompileRawFunction` (the `m3_bind` link path) for an
  import; `Compile_Call` reports `function import missing` for an import
  whose `moduleIdx` is still -1. Module handles into `rt.modules` are
  never reused; `m3_FreeModule` leaves a released slot.
- `M3Module.startFunction : i32 = -1` from construction (C callocs 0 and
  sets -1 in `m3_parse.c` before use; `m3_LoadModule` runs any index >= 0).
- `cstr_t = string` cannot tell C's `NULL` from `""`. C relies on the
  difference for import/export names (`m3_env.c`: `isImported =
  moduleUtf8 || fieldUtf8`, `names[j] && strcmp`, and `m3_bind.c`), and the
  spec suite's `names.wast` exports a function named `""`. The porters of
  `m3_env` and `m3_bind` must carry the distinction explicitly (a `bool`
  next to the string, or `numNames` as the guard) rather than `!empty(s)`,
  and the reviewer of those modules checks `names.wast`-style cases.

Freeing a runtime is clearing the arrays; there is no `delete` and no `new`
for `M3*` data. Structs are values inside arrays (`M3Function`, `M3Module`,
`M3Global`, `M3FuncType`, `M3ImportInfo`, `M3DataSegment`, `M3MemoryInfo`,
`M3Compilation` ...), created with `S()` and their initializers.

Every C pointer field becomes an `int` handle into the arena named by the
field's type (`IM3Function` → `int` into `rt.functions`, `IM3Module` → `int`
into `rt.modules`, `IM3FuncType` → `int` into `rt.funcTypes`). Name the field
as in C and add the suffix `Idx` only when the C name would read as a value
(`functionIdx` for `function`, `moduleIdx` for `module`).

### 4.2 Linear memory

`rt.mem : array<uint8>`; the wasm address is the index. `m3_exec_defs`
provides the accessors and they are the only place bytes are assembled:

```das
def load_u32(rt : M3Runtime; at : int) : uint     // little-endian, no bounds check
def store_u32(var rt : M3Runtime; at : int; v : uint)
// u8 s8 u16 s16 u32 i32 u64 i64 f32 f64 variants, f32/f64 through
// uint_bits_to_float / uint64_bits_to_double and back (daslib/math_bits)
```

Bounds checks stay where C has them (in the op, against `length(rt.mem)`),
with the same trap strings. `ResizeMemory` is `resize(rt.mem, newLength)`;
no `_mem` reload dance is needed because there is no pointer.

### 4.3 Operand stack and registers

`rt.stack : array<uint64>`, one 64-bit word per **slot**. The compiler's slot
accounting is unchanged (`m3slot_t` units, 64-bit values still reserve two
consecutive slots, the second one stays unused). `_sp` is `rt.sp`, an index.
Slot readers in `m3_exec_defs`:

```das
def slot_u32(rt; off : int) : uint      // uint(rt.stack[rt.sp + off])
def slot_i64(rt; off : int) : int64
def slot_f32(rt; off : int) : float     // uint_bits_to_float(uint(word))
def slot_f64(rt; off : int) : double    // uint64_bits_to_double(word)
def set_slot_*(var rt; off; value)
```

`_r0` is `rt.r0 : uint64`, `_fp0` is `rt.fp0 : double` (C `f64`). Stack
overflow is `rt.sp + maxStackSlots > length(rt.stack)` in `op_Entry`, same
trap string.

### 4.4 Code words, immediates and dispatch

`rt.code : array<uint64>` holds every compiled function; `rt.pc` is an index.
A word is either an operation (its index in the op table) or an immediate:

| C immediate | Eden word |
|---|---|
| `i32`/`u32` constant | `uint64(uint(v))` |
| `i64`/`f64` constant | the bits |
| `pc_t` | `uint64(pcIndex)` |
| `IM3Function` | function handle |
| `IM3Module` | module handle |
| `IM3FuncType` | func-type handle |
| `M3RawCall` | raw-call handle |
| global address | global handle |

Operations have one signature and are ordinary functions:

```das
typedef M3Op = function<(var rt : M3Runtime) : int>

// return protocol (m3_exec_defs)
let public M3_NEXT   = -1      // continue with rt.code[rt.pc]
let public M3_RETURN = -2      // the function returned normally (C: m3Err_none)
let public M3_TRAP   = -3      // rt.trap holds the M3Result
// any value >= 0 is the pc of a loop header (C: op_ContinueLoop returning the pc)
```

`RunLoop(var rt : M3Runtime) : int` is the C `RunLoop`/`nextOpImpl` trampoline:
read the word, `rt.pc++`, `invoke(g_ops[int(word)], rt)`, repeat while the
result is `M3_NEXT`. Immediates are read with `immediate_u64(var rt) : uint64`
(`let v = rt.code[rt.pc]; rt.pc++; return v`) and typed wrappers; each read is
its own statement, never nested inside another expression (the reason the
upstream macro pass existed).

Fixed by `m3_exec_defs` (its header is the API reference for `m3_exec`):
`retOp(rt)` = `M3_RETURN` (C `return m3Err_none` from an op),
`newTrap(rt, err)` stores the string in `rt.trap` and returns `M3_TRAP`,
`forwardTrap(rt, result : M3Result)` maps `""` to `M3_RETURN` and anything
else to a trap (for `op_CallRawFunction`), `d_m3ClearRegisters(rt)` zeroes
`r0`/`fp0`. The immediate readers are `immediate_u64/u32/i32/i64/f32/f64/pc/handle/slot`
(one word each, `immediate_handle` replaces C's function/module/functype/
rawcall immediates), the slot accessors come in three forms, frame-relative
`slot_T(rt, off)`, saved-index `stack_T(rt, idx)` with `slot_index`, and the
combined `slot_T(var rt)` that reads the offset immediate then dereferences
(C's `slot(_pc)` macro). **Two combined reads never share one expression**:
each is the sole side effect of its statement (`let a = slot_i32(rt)` then
`let b = slot_i32(rt)`), or the evaluation order is unspecified. A 32-bit
slot store writes the whole word zero-extended (the word is the slot).
Memory accessors `load_T/store_T(rt, at)` assemble little-endian bytes with
no bounds check; `mem_size(rt)` stands for `_mem->length`. Nesting sites of
`RunLoop` (`op_Call`, `op_CallIndirect`, `op_Entry`, `op_Loop`) save and
restore `rt.pc`/`rt.sp` around the nested call, since C's by-value
registers are shared fields here.

The op table `g_ops : array<M3Op>` and `g_opIndex : table<string; int>` are
filled once by `m3_build_op_table()` in `m3_exec`, which registers every
operation by name (`m3_register_op("op_Entry", @@op_Entry)` ...); the index
is the registration order, and only consistency matters (words store the
index, `m3_compile` looks names up through the same table), so the table
can be built up module-part by module-part. `m3_OpWord(name) : u64` /
`m3_OpAt(idx) : M3Op` / `m3_OpCount()` are the accessors; the compiler's
`M3OP` records carry op names (resolved to indices when the table is built)
instead of function values. `op_Compile` rewrites the word in `rt.code` in
place. `m3_exec` is ported in three parts (infrastructure and calls;
control, slot, global and memory ops; the arithmetic families), each part
compiling and passing its tests before the next; the op count is 510 when
complete (the upstream file's `def op_` count).

Nested execution (C's real calls): `op_Call`, `op_CallIndirect`, `op_Entry`
and `op_Loop` call `RunLoop` recursively, exactly where C does. Fixed by
`m3_exec` part 1: `Call(rt, pc, sp, r0, fp0) : m3ret_t` saves
`rt.pc/sp/r0/fp0`, installs the arguments, runs one nested `RunLoop` and
restores all four (C's by-value registers); it returns `M3_RETURN`,
`M3_TRAP` (set once by `newTrap`, forwarded by every level) or an escaped
loop pc. `op_Entry` forwards its nested result; `op_Loop` resets `rt.pc`
to the loop header and clears the registers per iteration while the
result equals the header pc. Nothing clears `rt.trap`; `m3_Call` (m3_env)
resets it before `RunCode`. `op_CallRawFunction` swaps `rt.originStack`
as C swaps `runtime->stack`, so `m3_Call` uses `rt.originStack` as the
frame base. `op_Entry` keeps C's strict `sp + maxStackSlots <
length(rt.stack)` check. An unknown op name in `m3_OpWord` is a
`d_m3Assert` panic (as upstream `m3_OpIndex`). Deep wasm
recursion therefore needs `options stack = 67_108_864` in the Eden host and in
`.local/app`; the trap `[trap] stack overflow` from `op_Entry` remains the
documented limit.

### 4.5 Host functions

```das
typedef M3RawCall = function<(var rt : M3Runtime; sp : int) : string>
```

Arguments are read from `rt.stack[sp + i]` through the `m3Api*` helpers of
`m3_api_defs`, memory through the 4.2 accessors. Linking (`m3_bind`) stores the
function value in `rt.rawCalls` and its handle in the code word.

### 4.6 Errors and traps

`M3Result = string`, `""` means success, the constants keep their C text.
Results are compared by content (`r == ""`, `r == m3Err_trapStackOverflow`).
No result is ever compared by identity and none is used as a control token;
the return protocol of 4.4 replaced that.

### 4.7 WASI and files

The Eden sandbox has no file system. `m3_api_wasi_fd` implements the fd table
over an in-memory model: fd 0 reads from `rt.stdinBuffer : array<uint8>`, fd 1
and 2 append to `rt.stdoutBuffer` / `rt.stderrBuffer` (also mirrored to
`print` in the Eden host), every other fd operation returns `WASI_EBADF` or
`WASI_ENOSYS` as Wasm3 does for unsupported cases. `.local/app` adds real
stdin/stdout on top for the WASI driver. `m3_api_libc` and `m3_api_wasi` lose
nothing else.

### 4.6a Canonical NaN

`_nan_f32()` / `_nan_f64()` of `m3_math_utils` are `inf / inf` (the upstream
form): on x86 that is the sign-set default NaN `0xffc00000` /
`0xfff8000000000000`, while C wasm3's `NAN` macro is the positive
`0x7fc00000`. The wasm spec accepts either sign for `nan:canonical`, the
upstream spec run passes with it, and the tests assert `isnan` only. Not
measured in the editor (same x86-64 hardware, no difference expected); if
the spec run in the editor ever disagrees on a NaN case, this is the first
place to look.

### 4.6b Bit counts at zero

`builtin_clz/ctz` of `m3_math_utils` delegate to daslang's `clz`/`ctz`,
which return 31/0 (63/0 for 64-bit) at zero, like C's undefined builtins.
The zero guard is the caller's, as in C: `OP_CLZ_32(x) = x == 0 ? 32 :
...` in `m3_exec.h` and the upstream `m3_exec.das`. The `m3_exec` port
keeps every such guard.

### 4.7a The `_try` / `_catch` macros

`m3_exception` (a re-export module) documents the expansion of C's `_try`,
`_()`, `_throw`, `_throwif`, `_throwifnull` as early `return result`. Two C
sites carry code after `_catch:` and must not take that shape mechanically:
`m3_bind.c` (`_catch:` then `m3_Free(ftype)`) and `m3_compile.c`
(`_catch:` then `*o_codePage = page`). The upstream port falls through at
both (`.upstream/source/m3_bind.das`, `.upstream/source/m3_compile.das`);
the Eden port does the same. `_throwifnull(PTR)` tests a handle against
`-1`.

### 4.7b Allocator helpers of `m3_core`

`m3_Malloc_Impl(var arr; n)`, `m3_Realloc_Impl(var arr; new; old)`,
`m3_Free_Impl(var arr)` and `m3_CopyMem(arr; n) : array<T>` are generic over
`array<T>` and take **element counts**. The one C caller of `m3_CopyMem`
(`m3_compile.c`, the constant table) passes a byte count
(`numConstantBytes`); the Eden `m3_compile` passes the element count
(`numConstants`). `m3_AllocStruct(S)` is `S()`.

### 4.8 What must not change

- C function and variable names, the order of functions in a file, the
  control flow, the trap and error strings, the checks and their order.
- The C-origin header comment and the list of deviations at the top of every
  file (the upstream port's convention). Every deviation from C or from the
  upstream port is stated at its site: `// Eden: <what and why>`.
- One implementation per behavior: reuse `daslib`, never re-implement it.

## 5. Tests

### 5.1 Framework: `source/eden_test.das`

Pure Daslang, no macros:

```das
struct TestRun {
    pass, fail : int
    failures : array<string>       // "test_name: message"
    current : string               // the running test's name
}
struct FixtureSource {
    load : lambda<(name : string) : array<uint8>>   // "" -> empty array when missing
}
def check(var t : TestRun; cond : bool; msg : string)
def equal(var t : TestRun; got, want : auto; msg : string)   // formats both values
def begin_test(var t : TestRun; name : string)
def summary(t : TestRun) : string   // "WASM3 TESTS pass=N fail=M"
```

`FixtureSource` names are paths under `wasm3c/test/` (`lang/fib32.wasm`). The
local runner loads them with `fio`; the Eden host loads
`assets/wasm/<name>.data` through `get_binary_asset`. The fixtures a test
needs are listed in `docs/eden-port/fixtures.txt` and installed by
`scripts/eden/install_host.sh`.

### 5.2 One test module per source module

`tests/eden/test_<module>.das` exposes
`def public run_tests_<module>(var t : TestRun; fx : FixtureSource)` which
calls every test function. Each upstream `[test] def test_x` in
`.upstream/tests/integration/test_<module>.das` has a counterpart
`def test_x(var t : TestRun; fx : FixtureSource)` with the same checks
(translated from pointers to handles), or a line
`// dropped: test_x -- <reason>` in the header. `scripts/eden/coverage.sh`
enforces this mechanically; a dropped test needs a reason that names the
capability the sandbox lacks, "hard to port" is not one.

`tests/eden/all_tests.das` requires every test module that exists and runs them
all; the porter adds the new module's line when the module lands.

### 5.3 Gates a module must pass (in this order)

1. `scripts/eden/compile.sh` — every file under `source/`, `tests/eden/`,
   `.local/` compiles under the sandbox project with the 0.6.4 pin **and** the
   0.6.3 build. Zero errors.
2. `scripts/eden/coverage.sh` — the upstream-test mapping of 5.2 holds.
3. `scripts/eden/test.sh` — the local runner reports `fail=0`.
4. `scripts/eden/eden_gate.sh` — the editor compiles the project (no
   `compilation failed` in `get_game_status`), the cheat `wasm3_tests` prints
   `WASM3 TESTS pass=N fail=0`, and N equals the local run.
5. `scripts/eden/install_host.sh --check` — the host and fixtures installed
   in the Eden project are the committed ones.
6. Module `lang_modules` is the end-to-end smoke: every `wasm3c/test/lang`
   fixture runs through the whole stack, `fib(25) = 75025`, locally and in
   the editor (it is an ordinary test module, so gates 3 and 4 cover it).
7. Final (module `app`): `scripts/eden/spec.sh` (the unmodified
   `wasm3c/test/run-spec-test.py` against `.local/app` through
   `scripts/eden/wasm3`) passes its default list with the pass count of
   `STATE.json spec_expected` and 0 failures, 0 crashes; and
   `scripts/eden/wasi.sh --fast` passes 7/7.

`scripts/eden/gate.sh` runs 1–5 (7 when the ledger says `app` is in verify
or done) and is what the verifier and the goal condition
(`scripts/eden/goal_check.sh`) call.

## 6. Language pitfalls, measured on 0.6.3

Each of these cost a compile cycle while bootstrapping; check them before
asking the compiler.

- `pass` is a keyword: no field, variable or function may be called `pass`
  (the test counters are `passed`/`failed`).
- A struct variable must be initialized: `var t = TestRun()`, never
  `var t : TestRun` ("Uninitialized variable t is unsafe").
- A lambda value is `@(args) : ret { ... }`; `@@(...)` is a function pointer
  and does not convert to a `lambda<>` field. `invoke(fx.load, name)` calls it.
- No line continuation: an expression cannot be split after `||` or `&&`
  onto the next line (automatic semicolon insertion). Bind partial results
  to `let` variables instead.
- `exit()` is unsafe; only `.local/` tools may call it (`unsafe(exit(1))`).
- `print` ends the line in the editor console but not on the command line:
  print through `out()` of `eden_test` (adds `\n`) in anything the gates parse.
- Keywords that are legal identifiers in C but not here: `addr`, `pass`,
  `new`, `delete`, `typeinfo`, `label`, `goto` (rename parameters such as
  `addr` to `at`).
- `resize` on an `array<Struct>` whose struct has field initializers is
  refused by 0.6.3 as an unsafe builtin (0.6.4 accepts it). Grow with
  `reserve` + `push(arr, T())`, shrink with `pop`; the `m3_Malloc_Impl` /
  `m3_Realloc_Impl` helpers of `m3_core` do exactly that, use them for every
  arena of `M3*` structs. `resize` on arrays of scalars is fine.
- `[inline]` does not exist in 0.6.3: drop it (the upstream port used it on
  small helpers).
- Byte cursors are `(bytes : array<uint8>; var o_value : T&; var io_pos : int&; i_end : int) : M3Result`
  (the array first, then the C parameters in C order); the full list is in
  the header of `source/m3_core.das`.
- A `require` must be Eden-project-root relative
  (`require modules/wasm3das/source/m3_core`); `./x.das` does not resolve in
  the editor.

## 7. Non-goals

- Performance parity with the pointer port; the interpreter is the target and
  measurements go to `docs/eden-port/MEASUREMENTS.md` when they exist.
- The JIT/AOT/standalone tiers of the upstream port.
- `m3_info`, the tracer, imported memories/tables/globals: not started
  upstream either.
