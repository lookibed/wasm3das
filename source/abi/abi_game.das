options gen2
options indenting = 4

module abi_game shared public

require modules/wasm3das/source/abi/gen/abi_eden_game public

/*
    abi_game.das: host-side helpers of the eden_game world on top of the
    generated wrappers, shared by every host (the Eden component, the
    headless golden runs, the tests):

      game_start      eden_init of a bound instance
      game_frame      step until a frame is presented, the guest stops or
                      fails, or the step limit is reached
      game_snapshot   eden_state_size + eden_state_save, copied out
      game_restore    eden_state_load of a snapshot
      game_stop       eden_shutdown (when the instance is still healthy)

    Engine-free.
*/


// eden_init of an instance already bound to eden_game or a world extending
// it (abi_bind_<world>); "" on success
def public game_start(var inst : AbiInstance) : string {
    if (empty(inst.world)) {
        return "{inst.name}: game_start before abi_bind_<world>"
    }
    let code = abi_eden_init(inst)
    if (!empty(inst.error)) {
        return inst.error
    }
    if (code != 0) {
        return "{inst.name}: eden_init returned {code}"
    }
    return ""
}


// steps with `budget_us` until STEP_FRAME, STEP_QUIT, STEP_ERROR, a failed
// call, or `maxSteps` steps; returns the flags of the last step (0 when the
// step limit ran out mid-frame, -1 when a call failed: inst.error says why)
def public game_frame(var inst : AbiInstance; budget_us : int; maxSteps : int) : int {
    for (i in range(maxSteps)) {
        let flags = abi_eden_step(inst, budget_us)
        if (!empty(inst.error)) {
            return -1
        }
        if ((flags & (EDEN_GAME_STEP_FRAME | EDEN_GAME_STEP_QUIT | EDEN_GAME_STEP_ERROR)) != 0) {
            return flags
        }
    }
    return 0
}


// the guest's snapshot; empty when the guest has none or it failed
// (inst.error then says why, unless the export is simply absent)
def public game_snapshot(var inst : AbiInstance) : array<uint8> {
    var out : array<uint8>
    if (!abi_has_export(inst, "eden_state_size") || !abi_has_export(inst, "eden_state_save")) {
        return <- out
    }
    let size = abi_eden_state_size(inst)
    if (!empty(inst.error) || size <= 0) {
        return <- out
    }
    let ptr = abi_eden_alloc(inst, size)
    if (!empty(inst.error) || ptr == 0) {
        if (empty(inst.error)) {
            inst.error = "{inst.name}: eden_alloc({size}) returned 0"
        }
        return <- out
    }
    let written = abi_eden_state_save(inst, ptr, size)
    if (empty(inst.error)) {
        if (written == size) {
            out <- abi_read_bytes(inst, ptr, size)
        } else {
            inst.error = "{inst.name}: eden_state_save wrote {written} of {size} bytes"
        }
    }
    abi_free_guest(inst, ptr)
    return <- out
}


// true when the guest accepted the snapshot
def public game_restore(var inst : AbiInstance; snapshot : array<uint8>) : bool {
    if (!abi_has_export(inst, "eden_state_load")) {
        inst.error = "{inst.name}: the guest has no eden_state_load"
        return false
    }
    let code = abi_eden_state_load(inst, snapshot)
    if (!empty(inst.error)) {
        return false
    }
    if (code != 0) {
        inst.error = "{inst.name}: eden_state_load returned {code}"
        return false
    }
    return true
}


// eden_shutdown when the guest can still run it
def public game_stop(var inst : AbiInstance) {
    if (inst.alive && !inst.faulted && !empty(inst.world)) {
        abi_eden_shutdown(inst)
    }
}
