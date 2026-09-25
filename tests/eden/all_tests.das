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
// require modules/wasm3das/tests/eden/test_m3_exception
// require modules/wasm3das/tests/eden/test_m3_core
// require modules/wasm3das/tests/eden/test_m3_types
// require modules/wasm3das/tests/eden/test_m3_math_utils
// require modules/wasm3das/tests/eden/test_m3_code
// require modules/wasm3das/tests/eden/test_m3_function
// require modules/wasm3das/tests/eden/test_m3_module
// require modules/wasm3das/tests/eden/test_m3_exec_defs
// require modules/wasm3das/tests/eden/test_m3_exec
// require modules/wasm3das/tests/eden/test_m3_compile
// require modules/wasm3das/tests/eden/test_m3_env
// require modules/wasm3das/tests/eden/test_m3_parse
// require modules/wasm3das/tests/eden/test_m3_bind
// require modules/wasm3das/tests/eden/test_m3_api_defs
// require modules/wasm3das/tests/eden/test_wasi_core
// require modules/wasm3das/tests/eden/test_m3_api_wasi_fd
// require modules/wasm3das/tests/eden/test_m3_api_libc
// require modules/wasm3das/tests/eden/test_m3_api_wasi
// require modules/wasm3das/tests/eden/test_lang_modules
// require modules/wasm3das/tests/eden/test_fib32_regression


def public run_all_tests(var t : TestRun; fx : FixtureSource) {
    // --- run lines, in the same order (edited by the porter) ---
    run_tests_wasm3_defs(t, fx)
    run_tests_m3_config(t, fx)
    // run_tests_m3_exception(t, fx)
    // run_tests_m3_core(t, fx)
    // run_tests_m3_types(t, fx)
    // run_tests_m3_math_utils(t, fx)
    // run_tests_m3_code(t, fx)
    // run_tests_m3_function(t, fx)
    // run_tests_m3_module(t, fx)
    // run_tests_m3_exec_defs(t, fx)
    // run_tests_m3_exec(t, fx)
    // run_tests_m3_compile(t, fx)
    // run_tests_m3_env(t, fx)
    // run_tests_m3_parse(t, fx)
    // run_tests_m3_bind(t, fx)
    // run_tests_m3_api_defs(t, fx)
    // run_tests_wasi_core(t, fx)
    // run_tests_m3_api_wasi_fd(t, fx)
    // run_tests_m3_api_libc(t, fx)
    // run_tests_m3_api_wasi(t, fx)
    // run_tests_lang_modules(t, fx)
    // run_tests_fib32_regression(t, fx)
    pass
}
