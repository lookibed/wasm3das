options gen2
options indenting = 4

module test_abi_binjgb shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/abi_golden
require modules/wasm3das/source/abi/abi_game
require modules/wasm3das/source/abi/impl/abi_headless
require strings

/*
    test_abi_binjgb.das: the binjgb guest in the regular suite, one frame per
    variant (the 16-frame golden runs are abi_golden.run_abi_golden).
*/


def test_abi_binjgb_first_frame(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_binjgb_first_frame")
    let wasm <- load_fixture(fx, BINJGB_WASM)
    let rom <- load_fixture(fx, ACID2_ROM)
    check(t, length(wasm) > 0 && length(rom) > 0, "fixtures present")
    let whole <- golden_binjgb(wasm, rom, 1, 1000000000)
    equal_str(t, whole.error, "", "one frame ran")
    check(t, length(whole.digests) == 1 && whole.digests[0] == GOLDEN_FIRST, "first frame = binjgb_probe_first_frame_hash ({whole.digests})")
    equal(t, whole.steps, 1, "one step with an unlimited budget")
    check(t, whole.rate == 44100 && whole.channels == 2, "audio stream 44100 Hz stereo")
    // a full frame is 70224 ticks of the 4194304 Hz clock, 738.4 audio frames
    // at 44100 Hz; the first frame after the post-boot state is shorter
    check(t, whole.audioFrames >= 600l && whole.audioFrames <= 740l, "at most one frame of audio ({whole.audioFrames} frames)")
    let sliced <- golden_binjgb(wasm, rom, 1, 1)
    equal_str(t, sliced.error, "", "one frame in the smallest slices")
    check(t, length(sliced.digests) == 1 && sliced.digests[0] == GOLDEN_FIRST, "the same frame")
    check(t, sliced.steps >= 8, "split across the slices of 1/16 frame ({sliced.steps} steps)")
    equal(t, sliced.audioFrames, whole.audioFrames, "the same audio")
}


def test_abi_binjgb_missing_rom(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_binjgb_missing_rom")
    let wasm <- load_fixture(fx, BINJGB_WASM)
    var none : array<uint8>
    let run <- golden_binjgb(wasm, none, 1, 1000000000)
    check(t, find(run.error, "eden_init returned 1") >= 0, "an empty ROM is refused by the guest ({run.error})")
}


// runs the battery test ROM for `frames` frames in namespace `ns`, then
// eden_shutdown; returns the guest's log
def private run_battery_rom(wasm : array<uint8>; rom : array<uint8>; ns : string; frames : int; var t : TestRun) : array<string> {
    var logs : array<string>
    var inst <- abi_instantiate(wasm, "binjgb_battery")
    is_ok(t, headless_link_all(inst, false, ns), "links")
    headless_add_asset(inst.id, "rom", rom)
    is_ok(t, abi_bind_eden_game(inst), "binds")
    equal_str(t, game_start(inst), "", "init")
    for (k in range(frames)) {
        game_frame(inst, 1000000000, 4)
    }
    game_stop(inst)
    equal_str(t, inst.error, "", "ran and stopped")
    logs <- headless_logs(inst.id)
    abi_destroy(inst)
    return <- logs
}


// battery RAM through eden_storage: saved at shutdown, restored at the
// next start (guests/binjgb/roms/battery_test.gb from
// scripts/abi/make_battery_rom.py writes 0x42 0x43 to cartridge RAM)
def test_abi_binjgb_battery(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_binjgb_battery")
    let wasm <- load_fixture(fx, BINJGB_WASM)
    let rom <- load_fixture(fx, BATTERY_ROM)
    check(t, length(rom) == 32768, "battery test ROM present")
    storage_drop_namespace("battery_test")
    let first <- run_battery_rom(wasm, rom, "battery_test", 3, t)
    equal(t, storage_size("battery_test", "battery"), 8192, "shutdown saved 8 KB of battery RAM")
    let saved <- storage_copy("battery_test", "battery")
    check(t, length(saved) == 8192 && saved[0] == 0x42u8 && saved[1] == 0x43u8, "with the bytes the ROM wrote")
    var restoredFirst = false
    for (l in first) {
        restoredFirst = restoredFirst || find(l, "battery RAM restored") >= 0
    }
    check(t, !restoredFirst, "nothing to restore on the first start")
    let second <- run_battery_rom(wasm, rom, "battery_test", 1, t)
    var restored = false
    for (l in second) {
        restored = restored || find(l, "battery RAM restored (8192 bytes)") >= 0
    }
    check(t, restored, "the second start restored it")
    storage_drop_namespace("battery_test")
}


def public run_tests_abi_binjgb(var t : TestRun; fx : FixtureSource) {
    test_abi_binjgb_first_frame(t, fx)
    test_abi_binjgb_missing_rom(t, fx)
    test_abi_binjgb_battery(t, fx)
}
