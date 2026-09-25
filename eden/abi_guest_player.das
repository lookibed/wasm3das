options gen2
options indenting = 4

module abi_guest_player shared public

require engine.core
require modules/wasm3das/eden/abi_eden_host public
require modules/wasm3das/source/abi/abi_game public
require strings
require math

/*
    abi_guest_player.das: plays an eden_game guest in the scene.

    guest_player_start instantiates the guest with the Eden host
    (abi_eden_host), adds its assets, binds eden_game, runs eden_init and
    creates a node with a GuestPlayer component. Every on_update the
    component runs eden_step with `budgetUs`, so the editor stays responsive
    however slow the guest is; when a frame is presented the quad shows the
    texture (pixel_art shader, rebuilt when the frame size changes). The
    status text shows frames, emulated fps and the milliseconds of the last
    frame.

    Instances live in g_players (the component keeps the slot); an
    AbiInstance holds the whole wasm3 runtime, which is plain data, while
    the component is a class the engine owns.
*/


var private g_players : array<AbiInstance>


class GuestPlayer : Component {
    slot : int = -1
    budgetUs : int = 12000
    screen : NodeId
    status : NodeId
    texture : TextureId
    hasMaterial : bool = false
    frameStartTicks : int64 = 0l
    lastFrameMs : double = 0.0lf
    startTicks : int64 = 0l
    stopped : bool = false
    reason : string
    relinks : int = 0

    def override on_update {
        if (stopped || slot < 0 || slot >= length(g_players)) {
            return
        }
        if (!g_players[slot].alive) {
            stop_with("the instance is gone")
            return
        }
        if (abi_is_stale(g_players[slot])) {
            // a hot reload of the scripts: same guest, same memory, fresh links
            let r = eden_host_relink(g_players[slot])
            if (r != m3Err_none) {
                stop_with("relink after hot reload failed: {r}")
                return
            }
            relinks++
            print("[guest player] {g_players[slot].name}: relinked after a hot reload ({relinks})\n")
        }
        let flags = abi_eden_step(g_players[slot], budgetUs)
        if (!empty(g_players[slot].error)) {
            stop_with(g_players[slot].error)
            return
        }
        if ((flags & EDEN_GAME_STEP_FRAME) != 0) {
            lastFrameMs = double(get_time_nsec(frameStartTicks)) / 1000000.0lf
            frameStartTicks = ref_time_ticks()
            show_frame()
        }
        if ((flags & EDEN_GAME_STEP_ERROR) != 0) {
            stop_with("the guest reported an error (see its log)")
        } elif ((flags & EDEN_GAME_STEP_QUIT) != 0) {
            stop_with("the guest quit")
        }
        update_status()
    }

    def show_frame {
        let id = g_players[slot].id
        if (!eden_host_has_frame(id)) {
            return
        }
        let tex = eden_host_texture(id)
        if (!hasMaterial || tex != texture) {
            texture = tex
            hasMaterial = true
            let size = eden_host_frame_size(id)
            let h = 9.0   // of the host camera's 10 visible units (main.das)
            let w = h * float(size.x) / float(max(size.y, 1))
            screen.localScale = float3(w, h, 1.0)
            screen?.Mesh.materialId = create_material(MaterialImport(shaderName = "pixel_art", diffuse = tex))
        }
    }

    def update_status {
        if (!status.isAlive || slot < 0) {
            return
        }
        let id = g_players[slot].id
        let frames = eden_host_frames(id)
        let seconds = double(get_time_nsec(startTicks)) / 1000000000.0lf
        let fps = seconds > 0.0lf ? double(frames) / seconds : 0.0lf
        let fps100 = int(fps * 100.0lf)
        var text = "{g_players[slot].name}: {frames} frames, {fps100 / 100}.{fps100 % 100 < 10 ? "0" : ""}{fps100 % 100} fps, last frame {int(lastFrameMs)} ms, relinks {relinks}"
        if (stopped) {
            text = "{text}\nstopped: {reason}"
        }
        update_debug_text(status, text)
    }

    def stop_with(why : string) {
        stopped = true
        reason = why
        print("[guest player] stopped: {why}\n")
        update_status()
    }

    def override on_destroy {
        if (slot >= 0 && slot < length(g_players)) {
            if (abi_is_stale(g_players[slot])) {
                eden_host_relink(g_players[slot])
            }
            game_stop(g_players[slot])
            abi_destroy(g_players[slot])
        }
        if (status.isAlive) {
            remove_node(status)
        }
    }
}


// starts a guest; `assets` maps asset names (eden_asset) to their bytes,
// `ns` is its eden_storage namespace (saves). Returns the player node, or
// an invalid NodeId with the reason printed
def public guest_player_start(wasm : array<uint8>; name : string; assets : table<string; array<uint8>>; ns : string; budgetUs : int = 12000) : NodeId {
    var inst <- abi_instantiate(wasm, name)
    if (!inst.alive) {
        print("[guest player] {inst.error}\n")
        return NodeId()
    }
    var r = eden_host_link(inst, true, ns)
    if (r == m3Err_none) {
        for (k, v in keys(assets), values(assets)) {
            headless_add_asset(inst.id, k, v)
        }
        r = abi_bind_eden_game(inst)
    }
    if (r == m3Err_none) {
        r = game_start(inst)
    }
    if (r != m3Err_none) {
        print("[guest player] {name}: {r}\n")
        abi_destroy(inst)
        return NodeId()
    }
    let slot = length(g_players)
    g_players |> emplace(inst)
    let screen = create_node(NodeData(name = "guest_{name}", position = float3(0, 0, 0)))
    add_component(screen, new Mesh(meshId = QUAD_MESH_ID, visibility = MeshVisibility.VisibleInAnyCamera))
    let status = create_debug_text("{name}: starting", float2(16, 48), TOP_LEFT_ANCHOR)
    var player = new GuestPlayer(slot = slot, budgetUs = budgetUs, screen = screen, status = status)
    player.startTicks = ref_time_ticks()
    player.frameStartTicks = player.startTicks
    add_component(screen, player)
    return screen
}


// abi_reload_report of a player's instance; "none" without a player
def public guest_player_reload_report(node : NodeId) : string {
    var report = "none"
    let player = get_component(node, type<GuestPlayer>)
    if (player != null && player.slot >= 0 && player.slot < length(g_players)) {
        report = abi_reload_report(g_players[player.slot])
    }
    return report
}


// the instance of a running player (for cheats and checks); -1 when none
def public guest_player_instance_id(node : NodeId) : int {
    var id = -1
    let player = get_component(node, type<GuestPlayer>)
    if (player != null && player.slot >= 0 && player.slot < length(g_players)) {
        id = g_players[player.slot].id
    }
    return id
}
