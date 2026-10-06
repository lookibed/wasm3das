# The Eden guest ABI pipeline: manual

How new ABI work is done and verified: a new package, a new guest (a
"case": binjgb, PureDOOM, Unity), or a change to the ABI itself. The spec
is `ABI.md`, the long-term plan `PLAN.md`, the ledger `STATE.json`. The
orchestration procedure is the skill `.claude/skills/eden-abi/SKILL.md`,
the agents `abi-porter`, `abi-verifier`, `abi-reviewer` in `.claude/agents/`.

## 1. Prerequisites

Everything of the port pipeline (`docs/eden-port/PIPELINE.md` section 1),
plus:

| Need | Where | Check |
|---|---|---|
| wasi-sdk 24.0 (clang 18.1.2, the reference compiler of the binjgb fixture) | `D:\Backups\WASI\wasi-sdk-24.0` (`WASI_SDK` overrides) | `/mnt/d/Backups/WASI/wasi-sdk-24.0/bin/clang.exe --version` |
| python3 | WSL | `python3 --version` |

## 2. Layout

| Path | What | Written by |
|---|---|---|
| `abi/idl/<package>.json`, `abi/idl/<world>.world.json` | the interface descriptions | hand |
| `scripts/abi/abigen.py` | the generator (`--check` in the gate) | hand |
| `source/abi/gen/` | host bindings: one module per package and world | generator |
| `guests/include/eden/` | guest C headers | generator |
| `docs/eden-abi/REFERENCE.md` | the reference tables | generator |
| `source/abi/abi_runtime.das` | instances, calls, traps, budget, relink | hand |
| `source/abi/abi_game.das` | eden_game helpers: start, frame, snapshot, restore, stop | hand |
| `source/abi/impl/abi_media.das` | pixel / sample conversion shared by every host | hand |
| `source/abi/impl/abi_headless.das` | the engine-free host (tests, golden runs) | hand |
| `eden/abi_eden_host.das` | the Eden host: texture, action set, sound stream | hand |
| `eden/abi_guest_player.das` | the component that plays a guest in the scene | hand |
| `eden/abi_host_check.das` | editor-only checks of the Eden host | hand |
| `guests/common/` | the guest libc (malloc, stdio over eden_core/eden_asset) | hand |
| `guests/<case>/` | a guest's sources (vendored upstream code under `upstream/`) | hand |
| `guests/build/` | built guests + `SHA256SUMS`, committed | `scripts/abi/build_guests.sh` |
| `tests/eden/test_abi*.das`, `tests/eden/abi_golden.das` | tests (run in the local runner and the editor) | hand |

Everything under `source/` and `tests/eden/` is engine-free and compiles
with the local compilers under the sandbox model; `eden/` needs the engine
and is compiled only by the editor.

## 3. The gate

```
scripts/abi/gate.sh            # every stage; exit 0 = green
scripts/abi/gate.sh --local    # without the editor
```

| Stage | Proves |
|---|---|
| idl | generated files are exactly what the IDL produces |
| guests | committed `.wasm` files are what their sources build to |
| compile | every Eden-visible file passes the sandbox rules |
| test | the whole suite, ABI included, passes locally |
| golden (local) | binjgb: 16 frames equal the wasmtime baselines, whole, sliced into 2 ms steps, and across a snapshot restored into a new instance |
| host | the project's `main.das` and assets are the repository's |
| eden | the editor compiles the project and its suite passes with the local count |
| golden (editor) | the same golden checks inside the editor |
| engine | the Eden host: first-frame digest, `Bitmap` pixel packing, the three pixel formats, the audio stream |
| input | keys held with the MCP input tool reach `eden_input` (`pad=257 key30=1`) |
| reload | a script reload while a guest plays: the player relinks and keeps presenting frames |

## 4. Adding a package

1. Write `abi/idl/<package>.json` (see an existing one; every function and
   constant has a `doc`). Add it to the `imports` of the worlds that offer it.
2. `python3 scripts/abi/abigen.py`.
3. Implement it: a headless implementation in `abi_headless.das` (so the
   tests and golden runs cover it without the engine) and an Eden one in
   `abi_eden_host.das`. Both must behave identically on every input the
   ABI allows; shared logic goes to `abi_media.das` or a new engine-free
   module.
4. Tests: extend the self-test guest (`guests/abi_selftest/selftest.c`)
   so it calls every new function with valid and invalid arguments, and
   `tests/eden/test_abi.das` so the host side checks what arrived; add an
   engine check in `eden/abi_host_check.das` when the Eden implementation
   does something the headless one does not.
5. `scripts/abi/build_guests.sh`, then `scripts/abi/gate.sh`.

## 5. Adding a case (a guest program)

1. `guests/<case>/`: vendored upstream sources under `upstream/` with their
   license, the ABI glue in `<case>.c` (the world's exports), a `README.md`
   with sources, versions and licenses. Add the build to
   `scripts/abi/build_guests.sh`.
2. A golden reference that does not come from this pipeline: outputs of the
   same program run natively or under wasmtime (frame digests, audio,
   return values), written down with where they came from.
3. `tests/eden/test_abi_<case>.das` for fast checks in the suite, golden
   checks in `abi_golden.das` style for the slow ones.
4. A row in `STATE.json` and the checks in `scripts/abi/gate.sh` when the
   case adds a new kind of check.

## 6. Autonomous run

```
/goal scripts/abi/goal_check.sh <case> exits 0 (run it from modules/wasm3das); follow the eden-abi skill
```

The skill picks the case's open items from `STATE.json`, runs the
porter / verifier / reviewer agents per item and commits each item when
`scripts/abi/gate.sh` is green.

## 7. Measured editor facts the ABI depends on

| Fact | Consequence |
|---|---|
| after a script reload every carried function value whose type mentions `M3Runtime` is **null** (all `g_ops`, both hooks, every `rt.rawCalls`, the package implementation tables); a `function<() : bool>` survives | `abi_is_stale` checks those nulls; hosts relink in place (`abi_relink_begin` → link again → `abi_relink_end`), which rebuilds the op tables and replaces the raw-call slots, so the guest keeps its memory and state |
| the editor's file watcher sometimes misses a save; a new file forces a rescan | the gate creates a probe file to trigger a reload |
| denormal floats are **flushed to zero** (a subnormal `1e-310` computes as 0): in 0.9 only in `on_update`, since EdenSpark 1.0 in every script context, cheats included; the script cannot change the mode | guests get flush-to-zero float semantics, a deviation from wasm that integer guests (binjgb, DOOM's fixed point) never see; the port's `strtod` builds decimal subnormals from integers when the host flushes them (`decimal_subnormal_bits`), so its results stay glibc's; the gate prints `abi_denormal_probe` every run |
| a deprecated engine call fails an exported build (the editor only warns); `engine.input.global_input_state` is deprecated as a whole | the Eden host reads all input through action sets; `docs/eden-port/BUILDS.md` |
| the script heap is collected only between engine frames; `delete` frees at once, but temporaries of the port (the parser: about 340 KB per 20 KB module) stay until the frame ends | the editor runs the test suite one module per cheat call (`wasm3_tests` / `wasm3_tests_next`, driven by `eden_gate.sh`); a player step is bounded by its budget, so its temporaries are collected every frame |
| `keys()` of a `GenericStorage` does not compile (engine 0.9.0.34, generic_storage.das:69) | the Eden storage keeps the blob names in an explicit `names` entry |
| `Bitmap.pixels` are `0xAARRGGBB` | the Eden host packs RGBA8 frames that way; `abi_host_check` pins it |
| `delete` of a class pointer needs `unsafe` | host implementations are structs of function values, per-instance state is keyed by instance id |
| `each_enum` is deprecated (hard error in a published build) | `daslib/enum_trait` `each` is used |
