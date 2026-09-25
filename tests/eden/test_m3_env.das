options gen2
options indenting = 4

module test_m3_env shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_exec        // CompileFunctionHook, ResizeMemoryHook, m3_OpCount
require modules/wasm3das/source/m3_exec_defs   // load_u32 over rt.mem
require modules/wasm3das/source/m3_compile     // c_operations
require modules/wasm3das/source/m3_function    // AllocFuncType
require modules/wasm3das/source/m3_module      // Module_AddFunction, Module_AddGlobal
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core

/*
    test_m3_env.das: Eden counterpart of
    .upstream/tests/integration/test_m3_env.das.

    The upstream part 2 parses wasm3c/test/lang/fib32.wasm with
    m3_ParseModule (m3_parse, the next module). Eden: the fixture builds the
    same module by hand in the runtime's arenas, as m3_ParseModule will: one
    interned func type (i32) -> i32 (AllocFuncType + Environment_AddFuncType),
    a module slot with `runtime = -1` (not linked), one function added with
    Module_AddFunction whose body is the code body of fib32.wasm, copied into
    the module's `wasm` array (size byte, locals, code), exported as "fib"
    (names / numNames / export_name as ParseSection_Export sets them). It is
    then loaded with m3_LoadModule, so every upstream check runs on the same
    module through the same API. No test is deferred to m3_parse.

    Coverage of the upstream [test]s (10 of 10 ported):
      - test_env_new_environment_wires_hooks, test_env_hook_wiring_is_idempotent:
        the hooks are cleared first, then wired by m3_NewEnvironment (and the
        environment value has no func types yet: -1 handles).
      - test_env_new_runtime_environment_survives_wiring: the runtime keeps
        the environment's configuration (its custom section handler) and
        userdata; Eden: its copy holds the five interned block-result types,
        the stack is exactly numStackSlots words, the tables are built.
      - test_env_runtime_releases_linked_module_without_owning_environment:
        Runtime_Release frees the linked module (released slot) and the
        stack; the environment value still makes a new runtime.
      - test_env_load_module_links_and_rejects_relinking,
        test_env_memory_of_module_without_memory_section,
        test_env_function_signature_queries,
        test_env_find_function_and_error_info,
        test_env_globals_and_table_of_fib32,
        test_env_call_argument_and_result_protocol: the upstream checks on
        the hand-built fib32 (pointers become handles, -1 = NULL; the raw
        m3_Call takes value bits, m3_GetResults returns them).
    Tests added for the Eden shape (no upstream counterpart):
      - test_env_load_full_module: memory + data segment + globals of the
        four types (exported, one set by the start function) + table / elem
        + start function (run by the first call, not by the load), table
        dispatch through call_indirect with its traps as M3Result strings,
        m3_FindGlobal / m3_GetGlobal / m3_SetGlobal, m3_GetTableFunction;
      - test_env_call_typed_values: args of the four types at the
        c_ioSlotCount stride, a four-result function read back as bits and
        as tagged values, the i32 / i64 / f32 / f64 identity functions
        through m3_Call, m3_CallV and m3_CallArgv (strtoul / strtoull /
        strtod rules, glibc's strtod bits for range errors, inf / nan and
        hexadecimal floats);
      - test_env_trap_and_stack_overflow: `unreachable` and deep recursion on
        a small stack give "[trap] unreachable executed" and
        "[trap] stack overflow" as the m3_Call result; lastCalled is cleared;
        the next call succeeds;
      - test_env_memory_grow: memory.grow / memory.size through
        ResizeMemory, the maximum, a store past the first page, m3_GetMemory
        as an index into rt.mem, ResizeMemory's limits and memoryLimit;
      - test_env_find_function_names: the NULL-vs-"" rule (DESIGN 4.1): an
        import with field name "" is not found by "", a function exported
        as "" is, an internal name is found, a re-exported import is found
        (and fails to compile, it has no body), an export "" wins over a
        local function whose name section entry is "" (C tests
        export_name != NULL: isExported), m3_FindGlobal finds a global
        exported as "" and not an unexported one;
      - test_env_host_panic_restores_origin_stack: a host function
        (CompileRawFunction) that panics makes m3_Call return
        m3Err_panicRunCode with rt.originStack back at its base; the next
        m3_Call / m3_GetResults work;
      - test_env_invalid_body_panics_to_result: a body that panics the
        compiler (local.set on an empty stack) returns
        m3Err_panicCompileFunction from m3_FindFunction / m3_CompileModule,
        a lazy compilation during a call returns m3Err_panicRunCode, a
        function-only opcode in an init expression fails m3_LoadModule with
        C's m3Err_restrictedOpcode, a load that panics (a data segment past
        the module's bytes) returns m3Err_panicLoadModule and leaves the
        module unlinked; no code page stays active and m3_FreeRuntime
        succeeds;
      - test_env_evaluate_expression_and_interning: EvaluateExpression on
        the four constant types and a global.get, leaving the runtime's
        compilation, page lists and error untouched; Environment_AddFuncType
        interning (equal type -> existing handle, slot popped).
*/


// ============================================================================
// Helpers: hand-built modules (what m3_ParseModule will build)
// ============================================================================


let T_NONE : u8 = u8(M3ValueType.c_m3Type_none)
let T_I32 : u8 = u8(M3ValueType.c_m3Type_i32)
let T_I64 : u8 = u8(M3ValueType.c_m3Type_i64)
let T_F32 : u8 = u8(M3ValueType.c_m3Type_f32)
let T_F64 : u8 = u8(M3ValueType.c_m3Type_f64)


// fib32.wasm's code body after its size byte: no locals, then the code
let FIB32_BODY = fixed_array(
    0x00u8,
    0x20u8, 0x00u8, 0x41u8, 0x02u8, 0x49u8, 0x04u8, 0x40u8, 0x20u8, 0x00u8, 0x0fu8, 0x0bu8,
    0x20u8, 0x00u8, 0x41u8, 0x02u8, 0x6bu8, 0x10u8, 0x00u8,
    0x20u8, 0x00u8, 0x41u8, 0x01u8, 0x6bu8, 0x10u8, 0x00u8,
    0x6au8, 0x0fu8, 0x0bu8)


// an empty type list (no results or no arguments)
def private no_types() : array<u8> {
    var types : array<u8>
    return <- types
}


// a runtime of `stackBytes` bytes of stack from a fresh environment
def private new_runtime(stackBytes : u32) : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, stackBytes, -1)
    return <- rt
}


// a module slot as m3_ParseModule leaves it: not linked (runtime -1)
def private add_module(var rt : M3Runtime; name : string) : IM3Module {
    let m = length(rt.modules)
    m3_Realloc_Impl(rt.modules, m + 1, m)
    rt.modules[m].name = name
    return m
}


// appends bytes to the module's binary; returns the index of the first
def private append_bytes(var rt : M3Runtime; m : IM3Module; bytes : array<u8>) : int {
    let start = length(rt.modules[m].wasm)
    for (b in bytes) {
        push(rt.modules[m].wasm, b)
    }
    return start
}


// a func type (rets, then args) interned into the runtime and appended to
// the module's type list; returns its module type index
def private add_type(var rt : M3Runtime; m : IM3Module; rets : array<u8>; args : array<u8>) : u32 {
    var ft : IM3FuncType = -1
    AllocFuncType(rt, ft, u32(length(rets) + length(args)))
    rt.funcTypes[ft].numRets = u16(length(rets))
    rt.funcTypes[ft].numArgs = u16(length(args))
    for (i in range(length(rets))) {
        rt.funcTypes[ft].types[i] = rets[i]
    }
    for (i in range(length(args))) {
        rt.funcTypes[ft].types[length(rets) + i] = args[i]
    }
    Environment_AddFuncType(rt, ft)
    push(rt.modules[m].funcTypes, ft)
    rt.modules[m].numFuncTypes++
    return rt.modules[m].numFuncTypes - 1u
}


// an imported function (ParseSection_Import)
def private add_import(var rt : M3Runtime; m : IM3Module; typeIndex : u32; moduleName : string; fieldName : string) : IM3Function {
    Module_AddFunction(rt, m, typeIndex, M3ImportInfo(moduleUtf8 = moduleName, fieldUtf8 = fieldName), true)
    rt.modules[m].numFuncImports++
    return rt.modules[m].functions[length(rt.modules[m].functions) - 1]
}


// a local function with a body (ParseSection_Function + ParseSection_Code):
// `body` is what follows the size byte (the locals, then the code)
def private add_function(var rt : M3Runtime; m : IM3Module; typeIndex : u32; body : array<u8>) : IM3Function {
    Module_AddFunction(rt, m, typeIndex, M3ImportInfo(), false)
    let f = rt.modules[m].functions[length(rt.modules[m].functions) - 1]
    d_m3Assert(length(body) < 128, "test bodies are shorter than one LEB byte")
    rt.functions[f].moduleIdx = m
    rt.functions[f].wasm = length(rt.modules[m].wasm)
    push(rt.modules[m].wasm, u8(length(body)))
    append_bytes(rt, m, body)
    rt.functions[f].wasmEnd = length(rt.modules[m].wasm)
    return f
}


// ParseSection_Export for a function; Eden: isExported with export_name
// (C: export_name != NULL)
def private export_function(var rt : M3Runtime; f : IM3Function; name : string) {
    let n = int(rt.functions[f].numNames)
    rt.functions[f].names[n] = name
    rt.functions[f].numNames = u16(n + 1)
    rt.functions[f].export_name = name
    rt.functions[f].isExported = true
}


// ParseSection_Global: a global with its init expression (ending in `end`),
// not exported
def private add_unexported_global(var rt : M3Runtime; m : IM3Module; t : u8; mutable : bool; initExpr : array<u8>) : IM3Global {
    var g : IM3Global = -1
    Module_AddGlobal(rt, m, g, t, mutable, false)
    rt.globals[g].initExpr = append_bytes(rt, m, initExpr)
    rt.globals[g].initExprSize = u32(length(initExpr))
    return g
}


// the same global exported as `name` (ParseSection_Export; Eden: isExported
// with the name, C: name != NULL)
def private add_global(var rt : M3Runtime; m : IM3Module; t : u8; mutable : bool; initExpr : array<u8>; name : string) : IM3Global {
    let g = add_unexported_global(rt, m, t, mutable, initExpr)
    rt.globals[g].name = name
    rt.globals[g].isExported = true
    return g
}


// the fib32.wasm module; linked when `load`
def private fib32_module(var t : TestRun; var rt : M3Runtime; load : bool) : IM3Module {
    let m = add_module(rt, "fib32")
    let t0 = add_type(rt, m, [T_I32], [T_I32])
    var body : array<u8>
    for (b in FIB32_BODY) {
        push(body, b)
    }
    let fib = add_function(rt, m, t0, body)
    export_function(rt, fib, "fib")
    if (load) {
        is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule fib32")
    }
    return m
}


// the fixture of upstream part 2: runtime, fib32 loaded, `fib` found when `find`
struct EnvFixture {
    _module : IM3Module = -1
    fib : IM3Function = -1
}


def private load_fixture(var t : TestRun; var rt : M3Runtime; find : bool) : EnvFixture {
    var fx = EnvFixture()
    fx._module = fib32_module(t, rt, true)
    if (find) {
        is_ok(t, m3_FindFunction(rt, fx.fib, "fib"), "m3_FindFunction fib")
    }
    return fx
}


def private i32_arg(n : int) : array<M3TaggedValue> {
    var args : array<M3TaggedValue>
    var v = M3TaggedValue(_type = M3ValueType.c_m3Type_i32)
    tagged_set_i32(v, n)
    push(args, v)
    return <- args
}


def private linked_module_count(rt : M3Runtime) : int {
    var n = 0
    for (m in rt.modules) {
        if (m.runtime != -1) {
            n++
        }
    }
    return n
}


def private expect_hooks_wired(var t : TestRun; stage : string) {
    check(t, CompileFunctionHook != null, "{stage}: CompileFunctionHook wired")
    check(t, ResizeMemoryHook != null, "{stage}: ResizeMemoryHook wired")
}


def private clear_hooks() {
    CompileFunctionHook = default<function<(var rt : M3Runtime; io_function : IM3Function) : M3Result>>
    ResizeMemoryHook = default<function<(var rt : M3Runtime; i_numPages : u32) : M3Result>>
}


def private custom_handler(var rt : M3Runtime; i_module : IM3Module; i_name : cstr_t; i_start : cbytes_t; i_end : cbytes_t) : M3Result {
    return "custom"
}


// ============================================================================
// Upstream part 1: the environment and the hook wiring
// ============================================================================


def test_env_new_environment_wires_hooks(var t : TestRun; fx : FixtureSource) {
    clear_hooks()
    var env = m3_NewEnvironment()
    expect_hooks_wired(t, "first m3_NewEnvironment")
    // Eden: the environment value has no func types of its own (m3_NewRuntime interns them)
    for (i in range(6)) {
        equal(t, env.retFuncTypes[i], -1, "retFuncTypes[{i}] before a runtime")
    }
    check(t, env.customSectionHandler == null, "no custom section handler")
    m3_FreeEnvironment(env)
}


def test_env_hook_wiring_is_idempotent(var t : TestRun; fx : FixtureSource) {
    clear_hooks()
    var first = m3_NewEnvironment()
    var second = m3_NewEnvironment()
    expect_hooks_wired(t, "repeated m3_NewEnvironment")
    m3_FreeEnvironment(second)
    m3_FreeEnvironment(first)
    expect_hooks_wired(t, "after m3_FreeEnvironment")
}


def test_env_new_runtime_environment_survives_wiring(var t : TestRun; fx : FixtureSource) {
    var env = m3_NewEnvironment()
    m3_SetCustomSectionHandler(env, @@custom_handler)
    clear_hooks()

    var runtime <- m3_NewRuntime(env, 65536u, 7)
    expect_hooks_wired(t, "after m3_NewRuntime")
    // C: runtime->environment == env; Eden: the embedded copy keeps its configuration
    check(t, runtime.environment.customSectionHandler != null, "runtime keeps the environment's handler")
    equal_str(t, invoke(runtime.environment.customSectionHandler, runtime, -1, "", 0, 0), "custom", "the handler is the environment's")
    equal(t, m3_GetUserData(runtime), 7, "m3_GetUserData")

    // Eden: the C m3_NewEnvironment loop, interned into the runtime
    for (ti in range(5)) {
        let ft = runtime.environment.retFuncTypes[ti]
        check(t, ft >= 0 && ft < length(runtime.funcTypes), "retFuncTypes[{ti}] is a func type handle")
        if (ft >= 0 && ft < length(runtime.funcTypes)) {
            equal(t, int(runtime.funcTypes[ft].numArgs), 0, "retFuncTypes[{ti}] numArgs")
            equal(t, int(runtime.funcTypes[ft].numRets), ti == 0 ? 0 : 1, "retFuncTypes[{ti}] numRets")
            equal(t, int(runtime.funcTypes[ft].types[0]), ti, "retFuncTypes[{ti}] type")
        }
    }
    equal(t, runtime.environment.retFuncTypes[5], -1, "no retFuncTypes for v128")
    equal(t, length(runtime.funcTypes), 5, "five distinct interned types")
    equal(t, env.retFuncTypes[1], -1, "the caller's environment value is unchanged")

    // Eden: the stack is exactly numStackSlots words (DESIGN 4.4, 4.5)
    equal(t, runtime.numStackSlots, 16384u, "numStackSlots = bytes / sizeof (m3slot_t)")
    equal(t, length(runtime.stack), 16384, "rt.stack has numStackSlots words")
    equal(t, runtime.originStack, 0, "originStack")
    equal(t, length(c_operations), 253, "operation table built")
    equal(t, m3_OpCount(), 510, "op table built")

    m3_FreeRuntime(runtime)
    equal(t, length(runtime.stack), 0, "m3_FreeRuntime frees the stack")
    equal(t, length(runtime.funcTypes), 0, "m3_FreeRuntime frees the arenas")
    m3_FreeEnvironment(env)
    check(t, env.customSectionHandler == null, "m3_FreeEnvironment resets the value")
}


def test_env_runtime_releases_linked_module_without_owning_environment(var t : TestRun; fx : FixtureSource) {
    var env = m3_NewEnvironment()
    var runtime <- m3_NewRuntime(env, 64u * 1024u, -1)

    // the module is linked (C: linkedModule->runtime = runtime; runtime->modules = linkedModule)
    let m = fib32_module(t, runtime, false)
    runtime.modules[m].runtime = 0
    equal(t, Runtime_FirstModule(runtime), m, "the linked module heads the list")

    Runtime_Release(runtime)
    equal(t, runtime.modules[m].runtime, -1, "Runtime_Release frees the linked module")
    equal(t, length(runtime.modules[m].functions), 0, "the module's functions are released")
    equal(t, length(runtime.modules[m].wasm), 0, "the module's binary is released")
    equal(t, length(runtime.stack), 0, "the stack is released")
    equal(t, runtime.originStack, -1, "originStack is NULL")
    equal(t, Runtime_FirstModule(runtime), -1, "no module is linked any more")
    m3_FreeRuntime(runtime)

    // the environment is not owned by the runtime: it still makes runtimes
    var again <- m3_NewRuntime(env, 1024u, -1)
    equal(t, length(again.stack), 256, "a new runtime from the same environment")
    m3_FreeRuntime(again)
    m3_FreeEnvironment(env)
}


// ============================================================================
// Upstream part 2: the public runtime API over fib32
// ============================================================================


def test_env_load_module_links_and_rejects_relinking(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let f = load_fixture(t, rt, false)

    // C m3_LoadModule: io_module->next = runtime->modules; runtime->modules = io_module.
    equal(t, Runtime_FirstModule(rt), f._module, "runtime.modules is the loaded module")
    equal(t, rt.modules[f._module].runtime, 0, "module.runtime set")
    equal(t, linked_module_count(rt), 1, "single module list")

    // C m3_LoadModule: if (io_module->runtime) return m3Err_moduleAlreadyLinked.
    is_err(t, m3_LoadModule(rt, f._module), m3Err_moduleAlreadyLinked, "second load")
    equal(t, linked_module_count(rt), 1, "still a single module")

    m3_FreeRuntime(rt)
}


def test_env_memory_of_module_without_memory_section(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    load_fixture(t, rt, false)

    // C InitMemory: memoryInfo is all zero, so maxPages = 65536, pageSize =
    // d_m3DefaultMemPageSize and ResizeMemory(0) allocates a header only.
    equal(t, rt.memory.maxPages, 65536u, "maxPages default")
    equal(t, rt.memory.pageSize, u32(d_m3DefaultMemPageSize), "pageSize default")
    equal(t, rt.memory.numPages, 0u, "numPages")
    // Eden: "header allocated" is the memory initialized (pageSize set, rt.mem empty)
    check(t, rt.memory.pageSize != 0u, "memory initialized")
    equal(t, length(rt.mem), 0, "no bytes")
    equal(t, m3_GetMemorySize(rt), 0u, "m3_GetMemorySize")

    var size = 77u
    let memory = m3_GetMemory(rt, size, 0u)
    equal(t, size, 0u, "m3_GetMemory size out")
    equal(t, memory, -1, "m3_GetMemory returns NULL for size 0")

    m3_FreeRuntime(rt)
}


def test_env_function_signature_queries(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let f = load_fixture(t, rt, true)

    // fib32.wat: (func $fib (param $n i32) (result i32))
    equal(t, m3_GetArgCount(rt, f.fib), 1u, "arg count")
    equal(t, m3_GetRetCount(rt, f.fib), 1u, "ret count")
    check(t, m3_GetArgType(rt, f.fib, 0u) == M3ValueType.c_m3Type_i32, "arg 0 type")
    check(t, m3_GetRetType(rt, f.fib, 0u) == M3ValueType.c_m3Type_i32, "ret 0 type")
    // C: index >= numArgs / numRets falls through to c_m3Type_none.
    check(t, m3_GetArgType(rt, f.fib, 1u) == M3ValueType.c_m3Type_none, "arg 1 type")
    check(t, m3_GetRetType(rt, f.fib, 1u) == M3ValueType.c_m3Type_none, "ret 1 type")
    // C: a null function yields 0 / c_m3Type_none.
    equal(t, m3_GetArgCount(rt, -1), 0u, "arg count of null")
    equal(t, m3_GetRetCount(rt, -1), 0u, "ret count of null")
    check(t, m3_GetArgType(rt, -1, 0u) == M3ValueType.c_m3Type_none, "arg type of null")
    check(t, m3_GetRetType(rt, -1, 0u) == M3ValueType.c_m3Type_none, "ret type of null")

    m3_FreeRuntime(rt)
}


def test_env_find_function_and_error_info(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let f = load_fixture(t, rt, true)

    // C m3_FindFunction compiles lazily: the found function has code.
    check(t, f.fib != -1 && rt.functions[f.fib].compiled != -1, "fib compiled by m3_FindFunction")

    // C: _throw (ErrorModule (m3Err_functionLookupFailed, ...)) then *o_function = NULL.
    var missing : IM3Function = f.fib
    is_err(t, m3_FindFunction(rt, missing, "no_such_export"), m3Err_functionLookupFailed, "missing export")
    equal(t, missing, -1, "o_function cleared on failure")

    // C m3Error stores the result in runtime->error; m3_GetErrorInfo copies and resets it.
    var info = M3ErrorInfo()
    m3_GetErrorInfo(rt, info)
    equal_str(t, info.result, m3Err_functionLookupFailed, "error info result")
    equal(t, info.runtime, 0, "error info runtime")
    equal(t, info.moduleIdx, f._module, "error info module")
    equal_str(t, info.message, "'no_such_export'", "error info message")
    m3_GetErrorInfo(rt, info)
    equal_str(t, info.result, m3Err_none, "error info reset after read")

    // C m3_FindFunction: if (not i_runtime->modules) _throw ("no modules loaded").
    var bare <- new_runtime(1024u)
    var none : IM3Function = 5
    is_err(t, m3_FindFunction(bare, none, "fib"), "no modules loaded", "runtime without modules")
    equal(t, none, -1, "o_function cleared without modules")
    m3_FreeRuntime(bare)

    m3_FreeRuntime(rt)
}


def test_env_globals_and_table_of_fib32(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let f = load_fixture(t, rt, true)

    // fib32 declares no globals and no table.
    equal(t, m3_FindGlobal(rt, f._module, "anything"), -1, "m3_FindGlobal on no globals")
    check(t, m3_GetGlobalType(rt, -1) == M3ValueType.c_m3Type_none, "m3_GetGlobalType(null)")
    var value = M3TaggedValue()
    is_err(t, m3_GetGlobal(rt, -1, value), m3Err_globalLookupFailed, "m3_GetGlobal(null)")
    is_err(t, m3_SetGlobal(rt, -1, value), m3Err_globalLookupFailed, "m3_SetGlobal(null)")

    // C m3_GetTableFunction: i_index >= table0Size -> "function index out of range".
    var fromTable : IM3Function = -1
    is_err(t, m3_GetTableFunction(rt, fromTable, f._module, 0u), "function index out of range", "empty table")

    m3_FreeRuntime(rt)
}


def test_env_call_argument_and_result_protocol(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let f = load_fixture(t, rt, true)

    // C m3_GetResultsV: i_function != runtime->lastCalled -> "function not called".
    var rets : array<M3TaggedValue>
    is_err(t, m3_GetResultsV(rt, f.fib, rets), "function not called", "results before any call")

    // Typed m3_CallV rejects a wrong argument count like C m3_Call does.
    var noArgs : array<M3TaggedValue>
    is_err(t, m3_CallV(rt, f.fib, noArgs), m3Err_argumentCountMismatch, "zero arguments")
    var twoArgs : array<M3TaggedValue>
    push(twoArgs, M3TaggedValue())
    push(twoArgs, M3TaggedValue())
    is_err(t, m3_CallV(rt, f.fib, twoArgs), m3Err_argumentCountMismatch, "two arguments")

    // C m3_Call: argc is checked before the compiled check; Eden: the arguments are value bits.
    is_ok(t, m3_Call(rt, f.fib, [m3_bits_from_i32(12)]), "m3_Call fib(12)")
    var out : array<u64>
    is_ok(t, m3_GetResults(rt, f.fib, 1u, out), "m3_GetResults")
    equal(t, length(out), 1, "one result")
    equal(t, m3_bits_to_i32(out[0]), 144, "fib(12) through m3_Call/m3_GetResults")
    // C m3_GetResults: i_retc != numRets -> m3Err_argumentCountMismatch.
    is_err(t, m3_GetResults(rt, f.fib, 2u, out), m3Err_argumentCountMismatch, "wrong ret count")
    var noBits : array<u64>
    is_err(t, m3_Call(rt, f.fib, noBits), m3Err_argumentCountMismatch, "m3_Call argc")

    // C m3_CallArgv parses decimal text with strtoul.
    is_ok(t, m3_CallArgv(rt, f.fib, ["15"]), "m3_CallArgv fib(15)")
    is_ok(t, m3_GetResultsV(rt, f.fib, rets), "results after m3_CallArgv")
    equal(t, length(rets), 1, "one tagged result")
    check(t, rets[0]._type == M3ValueType.c_m3Type_i32, "tagged result type")
    equal(t, tagged_get_i32(rets[0]), 610, "fib(15)")

    // lastCalled is set only on success; a typed call refreshes it.
    var args <- i32_arg(7)
    is_ok(t, m3_CallV(rt, f.fib, args), "m3_CallV fib(7)")
    equal(t, rt.lastCalled, f.fib, "lastCalled after success")
    is_ok(t, m3_GetResultsV(rt, f.fib, rets), "results after m3_CallV")
    equal(t, tagged_get_i32(rets[0]), 13, "fib(7)")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: a module with memory, data, globals, table and a start function
// ============================================================================


// calls an exported (i32) -> i32 function by name; the trap or m3Err_none,
// the value in `out`
def private call_i32_i32(var rt : M3Runtime; name : string; n : int; var out : int&) : M3Result {
    var f : IM3Function = -1
    var result = m3_FindFunction(rt, f, name)
    if (result != m3Err_none) {
        return result
    }
    result = m3_Call(rt, f, [m3_bits_from_i32(n)])
    if (result != m3Err_none) {
        return result
    }
    var bits : array<u64>
    result = m3_GetResults(rt, f, 1u, bits)
    if (result == m3Err_none) {
        out = m3_bits_to_i32(bits[0])
    }
    return result
}


// calls an exported () -> i32 function by name
def private call_void_i32(var rt : M3Runtime; name : string; var out : int&) : M3Result {
    var f : IM3Function = -1
    var result = m3_FindFunction(rt, f, name)
    if (result != m3Err_none) {
        return result
    }
    var none : array<u64>
    result = m3_Call(rt, f, none)
    if (result != m3Err_none) {
        return result
    }
    var bits : array<u64>
    result = m3_GetResults(rt, f, 1u, bits)
    if (result == m3Err_none) {
        out = m3_bits_to_i32(bits[0])
    }
    return result
}


def private full_module(var rt : M3Runtime) : IM3Module {
    let m = add_module(rt, "full")
    let t0 = add_type(rt, m, no_types(), no_types())
    let t1 = add_type(rt, m, [T_I32], no_types())
    let t2 = add_type(rt, m, [T_I32], [T_I32])

    // (func $start  i32.const 0  i32.const 7  i32.store  i32.const 5  global.set 1)
    add_function(rt, m, t0, [0x00u8, 0x41u8, 0x00u8, 0x41u8, 0x07u8, 0x36u8, 0x02u8, 0x00u8, 0x41u8, 0x05u8, 0x24u8, 0x01u8, 0x0bu8])
    let a = add_function(rt, m, t1, [0x00u8, 0x41u8, 0x0bu8, 0x0bu8])                 // i32.const 11
    let b = add_function(rt, m, t1, [0x00u8, 0x41u8, 0x16u8, 0x0bu8])                 // i32.const 22
    let dispatch = add_function(rt, m, t2, [0x00u8, 0x20u8, 0x00u8, 0x11u8, 0x01u8, 0x00u8, 0x0bu8])   // call_indirect (type 1)
    let peek = add_function(rt, m, t2, [0x00u8, 0x20u8, 0x00u8, 0x28u8, 0x02u8, 0x00u8, 0x0bu8])       // i32.load
    let counter = add_function(rt, m, t1, [0x00u8, 0x23u8, 0x01u8, 0x0bu8])           // global.get 1
    export_function(rt, a, "a")
    export_function(rt, b, "b")
    export_function(rt, dispatch, "dispatch")
    export_function(rt, peek, "peek")
    export_function(rt, counter, "counter")
    rt.modules[m].startFunction = 0

    add_global(rt, m, T_I32, false, [0x41u8, 0x2au8, 0x0bu8], "g_i32")                // 42
    add_global(rt, m, T_I32, true, [0x41u8, 0x00u8, 0x0bu8], "g_counter")             // 0, the start function sets 5
    add_global(rt, m, T_I64, true, [0x42u8, 0x7fu8, 0x0bu8], "g_i64")                 // -1
    add_global(rt, m, T_F32, false, [0x43u8, 0x00u8, 0x00u8, 0xc0u8, 0x3fu8, 0x0bu8], "g_f32")   // 1.5
    add_global(rt, m, T_F64, true, [0x44u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x02u8, 0x40u8, 0x0bu8], "g_f64")   // 2.25

    rt.modules[m].memoryInfo.initPages = 1u
    rt.modules[m].memoryInfo.maxPages = 2u

    // (data (i32.const 16) "hi!")
    let dataExpr = append_bytes(rt, m, [0x41u8, 0x10u8, 0x0bu8])
    let data = append_bytes(rt, m, [0x68u8, 0x69u8, 0x21u8])
    push(rt.modules[m].dataSegments, M3DataSegment(initExpr = dataExpr, initExprSize = 3u, data = data, size = 3u))
    rt.modules[m].numDataSegments = 1u

    // (elem (i32.const 1) $a $b $peek): table 0, offset expression, count, indices
    rt.modules[m].elementSection = append_bytes(rt, m, [0x00u8, 0x41u8, 0x01u8, 0x0bu8, 0x03u8, 0x01u8, 0x02u8, 0x04u8])
    rt.modules[m].elementSectionEnd = length(rt.modules[m].wasm)
    rt.modules[m].numElementSegments = 1u
    return m
}


def test_env_load_full_module(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = full_module(rt)
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule of the full module")
    equal(t, rt.numActiveCodePages, 0u, "no code page active after the load")

    // InitMemory / ResizeMemory
    equal(t, rt.memory.numPages, 1u, "one page")
    equal(t, rt.memory.maxPages, 2u, "maxPages from the module")
    equal(t, m3_GetMemorySize(rt), 65536u, "memory size")
    // InitDataSegments
    equal(t, rt.mem[16], 0x68u8, "data byte 0")
    equal(t, rt.mem[17], 0x69u8, "data byte 1")
    equal(t, rt.mem[18], 0x21u8, "data byte 2")
    equal(t, int(rt.mem[15]), 0, "before the segment")
    // the start function has not run yet (C runs it before the first call)
    equal(t, rt.modules[m].startFunction, 0, "start function pending")
    equal(t, load_u32(rt, 0), 0u, "memory untouched before the start function")

    // InitGlobals, m3_FindGlobal, m3_GetGlobal
    var v = M3TaggedValue()
    let g_i32 = m3_FindGlobal(rt, m, "g_i32")
    check(t, g_i32 != -1, "g_i32 found")
    is_ok(t, m3_GetGlobal(rt, g_i32, v), "m3_GetGlobal g_i32")
    check(t, v._type == M3ValueType.c_m3Type_i32, "g_i32 type")
    equal(t, tagged_get_i32(v), 42, "g_i32 value")
    is_ok(t, m3_GetGlobal(rt, m3_FindGlobal(rt, m, "g_i64"), v), "m3_GetGlobal g_i64")
    check(t, v._type == M3ValueType.c_m3Type_i64, "g_i64 type")
    equal(t, tagged_get_i64(v), -1l, "g_i64 value")
    is_ok(t, m3_GetGlobal(rt, m3_FindGlobal(rt, m, "g_f32"), v), "m3_GetGlobal g_f32")
    check(t, v._type == M3ValueType.c_m3Type_f32, "g_f32 type")
    equal(t, tagged_get_f32(v), 1.5f, "g_f32 value")
    is_ok(t, m3_GetGlobal(rt, m3_FindGlobal(rt, m, "g_f64"), v), "m3_GetGlobal g_f64")
    equal(t, tagged_get_f64(v), 2.25lf, "g_f64 value")
    check(t, m3_GetGlobalType(rt, m3_FindGlobal(rt, m, "g_f64")) == M3ValueType.c_m3Type_f64, "m3_GetGlobalType")
    equal(t, m3_FindGlobal(rt, m, "nope"), -1, "unknown global")

    // m3_SetGlobal: C's three checks, then the store
    var nv = M3TaggedValue(_type = M3ValueType.c_m3Type_i32)
    tagged_set_i32(nv, 9)
    is_err(t, m3_SetGlobal(rt, g_i32, nv), m3Err_globalNotMutable, "immutable global")
    let g_f64 = m3_FindGlobal(rt, m, "g_f64")
    is_err(t, m3_SetGlobal(rt, g_f64, nv), m3Err_globalTypeMismatch, "type mismatch")
    var fv = M3TaggedValue(_type = M3ValueType.c_m3Type_f64)
    tagged_set_f64(fv, -0.5lf)
    is_ok(t, m3_SetGlobal(rt, g_f64, fv), "m3_SetGlobal g_f64")
    is_ok(t, m3_GetGlobal(rt, g_f64, v), "read back g_f64")
    equal(t, tagged_get_f64(v), -0.5lf, "g_f64 after m3_SetGlobal")

    // InitElements: table0 = [NULL, a, b, peek]
    equal(t, rt.modules[m].table0Size, 4u, "table size")
    equal(t, rt.modules[m].table0[0], -1, "table[0] NULL")
    equal(t, rt.modules[m].table0[1], rt.modules[m].functions[1], "table[1] = a")
    equal(t, rt.modules[m].table0[2], rt.modules[m].functions[2], "table[2] = b")
    equal(t, rt.modules[m].table0[3], rt.modules[m].functions[4], "table[3] = peek")
    var fromTable : IM3Function = -1
    is_ok(t, m3_GetTableFunction(rt, fromTable, m, 1u), "m3_GetTableFunction 1")
    equal(t, fromTable, rt.modules[m].functions[1], "table function 1")
    check(t, rt.functions[fromTable].compiled != -1, "the table function is compiled")
    is_ok(t, m3_GetTableFunction(rt, fromTable, m, 0u), "m3_GetTableFunction of a NULL entry")
    equal(t, fromTable, -1, "NULL table entry")
    is_err(t, m3_GetTableFunction(rt, fromTable, m, 4u), "function index out of range", "past the table")

    // the first call runs the start function (checkStartFunction)
    var out = 0
    is_ok(t, call_i32_i32(rt, "peek", 16, out), "peek(16)")
    equal(t, u32(out), 0x00216968u, "the data segment read by i32.load")
    equal(t, rt.modules[m].startFunction, -1, "start function consumed")
    equal(t, load_u32(rt, 0), 7u, "the start function stored 7")
    is_ok(t, call_void_i32(rt, "counter", out), "counter()")
    equal(t, out, 5, "the start function set the mutable global")
    is_ok(t, call_i32_i32(rt, "peek", 0, out), "peek(0)")
    equal(t, out, 7, "peek(0)")

    // call_indirect through the table, and its traps as M3Result strings
    is_ok(t, call_i32_i32(rt, "dispatch", 1, out), "dispatch(1)")
    equal(t, out, 11, "table[1] = a")
    is_ok(t, call_i32_i32(rt, "dispatch", 2, out), "dispatch(2)")
    equal(t, out, 22, "table[2] = b")
    is_err(t, call_i32_i32(rt, "dispatch", 0, out), m3Err_trapTableElementIsNull, "dispatch(0): NULL element")
    is_err(t, call_i32_i32(rt, "dispatch", 3, out), m3Err_trapIndirectCallTypeMismatch, "dispatch(3): peek has another type")
    is_err(t, call_i32_i32(rt, "dispatch", 4, out), m3Err_trapTableIndexOutOfRange, "dispatch(4): past the table")
    is_err(t, call_i32_i32(rt, "peek", 65535, out), m3Err_trapOutOfBoundsMemoryAccess, "peek past the memory")
    is_ok(t, call_i32_i32(rt, "dispatch", 1, out), "dispatch(1) after the traps")
    equal(t, out, 11, "a call after a trap")

    // m3_CompileModule compiles what is left
    is_ok(t, m3_CompileModule(rt, m), "m3_CompileModule")
    for (i in range(int(rt.modules[m].numFunctions))) {
        check(t, rt.functions[rt.modules[m].functions[i]].compiled != -1, "function {i} compiled")
    }

    // a data segment past the memory fails the load and unlinks the module
    var rt2 <- new_runtime(64u * 1024u)
    let m2 = full_module(rt2)
    rt2.modules[m2].memoryInfo.initPages = 0u
    is_err(t, m3_LoadModule(rt2, m2), "data segment out of bounds", "data segment past the memory")
    equal(t, rt2.modules[m2].runtime, -1, "a failed load unlinks the module")
    equal(t, Runtime_FirstModule(rt2), -1, "no module linked")
    m3_FreeRuntime(rt2)

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: the four value types through the call API
// ============================================================================


def test_env_call_typed_values(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = add_module(rt, "typed")
    let tMix = add_type(rt, m, [T_F64], [T_I32, T_I64, T_F32, T_F64])
    let tMulti = add_type(rt, m, [T_I32, T_I64, T_F32, T_F64], no_types())
    let tI32 = add_type(rt, m, [T_I32], [T_I32])
    let tI64 = add_type(rt, m, [T_I64], [T_I64])
    let tF32 = add_type(rt, m, [T_F32], [T_F32])
    let tF64 = add_type(rt, m, [T_F64], [T_F64])
    // f64(a) + f64(b) + f64(c) + d
    let mix = add_function(rt, m, tMix, [0x00u8, 0x20u8, 0x00u8, 0xb7u8, 0x20u8, 0x01u8, 0xb9u8, 0xa0u8, 0x20u8, 0x02u8, 0xbbu8, 0xa0u8, 0x20u8, 0x03u8, 0xa0u8, 0x0bu8])
    // (i32 -7, i64 8, f32 1.5, f64 2.25)
    let multi = add_function(rt, m, tMulti, [0x00u8, 0x41u8, 0x79u8, 0x42u8, 0x08u8, 0x43u8, 0x00u8, 0x00u8, 0xc0u8, 0x3fu8, 0x44u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x02u8, 0x40u8, 0x0bu8])
    let idI32 = add_function(rt, m, tI32, [0x00u8, 0x20u8, 0x00u8, 0x0bu8])
    let idI64 = add_function(rt, m, tI64, [0x00u8, 0x20u8, 0x00u8, 0x0bu8])
    let idF32 = add_function(rt, m, tF32, [0x00u8, 0x20u8, 0x00u8, 0x0bu8])
    let idF64 = add_function(rt, m, tF64, [0x00u8, 0x20u8, 0x00u8, 0x0bu8])
    export_function(rt, mix, "mix")
    export_function(rt, multi, "multi")
    export_function(rt, idI32, "id_i32")
    export_function(rt, idI64, "id_i64")
    export_function(rt, idF32, "id_f32")
    export_function(rt, idF64, "id_f64")
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule typed")
    var f : IM3Function = -1
    for (name in ["mix", "multi", "id_i32", "id_i64", "id_f32", "id_f64"]) {
        is_ok(t, m3_FindFunction(rt, f, name), "m3_FindFunction {name}")
    }

    // four argument types at the c_ioSlotCount stride (m3_Call, bits)
    var bits : array<u64>
    is_ok(t, m3_Call(rt, mix, [m3_bits_from_i32(3), m3_bits_from_i64(-10l), m3_bits_from_f32(1.5f), m3_bits_from_f64(0.25lf)]), "m3_Call mix")
    is_ok(t, m3_GetResults(rt, mix, 1u, bits), "m3_GetResults mix")
    equal(t, m3_bits_to_f64(bits[0]), -5.25lf, "mix(3, -10, 1.5, 0.25)")
    // the same through m3_CallV (tagged)
    var targs : array<M3TaggedValue>
    var a0 = M3TaggedValue(_type = M3ValueType.c_m3Type_i32)
    tagged_set_i32(a0, -1)
    var a1 = M3TaggedValue(_type = M3ValueType.c_m3Type_i64)
    tagged_set_i64(a1, 1000000000000l)
    var a2 = M3TaggedValue(_type = M3ValueType.c_m3Type_f32)
    tagged_set_f32(a2, -0.5f)
    var a3 = M3TaggedValue(_type = M3ValueType.c_m3Type_f64)
    tagged_set_f64(a3, 0.125lf)
    push(targs, a0)
    push(targs, a1)
    push(targs, a2)
    push(targs, a3)
    is_ok(t, m3_CallV(rt, mix, targs), "m3_CallV mix")
    var rets : array<M3TaggedValue>
    is_ok(t, m3_GetResultsV(rt, mix, rets), "m3_GetResultsV mix")
    check(t, rets[0]._type == M3ValueType.c_m3Type_f64, "mix result type")
    equal(t, tagged_get_f64(rets[0]), 999999999998.625lf, "mix(-1, 1e12, -0.5, 0.125)")
    // the same through m3_CallArgv (strings)
    is_ok(t, m3_CallArgv(rt, mix, ["2", "40", "0.5", "-0.25"]), "m3_CallArgv mix")
    is_ok(t, m3_GetResults(rt, mix, 1u, bits), "m3_GetResults after m3_CallArgv")
    equal(t, m3_bits_to_f64(bits[0]), 42.25lf, "mix(2, 40, 0.5, -0.25)")

    // four result types at the stride
    var none : array<u64>
    is_ok(t, m3_Call(rt, multi, none), "m3_Call multi")
    is_ok(t, m3_GetResults(rt, multi, 4u, bits), "m3_GetResults multi")
    equal(t, length(bits), 4, "four results")
    equal(t, bits[0], 0xfffffff9ul, "i32 result bits (zero-extended)")
    equal(t, m3_bits_to_i32(bits[0]), -7, "i32 result")
    equal(t, m3_bits_to_i64(bits[1]), 8l, "i64 result")
    equal(t, bits[2], 0x3fc00000ul, "f32 result bits")
    equal(t, m3_bits_to_f32(bits[2]), 1.5f, "f32 result")
    equal(t, m3_bits_to_f64(bits[3]), 2.25lf, "f64 result")
    is_err(t, m3_GetResults(rt, multi, 1u, bits), m3Err_argumentCountMismatch, "wrong ret count")
    is_ok(t, m3_GetResultsV(rt, multi, rets), "m3_GetResultsV multi")
    equal(t, length(rets), 4, "four tagged results")
    check(t, rets[0]._type == M3ValueType.c_m3Type_i32 && rets[1]._type == M3ValueType.c_m3Type_i64, "tagged types 0, 1")
    check(t, rets[2]._type == M3ValueType.c_m3Type_f32 && rets[3]._type == M3ValueType.c_m3Type_f64, "tagged types 2, 3")
    equal(t, tagged_get_i32(rets[0]), -7, "tagged i32")
    equal(t, tagged_get_i64(rets[1]), 8l, "tagged i64")
    equal(t, tagged_get_f32(rets[2]), 1.5f, "tagged f32")
    equal(t, tagged_get_f64(rets[3]), 2.25lf, "tagged f64")

    // bits round trips through the identity functions
    is_ok(t, m3_Call(rt, idF32, [m3_bits_from_f32(-2.5f)]), "id_f32")
    is_ok(t, m3_GetResults(rt, idF32, 1u, bits), "id_f32 results")
    equal(t, bits[0], m3_bits_from_f32(-2.5f), "f32 bits round trip")
    is_ok(t, m3_Call(rt, idF64, [0x7ff8000000000123ul]), "id_f64 NaN")
    is_ok(t, m3_GetResults(rt, idF64, 1u, bits), "id_f64 NaN results")
    equal(t, bits[0], 0x7ff8000000000123ul, "f64 NaN payload round trip")
    is_ok(t, m3_Call(rt, idI64, [0x8000000000000001ul]), "id_i64")
    is_ok(t, m3_GetResults(rt, idI64, 1u, bits), "id_i64 results")
    equal(t, bits[0], 0x8000000000000001ul, "i64 bits round trip")

    // m3_CallArgv: C's strtoul / strtoull / strtod
    let i32Cases = [("-1", -1), ("4294967295", -1), ("  42abc", 42), ("abc", 0), ("4294967296", 0), ("+7", 7)]
    for (c in i32Cases) {
        is_ok(t, m3_CallArgv(rt, idI32, [c._0]), "id_i32(\"{c._0}\")")
        is_ok(t, m3_GetResults(rt, idI32, 1u, bits), "id_i32 results")
        equal(t, m3_bits_to_i32(bits[0]), c._1, "strtoul(\"{c._0}\")")
    }
    let i64Cases = [("18446744073709551615", -1l), ("99999999999999999999", -1l), ("-9223372036854775808", -9223372036854775807l - 1l), ("123", 123l), ("-0", 0l)]
    for (c in i64Cases) {
        is_ok(t, m3_CallArgv(rt, idI64, [c._0]), "id_i64(\"{c._0}\")")
        is_ok(t, m3_GetResults(rt, idI64, 1u, bits), "id_i64 results")
        equal(t, m3_bits_to_i64(bits[0]), c._1, "strtoull(\"{c._0}\")")
    }
    let f64Cases = [("+2.5", 2.5lf), (" -0.5", -0.5lf), ("1e3", 1000.0lf), ("x", 0.0lf)]
    for (c in f64Cases) {
        is_ok(t, m3_CallArgv(rt, idF64, [c._0]), "id_f64(\"{c._0}\")")
        is_ok(t, m3_GetResults(rt, idF64, 1u, bits), "id_f64 results")
        equal(t, m3_bits_to_f64(bits[0]), c._1, "strtod(\"{c._0}\")")
    }
    // strtod as glibc: the expected bits are glibc's (strtod compiled and
    // run on the C side): range errors, inf / nan, hexadecimal floats
    let f64BitsCases = [
        ("1e400", 0x7ff0000000000000ul), ("-1e400", 0xfff0000000000000ul),
        ("1e309", 0x7ff0000000000000ul), ("1.8e308", 0x7ff0000000000000ul),
        ("1.7976931348623157e308", 0x7feffffffffffffful),
        ("1e-400", 0ul), ("-1e-400", 0x8000000000000000ul),
        ("4.9e-324", 1ul), ("2e-324", 0ul),
        ("0x1p3", 0x4020000000000000ul), ("0x10", 0x4030000000000000ul),
        ("-0x10", 0xc030000000000000ul), ("0x1.8p1", 0x4008000000000000ul),
        ("0X1P-2", 0x3fd0000000000000ul), ("0x.8", 0x3fe0000000000000ul),
        ("0xAbC.dEp-4", 0x406579bc00000000ul), (" 0x1P+4x", 0x4030000000000000ul),
        ("0x", 0ul), ("-0x", 0x8000000000000000ul), ("0x1p", 0x3ff0000000000000ul),
        ("0x1p1024", 0x7ff0000000000000ul), ("0x1p-1074", 1ul), ("0x1p-1075", 0ul),
        ("0x3p-1076", 1ul), ("0x1.fffffffffffff8p1023", 0x7ff0000000000000ul),
        ("0x1.00000000000008p0", 0x3ff0000000000000ul), ("0x1.000000000000081p0", 0x3ff0000000000001ul),
        ("0x123456789abcdef123p0", 0x44323456789abcdful),
        ("INF", 0x7ff0000000000000ul), ("-infinity", 0xfff0000000000000ul), ("infx", 0x7ff0000000000000ul),
        ("NAN", 0x7ff8000000000000ul), ("-nan", 0xfff8000000000000ul),
        ("nan(123)", 0x7ff800000000007bul), ("nan(0x7b)", 0x7ff800000000007bul), ("nan(abc_1)", 0x7ff8000000000000ul),
        ("1e", 0x3ff0000000000000ul), ("1.5e3x", 0x4097700000000000ul), ("+-1", 0ul), ("5.", 0x4014000000000000ul)]
    for (c in f64BitsCases) {
        is_ok(t, m3_CallArgv(rt, idF64, [c._0]), "id_f64(\"{c._0}\")")
        is_ok(t, m3_GetResults(rt, idF64, 1u, bits), "id_f64 results")
        equal(t, bits[0], c._1, "strtod(\"{c._0}\") bits")
    }
    is_ok(t, m3_CallArgv(rt, idF32, ["0.1"]), "id_f32(\"0.1\")")
    is_ok(t, m3_GetResults(rt, idF32, 1u, bits), "id_f32 results")
    equal(t, m3_bits_to_f32(bits[0]), f32(0.1lf), "f32 of strtod (C: the double narrowed)")
    is_ok(t, m3_CallArgv(rt, idF32, ["-1e400"]), "id_f32(\"-1e400\")")
    is_ok(t, m3_GetResults(rt, idF32, 1u, bits), "id_f32 results")
    equal(t, bits[0], 0xff800000ul, "f32 of strtod(\"-1e400\") is -inf")
    is_err(t, m3_CallArgv(rt, idF32, ["1", "2"]), m3Err_argumentCountMismatch, "m3_CallArgv argc")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: traps as the call's M3Result, stack overflow on a small stack
// ============================================================================


def test_env_trap_and_stack_overflow(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(1024u)   // 256 slots
    let m = add_module(rt, "traps")
    let t0 = add_type(rt, m, [T_I32], [T_I32])
    let t1 = add_type(rt, m, [T_I32], no_types())
    let recurse = add_function(rt, m, t0, [0x00u8, 0x20u8, 0x00u8, 0x10u8, 0x00u8, 0x0bu8])   // local.get 0; call 0
    let boom = add_function(rt, m, t1, [0x00u8, 0x00u8, 0x0bu8])                           // unreachable
    let ok = add_function(rt, m, t1, [0x00u8, 0x41u8, 0x05u8, 0x0bu8])                     // i32.const 5
    export_function(rt, recurse, "recurse")
    export_function(rt, boom, "boom")
    export_function(rt, ok, "ok")
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule traps")

    var out = 0
    is_err(t, call_i32_i32(rt, "recurse", 1, out), m3Err_trapStackOverflow, "deep recursion traps")
    equal(t, rt.lastCalled, -1, "lastCalled cleared by a trap")
    var bits : array<u64>
    is_err(t, m3_GetResults(rt, recurse, 1u, bits), "function not called", "no results after a trap")
    equal(t, rt.sp, -1, "the registers are restored after the call")

    is_err(t, call_void_i32(rt, "boom", out), m3Err_trapUnreachable, "unreachable traps")
    equal_str(t, rt.trap, m3Err_trapUnreachable, "rt.trap holds the trap")

    is_ok(t, call_void_i32(rt, "ok", out), "a call after the traps")
    equal(t, out, 5, "ok()")
    equal_str(t, rt.trap, m3Err_none, "rt.trap reset by the call")
    equal(t, rt.lastCalled, ok, "lastCalled after success")
    equal(t, rt.numActiveCodePages, 0u, "no code page active")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: memory.grow through ResizeMemory
// ============================================================================


def test_env_memory_grow(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = add_module(rt, "grow")
    let tGrow = add_type(rt, m, [T_I32], [T_I32])
    let tSize = add_type(rt, m, [T_I32], no_types())
    let tStore = add_type(rt, m, no_types(), [T_I32, T_I32])
    export_function(rt, add_function(rt, m, tGrow, [0x00u8, 0x20u8, 0x00u8, 0x40u8, 0x00u8, 0x0bu8]), "grow")   // memory.grow
    export_function(rt, add_function(rt, m, tSize, [0x00u8, 0x3fu8, 0x00u8, 0x0bu8]), "size")                   // memory.size
    let store = add_function(rt, m, tStore, [0x00u8, 0x20u8, 0x00u8, 0x20u8, 0x01u8, 0x36u8, 0x02u8, 0x00u8, 0x0bu8])   // i32.store
    export_function(rt, store, "store")
    rt.modules[m].memoryInfo.initPages = 1u
    rt.modules[m].memoryInfo.maxPages = 3u
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule grow")
    var f : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, f, "store"), "m3_FindFunction store")

    var out = 0
    is_ok(t, call_void_i32(rt, "size", out), "size()")
    equal(t, out, 1, "one page")
    is_err(t, m3_Call(rt, store, [m3_bits_from_i32(70000), m3_bits_from_i32(305419896)]), m3Err_trapOutOfBoundsMemoryAccess, "store past the first page")

    is_ok(t, call_i32_i32(rt, "grow", 1, out), "grow(1)")
    equal(t, out, 1, "memory.grow returns the previous size")
    is_ok(t, call_void_i32(rt, "size", out), "size() after grow")
    equal(t, out, 2, "two pages")
    equal(t, rt.memory.numPages, 2u, "numPages")
    equal(t, m3_GetMemorySize(rt), 131072u, "m3_GetMemorySize after grow")
    is_ok(t, m3_Call(rt, store, [m3_bits_from_i32(70000), m3_bits_from_i32(305419896)]), "store in the new page")
    var size = 0u
    let base = m3_GetMemory(rt, size, 0u)
    equal(t, base, 0, "m3_GetMemory: the index of the first byte")
    equal(t, size, 131072u, "m3_GetMemory size")
    equal(t, load_u32(rt, base + 70000), 0x12345678u, "the stored word through rt.mem")
    equal(t, load_u32(rt, base + 65536), 0u, "the grown page is zero")

    is_ok(t, call_i32_i32(rt, "grow", 5, out), "grow(5)")
    equal(t, out, -1, "grow past maxPages fails with -1")
    is_ok(t, call_i32_i32(rt, "grow", -1, out), "grow(-1)")
    equal(t, out, -1, "a negative grow fails with -1")
    is_ok(t, call_i32_i32(rt, "grow", 0, out), "grow(0)")
    equal(t, out, 2, "grow(0) returns the size")
    equal(t, m3_GetMemorySize(rt), 131072u, "the size is unchanged by the failed grows")

    // ResizeMemory directly: the maximum and memoryLimit
    is_err(t, ResizeMemory(rt, 4u), m3Err_wasmMemoryOverflow, "ResizeMemory past maxPages")
    rt.memoryLimit = 70004u
    is_ok(t, ResizeMemory(rt, 3u), "ResizeMemory under memoryLimit")
    equal(t, rt.memory.numPages, 3u, "numPages is the requested count")
    equal(t, length(rt.mem), 70004, "the bytes are limited by memoryLimit")
    equal(t, load_u32(rt, 70000), 0x12345678u, "the bytes survive the resize")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: m3_FindFunction and the NULL-vs-"" names
// ============================================================================


def test_env_find_function_names(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = add_module(rt, "names")
    let t0 = add_type(rt, m, [T_I32], no_types())
    let imp = add_import(rt, m, t0, "env", "")                      // (import "env" "" (func))
    let empty = add_function(rt, m, t0, [0x00u8, 0x41u8, 0x01u8, 0x0bu8])
    let internal = add_function(rt, m, t0, [0x00u8, 0x41u8, 0x02u8, 0x0bu8])
    export_function(rt, empty, "")                                   // (export "" (func 1))
    rt.functions[internal].names[0] = "internal"                    // a name section entry
    rt.functions[internal].numNames = u16(1)
    export_function(rt, imp, "reexp")                                // (export "reexp" (func 0))
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule names")

    equal(t, v_FindFunction(rt, m, ""), empty, "v_FindFunction(\"\") is the export, not the import")
    var f : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, f, ""), "m3_FindFunction(\"\")")
    equal(t, f, empty, "the function exported as \"\"")
    var none : array<u64>
    is_ok(t, m3_Call(rt, f, none), "call the \"\" export")
    var bits : array<u64>
    is_ok(t, m3_GetResults(rt, f, 1u, bits), "results of the \"\" export")
    equal(t, m3_bits_to_i32(bits[0]), 1, "the \"\" export returns 1")

    is_ok(t, m3_FindFunction(rt, f, "internal"), "m3_FindFunction internal name")
    equal(t, f, internal, "found through names[]")
    equal(t, v_FindFunction(rt, m, "reexp"), imp, "a re-exported import is found")
    is_err(t, m3_FindFunction(rt, f, "reexp"), "function body is missing", "an unlinked import cannot compile")
    equal(t, f, -1, "o_function cleared")
    equal(t, v_FindFunction(rt, m, "env"), -1, "the import module name is not a function name")
    m3_FreeRuntime(rt)

    // only the import is named "": C skips it in both loops
    var rt2 <- new_runtime(64u * 1024u)
    let m2 = add_module(rt2, "names2")
    let t2 = add_type(rt2, m2, [T_I32], no_types())
    add_import(rt2, m2, t2, "env", "")
    let x = add_function(rt2, m2, t2, [0x00u8, 0x41u8, 0x03u8, 0x0bu8])
    export_function(rt2, x, "x")
    is_ok(t, m3_LoadModule(rt2, m2), "m3_LoadModule names2")
    equal(t, v_FindFunction(rt2, m2, ""), -1, "an import with field \"\" is not found by \"\"")
    var g : IM3Function = 3
    is_err(t, m3_FindFunction(rt2, g, ""), m3Err_functionLookupFailed, "m3_FindFunction(\"\") fails")
    equal(t, g, -1, "o_function cleared")
    is_ok(t, m3_FindFunction(rt2, g, "x"), "m3_FindFunction x")
    equal(t, g, x, "x found")
    m3_FreeRuntime(rt2)

    // a local function named "" by the name section only, before the
    // function exported as "": C returns the export (the export loop tests
    // export_name != NULL, the name section sets no export)
    var rt3 <- new_runtime(64u * 1024u)
    let m3 = add_module(rt3, "names3")
    let t3 = add_type(rt3, m3, [T_I32], no_types())
    let named = add_function(rt3, m3, t3, [0x00u8, 0x41u8, 0x04u8, 0x0bu8])
    let exported = add_function(rt3, m3, t3, [0x00u8, 0x41u8, 0x05u8, 0x0bu8])
    rt3.functions[named].names[0] = ""                               // ParseSection_Name
    rt3.functions[named].numNames = u16(1)
    export_function(rt3, exported, "")                               // (export "" (func 1))
    check(t, !rt3.functions[named].isExported, "a name section entry is no export")
    is_ok(t, m3_LoadModule(rt3, m3), "m3_LoadModule names3")
    equal(t, v_FindFunction(rt3, m3, ""), exported, "v_FindFunction(\"\") is the export (C), not the named function")
    rt3.functions[exported].isExported = false                       // no export at all: the name section entry
    equal(t, v_FindFunction(rt3, m3, ""), named, "without the export, the first name \"\" (names[] loop)")
    rt3.functions[exported].isExported = true

    // m3_FindGlobal: C's `g->name != NULL` is isExported
    let gEmpty = add_global(rt3, m3, T_I32, false, [0x41u8, 0x07u8, 0x0bu8], "")   // (export "" (global 0))
    let gHidden = add_unexported_global(rt3, m3, T_I32, false, [0x41u8, 0x08u8, 0x0bu8])
    let gNamed = add_global(rt3, m3, T_I32, false, [0x41u8, 0x09u8, 0x0bu8], "g")
    equal(t, m3_FindGlobal(rt3, m3, ""), gEmpty, "a global exported as \"\" is found by \"\"")
    equal(t, m3_FindGlobal(rt3, m3, "g"), gNamed, "a named export is found")
    rt3.globals[gEmpty].isExported = false
    equal(t, m3_FindGlobal(rt3, m3, ""), -1, "an unexported global is not found by \"\"")
    check(t, gHidden != -1 && !rt3.globals[gHidden].isExported, "the unexported global has no export flag")
    m3_FreeRuntime(rt3)
}


// ============================================================================
// Eden: a panicking host function leaves rt.originStack where it was
// ============================================================================


// a host function that panics (an array bound, as a host reading a bad index)
def private host_panics(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var none : array<int>
    let x = none[sp]
    return "never {x}"
}


def private host_ok(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    return m3Err_none
}


def test_env_host_panic_restores_origin_stack(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = add_module(rt, "host")
    let t0 = add_type(rt, m, no_types(), no_types())
    let t1 = add_type(rt, m, [T_I32], no_types())
    let host = add_import(rt, m, t0, "env", "host")
    let run = add_function(rt, m, t0, [0x00u8, 0x10u8, 0x00u8, 0x0bu8])   // call 0
    let five = add_function(rt, m, t1, [0x00u8, 0x41u8, 0x05u8, 0x0bu8])  // i32.const 5
    export_function(rt, run, "run")
    export_function(rt, five, "five")
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule host")
    push(rt.rawCalls, @@host_panics)
    is_ok(t, CompileRawFunction(rt, m, host, length(rt.rawCalls) - 1, 0), "link the host function")

    var f : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, f, "run"), "m3_FindFunction run")
    let origin = rt.originStack
    var none : array<u64>
    is_err(t, m3_Call(rt, f, none), m3Err_panicRunCode, "a panicking host function")
    equal(t, rt.originStack, origin, "rt.originStack restored after the panic")

    // the next calls work from the right base
    is_ok(t, m3_FindFunction(rt, f, "five"), "m3_FindFunction five")
    is_ok(t, m3_Call(rt, f, none), "a call after the panic")
    var bits : array<u64>
    is_ok(t, m3_GetResults(rt, f, 1u, bits), "results after the panic")
    equal(t, m3_bits_to_i32(bits[0]), 5, "five() == 5")
    rt.rawCalls[length(rt.rawCalls) - 1] = @@host_ok
    is_ok(t, m3_FindFunction(rt, f, "run"), "m3_FindFunction run again")
    is_ok(t, m3_Call(rt, f, none), "the host call succeeds once it does not panic")
    equal(t, rt.originStack, origin, "rt.originStack after a normal host call")
    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: a panicking compilation becomes an M3Result (DESIGN 4.4a)
// ============================================================================


def test_env_invalid_body_panics_to_result(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = add_module(rt, "bad")
    let t0 = add_type(rt, m, [T_I32], [T_I32])
    let t1 = add_type(rt, m, [T_I32], no_types())
    let bad = add_function(rt, m, t0, [0x00u8, 0x21u8, 0x00u8, 0x0bu8])                    // local.set 0 on an empty stack
    let callsBad = add_function(rt, m, t1, [0x00u8, 0x41u8, 0x01u8, 0x10u8, 0x00u8, 0x0bu8])   // i32.const 1; call 0
    export_function(rt, bad, "bad")
    export_function(rt, callsBad, "calls_bad")
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule bad")

    var f : IM3Function = 7
    is_err(t, m3_FindFunction(rt, f, "bad"), m3Err_panicCompileFunction, "m3_FindFunction of a panicking body")
    equal(t, f, -1, "o_function cleared")
    equal(t, rt.numActiveCodePages, 0u, "the interrupted compilation released its page")
    equal(t, rt.functions[bad].compiled, -1, "the body stays uncompiled")

    // the caller compiles (op_Compile for the callee); the lazy compile panics during the call
    is_ok(t, m3_FindFunction(rt, f, "calls_bad"), "m3_FindFunction calls_bad")
    var none : array<u64>
    is_err(t, m3_Call(rt, f, none), m3Err_panicRunCode, "a panic during the call")
    equal(t, rt.lastCalled, -1, "lastCalled cleared")
    equal(t, rt.numActiveCodePages, 0u, "no code page active after the call")

    is_err(t, m3_CompileModule(rt, m), m3Err_panicCompileFunction, "m3_CompileModule")
    equal(t, rt.numActiveCodePages, 0u, "no code page active after m3_CompileModule")

    // an init expression with a function-only opcode fails the load with C's error
    let m2 = add_module(rt, "bad_init")
    add_global(rt, m2, T_I32, false, [0x21u8, 0x00u8, 0x0bu8], "g")   // local.set 0 outside a function
    is_err(t, m3_LoadModule(rt, m2), m3Err_restrictedOpcode, "a bad init expression fails the load")
    equal(t, rt.modules[m2].runtime, -1, "the module stays unlinked")
    equal(t, rt.numActiveCodePages, 0u, "no code page active after the failed load")

    // a load that panics (a hand-built data segment whose bytes lie past the
    // module's binary: the array bound) returns m3Err_panicLoadModule
    let m3 = add_module(rt, "bad_data")
    rt.modules[m3].memoryInfo.initPages = 1u
    let dataExpr = append_bytes(rt, m3, [0x41u8, 0x00u8, 0x0bu8])
    push(rt.modules[m3].dataSegments, M3DataSegment(initExpr = dataExpr, initExprSize = 3u, data = 1000, size = 3u))
    rt.modules[m3].numDataSegments = 1u
    is_err(t, m3_LoadModule(rt, m3), m3Err_panicLoadModule, "a panicking load")
    equal(t, rt.modules[m3].runtime, -1, "the panicking module stays unlinked")
    equal(t, rt.numActiveCodePages, 0u, "no code page active after the panicking load")

    m3_FreeRuntime(rt)
    equal(t, length(rt.modules), 0, "m3_FreeRuntime after the panics")
}


// ============================================================================
// Eden: EvaluateExpression and Environment_AddFuncType
// ============================================================================


def test_env_evaluate_expression_and_interning(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = add_module(rt, "expr")
    let g = add_global(rt, m, T_I64, false, [0x42u8, 0x00u8, 0x0bu8], "g")
    rt.globals[g].valueBits = 77ul
    rt.modules[m].runtime = 0

    rt.compilation.maxStackSlots = 1234
    rt.error.message = "keep"
    let pagesOpen = rt.pagesOpen

    var bits = 0xaaaaaaaa00000000ul
    var at = append_bytes(rt, m, [0x41u8, 0x7bu8, 0x0bu8])   // i32.const -5
    is_ok(t, EvaluateExpression(rt, m, bits, T_I32, at, length(rt.modules[m].wasm)), "i32 expression")
    equal(t, bits, 0xaaaaaaaafffffffbul, "a 32-bit result replaces the low four bytes")
    equal(t, at, length(rt.modules[m].wasm), "io_bytes after the expression")

    at = append_bytes(rt, m, [0x42u8, 0x7fu8, 0x0bu8])       // i64.const -1
    is_ok(t, EvaluateExpression(rt, m, bits, T_I64, at, length(rt.modules[m].wasm)), "i64 expression")
    equal(t, bits, 0xfffffffffffffffful, "i64 result")

    bits = 0ul
    at = append_bytes(rt, m, [0x43u8, 0x00u8, 0x00u8, 0xc0u8, 0x3fu8, 0x0bu8])   // f32.const 1.5
    is_ok(t, EvaluateExpression(rt, m, bits, T_F32, at, length(rt.modules[m].wasm)), "f32 expression")
    equal(t, bits, 0x3fc00000ul, "f32 result bits")

    at = append_bytes(rt, m, [0x44u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x02u8, 0x40u8, 0x0bu8])   // f64.const 2.25
    is_ok(t, EvaluateExpression(rt, m, bits, T_F64, at, length(rt.modules[m].wasm)), "f64 expression")
    equal(t, bits, 0x4002000000000000ul, "f64 result bits")

    at = append_bytes(rt, m, [0x23u8, 0x00u8, 0x0bu8])       // global.get 0
    is_ok(t, EvaluateExpression(rt, m, bits, T_I64, at, length(rt.modules[m].wasm)), "global.get expression")
    equal(t, bits, 77ul, "global.get result")

    at = append_bytes(rt, m, [0x1au8, 0x0bu8])               // drop on an empty stack
    bits = 5ul
    let r = EvaluateExpression(rt, m, bits, T_I32, at, length(rt.modules[m].wasm))
    check(t, r != m3Err_none, "an invalid expression fails (\"{r}\")")
    equal(t, bits, 5ul, "o_expressed untouched on failure")

    // the temporary runtime's state did not leak into rt
    equal(t, rt.compilation.maxStackSlots, 1234, "rt.compilation restored")
    equal_str(t, rt.error.message, "keep", "rt.error restored")
    equal(t, rt.pagesOpen, pagesOpen, "rt.pagesOpen restored")
    equal(t, rt.numActiveCodePages, 0u, "no code page active")
    check(t, rt.pagesReleased != -1, "the expression's page went back to the pool")

    // Environment_AddFuncType: an equal type is the existing handle, the new slot popped
    let numTypes = length(rt.funcTypes)
    var ft : IM3FuncType = -1
    AllocFuncType(rt, ft, 1u)
    rt.funcTypes[ft].numRets = u16(1)
    rt.funcTypes[ft].types[0] = T_I32
    Environment_AddFuncType(rt, ft)
    equal(t, ft, rt.environment.retFuncTypes[1], "() -> i32 is interned")
    equal(t, length(rt.funcTypes), numTypes, "the duplicate slot is popped")
    AllocFuncType(rt, ft, 1u)
    rt.funcTypes[ft].numArgs = u16(1)
    rt.funcTypes[ft].types[0] = T_I64
    Environment_AddFuncType(rt, ft)
    equal(t, ft, numTypes, "a new type keeps its slot")
    equal(t, length(rt.funcTypes), numTypes + 1, "one more interned type")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_env(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_env_new_environment_wires_hooks")
    test_env_new_environment_wires_hooks(t, fx)
    begin_test(t, "test_env_hook_wiring_is_idempotent")
    test_env_hook_wiring_is_idempotent(t, fx)
    begin_test(t, "test_env_new_runtime_environment_survives_wiring")
    test_env_new_runtime_environment_survives_wiring(t, fx)
    begin_test(t, "test_env_runtime_releases_linked_module_without_owning_environment")
    test_env_runtime_releases_linked_module_without_owning_environment(t, fx)
    begin_test(t, "test_env_load_module_links_and_rejects_relinking")
    test_env_load_module_links_and_rejects_relinking(t, fx)
    begin_test(t, "test_env_memory_of_module_without_memory_section")
    test_env_memory_of_module_without_memory_section(t, fx)
    begin_test(t, "test_env_function_signature_queries")
    test_env_function_signature_queries(t, fx)
    begin_test(t, "test_env_find_function_and_error_info")
    test_env_find_function_and_error_info(t, fx)
    begin_test(t, "test_env_globals_and_table_of_fib32")
    test_env_globals_and_table_of_fib32(t, fx)
    begin_test(t, "test_env_call_argument_and_result_protocol")
    test_env_call_argument_and_result_protocol(t, fx)
    begin_test(t, "test_env_load_full_module")
    test_env_load_full_module(t, fx)
    begin_test(t, "test_env_call_typed_values")
    test_env_call_typed_values(t, fx)
    begin_test(t, "test_env_trap_and_stack_overflow")
    test_env_trap_and_stack_overflow(t, fx)
    begin_test(t, "test_env_memory_grow")
    test_env_memory_grow(t, fx)
    begin_test(t, "test_env_find_function_names")
    test_env_find_function_names(t, fx)
    begin_test(t, "test_env_host_panic_restores_origin_stack")
    test_env_host_panic_restores_origin_stack(t, fx)
    begin_test(t, "test_env_invalid_body_panics_to_result")
    test_env_invalid_body_panics_to_result(t, fx)
    begin_test(t, "test_env_evaluate_expression_and_interning")
    test_env_evaluate_expression_and_interning(t, fx)
}
