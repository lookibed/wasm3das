# wasm3das

[Wasm3](https://github.com/wasm3/wasm3), the WebAssembly interpreter, ported
by hand from C to [Daslang](https://github.com/GaijinEntertainment/daScript).
The port keeps Wasm3's file layout, names and control flow; the C reference
it follows is vendored in `wasm3c/`.

It comes in two forms:

- **Native**: the port compiled ahead of time by daslang's LLVM backend
  into one executable, for Linux x86_64 and Windows x64.
- **EdenSpark**: the same interpreter written for the EdenSpark editor's
  script sandbox (no `unsafe`, no pointers), with a guest ABI that lets a
  WebAssembly program draw, play sound and read input inside an Eden scene.
  It lives on the [`eden`](https://github.com/lookibed/wasm3das/tree/eden)
  branch.

## Status

- WebAssembly core spec suite, driven by Wasm3's own `run-spec-test.py`:
  17863 / 17863 on the native binaries (Linux and Windows).
- Wasm3's WASI suite: 12 / 12 (mandelbrot, C-Ray, smallpt, mal, STREAM,
  Brotli, CoreMark, the self-hosted wasm3, ...).
- The EdenSpark version passes exactly the same 29480 commands of the
  official WebAssembly 3.0 test suite as the C Wasm3 0.5.2.
- What Wasm3 supports, wasm3das supports: WebAssembly 1.0 with mutable
  globals, sign extension, saturating truncation, multi-value, part of bulk
  memory, WASI `preview1`. Not SIMD, reference types, exceptions, GC or
  threads - Wasm3 has none of them either.

## Download

[Releases](https://github.com/lookibed/wasm3das/releases):

| asset | what |
|---|---|
| `wasm3das-<ver>-linux-x86_64.tar.gz` | `wasm3`, one binary, needs only glibc |
| `wasm3das-<ver>-windows-x64.zip` | `wasm3.exe` and the three Visual C++ runtime DLLs it uses |
| `wasm3das-<ver>-edenspark.zip` | the EdenSpark sources, to drop into a project's `modules/` |

## Usage

The command line is Wasm3's:

```sh
wasm3 fib32.wasm --func fib 25             # call an export: Result: 75025
wasm3 mal.wasm ./test-fib.mal 10           # run a WASI program (_start)
wasm3 --repl                               # :load, :invoke, :exit
```

WASI file access goes through the working directory, preopened as `.`.

## EdenSpark

Unpack `wasm3das-<ver>-edenspark.zip` into `<project>/modules/wasm3das`
(or clone the `eden` branch there) and run
`modules/wasm3das/scripts/eden/install_host.sh` from WSL, or copy
`.eden_host/main.das` to the project root by hand. The design, the sandbox
rules and the guest ABI are documented in `docs/eden-port/` and
`docs/eden-abi/` of that branch.

## Building

The native binary needs a daslang checkout built with dasLLVM
(`DAS_LLVM_DISABLED=OFF`); `scripts/daslang_pin` names the commit the port
is verified against.

```sh
export DASLANG_ROOT=/path/to/daScript
scripts/build_port.sh exe            # tmp/native-exe/bin/wasm3das.exe
scripts/wasm3 fib32.wasm --func fib 25   # or run the sources interpreted
```

`docs/native-build.md` covers the other tiers (interpreter, standalone
context, AOT) and their measurements; `docs/test-suites.md` the suites;
`docs/development-pipeline.md` and `AGENTS.md` how changes are made.

## License

MIT (`LICENSE`). The vendored Wasm3 sources in `wasm3c/` keep their MIT
license (`wasm3c/LICENSE`); the test modules in `tests/manual/` carry the
licenses listed in `tests/manual/ATTRIBUTION.md`.
