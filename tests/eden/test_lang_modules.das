options gen2
options indenting = 4

module test_lang_modules shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_api_libc    // m3_LinkSpecTest, m3_LinkLibC
require modules/wasm3das/source/m3_parse       // m3_ParseModule
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_module      // m3_FreeModule
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core

/*
    test_lang_modules.das: Eden counterpart of
    .upstream/tests/integration/test_lang_modules.das and
    .upstream/tests/integration/test_fib32_regression.das (folded in, see
    docs/eden-port/STATE.json module lang_modules).

    End-to-end regression over every module in wasm3c/test/lang, the
    fixtures the C project ships for its own smoke runs. Each exports `fib`:
      - lang/fib32.wasm      (i32) -> i32   plain recursion
      - lang/fib64.wasm      (i64) -> i64   plain recursion, 64-bit operands
      - lang/fib.c.wasm      (i32) -> i32   emcc output: memory + global +
                                            data sections, several exports
      - lang/fib32_tail.wasm (i32) -> i32   tail-call proposal: return_call
                                            (0x12), compiled by Compile_Call
                                            as in C
    Every fixture runs through the public stack as a host does, in the
    order of wasm3c/platforms/app/main.c (repl_init, repl_load, link_all,
    repl_call): m3_NewEnvironment -> m3_NewRuntime(env, 64 KiB, as
    upstream) -> m3_ParseModule -> m3_LoadModule -> m3_LinkSpecTest +
    m3_LinkLibC (link_all; none of the four modules imports anything, so
    both return m3Err_none through SuppressLookupFailure) ->
    m3_FindFunction("fib") -> m3_CallV / m3_Call / m3_CallArgv ->
    m3_GetResultsV / m3_GetResults -> m3_FreeRuntime -> m3_FreeEnvironment.

    Eden: the runtime is a value and every function takes it first; module
    and function are handles (-1 = NULL); the fixture bytes come from the
    FixtureSource (upstream: fopen/fread of wasm3c/test/lang/<name>);
    m3_ParseModule returns (result, module handle); the environment is a
    value that m3_NewRuntime copies.

    Coverage of the upstream [test]s (7 of 7 ported):
      - test_lang_fib32, test_lang_fib_c, test_lang_fib32_tail: arg / ret
        count and types, fib(2) = 1, fib(10) = 55, fib(25) = 75025 through
        m3_CallV / m3_GetResultsV with the result type i32.
      - test_lang_fib64: the same with i64 arguments and results.
      - test_lang_fib_c_memory_and_globals: 256 initial / max pages,
        m3_GetMemorySize = 16 MiB, one global, one data segment, exports
        main, stackAlloc and _start found by name.
      - test_fib32_results (test_fib32_regression.das): fib32.wasm is 62
        bytes, fib(2) / fib(10) / fib(25).
      - test_fib32_teardown (test_fib32_regression.das): fib(10) = 55, then
        m3_FreeRuntime / m3_FreeEnvironment complete. Eden: they also leave
        nothing behind (no module, stack, memory or code; the environment
        is the default value) and 20 load / call / free cycles over the
        four fixtures (five of fib.c.wasm with its 16 MiB memory) grow
        heap_bytes_allocated() by less than 256 KiB.
    Tests added for the Eden port (no upstream counterpart):
      - test_lang_call_argv: m3_CallArgv(["25"]) on every fixture (C
        strtoul / strtoull) read with m3_GetResults, and m3_Call with value
        bits fib(20) = 6765.
      - test_lang_argument_errors: zero or two arguments through m3_CallArgv,
        m3_Call and m3_CallV give m3Err_argumentCountMismatch, a wrong
        m3_GetResults count too, results before any call give "function
        not called". A non-numeric argument is not an error in C:
        m3_CallArgv parses with strtoul / strtoull, which read the longest
        decimal prefix after white space and give 0 without digits, so
        "abc" runs fib(0) = 0, "12abc" fib(12) = 144, " 7" fib(7) = 13 (the
        "not enough / too many arguments" strings are main.c's repl_call,
        not the library's).
      - test_lang_deep_recursion: fib(30) = 832040 on fib32.wasm (2.7
        million wasm calls, 30 frames deep; the largest cost of the module,
        so it runs on fib32 only: the whole module adds about 7 s to the
        local run).
*/


let LANG_FIXTURES = fixed_array("lang/fib32.wasm", "lang/fib64.wasm", "lang/fib32_tail.wasm", "lang/fib.c.wasm")


struct LangFixture {
    _module : IM3Module = -1   // C local `module` renamed: a daslang keyword
    fib : IM3Function = -1
}


// ============================================================================
// Helpers
// ============================================================================


// C repl_init: m3_NewRuntime (env, stack, NULL); upstream: 64 KiB of stack
def private new_lang_runtime(env : M3Environment) : M3Runtime {
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    return <- rt
}


// Parse, load, link and find `fib` out of one lang fixture (C repl_load +
// link_all + m3_FindFunction). `fib` is -1 when any step failed; every step
// is asserted on `t`.
def private load_lang(var t : TestRun; var rt : M3Runtime; name : string; bytes : array<u8>) : LangFixture {
    var lf = LangFixture()
    if (length(bytes) == 0) {
        check(t, false, "{name}: fixture is readable")
        return lf
    }

    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "{name}: m3_ParseModule")
    if (parsed._0 != m3Err_none) {
        return lf
    }
    lf._module = parsed._1

    var result = m3_LoadModule(rt, lf._module)
    is_ok(t, result, "{name}: m3_LoadModule")
    if (result != m3Err_none) {
        // C repl_load: a module that failed to load is still owned by the caller.
        m3_FreeModule(rt, lf._module)
        lf._module = -1
        return lf
    }

    // C link_all: spectest first, then libc
    result = m3_LinkSpecTest(rt, lf._module)
    is_ok(t, result, "{name}: m3_LinkSpecTest")
    if (result != m3Err_none) {
        return lf
    }
    result = m3_LinkLibC(rt, lf._module)
    is_ok(t, result, "{name}: m3_LinkLibC")
    if (result != m3Err_none) {
        return lf
    }

    result = m3_FindFunction(rt, lf.fib, "fib")
    is_ok(t, result, "{name}: m3_FindFunction fib")
    if (result != m3Err_none) {
        lf.fib = -1
    }
    return lf
}


// fib(n) through the typed i32 entry point. Returns -1 when the call
// protocol failed.
def private call_fib_i32(var t : TestRun; var rt : M3Runtime; name : string; fib : IM3Function; n : int) : int {
    var args : array<M3TaggedValue>
    push(args, M3TaggedValue())
    args[0]._type = M3ValueType.c_m3Type_i32
    tagged_set_i32(args[0], n)

    let callResult = m3_CallV(rt, fib, args)
    is_ok(t, callResult, "{name}: m3_CallV fib({n})")
    if (callResult != m3Err_none) {
        return -1
    }

    var rets : array<M3TaggedValue>
    let retResult = m3_GetResultsV(rt, fib, rets)
    is_ok(t, retResult, "{name}: m3_GetResultsV fib({n})")
    if (retResult != m3Err_none || length(rets) != 1) {
        return -1
    }
    check(t, rets[0]._type == M3ValueType.c_m3Type_i32, "{name}: result type i32")
    return tagged_get_i32(rets[0])
}


def private call_fib_i64(var t : TestRun; var rt : M3Runtime; name : string; fib : IM3Function; n : i64) : i64 {
    var args : array<M3TaggedValue>
    push(args, M3TaggedValue())
    args[0]._type = M3ValueType.c_m3Type_i64
    tagged_set_i64(args[0], n)

    let callResult = m3_CallV(rt, fib, args)
    is_ok(t, callResult, "{name}: m3_CallV fib({n})")
    if (callResult != m3Err_none) {
        return -1l
    }

    var rets : array<M3TaggedValue>
    let retResult = m3_GetResultsV(rt, fib, rets)
    is_ok(t, retResult, "{name}: m3_GetResultsV fib({n})")
    if (retResult != m3Err_none || length(rets) != 1) {
        return -1l
    }
    check(t, rets[0]._type == M3ValueType.c_m3Type_i64, "{name}: result type i64")
    return tagged_get_i64(rets[0])
}


// fib(argv[0]) through m3_CallArgv / m3_GetResults; the result bits, or
// 0xffffffffffffffff when the call protocol failed
def private call_fib_argv(var t : TestRun; var rt : M3Runtime; name : string; fib : IM3Function; arg : string) : u64 {
    let callResult = m3_CallArgv(rt, fib, [arg])
    is_ok(t, callResult, "{name}: m3_CallArgv fib(\"{arg}\")")
    if (callResult != m3Err_none) {
        return 0xfffffffffffffffful
    }
    var out : array<u64>
    let retResult = m3_GetResults(rt, fib, 1u, out)
    is_ok(t, retResult, "{name}: m3_GetResults fib(\"{arg}\")")
    if (retResult != m3Err_none || length(out) != 1) {
        return 0xfffffffffffffffful
    }
    return out[0]
}


// The three (i32) -> i32 fixtures share one body; only the file differs.
def private run_i32_fixture(var t : TestRun; fx : FixtureSource; name : string) {
    var bytes <- load_fixture(fx, name)
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf.fib != -1) {
        equal(t, m3_GetArgCount(rt, lf.fib), 1u, "{name}: arg count")
        equal(t, m3_GetRetCount(rt, lf.fib), 1u, "{name}: ret count")
        check(t, m3_GetArgType(rt, lf.fib, 0u) == M3ValueType.c_m3Type_i32, "{name}: arg 0 i32")
        check(t, m3_GetRetType(rt, lf.fib, 0u) == M3ValueType.c_m3Type_i32, "{name}: ret 0 i32")

        equal(t, call_fib_i32(t, rt, name, lf.fib, 2), 1, "{name}: fib(2)")
        equal(t, call_fib_i32(t, rt, name, lf.fib, 10), 55, "{name}: fib(10)")
        equal(t, call_fib_i32(t, rt, name, lf.fib, 25), 75025, "{name}: fib(25)")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


// ============================================================================
// test_lang_modules.das
// ============================================================================


def test_lang_fib32(var t : TestRun; fx : FixtureSource) {
    run_i32_fixture(t, fx, "lang/fib32.wasm")
}


def test_lang_fib_c(var t : TestRun; fx : FixtureSource) {
    run_i32_fixture(t, fx, "lang/fib.c.wasm")
}


// return_call (0x12) shares Compile_Call with 0x10 in the C operation table.
def test_lang_fib32_tail(var t : TestRun; fx : FixtureSource) {
    run_i32_fixture(t, fx, "lang/fib32_tail.wasm")
}


def test_lang_fib64(var t : TestRun; fx : FixtureSource) {
    let name = "lang/fib64.wasm"
    var bytes <- load_fixture(fx, name)
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf.fib != -1) {
        equal(t, m3_GetArgCount(rt, lf.fib), 1u, "{name}: arg count")
        equal(t, m3_GetRetCount(rt, lf.fib), 1u, "{name}: ret count")
        check(t, m3_GetArgType(rt, lf.fib, 0u) == M3ValueType.c_m3Type_i64, "{name}: arg 0 i64")
        check(t, m3_GetRetType(rt, lf.fib, 0u) == M3ValueType.c_m3Type_i64, "{name}: ret 0 i64")

        equal(t, call_fib_i64(t, rt, name, lf.fib, 2l), 1l, "{name}: fib(2)")
        equal(t, call_fib_i64(t, rt, name, lf.fib, 10l), 55l, "{name}: fib(10)")
        equal(t, call_fib_i64(t, rt, name, lf.fib, 25l), 75025l, "{name}: fib(25)")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


// fib.c.wasm is the only lang fixture with memory, a global and a data
// segment: m3_LoadModule must run InitMemory/InitGlobals/InitDataSegments.
def test_lang_fib_c_memory_and_globals(var t : TestRun; fx : FixtureSource) {
    let name = "lang/fib.c.wasm"
    var bytes <- load_fixture(fx, name)
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf._module != -1) {
        // memory section bytes 05 06 01 01 80 02 80 02: one memory, flag 1
        // (max present), initPages = maxPages = 256 pages of 64 KiB.
        equal(t, rt.memory.numPages, 256u, "{name}: numPages")
        equal(t, rt.memory.maxPages, 256u, "{name}: maxPages")
        equal(t, m3_GetMemorySize(rt), 256u * 65536u, "{name}: memory size")
        // one mutable i32 global (the emscripten stack pointer).
        equal(t, rt.modules[lf._module].numGlobals, 1u, "{name}: numGlobals")
        equal(t, rt.modules[lf._module].numDataSegments, 1u, "{name}: numDataSegments")
        // exports of the emcc side module, all reachable by name.
        var f : IM3Function = -1
        is_ok(t, m3_FindFunction(rt, f, "main"), "{name}: export main")
        is_ok(t, m3_FindFunction(rt, f, "stackAlloc"), "{name}: export stackAlloc")
        is_ok(t, m3_FindFunction(rt, f, "_start"), "{name}: export _start")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


// ============================================================================
// test_fib32_regression.das
// ============================================================================


def test_fib32_results(var t : TestRun; fx : FixtureSource) {
    let name = "lang/fib32.wasm"
    var bytes <- load_fixture(fx, name)
    equal(t, length(bytes), 62, "fib32.wasm size")
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf.fib != -1) {
        equal(t, call_fib_i32(t, rt, name, lf.fib, 2), 1, "fib(2)")
        equal(t, call_fib_i32(t, rt, name, lf.fib, 10), 55, "fib(10)")
        equal(t, call_fib_i32(t, rt, name, lf.fib, 25), 75025, "fib(25)")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


// one load / call / free cycle of `name`; fib(10) = 55 on every fixture
def private lang_cycle(var t : TestRun; fx : FixtureSource; name : string) {
    var bytes <- load_fixture(fx, name)
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf.fib != -1) {
        let bits = call_fib_argv(t, rt, name, lf.fib, "10")
        equal(t, bits & 0xfffffffful, 55ul, "{name}: fib(10) in a teardown cycle")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


// Teardown after a successful run. Eden: m3_FreeRuntime deletes the runtime
// value (m3_env's header) and m3_FreeEnvironment resets the environment
// value; both leave a default value behind, and repeated cycles return
// their memory to the heap.
def test_fib32_teardown(var t : TestRun; fx : FixtureSource) {
    let name = "lang/fib32.wasm"
    var bytes <- load_fixture(fx, name)
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf.fib != -1) {
        equal(t, call_fib_i32(t, rt, name, lf.fib, 10), 55, "fib(10) before teardown")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
    check(t, true, "teardown completed")

    // nothing is left behind
    equal(t, length(rt.modules), 0, "no module after m3_FreeRuntime")
    equal(t, length(rt.functions), 0, "no function after m3_FreeRuntime")
    equal(t, length(rt.funcTypes), 0, "no func type after m3_FreeRuntime")
    equal(t, length(rt.stack), 0, "no stack after m3_FreeRuntime")
    equal(t, length(rt.mem), 0, "no memory after m3_FreeRuntime")
    equal(t, length(rt.code), 0, "no code after m3_FreeRuntime")
    equal(t, rt.originStack, -1, "originStack is NULL")
    equal(t, env.retFuncTypes[1], -1, "the environment is the default after m3_FreeEnvironment")

    // 20 cycles over the four fixtures: the heap does not grow with them
    for (warm in LANG_FIXTURES) {
        lang_cycle(t, fx, warm)   // warm-up: the op tables and hooks exist afterwards
    }
    let before = heap_bytes_allocated()
    for (i in range(20)) {
        lang_cycle(t, fx, LANG_FIXTURES[i % 4])
    }
    let after = heap_bytes_allocated()
    let growth = int64(after) - int64(before)
    if (t.verbose) {
        out("[test_lang_modules] heap before={int64(before)} after={int64(after)} growth={growth} bytes over 20 cycles")
    }
    check(t, growth < 256l * 1024l, "20 lang cycles grow the heap by {growth} bytes (bound 256 KiB)")
}


// ============================================================================
// Added for the Eden port
// ============================================================================


// m3_CallArgv with C's decimal text and m3_Call with value bits, on every
// fixture
def test_lang_call_argv(var t : TestRun; fx : FixtureSource) {
    for (name in LANG_FIXTURES) {
        let is64 = name == "lang/fib64.wasm"
        var bytes <- load_fixture(fx, name)
        var env = m3_NewEnvironment()
        var rt <- new_lang_runtime(env)
        let lf = load_lang(t, rt, name, bytes)
        if (lf.fib != -1) {
            let bits = call_fib_argv(t, rt, name, lf.fib, "25")
            if (is64) {
                equal(t, m3_bits_to_i64(bits), 75025l, "{name}: m3_CallArgv fib(25)")
            } else {
                equal(t, m3_bits_to_i32(bits), 75025, "{name}: m3_CallArgv fib(25)")
            }

            let arg = is64 ? m3_bits_from_i64(20l) : m3_bits_from_i32(20)
            is_ok(t, m3_Call(rt, lf.fib, [arg]), "{name}: m3_Call fib(20)")
            var out : array<u64>
            is_ok(t, m3_GetResults(rt, lf.fib, 1u, out), "{name}: m3_GetResults fib(20)")
            if (length(out) == 1) {
                if (is64) {
                    equal(t, m3_bits_to_i64(out[0]), 6765l, "{name}: m3_Call fib(20)")
                } else {
                    equal(t, m3_bits_to_i32(out[0]), 6765, "{name}: m3_Call fib(20)")
                }
            } else {
                check(t, false, "{name}: one result for fib(20)")
            }
        }
        m3_FreeRuntime(rt)
        m3_FreeEnvironment(env)
    }
}


// wrong argument counts give m3Err_argumentCountMismatch; non-numeric text
// is what C's strtoul / strtoull make of it (see the header)
def test_lang_argument_errors(var t : TestRun; fx : FixtureSource) {
    for (name in fixed_array("lang/fib32.wasm", "lang/fib64.wasm")) {
        let is64 = name == "lang/fib64.wasm"
        var bytes <- load_fixture(fx, name)
        var env = m3_NewEnvironment()
        var rt <- new_lang_runtime(env)
        let lf = load_lang(t, rt, name, bytes)
        if (lf.fib != -1) {
            var out : array<u64>
            is_err(t, m3_GetResults(rt, lf.fib, 1u, out), "function not called", "{name}: results before any call")

            var noArgv : array<string>
            is_err(t, m3_CallArgv(rt, lf.fib, noArgv), m3Err_argumentCountMismatch, "{name}: m3_CallArgv with no argument")
            is_err(t, m3_CallArgv(rt, lf.fib, ["1", "2"]), m3Err_argumentCountMismatch, "{name}: m3_CallArgv with two arguments")
            var noBits : array<u64>
            is_err(t, m3_Call(rt, lf.fib, noBits), m3Err_argumentCountMismatch, "{name}: m3_Call with no argument")
            is_err(t, m3_Call(rt, lf.fib, [1ul, 2ul]), m3Err_argumentCountMismatch, "{name}: m3_Call with two arguments")
            var noArgs : array<M3TaggedValue>
            is_err(t, m3_CallV(rt, lf.fib, noArgs), m3Err_argumentCountMismatch, "{name}: m3_CallV with no argument")
            equal(t, rt.lastCalled, -1, "{name}: no call happened")

            // C strtoul / strtoull: the longest decimal prefix after white space
            let texts = fixed_array("abc", "12abc", " 7", "")
            let wants = fixed_array(0, 144, 13, 0)
            for (text, want in texts, wants) {
                let bits = call_fib_argv(t, rt, name, lf.fib, text)
                if (is64) {
                    equal(t, m3_bits_to_i64(bits), i64(want), "{name}: m3_CallArgv fib(\"{text}\")")
                } else {
                    equal(t, m3_bits_to_i32(bits), want, "{name}: m3_CallArgv fib(\"{text}\")")
                }
            }

            // a wrong result count after a successful call
            is_err(t, m3_GetResults(rt, lf.fib, 2u, out), m3Err_argumentCountMismatch, "{name}: m3_GetResults with two results")
        }
        m3_FreeRuntime(rt)
        m3_FreeEnvironment(env)
    }
}


// fib(30): 2.7 million wasm calls, 30 frames deep
def test_lang_deep_recursion(var t : TestRun; fx : FixtureSource) {
    let name = "lang/fib32.wasm"
    var bytes <- load_fixture(fx, name)
    var env = m3_NewEnvironment()
    var rt <- new_lang_runtime(env)
    let lf = load_lang(t, rt, name, bytes)
    if (lf.fib != -1) {
        equal(t, call_fib_i32(t, rt, name, lf.fib, 30), 832040, "{name}: fib(30)")
    }
    m3_FreeRuntime(rt)
    m3_FreeEnvironment(env)
}


def public run_tests_lang_modules(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_lang_fib32")
    test_lang_fib32(t, fx)
    begin_test(t, "test_lang_fib_c")
    test_lang_fib_c(t, fx)
    begin_test(t, "test_lang_fib32_tail")
    test_lang_fib32_tail(t, fx)
    begin_test(t, "test_lang_fib64")
    test_lang_fib64(t, fx)
    begin_test(t, "test_lang_fib_c_memory_and_globals")
    test_lang_fib_c_memory_and_globals(t, fx)
    begin_test(t, "test_fib32_results")
    test_fib32_results(t, fx)
    begin_test(t, "test_fib32_teardown")
    test_fib32_teardown(t, fx)
    begin_test(t, "test_lang_call_argv")
    test_lang_call_argv(t, fx)
    begin_test(t, "test_lang_argument_errors")
    test_lang_argument_errors(t, fx)
    begin_test(t, "test_lang_deep_recursion")
    test_lang_deep_recursion(t, fx)
}
