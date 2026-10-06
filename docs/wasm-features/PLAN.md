# WebAssembly feature coverage: plan

Goal: wasm3das runs arbitrary WebAssembly as the current standard defines
it - the WebAssembly 3.0 core and the proposals toolchains emit - with the
semantics of the specification, inside the EdenSpark sandbox. The C wasm3
the port follows stops at WebAssembly 1.0 plus mutable globals, sign
extension, saturating truncation, multi-value, part of bulk memory and
custom page sizes; everything past that is new code, written in the
port's style (DESIGN.md of docs/eden-port) and tested against the official
test suite. Optimisations stay optional (`edenFuseOps`); the default path
executes what the module says.

The ledger is `STATE.json` next to this file. The verification pipeline
is built first (phase P0) and is the same for every feature.

## 1. The reference: the official test suite

- `WebAssembly/testsuite` at a pinned commit (`STATE.json` `corpus.commit`,
  first pin b464a4cd, 2026-09-15). Its top level is the WebAssembly 3.0
  core: the 1.0/2.0 core plus the merged proposals (reference types, bulk
  memory, SIMD, relaxed SIMD, tail calls, exception handling, multi-memory,
  memory64 and table64, function references, GC, extended constant
  expressions). `proposals/` holds the open ones: threads,
  wide-arithmetic, custom-page-sizes, custom-descriptors,
  compact-import-section; `legacy/` the pre-3.0 exception handling.
- The corpus lives outside the Eden project (`WASM3DAS_CORPUS`, default
  `/root/.cache/wasm3das`): the editor imports every text file of the
  project tree, and the converted suite is tens of thousands of files.
- `.wast` files are converted with `wasm-tools json-from-wast` (pinned
  version in `STATE.json`) into the JSON + `.wasm` form spec drivers read.
- The opam-1.1.1 corpus of `scripts/eden/spec.sh` stays the regression gate
  of what already works (17863 assertions).

## 2. Feature groups

Every `.wast` belongs to exactly one group (`groups.json`, patterns over
the corpus paths; a file no pattern claims fails the pipeline, so a new
corpus pin cannot add untracked tests). Several 3.0 core files mix in later
features (typed `select`, table indices in `call_indirect`); a test of such
a file counts in its group but its failure names the missing feature.

| Group | Files (patterns) | Needs |
|---|---|---|
| core | the 1.0/2.0 files: address, align, binary, block, br, br_if, br_table, call, call_indirect, const, conversions, custom, data, elem, endianness, exports, f32*, f64*, fac, float_*, forward, func, func_ptrs, global, i32, i64, if, imports, int_*, labels, left-to-right, linking, load, local_*, loop, memory, memory_grow, memory_redundancy, memory_size, memory_trap, names, nop, return, select, stack, start, store, switch, token, traps, type, unreachable, unreached-*, unwind, utf8-*, comments, id, inline-module, annotations, obsolete-keywords, skip-stack-guard-page, instance | multi-module linking, the 3.0 additions in these files |
| bulk-memory | memory_copy, memory_fill, memory_init, data_drop0, bulk | passive segments, memory.init, data.drop |
| reference-types | ref_null, ref_is_null, ref_func, table, table-sub, table_*, elem expressions | tables of funcref/externref, table.* ops, multiple tables, select t |
| tail-call | return_call, return_call_indirect | return_call* |
| multi-memory | memory-multi, the numbered variants (address0/1, load0..2, store0..2, memory_size0..3, data0/1, float_memory0, memory_copy0/1, memory_fill0, memory_init0, memory_trap0/1, imports0..4, exports0, linking0..3, binary0, float_exprs0/1, start0, traps0, data_drop0) | memory index on every memory op |
| simd | simd_* | v128 values, 236 operations |
| relaxed-simd | relaxed_*, *_relaxed_* | the relaxed operations (deterministic choice) |
| exceptions | tag, throw, throw_ref, try_table, legacy/* | tags, exnref, unwinding through RunLoop |
| memory64 | *64.wast, binary_leb128_64, memory64-imports | i64 addresses, table64 |
| function-references | call_ref, return_call_ref, br_on_null, br_on_non_null, ref_as_non_null, local_init, type-equivalence | typed references, non-null locals |
| gc | struct, array*, i31, br_on_cast*, ref_cast, ref_test, ref_eq, extern, type-canon, type-rec, type-subtyping, binary-gc | heap types, structs and arrays on a managed heap, subtyping |
| threads | proposals/threads | shared memory, atomics (single-threaded host: atomics are plain accesses, wait returns "not-equal"/"timed-out") |
| wide-arithmetic | proposals/wide-arithmetic | i64 add128/sub128/mul_wide |
| custom-page-sizes | proposals/custom-page-sizes | (C wasm3 has it; verify) |
| validation | every `assert_invalid` / `assert_malformed` of every group | a validator: the C compiler checks only what it needs |

custom-descriptors and compact-import-section are tracked but last: no
toolchain emits them yet.

## 3. Order

| Phase | Work | Why first |
|---|---|---|
| P0 | the pipeline: corpus fetch + conversion, `groups.json`, the driver (`--check` / `--update` against `passing.json`), the baseline per group | every later phase is measured with it |
| F1 | core: multi-module linking (wasm imports of another wasm module's functions, globals, memories, tables) with the app's REPL for named modules, `register` and `get`; the 3.0 details in the core files | linking.wast, imports.wast and most groups use `register`; the runtime cannot link wasm to wasm, so the REPL commands wait for it |
| F2 | bulk-memory complete | clang and rustc emit it by default |
| F3 | reference-types (tables, multiple tables, externref) | rustc and clang emit reference types by default; F2/F3 share the segment model |
| F4 | tail-call | small; C++ coroutines and functional languages |
| F5 | multi-memory | the memory index everywhere; before SIMD so SIMD memory ops take it once |
| F6 | simd | the largest operation set; Emscripten/clang -msimd128 |
| F7 | relaxed-simd | on top of F6 |
| F8 | exceptions (+ legacy) | C++ exceptions with -fwasm-exceptions; needs unwinding |
| F9 | memory64 / table64 | large-memory programs |
| F10 | function-references | prerequisite of GC |
| F11 | gc | Kotlin, Dart, OCaml, Java via wasm GC |
| F12 | threads, wide-arithmetic, custom-page-sizes | single-threaded host semantics |
| V | validation | runs alongside: each phase adds the validation rules of its group |

## 4. Gate of a phase

A phase is done when, committed together:

1. its group passes every runnable assertion of the corpus (`run.py
   --group <g>`; the whole corpus runs in about half a minute on 8 jobs,
   so every phase runs all of it): `assert_return`, `assert_trap`, `assert_exhaustion`,
   `assert_exception`, `assert_unlinkable`, `assert_uninstantiable`, and
   the module and register commands; an exclusion is allowed only with a
   measured reason in `STATE.json` (for example an editor-only float
   deviation), never "not implemented";
2. no command of `passing.json` stops passing (`run.py --check`), and the
   phase's commit records the new passing set (`run.py --update`);
3. the existing gates stay green: `scripts/eden/compile.sh`, `test.sh`,
   `spec.sh` (opam 17863), `wasi.sh` (12/12), the DOOM digests of
   `.local/run_dgv.das`, and the editor compiles the project
   (`scripts/eden/eden_gate.sh`);
4. tests in `tests/eden/` for the new operations (each operation word
   executed, as `test_every_op_executed` enforces), so the editor's own
   suite covers them too.

## 5. Constraints that shape the design

- The sandbox: no `unsafe`, no pointers; values are words in `rt.stack`
  (DESIGN 4.3). A v128 is two adjacent 64-bit words; a reference is a word
  holding a handle (funcref: function index + 1, null 0; externref: the
  host value; GC objects: handles into a runtime heap the port manages,
  collected by its own mark-sweep from the roots it knows).
- The editor flushes subnormal floats to zero and compares NaN non-IEEE
  (DESIGN 1, PIPELINE 7): scalar float operations already guard with
  isnan; SIMD float lanes go through the same helpers. Assertions that
  depend on subnormal results can pass locally and fail in the editor;
  the editor run of a group records those separately.
- The script heap is 100 MiB in the editor; GC objects and tables live in
  it.
- Hot reload: new function values in tables follow the relink rules
  (ABI.md 7).

## 6. Measurements

`run.py` writes per group: assertions run, passed, failed, skipped (with
the reason), and per test the outcome, so a regression is a diff against
the baseline. `STATE.json` keeps the numbers each commit reached.
