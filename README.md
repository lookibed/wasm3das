# wasm3das

A port of the [Wasm3](https://github.com/wasm3/wasm3) WebAssembly interpreter
from C to [Daslang](https://github.com/GaijinEntertainment/daScript), done by
hand, file by file. The port keeps Wasm3's source layout, names and control
flow, so the two trees can be read side by side; the reference C sources are
vendored in `wasm3c/`.

The goal is a WebAssembly interpreter written in Daslang that behaves exactly
like Wasm3 and is verified with Wasm3's own test suite.

## What it does

- Parses, loads, compiles and executes WebAssembly 1.0 core modules,
  including the sign-extension, non-trapping float-to-int and tail-call
  (`return_call`) instructions Wasm3 supports.
- Passes the WebAssembly core spec suite driven by Wasm3's unmodified
  `run-spec-test.py`: 17863 / 17863 assertions on the current corpus
  (`opam-1.1.1`) and 17526 / 17526 on the previous one (`v1.1`), with no
  crashes. Per-file numbers are in `notes/spec_test_status.md`.
- Runs every module in `wasm3c/test/lang`.
- Runs WASI programs (`wasi_snapshot_preview1` and `wasi_unstable`, the
  same function set as Wasm3): Wasm3's own `run-wasi-test.py` passes its
  whole list, 12 of 12 (a C test suite, mandelbrot, C-Ray, two smallpt
  builds, the mal Lisp interpreter, STREAM, Brotli, CoreMark and the
  self-hosted `wasm3-fib.wasm`) with byte-exact output.
- Links host functions into a module (`m3_LinkRawFunction`) and provides the
  `spectest` and libc (`env.*`) host modules.
- Command line front end with the same commands and output as the C `wasm3`
  binary: `--func`, `--repl`, `--stack-size`.

## What it does not do

- WASI covers what Wasm3 covers: no `fd_readdir`, `fd_filestat_get`,
  `poll_oneoff`, sockets or `environ` contents. File access goes through the
  preopened directory `.` (the working directory), as in Wasm3.
- No imported memories, imported tables or host globals, the same as Wasm3.
- Speed: run through `scripts/wasm3` the port is interpreted by Daslang and
  is tens of times slower than the C build; the native AOT build
  (`scripts/build_port.sh`, below) closes most of that gap. Numbers for
  every engine are in `notes/benchmark_2026-09-07.md`.
- Every run compiles the Daslang sources first (about 2 s), in both the
  interpreted and the native build.
- Deep recursion needs a large stack. The wrapper raises the thread stack
  limit and the app reserves a 64 MiB Daslang stack so a runaway recursion
  reports `[trap] stack overflow` instead of crashing.

## Usage

Run an exported function:

```sh
$ scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 25
Result: 75025
```

Run a WASI program (the exported `_start` is the default function; the words
after the file are its arguments, and paths are resolved through the
preopened `.` directory, so they start with `./`):

```sh
$ scripts/wasm3 wasm3c/test/wasi/mal/mal.wasm ./wasm3c/test/wasi/mal/test-fib.mal 10
55
$ scripts/wasm3 wasm3c/test/wasi/mandelbrot/mandel.wasm 32 4e5 > mandel.ppm
```

Embed the interpreter in your own Daslang program: `tests/host_test/` holds
the Daslang counterparts of the C host programs in `wasm3c/host_test`
(`smoke`, `min`, `min2`, `main`), which drive a module through the public
API (`m3_ParseModule`, `m3_LoadModule`, `m3_FindFunction`, `m3_CallV`,
`m3_GetResultsV`, `m3_GetMemory`):

```sh
$ tmp/daslang/bin/daslang tests/host_test/smoke.das
$ tmp/daslang/bin/daslang tests/host_test/main.das -- tests/manual/real-world-h264bsd-mp4/generated/h264mp4.wasm clip.mp4 outdir 12
```

Interactive session, the same protocol the spec-test driver speaks:

```sh
$ scripts/wasm3 --repl
wasm3> :load wasm3c/test/lang/fib64.wasm
wasm3> :invoke fib 30
Result: 832040:i64
wasm3> :exit
```

Run the original Wasm3 spec suite against the port (the driver downloads the
corpus into its working directory on first use):

```sh
$ mkdir -p tmp/spec/run && cd tmp/spec/run
$ ln -sfn ../../../wasm3c/test/run-spec-test.py .
$ ln -sfn ../../../wasm3c/extra ../extra
$ python3 run-spec-test.py --exec "$PWD/../../../scripts/wasm3 --repl"
...
 17863/17863 tests OK
```

## Install and run

### Release bundle

Each [release](https://github.com/lookibed/wasm3das/releases) ships a
self-contained bundle for Linux x86_64, Linux arm64 and Windows x64: the
Daslang interpreter of the pinned daslang release, the port and the example
modules. Unpack it and run:

```sh
tar -xzf wasm3das-v0.1.0-linux-x86_64.tar.gz
wasm3das/wasm3 wasm3das/examples/fib32.wasm --func fib 25
```

```bat
wasm3das\wasm3.cmd wasm3das\examples\fib32.wasm --func fib 25
```

### From the repository

Requirements: a C++17 toolchain (gcc or clang), `cmake`, `git` and Python 3
for the spec-test driver. daslang is an external project: this repository
neither downloads nor ships a compiler.

1. Clone the repository:

   ```sh
   git clone https://github.com/lookibed/wasm3das.git
   cd wasm3das
   ```

2. Clone, check out and build the daslang the port is pinned against
   (the commit in `scripts/daslang_pin`):

   ```sh
   git clone https://github.com/GaijinEntertainment/daScript.git
   git -C daScript checkout "$(sed -n 's/^\\([0-9a-f]\\{40\\}\\)$/\\1/p' scripts/daslang_pin | head -n 1)"
   scripts/build-daslang.sh daScript
   ```

   The build is Release with the headless module set (no LLVM/GUI/media),
   the exact set every gate and launcher expects. The result lives inside
   the checkout itself: `daScript/bin/daslang`, `daScript/lib/`,
   `daScript/include/`, `daScript/daslib/`.

3. Point the repository at your daslang and run:

   ```sh
   export DASLANG_ROOT="$(pwd)/daScript"
   scripts/verify_daslang.sh          # the pin and the built layout are checked
   scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 25
   ```

   Every script, the gate, CI and the editor tooling read `DASLANG_ROOT`;
   `scripts/gate.sh` refuses to run against any other daslang (set
   `DASLANG_ALLOW_UNPINNED=1` for a local experiment off the pin).

The port is plain Daslang source; nothing needs building for the interpreted
run above. Note: because daslang is built locally, the resulting binary runs
on the local libc — no bundles of someone else's build, no `GLIBC` version
mismatch, no chroot gymnastics.

### Native build

`scripts/build_port.sh` compiles the port ahead of time: daslang's AOT
turns every module into C++, which is linked with the static `libDaScript`
of your DASLANG_ROOT checkout and the host in `native/` into
`tmp/native/bin/wasm3das`. It needs clang++ or g++. `scripts/wasm3-native`
is the drop-in counterpart of `scripts/wasm3`:

```sh
scripts/build_port.sh
scripts/wasm3-native wasm3c/test/lang/fib32.wasm --func fib 35
```

### Standalone-context build (zero startup)

`scripts/build_port.sh ctx` goes one layer further: daslang's `-ctx` emitter
bakes the compiled program into one C++ translation unit
(`tmp/native-ctx/ctx/`), linked with the host stub `native/standalone_main.cpp`
into a binary that runs with no daslang front end at startup
(`scripts/wasm3-ctx` is its launcher):

```sh
scripts/build_port.sh ctx
scripts/wasm3-ctx wasm3c/test/lang/fib32.wasm --func fib 35   # ~50 ms total
```

The measured column in `tests/manual/fixture_report.md` is
`wasm3das(aot_ctx)`. Development rules, the verification gate and the review
process are in `docs/development-pipeline.md` and `AGENTS.md`.
