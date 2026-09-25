# wasm3das on EdenSpark: result

The goal condition `scripts/eden/goal_check.sh` exits 0 on branch `eden`
(2026-09-25): every module of `STATE.json` is done, the tree is clean, and
`scripts/eden/gate.sh` is green with all its stages.

| Check | Result |
|---|---|
| Modules ported | 22 / 22 (`docs/eden-port/STATE.json`) |
| Upstream tests covered | 119 upstream `[test]` functions, every one with an Eden counterpart, none dropped |
| Eden test suite, local (Daslang 0.6.3 and 0.6.4 under the sandbox model) | `WASM3 TESTS pass=15647 fail=0` |
| Eden test suite, in the editor (cheat `wasm3_tests`) | `WASM3 TESTS pass=15647 fail=0`, about 7.5 s |
| WebAssembly core spec suite, unmodified `run-spec-test.py`, opam-1.1.1 | 17863 / 17863, 0 fail, 0 crash, 235 skipped (as C wasm3) |
| WASI suite, unmodified `run-wasi-test.py --fast` | 7 / 7, every output sha1 matching (simple, mandelbrot, c-ray, smallpt, smallpt multi-value, mal, brotli), 98 s |
| Size | 21220 lines of `source/`, 17203 lines of `tests/eden/` |

The spec and WASI suites run locally through `.local/app` (the REPL the
drivers need, with real stdio and a WASI file backend over `fio`). The
same modules run in the editor, where the fixtures come from the
project's assets and WASI works over in-memory stdio.

## Using it in the editor

Open the project from the launcher; the host installed by
`scripts/eden/install_host.sh` provides these console cheats:

- `wasm3_tests` / `wasm3_tests_verbose` — the whole Eden suite, summary on screen and in the console
- `wasm3_run <fixture> <function> <args...>` — e.g. `wasm3_run lang/fib32.wasm fib 25` → `WASM3 RUN Result: 75025`
- `wasm3_run_start <fixture> <args...>` — a WASI program's `_start`, its stdout/stderr printed, then its exit code
- `wasm3_fixture_check <fixture>` — proves a fixture asset is installed

A new `.wasm` is added by listing it in `docs/eden-port/fixtures.txt` and
running `scripts/eden/install_host.sh` (it becomes `assets/wasm/<name>.data`).

## Limits that remain (all in DESIGN §1)

- No `unsafe` in the sandbox: memory, stack and code are arrays and
  handles; the interpreter is slower than the pointer port.
- Linear memory is capped at 2 GB (`length()` of a daslang array is an int).
- Float NaN comparisons in the editor's build are not IEEE; every
  comparison the port makes is guarded with `isnan`.
- WASI in the editor has no files (stdin/stdout/stderr buffers only);
  `.local/app` has real files.
- Hot reload keeps global variables but not function values: the op
  table is rebuilt by every `m3_NewRuntime`, and a runtime created before
  a reload is not used after it.
- `random_get` is not a cryptographic generator; clocks come from the
  engine's time (REALTIME epoch to the second, MONOTONIC uptime-like).

## How it was verified

Each module went through the pipeline of `docs/eden-port/PIPELINE.md`:
porter, then verifier (all gates including the live editor, test
adequacy, fuzzing against a C build where the module parses input), then
a C-fidelity reviewer. Differences from C found by verification and
review were fixed before a module was marked done; each module's commit
lists them.
