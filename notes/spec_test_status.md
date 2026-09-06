# WebAssembly spec-test status of the Daslang port

Date: 2026-09-06. Toolchain: pinned `tmp/daslang-toolchain/bin/daslang`,
Daslang 0.6.4 (`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`).

## What was run

The **original, unmodified** wasm3 spec-test driver
`wasm3c/test/run-spec-test.py`, driving the Daslang port through the REPL of
`app/wasm3.das` (the port of `wasm3c/platforms/app/main.c`) via the wrapper
`scripts/wasm3`:

```sh
python3 run-spec-test.py --exec "/home/andry/wasm3das/scripts/wasm3 --repl" --timeout 120 <file.json>
```

Test corpus: `wasm-core-testsuite` tag `opam-1.1.1`, the same archive the
driver downloads itself, unpacked at
`tmp/spec/wasm-core-testsuite-opam-1.1.1` (73 `core/*.json` plus the
`sign-extension-ops` and `nontrapping-float-to-int-conversions` proposals,
which are part of the driver's default list).

### Scratch layout

`run-spec-test.py` resolves both the corpus (`./.spec-<spec>/`) and its
`--file` arguments relative to *its own* directory, so it only works when the
process runs beside the script. To keep the tracked `wasm3c/` tree clean, the
run happens in an ignored scratch directory that symlinks the script, the
`extra/` helpers it imports and the corpus:

```sh
mkdir -p tmp/spec/run
ln -sfn "$PWD/wasm3c/test/run-spec-test.py" tmp/spec/run/run-spec-test.py
ln -sfn "$PWD/wasm3c/extra"                 tmp/spec/extra
ln -sfn "$PWD/tmp/spec/wasm-core-testsuite-opam-1.1.1" tmp/spec/run/.spec-opam-1.1.1
cd tmp/spec/run && python3 ./run-spec-test.py --exec "$PWD/../../../scripts/wasm3 --repl" \
    --timeout 120 .spec-opam-1.1.1/core/i32.json
```

Nothing is written inside `wasm3c/`; the driver's `spec-test.log` and the
per-file logs stay in `tmp/spec/run/`.

## Result

**17863 / 17863 assertions pass, 0 failures, 0 crashes, 0 timeouts**
(235 skipped by the driver itself: its own blacklist plus the
`invoke in module` and non-`invoke` action types it does not implement).

The first full run had one failure (`names.wast:1107`, missing
`spectest.print_i32`); it disappeared once `link_all` was wired to
`m3_LinkSpecTest` from `source/m3_api_libc.das`. The table below is that
first run; the `names` row now reads 480 / 480 / 0.

### Per file

`run` is the driver's `total_run`; `skip` its `skipped`. Files with `run = 0`
contain only `assert_malformed` / `assert_invalid` / `assert_uninstantiable`
commands, which the driver deliberately ignores.

| file | run | pass | fail | crash | skip |
|---|---|---|---|---|---|
| address | 255 | 255 | 0 | 0 | 0 |
| align | 48 | 48 | 0 | 0 | 0 |
| binary | 0 | 0 | 0 | 0 | 0 |
| binary-leb128 | 0 | 0 | 0 | 0 | 0 |
| block | 52 | 52 | 0 | 0 | 0 |
| br | 76 | 76 | 0 | 0 | 0 |
| br_if | 88 | 88 | 0 | 0 | 0 |
| br_table | 146 | 146 | 0 | 0 | 0 |
| call | 72 | 72 | 0 | 0 | 0 |
| call_indirect | 122 | 122 | 0 | 0 | 0 |
| comments | 0 | 0 | 0 | 0 | 0 |
| const | 300 | 300 | 0 | 0 | 0 |
| conversions | 589 | 589 | 0 | 0 | 0 |
| custom | 0 | 0 | 0 | 0 | 0 |
| data | 0 | 0 | 0 | 0 | 14 |
| elem | 4 | 4 | 0 | 0 | 22 |
| endianness | 68 | 68 | 0 | 0 | 0 |
| exports | 1 | 1 | 0 | 0 | 5 |
| f32 | 2500 | 2500 | 0 | 0 | 0 |
| f32_bitwise | 360 | 360 | 0 | 0 | 0 |
| f32_cmp | 2400 | 2400 | 0 | 0 | 0 |
| f64 | 2500 | 2500 | 0 | 0 | 0 |
| f64_bitwise | 360 | 360 | 0 | 0 | 0 |
| f64_cmp | 2400 | 2400 | 0 | 0 | 0 |
| fac | 7 | 7 | 0 | 0 | 0 |
| float_exprs | 800 | 800 | 0 | 0 | 4 |
| float_literals | 83 | 83 | 0 | 0 | 0 |
| float_memory | 84 | 84 | 0 | 0 | 0 |
| float_misc | 440 | 440 | 0 | 0 | 0 |
| forward | 4 | 4 | 0 | 0 | 0 |
| func | 93 | 93 | 0 | 0 | 0 |
| func_ptrs | 26 | 26 | 0 | 0 | 0 |
| global | 46 | 46 | 0 | 0 | 0 |
| i32 | 374 | 374 | 0 | 0 | 0 |
| i64 | 384 | 384 | 0 | 0 | 0 |
| if | 123 | 123 | 0 | 0 | 0 |
| imports | 0 | 0 | 0 | 0 | 88 |
| inline-module | 0 | 0 | 0 | 0 | 0 |
| int_exprs | 89 | 89 | 0 | 0 | 0 |
| int_literals | 30 | 30 | 0 | 0 | 0 |
| labels | 25 | 25 | 0 | 0 | 0 |
| left-to-right | 95 | 95 | 0 | 0 | 0 |
| linking | 0 | 0 | 0 | 0 | 100 |
| load | 37 | 37 | 0 | 0 | 0 |
| local_get | 19 | 19 | 0 | 0 | 0 |
| local_set | 19 | 19 | 0 | 0 | 0 |
| local_tee | 55 | 55 | 0 | 0 | 0 |
| loop | 77 | 77 | 0 | 0 | 0 |
| memory | 45 | 45 | 0 | 0 | 0 |
| memory_grow | 84 | 84 | 0 | 0 | 0 |
| memory_redundancy | 7 | 7 | 0 | 0 | 0 |
| memory_size | 36 | 36 | 0 | 0 | 0 |
| memory_trap | 171 | 171 | 0 | 0 | 0 |
| names | 480 | 480 | 0 | 0 | 2 |
| nop | 83 | 83 | 0 | 0 | 0 |
| return | 63 | 63 | 0 | 0 | 0 |
| select | 94 | 94 | 0 | 0 | 0 |
| skip-stack-guard-page | 10 | 10 | 0 | 0 | 0 |
| stack | 5 | 5 | 0 | 0 | 0 |
| start | 10 | 10 | 0 | 0 | 0 |
| store | 9 | 9 | 0 | 0 | 0 |
| switch | 26 | 26 | 0 | 0 | 0 |
| table | 0 | 0 | 0 | 0 | 0 |
| token | 0 | 0 | 0 | 0 | 0 |
| traps | 32 | 32 | 0 | 0 | 0 |
| type | 0 | 0 | 0 | 0 | 0 |
| unreachable | 63 | 63 | 0 | 0 | 0 |
| unreached-invalid | 0 | 0 | 0 | 0 | 0 |
| unwind | 49 | 49 | 0 | 0 | 0 |
| utf8-custom-section-id | 0 | 0 | 0 | 0 | 0 |
| utf8-import-field | 0 | 0 | 0 | 0 | 0 |
| utf8-import-module | 0 | 0 | 0 | 0 | 0 |
| utf8-invalid-encoding | 0 | 0 | 0 | 0 | 0 |
| proposals/sign-extension-ops/i32 | 373 | 373 | 0 | 0 | 0 |
| proposals/sign-extension-ops/i64 | 383 | 383 | 0 | 0 | 0 |
| proposals/nontrapping-float-to-int-conversions/conversions | 589 | 589 | 0 | 0 | 0 |
| **total** | **17863** | **17863** | **0** | **0** | **235** |

### The one failure of the first run (closed)

```
Test:     names.wast:1107 names.3.wasm print32(42, 123)
Expected: result <Empty Stack>
Actual:   error missing imported function ('spectest.print_i32')
```

C `link_all` binds `m3_LinkSpecTest`, `m3_LinkLibC` and `m3_LinkWASI`.
`app/wasm3.das` now calls `m3_LinkSpecTest` (the spectest half of
`m3_api_libc.c`, ported in `source/m3_api_libc.das`); libc and WASI stay
out of scope. The 88 skipped `imports.wast` and 100 skipped `linking.wast`
assertions are skipped by the driver itself (upstream blacklist and the
`register`/`invoke in module` actions it does not implement).

## Previous spec corpus (`--spec=v1.1`)

The second spec step of Wasm3's CI, `run-spec-test.py --spec=v1.1`, was run
the same way after `m3_LinkSpecTest` was wired: **17526 / 17526 assertions
pass, 0 failures, 0 crashes, 0 timeouts, 235 skipped**.

## With `--all` (upstream blacklist disabled)

`run-spec-test.py --all` also runs the 35 assertions wasm3 blacklists for
every engine. Result before `m3_LinkSpecTest` was wired: **17870 / 17898,
28 failures, 0 crashes**. All 28 are accounted for:

| count | assertions | cause |
|---|---|---|
| 23 | `imports.wast` (`print32`, `get-0`, `load`, `grow`, `call`) | host globals/memories/tables are not linked (wasm3 has none); blacklisted upstream as `imports.wast:*` |
| 2 | `float_exprs.wast:2337-2338 f32.nonarithmetic_nan_bitpattern` | blacklisted upstream for every engine (NaN bit pattern) |
| 2 | `names.wast:615,637` — exports whose name starts with `\x00` | blacklisted upstream as `names.wast:* *.wasm \x00*`; also a hard limit here, see below |
| 1 | `names.wast:1107 print32` | closed: `spectest` is now linked |

The `\x00` name cases cannot be made to pass without changing the transport:
the driver escapes such a name to `\x00...`, `unescape_argv` turns it back
into a byte with value 0, and a Daslang `string` is NUL-terminated, so the
name is truncated to `""` and `m3_FindFunction` reports
`function lookup failed ('')`. Reaching them would need an
`array<u8>`-carrying variant of `m3_FindFunction`.

## Known gaps and how they were closed

### Unbounded recursion must trap, not kill the process

The port has no equivalent of C `M3_MUSTTAIL`: every `op_*` calls the next
operation instead of tail-jumping, so one wasm frame costs several Daslang
frames *and* several native C++ frames. The `assert_exhaustion` cases
(`call.wast` `runaway`/`mutual-runaway`, the same pair in
`call_indirect.wast`) expect `[trap] stack overflow`, which `op_Entry`
(`source/m3_exec.das`, C `m3_exec.h`: `_sp + maxStackSlots < _mem->maxStack`)
raises when the *wasm* stack fills. With the defaults the interpreter's own
stack died first:

- Daslang context stack too small (`options stack = 4 MiB`) →
  `EXCEPTION: stack overflow while calling @m3_exec::op_Call`, process dies,
  the driver reports `<Crashed>`;
- native thread stack too small (8 MiB default `ulimit -s`) →
  `CRASH: SIGSEGV (signal 11)`.

Both are fixed on the tool side, without touching `source/`:

- `app/wasm3.das`: `options stack = 67_108_864` (64 MiB Daslang context
  stack; `options stack` counts only in the program root);
- `scripts/wasm3`: `ulimit -s 262144` (256 MiB thread stack) before `exec`.

With those, all four cases report `Error: [trap] stack overflow (...)` and
`call.json` / `call_indirect.json` are fully green. Both limits scale with
`--stack-size`: a much larger wasm stack can still exhaust them first. The
real fix remains the trampoline/tail-call architecture noted in `AGENTS.md`.

### daslang CLI swallows `--help`

The daslang driver consumes `--help` and `-h` anywhere in `argv`, including
after the `--` separator, and prints its own usage instead of running the
script. `scripts/wasm3` forwards them as `--wasm3-help`, which
`app/wasm3.das` accepts as a spelling of main.c's `--help`.

## Reproducing

```sh
# smoke
scripts/wasm3 --version
scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib 25     # Result: 75025
scripts/wasm3 wasm3c/test/lang/fib64.wasm --func fib 25     # Result: 75025
printf ':load wasm3c/test/lang/fib32.wasm\n:invoke fib 10\n:exit\n' | scripts/wasm3 --repl
#   wasm3> wasm3> Result: 55:i32

# whole default suite, from the scratch directory described above
cd tmp/spec/run
python3 ./run-spec-test.py --exec "$PWD/../../../scripts/wasm3 --repl" --timeout 120
```

A single run of the whole default list takes a few minutes; each REPL start
costs roughly 2-3 s of CPU because the daslang program is compiled from
source on every process start.
