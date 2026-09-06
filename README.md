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
- Links host functions into a module (`m3_LinkRawFunction`) and provides the
  `spectest` host module.
- Command line front end with the same commands and output as the C `wasm3`
  binary: `--func`, `--repl`, `--stack-size`.

## What it does not do

- No WASI: modules that import `wasi_snapshot_preview1` do not run. The
  Wasm3 WASI apps (CoreMark, Brotli, the self-hosted `wasm3.wasm`) are out of
  scope.
- No libc host module (`m3_LinkLibC`).
- No imported memories, imported tables or host globals, the same as Wasm3.
- Speed: this is an interpreter running inside the Daslang interpreter,
  roughly two orders of magnitude slower than the C build.
- Deep recursion needs a large stack. The wrapper raises the thread stack
  limit and the app reserves a 64 MiB Daslang stack so a runaway recursion
  reports `[trap] stack overflow` instead of crashing.

## Usage

Run an exported function:

```sh
$ scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 25
Result: 75025
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
pinned Daslang interpreter, the port and the example modules. Unpack it and
run:

```sh
tar -xzf wasm3das-v0.1.0-linux-x86_64.tar.gz
wasm3das/wasm3 wasm3das/examples/fib32.wasm --func fib 25
```

```bat
wasm3das\wasm3.cmd wasm3das\examples\fib32.wasm --func fib 25
```

### From source

Requirements: Linux or macOS, `bash`, `git`, `cmake`, a C++17 compiler, and
Python 3 for the spec-test driver.

1. Clone the repository:

   ```sh
   git clone https://github.com/lookibed/wasm3das.git
   cd wasm3das
   ```

2. Build the pinned Daslang toolchain (version 0.6.4, commit
   `1524b3bf62e7decbfe530dc5f2e794b296fa1e68`) into `tmp/daslang-toolchain`:

   ```sh
   git clone https://github.com/GaijinEntertainment/daScript.git tmp/daslang-toolchain
   git -C tmp/daslang-toolchain checkout 1524b3bf62e7decbfe530dc5f2e794b296fa1e68
   git -C tmp/daslang-toolchain submodule update --init --recursive
   cmake -S tmp/daslang-toolchain -B tmp/daslang-toolchain/build -DCMAKE_BUILD_TYPE=Release
   cmake --build tmp/daslang-toolchain/build --target daslang --parallel
   ```

   An existing Daslang build of that commit works too: point `DASLANG` at
   its `bin/daslang`.

3. Run:

   ```sh
   scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 25
   ```

The port is plain Daslang source; there is nothing to build in this
repository. Development rules, the verification gate and the review process
are in `docs/development-pipeline.md` and `AGENTS.md`.
