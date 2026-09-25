options stack = 67_108_864

require engine.core
require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/all_tests

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
      - [cheat] wasm3_run <fixture> <function> <args...> runs one exported
        wasm function once the runtime layers exist (m3_env and up)
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
