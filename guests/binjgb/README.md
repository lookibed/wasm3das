# binjgb as an eden_game guest

A Game Boy / Game Boy Color emulator running in Eden through the guest ABI
(`docs/eden-abi`).

| File | What | Origin | License |
|---|---|---|---|
| `upstream/common.*`, `emulator.*`, `joypad.*`, `builtin-palettes.def`, `LICENSE` | the emulator core | [binji/binjgb](https://github.com/binji/binjgb), (C) 2016-2017 Ben Smith, as vendored by the Spider project (`tests/manual/real-world-binjgb/upstream/src`) | MIT (`upstream/LICENSE`) |
| `upstream/memory.h` | binjgb's allocation wrappers, without its memory-tracking branch (the Spider copy omits the file) | binjgb `src/memory.h` | MIT |
| `eden_binjgb.c` | the eden_game exports: ROM from `eden_asset`, pad from `eden_input`, frames to `eden_video`, audio to `eden_audio`, battery RAM in `eden_storage`, snapshots | this repository | the repository's |
| `roms/cgb-acid2.gbc` | the CGB PPU test ROM of the golden checks | [mattcurrie/cgb-acid2](https://github.com/mattcurrie/cgb-acid2) | MIT |
| `roms/battery_test.gb` | a 32 KB MBC1+RAM+BATTERY ROM that writes two bytes of cartridge RAM | `scripts/abi/make_battery_rom.py` | the repository's |

Build: `scripts/abi/build_guests.sh binjgb` (wasi-sdk 24.0 clang, the
compiler of the reference fixture) writes `guests/build/binjgb.wasm`.

Golden references: the wasmtime results of the Spider fixture's probes,
listed in `tests/eden/abi_golden.das`, which the guest reproduces frame for
frame through the whole ABI.

Commercial ROMs are not part of the repository. To play one, list it in
`fixtures.local.txt` at the repository root (git-ignored), one line per
file:

```
local/roms/tetris.gb = /mnt/d/roms/Tetris (World) (Rev 1).gb
```

run `scripts/eden/install_host.sh` (it copies the file into the project
assets), restart the game, and type in the editor console
`abi_play abi/build/binjgb.wasm local/roms/tetris.gb`.
