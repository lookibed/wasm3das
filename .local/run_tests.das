options gen2
options indenting = 4
options stack = 67_108_864

require daslib/fio
require daslib/strings_boost
require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/all_tests

/*
    .local/run_tests.das: the local runner of the Eden test modules.

    Lives under .local/ (hidden from the editor) because it reads fixtures
    with daslib/fio, which the editor sandbox forbids (the sandbox project
    allows fio only for files under .local/). Everything it requires
    (source/, tests/eden/) is sandbox-clean; scripts/eden/compile.sh proves
    that separately, this file only runs the tests.

    Run from the Eden project root (the folder with manifest.blk), which is
    what scripts/eden/test.sh does:
        daslang -no-dynamic-modules -project modules/wasm3das/scripts/eden/sandbox.das_project \
            modules/wasm3das/.local/run_tests.das -- [--verbose]
    Exit code: 0 when fail=0, 1 otherwise. The last line is the summary
    "WASM3 TESTS pass=N fail=M".
*/


def read_fixture(name : string) : array<uint8> {
    var bytes : array<uint8>
    // names under abi/ are the ABI guests and their data (guests/), the rest
    // wasm3c/test (the same mapping as scripts/eden/install_host.sh)
    let path = starts_with(name, "abi/") ? "modules/wasm3das/guests/{slice(name, 4)}" : "modules/wasm3das/wasm3c/test/{name}"
    fopen(path, "rb") <| $(f) {
        if (f != null) {
            fmap(f) <| $(data) {
                resize(bytes, length(data))
                for (i in range(length(data))) {
                    bytes[i] = data[i]
                }
            }
        } else {
            out("[run_tests] fixture not found: {path}")
        }
    }
    return <- bytes
}


[export]
def main() {
    var t = TestRun()
    for (arg in get_command_line_arguments()) {
        if (arg == "--verbose") {
            t.verbose = true
        }
    }
    var fx = FixtureSource()
    fx.load <- @(name : string) : array<uint8> {
        return <- read_fixture(name)
    }
    run_all_tests(t, fx)
    print_report(t)
    if (t.failed != 0) {
        unsafe(exit(1))
    }
}
