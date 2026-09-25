# The Eden guest ABI, version 1

The contract between a WebAssembly guest and an EdenSpark host running it
through wasm3das. Both directions: the guest calls **imports** the host
provides (video, audio, input, assets, time, log), the host calls **exports**
the guest provides (init, step, state). The plan and the order of cases is
`PLAN.md`; this file is the normative spec. Everything here is generated
from, or checked against, the interface descriptions in `abi/idl/`.

## 1. Pieces

| Piece | Where | Written by |
|---|---|---|
| Interface descriptions (IDL) | `abi/idl/<package>.json`, `abi/idl/<world>.world.json` | hand |
| Generator | `scripts/abi/abigen.py` | hand |
| Host bindings (daslang) | `source/abi/gen/abi_<package>.das`, `source/abi/gen/abi_<world>.das` | generator |
| Guest header (C) | `guests/include/eden/<package>.h`, `guests/include/eden/<world>.h` | generator |
| Runtime core | `source/abi/abi_runtime.das`: instances, marshalling, traps, budget | hand |
| Host implementations | `eden/abi_eden_*.das` (editor, engine APIs); test doubles in `tests/eden/abi_doubles.das` | hand |
| Guests | `guests/<name>/`, built by `scripts/abi/build_guests.sh` into `guests/build/` | hand |

`scripts/abi/abigen.py --check` fails when a generated file differs from
what the IDL produces, so the bindings can never drift from the IDL.

## 2. Packages and worlds

A **package** is a named, versioned group of host functions and constants;
its name is the wasm import module (`eden_video`), a function's name the
import field (`present`). A **world** is what one kind of guest links
against: the list of packages it may import and the exports it must or may
provide. v1 has one world, `eden_game`:

| Package | Functions |
|---|---|
| `eden_core` | `log(level, message)`, `time_us()`, `abort(message)` |
| `eden_asset` | `size(name)`, `read(name, offset, dst)` |
| `eden_video` | `present(pixels, width, height, stride, format)`, `set_palette(colors)` |
| `eden_input` | `buttons(pad)`, `key_down(scancode)`, `mouse_buttons()`, `mouse_delta(axis)` |
| `eden_audio` | `open(rate, channels)`, `push(stream, samples, format)`, `queued(stream)`, `close(stream)` |
| `eden_storage` | `size(name)`, `read(name, offset, dst)`, `write(name, data)`, `remove(name)`: persistent blobs in a namespace the host gives each guest |

| Export of `eden_game` | Required | Meaning |
|---|---|---|
| `eden_abi_version() -> i32` | yes | must return the world version (1); the host refuses others |
| `eden_alloc(size) -> ptr`, `eden_free(ptr)` | yes | the guest's allocator; the host places `str`/`bytes` arguments with it |
| `eden_init() -> i32` | yes | 0 = ready, anything else = the guest's error code |
| `eden_step(budget_us) -> i32` | yes | do work for about `budget_us` microseconds of host time; flags below |
| `eden_shutdown()` | yes | release everything; the instance is destroyed after it |
| `eden_state_size() -> i32`, `eden_state_save(dst, cap) -> i32`, `eden_state_load(src, len) -> i32` | no | snapshot for hot reload and save games |

`eden_step` flags: bit 0 `STEP_FRAME` (a frame was presented during this
step), bit 1 `STEP_QUIT` (the guest wants to stop), bit 2 `STEP_ERROR` (the
guest failed; it logged why through `eden_core.log`).

A guest may import any subset of a world's packages. It may **not** import
anything else: instantiation fails with the list of every unresolved import
(`module.field`), never with a stub that traps later.

## 3. Types

| IDL | wasm | C (guest) | host implementation receives | Export argument |
|---|---|---|---|---|
| `i32`, `i64`, `f32`, `f64` | same | `int32_t` … `double` | `int`, `int64`, `float`, `double` | same |
| `bool` | i32 | `int32_t` (0/1) | `bool` (any non-zero is true) | `bool` |
| `handle` | i32 | `int32_t` | `int`; > 0 valid, ≤ 0 invalid | `int` |
| `str` | i32 ptr, i32 len | `const char *, int32_t` | `string` (UTF-8, copied; a NUL byte traps) | `string` |
| `bytes` | i32 ptr, i32 len | `const void *, int32_t` | `AbiBytes` view, bounds already checked | `array<uint8>` |
| `outbuf` | i32 ptr, i32 cap | `void *, int32_t` | `AbiBytes` view the implementation writes, bounds checked | — |

Results are `void` or one scalar (`i32`, `i64`, `f32`, `f64`, `bool`,
`handle`). For every `str` parameter the header also emits a convenience
`static inline` taking a NUL-terminated `const char *`.

## 4. Memory

- Linear memory belongs to the guest. The host never keeps a guest pointer
  (`AbiBytes`) past the import call that received it.
- Host → guest data goes through `eden_alloc`: an export wrapper with a
  `str`/`bytes` argument allocates, copies, calls, then `eden_free`s.
- Guest → host bulk data (framebuffer, audio) is a `bytes` argument read in
  place during the import call. Guest-owned results the host reads later are
  returned as `(ptr, len)` and read with `abi_read_bytes`.
- Budget: the editor caps the whole script heap at 100 MiB, linear memory
  included. `abi_instantiate` refuses a module whose initial memory exceeds
  `AbiConfig.maxMemoryBytes` before allocating it, with a message that names
  both numbers.

## 5. Errors

- An import implementation that must fail the guest calls
  `abi_trap(message)` and returns; the generated wrapper then aborts the
  guest with `[trap] <package>.<function>: <message>`. Recoverable failures
  are negative return codes (`ERR_*` constants of the package).
- Bounds violations of `str`/`bytes`/`outbuf` trap in the wrapper before the
  implementation runs.
- A trap inside an export call leaves the instance **faulted**: the result
  and the backtrace-free message are in `inst.error`, further calls return
  immediately with the same error. The host destroys and re-creates it.

## 6. Calls, re-entrancy, time

- Calls are synchronous on the script thread. **No re-entry:** while a guest
  export runs, calling another export of the same instance fails with
  `reentrant call` (the wasm3 stack is shared). Host → guest events that
  arise inside an import (for example "a key was pressed") are queued by the
  host and delivered by the next export call; a guest that needs callbacks
  exports a pump function that the host calls between steps.
- `eden_step(budget_us)` is the only long-running call. The guest checks
  `eden_core.time_us()` between work units and returns when the budget is
  spent or a frame is complete; the host picks the budget so the editor
  stays interactive. Simulation results must not depend on the budget: a
  guest samples input and presents at frame boundaries only.
- A step ends at the latest right after it presented a frame (at most one
  `STEP_FRAME` per call). The host therefore sets the input of frame N+1
  between the step that presented frame N and the next one.
- Floating point: a guest stepped from the engine's update (the scene
  player) runs with denormals flushed to zero, an engine setting scripts
  cannot change (measured, PIPELINE.md 7). Guests whose results depend on
  subnormal floats see different values there than under a strict wasm
  engine; integer and fixed-point guests are unaffected.

## 7. Lifecycle

```
abi_instantiate(bytes, name, config)      parse, memory budget check, load
abi_link_<package>(inst, impl) ...         every package the host offers
abi_bind_<world>(inst)                      unresolved imports, required exports, version
<world>_init / _step ... / _shutdown       typed export wrappers
abi_destroy(inst)                          unlinks every package, frees the runtime
```

Hot reload of host scripts nulls every stored function value that mentions
the runtime (the wasm3 op tables and hooks, the raw calls, the package
implementations), while the instance's data survives. The host relinks in
place, keeping the guest's memory and state:

```
if (abi_is_stale(inst)) {
    abi_relink_begin(inst)        rebuild the op tables, drop the old unlinkers
    <link the same packages again, with the same implementations>
    abi_relink_end(inst)          fails (and faults) if a package was left out
}
```

Relinking replaces each import's slot in `rt.rawCalls`, so the compiled
code is kept. Snapshots (`eden_state_save` / `eden_state_load`) are for
save states and for moving a guest to a new instance, not for reloads.

## 9. Files for C guests

`guests/common/eden_libc.c` is the C runtime every guest links: a free-list
`malloc` over `memory.grow`, `printf` into `eden_core.log`, and files as
named blobs. Reads look in `eden_storage` first, then in `eden_asset`;
writes become `eden_storage` blobs on `fclose`; `remove` deletes one;
`exit`, `abort` and a failed `assert` go to `eden_core.abort`. It also
defines the `eden_alloc` and `eden_free` exports.

## 8. Versioning

A package version changes when a function's signature or meaning changes;
adding a function or constant does not. The world version is the number
`eden_abi_version` returns; a host supports exactly the world versions it
has bindings for.
