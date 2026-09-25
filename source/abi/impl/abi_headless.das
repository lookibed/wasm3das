options gen2
options indenting = 4

module abi_headless shared public

require modules/wasm3das/source/abi/impl/abi_media public
require modules/wasm3das/source/abi/impl/abi_storage public
require modules/wasm3das/source/abi/gen/abi_eden_core public
require modules/wasm3das/source/abi/gen/abi_eden_asset public
require modules/wasm3das/source/abi/gen/abi_eden_video public
require modules/wasm3das/source/abi/gen/abi_eden_input public
require modules/wasm3das/source/abi/gen/abi_eden_audio public
require strings
require math

/*
    abi_headless.das: a complete, engine-free host of the eden_game
    packages. Nothing is drawn or played; everything the guest sends is
    recorded, so the same guest run can be checked locally and inside the
    editor (golden digests, test suites, the golden cheats of the host).

      eden_core   log lines are printed (when `echo`) and kept; time_us is
                  the real clock since the instance was created
      eden_asset  assets the host added with headless_add_asset
      eden_video  every frame converted to RGBA8; the last one is kept, each
                  frame's RGB555 digest (abi_media) appended
      eden_input  the state the driver sets with headless_set_* before a step
      eden_audio  streams validated exactly as the Eden host does; frames
                  counted, the raw bytes digested
      eden_storage  the abi_storage model; namespaces live as long as the
                  script context (no persistence to disk)

    State is per instance id, created by headless_link_all and dropped by
    abi_destroy (headless_link_all registers headless_forget with
    abi_on_destroy).
*/


struct HeadlessStream {
    rate : int = 0
    channels : int = 0
    open : bool = false
}


struct HeadlessState {
    echo : bool = true
    startTicks : int64 = 0l
    logs : array<string>
    assets : table<string; array<uint8>>
    // video
    frames : int = 0
    width : int = 0
    height : int = 0
    lastFrame : array<uint8>        // RGBA8
    digests : array<int>            // frame_digest_rgb555 of each frame
    palette : array<uint8>
    videoErrors : int = 0           // present / set_palette calls that returned an error
    // input
    buttons : int = 0
    keys : array<bool>              // EDEN_INPUT_MAX_SCANCODE + 1 entries
    mouseButtons : int = 0
    mouseDelta : float3 = float3(0)
    // audio
    streams : array<HeadlessStream>  // handle = index + 1
    audioFrames : int64 = 0l
    audioDigest : uint = 0x811c9dc5u
    audioPushes : int = 0
}


var private g_state : table<int; HeadlessState>


def private known(id : int) : bool {
    return g_state |> key_exists(id)
}


// ============================================================================
// eden_core
// ============================================================================


def private core_log(var rt : M3Runtime; inst : int; level : int; message : string) {
    if (!known(inst)) {
        return
    }
    let tag = level == EDEN_CORE_LOG_DEBUG ? "debug" : level == EDEN_CORE_LOG_WARN ? "warn" : level == EDEN_CORE_LOG_ERROR ? "error" : "info"
    let line = "[{tag}] {message}"
    push(g_state[inst].logs, line)
    if (g_state[inst].echo) {
        print("[guest {inst}] {line}\n")
    }
}


def private core_time_us(var rt : M3Runtime; inst : int) : int64 {
    if (!known(inst)) {
        return 0l
    }
    return get_time_nsec(g_state[inst].startTicks) / 1000l
}


def private core_abort(var rt : M3Runtime; inst : int; message : string) {
    abi_trap("guest abort: {message}")
}


// ============================================================================
// eden_asset
// ============================================================================


def private asset_size(var rt : M3Runtime; inst : int; name : string) : int {
    if (!known(inst) || !(g_state[inst].assets |> key_exists(name))) {
        return EDEN_ASSET_ERR_NOT_FOUND
    }
    return length(g_state[inst].assets[name])
}


def private asset_read(var rt : M3Runtime; inst : int; name : string; offset : int; dst : AbiBytes) : int {
    if (!known(inst) || !(g_state[inst].assets |> key_exists(name))) {
        return EDEN_ASSET_ERR_NOT_FOUND
    }
    let size = length(g_state[inst].assets[name])
    if (offset < 0 || offset > size) {
        return EDEN_ASSET_ERR_RANGE
    }
    let n = min(dst.len, size - offset)
    for (i in range(n)) {
        rt.mem[dst.ptr + i] = g_state[inst].assets[name][offset + i]
    }
    return n
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
        g_state[inst].videoErrors++
        return v
    }
    // converted straight into lastFrame, whose capacity is reused frame after
    // frame (no temporary: the heap is only collected between engine frames)
    g_state |> get(inst) $(var s) {
        video_to_rgba(rt, pixels, width, height, stride, format, s.palette, s.lastFrame)
        push(s.digests, frame_digest_rgb555(s.lastFrame))
    }
    g_state[inst].width = width
    g_state[inst].height = height
    g_state[inst].frames++
    return EDEN_VIDEO_OK
}


def private video_set_palette(var rt : M3Runtime; inst : int; colors : AbiBytes) : int {
    if (!known(inst)) {
        return EDEN_VIDEO_ERR_PALETTE
    }
    var pal : array<uint8>
    let v = video_read_palette(rt, colors, pal)
    if (v != EDEN_VIDEO_OK) {
        g_state[inst].videoErrors++
        return v
    }
    g_state[inst].palette <- pal
    return EDEN_VIDEO_OK
}


// ============================================================================
// eden_input
// ============================================================================


def private input_buttons(var rt : M3Runtime; inst : int; pad : int) : int {
    return (known(inst) && pad == 0) ? g_state[inst].buttons : 0
}


def private input_key_down(var rt : M3Runtime; inst : int; scancode : int) : bool {
    if (!known(inst) || scancode < 1 || scancode > EDEN_INPUT_MAX_SCANCODE) {
        return false
    }
    return g_state[inst].keys[scancode]
}


def private input_mouse_buttons(var rt : M3Runtime; inst : int) : int {
    return known(inst) ? g_state[inst].mouseButtons : 0
}


def private input_mouse_delta(var rt : M3Runtime; inst : int; axis : int) : float {
    if (!known(inst)) {
        return 0.0
    }
    if (axis == EDEN_INPUT_AXIS_X) {
        return g_state[inst].mouseDelta.x
    } elif (axis == EDEN_INPUT_AXIS_Y) {
        return g_state[inst].mouseDelta.y
    } elif (axis == EDEN_INPUT_AXIS_WHEEL) {
        return g_state[inst].mouseDelta.z
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
    let count = length(g_state[inst].streams)
    if (stream < 1 || stream > count) {
        return false
    }
    return g_state[inst].streams[stream - 1].open
}


def private audio_open(var rt : M3Runtime; inst : int; rate : int; channels : int) : int {
    if (!known(inst)) {
        return EDEN_AUDIO_ERR_UNAVAILABLE
    }
    if (!audio_valid_stream(rate, channels)) {
        return EDEN_AUDIO_ERR_ARGS
    }
    push(g_state[inst].streams, HeadlessStream(rate = rate, channels = channels, open = true))
    return length(g_state[inst].streams)
}


def private audio_push(var rt : M3Runtime; inst : int; stream : int; samples : AbiBytes; format : int) : int {
    if (!stream_ok(inst, stream)) {
        return EDEN_AUDIO_ERR_HANDLE
    }
    let frames = audio_frame_count(samples, format, g_state[inst].streams[stream - 1].channels)
    if (frames < 0) {
        return frames
    }
    g_state[inst].audioFrames += int64(frames)
    let digest = bytes_digest(rt, samples, g_state[inst].audioDigest)
    g_state[inst].audioDigest = digest
    g_state[inst].audioPushes++
    return frames
}


def private audio_queued(var rt : M3Runtime; inst : int; stream : int) : int {
    return stream_ok(inst, stream) ? 0 : EDEN_AUDIO_ERR_HANDLE
}


def private audio_close(var rt : M3Runtime; inst : int; stream : int) {
    if (stream_ok(inst, stream)) {
        g_state[inst].streams[stream - 1].open = false
    }
}


// ============================================================================
// eden_storage (the abi_storage model; no persistence beyond the process)
// ============================================================================


def private st_size(var rt : M3Runtime; inst : int; name : string) : int {
    return storage_size(storage_namespace(inst), name)
}


def private st_read(var rt : M3Runtime; inst : int; name : string; offset : int; dst : AbiBytes) : int {
    return storage_read(rt, storage_namespace(inst), name, offset, dst)
}


def private st_write(var rt : M3Runtime; inst : int; name : string; data : AbiBytes) : int {
    let ns = storage_namespace(inst)
    let c = storage_check_write(ns, name, data.len)
    if (c != EDEN_STORAGE_OK) {
        return c
    }
    storage_put_from(rt, ns, name, data)
    return EDEN_STORAGE_OK
}


def private st_remove(var rt : M3Runtime; inst : int; name : string) : int {
    let ns = storage_namespace(inst)
    if (!storage_valid_name(name)) {
        return EDEN_STORAGE_ERR_NAME
    }
    if (!storage_has(ns, name)) {
        return EDEN_STORAGE_ERR_NOT_FOUND
    }
    storage_erase(ns, name)
    return EDEN_STORAGE_OK
}


// ============================================================================
// The host API
// ============================================================================


// creates the headless state of an instance (dropped by abi_destroy); the
// headless_link_* functions need it. A host may link only some packages
// headless (the Eden host links core and asset from here)
def public headless_attach(var inst : AbiInstance; echo : bool = true) {
    if (known(inst.id)) {
        if (inst.relinking) {
            abi_on_destroy(inst, @@headless_forget)   // the old function value died with the reload
        }
        return
    }
    var s = HeadlessState()
    s.echo = echo
    s.startTicks = inst.startTicks
    resize(s.keys, EDEN_INPUT_MAX_SCANCODE + 1)
    g_state[inst.id] <- s
    abi_on_destroy(inst, @@headless_forget)
}


def public headless_link_core(var inst : AbiInstance) : M3Result {
    return abi_link_eden_core(inst, EdenCoreHost(log = @@core_log, time_us = @@core_time_us, abort = @@core_abort))
}


def public headless_link_asset(var inst : AbiInstance) : M3Result {
    return abi_link_eden_asset(inst, EdenAssetHost(size = @@asset_size, read = @@asset_read))
}


def public headless_link_video(var inst : AbiInstance) : M3Result {
    return abi_link_eden_video(inst, EdenVideoHost(present = @@video_present, set_palette = @@video_set_palette))
}


def public headless_link_input(var inst : AbiInstance) : M3Result {
    return abi_link_eden_input(inst, EdenInputHost(buttons = @@input_buttons, key_down = @@input_key_down,
                                                   mouse_buttons = @@input_mouse_buttons, mouse_delta = @@input_mouse_delta))
}


def public headless_link_audio(var inst : AbiInstance) : M3Result {
    return abi_link_eden_audio(inst, EdenAudioHost(open = @@audio_open, push = @@audio_push, queued = @@audio_queued, close = @@audio_close))
}


// eden_storage in the namespace `ns` (default: the instance name); blobs
// outlive the instance for the life of the script context
def public headless_link_storage(var inst : AbiInstance; ns : string = "") : M3Result {
    if (!inst.relinking || empty(storage_namespace(inst.id))) {
        storage_bind(inst.id, empty(ns) ? inst.name : ns)
    }
    return abi_link_eden_storage(inst, EdenStorageHost(size = @@st_size, read = @@st_read, write = @@st_write, remove = @@st_remove))
}


// attaches and links the six eden_game packages headless
def public headless_link_all(var inst : AbiInstance; echo : bool = true; ns : string = "") : M3Result {
    headless_attach(inst, echo)
    var r = headless_link_core(inst)
    if (r == m3Err_none) {
        r = headless_link_asset(inst)
    }
    if (r == m3Err_none) {
        r = headless_link_video(inst)
    }
    if (r == m3Err_none) {
        r = headless_link_input(inst)
    }
    if (r == m3Err_none) {
        r = headless_link_audio(inst)
    }
    if (r == m3Err_none) {
        r = headless_link_storage(inst, ns)
    }
    return r
}


// re-links an instance linked with headless_link_all after a hot reload;
// other packages the host linked must be relinked between the
// abi_relink_begin / abi_relink_end this does not cover, so this is for
// instances with the eden_game packages only
def public headless_relink_all(var inst : AbiInstance) : M3Result {
    abi_relink_begin(inst)
    let r = headless_link_all(inst)
    let e = abi_relink_end(inst)
    return r != m3Err_none ? r : e
}


def public headless_forget(id : int) {
    g_state |> erase(id)
    storage_unbind(id)
}


def public headless_add_asset(id : int; name : string; bytes : array<uint8>) {
    if (known(id)) {
        g_state[id].assets[name] := bytes
    }
}


def public headless_set_buttons(id : int; mask : int) {
    if (known(id)) {
        g_state[id].buttons = mask
    }
}


def public headless_set_key(id : int; scancode : int; down : bool) {
    if (known(id) && scancode >= 1 && scancode <= EDEN_INPUT_MAX_SCANCODE) {
        g_state[id].keys[scancode] = down
    }
}


def public headless_set_mouse(id : int; buttons : int; delta : float3) {
    if (known(id)) {
        g_state[id].mouseButtons = buttons
        g_state[id].mouseDelta = delta
    }
}


def public headless_frames(id : int) : int {
    return known(id) ? g_state[id].frames : 0
}


def public headless_digests(id : int) : array<int> {
    var out : array<int>
    if (known(id)) {
        out := g_state[id].digests
    }
    return <- out
}


def public headless_last_frame(id : int; var o_rgba : array<uint8>; var o_width : int&; var o_height : int&) {
    clear(o_rgba)
    o_width = 0
    o_height = 0
    if (known(id)) {
        o_rgba := g_state[id].lastFrame
        o_width = g_state[id].width
        o_height = g_state[id].height
    }
}


def public headless_video_errors(id : int) : int {
    return known(id) ? g_state[id].videoErrors : 0
}


def public headless_logs(id : int) : array<string> {
    var out : array<string>
    if (known(id)) {
        out := g_state[id].logs
    }
    return <- out
}


def public headless_audio(id : int; var o_frames : int64&; var o_digest : uint&; var o_pushes : int&; var o_streams : int&) {
    o_frames = 0l
    o_digest = 0u
    o_pushes = 0
    o_streams = 0
    if (known(id)) {
        o_frames = g_state[id].audioFrames
        o_digest = g_state[id].audioDigest
        o_pushes = g_state[id].audioPushes
        o_streams = length(g_state[id].streams)
    }
}


def public headless_stream_format(id : int; stream : int; var o_rate : int&; var o_channels : int&) : bool {
    o_rate = 0
    o_channels = 0
    if (!known(id) || stream < 1 || stream > length(g_state[id].streams)) {
        return false
    }
    o_rate = g_state[id].streams[stream - 1].rate
    o_channels = g_state[id].streams[stream - 1].channels
    return true
}
