options gen2
options indenting = 4
options stack = 67_108_864

require daslib/fio
require strings
require math
require modules/wasm3das/source/abi/abi_dgv

/*
    .local/run_dgv.das: runs Spider's doomgeneric guest (dgv_* interface,
    source/abi/abi_dgv.das) on the port without the engine: -timedemo demo1
    by default, prints init time, ticks per second and frame digests.

    Run from the Eden project root:
        daslang -no-dynamic-modules -project modules/wasm3das/scripts/eden/sandbox.das_project \
            modules/wasm3das/.local/run_dgv.das -- <doom.wasm> <doom1.wad> [mode] [ticks]
*/


def read_file(path : string) : array<uint8> {
    var bytes : array<uint8>
    fopen(path, "rb") <| $(f) {
        if (f != null) {
            fmap(f) <| $(data) {
                resize(bytes, length(data))
                for (i in range(length(data))) {
                    bytes[i] = data[i]
                }
            }
        } else {
            print("[run_dgv] not found: {path}\n")
        }
    }
    return <- bytes
}


[export]
def main() {
    var args : array<string>
    var seen = false
    for (a in get_command_line_arguments()) {
        if (seen) {
            push(args, a)
        }
        if (a == "--") {
            seen = true
        }
    }
    if (length(args) < 2) {
        print("usage: run_dgv.das -- <doom.wasm> <doom1.wad> [mode] [ticks]\n")
        unsafe(exit(2))
    }
    let mode = length(args) > 2 ? to_int(args[2]) : 1
    let maxTicks = length(args) > 3 ? to_int(args[3]) : 100
    let wasm <- read_file(args[0])
    let wad <- read_file(args[1])
    let t0 = ref_time_ticks()
    var game <- dgv_start(wasm, wad, "doom", mode)
    let initMs = get_time_usec(t0) / 1000
    print("{game.log}")
    if (!empty(game.inst.error)) {
        print("[run_dgv] start failed after {initMs} ms: {game.inst.error}\n")
        unsafe(exit(1))
    }
    print("[run_dgv] init {initMs} ms, screen {game.width}x{game.height}, memory {length(game.inst.rt.mem)} bytes\n")
    let t1 = ref_time_ticks()
    var ticks = 0
    var now = 0
    while (ticks < maxTicks && dgv_tick(game, now)) {
        ticks++
        now += 29   // a little over one 35 Hz game tic per call
        if (ticks % 20 == 0) {
            let ms = get_time_usec(t1) / 1000
            print("[run_dgv] tick {ticks}: frames {dgv_frames(game)}, {ms} ms, digest {dgv_frame_digest(game)}\n")
        }
    }
    let loopMs = get_time_usec(t1) / 1000
    print("{dgv_take_log(game)}")
    print("[run_dgv] ticks={ticks} frames={dgv_frames(game)} loop {loopMs} ms ({loopMs / max(ticks, 1)} ms/tick) exited={game.exited} error={game.inst.error}\n")
    dgv_destroy(game)
}
