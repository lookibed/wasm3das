options gen2
options indenting = 4

module abi_dgv_player shared public

require engine.core
require modules/wasm3das/source/abi/abi_dgv public
require strings
require math

/*
    abi_dgv_player.das: plays a doomgeneric guest with the dgv_* interface
    (source/abi/abi_dgv.das) in the scene.

    dgv_player_start runs the guest up to the end of dgv_init (the WAD
    load and R_Init: seconds in the interpreter, in that one call) and
    creates a node with a DgvPlayer component. Every on_update the component
    sends the key edges, runs one dgv_tick and shows the frame. The clock
    the guest sees advances by exactly one game tic (1/35 s) per tick:
    a slow interpreter then plays the game slowed down instead of making
    doom run several tics per call to catch up with real time, which would
    make every call slower still.

    Keys (action set dgv_keys): arrows / W S move and turn, A D strafe,
    Ctrl or F fire, Space or E use, Shift run, Enter, Esc or Backspace the
    menu, Y / N answers, Tab the map, 1..7 weapons.
*/


struct private DgvKeyMap {
    action : string
    key : KeyCode
    doomKey : int
}


// doomkeys.h (decimal: hex literals are uint in daslang 0.6.4)
let private DOOM_KEY_RIGHTARROW = 174   // 0xae
let private DOOM_KEY_LEFTARROW = 172    // 0xac
let private DOOM_KEY_UPARROW = 173      // 0xad
let private DOOM_KEY_DOWNARROW = 175    // 0xaf
let private DOOM_KEY_STRAFE_L = 160     // 0xa0
let private DOOM_KEY_STRAFE_R = 161     // 0xa1
let private DOOM_KEY_USE = 162          // 0xa2
let private DOOM_KEY_FIRE = 163         // 0xa3
let private DOOM_KEY_ESCAPE = 27
let private DOOM_KEY_ENTER = 13
let private DOOM_KEY_TAB = 9
let private DOOM_KEY_RSHIFT = 182       // 0x80 + 0x36


var private g_games : array<DgvGame>
var private g_keyMap : array<DgvKeyMap>
var private g_keysReady = false


def private add_key(action : string; key : KeyCode; doomKey : int) {
    push(g_keyMap, DgvKeyMap(action = action, key = key, doomKey = doomKey))
}


def private ensure_keys() {
    if (g_keysReady) {
        return
    }
    g_keysReady = true
    clear(g_keyMap)
    add_key("dgv_up", KeyCode.Up, DOOM_KEY_UPARROW)
    add_key("dgv_w", KeyCode.W, DOOM_KEY_UPARROW)
    add_key("dgv_down", KeyCode.Down, DOOM_KEY_DOWNARROW)
    add_key("dgv_s", KeyCode.S, DOOM_KEY_DOWNARROW)
    add_key("dgv_left", KeyCode.Left, DOOM_KEY_LEFTARROW)
    add_key("dgv_right", KeyCode.Right, DOOM_KEY_RIGHTARROW)
    add_key("dgv_a", KeyCode.A, DOOM_KEY_STRAFE_L)
    add_key("dgv_d", KeyCode.D, DOOM_KEY_STRAFE_R)
    add_key("dgv_ctrl", KeyCode.LControl, DOOM_KEY_FIRE)
    add_key("dgv_f", KeyCode.F, DOOM_KEY_FIRE)
    add_key("dgv_space", KeyCode.Space, DOOM_KEY_USE)
    add_key("dgv_e", KeyCode.E, DOOM_KEY_USE)
    add_key("dgv_shift", KeyCode.LShift, DOOM_KEY_RSHIFT)
    add_key("dgv_enter", KeyCode.Return, DOOM_KEY_ENTER)
    add_key("dgv_escape", KeyCode.Escape, DOOM_KEY_ESCAPE)
    add_key("dgv_back", KeyCode.Back, DOOM_KEY_ESCAPE)
    add_key("dgv_tab", KeyCode.Tab, DOOM_KEY_TAB)
    add_key("dgv_y", KeyCode.Y, int('y'))
    add_key("dgv_n", KeyCode.N, int('n'))
    add_key("dgv_1", KeyCode._1, int('1'))
    add_key("dgv_2", KeyCode._2, int('2'))
    add_key("dgv_3", KeyCode._3, int('3'))
    add_key("dgv_4", KeyCode._4, int('4'))
    add_key("dgv_5", KeyCode._5, int('5'))
    add_key("dgv_6", KeyCode._6, int('6'))
    add_key("dgv_7", KeyCode._7, int('7'))
    var keys : ActionSet
    for (m in g_keyMap) {
        var buttons : array<KeyboardButtonInput>
        push(buttons, KeyboardButtonInput(idx = m.key))
        keys[m.action] = Action(buttonActions = ButtonAction(keyboardButtons <- buttons))
    }
    add_and_activate_action_set("dgv_keys", keys)
}


class DgvPlayer : Component {
    slot : int = -1
    screen : NodeId
    status : NodeId
    texture : TextureId
    bitmap : Bitmap
    pixels : array<uint>
    hasTexture : bool = false
    ticks : int = 0
    lastTickMs : double = 0.0lf
    totalTickMs : double = 0.0lf
    startTicks : int64 = 0l
    stopped : bool = false
    reason : string
    relinks : int = 0

    def override on_update {
        if (stopped || slot < 0 || slot >= length(g_games)) {
            return
        }
        if (!g_games[slot].inst.alive) {
            stop_with("the instance is gone")
            return
        }
        if (abi_is_stale(g_games[slot].inst)) {
            // a hot reload of the scripts: same guest, same memory, fresh op tables
            let r = dgv_relink(g_games[slot])
            if (r != m3Err_none) {
                stop_with("relink after hot reload failed: {r}")
                return
            }
            g_keysReady = false
            relinks++
            print("[dgv player] {g_games[slot].inst.name}: relinked after a hot reload ({relinks})\n")
        }
        ensure_keys()
        for (m in g_keyMap) {
            if (is_action_just_pressed(m.action, ModifierMatchMode.Weak)) {
                dgv_key(g_games[slot], true, m.doomKey)
            } elif (is_action_just_released(m.action, ModifierMatchMode.Weak)) {
                dgv_key(g_games[slot], false, m.doomKey)
            }
        }
        let t0 = ref_time_ticks()
        // the guest's clock: one game tic (1000 / 35 ms) per call
        let running = dgv_tick(g_games[slot], (ticks + 1) * 1000 / 35)
        lastTickMs = double(get_time_nsec(t0)) / 1000000.0lf
        totalTickMs += lastTickMs
        ticks++
        let printed = dgv_take_log(g_games[slot])
        if (!empty(printed)) {
            print("[dgv] {printed}")
        }
        if (!empty(g_games[slot].inst.error)) {
            stop_with(g_games[slot].inst.error)
            return
        }
        show_frame()
        if (!running) {
            stop_with("the game exited (code {dgv_call(g_games[slot], "dgv_exit_code")})")
        }
        update_status()
    }

    def show_frame {
        let w = g_games[slot].width
        let h = g_games[slot].height
        if (w <= 0 || h <= 0) {
            return
        }
        if (!hasTexture) {
            hasTexture = true
            var blank : array<uint>
            resize(blank, w * h)
            texture = create_texture(w, h, blank, TextureDeclaration(
                filter = TextureFilter.Point,
                generateMipLevels = false,
                addressing = TextureAddress.Clamp
            ))
            bitmap <- Bitmap(w, h)
            // doom's 320x200 is drawn for a 4:3 screen
            screen.localScale = float3(12.0, 9.0, 1.0)
            screen?.Mesh.materialId = create_material(MaterialImport(shaderName = "pixel_art", diffuse = texture))
        }
        dgv_frame_argb(g_games[slot], pixels)
        for (i in range(w * h)) {
            bitmap.pixels[i] = pixels[i]
        }
        update_texture(bitmap, texture)
    }

    def update_status {
        if (!status.isAlive || slot < 0) {
            return
        }
        let seconds = double(get_time_nsec(startTicks)) / 1000000000.0lf
        let fps10 = seconds > 0.0lf ? int(double(ticks) * 10.0lf / seconds) : 0
        let avg = ticks > 0 ? int(totalTickMs / double(ticks)) : 0
        var text = "{g_games[slot].inst.name}: {ticks} tics, {fps10 / 10}.{fps10 % 10} tics/s (35 = real time), tick {int(lastTickMs)} ms, avg {avg} ms, relinks {relinks}"
        if (stopped) {
            text = "{text}\nstopped: {reason}"
        }
        update_debug_text(status, text)
    }

    def stop_with(why : string) {
        stopped = true
        reason = why
        print("[dgv player] stopped: {why}\n")
        update_status()
    }

    def override on_destroy {
        if (slot >= 0 && slot < length(g_games)) {
            dgv_destroy(g_games[slot])
        }
        if (status.isAlive) {
            remove_node(status)
        }
    }
}


// starts a doomgeneric guest: `mode` 0 = play, 1 = -timedemo demo1.
// Returns the player node, or an invalid NodeId with the reason printed
def public dgv_player_start(wasm : array<uint8>; wad : array<uint8>; name : string; mode : int) : NodeId {
    ensure_keys()
    let t0 = ref_time_ticks()
    var game <- dgv_start(wasm, wad, name, mode)
    let initMs = get_time_usec(t0) / 1000
    if (!empty(game.log)) {
        print("[dgv] {game.log}\n")
    }
    if (!empty(game.inst.error)) {
        print("[dgv player] {name}: start failed after {initMs} ms: {game.inst.error}\n")
        dgv_destroy(game)
        return NodeId()
    }
    print("[dgv player] {name}: dgv_init done in {initMs} ms, screen {game.width}x{game.height}, memory {length(game.inst.rt.mem)} bytes\n")
    let slot = length(g_games)
    g_games |> emplace(game)
    let screen = create_node(NodeData(name = "dgv_{name}", position = float3(0, 0, 0)))
    add_component(screen, new Mesh(meshId = QUAD_MESH_ID, visibility = MeshVisibility.VisibleInAnyCamera))
    let status = create_debug_text("{name}: starting", float2(16, 48), TOP_LEFT_ANCHOR)
    var player = new DgvPlayer(slot = slot, screen = screen, status = status)
    player.startTicks = ref_time_ticks()
    add_component(screen, player)
    return screen
}


// "tics=N frames=F digest=D" of a running player; "none" without one
def public dgv_player_report(node : NodeId) : string {
    var report = "none"
    let player = get_component(node, type<DgvPlayer>)
    if (player != null && player.slot >= 0 && player.slot < length(g_games)) {
        let n = length(player.pixels)
        let mid = n > 0 ? player.pixels[n / 2 + 160] : 0u
        let hasMesh = node?.Mesh != null
        report = "tics={player.ticks} frames={dgv_frames(g_games[player.slot])} digest={dgv_frame_digest(g_games[player.slot])} texture={player.hasTexture} pixels={n} mid={mid} scale={node.localScale} mesh={hasMesh} stopped={player.stopped} {player.reason}"
    }
    return report
}
