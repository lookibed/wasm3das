# Two-way wasm ⇄ Eden ABI: plan

## Status (2026-09-26)

- Phase 1 (ABI core and pipeline) and phase 2 (binjgb) are done:
  `ABI.md` is the spec, `PIPELINE.md` the manual, `STATE.json` the ledger,
  `scripts/abi/gate.sh` the gate. binjgb plays in the scene with video,
  pad, audio and battery saves; its frames equal the wasmtime baselines
  through the whole ABI.
- The owner's decisions: speed is not a goal for binjgb now (section 6,
  decision 1; the Tier C translator of phase 3 waits); the IDL is JSON
  (decision 3). Decision 2 (Unity's output format) is still open and gates
  phase 5.
- Added beyond the first plan, because every later case needs them:
  `eden_storage` (persistent blobs; DOOM saves, cartridge RAM), the guest
  libc (`guests/common`), in-place relinking after a hot reload.
- Measured on the way (PIPELINE.md 7): denormals are flushed in
  `on_update`; the heap is collected only between frames.

The rest of this file is the plan as proposed on 2026-09-25.

Status then: proposal, 2026-09-25. Cases in order: **binjgb** (Game Boy / Color
emulator) → **PureDOOM** → **Unity**. binjgb is the first case, not the
yardstick: every decision below is checked against all three.

binjgb comes from `/root/Spider/tests/manual/real-world-binjgb`: sources
(`src/module.c` host API, `src/shim.c` libc, `upstream/src`), the ROM
`fixtures/cgb-acid2.gbc`, and `host_main.lua`, a working Lua host of the
same host API. The benchmark copy in wasm3das is byte-identical
(sha256 3fccd3a0…). `host_main.lua` is the reference host: the Eden host
must reproduce its frame output, and its `--all-frames 16` run gives the
golden hashes.

## 1. What each case demands

| Need | binjgb | PureDOOM | Unity (WebGL/emscripten output) |
|---|---|---|---|
| Guest language / toolchain | C, freestanding (`clang --target=wasm32`, own libc shim) | C, needs libc (malloc, stdio, math, string) → wasi-sdk | C#/IL2CPP → emscripten: C++ runtime + hundreds of JS imports |
| Host → guest calls | init, run_frame, set_buttons, load_rom | init, tick, key events | main loop callback, input events |
| Guest → host calls | none today (no imports) | file I/O, time, (optionally) video/audio push | GL/WebGL (~300 calls), WebAudio, DOM input, fetch, time, threads |
| Video | 160×144 RGBA framebuffer in guest memory, pull per frame | 320×200 8-bit + palette, pull per frame | GPU command stream (GL) — not a framebuffer |
| Audio | APU sample buffer (stereo PCM), pull per frame | SFX PCM + MUS/MIDI music | WebAudio graph |
| Input | 8 buttons | keyboard (+mouse) | keyboard, mouse, gamepad, touch |
| Data files | ROM (32 KB – 8 MB), save RAM | WAD (4 – 12 MB) | data bundles (10s–100s MB) |
| Memory | 64 MB declared (fits the 100 MB editor heap after the reserve fix) | ~8–32 MB | usually 256 MB+ → **over the editor's 100 MB heap cap** |
| Real-time budget | 16.7 ms/frame (59.7 Hz) | 28.6 ms/tic (35 Hz) | 16.7 ms/frame |

## 2. The constraint that decides the architecture: speed

Measured, 16-frame `binjgb_decode_hash` probe divided by 16, process start
included (upstream `tests/manual/fixture_report.md`,
docs/eden-port/BENCH_EDITOR.md, Spider `docs/notes/lua-no-ffi-measurements.md`):

| Executor | binjgb ms/frame | vs 16.7 ms |
|---|---:|---:|
| C wasm3 | ~12 | ok |
| Spider wasm → Lua (`lua-no-ffi`), warm in-process, 2026-09-21 | ~37 | ~2× too slow |
| upstream wasm3das, standalone ctx / exe | 19–30 | ~1.2–1.8× too slow |
| upstream wasm3das, interpreter | ~700 | ~42× too slow |
| Eden port, in the editor | ~1250 | ~75× too slow |

The Spider row is the evidence that translation beats interpretation on
this exact guest (Spider went from 2219 ms to 598 ms for 16 frames after its
packed-word memory change, so memory layout matters as much as the
translation). Lua is not daslang, so Tier C still needs its own measurement.

No ABI design makes an interpreter 75× faster. The ABI must therefore be
**independent of the executor**, and the plan carries a second executor:

- **Tier I — wasm3das interpreter (exists).** Any wasm, loaded at run time,
  full compatibility; for tools, tests, slow-paced content.
- **Tier C — wasm → daslang translation, ahead of time.** A translator
  (the approach of the user's Spider project, wasm → Lua) emits daslang
  source per module: functions become daslang functions, locals become
  locals, the operand stack disappears, memory accesses become the
  `load_*`/`store_*` accessors over `array<uint8>`. No dispatch loop, no
  slot traffic. The emitted code must obey the same sandbox (no unsafe),
  so its speed is bounded by daslang itself — the Phase 0 spike measures
  how close it gets.
- **Tier A — Eden's own AOT of scripts in standalone builds**, if the
  engine AOT-compiles user scripts there (`eden-aot-windows-x86_64.exe`
  ships with the engine). Tier C code would benefit directly. To measure.

Both tiers expose the same module interface (instantiate, call export,
memory, imports), so bindings, tests and hosts never know which tier runs.

## 3. ABI layers

1. **Runtime** (exists): wasm3das API — parse/load/link/call, raw host
   functions, memory accessors, WASI with pluggable file backend.
2. **Binding layer (to build).** One interface description per guest
   (a small IDL, JSON or a WIT-like text) → a generator that emits:
   - the daslang host module: typed wrappers for exports
     (`binjgb.run_frame(inst, i)`), typed import implementations linked
     by name, argument/result marshalling;
   - the guest C header: `__attribute__((import_module(...)))`
     declarations of imports, export prototypes.
   Types v1: i32/i64/f32/f64, bool, string (ptr,len UTF-8), bytes
   (ptr,len), handle<T> (host object table), callback (table index),
   out-buffer (guest-owned region the host fills). v2: structs with a
   fixed byte layout shared by both sides.
3. **Memory ownership rules.** Guest memory is guest-owned; the host never
   keeps a guest pointer across calls. Host → guest data goes through a
   guest-exported allocator (`abi_alloc`/`abi_free`, generated). Pulled
   buffers (framebuffer, audio) are read in place during the host call
   that returns their (ptr,len).
4. **Engine services** (host modules, each an ABI package): `eden.video`
   (framebuffer → Bitmap → texture, palette conversion), `eden.input`
   (Eden action sets → guest button/key state), `eden.audio`
   (guest PCM → Eden audio; API to be found, see §6), `eden.fs`
   (read-only files over project assets as a WASI backend, so C code
   that fopen()s a WAD works unchanged), `eden.time`.
5. **Frame contract.** Guest exports `init`, `frame(dt)` (or the
   emulator's own `run_frame`); the host component calls them from
   `on_update`, owns timing (fixed-step accumulator, frame skip) and
   reports overruns.
6. **Lifecycle rules**: re-entrancy (host import calling back into the
   guest) tested; traps become results, never editor crashes; hot reload
   re-instantiates and relinks by name (function values die on reload,
   DESIGN §1 of the port); instance state that must survive a reload is
   saved through the guest's own save-state export.

## 4. Phases and exit criteria

| Phase | Content | Exit criterion |
|---|---|---|
| 0. Spikes | (a) speed of a Tier C translation of one hot binjgb function; (b) standalone build: does Eden AOT user scripts, how fast is the interpreter there; (c) audio: can a script push PCM to Eden audio; (d) re-entrancy test | numbers in docs/eden-abi/SPIKES.md, go/no-go for Tier C |
| 1. ABI core + pipeline | IDL, generator (host das + guest C), ownership rules, gates of §5, ledger | a generated round-trip test guest passes every gate in the editor |
| 2. binjgb | guest built from source (Spider fixture + upstream binjgb) with a generated header; `eden.video` + `eden.input` (+ `eden.audio` if Phase 0c allows); an Eden scene playing cgb-acid2 and a real ROM | golden frame hashes equal C wasm3 for N frames; playable at whatever speed the tier gives, with the measured ms/frame on screen |
| 3. Tier C (if go) | translator wasm → daslang, same ABI | binjgb frame hashes identical under Tier I and Tier C; ms/frame measured |
| 4. PureDOOM | wasi-sdk build, `eden.fs` over assets (WAD), palette video, key input, audio | demo playback (timedemo) hash equal to C; playable |
| 5. Unity | research first: which Unity output (WebGL = emscripten + JS glue + GL) and whether a GL-command → Eden rendering bridge and the 100 MB heap cap make it feasible | written feasibility report with a go/no-go; no code before it |

## 5. Pipeline (built in Phase 1, same shape as docs/eden-port)

- **Ledger** `docs/eden-abi/STATE.json`: packages and cases with status.
- **Reproducible guest builds**: pinned toolchains (LLVM 22 on Windows,
  wasi-sdk 24 at D:\Backups\WASI), a build script per guest, the built
  `.wasm` checked into fixtures with its sha256.
- **Golden references**: every guest case has outputs produced by C wasm3
  (and wasmtime where it runs): frame hashes, audio hashes, return values.
- **Gates**: generator output compiles under the sandbox model and in the
  editor; binding round-trip tests; golden comparisons locally (Tier I and
  Tier C) and in the editor (cheats, as `wasm3_bench`); perf gate records
  ms/frame per case and tier and flags regressions; hot-reload gate
  (reload during play, instance relinks, state survives).
- **Agents**: `abi-porter` (implements a package or case against the IDL),
  `abi-verifier` (gates + golden + adequacy), `abi-reviewer` (ownership,
  lifetimes, re-entrancy, sandbox limits), `perf-auditor` (profiles a case
  in the editor, proposes and measures optimizations, never merges
  unmeasured changes).

## 6. Open facts to measure (Phase 0) and decisions for the owner

To measure: script AOT in standalone builds; PCM streaming API reachable
from the sandbox (engine `audio` / strudel modules); cost of one host ⇄
guest call; Tier C speed.

Decisions:
1. Target speed for binjgb in the editor: real time required (then Tier C
   is mandatory and Phase 3 moves before Phase 2's polish), or correct but
   slow is acceptable for the first milestone.
2. Unity: which output format is meant (WebGL/emscripten build, or IL2CPP
   sources rebuilt for WASI), and whether the 100 MB editor heap cap is
   acceptable to hit (standalone builds may not have it — to measure).
3. IDL form: JSON (simplest to generate from) or a WIT-like text (nicer to
   write by hand).
