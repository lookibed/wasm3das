options gen2
options indenting = 4

module abi_eden_host shared public

require engine.core
require modules/wasm3das/source/abi/impl/abi_headless public
require strings
require math
require daslib/enum_trait    // each(enum value): every KeyCode
require daslib/base64        // eden_storage blobs as strings of the engine's local storage

/*
    abi_eden_host.das: the EdenSpark host of the eden_game packages
    (docs/eden-abi/ABI.md). Editor only: it needs the engine, so the local
    compilers never see it; the editor compiles it with the project.

      eden_core, eden_asset  the headless implementations (log to the
                             console, real clock, assets the host adds with
                             headless_add_asset)
      eden_video             frames converted with abi_media into a Bitmap,
                             uploaded to a texture (Point filter, Clamp);
                             eden_host_texture gives it to the view
      eden_input             pad 0 from the action set "eden_abi_pad"
                             (keyboard and gamepad, table below); keys by
                             set-1 scan code (= Eden KeyCode values) and the
                             mouse from the action sets "eden_abi_keys" and
                             "eden_abi_mouse" (ensure_pad has why)
      eden_audio             play_sound_stream + append_to_stream per stream
      eden_storage           the abi_storage model, persisted with
                             save_storage / load_storage (engine limits:
                             5 MB per storage, 20 storages per game)

    Pad bindings (keyboard / gamepad):
        A       X          / A          B      Z          / B
        Select  Backspace  / Back       Start  Return     / Y
        D-pad   arrows     / d-pad      X      A          / X
        Y       S          / (none)     L      Q          / LB
        R       W          / RB
*/


struct EdenStream {
    handle : SoundHandle
    rate : int = 0
    channels : int = 0
    open : bool = false
    batches : array<int>     // frames of each appended batch, oldest first
}


struct EdenView {
    bitmap : Bitmap
    textureId : TextureId
    hasTexture : bool = false
    width : int = 0
    height : int = 0
    frames : int = 0
    digest : bool = false    // compute frame_digest_rgb555 of each frame
    rgba : array<uint8>      // the conversion buffer of the last frame
    lastDigest : int = 0
    palette : array<uint8>
    streams : array<EdenStream>
}


var private g_views : table<int; EdenView>
var private g_padReady = false
var private g_keyCodes : table<int; KeyCode>


let private PAD_ACTIONS = fixed_array("pad_a", "pad_b", "pad_select", "pad_start", "pad_right", "pad_left", "pad_up", "pad_down",
                                      "pad_x", "pad_y", "pad_l", "pad_r")


def private known(id : int) : bool {
    return g_views |> key_exists(id)
}


// ============================================================================
// eden_video
// ============================================================================


def private video_present(var rt : M3Runtime; inst : int; pixels : AbiBytes; width : int; height : int; stride : int; format : int) : int {
    if (!known(inst)) {
        return EDEN_VIDEO_ERR_SIZE
    }
    let v = video_validate(pixels, width, height, stride, format)
    if (v != EDEN_VIDEO_OK) {
        return v
    }
    g_views |> get(inst) $(var view) {
        // the conversion buffer is kept in the view and reused every frame
        video_to_rgba(rt, pixels, width, height, stride, format, view.palette, view.rgba)
        if (!view.hasTexture || view.width != width || view.height != height) {
            var blank : array<uint>
            resize(blank, width * height)
            view.textureId = create_texture(width, height, blank, TextureDeclaration(
                filter = TextureFilter.Point,
                generateMipLevels = false,
                addressing = TextureAddress.Clamp
            ))
            view.bitmap <- Bitmap(width, height)
            view.width = width
            view.height = height
            view.hasTexture = true
        }
        // Bitmap pixels are 0xAARRGGBB (measured: RGBA bytes packed with R
        // in the low byte showed yellow as cyan)
        let n = width * height
        for (i in range(n)) {
            let at = i * 4
            view.bitmap.pixels[i] = uint(view.rgba[at + 2]) | (uint(view.rgba[at + 1]) << 8u) | (uint(view.rgba[at]) << 16u) | (uint(view.rgba[at + 3]) << 24u)
        }
        update_texture(view.bitmap, view.textureId)
        if (view.digest) {
            view.lastDigest = frame_digest_rgb555(view.rgba)
        }
        view.frames++
    }
    return EDEN_VIDEO_OK
}


def private video_set_palette(var rt : M3Runtime; inst : int; colors : AbiBytes) : int {
    if (!known(inst)) {
        return EDEN_VIDEO_ERR_PALETTE
    }
    var pal : array<uint8>
    let v = video_read_palette(rt, colors, pal)
    if (v == EDEN_VIDEO_OK) {
        g_views[inst].palette <- pal
    }
    return v
}


// ============================================================================
// eden_input
// ============================================================================


def private kb(key : KeyCode) : array<KeyboardButtonInput> {
    var out : array<KeyboardButtonInput>
    push(out, KeyboardButtonInput(idx = key))
    return <- out
}


def private gp(button : GamepadButton) : array<GamepadButtonInput> {
    var out : array<GamepadButtonInput>
    push(out, GamepadButtonInput(idx = button))
    return <- out
}


def private mb(button : MouseButton) : array<MouseButtonInput> {
    var out : array<MouseButtonInput>
    push(out, MouseButtonInput(idx = button))
    return <- out
}


def private mouse_axis(axis : MouseMoveAxis) : array<MouseMoveAxisInput> {
    var out : array<MouseMoveAxisInput>
    push(out, MouseMoveAxisInput(idx = axis, sensitivity = 1.0))
    return <- out
}


// All input goes through action sets: engine.input.global_input_state is
// deprecated in EdenSpark 1.0 and a deprecated call fails the export of a
// game ("It will prevent publishing the game", measured on 1.0.0.19).
//   eden_abi_pad    the BUTTON_* pad (keyboard and gamepad)
//   eden_abi_keys   one button action "key_<scancode>" per KeyCode (set-1
//                   scan codes), queried with ModifierMatchMode.Weak so a
//                   held Shift does not hide the other keys
//   eden_abi_mouse  buttons and the raw movement / wheel axes
def private ensure_pad() {
    if (g_padReady) {
        return
    }
    g_padReady = true
    var keys : ActionSet
    for (k in each(KeyCode.A)) {
        let code = int(k)
        if (code >= 1 && code <= EDEN_INPUT_MAX_SCANCODE && !(keys |> key_exists("key_{code}"))) {
            keys["key_{code}"] = Action(buttonActions = ButtonAction(keyboardButtons <- kb(k)))
            g_keyCodes[code] = k
        }
    }
    add_and_activate_action_set("eden_abi_keys", keys)
    add_and_activate_action_set("eden_abi_mouse", {
        "mouse_left" => Action(buttonActions = ButtonAction(mouseButtons <- mb(MouseButton.Left))),
        "mouse_right" => Action(buttonActions = ButtonAction(mouseButtons <- mb(MouseButton.Right))),
        "mouse_middle" => Action(buttonActions = ButtonAction(mouseButtons <- mb(MouseButton.Middle))),
        "mouse_dx" => Action(axisActions = AxisAction(mouseMoveAxis <- mouse_axis(MouseMoveAxis.Horizontal))),
        "mouse_dy" => Action(axisActions = AxisAction(mouseMoveAxis <- mouse_axis(MouseMoveAxis.Vertical))),
        "mouse_wheel" => Action(axisActions = AxisAction(mouseMoveAxis <- mouse_axis(MouseMoveAxis.Wheel)))
    })
    add_and_activate_action_set("eden_abi_pad", {
        "pad_a" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.X), gamepadButtons <- gp(GamepadButton.A))),
        "pad_b" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Z), gamepadButtons <- gp(GamepadButton.B))),
        "pad_select" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Back), gamepadButtons <- gp(GamepadButton.Back))),
        "pad_start" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Return), gamepadButtons <- gp(GamepadButton.Y))),
        "pad_right" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Right), gamepadButtons <- gp(GamepadButton.Right))),
        "pad_left" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Left), gamepadButtons <- gp(GamepadButton.Left))),
        "pad_up" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Up), gamepadButtons <- gp(GamepadButton.Up))),
        "pad_down" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Down), gamepadButtons <- gp(GamepadButton.Down))),
        "pad_x" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.A), gamepadButtons <- gp(GamepadButton.X))),
        "pad_y" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.S))),
        "pad_l" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.Q), gamepadButtons <- gp(GamepadButton.LeftBumper))),
        "pad_r" => Action(buttonActions = ButtonAction(keyboardButtons <- kb(KeyCode.W), gamepadButtons <- gp(GamepadButton.RightBumper)))
    })
}


def private input_buttons(var rt : M3Runtime; inst : int; pad : int) : int {
    if (pad != 0) {
        return 0
    }
    var mask = 0
    for (name, i in PAD_ACTIONS, count()) {
        if (is_action_pressed(name)) {
            mask |= 1 << i
        }
    }
    return mask
}


def private input_key_down(var rt : M3Runtime; inst : int; scancode : int) : bool {
    if (scancode < 1 || scancode > EDEN_INPUT_MAX_SCANCODE || !(g_keyCodes |> key_exists(scancode))) {
        return false
    }
    return is_action_pressed("key_{scancode}", ModifierMatchMode.Weak)
}


def private input_mouse_buttons(var rt : M3Runtime; inst : int) : int {
    var mask = 0
    if (is_action_pressed("mouse_left", ModifierMatchMode.Weak)) {
        mask |= EDEN_INPUT_MOUSE_LEFT
    }
    if (is_action_pressed("mouse_right", ModifierMatchMode.Weak)) {
        mask |= EDEN_INPUT_MOUSE_RIGHT
    }
    if (is_action_pressed("mouse_middle", ModifierMatchMode.Weak)) {
        mask |= EDEN_INPUT_MOUSE_MIDDLE
    }
    return mask
}


def private input_mouse_delta(var rt : M3Runtime; inst : int; axis : int) : float {
    if (axis == EDEN_INPUT_AXIS_X) {
        return get_action_axis("mouse_dx")
    } elif (axis == EDEN_INPUT_AXIS_Y) {
        return get_action_axis("mouse_dy")
    } elif (axis == EDEN_INPUT_AXIS_WHEEL) {
        return get_action_axis("mouse_wheel")
    }
    return 0.0
}


// ============================================================================
// eden_audio
// ============================================================================


def private stream_ok(inst : int; stream : int) : bool {
    if (!known(inst)) {
        return false
    }
    let count = length(g_views[inst].streams)
    if (stream < 1 || stream > count) {
        return false
    }
    return g_views[inst].streams[stream - 1].open
}


def private audio_open(var rt : M3Runtime; inst : int; rate : int; channels : int) : int {
    if (!known(inst) || !is_audio_active()) {
        return EDEN_AUDIO_ERR_UNAVAILABLE
    }
    if (!audio_valid_stream(rate, channels)) {
        return EDEN_AUDIO_ERR_ARGS
    }
    var s = EdenStream()
    s.handle = play_sound_stream(rate, channels)
    s.rate = rate
    s.channels = channels
    s.open = true
    g_views[inst].streams |> emplace(s)
    return length(g_views[inst].streams)
}


def private audio_push(var rt : M3Runtime; inst : int; stream : int; samples : AbiBytes; format : int) : int {
    if (!stream_ok(inst, stream)) {
        return EDEN_AUDIO_ERR_HANDLE
    }
    let frames = audio_frame_count(samples, format, g_views[inst].streams[stream - 1].channels)
    if (frames <= 0) {
        return frames
    }
    var inscope floats : array<float>
    audio_to_float(rt, samples, format, floats)
    let handle = g_views[inst].streams[stream - 1].handle
    append_to_stream(handle, floats)
    push(g_views[inst].streams[stream - 1].batches, frames)
    return frames
}


// frames of the batches the engine still holds
def private audio_queued(var rt : M3Runtime; inst : int; stream : int) : int {
    if (!stream_ok(inst, stream)) {
        return EDEN_AUDIO_ERR_HANDLE
    }
    let handle = g_views[inst].streams[stream - 1].handle
    let pending = get_stream_queue(handle)
    let count = length(g_views[inst].streams[stream - 1].batches)
    let drop = max(count - pending, 0)
    if (drop > 0) {
        erase(g_views[inst].streams[stream - 1].batches, 0, drop)
    }
    var total = 0
    for (b in g_views[inst].streams[stream - 1].batches) {
        total += b
    }
    return total
}


def private audio_close(var rt : M3Runtime; inst : int; stream : int) {
    if (stream_ok(inst, stream)) {
        let handle = g_views[inst].streams[stream - 1].handle
        stop(handle)
        g_views[inst].streams[stream - 1].open = false
    }
}


// ============================================================================
// eden_storage: the abi_storage model, persisted in the engine's local
// storage (one storage "abi_<namespace>" per namespace, each blob a base64
// string under the key "b:<name>", the names listed under "names")
// ============================================================================


def private engine_storage_name(ns : string) : string {
    let clean = build_string() $(var w) {
        for (i in range(length(ns))) {
            let c = character_at(ns, i)
            let ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
            write_char(w, ok ? c : '_')
        }
    }
    return "abi_{clean}"
}


def private ensure_loaded(ns : string) {
    if (storage_is_loaded(ns)) {
        return
    }
    var blobs : table<string; array<uint8>>
    // the blob names are listed under "names": keys() of a GenericStorage
    // does not compile inside the engine (0.9.0.34, generic_storage.das:69)
    var data <- load_storage(engine_storage_name(ns))
    var names : array<string>
    get(data, "names", names)
    for (name in names) {
        var text = ""
        if (get(data, "b:{name}", text)) {
            var bytes : array<uint8>
            base64_decode(text, bytes)
            blobs[name] <- bytes
        } else {
            print("[abi eden_storage] {engine_storage_name(ns)}: blob {name} listed but missing\n")
        }
    }
    storage_set_loaded(ns, blobs)
}


def private persist(ns : string) : bool {
    var data : GenericStorage
    var names : array<string>
    storage_each(ns) $(name, bytes) {
        set(data, "b:{name}", base64_encode(bytes))
        push(names, name)
    }
    let count = length(names)
    set(data, "names", names)
    if (count == 0) {
        remove_storage(engine_storage_name(ns))
        return true
    }
    let r = save_storage(data, engine_storage_name(ns))
    if (r != SaveStorageResult.Success) {
        print("[abi eden_storage] saving {engine_storage_name(ns)} failed: {r}\n")
    }
    return r == SaveStorageResult.Success
}


def private st_size(var rt : M3Runtime; inst : int; name : string) : int {
    let ns = storage_namespace(inst)
    ensure_loaded(ns)
    return storage_size(ns, name)
}


def private st_read(var rt : M3Runtime; inst : int; name : string; offset : int; dst : AbiBytes) : int {
    let ns = storage_namespace(inst)
    ensure_loaded(ns)
    return storage_read(rt, ns, name, offset, dst)
}


def private st_write(var rt : M3Runtime; inst : int; name : string; data : AbiBytes) : int {
    let ns = storage_namespace(inst)
    ensure_loaded(ns)
    let c = storage_check_write(ns, name, data.len)
    if (c != EDEN_STORAGE_OK) {
        return c
    }
    let existed = storage_has(ns, name)
    var old <- storage_copy(ns, name)
    storage_put_from(rt, ns, name, data)
    if (!persist(ns)) {
        if (existed) {
            storage_put(ns, name, old)
        } else {
            storage_erase(ns, name)
        }
        return EDEN_STORAGE_ERR_IO
    }
    return EDEN_STORAGE_OK
}


def private st_remove(var rt : M3Runtime; inst : int; name : string) : int {
    let ns = storage_namespace(inst)
    ensure_loaded(ns)
    if (!storage_valid_name(name)) {
        return EDEN_STORAGE_ERR_NAME
    }
    if (!storage_has(ns, name)) {
        return EDEN_STORAGE_ERR_NOT_FOUND
    }
    var old <- storage_copy(ns, name)
    storage_erase(ns, name)
    if (!persist(ns)) {
        storage_put(ns, name, old)
        return EDEN_STORAGE_ERR_IO
    }
    return EDEN_STORAGE_OK
}


// ============================================================================
// The host API
// ============================================================================


def private eden_host_forget(id : int) {
    if (!known(id)) {
        return
    }
    for (s in g_views[id].streams) {
        if (s.open) {
            stop(s.handle)
        }
    }
    g_views |> erase(id)
}


// re-links a live instance after a hot reload of the scripts (ABI.md 7):
// the guest keeps its memory and state
def public eden_host_relink(var inst : AbiInstance) : M3Result {
    abi_relink_begin(inst)
    let r = eden_host_link(inst)
    let e = abi_relink_end(inst)
    return r != m3Err_none ? r : e
}


// links the six eden_game packages for play inside Eden; eden_storage
// persists in the namespace `ns` (default: the instance name)
def public eden_host_link(var inst : AbiInstance; echo : bool = true; ns : string = "") : M3Result {
    ensure_pad()
    headless_attach(inst, echo)
    if (!inst.relinking || empty(storage_namespace(inst.id))) {
        storage_bind(inst.id, empty(ns) ? inst.name : ns)
    }
    if (!known(inst.id)) {
        g_views[inst.id] <- EdenView()
        abi_on_destroy(inst, @@eden_host_forget)
    } elif (inst.relinking) {
        abi_on_destroy(inst, @@eden_host_forget)   // the old function value died with the reload
    }
    var r = headless_link_core(inst)
    if (r == m3Err_none) {
        r = headless_link_asset(inst)
    }
    if (r == m3Err_none) {
        r = abi_link_eden_video(inst, EdenVideoHost(present = @@video_present, set_palette = @@video_set_palette))
    }
    if (r == m3Err_none) {
        r = abi_link_eden_input(inst, EdenInputHost(buttons = @@input_buttons, key_down = @@input_key_down,
                                                    mouse_buttons = @@input_mouse_buttons, mouse_delta = @@input_mouse_delta))
    }
    if (r == m3Err_none) {
        r = abi_link_eden_audio(inst, EdenAudioHost(open = @@audio_open, push = @@audio_push, queued = @@audio_queued, close = @@audio_close))
    }
    if (r == m3Err_none) {
        r = abi_link_eden_storage(inst, EdenStorageHost(size = @@st_size, read = @@st_read, write = @@st_write, remove = @@st_remove))
    }
    return r
}


def public eden_host_has_frame(id : int) : bool {
    return known(id) && g_views[id].hasTexture
}


def public eden_host_texture(id : int) : TextureId {
    var tex : TextureId
    if (known(id)) {
        tex = g_views[id].textureId
    }
    return tex
}


def public eden_host_frame_size(id : int) : int2 {
    var size = int2(0, 0)
    g_views |> get(id) $(view) {
        size = int2(view.width, view.height)
    }
    return size
}


def public eden_host_frames(id : int) : int {
    return known(id) ? g_views[id].frames : 0
}


def public eden_host_set_digest(id : int; on : bool) {
    if (known(id)) {
        g_views[id].digest = on
    }
}


// the pad 0 mask eden_input.buttons answers now (probes and checks)
def public eden_host_pad_buttons() : int {
    ensure_pad()
    var rt = M3Runtime()
    return input_buttons(rt, 0, 0)
}


// whether the key with this scan code is down, as eden_input.key_down answers
def public eden_host_key_down(scancode : int) : bool {
    ensure_pad()
    var rt = M3Runtime()
    return input_key_down(rt, 0, scancode)
}


// the Bitmap pixel (0xAARRGGBB) at x, y of the last frame; 0 when none
def public eden_host_pixel(id : int; x : int; y : int) : uint {
    var p = 0u
    g_views |> get(id) $(view) {
        if (view.hasTexture && x >= 0 && y >= 0 && x < view.width && y < view.height) {
            p = view.bitmap.pixels[y * view.width + x]
        }
    }
    return p
}


def public eden_host_last_digest(id : int) : int {
    return known(id) ? g_views[id].lastDigest : 0
}
