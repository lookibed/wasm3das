# Running Wasm3's own test suites against the port

Both suites are the **original, unmodified** drivers from `wasm3c/test/`,
driving the port through `app/wasm3.das` (the port of
`platforms/app/main.c`) via `scripts/wasm3`; `scripts/wasm3-native` and
`scripts/wasm3-ctx` are drop-in replacements. This document replaces the
working notes `spec_test_status.md` and `wasi_test_status.md`.

The gate (`scripts/gate.sh`) runs the component tests under
`tests/integration/`; the two drivers below are the end-to-end proof and are
run by hand before a runtime change lands (`docs/development-pipeline.md`).
The manual fixture corpus and its harness live in `tests/manual/`
(`run_fixtures.py`, `fixture_report.md`, `ATTRIBUTION.md`).

## Spec suite: 17863 / 17863

Corpus: `wasm-core-testsuite` tag `opam-1.1.1`, the archive the driver
downloads itself (73 `core/*.json` plus the `sign-extension-ops` and
`nontrapping-float-to-int-conversions` proposals). `run-spec-test.py`
resolves the corpus (`./.spec-<spec>/`) and `--file` arguments relative to its
own directory, so it runs from an ignored scratch directory that symlinks the
script, the `extra/` helpers and the corpus; nothing is written inside
`wasm3c/`:

```sh
mkdir -p tmp/spec/run
ln -sfn "$PWD/wasm3c/test/run-spec-test.py" tmp/spec/run/run-spec-test.py
ln -sfn "$PWD/wasm3c/extra"                 tmp/spec/extra
cd tmp/spec/run
python3 ./run-spec-test.py --exec "$PWD/../../../scripts/wasm3 --repl" --timeout 120
python3 ./run-spec-test.py --exec "$PWD/../../../scripts/wasm3 --repl" --timeout 120 .spec-opam-1.1.1/core/i32.json
```

Result on the default list: **17863 / 17863 pass, 0 failures, 0 crashes,
0 timeouts**, 235 skipped by the driver itself (its blacklist plus the
`invoke in module` and non-`invoke` actions it does not implement). The
previous corpus, `--spec=v1.1`: **17526 / 17526**, 235 skipped. The same
numbers hold on the aot and ctx tiers. A whole run takes a few minutes; each
REPL start costs 2-3 s of CPU on the interpreter tier (the program is compiled
from source per process).

Per file (`run` is the driver's `total_run`; files with `run = 0` contain only
`assert_malformed` / `assert_invalid` / `assert_uninstantiable`, which the
driver ignores):

| file | run | file | run | file | run |
|---|---:|---|---:|---|---:|
| address | 255 | float_misc | 440 | memory_size | 36 |
| align | 48 | forward | 4 | memory_trap | 171 |
| block | 52 | func | 93 | names | 480 (2 skip) |
| br | 76 | func_ptrs | 26 | nop | 83 |
| br_if | 88 | global | 46 | return | 63 |
| br_table | 146 | i32 | 374 | select | 94 |
| call | 72 | i64 | 384 | skip-stack-guard-page | 10 |
| call_indirect | 122 | if | 123 | stack | 5 |
| const | 300 | imports | 0 (88 skip) | start | 10 |
| conversions | 589 | int_exprs | 89 | store | 9 |
| data | 0 (14 skip) | int_literals | 30 | switch | 26 |
| elem | 4 (22 skip) | labels | 25 | traps | 32 |
| endianness | 68 | left-to-right | 95 | unreachable | 63 |
| exports | 1 (5 skip) | linking | 0 (100 skip) | unwind | 49 |
| f32 | 2500 | load | 37 | sign-extension-ops/i32 | 373 |
| f32_bitwise | 360 | local_get | 19 | sign-extension-ops/i64 | 383 |
| f32_cmp | 2400 | local_set | 19 | nontrapping-float-to-int/conversions | 589 |
| f64 | 2500 | local_tee | 55 | binary, binary-leb128, comments, custom, inline-module, table, token, type, unreached-invalid, utf8-* | 0 |
| f64_bitwise | 360 | loop | 77 | | |
| f64_cmp | 2400 | memory | 45 | | |
| fac | 7 | memory_grow | 84 | | |
| float_exprs | 800 (4 skip) | memory_redundancy | 7 | | |
| float_literals | 83 | float_memory | 84 | | |

Every `pass` equals `run`; every `fail` and `crash` is 0.

### `--all` (the upstream blacklist disabled)

Adds the 35 assertions wasm3 blacklists for every engine. Result before the
spectest module was linked: 17870 / 17898, 28 failures, 0 crashes, all
accounted for: 23 in `imports.wast` (host globals/memories/tables are not
linked; wasm3 has none), 2 `float_exprs.wast:2337-2338`
`f32.nonarithmetic_nan_bitpattern` (blacklisted for every engine), 2
`names.wast:615,637` (exports whose name starts with `\x00`), 1 `names.wast:1107
print32` (closed by linking `m3_LinkSpecTest`). The `\x00` names cannot pass
without changing the transport: `unescape_argv` turns the escape into a byte
0, a Daslang `string` is NUL-terminated, the name truncates to `""` and
`m3_FindFunction` reports `function lookup failed ('')`; reaching them would
need an `array<u8>`-carrying variant of `m3_FindFunction`.

### Recursion must trap, not kill the process

The `assert_exhaustion` cases (`call.wast` `runaway`/`mutual-runaway`, the
same pair in `call_indirect.wast`) expect `[trap] stack overflow` from
`op_Entry`. With the defaults the interpreter's own stack died first: a 4 MiB
Daslang context stack gives `EXCEPTION: stack overflow while calling
@m3_exec::op_Call` (`<Crashed>`), an 8 MiB thread stack `CRASH: SIGSEGV`.
Fixed on the tool side: `app/wasm3.das` `options stack = 67_108_864` (counts
only in the program root) and `scripts/wasm3` `ulimit -s 262144`; the
standalone binary reserves its 256 MiB thread stack itself. Both limits scale
with `--stack-size`. Background in `docs/execution-design.md`.

### The daslang CLI swallows `--help`

The daslang driver consumes `--help` and `-h` anywhere in `argv`, including
after `--`. `scripts/wasm3` forwards them as `--wasm3-help`, which
`app/wasm3.das` accepts as a spelling of main.c's `--help`. A handful of other
daslang option words (`-jit`, `-log`, ...) are consumed the same way; no
fixture uses one.

## WASI suite: 12 / 12

The port links the same three host modules C `link_all` links:
`m3_LinkSpecTest` and `m3_LinkLibC` (`source/m3_api_libc.das`) and
`m3_LinkWASI` (`source/m3_api_wasi.das`). `repl_call` implements C's
`#if defined(LINK_WASI)` branch for `_start`: the wasm path is stripped into
`argv[0]`, the words after the file become the program's argv through
`m3_wasi_context_t`, and `m3Err_trapExit` leaves the process with
`wasi_ctx->exit_code`.

`run-wasi-test.py` imports `../extra/testutils.py` relative to its own
directory and resolves fixtures as `./wasi/...` and `./self-hosting/...`
relative to its working directory:

```sh
mkdir -p tmp/wasi/run
ln -sfn "$PWD/wasm3c/test/run-wasi-test.py" tmp/wasi/run/run-wasi-test.py
ln -sfn "$PWD/wasm3c/extra"                 tmp/wasi/extra
ln -sfn "$PWD/wasm3c/test/wasi"             tmp/wasi/run/wasi
ln -sfn "$PWD/wasm3c/test/self-hosting"     tmp/wasi/run/self-hosting
cd tmp/wasi/run
python3 -u ./run-wasi-test.py --exec "$PWD/../../../scripts/wasm3" --fast --timeout 900
python3 -u ./run-wasi-test.py --exec "$PWD/../../../scripts/wasm3" --timeout 36000
```

Operational notes: pass `python3 -u`, or the `=== name ===` and `FAIL:` lines
sit in Python's buffer until exit; do not run the driver while `source/` is
being edited (a half-written module fails the whole program and the driver
reports `Exited with error code 1` for whatever test was running). The driver
compares whole-output SHA-1 digests for the rendering benchmarks and `fnmatch`
patterns for the rest, so any extra byte on **stdout** fails a test;
diagnostics of `app/wasm3.das` go to stderr, and `Result:` too (in both
modes, as in C `main.c`), so any capture of the output must merge the streams.

`--fast`, 7 of 7:

| # | test | wasm | verdict |
|---|---|---|---|
| 1 | Simple WASI test | `wasi/simple/test.wasm cat ./wasi/simple/0.txt` | pattern |
| 2 | mandelbrot | `wasi/mandelbrot/mandel.wasm 32 4e5` | sha1 `1fdb7dea…` |
| 3 | C-Ray | `wasi/c-ray/c-ray.wasm -s 32x32` < `scene` | sha1 `05af9604…` |
| 4 | smallpt | `wasi/smallpt/smallpt-ex.wasm 4 32` | sha1 `ea05d859…` |
| 5 | smallpt multi-value | `wasi/smallpt/smallpt-ex-mv.wasm 4 32` | sha1 `ea05d859…` |
| 6 | mal | `wasi/mal/mal.wasm ./wasi/mal/test-fib.mal 10` | pattern `55` |
| 7 | Brotli | `wasi/brotli/brotli.wasm -c -f` < `alice29_small.txt` | sha1 `0e8af02a…` |

Full list, 12 of 12, about 80 minutes on the interpreter tier: the two
`simple` builds, mandelbrot `128 4e5` (174 s self-reported), mandelbrot
doubledouble (952 s), C-Ray `128x128` (17 s), smallpt `16 64` (403 s), smallpt
multi-value (892 s), mal `test-fib.mal 16` (`987`), STREAM ("Solution
Validates"), the self-hosting `wasm3-fib.wasm` (wasm3 interpreting wasm inside
this interpreter, `Result: 832040`), Brotli on the full `alice29.txt` (sha1
`8eacda4b…`), CoreMark ("Correct operation validated").

### The Brotli fixtures and CRLF

Against the fixtures as first vendored, Brotli failed for the reference C wasm3
too, with the same digest as the port: the expected digests were generated
from CRLF text (`alice29_small.txt` 12126 B, `alice29.txt` 152089 B) and the
vendored copies were LF (11881 B, 148481 B); the sibling
`alice29.txt.compressed` decompresses to the CRLF text and has exactly the
expected digest of the non-`--fast` case. The port reproduced C byte for byte
in both forms, the produced stream round-trips through `brotli.wasm -d`, and
the bytes are identical whether stdin is a pipe or a file, so nothing in the
WASI layer needed changing. Remedy applied: the two fixtures were replaced
with the upstream bytes and `.gitattributes` marks `wasm3c/test/**` as
`-text` so no line-ending conversion touches fixtures again.

### Command line

`wasm3 <file> <args...>` keeps C's behaviour: the function defaults to
`_start`, every word after the file is the program's argv with the wasm path
in `argv[0]`. `app/wasm3.das` still rescans the long spellings in
`POST_FILE_OPTIONS` after the file operand (documented at the site, so this
repository's `wasm3 fib32.wasm --func fib 25` works); `-s`, `-c`, `-f` and
every other word reach the wasm program untouched. `main.c` in this wasm3
revision does no stdin/stdout mode switching; the Windows `_O_BINARY` handling
lives in the WASI layer.

## Reproducing one case

```sh
scripts/wasm3 --version
scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 25     # Result: 75025
printf ':load wasm3c/test/lang/fib32.wasm\n:invoke fib 10\n:exit\n' | scripts/wasm3 --repl
cd tmp/wasi/run
$PWD/../../../scripts/wasm3 ./wasi/simple/test.wasm cat ./wasi/simple/0.txt
cat ./wasi/c-ray/scene | $PWD/../../../scripts/wasm3 ./wasi/c-ray/c-ray.wasm -s 32x32 | sha1sum
```
