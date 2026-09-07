options gen2
options indenting = 4
// The port has no equivalent of C M3_MUSTTAIL: every op_* calls the next
// operation instead of tail-jumping, so a wasm call chain costs Daslang
// frames. options stack counts only in the program root, which under dastest
// is this file.
options stack = 4_194_304

// No `module` declaration, like tests/integration/test_fib32_regression.das: under dastest
// a test file that names its module does not run the [init] functions of
// required shared modules.

require dastest/testing_boost
require daslib/fio
require ../../source/m3_parse.das


/*
    End-to-end regression over every module in wasm3c/test/lang: the fixtures
    the C project ships for its own smoke runs. Each exports `fib`.

    - fib32.wasm      (i32) -> i32   plain recursion
    - fib64.wasm      (i64) -> i64   plain recursion, 64-bit operands
    - fib.c.wasm      (i32) -> i32   emcc output: memory + global + data
                                     sections, several exports
    - fib32_tail.wasm (i32) -> i32   tail-call proposal: `return_call` (0x12)

    C wasm3 maps 0x12 `return_call` and 0x13 `return_call_indirect` onto the
    ordinary Compile_Call / Compile_CallIndirect compilers (m3_compile.c
    c_operations rows 0x12/0x13, "TODO: Optimize"), so the tail-call module is
    expected to run like the others, only without the constant-stack property.

    Lifecycle mirrors wasm3c/platforms/app/main.c (repl_load, repl_call):
    m3_NewEnvironment -> m3_NewRuntime -> m3_ParseModule -> m3_LoadModule ->
    m3_FindFunction -> m3_CallV -> m3_GetResultsV -> m3_FreeRuntime ->
    m3_FreeEnvironment.
*/


let LANG_DIR = "wasm3c/test/lang/"


struct LangFixture {
    env : IM3Environment
    runtime : IM3Runtime
    _module : IM3Module
    fib : IM3Function
}


def private read_file(path : string) : array<u8> {
    var bytes : array<u8>
    fopen(path, "rb") $(f) {
        if (f != null) {
            let st = fstat(f)
            bytes |> resize(int64(st.size))
            fread(f, bytes)
        }
    }
    return <- bytes
}


// Parse, load and compile `fib` out of one lang fixture. `fib` is null when
// any step failed; every step is asserted on `t`.
def private load_lang(t : T?; name : string; var bytes : array<u8>) : LangFixture {
    var fx : LangFixture
    if (empty(bytes)) {
        t |> success(false, "{name}: fixture is readable")
        return fx
    }

    fx.env = m3_NewEnvironment()
    t |> success(fx.env != null, "{name}: m3_NewEnvironment")
    if (fx.env == null) return fx

    fx.runtime = m3_NewRuntime(fx.env, 64u * 1024u, null)
    t |> success(fx.runtime != null, "{name}: m3_NewRuntime")
    if (fx.runtime == null) return fx

    var result = m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes)))
    t |> equal(result, m3Err_none, "{name}: m3_ParseModule")
    if (result != m3Err_none) return fx

    result = m3_LoadModule(fx.runtime, fx._module)
    t |> equal(result, m3Err_none, "{name}: m3_LoadModule")
    if (result != m3Err_none) {
        // C repl_load: a module that failed to load is still owned by the caller.
        m3_FreeModule(fx._module)
        fx._module = null
        return fx
    }

    result = m3_FindFunction(fx.fib, fx.runtime, "fib")
    t |> equal(result, m3Err_none, "{name}: m3_FindFunction fib")
    return fx
}


def private free_lang(var fx : LangFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


// fib(25) through the i32 entry point. Returns -1 when the call protocol failed.
def private call_fib_i32(t : T?; name : string; var fib : IM3Function; n : int) : int {
    var args : array<M3TaggedValue>
    args |> resize(1)
    args[0]._type = M3ValueType.c_m3Type_i32
    tagged_set_i32(args[0], n)

    let callResult = m3_CallV(fib, args)
    t |> equal(callResult, m3Err_none, "{name}: m3_CallV fib({n})")
    if (callResult != m3Err_none) return -1

    var rets : array<M3TaggedValue>
    let retResult = m3_GetResultsV(fib, rets)
    t |> equal(retResult, m3Err_none, "{name}: m3_GetResultsV fib({n})")
    if (retResult != m3Err_none || length(rets) != 1) return -1
    t |> success(rets[0]._type == M3ValueType.c_m3Type_i32, "{name}: result type i32")
    return tagged_get_i32(rets[0])
}


def private call_fib_i64(t : T?; name : string; var fib : IM3Function; n : i64) : i64 {
    var args : array<M3TaggedValue>
    args |> resize(1)
    args[0]._type = M3ValueType.c_m3Type_i64
    tagged_set_i64(args[0], n)

    let callResult = m3_CallV(fib, args)
    t |> equal(callResult, m3Err_none, "{name}: m3_CallV fib({n})")
    if (callResult != m3Err_none) return -1l

    var rets : array<M3TaggedValue>
    let retResult = m3_GetResultsV(fib, rets)
    t |> equal(retResult, m3Err_none, "{name}: m3_GetResultsV fib({n})")
    if (retResult != m3Err_none || length(rets) != 1) return -1l
    t |> success(rets[0]._type == M3ValueType.c_m3Type_i64, "{name}: result type i64")
    return tagged_get_i64(rets[0])
}


// The three (i32) -> i32 fixtures share one body; only the file differs.
def private run_i32_fixture(t : T?; name : string) {
    var bytes <- read_file(LANG_DIR + name)
    var fx = load_lang(t, name, bytes)
    if (fx.fib != null) {
        t |> equal(m3_GetArgCount(fx.fib), 1u, "{name}: arg count")
        t |> equal(m3_GetRetCount(fx.fib), 1u, "{name}: ret count")
        t |> success(m3_GetArgType(fx.fib, 0u) == M3ValueType.c_m3Type_i32, "{name}: arg 0 i32")
        t |> success(m3_GetRetType(fx.fib, 0u) == M3ValueType.c_m3Type_i32, "{name}: ret 0 i32")

        t |> equal(call_fib_i32(t, name, fx.fib, 2), 1, "{name}: fib(2)")
        t |> equal(call_fib_i32(t, name, fx.fib, 10), 55, "{name}: fib(10)")
        t |> equal(call_fib_i32(t, name, fx.fib, 25), 75025, "{name}: fib(25)")
    }
    free_lang(fx)
}


[test]
def test_lang_fib32(t : T?) {
    run_i32_fixture(t, "fib32.wasm")
}


[test]
def test_lang_fib_c(t : T?) {
    run_i32_fixture(t, "fib.c.wasm")
}


// return_call (0x12) shares Compile_Call with 0x10 in the C operation table.
[test]
def test_lang_fib32_tail(t : T?) {
    run_i32_fixture(t, "fib32_tail.wasm")
}


[test]
def test_lang_fib64(t : T?) {
    let name = "fib64.wasm"
    var bytes <- read_file(LANG_DIR + name)
    var fx = load_lang(t, name, bytes)
    if (fx.fib != null) {
        t |> equal(m3_GetArgCount(fx.fib), 1u, "{name}: arg count")
        t |> equal(m3_GetRetCount(fx.fib), 1u, "{name}: ret count")
        t |> success(m3_GetArgType(fx.fib, 0u) == M3ValueType.c_m3Type_i64, "{name}: arg 0 i64")
        t |> success(m3_GetRetType(fx.fib, 0u) == M3ValueType.c_m3Type_i64, "{name}: ret 0 i64")

        t |> equal(call_fib_i64(t, name, fx.fib, 2l), 1l, "{name}: fib(2)")
        t |> equal(call_fib_i64(t, name, fx.fib, 10l), 55l, "{name}: fib(10)")
        t |> equal(call_fib_i64(t, name, fx.fib, 25l), 75025l, "{name}: fib(25)")
    }
    free_lang(fx)
}


// fib.c.wasm is the only lang fixture with memory, a global and a data
// segment: m3_LoadModule must run InitMemory/InitGlobals/InitDataSegments.
[test]
def test_lang_fib_c_memory_and_globals(t : T?) {
    let name = "fib.c.wasm"
    var bytes <- read_file(LANG_DIR + name)
    var fx = load_lang(t, name, bytes)
    if (fx._module != null) {
        // memory section bytes 05 06 01 01 80 02 80 02: one memory, flag 1
        // (max present), initPages = maxPages = 256 pages of 64 KiB.
        t |> equal(fx.runtime.memory.numPages, 256u, "{name}: numPages")
        t |> equal(fx.runtime.memory.maxPages, 256u, "{name}: maxPages")
        t |> equal(m3_GetMemorySize(fx.runtime), 256u * 65536u, "{name}: memory size")
        // one mutable i32 global (the emscripten stack pointer).
        t |> equal(fx._module.numGlobals, 1u, "{name}: numGlobals")
        t |> equal(fx._module.numDataSegments, 1u, "{name}: numDataSegments")
        // exports of the emcc side module, all reachable by name.
        var f : IM3Function
        t |> equal(m3_FindFunction(f, fx.runtime, "main"), m3Err_none, "{name}: export main")
        t |> equal(m3_FindFunction(f, fx.runtime, "stackAlloc"), m3Err_none, "{name}: export stackAlloc")
        t |> equal(m3_FindFunction(f, fx.runtime, "_start"), m3Err_none, "{name}: export _start")
    }
    free_lang(fx)
}
