options stack = 67_108_864

require engine.core
require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/all_tests
require modules/wasm3das/source/m3_parse       // m3_ParseModule
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_module      // m3_FreeModule, m3_SetModuleName
require modules/wasm3das/source/m3_api_libc    // m3_LinkSpecTest, m3_LinkLibC
require modules/wasm3das/source/m3_api_wasi    // m3_LinkWASI, m3_GetWasiContext
require modules/wasm3das/tests/eden/abi_golden // run_abi_golden (docs/eden-abi)
require modules/wasm3das/eden/abi_guest_player // guest_player_start: a guest playing in the scene
require modules/wasm3das/eden/abi_host_check   // run_abi_host_check: the Eden host paths
require strings
require daslib/strings_boost

/*
    The Eden project's main.das for wasm3das: installed to the project root
    by modules/wasm3das/scripts/eden/install_host.sh (the copy in the
    repository, .eden_host/main.das, is the source of truth).

    It is the host of the port inside the editor:
      - on_initialize requests every fixture listed in
        modules/wasm3das/docs/eden-port/fixtures.txt (installed as
        assets/wasm/<name>.data) so tests can read them synchronously
      - [cheat] wasm3_tests runs the whole Eden test suite and prints the
        summary line "WASM3 TESTS pass=N fail=M" (scripts/eden/eden_gate.sh
        reads it from the editor log)
      - [cheat] wasm3_run <fixture> <function> <args...> loads a fixture,
        links spectest + libc + WASI, calls one exported function with up to
        five decimal arguments (C m3_CallArgv) and prints
        "WASM3 RUN Result: ..." lines plus the guest's stdout / stderr
      - [cheat] wasm3_run_start <fixture> <args...> runs a WASI program's
        _start with argv = [fixture file name, args...] (platforms/app
        main.c) and prints its stdout / stderr and "WASM3 RUN exit <code>"
      - a debug text on screen mirrors the last summary, so the result is
        visible without the console

    Fixture names are paths under wasm3c/test/ ("lang/fib32.wasm"); the
    asset for such a name is "assets/wasm/lang/fib32.wasm.data".
*/


var fixtureNames : array<string>
var fixtureIds : table<string; TextId>
var statusNode : NodeId
var lastSummary = "wasm3das: no run yet"


def fixture_asset_path(name : string) : string {
    return "assets/wasm/{name}.data"
}


def request_fixtures() {
    // the list is generated into this file by install_host.sh between the
    // FIXTURES markers; keep the markers
    // FIXTURES-BEGIN
    // FIXTURES-END
    for (name in fixtureNames) {
        fixtureIds[name] = request_text(fixture_asset_path(name))
    }
}


def load_fixture_bytes(name : string) : array<uint8> {
    var bytes : array<uint8>
    if (fixtureIds |> key_exists(name)) {
        let id = fixtureIds[name]
        let found = get_binary_asset(id) $(data) {
            resize(bytes, length(data))
            for (i in range(length(data))) {
                bytes[i] = data[i]
            }
        }
        if (!found) {
            print("[wasm3das] fixture not loaded yet: {name}")
        }
    } else {
        print("[wasm3das] fixture not registered: {name} (add it to docs/eden-port/fixtures.txt and reinstall the host)")
    }
    return <- bytes
}


def make_fixture_source() : FixtureSource {
    var fx = FixtureSource()
    fx.load <- @(name : string) : array<uint8> {
        return <- load_fixture_bytes(name)
    }
    return <- fx
}


def set_status(text : string) {
    lastSummary = text
    if (statusNode.isAlive) {
        update_debug_text(statusNode, text)
    }
}


// The test modules run one per cheat call: wasm3_tests starts the run with
// the first module, each wasm3_tests_next runs the next one and prints
// "WASM3 TESTS STEP k/n"; after the last one the report and the summary
// line "WASM3 TESTS pass=N fail=M". scripts/eden/eden_gate.sh drives it.
//   - one module per call: the editor collects the script heap only between
//     frames, and the temporaries of the whole suite do not fit its 100 MiB
//     in one call
//   - cheats, not on_update: in EdenSpark 0.9 on_update flushed denormal
//     floats to zero and cheats did not; since 1.0 both flush
//     (abi_denormal_probe), and the port's strtod no longer depends on it
var testQueue : array<TestModuleRun>
var testNext = 0
var testRun = TestRun()
var testFx = FixtureSource()
var testRunning = false


def start_tests(var mods : array<TestModuleRun>; verbose : bool) {
    testQueue <- mods
    testNext = 0
    testRun = TestRun()
    testRun.verbose = verbose
    testFx <- make_fixture_source()
    testRunning = true
    set_status("tests running: {length(testQueue)} modules")
}


def step_tests() {
    if (!testRunning) {
        return
    }
    if (testNext < length(testQueue)) {
        invoke(testQueue[testNext], testRun, testFx)
        testNext++
    }
    if (testNext < length(testQueue)) {
        print("WASM3 TESTS STEP {testNext}/{length(testQueue)}")
        return
    }
    testRunning = false
    print_report(testRun)
    set_status("{summary(testRun)}\n{length(testRun.failures)} failure(s) listed in the console")
}


[cheat]
def wasm3_tests() {
    var mods <- all_test_modules()
    start_tests(mods, false)
    step_tests()
}


[cheat]
def wasm3_tests_verbose() {
    var mods <- all_test_modules()
    start_tests(mods, true)
    step_tests()
}


[cheat]
def wasm3_tests_next() {
    if (!testRunning) {
        print("WASM3 TESTS no run in progress (start with wasm3_tests)")
        return
    }
    step_tests()
}


[cheat]
def wasm3_fixture_check(name : string) {
    // proves a fixture is installed and readable: prints its size and header
    let bytes <- load_fixture_bytes(name)
    var head = ""
    for (i in range(min(length(bytes), 4))) {
        head += "{int(bytes[i])} "
    }
    print("WASM3 FIXTURE {name} len={length(bytes)} head=[{head}]")
}


// the guest's output bytes as print lines (a NUL byte cannot live in a
// daslang string and is dropped, DESIGN 4.7c)
def print_guest_output(tag : string; bytes : array<uint8>) {
    if (length(bytes) == 0) {
        return
    }
    let text = build_string() $(var w) {
        for (b in bytes) {
            if (b != 0u8) {
                write_char(w, int(b))
            }
        }
    }
    for (line in split(text, "\n")) {
        if (!empty(line)) {
            print("WASM3 RUN {tag}: {line}")
        }
    }
}


def fixture_file_name(fixture : string) : string {
    let parts <- split(fixture, "/")
    return length(parts) > 0 ? parts[length(parts) - 1] : fixture
}


// C platforms/app/main.c repl_init + repl_load + link_all + repl_call, over
// a fixture: `isStart` runs _start with `args` as the WASI argv tail
def run_fixture(fixture : string; funcName : string; args : array<string>; isStart : bool) {
    print("WASM3 RUN {fixture} {funcName} {join(args, " ")}")
    let bytes <- load_fixture_bytes(fixture)
    if (length(bytes) == 0) {
        print("WASM3 RUN Error: fixture {fixture} not loaded")
        return
    }
    var env <- m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    var result : M3Result = m3Err_none
    let parsed = m3_ParseModule(rt, bytes)
    result = parsed._0
    let wasmModule = parsed._1
    if (result == m3Err_none) {
        result = m3_LoadModule(rt, wasmModule)
        if (result != m3Err_none) {
            m3_FreeModule(rt, wasmModule)
        }
    }
    if (result == m3Err_none) {
        m3_SetModuleName(rt, wasmModule, fixture_file_name(fixture))
        result = m3_LinkSpecTest(rt, wasmModule)
        if (result == m3Err_none) {
            result = m3_LinkLibC(rt, wasmModule)
        }
        if (result == m3Err_none) {
            result = m3_LinkWASI(rt, wasmModule)
        }
    }
    var func : IM3Function = -1
    if (result == m3Err_none) {
        result = m3_FindFunction(rt, func, funcName)
    }
    if (result == m3Err_none) {
        if (isStart) {
            let token = m3_GetWasiContext()
            var wasiArgv : array<string>
            push(wasiArgv, fixture_file_name(fixture))
            for (a in args) {
                push(wasiArgv, a)
            }
            if (m3_IsWasiContext(token)) {
                m3_wasi_contexts[token].argc = u32(length(wasiArgv))
                m3_wasi_contexts[token].argv := wasiArgv
                m3_wasi_contexts[token].exit_code = 0
            }
            var noArgs : array<string>
            result = m3_CallArgv(rt, func, noArgs)
            print_guest_output("stdout", rt.stdoutBuffer)
            print_guest_output("stderr", rt.stderrBuffer)
            if (result == m3Err_trapExit) {
                let code = m3_IsWasiContext(token) ? m3_wasi_contexts[token].exit_code : 0
                print("WASM3 RUN exit {code}")
                result = m3Err_none
            } elif (result == m3Err_none) {
                print("WASM3 RUN exit 0")
            }
        } else {
            result = m3_CallArgv(rt, func, args)
            print_guest_output("stdout", rt.stdoutBuffer)
            print_guest_output("stderr", rt.stderrBuffer)
            if (result == m3Err_none) {
                let retCount = int(m3_GetRetCount(rt, func))
                var rets : array<u64>
                result = m3_GetResults(rt, func, u32(retCount), rets)
                if (result == m3Err_none && retCount == 0) {
                    print("WASM3 RUN Result: <Empty Stack>")
                }
                for (i in range(result == m3Err_none ? retCount : 0)) {
                    let t = m3_GetRetType(rt, func, u32(i))
                    if (t == M3ValueType.c_m3Type_i32) {
                        print("WASM3 RUN Result: {m3_bits_to_i32(rets[i])}")
                    } elif (t == M3ValueType.c_m3Type_i64) {
                        print("WASM3 RUN Result: {m3_bits_to_i64(rets[i])}")
                    } elif (t == M3ValueType.c_m3Type_f32) {
                        print("WASM3 RUN Result: {m3_bits_to_f32(rets[i])}")
                    } else {
                        print("WASM3 RUN Result: {m3_bits_to_f64(rets[i])}")
                    }
                }
            }
        }
    }
    if (result != m3Err_none) {
        var info = M3ErrorInfo()
        m3_GetErrorInfo(rt, info)
        print("WASM3 RUN Error: {result} ({info.message})")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


// the upstream benchmark (run_fixtures.py) inside the editor: one fixture
// export, timed with the engine's clock. Prints one parseable line:
// WASM3 BENCH <fixture> <function> result=<i32|error> load_ms=<ms> call_ms=<ms> total_ms=<ms>
// load = parse + load + link (spectest, libc, WASI), call = m3_CallArgv +
// m3_GetResults; the result is the first return value as signed i32, as
// run_fixtures.py compares it
def bench_fixture(fixture : string; funcName : string; args : array<string>) {
    let t0 = ref_time_ticks()
    let bytes <- load_fixture_bytes(fixture)
    if (length(bytes) == 0) {
        print("WASM3 BENCH {fixture} {funcName} result=error:fixture-not-loaded load_ms=0 call_ms=0 total_ms=0")
        return
    }
    var env <- m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    var result : M3Result = m3Err_none
    let parsed = m3_ParseModule(rt, bytes)
    result = parsed._0
    let wasmModule = parsed._1
    if (result == m3Err_none) {
        result = m3_LoadModule(rt, wasmModule)
    }
    if (result == m3Err_none) {
        result = m3_LinkSpecTest(rt, wasmModule)
    }
    if (result == m3Err_none) {
        result = m3_LinkLibC(rt, wasmModule)
    }
    if (result == m3Err_none) {
        result = m3_LinkWASI(rt, wasmModule)
    }
    var func : IM3Function = -1
    if (result == m3Err_none) {
        result = m3_FindFunction(rt, func, funcName)
    }
    let loadNs = get_time_nsec(t0)
    let t1 = ref_time_ticks()
    var value = "error"
    if (result == m3Err_none) {
        result = m3_CallArgv(rt, func, args)
        if (result == m3Err_none) {
            var rets : array<u64>
            let retCount = m3_GetRetCount(rt, func)
            result = m3_GetResults(rt, func, retCount, rets)
            if (result == m3Err_none && length(rets) > 0) {
                value = "{m3_bits_to_i32(rets[0])}"
            }
        }
    }
    let callNs = get_time_nsec(t1)
    if (result != m3Err_none) {
        value = "error:{result}"
    }
    print("WASM3 BENCH {fixture} {funcName} result={value} load_ms={double(loadNs) / 1000000.0lf} call_ms={double(callNs) / 1000000.0lf} total_ms={double(loadNs + callNs) / 1000000.0lf}")
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


[cheat]
def wasm3_bench(fixture : string; funcName : string; a1 : string = ""; a2 : string = "") {
    let args <- collect_args(a1, a2, "", "", "")
    bench_fixture(fixture, funcName, args)
}


def collect_args(a1, a2, a3, a4, a5 : string) : array<string> {
    var args : array<string>
    for (a in fixed_array(a1, a2, a3, a4, a5)) {
        if (!empty(a)) {
            push(args, a)
        }
    }
    return <- args
}


[cheat]
def wasm3_run(fixture : string; funcName : string; a1 : string = ""; a2 : string = ""; a3 : string = ""; a4 : string = "") {
    let args <- collect_args(a1, a2, a3, a4, "")
    run_fixture(fixture, funcName, args, false)
}


[cheat]
def wasm3_run_start(fixture : string; a1 : string = ""; a2 : string = ""; a3 : string = ""; a4 : string = ""; a5 : string = "") {
    let args <- collect_args(a1, a2, a3, a4, a5)
    run_fixture(fixture, "_start", args, true)
}


// ---------------------------------------------------------------------------
// The Eden guest ABI (modules/wasm3das/docs/eden-abi)
// ---------------------------------------------------------------------------


var playerNode : NodeId


// the binjgb golden checks (tests/eden/abi_golden.das) inside the editor;
// prints the report and "WASM3 TESTS pass=N fail=M" like wasm3_tests
[cheat]
def abi_binjgb_golden() {
    var t = TestRun()
    let fx <- make_fixture_source()
    run_abi_golden(t, fx)
    print_report(t)
    set_status("abi golden: {summary(t)}")
}


// only the ABI test modules (one per frame, as wasm3_tests)
[cheat]
def abi_tests() {
    var mods : array<TestModuleRun>
    push(mods, @@run_tests_abi)
    push(mods, @@run_tests_abi_binjgb)
    start_tests(mods, false)
    step_tests()
}


// heap growth of ABI operations inside one call (the heap is collected
// only between engine frames): "ABI HEAP PROBE <what> delta=N"
[cheat]
def abi_heap_probe() {
    let fx <- make_fixture_source()
    let selftest <- load_fixture(fx, "abi/build/abi_selftest.wasm")
    let wasm <- load_fixture(fx, BINJGB_WASM)
    let rom <- load_fixture(fx, ACID2_ROM)
    var h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var big : array<uint8>
        resize(big, 1048576)
        delete big
    }
    print("ABI HEAP PROBE 1 MB array allocated and deleted x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var big : array<uint8>
        reserve(big, 327680)
        resize(big, 327680)
        delete big
    }
    print("ABI HEAP PROBE reserve+resize 320 KB then delete x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var env <- m3_NewEnvironment()
        var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
        let parsed = m3_ParseModule(rt, selftest)
        m3_FreeRuntime(rt)
        m3_FreeEnvironment(env)
    }
    print("ABI HEAP PROBE bare wasm3 new+parse+free x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var env <- m3_NewEnvironment()
        var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
        let parsed = m3_ParseModule(rt, selftest)
        m3_LoadModule(rt, parsed._1)
        m3_FreeRuntime(rt)
        m3_FreeEnvironment(env)
    }
    print("ABI HEAP PROBE bare wasm3 new+parse+load+free x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var env <- m3_NewEnvironment()
        var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
        m3_FreeRuntime(rt)
        m3_FreeEnvironment(env)
    }
    print("ABI HEAP PROBE bare wasm3 new+free x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var inst <- abi_instantiate(selftest, "probe")
        abi_destroy(inst)
    }
    print("ABI HEAP PROBE instantiate+destroy selftest x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    for (i in range(10)) {
        var inst <- abi_instantiate(selftest, "probe")
        headless_link_all(inst, false)
        abi_destroy(inst)
    }
    print("ABI HEAP PROBE +link x10 delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    var one <- golden_binjgb(wasm, rom, 1, 1000000000)
    print("ABI HEAP PROBE binjgb 1 frame delta={int64(heap_bytes_allocated()) - int64(h0)}")
    h0 = heap_bytes_allocated()
    var four <- golden_binjgb(wasm, rom, 4, 1000000000)
    print("ABI HEAP PROBE binjgb 4 frames delta={int64(heap_bytes_allocated()) - int64(h0)}")
}


// ---------------------------------------------------------------------------
// Autobench: the same CPU work timed in the editor (cheat abi_autobench) and
// in a standalone build (runs by itself on the 30th frame there, since a
// shipped game has no console): "AUTOBENCH <mode> <name> ms=<t> result=<r>"
// ---------------------------------------------------------------------------


var autobenchFrames = 0
var autobenchDone = false


// A build made for measuring carries the asset assets/wasm/autobench.data
// with the byte '1' (scripts/eden/install_host.sh installs it as '0';
// C:\Users\Andry\.edenspark\eden_build.py --autobench writes '1' only while
// it packs the project). Nothing in Eden 1.0 tells a build from the editor:
// is_standalone_exe() is about `daslang -exe` (false in both) and
// get_command_line_arguments() panics in the game context
// ("can't delete locked array" inside builtin.das, measured).
var autobenchFlagId : TextId
var edenBuildKnown = false
var edenBuild = false


def request_autobench_flag() {
    autobenchFlagId = request_text("assets/wasm/autobench.data")
}


def is_eden_build() : bool {
    if (!edenBuildKnown) {
        let found = get_binary_asset(autobenchFlagId) $(data) {
            edenBuild = length(data) > 0 && data[0] == uint8('1')
        }
        edenBuildKnown = found
    }
    return edenBuild
}


def autobench_ms(t0 : int64) : double {
    return double(get_time_nsec(t0)) / 1000000.0lf
}


// pure daslang: integer mixing, an array walk, float math
def bench_script_loop() : uint {
    var h = 2166136261u
    var buf : array<uint>
    resize(buf, 1 << 20)
    for (round in range(8)) {
        for (i in range(length(buf))) {
            buf[i] = buf[i] * 1664525u + uint(i) + 1013904223u
            h = (h ^ buf[i]) * 16777619u
        }
    }
    var f = 0.0lf
    for (i in range(2000000)) {
        f += sqrt(double(i)) * 0.5lf
    }
    delete buf
    return h ^ uint(int(f) & 0x7fffffff)
}


def run_autobench() {
    let mode = is_eden_build() ? "build" : "editor"
    var lines : array<string>
    var t0 = ref_time_ticks()
    let h = bench_script_loop()
    push(lines, "AUTOBENCH {mode} script_loop ms={autobench_ms(t0)} result={h}")

    t0 = ref_time_ticks()
    let wasm <- load_fixture_bytes("lang/fib32.wasm")
    var env <- m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    let parsed = m3_ParseModule(rt, wasm)
    var r = parsed._0
    if (r == m3Err_none) {
        r = m3_LoadModule(rt, parsed._1)
    }
    var func : IM3Function = -1
    if (r == m3Err_none) {
        r = m3_FindFunction(rt, func, "fib")
    }
    var fibResult = "error"
    if (r == m3Err_none) {
        var args : array<string>
        push(args, "24")
        r = m3_CallArgv(rt, func, args)
        var rets : array<u64>
        if (r == m3Err_none && m3_GetResults(rt, func, 1u, rets) == m3Err_none) {
            fibResult = "{m3_bits_to_i32(rets[0])}"
        }
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
    push(lines, "AUTOBENCH {mode} wasm3_fib24 ms={autobench_ms(t0)} result={fibResult}")

    t0 = ref_time_ticks()
    let bj <- load_fixture_bytes(BINJGB_WASM)
    let rom <- load_fixture_bytes(ACID2_ROM)
    let run <- golden_binjgb(bj, rom, 4, 1000000000)
    let last = length(run.digests) > 0 ? run.digests[length(run.digests) - 1] : 0
    push(lines, "AUTOBENCH {mode} binjgb_4_frames ms={autobench_ms(t0)} result={last} error={run.error}")

    for (l in lines) {
        print(l)
    }
    set_status(join(lines, "\n"))
}


[cheat]
def abi_autobench() {
    run_autobench()
}


def step_autobench() {
    if (autobenchDone || !is_eden_build()) {
        return
    }
    autobenchFrames++
    if (autobenchFrames == 30) {
        autobenchDone = true
        run_autobench()
    }
}


// whether denormal doubles and floats survive arithmetic here and in
// on_update: "ABI DENORMAL <where> f64=<bits> f32=<bits>" (0 = flushed)
var denormalProbePending = false


def denormal_report(context : string) {
    var d = 1.0e-300lf
    d = d * 1.0e-10lf       // 1e-310, a subnormal double
    var f = 1.0e-30
    f = f * 1.0e-10         // 1e-40, a subnormal float
    print("ABI DENORMAL {context} f64={m3_bits_from_f64(d)} f32={m3_bits_from_f32(f)}")
}


[cheat]
def abi_denormal_probe() {
    denormal_report("cheat")
    denormalProbePending = true
}


// the script heap now: "ABI HEAP bytes=N"
[cheat]
def abi_heap() {
    print("ABI HEAP bytes={heap_bytes_allocated()}")
}


// the Eden host's engine paths (eden/abi_host_check.das); prints the report
// and "WASM3 TESTS pass=N fail=M"
[cheat]
def abi_host_check() {
    var t = TestRun()
    let fx <- make_fixture_source()
    run_abi_host_check(t, fx)
    print_report(t)
    set_status("abi host check: {summary(t)}")
}


// what eden_input answers right now: "ABI INPUT pad=<mask> key30=<0|1>"
// (scan code 30 = A); scripts/abi/gate.sh holds keys with the MCP input
// tool and reads this line
[cheat]
def abi_input_probe() {
    print("ABI INPUT pad={eden_host_pad_buttons()} key30={eden_host_key_down(30) ? 1 : 0}")
}


// plays a guest in the scene with the Eden host: `guest` and `rom` are
// fixture names (docs/eden-port/fixtures.txt); the ROM becomes the asset
// "rom". budget = microseconds of guest work per editor frame
[cheat]
def abi_play(guest : string = "abi/build/binjgb.wasm"; rom : string = "abi/binjgb/roms/cgb-acid2.gbc"; budget : string = "12000") {
    abi_stop()
    let wasm <- load_fixture_bytes(guest)
    var assets : table<string; array<uint8>>
    if (!empty(rom)) {
        assets["rom"] <- load_fixture_bytes(rom)
    }
    // saves (eden_storage) are kept per guest and ROM
    let ns = "{fixture_file_name(guest)}_{fixture_file_name(rom)}"
    playerNode = guest_player_start(wasm, fixture_file_name(guest), assets, ns, to_int(budget))
    print("ABI PLAY {guest} {rom}: {playerNode.isAlive ? "started" : "failed"}")
}


[cheat]
def abi_stop() {
    if (playerNode.isAlive) {
        remove_node(playerNode)
    }
    playerNode = NodeId()
}


// which function values of the running player survived the last hot
// reload: "ABI RELOAD <abi_reload_report>"
[cheat]
def abi_reload_diag() {
    print("ABI RELOAD {guest_player_reload_report(playerNode)}")
}


// turns on the RGB555 digest of the running player's frames and prints the
// frame count and the last digest: "ABI PLAYER frames=N digest=D"
[cheat]
def abi_player_digest() {
    let id = guest_player_instance_id(playerNode)
    if (id < 0) {
        print("ABI PLAYER none")
        return
    }
    eden_host_set_digest(id, true)
    print("ABI PLAYER frames={eden_host_frames(id)} digest={eden_host_last_digest(id)}")
}


[export]
def on_initialize() {
    let camera = create_node(NodeData(name = "camera", position = float3(0, 0, -5)))
    // the size is the visible height (10 units), whatever the tab's aspect
    add_component(camera, new Camera(orthographic = true, orthographicSize = 10f, fovAxis = FovAxis.Vertical))
    statusNode = create_debug_text(lastSummary, float2(16, 16), TOP_LEFT_ANCHOR)
    set_text_font_size(statusNode, 20.0)
    request_fixtures()
    request_autobench_flag()
}


[export]
def on_update() {
    if (denormalProbePending) {
        denormalProbePending = false
        denormal_report("on_update")
    }
    step_autobench()
}
