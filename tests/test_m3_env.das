options gen2
options indenting = 4
// The executor nests one Daslang frame per executed op (no M3_MUSTTAIL), so
// the calls below need a larger context stack; options stack counts only in
// the program root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/test_fib32_regression.das: a named
// test module does not get the [init] of required shared modules under dastest.

require dastest/testing_boost
require daslib/fio
require ../source/m3_parse.das
require ../source/m3_exec.das


/*
    Component test for m3_env.das (C m3_env.c).

    Part 1: the execution-hook wiring performed by m3_NewEnvironment. C
    m3_exec.h reaches CompileFunction and ResizeMemory through its include
    cycle; the Daslang port replaces those edges with global function bindings
    registered at environment creation.

    Part 2: the public runtime API on wasm3c/test/lang/fib32.wasm (one
    exported function `fib (i32) -> i32`, no globals, no memory section, no
    table). Every expected value is the C branch named in the comment.
*/


def private expect_true(name : string; actual : bool) {
    if (!actual) {
        panic("{name}: expected true, got false")
    }
}


def private expect_hooks_wired(stage : string) {
    expect_true("{stage}: CompileFunctionHook wired", CompileFunctionHook != null)
    expect_true("{stage}: ResizeMemoryHook wired", ResizeMemoryHook != null)
}


// Bindings are var, not let: const bindings propagate pointee-constness and
// the env API takes mutable IM3Environment / IM3Runtime values.
[test]
def test_env_new_environment_wires_hooks() {
    var env = m3_NewEnvironment()
    expect_true("environment allocated", env != null)
    expect_hooks_wired("first m3_NewEnvironment")
    m3_FreeEnvironment(env)
}


[test]
def test_env_hook_wiring_is_idempotent() {
    var first = m3_NewEnvironment()
    expect_true("first environment allocated", first != null)

    var second = m3_NewEnvironment()
    expect_true("second environment allocated", second != null)
    expect_hooks_wired("repeated m3_NewEnvironment")

    m3_FreeEnvironment(second)
    m3_FreeEnvironment(first)
}


[test]
def test_env_new_runtime_environment_survives_wiring() {
    var env = m3_NewEnvironment()
    expect_true("environment allocated", env != null)

    var runtime = m3_NewRuntime(env, 65536u, null)
    expect_true("runtime allocated", runtime != null)
    expect_true("runtime keeps environment", runtime.environment == env)
    expect_hooks_wired("after m3_NewRuntime")

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
}


[test]
def test_env_runtime_releases_linked_module_without_owning_environment() {
    var env = m3_NewEnvironment()
    expect_true("environment allocated for linked module", env != null)

    var runtime = m3_NewRuntime(env, 64u * 1024u, null)
    expect_true("runtime allocated for linked module", runtime != null)

    // The runtime frees its modules with m3_Free_Impl (C: m3_Free), so the
    // linked module must come from the host allocator, as in m3_ParseModule.
    var linkedModule : IM3Module = unsafe(reinterpret<IM3Module>(m3_Malloc_Impl(u64(typeinfo sizeof(type<M3Module>)))))
    expect_true("linked module allocated", linkedModule != null)
    linkedModule.environment = env
    linkedModule.runtime = runtime
    runtime.modules = linkedModule

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
}


// ============================================================================
// Part 2: public runtime API over fib32.wasm
// ============================================================================


let FIB32_PATH = "wasm3c/test/lang/fib32.wasm"


struct EnvFixture {
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


// Parse and load fib32.wasm; `fib` is found and compiled when `find` is true.
def private load_fixture(t : T?; find : bool) : EnvFixture {
    var fx : EnvFixture
    var bytes <- read_file(FIB32_PATH)
    t |> equal(length(bytes), 62, "fib32.wasm size")
    if (empty(bytes)) return fx

    fx.env = m3_NewEnvironment()
    fx.runtime = m3_NewRuntime(fx.env, 64u * 1024u, null)
    t |> success(fx.env != null && fx.runtime != null, "environment and runtime")
    if (fx.runtime == null) return fx

    var result = m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes)))
    t |> equal(result, m3Err_none, "m3_ParseModule")
    if (result != m3Err_none) return fx

    result = m3_LoadModule(fx.runtime, fx._module)
    t |> equal(result, m3Err_none, "m3_LoadModule")
    if (result != m3Err_none) {
        m3_FreeModule(fx._module)
        fx._module = null
        return fx
    }

    if (find) {
        result = m3_FindFunction(fx.fib, fx.runtime, "fib")
        t |> equal(result, m3Err_none, "m3_FindFunction fib")
    }
    return fx
}


def private free_fixture(var fx : EnvFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


def private i32_arg(n : int) : array<M3TaggedValue> {
    var args : array<M3TaggedValue>
    args |> resize(1)
    args[0]._type = M3ValueType.c_m3Type_i32
    tagged_set_i32(args[0], n)
    return <- args
}


[test]
def test_env_load_module_links_and_rejects_relinking(t : T?) {
    var fx = load_fixture(t, false)
    if (fx._module == null) return

    // C m3_LoadModule: io_module->next = runtime->modules; runtime->modules = io_module.
    t |> success(fx.runtime.modules == fx._module, "runtime.modules is the loaded module")
    t |> success(fx._module.runtime == fx.runtime, "module.runtime set")
    t |> success(fx._module.next == null, "single module list")

    // C m3_LoadModule: if (io_module->runtime) return m3Err_moduleAlreadyLinked.
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_moduleAlreadyLinked, "second load")

    free_fixture(fx)
}


[test]
def test_env_memory_of_module_without_memory_section(t : T?) {
    var fx = load_fixture(t, false)
    if (fx._module == null) return

    // C InitMemory: memoryInfo is all zero, so maxPages = 65536, pageSize =
    // d_m3DefaultMemPageSize and ResizeMemory(0) allocates a header only.
    t |> equal(fx.runtime.memory.maxPages, 65536u, "maxPages default")
    t |> equal(fx.runtime.memory.pageSize, u32(d_m3DefaultMemPageSize), "pageSize default")
    t |> equal(fx.runtime.memory.numPages, 0u, "numPages")
    t |> success(fx.runtime.memory.mallocated != null, "header allocated")
    t |> equal(m3_GetMemorySize(fx.runtime), 0u, "m3_GetMemorySize")

    var size = 77u
    let memory = m3_GetMemory(fx.runtime, size, 0u)
    t |> equal(size, 0u, "m3_GetMemory size out")
    t |> success(memory == null, "m3_GetMemory returns null for size 0")

    free_fixture(fx)
}


[test]
def test_env_function_signature_queries(t : T?) {
    var fx = load_fixture(t, true)
    if (fx.fib == null) return

    // fib32.wat: (func $fib (param $n i32) (result i32))
    t |> equal(m3_GetArgCount(fx.fib), 1u, "arg count")
    t |> equal(m3_GetRetCount(fx.fib), 1u, "ret count")
    t |> success(m3_GetArgType(fx.fib, 0u) == M3ValueType.c_m3Type_i32, "arg 0 type")
    t |> success(m3_GetRetType(fx.fib, 0u) == M3ValueType.c_m3Type_i32, "ret 0 type")
    // C: index >= numArgs / numRets falls through to c_m3Type_none.
    t |> success(m3_GetArgType(fx.fib, 1u) == M3ValueType.c_m3Type_none, "arg 1 type")
    t |> success(m3_GetRetType(fx.fib, 1u) == M3ValueType.c_m3Type_none, "ret 1 type")
    // C: a null function yields 0 / c_m3Type_none.
    t |> equal(m3_GetArgCount(null), 0u, "arg count of null")
    t |> equal(m3_GetRetCount(null), 0u, "ret count of null")
    t |> success(m3_GetArgType(null, 0u) == M3ValueType.c_m3Type_none, "arg type of null")

    free_fixture(fx)
}


[test]
def test_env_find_function_and_error_info(t : T?) {
    var fx = load_fixture(t, true)
    if (fx.fib == null) return

    // C m3_FindFunction compiles lazily: the found function has code.
    t |> success(fx.fib.compiled != null, "fib compiled by m3_FindFunction")

    // C: _throw (ErrorModule (m3Err_functionLookupFailed, ...)) then *o_function = NULL.
    var missing : IM3Function = fx.fib
    let result = m3_FindFunction(missing, fx.runtime, "no_such_export")
    t |> equal(result, m3Err_functionLookupFailed, "missing export")
    t |> success(missing == null, "o_function cleared on failure")

    // C m3Error stores the result in runtime->error; m3_GetErrorInfo copies and resets it.
    var info : M3ErrorInfo
    m3_GetErrorInfo(fx.runtime, info)
    t |> equal(info.result, m3Err_functionLookupFailed, "error info result")
    t |> success(info.runtime == fx.runtime, "error info runtime")
    t |> success(info._module == fx._module, "error info module")
    t |> equal(info.message, "'no_such_export'", "error info message")
    m3_GetErrorInfo(fx.runtime, info)
    t |> equal(info.result, m3Err_none, "error info reset after read")

    // C m3_FindFunction: if (not i_runtime->modules) _throw ("no modules loaded").
    var bare = m3_NewRuntime(fx.env, 1024u, null)
    var none : IM3Function
    t |> equal(m3_FindFunction(none, bare, "fib"), "no modules loaded", "runtime without modules")
    m3_FreeRuntime(bare)

    free_fixture(fx)
}


[test]
def test_env_globals_and_table_of_fib32(t : T?) {
    var fx = load_fixture(t, true)
    if (fx.fib == null) return

    // fib32 declares no globals and no table.
    t |> success(m3_FindGlobal(fx._module, "anything") == null, "m3_FindGlobal on no globals")
    t |> success(m3_GetGlobalType(null) == M3ValueType.c_m3Type_none, "m3_GetGlobalType(null)")
    var value : M3TaggedValue
    t |> equal(m3_GetGlobal(null, value), m3Err_globalLookupFailed, "m3_GetGlobal(null)")
    t |> equal(m3_SetGlobal(null, value), m3Err_globalLookupFailed, "m3_SetGlobal(null)")

    // C m3_GetTableFunction: i_index >= table0Size -> "function index out of range".
    var fromTable : IM3Function
    t |> equal(m3_GetTableFunction(fromTable, fx._module, 0u), "function index out of range", "empty table")

    free_fixture(fx)
}


[test]
def test_env_call_argument_and_result_protocol(t : T?) {
    var fx = load_fixture(t, true)
    if (fx.fib == null) return

    // C m3_GetResultsV: i_function != runtime->lastCalled -> "function not called".
    var rets : array<M3TaggedValue>
    t |> equal(m3_GetResultsV(fx.fib, rets), "function not called", "results before any call")

    // Typed m3_CallV rejects a wrong argument count like C m3_Call does.
    let noArgs : array<M3TaggedValue>
    t |> equal(m3_CallV(fx.fib, noArgs), m3Err_argumentCountMismatch, "zero arguments")
    var twoArgs : array<M3TaggedValue>
    twoArgs |> resize(2)
    t |> equal(m3_CallV(fx.fib, twoArgs), m3Err_argumentCountMismatch, "two arguments")

    // C m3_Call: argc is checked before the compiled check; m3_Call takes raw pointers.
    var n = 12
    var argptrs : array<void const?>
    argptrs |> push(unsafe(addr<void const?>(n)))
    t |> equal(m3_Call(fx.fib, 1u, argptrs), m3Err_none, "m3_Call fib(12)")
    var out = 0
    var retptrs : array<void?>
    retptrs |> push(unsafe(addr<void?>(out)))
    t |> equal(m3_GetResults(fx.fib, 1u, retptrs), m3Err_none, "m3_GetResults")
    t |> equal(out, 144, "fib(12) through m3_Call/m3_GetResults")
    // C m3_GetResults: i_retc != numRets -> m3Err_argumentCountMismatch.
    t |> equal(m3_GetResults(fx.fib, 2u, retptrs), m3Err_argumentCountMismatch, "wrong ret count")

    // C m3_CallArgv parses decimal text with strtoul.
    var argv : array<string>
    argv |> push("15")
    t |> equal(m3_CallArgv(fx.fib, 1u, argv), m3Err_none, "m3_CallArgv fib(15)")
    t |> equal(m3_GetResultsV(fx.fib, rets), m3Err_none, "results after m3_CallArgv")
    t |> equal(tagged_get_i32(rets[0]), 610, "fib(15)")

    // lastCalled is set only on success; a typed call refreshes it.
    let args <- i32_arg(7)
    t |> equal(m3_CallV(fx.fib, args), m3Err_none, "m3_CallV fib(7)")
    t |> success(fx.runtime.lastCalled == fx.fib, "lastCalled after success")

    free_fixture(fx)
}


[export]
def main() {
    test_env_new_environment_wires_hooks()
    test_env_hook_wiring_is_idempotent()
    test_env_new_runtime_environment_survives_wiring()
    test_env_runtime_releases_linked_module_without_owning_environment()
    print("test_m3_env: hook tests passed\n")
}
