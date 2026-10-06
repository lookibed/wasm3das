# WebAssembly feature coverage: plan

Goal: wasm3das runs whatever WebAssembly the C wasm3 runs, the way the C
wasm3 runs it, and delivers that inside EdenSpark through the guest ABI
(docs/eden-abi). The reference is the C wasm3 the port follows (wasm3c/,
v0.5.2), not the WebAssembly specification at large: what the C wasm3
cannot do is out of scope, what it can do the port must do too. The
optional optimisations (`edenFuseOps`) stay optional; the default path
executes what the C wasm3 executes.

The ledger is `STATE.json` next to this file.

## 1. The measurement

- The corpus is the official `WebAssembly/testsuite` at a pinned commit
  (`STATE.json` `corpus`), converted with `wasm-tools json-from-wast`, kept
  outside the Eden project (`WASM3DAS_CORPUS`, default
  `/root/.cache/wasm3das`; the editor imports every text file of its
  tree). `scripts/features/corpus.sh` fetches and converts it;
  `groups.json` assigns every file to a feature group, an unclaimed file
  fails the pipeline.
- `scripts/features/run.py` plays every command through a front end's
  REPL - the port's (`scripts/eden/wasm3`) by default, the C wasm3 with
  `--exec` - one process per file, the whole corpus in about half a minute
  on 8 jobs. Outcomes: pass, fail, unsupported (with the reason), skip
  (text-format modules: both front ends read binaries only).
- **The target: `reference.json`**, every command the C wasm3 passes
  (`run.py --exec <C wasm3> --reference`; the C build is
  `/root/wasm3das/tmp/wasm3c-build/wasm3`, Release, uvwasi, from the same
  wasm3c sources). `run.py --parity` lists the commands the C wasm3 passes
  and the port does not: the parity gap, which must be 0.
- **No regressions: `passing.json`**, every command the port passes;
  `run.py --check` fails when one stops passing. A command may leave it
  only to match the C wasm3, recorded in `STATE.json` `parity_changes`.
- The opam-1.1.1 corpus of `scripts/eden/spec.sh` and the WASI suite stay
  the gates they are.

## 2. Phases

| Phase | Work | Status |
|---|---|---|
| P0 | the pipeline (corpus, groups, run.py with --check / --update / --exec / --reference / --parity), the baselines | done |
| F1 | parity with the C wasm3 on the corpus: gap 0 | 2026-10-07: gap 20 -> 0 (f64 floor/ceil/trunc/nearest of a signalling NaN return it quieted as glibc does; an element segment that leaves table0 empty fails the load as C's _throwifnull does) |
| F2 | the commands the port passes and the C wasm3 does not: each one either a C behaviour to match or a documented intended difference | open: 5 assert_invalid of br_table / local_tee the port rejects and the C wasm3 accepts |
| E1 | the same in the editor: the parity set run inside EdenSpark through the guest ABI's host, with the editor's float environment (flush-to-zero, non-IEEE NaN compares, docs/eden-abi PIPELINE 7); every difference to the local run measured and either fixed in the port or recorded with its cause | next |
| E2 | the ABI side of arbitrary modules: a guest that imports what the C wasm3's front end links (spectest, libc, WASI) runs through eden_game hosts, and an eden_game guest built from any of the corpus' passing programs behaves as under the C wasm3 | after E1 |

## 3. Gate of a change

1. `run.py --parity` gap 0 and `run.py --check` 0 regressions (or the
   intended ones in `STATE.json` `parity_changes`), then `--update`;
2. `scripts/eden/compile.sh`, `test.sh`, `spec.sh` (opam 17863),
   `wasi.sh` (12/12), the DOOM digests of `.local/run_dgv.das`, and the
   editor compiles the project;
3. tests in `tests/eden/` for changed behaviour, so the editor's suite
   covers it too.

## 4. Out of scope (the C wasm3 does not do it)

Beyond what `reference.json` records: SIMD, relaxed SIMD, reference types
beyond table0, multiple tables, tail calls, exception handling, multi-memory
past what the C build accepts, memory64, function references, GC, threads,
wide arithmetic, and a full validator. The corpus keeps measuring them
(STATE.json `groups`), so the numbers show where the C wasm3 and the port
stand together if the reference moves (a newer wasm3).
