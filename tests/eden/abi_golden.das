options gen2
options indenting = 4

module abi_golden shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/abi/abi_game
require modules/wasm3das/source/abi/impl/abi_headless
require strings

/*
    abi_golden.das: the binjgb guest (guests/build/binjgb.wasm) against the
    wasmtime baselines of the reference fixture (Spider
    tests/manual/real-world-binjgb, module.c run_probe_script; the numbers
    are in the upstream port's tests/manual/run_fixtures.py):

      first frame digest        1015431621   binjgb_probe_first_frame_hash
      frame 16 digest            838717591   binjgb_probe_last_frame_hash 16
      16-frame combined hash   -1323964910   binjgb_decode_hash 16

    The reference presses A on frames 8 and 9 (INPUT_PRESET_ACID2_A_PRESS)
    and hashes every frame with the RGB555 FNV digest (abi_media
    frame_digest_rgb555). Here the same frames go through the whole ABI:
    ROM from eden_asset, input from eden_input, frames through
    eden_video.present, time-sliced eden_step.

    run_abi_golden (the 16-frame checks, about 16 interpreted frames per
    variant) is not part of run_all_tests; it runs from
    .local/run_abi_golden.das and the editor cheat abi_binjgb_golden.
*/


let public BINJGB_WASM = "abi/build/binjgb.wasm"
let public ACID2_ROM = "abi/binjgb/roms/cgb-acid2.gbc"
let public BATTERY_ROM = "abi/binjgb/roms/battery_test.gb"
let public GOLDEN_FIRST = 1015431621
let public GOLDEN_LAST16 = 838717591
let public GOLDEN_COMBINED16 = -1323964910


struct GoldenRun {
    digests : array<int>
    combined : int = 0
    steps : int = 0
    audioFrames : int64 = 0l
    rate : int = 0
    channels : int = 0
    error : string
    ms : double = 0.0lf
}


// the acid2 input script of the reference
def public acid2_buttons(frame : int) : int {
    return (frame == 8 || frame == 9) ? EDEN_INPUT_BUTTON_A : 0
}


def private open_binjgb(wasm : array<uint8>; rom : array<uint8>; var inst : AbiInstance) : string {
    inst <- abi_instantiate(wasm, "binjgb")
    if (!inst.alive) {
        return inst.error
    }
    var r = headless_link_all(inst, false)
    if (r != m3Err_none) {
        return r
    }
    headless_add_asset(inst.id, "rom", rom)
    r = abi_bind_eden_game(inst)
    if (r != m3Err_none) {
        return r
    }
    return game_start(inst)
}


def private collect(var run : GoldenRun; id : int) {
    let digests <- headless_digests(id)
    for (d in digests) {
        push(run.digests, d)
    }
    var frames = 0l
    var digest = 0u
    var pushes = 0
    var streams = 0
    headless_audio(id, frames, digest, pushes, streams)
    run.audioFrames += frames
    headless_stream_format(id, 1, run.rate, run.channels)
}


// runs `frames` frames with steps of `budget_us`; when snapshotAt >= 0, the
// instance is snapshotted after that many frames, destroyed, and a fresh
// instance restored from the snapshot runs the rest
def public golden_binjgb(wasm : array<uint8>; rom : array<uint8>; frames : int; budget_us : int; snapshotAt : int = -1) : GoldenRun {
    var run = GoldenRun()
    let t0 = ref_time_ticks()
    var inst = AbiInstance()
    run.error = open_binjgb(wasm, rom, inst)
    if (!empty(run.error)) {
        abi_destroy(inst)
        return <- run
    }
    for (k in range(frames)) {
        if (k == snapshotAt) {
            let snap <- game_snapshot(inst)
            if (length(snap) == 0) {
                run.error = "snapshot failed: {inst.error}"
                break
            }
            collect(run, inst.id)
            game_stop(inst)
            if (!empty(inst.error)) {
                run.error = "shutdown before the restore: {inst.error}"
                break
            }
            abi_destroy(inst)
            run.error = open_binjgb(wasm, rom, inst)
            if (!empty(run.error)) {
                break
            }
            if (!game_restore(inst, snap)) {
                run.error = "restore failed: {inst.error}"
                break
            }
        }
        headless_set_buttons(inst.id, acid2_buttons(k))
        var flags = 0
        while (flags == 0) {
            flags = abi_eden_step(inst, budget_us)
            run.steps++
            if (!empty(inst.error)) {
                run.error = "frame {k}: {inst.error}"
                break
            }
        }
        if (!empty(run.error)) {
            break
        }
        if ((flags & EDEN_GAME_STEP_FRAME) == 0) {
            run.error = "frame {k}: step returned flags {flags}"
            break
        }
    }
    if (inst.alive) {
        collect(run, inst.id)
        game_stop(inst)
        if (empty(run.error) && !empty(inst.error)) {
            run.error = "shutdown: {inst.error}"
        }
        abi_destroy(inst)
    }
    var c = 0u
    for (d in run.digests) {
        c = (c * 33u) ^ uint(d)
    }
    run.combined = int(c)
    run.ms = double(get_time_nsec(t0)) / 1000000.0lf
    return <- run
}


def private check_run(var t : TestRun; run : GoldenRun; what : string) {
    equal_str(t, run.error, "", "{what}: ran")
    equal(t, length(run.digests), 16, "{what}: 16 frames")
    if (length(run.digests) == 16) {
        equal(t, run.digests[0], GOLDEN_FIRST, "{what}: first frame = binjgb_probe_first_frame_hash")
        equal(t, run.digests[15], GOLDEN_LAST16, "{what}: frame 16 = binjgb_probe_last_frame_hash 16")
        equal(t, run.combined, GOLDEN_COMBINED16, "{what}: combined = binjgb_decode_hash 16")
    }
    out("[abi_golden] {what}: {run.steps} steps, {run.audioFrames} audio frames, {run.ms} ms")
}


def public run_abi_golden(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "abi_golden_binjgb")
    let wasm <- load_fixture(fx, BINJGB_WASM)
    let rom <- load_fixture(fx, ACID2_ROM)
    check(t, length(wasm) > 0 && length(rom) > 0, "fixtures present")
    let whole <- golden_binjgb(wasm, rom, 16, 1000000000)
    check_run(t, whole, "whole frames")
    let sliced <- golden_binjgb(wasm, rom, 16, 2000)
    check_run(t, sliced, "2 ms slices")
    check(t, sliced.steps > whole.steps, "slicing split frames across steps ({sliced.steps} > {whole.steps})")
    equal(t, sliced.audioFrames, whole.audioFrames, "the same audio whatever the slicing")
    let resumed <- golden_binjgb(wasm, rom, 16, 1000000000, 5)
    check_run(t, resumed, "snapshot after 5 frames, restored into a new instance")
}
