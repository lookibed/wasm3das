options stack = 67_108_864

require engine.core
require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/all_tests
require modules/wasm3das/source/m3_parse       // m3_ParseModule
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_module      // m3_FreeModule, m3_SetModuleName
require modules/wasm3das/source/m3_api_libc    // m3_LinkSpecTest, m3_LinkLibC
require modules/wasm3das/source/m3_api_wasi    // m3_LinkWASI, m3_GetWasiContext
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


[cheat]
def wasm3_tests() {
    var t = TestRun()
    let fx <- make_fixture_source()
    run_all_tests(t, fx)
    print_report(t)
    set_status("{summary(t)}\n{length(t.failures)} failure(s) listed in the console")
}


[cheat]
def wasm3_tests_verbose() {
    var t = TestRun()
    t.verbose = true
    let fx <- make_fixture_source()
    run_all_tests(t, fx)
    print_report(t)
    set_status(summary(t))
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


[export]
def on_initialize() {
    let camera = create_node(NodeData(name = "camera", position = float3(0, 0, -5)))
    add_component(camera, new Camera(orthographic = true, orthographicSize = 10f))
    statusNode = create_debug_text(lastSummary, float2(16, 16), TOP_LEFT_ANCHOR)
    set_text_font_size(statusNode, 20.0)
    request_fixtures()
}


[export]
def on_update() {
    pass
}
