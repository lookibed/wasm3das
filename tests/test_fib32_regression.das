options gen2
options indenting = 4
// The port has no equivalent of C M3_MUSTTAIL: every op_* calls the next
// operation instead of tail-jumping, so one wasm frame costs about one
// Daslang frame per executed op. fib(25) nests 25 wasm frames; the default
// 16 KiB context stack is not enough. options stack counts only in the
// program root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/test_m3_env.das: under dastest a test
// file that names its module does not run the [init] functions of required
// shared modules. m3_NewEnvironment fills the compiler's operation table
// itself since PR #11, so this is convention rather than a workaround.

require dastest/testing_boost
require daslib/fio
require ../source/m3_parse.das


/*
    End-to-end regression over wasm3c/test/lang/fib32.wasm, the module the
    C project uses for its own smoke run: export "fib" (i32) -> i32.

    Mirrors the C usage in wasm3c/platforms/app/main.c (repl_load,
    repl_call): m3_NewEnvironment -> m3_NewRuntime -> m3_ParseModule ->
    m3_LoadModule -> m3_FindFunction -> m3_CallV -> m3_GetResultsV ->
    m3_FreeRuntime -> m3_FreeEnvironment. Lazy compilation happens inside
    m3_FindFunction, as in C.

    AGENTS.md requires this lifecycle, including teardown without a crash,
    for every runtime change. Results and teardown are separate tests so a
    teardown crash cannot take the result assertions down with it.
*/


let FIB32_PATH = "wasm3c/test/lang/fib32.wasm"


struct Fib32Fixture {
    env : IM3Environment
    runtime : IM3Runtime
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


// Parse, load and compile fib32.wasm. Returns a fixture whose `fib` is null
// when any step failed; every step is asserted on `t`.
def private load_fib32(t : T?) : Fib32Fixture {
    var fx : Fib32Fixture
    var bytes <- read_file(FIB32_PATH)
    t |> equal(length(bytes), 62, "fib32.wasm size")
    if (empty(bytes)) return fx

    fx.env = m3_NewEnvironment()
    t |> success(fx.env != null, "m3_NewEnvironment")
    if (fx.env == null) return fx

    fx.runtime = m3_NewRuntime(fx.env, 64u * 1024u, null)
    t |> success(fx.runtime != null, "m3_NewRuntime")
    if (fx.runtime == null) return fx

    // C local `module` renamed to `_module`: `module` is a daslang keyword.
    var _module : IM3Module
    var result = m3_ParseModule(fx.env, _module, unsafe(addr(bytes[0])), u32(length(bytes)))
    t |> equal(result, m3Err_none, "m3_ParseModule")
    if (result != m3Err_none) return fx

    result = m3_LoadModule(fx.runtime, _module)
    t |> equal(result, m3Err_none, "m3_LoadModule")
    if (result != m3Err_none) {
        // C repl_load: a module that failed to load is still owned by the caller.
        m3_FreeModule(_module)
        return fx
    }

    result = m3_FindFunction(fx.fib, fx.runtime, "fib")
    t |> equal(result, m3Err_none, "m3_FindFunction fib")
    if (result != m3Err_none) {
        fx.fib = null
    }
    return fx
}


def private call_fib(t : T?; var fib : IM3Function; n : int) : int {
    var args : array<M3TaggedValue>
    args |> resize(1)
    args[0]._type = M3ValueType.c_m3Type_i32
    tagged_set_i32(args[0], n)

    let callResult = m3_CallV(fib, args)
    t |> equal(callResult, m3Err_none, "m3_CallV fib({n})")
    if (callResult != m3Err_none) return -1

    var rets : array<M3TaggedValue>
    let retResult = m3_GetResultsV(fib, rets)
    t |> equal(retResult, m3Err_none, "m3_GetResultsV fib({n})")
    if (retResult != m3Err_none || length(rets) != 1) return -1
    return tagged_get_i32(rets[0])
}


[test]
def test_fib32_results(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    t |> equal(call_fib(t, fx.fib, 2), 1, "fib(2)")
    t |> equal(call_fib(t, fx.fib, 10), 55, "fib(10)")
    t |> equal(call_fib(t, fx.fib, 25), 75025, "fib(25)")

    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


// Teardown after a successful run. Environment, runtime and module are host
// allocations released with m3_Free_Impl, as in C; a Daslang `delete` would
// walk their pointer fields (runtime.compilation.runtime is a cycle) and
// overflow the stack, which is what this test used to skip.
[test]
def test_fib32_teardown(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return
    t |> equal(call_fib(t, fx.fib, 10), 55, "fib(10) before teardown")

    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
    t |> success(true, "teardown completed")
}
