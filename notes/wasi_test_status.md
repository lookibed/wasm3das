# WASI test status of the Daslang port

Date: 2026-09-06. Toolchain: pinned `tmp/daslang-toolchain/bin/daslang`,
Daslang 0.6.4 (`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`).

## What is run

The **original, unmodified** wasm3 WASI driver `wasm3c/test/run-wasi-test.py`,
driving the Daslang port through `app/wasm3.das` (the port of
`wasm3c/platforms/app/main.c`) via the wrapper `scripts/wasm3`:

```sh
python3 -u run-wasi-test.py --exec "/home/andry/wasm3das/scripts/wasm3" --fast --timeout 900
```

The port links the same three host modules C `link_all` links:
`m3_LinkSpecTest` and `m3_LinkLibC` from `source/m3_api_libc.das` and
`m3_LinkWASI` from `source/m3_api_wasi.das`. `repl_call` implements C's
`#if defined(LINK_WASI)` branch for `_start`: the wasm path is stripped into
`argv[0]`, the words after the file become the program's argv through
`m3_wasi_context_t`, and `m3Err_trapExit` leaves the process with
`wasi_ctx->exit_code` (C `exit()`).

### Scratch layout

`run-wasi-test.py` imports `../extra/testutils.py` relative to its own
directory and resolves every fixture as `./wasi/...` and `./self-hosting/...`
relative to its *working* directory, so it only works when the process runs
beside the script. As with the spec tests (`notes/spec_test_status.md`,
"Scratch layout") the run happens in an ignored scratch directory that
symlinks the script, the `extra/` helpers and the two fixture trees, so
nothing is written inside `wasm3c/`:

```sh
mkdir -p tmp/wasi/run
ln -sfn "$PWD/wasm3c/test/run-wasi-test.py" tmp/wasi/run/run-wasi-test.py
ln -sfn "$PWD/wasm3c/extra"                 tmp/wasi/extra
ln -sfn "$PWD/wasm3c/test/wasi"             tmp/wasi/run/wasi
ln -sfn "$PWD/wasm3c/test/self-hosting"     tmp/wasi/run/self-hosting
cd tmp/wasi/run && python3 -u ./run-wasi-test.py \
    --exec "/home/andry/wasm3das/scripts/wasm3" --fast --timeout 900
```

Two operational notes:

- Pass `python3 -u`. The driver prints its `=== name ===` and `FAIL:` lines
  through Python's buffered stdout, so with the output redirected to a file
  none of the verdicts appear until the driver exits; the benchmarks' own
  progress on stderr is unbuffered either way.
- Do not run the driver while `source/` is being edited. A half-written
  module makes the whole daslang program fail to compile, and the driver
  reports that as `Exited with error code 1` for whatever test was running.
  One such transient C-Ray failure was observed and did not reproduce.

The driver compares whole-output SHA-1 digests for the rendering benchmarks
and `fnmatch` patterns for the rest, so any extra byte on **stdout** fails a
test. Diagnostics of `app/wasm3.das` go to stderr, which the driver does not
capture (the one `can_crash` case that would capture it is skipped upstream).

## Result: `--fast` — 7 of 7

```
{'crashed': 0, 'failed': 0, 'timeout': 0, 'total_run': 7}
 All 7 tests OK
```

| # | test | wasm | verdict | self-reported time |
|---|---|---|---|---|
| 1 | Simple WASI test | `wasi/simple/test.wasm cat ./wasi/simple/0.txt` | pass (pattern) | fib(20) in 1.2 s |
| 2 | mandelbrot | `wasi/mandelbrot/mandel.wasm 32 4e5` | pass (sha1 `1fdb7dea…`) | 9.9 s |
| 3 | C-Ray | `wasi/c-ray/c-ray.wasm -s 32x32` < `scene` | pass (sha1 `05af9604…`) | 1.3 s |
| 4 | smallpt | `wasi/smallpt/smallpt-ex.wasm 4 32` | pass (sha1 `ea05d859…`) | 29.5 s |
| 5 | smallpt multi-value | `wasi/smallpt/smallpt-ex-mv.wasm 4 32` | pass (sha1 `ea05d859…`) | 120.5 s |
| 6 | mal | `wasi/mal/mal.wasm ./wasi/mal/test-fib.mal 10` | pass (pattern `55\n`) | — |
| 7 | Brotli | `wasi/brotli/brotli.wasm -c -f` < `alice29_small.txt` | pass (sha1 `0e8af02a…`) **with the fixture restored, see below** | ~65 s |

The times are the benchmarks' own timers (measured through WASI
`clock_time_get`) on a machine also running two other builds; the whole
`--fast` list is a few minutes of wall time.

The "Simple WASI test" output, which exercises argv, the clocks, printf and
`fd_read` of a preopened file:

```
Hello world
Constructor OK
Hello printf!
Args: test.wasm; cat; ./wasi/simple/0.txt;
Now: 1788729917 sec, 1443 ns
6 + 6 = 12
fib(20) = 6765 [1232.459 ms]
48 65 6c 6c 6f 20 77 6f 72 6c 64
=== done ===
```

## The Brotli fixtures lost their CRLF when `wasm3c/` was vendored

Against the fixtures as they are in this checkout, the Brotli case fails for
**the reference C wasm3 too**, with the same digest as the port:

```sh
gcc -O2 -I wasm3c/source -Dd_m3HasWASI wasm3c/source/*.c \
    wasm3c/platforms/app/main.c -lm -o tmp/cwasm3/wasm3
cd tmp/wasi/run
python3 -u ./run-wasi-test.py --exec "$PWD/../../cwasm3/wasm3" --fast
#   FAIL: Actual sha1: 5e0233ae999aa9a10b6fc715f2fcecaca242704b
#   {'crashed': 0, 'failed': 1, 'timeout': 0, 'total_run': 7}
```

| input | C wasm3 | Daslang port | driver expects |
|---|---|---|---|
| `alice29_small.txt` as checked out (11881 B, LF) | `5e0233ae…` | `5e0233ae…` | — |
| the same text with CRLF (12126 B) | `0e8af02a…` | `0e8af02a…` | `0e8af02a…` |

So the port reproduces C wasm3 byte for byte on Brotli quality 11 in both
cases, and the expected digests in `run-wasi-test.py` were generated from
CRLF fixtures. Corroboration: the sibling reference
`wasm3c/test/wasi/brotli/alice29.txt.compressed` has sha1 `8eacda4b…`, which
is exactly the expected digest of the non-`--fast` Brotli case, and it
decompresses to a **152089**-byte CRLF text, while
`wasm3c/test/wasi/brotli/alice29.txt` here is 148481 bytes of LF — the same
text with the CRLFs converted. The blob is already LF in the initial import
commit (`git cat-file -p HEAD:wasm3c/test/wasi/brotli/alice29_small.txt` is
11881 bytes), so the CRLF was lost when the C tree was vendored, not later.

Other diagnostics, all clean, which is why nothing in the WASI layer needs
changing:

- the stream the port produces is valid and complete: feeding it back through
  `brotli.wasm -d -c -f` returns `alice29_small.txt` byte for byte, so
  `fd_read` delivered the whole input and `fd_write` emitted the whole output;
- the bytes are identical whether stdin is a pipe or a regular file, so
  nothing depends on `fd_seek` failing like `lseek` on a pipe, on
  `fd_fdstat_get` flags, or on read chunking;
- the port also decompresses `alice29.txt.compressed` to the full 152089-byte
  text.

**Remedy** — restore the two text fixtures to their upstream CRLF form; no
code changes:

```sh
python3 - <<'EOF'
for n in ('alice29_small.txt', 'alice29.txt'):
    p = 'wasm3c/test/wasi/brotli/' + n
    d = open(p, 'rb').read()
    open(p, 'wb').write(d.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n'))
EOF
```

The 7/7 run in the table above was produced with exactly that content, in a
scratch overlay (`tmp/wasi/run7/`) that symlinks every other fixture and
holds only the two restored `.txt` files.

Applied afterwards: the two fixtures were replaced with the upstream bytes
from `github.com/wasm3/wasm3` (`alice29_small.txt` 12126 bytes, `alice29.txt`
152089 bytes, both CRLF), and `.gitattributes` marks `wasm3c/test/**` as
`-text` so no line-ending conversion can touch fixtures again. With the
tracked tree the `--fast` list passes 7/7 without any overlay.

## Result: full list (no `--fast`) — 12 of 12

The full list runs the same benchmarks at production sizes and adds
`mandel_dd`, STREAM, CoreMark and the self-hosting `wasm3-fib.wasm`. Run on
the tracked tree (restored Brotli fixtures) with `--timeout 36000`, about
80 minutes of wall time in total:

```
{'crashed': 0, 'failed': 0, 'timeout': 0, 'total_run': 12}
 All 12 tests OK
```

| # | test | verdict | self-reported time |
|---|---|---|---|
| 1-2 | Simple WASI test, and the `wasm-opt -O3` build of it | pass (pattern) | — |
| 3 | mandelbrot `128 4e5` | pass (sha1) | 174 s |
| 4 | mandelbrot doubledouble `128 4e5` | pass (sha1) | 952 s |
| 5 | C-Ray `-s 128x128` | pass (sha1) | 17 s |
| 6 | smallpt `16 64` | pass (sha1) | 403 s |
| 7 | smallpt multi-value `16 64` | pass (sha1) | 892 s |
| 8 | mal `test-fib.mal 16` | pass (pattern `987`) | — |
| 9 | STREAM | pass (pattern, "Solution Validates") | — |
| 10 | Self-hosting `wasm3-fib.wasm` (wasm3 interpreting wasm inside this interpreter) | pass (pattern, `Result: 832040`) | — |
| 11 | Brotli `-c -f` < `alice29.txt` | pass (sha1 `8eacda4b…`) | — |
| 12 | CoreMark | pass (pattern, "Correct operation validated") | — |

An earlier attempt on a machine also running two daslang builds took 280 s
and 1426 s for the two mandelbrot variants; the driver's verdicts are only
printed at exit unless Python runs with `-u`.

## Reproducing a single test

```sh
cd tmp/wasi/run
/home/andry/wasm3das/scripts/wasm3 ./wasi/simple/test.wasm cat ./wasi/simple/0.txt
cat ./wasi/c-ray/scene | /home/andry/wasm3das/scripts/wasm3 ./wasi/c-ray/c-ray.wasm -s 32x32 | sha1sum
```

## Notes on the command line

- `wasm3 <file> <args...>` keeps C's behaviour: the function defaults to
  `_start` and every word after the file is the program's argv, with the wasm
  path stripped into `argv[0]`. `app/wasm3.das` still rescans a few option
  words after the file operand (a deviation documented at the site, so this
  repository's `wasm3 fib32.wasm --func fib 25` smoke test works), but only
  the long spellings in `POST_FILE_OPTIONS`; `-s`, `-c`, `-f` and every other
  word reach the wasm program untouched.
- `main.c` in this wasm3 revision does no stdin/stdout mode switching; the
  Windows `_O_BINARY` handling lives in the WASI layer, so there is nothing
  to port in the app.
- The daslang CLI still consumes a handful of its own option words even after
  the `--` separator (`-jit`, `-log`, …). None of the WASI fixtures uses one,
  and `--help`/`-h` are already forwarded as `--wasm3-help` by
  `scripts/wasm3`.
- Linking libc and WASI in `link_all` does not disturb the spec suite:
  `run-spec-test.py` over `i32`, `names`, `start`, `memory` and `exports`
  still reports 374/374 and 536/536.
