options gen2
options indenting = 4

module abi_host_check shared public

require engine.core
require modules/wasm3das/eden/abi_eden_host
require modules/wasm3das/source/abi/abi_game
require modules/wasm3das/source/abi/gen/abi_abi_selftest
require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/abi_golden
require modules/wasm3das/tests/eden/test_abi      // abi_test_double
require strings

/*
    abi_host_check.das: the Eden host (abi_eden_host) itself, inside the
    editor, where the headless tests cannot reach: the engine video, audio
    and input paths. Cheat abi_host_check; part of scripts/abi/gate.sh.

      - binjgb through the Eden host: frames reach the texture, the first
        frame's digest is the golden one, the Bitmap packing (0xAARRGGBB)
        puts the yellow acid2 face at the known pixel
      - the audio stream opens and accepts binjgb's samples (when the engine
        has audio)
      - the self-test guest's RGBA8, RGB565 and INDEXED8 frames and its
        palette go through the Eden host too (with the abi_test double);
        run it with no pad button held
    Pad input is checked from outside (scripts/abi/gate.sh presses keys with
    the MCP input tool and reads the cheat abi_input_probe).
*/


def private open_with_eden_host(wasm : array<uint8>; name : string; var inst : AbiInstance) : string {
    inst <- abi_instantiate(wasm, name)
    if (!inst.alive) {
        return inst.error
    }
    return eden_host_link(inst, false)
}


def check_binjgb(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "abi_host_check_binjgb")
    let wasm <- load_fixture(fx, BINJGB_WASM)
    let rom <- load_fixture(fx, ACID2_ROM)
    var inst = AbiInstance()
    is_ok(t, open_with_eden_host(wasm, "binjgb_host", inst), "binjgb links with the Eden host")
    headless_add_asset(inst.id, "rom", rom)
    is_ok(t, abi_bind_eden_game(inst), "binds eden_game")
    equal_str(t, game_start(inst), "", "init")
    eden_host_set_digest(inst.id, true)
    equal(t, game_frame(inst, 1000000000, 4), EDEN_GAME_STEP_FRAME, "frame 1")
    equal(t, eden_host_last_digest(inst.id), GOLDEN_FIRST, "first frame digest through the Eden host")
    check(t, eden_host_has_frame(inst.id), "a texture exists")
    let size = eden_host_frame_size(inst.id)
    check(t, size.x == 160 && size.y == 144, "160x144 ({size})")
    for (k in range(11)) {
        game_frame(inst, 1000000000, 4)
    }
    equal(t, eden_host_frames(inst.id), 12, "12 frames")
    // the acid2 face is (248, 248, 0) at (80, 30) by frame 12 (headless run)
    equal(t, eden_host_pixel(inst.id, 80, 30), 0xFFF8F800u, "Bitmap pixel of the yellow face is 0xAARRGGBB")
    equal(t, eden_host_pixel(inst.id, 80, 100), 0xFF000000u, "the black mouth")
    let logs <- headless_logs(inst.id)
    var audioLine = false
    for (l in logs) {
        if (find(l, "audio stream 1") >= 0) {
            audioLine = true
        }
    }
    if (is_audio_active()) {
        check(t, audioLine, "binjgb opened audio stream 1 with the Eden host")
    } else {
        out("[abi_host_check] the engine has no audio output; stream check skipped")
    }
    game_stop(inst)
    abi_destroy(inst)
    check(t, !eden_host_has_frame(inst.id), "the view went away with the instance")
}


def check_selftest(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "abi_host_check_selftest")
    let wasm <- load_fixture(fx, "abi/build/abi_selftest.wasm")
    var inst = AbiInstance()
    is_ok(t, open_with_eden_host(wasm, "selftest_host", inst), "selftest links with the Eden host")
    is_ok(t, abi_link_abi_test(inst, abi_test_double()), "plus the abi_test double")
    is_ok(t, abi_bind_abi_selftest(inst), "binds abi_selftest")
    var data : array<uint8>
    for (i in range(5)) {
        push(data, uint8(i + 1))
    }
    headless_add_asset(inst.id, "data", data)
    equal_str(t, game_start(inst), "", "init")
    equal(t, game_frame(inst, 1000000000, 4), EDEN_GAME_STEP_FRAME, "RGBA8 frame")
    equal(t, eden_host_pixel(inst.id, 1, 0), 0xFF0A0FC8u, "RGBA8 (10, 15, 200) as 0xAARRGGBB (no pad button held)")
    equal(t, game_frame(inst, 1000000000, 4), EDEN_GAME_STEP_FRAME, "RGB565 frame")
    equal(t, eden_host_pixel(inst.id, 3, 1), 0xFFFF0000u, "RGB565 0xF800 is red, short last row included")
    equal(t, game_frame(inst, 1000000000, 4), EDEN_GAME_STEP_FRAME | EDEN_GAME_STEP_QUIT, "INDEXED8 frame")
    equal(t, eden_host_pixel(inst.id, 1, 0), 0xFFFF0000u, "palette entry 1 red")
    equal(t, eden_host_pixel(inst.id, 2, 0), 0xFF0000FFu, "palette entry 2 blue")
    equal(t, eden_host_frames(inst.id), 3, "three frames, rejected presents not counted")
    game_stop(inst)
    abi_destroy(inst)
}


// eden_storage through the engine's local storage: the self-test guest's
// storage checks, the blob in the engine storage, and a fresh load of it
def check_storage(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "abi_host_check_storage")
    let wasm <- load_fixture(fx, "abi/build/abi_selftest.wasm")
    let ns = "abi_host_check"
    remove_storage("abi_{ns}")
    storage_drop_namespace(ns)
    var inst <- abi_instantiate(wasm, "storage_host")
    is_ok(t, eden_host_link(inst, false, ns), "links with the Eden host")
    is_ok(t, abi_link_abi_test(inst, abi_test_double()), "plus the abi_test double")
    is_ok(t, abi_bind_abi_selftest(inst), "binds")
    equal(t, abi_selftest_storage(inst), 0, "the guest's storage checks against engine persistence")
    abi_destroy(inst)
    var text = ""
    var stored <- load_storage("abi_{ns}")
    check(t, get(stored, "b:keep", text), "the engine storage abi_{ns} holds b:keep")
    equal_str(t, text, "a2VlcCE=", "the blob `keep` is base64 of keep!")
    // forget the in-memory copy: a new instance must load it from the engine
    storage_drop_namespace(ns)
    var again <- abi_instantiate(wasm, "storage_host_again")
    eden_host_link(again, false, ns)
    abi_link_abi_test(again, abi_test_double())
    abi_bind_abi_selftest(again)
    equal(t, abi_selftest_blob_size(again, "keep"), 5, "reloaded from the engine storage")
    abi_destroy(again)
    remove_storage("abi_{ns}")
    storage_drop_namespace(ns)
}


def public run_abi_host_check(var t : TestRun; fx : FixtureSource) {
    check_binjgb(t, fx)
    check_selftest(t, fx)
    check_storage(t, fx)
}
