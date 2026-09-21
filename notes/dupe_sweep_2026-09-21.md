# Dupe sweep of the port against the daslang toolchain, 2026-09-21

Three SHARD runs of `.claude/agents/dupe-sweeper.md` (Opus, `source/*.das` and
`app/wasm3.das`, 1072 functions read in full, `detect-dupe` corpus = the
checkout's `daslib`, `modules/*/daslib`, `utils`, 20k functions) merged by the
orchestrator. The question behind it: what does the port re-implement that
daslang already provides. Verdicts follow `/root/daScript/skills/dupe_audit.md`;
"ruled" means AGENTS.md's fidelity rule protects the C name, and the finding is
still listed because the owner decides per case.

## A. Re-implemented toolchain builtins (the answer to the question)

| port | toolchain | callers | note |
|---|---|---|---|
| `m3_exec.das:109 c_memmove` (op_MemCopy) | builtin `memmove(void?, void?, u32/u64/int/int64)` (`src/builtin/module_builtin_runtime.cpp:2707`) | 1 | the fast path in the port is what libc memmove does anyway; C wasm3 calls `memmove` here, so the builtin is the more faithful spelling |
| `m3_api_libc.das:124 libc_memmove` | the same builtin | 1 | the byte-at-a-time backward loop is the slow path of `env._memmove`; the comments at `m3_api_libc.das:82` and `:121` and `PORTING_MANIFEST.md:35` ("no memmove builtin") are wrong against the pin |
| `m3_api_libc.das:105 libc_memcpy` (2 GiB chunk loop) | builtin `memcpy` has `uint32_t`/`int64_t`/`uint64_t` size overloads | 1 | the loop guards an `int` limit the builtin does not have; `libc_memset`'s loop stays, `memset8` is bound with an `int` size only |
| `m3_core.das:536 m3_copy_bytes` (chunk loop) | builtin `memcpy` with a `u64` size | 2 | same; `m3_zero_bytes` stays for the same `memset8` reason |
| `app/wasm3.das:98 str_bytes`, `m3_api_libc.das:269 str_bytes` (byte-identical, twice) | `strings::to_bytes` | 6 | |
| `app/wasm3.das:166 utoa` | `fmt(value, "{}")` / `format` | 6 | the comment's reason (interpolation prints u64 in hex) argues against `"{x}"`, not against `fmt` |
| `m3_api_libc.das:291 internal_itoa` | `fmt(x, radix == 16 ? "{:X}" : "{}")` | 1 | uppercase hex matches C's `HEXDIGITS` |
| `app/wasm3.das:184 hex_value` | `strings::is_hex` for the test; no exported digit-value helper, `daslib/toml.das:76` has a private twin (four private copies in the toolchain) | 3 | the real fix is an exported `hex_value` in daslib/strings (upstream) |
| `app/wasm3.das:663 unescape_argv` | `strings::safe_unescape` | 2 | the port's `\0` arm cannot produce an embedded NUL in a daslang string anyway |
| `app/wasm3.das:701 split_argv` | `strings_boost::split_by_chars(s, " \n\r\t")` plus one `erase_if(empty)` | 1 | |
| `app/wasm3.das:131 strtoull_10` | `strings::uint64(str, result, offset)` (C's endptr semantics) or `to_uint64` | 6 | check the `-` wrap arm before folding |
| `m3_math_utils.das:287,381 strtoull` | the same | **0** | dead |
| `m3_math_utils.das:69-92 builtin_popcount/ctz/clz(+ll)` | `popcnt`, `clz`, `ctz` | **0** | dead; `m3_exec.das` calls the builtins directly |
| `m3_math_utils.das:866,870 M3_MAX/M3_MIN` | `max`, `min` | **0** | dead |
| `m3_core.das:1144 Read_utf8` staging through `array<u8>` | `map_to_ro_array(ptr, len) <| $(v) { s = string(v) }` | 11 (parse) | one resize, one copy and one free per name for nothing |
| `signbit`, `fabsf`, `fabs`, `copysign_f32/f64`, the bit reinterprets | `daslib/math_bits` (`float_bits_to_uint` family) | many | readability and `unsafe` surface only; the `op_*_Reinterpret_*` operations stay raw |

Genuinely absent from the toolchain, so the port's own code is right: libm-faithful
`floorf`/`ceilf`/`rintf`/`rint` (`math::floor/round` differ, documented at
`m3_math_utils.das:126`), `rotl`/`rotr`, `copysign`, NaN constants, byte swaps
(`m3_bswap*`), LEB128 and the cursor-based binary readers (`array_boost::pod_view`
is the nearest and cannot serve), a file-descriptor table over `fio`, POSIX clock
ids and resolution, runtime argv parsing (`daslib/build_const` is compile time),
and the `read_line` loop around `fgets`' 16383-byte cap (worth an upstream note).

## B. Defects found on the way

- **`m3Error` exists twice and behaves differently**: `m3_types.das:542` gates on
  `i_runtime != null`, `m3_env.das:1144` on `d_m3VerboseErrorMessages && ...` as C
  does (`m3_env.c:1167`, the only C definition). Compile errors therefore record
  file/line/message even with verbose messages off, lookup errors do not. One
  definition, in the type hub, with the C gate.
- **Sixteen typed accessors over one `valueBits : u64`**: `tagged_get/set_*`
  (`m3_env.das:41-90`, 47 callers) and `M3Global_Get/Set*Value`
  (`m3_types.das:487-526`, 8 source callers, each paired with a `tagged_*` on the
  same line). C reads the union members directly; the port invented both families,
  two of them by `reinterpret`, the rest by `addr` + deref. Fold: one generic get
  and one generic set over the storage word.
- **`SuppressLookupFailure` twice** (`m3_api_libc.das:458`, `m3_api_wasi.das:572`,
  35 callers): C also defines it twice with external linkage, an ODR collision
  the linker tolerates; the port copies a C bug, one public definition suffices.
- `M3_LIKELY`/`M3_UNLIKELY` (`wasm3_defs.das:227,232`): identity functions with
  zero production callers, seven test callers.
- `jumpOpImpl` (`m3_exec_defs.das:140`): zero callers since the trampoline; a C
  name with no C behaviour behind it.
- `m3_CallV`/`m3_GetResultsV` are bare forwards to the `VL` forms: the C reason
  (a `va_list`) does not exist in daslang; keep only as documented source
  compatibility.

## C. Templatable sets (the owner's call against the fidelity rule)

- `m3ApiGetArg_*` (6, two dead), `m3ApiReturn_*` (6, four dead), `m3ApiReadMem*`
  (4), `m3ApiWriteMem*` (4): the expansion of one C macro family parameterized on
  TYPE, so one generic per family is closer to C than eighteen copies;
  `m3ApiReturn_u32` and `m3ApiWriteMem32` are the same body.
- `errno_to_wasi` (33 arms, 30 callers): a table instead of 33 equality tests on
  every failing fd operation.
- The three link lists (35 copies of `SuppressLookupFailure(m3_LinkRawFunction(...))`
  + early return): a row array walked by one loop keeps C's order and early exit.
- `fd_read`/`fd_write`: the same iovec walk twice, the transfer is the axis (the
  port already folded `fd_seek`'s tail the same way).
- `m3_math_utils.das`: `floorf`/`ceilf`, `rintf`/`rint`, `fabsf`/`fabs`, `signbit`
  ×2, `_nan_*`, `min/max_f32/f64`, `rotl/rotr32/64`, `OP_DIV/REM_U/S`, the eight
  `OP_*_TRUNC_*` and eight `OP_*_TRUNC_SAT_*` (one table of `(TT, RMIN, RMAX)`
  rows each), `OP_ADD/SUB/MUL_32/64`, `OP_SHL/SHR_32/64`, `OP_CLZ/CTZ_32/64`,
  `copysign_f32/f64`: every pair differs on the type or one constant. C
  `m3_math_utils.h` keeps each as its own `#define`, so all are ruled; the
  `OP_*_TRUNC*` sixteen are the cheapest fold if any is taken.
- The 28 operand readers `immediate_*`/`slot_ptr_*`/`slot_*`: one type axis, but
  `m3_exec_expand.das` matches them by name (`is_reader_name`), so the fold
  rewrites the pass too.
- `m3_exec_expand.das:105-121 as_block/as_unsafe/as_let/as_return/as_var`: one
  generic `as_node`, the only exact cluster in that file.
- `m3_env.das`: the four-arm type dispatch appears seven times
  (`m3_GetGlobal`, `m3_SetGlobal`, `m3_CallVL`, `m3_Call`, `m3_CallArgv`,
  `m3_GetResults`, `m3_GetResultsVL`), the three-line call tail three times, the
  `checkStartFunction` preamble three times: faithful to C's per-function
  `switch`, and the largest repetition in the tree.

Ruled separate and not counted: the 509 operations and the 265 operation-table
rows (C macro families), `Read_u64/u32/f64/f32`, the `ReadLEB_*` wrappers,
`IsFpType/IsIntType`, the paired `GetFuncType*`/`GetFunction*` accessors, the
`Compile_Const_*`, `Compile_Memory_Size/Grow`, `IsStackTop*InRegister`, the two
`fd_seek` flavours, the two `wasi_iovec_t`/`wasi_ciovec_t` structs, the
`ParseSection_*` prologue, the `m3ApiCheckMem` expansion, the `ARGV_SHIFT` pairs.

Summary over the three shards: 1072 functions read, 21 duplicates, 27
templatable sets (136 members), 14 local blocks, 23 ruled separate.

## D. Suggested order

1. The defects of section B (`m3Error`, the sixteen accessors,
   `SuppressLookupFailure`, the dead `M3_LIKELY` pair, `jumpOpImpl`): a `fix/` PR
   with the C references, no behaviour change except the verbose gate.
2. The builtins of section A that C itself calls (`memmove` at both sites, the
   chunk loops of `libc_memcpy` and `m3_copy_bytes`, `to_bytes`, `Read_utf8`),
   plus the four dead helpers and the stale comments and manifest row: one PR,
   since every replacement is what the C source says (`memmove`, `memcpy`,
   `strtoull` unused).
3. The `app/wasm3.das` helpers (`utoa`, `hex_value`, `unescape_argv`,
   `split_argv`, `strtoull_10`, `internal_itoa`): the app is the port of
   `main.c`, whose helpers are libc calls, so daslang's `strings` is their
   counterpart; one PR with the spec suite as the gate.
4. The templatable sets of section C only with an explicit ruling change in
   `AGENTS.md` ("C constructs and their Daslang spellings"): a C macro
   parameterized on TYPE may be one daslang generic.
