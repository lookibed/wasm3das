options gen2
options indenting = 4

module abi_dgv shared public

require modules/wasm3das/source/abi/abi_runtime public
require strings

/*
    abi_dgv.das: the host of a doomgeneric guest built with the dgv_*
    interface of Spider's tests/manual/real-world-doomgeneric
    (src/dg_voxelcore.c). That guest is not an eden_game world: it imports
    nothing (its WASI calls are answered inside the module, the WAD is
    handed over as one buffer) and exports

      _initialize                       the reactor's constructors
      dgv_alloc(size) -> ptr            malloc
      dgv_init(wad, size, mode) -> i32  doomgeneric_Create; mode 0 = play,
                                        1/2 = -timedemo demo1
      dgv_tick(now_ms) -> i32           one doomgeneric_Tick at host time
                                        now_ms; 0 once the game exited
      dgv_key(pressed, doomkey)         queues a key event
      dgv_screen_ptr/_width/_height     the 8-bit indexed frame (CMAP256)
      dgv_palette_ptr                   256 x (b, g, r, a)
      dgv_frame_count, dgv_exited, dgv_exit_code
      dgv_log_ptr/_size/_clear          stdout/stderr of the game

    dgv_start instantiates through abi_runtime (memory budget, faults,
    re-entrancy, relink after a hot reload) and runs the guest up to the
    end of dgv_init; dgv_tick then runs one game tick. dgv_frame_argb turns
    the frame into 0xAARRGGBB pixels (the Eden Bitmap layout).

    Engine-free.
*/


let public DGV_EXPORTS = fixed_array<string>("_initialize", "dgv_alloc", "dgv_init", "dgv_tick", "dgv_key",
    "dgv_screen_ptr", "dgv_screen_width", "dgv_screen_height", "dgv_palette_ptr", "dgv_frame_count",
    "dgv_exited", "dgv_exit_code", "dgv_log_ptr", "dgv_log_size", "dgv_log_clear")


struct DgvGame {
    inst : AbiInstance = AbiInstance()
    width : int = 0
    height : int = 0
    screenPtr : int = 0
    palettePtr : int = 0
    exited : bool = false
    log : string                  // everything the guest printed so far
}


// calls an export with i32 arguments; the first result as i32 (0 without
// one). On failure inst.error says why
def public dgv_call(var game : DgvGame; name : string; a : int = 0; b : int = 0; c : int = 0; argc : int = 0) : int {
    var inscope args : array<uint64>
    if (argc > 0) {
        push(args, m3_bits_from_i32(a))
    }
    if (argc > 1) {
        push(args, m3_bits_from_i32(b))
    }
    if (argc > 2) {
        push(args, m3_bits_from_i32(c))
    }
    var inscope rets : array<uint64>
    if (!abi_call(game.inst, name, args, rets)) {
        return 0
    }
    return length(rets) > 0 ? int(m3_bits_to_i32(rets[0])) : 0
}


// appends what the guest printed since the last call to game.log and
// returns it
def public dgv_take_log(var game : DgvGame) : string {
    let ptr = dgv_call(game, "dgv_log_ptr")
    let size = dgv_call(game, "dgv_log_size")
    if (size <= 0 || !empty(game.inst.error)) {
        return ""
    }
    var inscope bytes <- abi_read_bytes(game.inst, ptr, size)
    dgv_call(game, "dgv_log_clear")
    let text = build_string() $(var w) {
        for (ch in bytes) {
            write_char(w, int(ch))
        }
    }
    game.log = game.log + text
    return text
}


// instantiates the guest, copies the WAD in and runs dgv_init. On failure
// game.inst.error is set (the instance may be dead or faulted)
def public dgv_start(wasm : array<uint8>; wad : array<uint8>; name : string; mode : int; config : AbiConfig = AbiConfig()) : DgvGame {
    var game = DgvGame()
    game.inst <- abi_instantiate(wasm, name, config)
    if (!game.inst.alive) {
        return <- game
    }
    var noPackages : array<string>
    var r = abi_check_imports(game.inst, "dgv", noPackages)
    if (r == m3Err_none) {
        var required : array<string>
        for (e in DGV_EXPORTS) {
            push(required, e)
        }
        var noOptional : array<string>
        r = abi_bind_exports(game.inst, required, noOptional)
    }
    if (r != m3Err_none) {
        game.inst.error = "{r}"
        return <- game
    }
    dgv_call(game, "_initialize")
    let wadPtr = dgv_call(game, "dgv_alloc", length(wad), 0, 0, 1)
    if (!empty(game.inst.error)) {
        return <- game
    }
    if (wadPtr == 0 || int64(wadPtr) + int64(length(wad)) > int64(length(game.inst.rt.mem))) {
        game.inst.error = "{name}: dgv_alloc({length(wad)}) returned {wadPtr}"
        return <- game
    }
    for (b, i in wad, count()) {
        game.inst.rt.mem[wadPtr + i] = b
    }
    let ok = dgv_call(game, "dgv_init", wadPtr, length(wad), mode, 3)
    dgv_take_log(game)
    if (!empty(game.inst.error)) {
        return <- game
    }
    if (ok == 0) {
        game.exited = true
        game.inst.error = "{name}: dgv_init: the game exited (code {dgv_call(game, "dgv_exit_code")})"
        return <- game
    }
    game.width = dgv_call(game, "dgv_screen_width")
    game.height = dgv_call(game, "dgv_screen_height")
    game.screenPtr = dgv_call(game, "dgv_screen_ptr")
    game.palettePtr = dgv_call(game, "dgv_palette_ptr")
    return <- game
}


// one game tick at host time nowMs; false once the game exited or failed
def public dgv_tick(var game : DgvGame; nowMs : int) : bool {
    if (game.exited || !empty(game.inst.error)) {
        return false
    }
    let running = dgv_call(game, "dgv_tick", nowMs, 0, 0, 1)
    if (!empty(game.inst.error)) {
        return false
    }
    if (running == 0) {
        game.exited = true
    }
    return !game.exited
}


def public dgv_key(var game : DgvGame; pressed : bool; doomKey : int) {
    dgv_call(game, "dgv_key", pressed ? 1 : 0, doomKey, 0, 2)
}


def public dgv_frames(var game : DgvGame) : int {
    return dgv_call(game, "dgv_frame_count")
}


// the frame as 0xAARRGGBB, row-major width x height; resized to fit
def public dgv_frame_argb(game : DgvGame; var pixels : array<uint>) {
    let n = game.width * game.height
    resize(pixels, n)
    if (n == 0 || game.screenPtr + n > length(game.inst.rt.mem) || game.palettePtr + 1024 > length(game.inst.rt.mem)) {
        return
    }
    var lut : uint[256]
    for (i in range(256)) {
        let p = game.palettePtr + i * 4
        let b = uint(game.inst.rt.mem[p])
        let g = uint(game.inst.rt.mem[p + 1])
        let r = uint(game.inst.rt.mem[p + 2])
        lut[i] = 0xff000000u | (r << 16u) | (g << 8u) | b
    }
    for (i in range(n)) {
        pixels[i] = lut[int(game.inst.rt.mem[game.screenPtr + i])]
    }
}


// FNV-1a of the indexed frame: a cheap digest to compare runs
def public dgv_frame_digest(game : DgvGame) : uint {
    var h = 2166136261u
    let n = game.width * game.height
    if (n == 0 || game.screenPtr + n > length(game.inst.rt.mem)) {
        return 0u
    }
    for (i in range(n)) {
        h = (h ^ uint(game.inst.rt.mem[game.screenPtr + i])) * 16777619u
    }
    return h
}


// relinks after a hot reload of the scripts; the guest imports nothing, so
// this only rebuilds the op tables
def public dgv_relink(var game : DgvGame) : M3Result {
    abi_relink_begin(game.inst)
    return abi_relink_end(game.inst)
}


def public dgv_destroy(var game : DgvGame) {
    abi_destroy(game.inst)
}
