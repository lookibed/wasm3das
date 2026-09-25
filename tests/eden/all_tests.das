options gen2
options indenting = 4

module all_tests shared public

require modules/wasm3das/source/eden_test

/*
    all_tests.das: the aggregate of the Eden test modules.

    The porter adds one `require modules/wasm3das/tests/eden/test_<module>`
    and one call in run_all_tests when a module lands (docs/eden-port/DESIGN.md
    5.2). The file is required by both the local runner (.local/run_tests.das)
    and the Eden host (.eden_host/main.das), which only differ in how fixtures
    are loaded.

    Require paths are relative to the Eden project root (the folder holding
    manifest.blk, two levels above this repository): that is how the editor
    resolves them, and the local scripts run daslang from the same folder.

    Module lines are kept in the port order of DESIGN.md section 3 so a
    failure in a lower layer is reported before the layers built on it.
*/

// --- test modules, in port order (edited by the porter) ---
require modules/wasm3das/tests/eden/test_wasm3_defs
require modules/wasm3das/tests/eden/test_m3_config
require modules/wasm3das/tests/eden/test_m3_exception
require modules/wasm3das/tests/eden/test_m3_core
require modules/wasm3das/tests/eden/test_m3_types
require modules/wasm3das/tests/eden/test_m3_math_utils
require modules/wasm3das/tests/eden/test_m3_code
require modules/wasm3das/tests/eden/test_m3_function
require modules/wasm3das/tests/eden/test_m3_module
require modules/wasm3das/tests/eden/test_m3_exec_defs
require modules/wasm3das/tests/eden/test_m3_exec
require modules/wasm3das/tests/eden/test_m3_compile
require modules/wasm3das/tests/eden/test_m3_env
require modules/wasm3das/tests/eden/test_m3_parse
require modules/wasm3das/tests/eden/test_m3_bind
require modules/wasm3das/tests/eden/test_m3_api_defs
require modules/wasm3das/tests/eden/test_wasi_core
require modules/wasm3das/tests/eden/test_m3_api_wasi_fd
require modules/wasm3das/tests/eden/test_m3_api_libc
require modules/wasm3das/tests/eden/test_m3_api_wasi
require modules/wasm3das/tests/eden/test_lang_modules
// --- the Eden guest ABI (docs/eden-abi), on top of the port ---
require modules/wasm3das/tests/eden/test_abi
require modules/wasm3das/tests/eden/test_abi_binjgb


typedef public TestModuleRun = function<(var t : TestRun; fx : FixtureSource) : void>


// the test modules in run order. The editor host runs one per engine frame
// (the script heap is collected only between frames, and the whole suite's
// temporaries do not fit its 100 MiB in one call); the local runner runs
// them in one go through run_all_tests
def public all_test_modules() : array<TestModuleRun> {
    var mods : array<TestModuleRun>
    // --- run lines, in the same order (edited by the porter) ---
    push(mods, @@run_tests_wasm3_defs)
    push(mods, @@run_tests_m3_config)
    push(mods, @@run_tests_m3_exception)
    push(mods, @@run_tests_m3_core)
    push(mods, @@run_tests_m3_types)
    push(mods, @@run_tests_m3_math_utils)
    push(mods, @@run_tests_m3_code)
    push(mods, @@run_tests_m3_function)
    push(mods, @@run_tests_m3_module)
    push(mods, @@run_tests_m3_exec_defs)
    push(mods, @@run_tests_m3_exec)
    push(mods, @@run_tests_m3_compile)
    push(mods, @@run_tests_m3_env)
    push(mods, @@run_tests_m3_parse)
    push(mods, @@run_tests_m3_bind)
    push(mods, @@run_tests_m3_api_defs)
    push(mods, @@run_tests_wasi_core)
    push(mods, @@run_tests_m3_api_wasi_fd)
    push(mods, @@run_tests_m3_api_libc)
    push(mods, @@run_tests_m3_api_wasi)
    push(mods, @@run_tests_lang_modules)
    push(mods, @@run_tests_abi)
    push(mods, @@run_tests_abi_binjgb)
    return <- mods
}


def public run_all_tests(var t : TestRun; fx : FixtureSource) {
    for (m in all_test_modules()) {
        invoke(m, t, fx)
    }
}
