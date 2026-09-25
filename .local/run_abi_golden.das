options gen2
options indenting = 4
options stack = 67_108_864

require daslib/fio
require daslib/strings_boost
require modules/wasm3das/source/eden_test
require modules/wasm3das/tests/eden/abi_golden

/*
    .local/run_abi_golden.das: the local runner of the binjgb golden checks
    (tests/eden/abi_golden.das: 16 frames whole, in 2 ms slices, and across
    a snapshot, against the wasmtime baselines). The editor runs the same
    checks with the cheat abi_binjgb_golden.

    Run from the Eden project root (scripts/abi/golden.sh does):
        daslang -no-dynamic-modules -project modules/wasm3das/scripts/eden/sandbox.das_project \
            modules/wasm3das/.local/run_abi_golden.das
    Exit code 0 when fail=0; the last line is "WASM3 TESTS pass=N fail=M".
*/


def read_fixture(name : string) : array<uint8> {
    var bytes : array<uint8>
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
            out("[run_abi_golden] fixture not found: {path}")
        }
    }
    return <- bytes
}


[export]
def main() {
    var t = TestRun()
    var fx = FixtureSource()
    fx.load <- @(name : string) : array<uint8> {
        return <- read_fixture(name)
    }
    run_abi_golden(t, fx)
    print_report(t)
    if (t.failed != 0) {
        unsafe(exit(1))
    }
}
