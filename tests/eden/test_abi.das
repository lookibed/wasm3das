options gen2
options indenting = 4

module test_abi shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/abi/abi_game
require modules/wasm3das/source/abi/gen/abi_abi_selftest
require modules/wasm3das/source/abi/impl/abi_headless
require strings
require math

/*
    test_abi.das: the Eden guest ABI (docs/eden-abi/ABI.md) end to end, with
    the round-trip guest guests/build/abi_selftest.wasm (fixture
    "abi/build/abi_selftest.wasm") on the headless host.

    Every rule of ABI.md has a check here: marshalling of each type in both
    directions (2, 3), unresolved and foreign imports (2), null
    implementations, the memory budget at load and at growth (4), traps and
    the faulted state (5), re-entrancy (6), the game loop over the five
    packages, snapshots, and destroy (7).
*/


let SELFTEST = "abi/build/abi_selftest.wasm"


// ============================================================================
// The abi_test host double
// ============================================================================


var private g_records : array<string>
var private g_handles : array<int>
var private g_reenterResult = -1
var private g_reenterError = ""
var private g_reenterWanted = false
var private g_inst = AbiInstance()   // the instance the reenter check calls back into


def private t_echo_i32(var rt : M3Runtime; inst : int; v : int) : int {
    return v
}


def private t_echo_i64(var rt : M3Runtime; inst : int; v : int64) : int64 {
    return v
}


def private t_echo_f32(var rt : M3Runtime; inst : int; v : float) : float {
    return v
}


def private t_echo_f64(var rt : M3Runtime; inst : int; v : double) : double {
    return v
}


def private t_negate(var rt : M3Runtime; inst : int; v : bool) : bool {
    return !v
}


def private t_mix(var rt : M3Runtime; inst : int; a : int; b : int64; c : float; d : double; e : bool) : double {
    return double(a) + double(b) + double(c) + d + (e ? 1.0lf : 0.0lf)
}


def private t_str_len(var rt : M3Runtime; inst : int; s : string) : int {
    return length(s)
}


def private t_bytes_sum(var rt : M3Runtime; inst : int; b : AbiBytes) : int {
    var sum = 0
    for (i in range(b.len)) {
        sum += int(abi_byte(rt, b, i))
    }
    return sum
}


def private t_fill(var rt : M3Runtime; inst : int; dst : AbiBytes; seed : int) : int {
    for (i in range(dst.len)) {
        abi_set_byte(rt, dst, i, uint8((seed + i) & 255))
    }
    return dst.len
}


def private t_make_handle(var rt : M3Runtime; inst : int; v : int) : int {
    push(g_handles, v)
    return length(g_handles)
}


def private t_handle_value(var rt : M3Runtime; inst : int; h : int) : int {
    if (h < 1 || h > length(g_handles)) {
        return -1
    }
    return g_handles[h - 1]
}


def private t_fail(var rt : M3Runtime; inst : int) {
    abi_trap("requested")
}


def private t_record(var rt : M3Runtime; inst : int; s : string) {
    push(g_records, s)
    if (s == "reenter" && g_reenterWanted) {
        // the host tries to call the guest while the guest calls the host
        g_reenterResult = int(abi_selftest_i64(g_inst, 5l))
        g_reenterError = g_inst.error
        g_inst.error = ""
    }
}


// the abi_test implementation (also used by eden/abi_host_check.das)
def public abi_test_double() : AbiTestHost {
    return test_host()
}


def private test_host() : AbiTestHost {
    return AbiTestHost(echo_i32 = @@t_echo_i32, echo_i64 = @@t_echo_i64, echo_f32 = @@t_echo_f32, echo_f64 = @@t_echo_f64,
                       negate = @@t_negate, mix = @@t_mix, str_len = @@t_str_len, bytes_sum = @@t_bytes_sum,
                       fill = @@t_fill, make_handle = @@t_make_handle, handle_value = @@t_handle_value,
                       fail = @@t_fail, record = @@t_record)
}


// instantiate + headless + abi_test + bind abi_selftest; "" on success
def private open_selftest(bytes : array<uint8>; var inst : AbiInstance; config : AbiConfig = AbiConfig()) : string {
    inst <- abi_instantiate(bytes, "selftest", config)
    if (!inst.alive) {
        return inst.error
    }
    var r = headless_link_all(inst, false)
    if (r == m3Err_none) {
        r = abi_link_abi_test(inst, test_host())
    }
    if (r == m3Err_none) {
        r = abi_bind_abi_selftest(inst)
    }
    return r
}


def private data_asset() : array<uint8> {
    var data : array<uint8>
    for (i in range(5)) {
        push(data, uint8(i + 1))
    }
    return <- data
}


// ============================================================================
// Tests
// ============================================================================


def test_abi_instantiate_errors(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_instantiate_errors")
    var junk : array<uint8>
    push(junk, 1u8)
    push(junk, 2u8)
    var bad <- abi_instantiate(junk, "junk")
    check(t, !bad.alive, "junk bytes do not instantiate")
    check(t, find(bad.error, "parse failed") >= 0, "junk: parse error reported ({bad.error})")
    let bytes <- load_fixture(fx, SELFTEST)
    check(t, length(bytes) > 0, "fixture {SELFTEST} present")
    var small <- abi_instantiate(bytes, "small", AbiConfig(maxMemoryBytes = 65536l))
    check(t, !small.alive, "5 initial pages refused under a 1-page budget")
    check(t, find(small.error, "exceeds the budget of 65536") >= 0, "budget error names the budget ({small.error})")
}


def test_abi_link_rules(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_link_rules")
    let bytes <- load_fixture(fx, SELFTEST)
    // abi_test not linked: every abi_test import is reported, none stubbed
    var a <- abi_instantiate(bytes, "no_test_pkg")
    check(t, a.alive, "instantiates")
    is_ok(t, headless_link_all(a, false), "headless links")
    let unresolved = abi_bind_abi_selftest(a)
    check(t, find(unresolved, "unresolved imports") >= 0, "bind refuses unresolved imports ({unresolved})")
    check(t, find(unresolved, "abi_test.echo_i32 (package not linked by the host)") >= 0, "names abi_test.echo_i32")
    check(t, find(unresolved, "abi_test.fail (package not linked by the host)") >= 0, "names abi_test.fail")
    check(t, find(unresolved, "eden_") < 0, "linked packages are not reported")
    abi_destroy(a)
    // abi_test linked, but the world is eden_game: foreign package
    var b <- abi_instantiate(bytes, "foreign")
    is_ok(t, headless_link_all(b, false), "headless links")
    is_ok(t, abi_link_abi_test(b, test_host()), "abi_test links")
    let foreign = abi_bind_eden_game(b)
    check(t, find(foreign, "abi_test.mix (package not in world eden_game)") >= 0, "bind eden_game refuses abi_test imports ({foreign})")
    // linking twice is refused
    let twice = abi_link_abi_test(b, test_host())
    check(t, find(twice, "already linked") >= 0, "a package links once ({twice})")
    abi_destroy(b)
    // a null implementation is refused before anything is linked
    var c <- abi_instantiate(bytes, "null_impl")
    // every function but fill
    let partial = AbiTestHost(echo_i32 = @@t_echo_i32, echo_i64 = @@t_echo_i64, echo_f32 = @@t_echo_f32, echo_f64 = @@t_echo_f64,
                              negate = @@t_negate, mix = @@t_mix, str_len = @@t_str_len, bytes_sum = @@t_bytes_sum,
                              make_handle = @@t_make_handle, handle_value = @@t_handle_value,
                              fail = @@t_fail, record = @@t_record)
    let refused = abi_link_abi_test(c, partial)
    check(t, find(refused, "abi_test.fill has no host implementation") >= 0, "null function refused ({refused})")
    check(t, !abi_is_linked(c, "abi_test"), "nothing registered after a refused link")
    abi_destroy(c)
}


def test_abi_imports_roundtrip(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_imports_roundtrip")
    let bytes <- load_fixture(fx, SELFTEST)
    var inst = AbiInstance()
    is_ok(t, open_selftest(bytes, inst), "open selftest")
    clear(g_records)
    clear(g_handles)
    let bad = abi_selftest_run_imports(inst)
    equal_str(t, inst.error, "", "run_imports ran")
    equal(t, bad, 0, "every import answered as the guest expected")
    check(t, length(g_records) == 1 && g_records[0] == "imports done", "abi_test.record received the string")
    equal(t, length(g_handles), 2, "two handles made")
    let logs <- headless_logs(inst.id)
    var printed = ""
    for (l in logs) {
        if (find(l, "selftest: printf") >= 0) {
            printed = l
        }
    }
    equal_str(t, printed, "[info] selftest: printf -12 str 03.14 ff 18446744073709551615|ab  |", "printf -> eden_core.log line")
    abi_destroy(inst)
}


def test_abi_exports_roundtrip(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_exports_roundtrip")
    let bytes <- load_fixture(fx, SELFTEST)
    var inst = AbiInstance()
    is_ok(t, open_selftest(bytes, inst), "open selftest")
    equal(t, abi_selftest_take_str(inst, "héllo"), 104006, "str: 6 UTF-8 bytes, first 'h'")
    equal(t, abi_selftest_take_str(inst, ""), 0, "str: empty")
    var b : array<uint8>
    push(b, 1u8)
    push(b, 2u8)
    push(b, 3u8)
    push(b, 255u8)
    equal(t, abi_selftest_take_bytes(inst, b), 261, "bytes")
    var empty_bytes : array<uint8>
    equal(t, abi_selftest_take_bytes(inst, empty_bytes), 0, "bytes: empty")
    equal(t, abi_selftest_scalars(inst, 1, 2l, 0.5, 0.25lf, true), 4.75lf, "every scalar type as arguments")
    equal(t, abi_selftest_i64(inst, -7000000000l), -21000000000l, "i64 both ways")
    equal(t, abi_selftest_f32(inst, 3.0), 1.5, "f32 both ways")
    equal_str(t, inst.error, "", "no error so far")
    check(t, !abi_has_export(inst, "selftest_missing"), "an optional export the guest lacks is absent")
    var noArgs : array<uint64>
    var noRets : array<uint64>
    let missing = abi_call(inst, "selftest_missing", noArgs, noRets)
    check(t, !missing && find(inst.error, "export not provided: selftest_missing") >= 0, "calling it fails cleanly ({inst.error})")
    check(t, !inst.faulted, "a missing export does not fault the instance")
    // many placements: the guest allocator reuses freed blocks
    var big : array<uint8>
    resize(big, 100000)
    for (i in range(100000)) {
        big[i] = uint8(i & 7)
    }
    var ok = true
    for (round in range(20)) {
        ok = ok && abi_selftest_take_bytes(inst, big) == 350000
    }
    check(t, ok && empty(inst.error), "20 placements of 100 KB")
    check(t, length(inst.rt.mem) < 2 * 1048576, "freed placements are reused (linear memory {length(inst.rt.mem)} bytes)")
    abi_destroy(inst)
}


def test_abi_trap_and_fault(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_trap_and_fault")
    let bytes <- load_fixture(fx, SELFTEST)
    var inst = AbiInstance()
    is_ok(t, open_selftest(bytes, inst), "open selftest")
    let r = abi_selftest_trap(inst)
    equal(t, r, 0, "a trapped call returns the default")
    check(t, inst.faulted, "the instance is faulted")
    check(t, find(inst.error, "[trap] abi_test.fail: requested") >= 0, "the trap names package, function and message ({inst.error})")
    let after = abi_selftest_i64(inst, 1l)
    equal(t, after, 0l, "a faulted instance refuses calls")
    check(t, find(inst.error, "[trap] abi_test.fail") >= 0, "and keeps the trap as its error")
    abi_destroy(inst)
    // bad (ptr, len) arguments trap in the generated wrapper, before the
    // implementation runs
    var wants : array<string>
    push(wants, "[trap] abi_test.str_len: s: range [2147483632, 2147483696) outside linear memory")
    push(wants, "[trap] abi_test.bytes_sum: b: negative length -1")
    push(wants, "[trap] abi_test.str_len: s: string contains a NUL byte at 1")
    for (which in range(3)) {
        var bad = AbiInstance()
        is_ok(t, open_selftest(bytes, bad), "open selftest for bad pointer {which}")
        let got = abi_selftest_bad_pointer(bad, which)
        check(t, got == 0 && bad.faulted, "bad pointer {which} faults the instance")
        check(t, find(bad.error, wants[which]) >= 0, "bad pointer {which}: {bad.error}")
        abi_destroy(bad)
    }
}


def test_abi_reentrancy(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_reentrancy")
    let bytes <- load_fixture(fx, SELFTEST)
    is_ok(t, open_selftest(bytes, g_inst), "open selftest")
    g_reenterWanted = true
    g_reenterResult = -1
    g_reenterError = ""
    let r = abi_selftest_reenter(g_inst)
    g_reenterWanted = false
    equal(t, r, 7, "the outer call completes")
    equal(t, g_reenterResult, 0, "the nested call returned the default")
    check(t, find(g_reenterError, "reentrant call: selftest_i64 while selftest_reenter runs") >= 0, "and was refused ({g_reenterError})")
    check(t, !g_inst.faulted, "the refusal does not fault the instance")
    equal(t, abi_selftest_i64(g_inst, 5l), 15l, "calls work again after the outer call")
    abi_destroy(g_inst)
}


def test_abi_game_loop(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_game_loop")
    let bytes <- load_fixture(fx, SELFTEST)
    var inst = AbiInstance()
    is_ok(t, open_selftest(bytes, inst), "open selftest")
    let noAsset = game_start(inst)
    check(t, find(noAsset, "eden_init returned 1") >= 0, "init without the asset fails with the guest's code ({noAsset})")
    abi_destroy(inst)

    var game = AbiInstance()
    is_ok(t, open_selftest(bytes, game), "open selftest")
    let data <- data_asset()
    headless_add_asset(game.id, "data", data)
    equal_str(t, game_start(game), "", "init with the asset")
    var rate = 0
    var channels = 0
    check(t, headless_stream_format(game.id, 1, rate, channels) && rate == 22050 && channels == 2, "audio stream 1 opened at 22050 Hz stereo")
    // frame 0: RGBA8 with buttons = 1 (key 0x1e down with it)
    headless_set_buttons(game.id, 1)
    headless_set_key(game.id, 30, true)   // 0x1e, scan code of A
    let f0 = game_frame(game, 1000000, 4)
    equal(t, f0, EDEN_GAME_STEP_FRAME, "frame 0 presented")
    var rgba : array<uint8>
    var w = 0
    var h = 0
    headless_last_frame(game.id, rgba, w, h)
    check(t, w == 4 && h == 2 && length(rgba) == 32, "RGBA8 4x2")
    check(t, rgba[0] == 1u8 && rgba[4] == 11u8 && rgba[1] == 15u8 && rgba[2] == 200u8 && rgba[3] == 255u8, "RGBA8 pixels carry input and asset sum")
    var expected : array<uint8>
    for (i in range(8)) {
        push(expected, uint8(i * 10 + 1))
        push(expected, 15u8)
        push(expected, 200u8)
        push(expected, 255u8)
    }
    let digests0 <- headless_digests(game.id)
    equal(t, digests0[0], frame_digest_rgb555(expected), "digest of frame 0")
    // frame 1: RGB565, stride 12, last row short
    headless_set_buttons(game.id, 0)
    headless_set_key(game.id, 30, false)
    equal(t, game_frame(game, 1000000, 4), EDEN_GAME_STEP_FRAME, "frame 1 presented")
    headless_last_frame(game.id, rgba, w, h)
    check(t, rgba[0] == 255u8 && rgba[1] == 0u8 && rgba[2] == 0u8 && rgba[3] == 255u8, "RGB565 0xF800 is red")
    check(t, rgba[28] == 255u8, "the short last row converted")
    // snapshot after two frames
    let snap <- game_snapshot(game)
    equal(t, length(snap), 8, "snapshot of 8 bytes")
    // frame 2: palette + INDEXED8, and the guest asks to quit
    let f2 = game_frame(game, 1000000, 4)
    equal(t, f2, EDEN_GAME_STEP_FRAME | EDEN_GAME_STEP_QUIT, "frame 2 presented, quit requested")
    headless_last_frame(game.id, rgba, w, h)
    check(t, rgba[0] == 0u8 && rgba[4] == 255u8 && rgba[5] == 0u8 && rgba[8] == 0u8 && rgba[10] == 255u8, "INDEXED8 through the palette")
    equal(t, headless_frames(game.id), 3, "three frames")
    equal(t, headless_video_errors(game.id), 3, "the three rejected presents were not frames")
    var aframes = 0l
    var adigest = 0u
    var apushes = 0
    var astreams = 0
    headless_audio(game.id, aframes, adigest, apushes, astreams)
    check(t, aframes == 192l && apushes == 3 && astreams == 1, "audio: 3 pushes of 64 frames, the bad push and the bad open refused")
    let logs <- headless_logs(game.id)
    check(t, length(logs) > 0 && logs[0] == "[info] init: asset sum 15", "stdout reached eden_core.log")
    let id = game.id
    game_stop(game)
    equal_str(t, game.error, "", "eden_shutdown ran cleanly")
    abi_destroy(game)
    check(t, !game.alive, "destroyed")
    equal(t, headless_frames(id), 0, "headless state dropped with the instance")
    let dead = abi_selftest_i64(game, 1l)
    check(t, dead == 0l && find(game.error, "not alive") >= 0, "a destroyed instance refuses calls")

    // restore the snapshot into a fresh instance: it resumes at step 2
    var again = AbiInstance()
    is_ok(t, open_selftest(bytes, again), "open selftest")
    headless_add_asset(again.id, "data", data)
    equal_str(t, game_start(again), "", "init")
    check(t, game_restore(again, snap), "restore accepted")
    equal(t, game_frame(again, 1000000, 4), EDEN_GAME_STEP_FRAME | EDEN_GAME_STEP_QUIT, "resumed at the third frame")
    var junk : array<uint8>
    push(junk, 1u8)
    check(t, !game_restore(again, junk) && find(again.error, "eden_state_load returned -1") >= 0, "a bad snapshot is refused")
    abi_destroy(again)
}


def test_abi_memory_growth_budget(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_memory_growth_budget")
    let bytes <- load_fixture(fx, SELFTEST)
    var inst = AbiInstance()
    is_ok(t, open_selftest(bytes, inst, AbiConfig(maxMemoryBytes = 8l * 65536l)), "open selftest with an 8-page budget")
    var big : array<uint8>
    resize(big, 1048576)
    let r = abi_selftest_take_bytes(inst, big)
    equal(t, r, 0, "a 1 MB argument does not fit")
    check(t, find(inst.error, "eden_alloc(1048576) returned 0") >= 0, "memory.grow failed inside the guest, reported ({inst.error})")
    check(t, !inst.faulted, "the guest stays healthy")
    check(t, length(inst.rt.mem) <= 8 * 65536, "linear memory stayed within the budget")
    var small : array<uint8>
    resize(small, 1000)
    equal(t, abi_selftest_take_bytes(inst, small), 0, "a small argument still works")
    equal_str(t, inst.error, "", "without error")
    abi_destroy(inst)
}


// the relink after a hot reload (ABI.md 7). A real reload only happens in
// the editor (scripts/abi/gate.sh triggers one while a guest plays); here
// the machinery: slots replaced in place, state kept, the rules enforced
def test_abi_relink(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_relink")
    let bytes <- load_fixture(fx, SELFTEST)
    var inst = AbiInstance()
    is_ok(t, open_selftest(bytes, inst), "open selftest")
    let data <- data_asset()
    headless_add_asset(inst.id, "data", data)
    equal_str(t, game_start(inst), "", "init")
    equal(t, game_frame(inst, 1000000, 4), EDEN_GAME_STEP_FRAME, "frame 0 before the relink")
    check(t, !abi_is_stale(inst), "a fresh instance is not stale")
    let slots = length(inst.rt.rawCalls)
    let linked = length(inst.linked)
    abi_relink_begin(inst)
    is_ok(t, headless_link_all(inst, false), "headless relinks")
    is_ok(t, abi_link_abi_test(inst, test_host()), "abi_test relinks")
    is_ok(t, abi_relink_end(inst), "relink complete")
    equal(t, length(inst.rt.rawCalls), slots, "raw-call slots replaced in place, none added")
    equal(t, length(inst.linked), linked, "the same packages")
    equal(t, game_frame(inst, 1000000, 4), EDEN_GAME_STEP_FRAME, "frame 1 after the relink: state kept")
    equal(t, headless_frames(inst.id), 2, "the headless state survived too")
    equal(t, abi_selftest_run_imports(inst), 0, "every import still answers")
    // a relink that forgets a package faults the instance
    abi_relink_begin(inst)
    is_ok(t, headless_link_all(inst, false), "headless relinks")
    let incomplete = abi_relink_end(inst)
    check(t, find(incomplete, "relink left packages without implementations: abi_test") >= 0, "a forgotten package is reported ({incomplete})")
    check(t, inst.faulted, "and faults the instance")
    abi_destroy(inst)
    // a relink cannot add a package the guest was not linked with
    var fresh = AbiInstance()
    is_ok(t, open_selftest(bytes, fresh), "open selftest")
    abi_relink_begin(fresh)
    headless_link_all(fresh, false)
    abi_link_abi_test(fresh, test_host())
    abi_relink_end(fresh)
    var bare <- abi_instantiate(bytes, "bare")
    abi_relink_begin(bare)
    let added = abi_link_abi_test(bare, test_host())
    check(t, find(added, "relink of abi_test, which was not linked before") >= 0, "relink cannot add packages ({added})")
    abi_destroy(bare)
    abi_destroy(fresh)
}


def test_abi_storage(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_abi_storage")
    let bytes <- load_fixture(fx, SELFTEST)
    storage_drop_namespace("selftest_storage")
    var inst <- abi_instantiate(bytes, "storage_a")
    is_ok(t, headless_link_all(inst, false, "selftest_storage"), "links with namespace selftest_storage")
    is_ok(t, abi_link_abi_test(inst, test_host()), "abi_test links")
    is_ok(t, abi_bind_abi_selftest(inst), "binds")
    let storageMismatches = abi_selftest_storage(inst)
    equal(t, storageMismatches, 0, "the guest's storage checks (raw API and libc files)")
    if (storageMismatches != 0) {
        let logs <- headless_logs(inst.id)
        for (l in logs) {
            if (starts_with(l, "[error]")) {
                out("  guest: {l}")
            }
        }
    }
    equal_str(t, inst.error, "", "without error")
    equal(t, storage_size("selftest_storage", "keep"), 5, "the host sees the blob")
    let kept <- storage_copy("selftest_storage", "keep")
    check(t, length(kept) == 5 && kept[0] == uint8('k') && kept[4] == uint8('!'), "with its bytes")
    abi_destroy(inst)
    // a new instance in the same namespace finds it; another namespace does not
    var again <- abi_instantiate(bytes, "storage_b")
    headless_link_all(again, false, "selftest_storage")
    abi_link_abi_test(again, test_host())
    abi_bind_abi_selftest(again)
    equal(t, abi_selftest_blob_size(again, "keep"), 5, "the blob outlives its instance")
    abi_destroy(again)
    var other <- abi_instantiate(bytes, "storage_c")
    headless_link_all(other, false, "another_namespace")
    abi_link_abi_test(other, test_host())
    abi_bind_abi_selftest(other)
    equal(t, abi_selftest_blob_size(other, "keep"), EDEN_STORAGE_ERR_NOT_FOUND, "namespaces are separate")
    abi_destroy(other)
    // the quota, in the model every host shares
    equal(t, storage_check_write("selftest_storage", "big", EDEN_STORAGE_MAX_TOTAL_BYTES - 5), EDEN_STORAGE_OK, "up to the quota")
    equal(t, storage_check_write("selftest_storage", "big", EDEN_STORAGE_MAX_TOTAL_BYTES - 4), EDEN_STORAGE_ERR_FULL, "one byte past it")
    equal(t, storage_check_write("selftest_storage", "keep", EDEN_STORAGE_MAX_TOTAL_BYTES), EDEN_STORAGE_OK, "replacing a blob counts its old size out")
    storage_drop_namespace("selftest_storage")
}


def public run_tests_abi(var t : TestRun; fx : FixtureSource) {
    test_abi_instantiate_errors(t, fx)
    test_abi_link_rules(t, fx)
    test_abi_imports_roundtrip(t, fx)
    test_abi_exports_roundtrip(t, fx)
    test_abi_trap_and_fault(t, fx)
    test_abi_reentrancy(t, fx)
    test_abi_game_loop(t, fx)
    test_abi_memory_growth_budget(t, fx)
    test_abi_relink(t, fx)
    test_abi_storage(t, fx)
}
