options gen2
options indenting = 4

module test_m3_function shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_function
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core     // the arena allocator helpers

/*
    test_m3_function.das: Eden counterpart of
    .upstream/tests/integration/test_m3_function.das.

    Every upstream [test] has a counterpart below with the same checks in the
    same order; the fail-fast check helper of the upstream file becomes the
    recording checks of eden_test, so one failing value never hides the
    others.

    Eden: the upstream tests build M3Function / M3FuncType values on the
    stack and pass their addresses; here a function or a function type is a
    handle into an arena of a runtime (source/m3_function.das, DESIGN.md
    section 4.1), so
      - every test builds a local `M3Runtime()`; a function is a slot of
        rt.functions (new_function, the upstream `var fn : M3Function`), a
        function type a handle from AllocFuncType, a module a slot of
        rt.modules; a null pointer is -1 and a pointer comparison a handle
        comparison;
      - the raw flexible-tail accessors of the upstream file (set_type,
        get_raw_type) index the `types` array of the arena slot;
      - free_func_type has no counterpart: a func type is freed with its
        runtime (DESIGN.md section 4.1), so the upstream free calls are gone;
      - GetFunctionNames returns a copy of the used names (an array<cstr_t>)
        and takes the count by reference: "the pointer is null" becomes "the
        array is empty", string_at(names, i) becomes names[i], and the
        upstream check that a null count pointer returns null has no
        counterpart (a reference cannot be null; noted at its site);
      - a function's wasm range is a pair of indices into its module's
        `wasm` array: the owned block of test_function_release_raw_ownership_
        and_alias is a 16-byte module array with wasm = 0, wasmEnd = 16 and
        the borrowed block of test_function_release_borrowed_wasm a 4-byte
        one; "freed" is wasm == -1, the bytes stay in the module;
      - the constant table is an array<u64> of one word per slot: the
        upstream 32-byte block (numConstantBytes = 32) is eight 32-bit slots,
        so eight words; "freed" is an empty array;
      - `compiled` is an index into rt.code (the upstream: the address of a
        local): a nonzero index, checked unchanged.
    One test is added for the Eden shape and has no upstream counterpart:
    test_func_type_arena (AllocFuncType appends consecutive handles with
    zeroed tails of the requested length, earlier handles and their bytes
    stay stable, and the arena is untouched by Function_Release).
*/


// ============================================================================
// Helpers
// ============================================================================


def private type_unknown() : u8 {
    return u8(M3ValueType.c_m3Type_unknown)
}


def private type_none() : u8 {
    return u8(M3ValueType.c_m3Type_none)
}


def private type_i32() : u8 {
    return u8(M3ValueType.c_m3Type_i32)
}


def private type_i64() : u8 {
    return u8(M3ValueType.c_m3Type_i64)
}


def private type_f32() : u8 {
    return u8(M3ValueType.c_m3Type_f32)
}


def private type_f64() : u8 {
    return u8(M3ValueType.c_m3Type_f64)
}


def private make_func_type(var t : TestRun; var rt : M3Runtime; numRets : u16; numArgs : u16) : IM3FuncType {
    var ft : IM3FuncType = -1
    let total = u32(numRets) + u32(numArgs)
    is_ok(t, AllocFuncType(rt, ft, total), "AllocFuncType failed")
    check(t, ft != -1, "AllocFuncType returned null")
    rt.funcTypes[ft].numRets = numRets
    rt.funcTypes[ft].numArgs = numArgs
    return ft
}


// Eden: the upstream raw flexible-tail write, an element of the `types` array
def private set_type(var rt : M3Runtime; ft : IM3FuncType; index : u32; value : u8) {
    rt.funcTypes[ft].types[int(index)] = value
}


def private get_raw_type(rt : M3Runtime; ft : IM3FuncType; index : u32) : u8 {
    return rt.funcTypes[ft].types[int(index)]
}


// Eden: the upstream `var fn : M3Function` local; a fresh slot of rt.functions
def private new_function(var rt : M3Runtime) : IM3Function {
    let numFunctions = length(rt.functions)
    m3_Realloc_Impl(rt.functions, numFunctions + 1, numFunctions)
    return numFunctions
}


// Eden: the upstream `var moduleValue : M3Module` local; a fresh slot of rt.modules
def private new_module(var rt : M3Runtime) : IM3Module {
    let numModules = length(rt.modules)
    m3_Realloc_Impl(rt.modules, numModules + 1, numModules)
    return numModules
}


// ============================================================================
// Upstream tests
// ============================================================================


def test_func_type_zero_and_null(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let zero = make_func_type(t, rt, u16(0), u16(0))
    equal(t, GetFuncTypeNumResults(rt, zero), u16(0), "zero results")
    equal(t, GetFuncTypeNumParams(rt, zero), u16(0), "zero args")
    equal(t, GetFuncTypeResultType(rt, zero, u16(0)), type_unknown(), "zero result sentinel")
    equal(t, GetFuncTypeParamType(rt, zero, u16(0)), type_unknown(), "zero arg sentinel")

    equal(t, GetFuncTypeNumResults(rt, -1), u16(0), "null result count")
    equal(t, GetFuncTypeNumParams(rt, -1), u16(0), "null arg count")
    equal(t, GetFuncTypeResultType(rt, -1, u16(0)), type_unknown(), "null result type")
    equal(t, GetFuncTypeParamType(rt, -1, u16(0)), type_unknown(), "null arg type")
}


def test_func_type_order_and_getters(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let ft = make_func_type(t, rt, u16(2), u16(3))
    set_type(rt, ft, 0u, type_i64())
    set_type(rt, ft, 1u, type_f32())
    set_type(rt, ft, 2u, type_i32())
    set_type(rt, ft, 3u, type_f64())
    set_type(rt, ft, 4u, type_i64())

    equal(t, get_raw_type(rt, ft, 0u), type_i64(), "raw result[0]")
    equal(t, get_raw_type(rt, ft, 1u), type_f32(), "raw result[1]")
    equal(t, get_raw_type(rt, ft, 2u), type_i32(), "raw arg[0] follows results")
    equal(t, GetFuncTypeResultType(rt, ft, u16(0)), type_i64(), "result getter 0")
    equal(t, GetFuncTypeResultType(rt, ft, u16(1)), type_f32(), "result getter 1")
    equal(t, GetFuncTypeResultType(rt, ft, u16(2)), type_unknown(), "result upper bound")
    equal(t, GetFuncTypeParamType(rt, ft, u16(0)), type_i32(), "arg getter 0")
    equal(t, GetFuncTypeParamType(rt, ft, u16(2)), type_i64(), "arg getter 2")
    equal(t, GetFuncTypeParamType(rt, ft, u16(3)), type_unknown(), "arg upper bound")
}


def test_func_type_only_results_and_only_args(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let onlyResults = make_func_type(t, rt, u16(2), u16(0))
    set_type(rt, onlyResults, 0u, type_i32())
    set_type(rt, onlyResults, 1u, type_i64())
    equal(t, GetFuncTypeNumResults(rt, onlyResults), u16(2), "only-results count")
    equal(t, GetFuncTypeNumParams(rt, onlyResults), u16(0), "only-results args")

    let onlyArgs = make_func_type(t, rt, u16(0), u16(2))
    set_type(rt, onlyArgs, 0u, type_f32())
    set_type(rt, onlyArgs, 1u, type_f64())
    equal(t, GetFuncTypeNumResults(rt, onlyArgs), u16(0), "only-args results")
    equal(t, GetFuncTypeNumParams(rt, onlyArgs), u16(2), "only-args count")
    equal(t, GetFuncTypeParamType(rt, onlyArgs, u16(0)), type_f32(), "only-args first")
}


def test_func_type_equality(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let a = make_func_type(t, rt, u16(1), u16(2))
    let b = make_func_type(t, rt, u16(1), u16(2))
    let countDiff = make_func_type(t, rt, u16(2), u16(1))

    for (i in urange(3u)) {
        let value = i == 0u ? type_i64() : (i == 1u ? type_i32() : type_f64())
        set_type(rt, a, i, value)
        set_type(rt, b, i, value)
        set_type(rt, countDiff, i, value)
    }

    check(t, AreFuncTypesEqual(rt, a, b), "equal signatures")
    check(t, !AreFuncTypesEqual(rt, a, countDiff), "different counts")
    set_type(rt, b, 2u, type_f32())
    check(t, !AreFuncTypesEqual(rt, a, b), "one differing type")
}


def private init_function_type(var t : TestRun; var rt : M3Runtime; fn : IM3Function; var ft : IM3FuncType&) {
    ft = make_func_type(t, rt, u16(2), u16(2))
    set_type(rt, ft, 0u, type_i64())
    set_type(rt, ft, 1u, type_f32())
    set_type(rt, ft, 2u, type_i32())
    set_type(rt, ft, 3u, type_f64())
    rt.functions[fn].funcTypeIdx = ft
    rt.functions[fn].numLocals = u16(3)
}


def test_function_null_and_unnamed(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    equal_str(t, m3_GetFunctionName(rt, -1), "<unnamed>", "null function name")
    equal(t, m3_GetFunctionModule(rt, -1), -1, "null module")
    equal(t, GetFunctionNumArgs(rt, -1), u16(0), "null args")
    equal(t, GetFunctionArgType(rt, -1, 0u), type_none(), "null arg sentinel")
    equal(t, GetFunctionNumReturns(rt, -1), u16(0), "null returns")
    equal(t, GetFunctionReturnType(rt, -1, u16(0)), type_unknown(), "null return sentinel")
    equal(t, GetFunctionNumArgsAndLocals(rt, -1), 0u, "null args+locals")

    let fn = new_function(rt)
    equal_str(t, m3_GetFunctionName(rt, fn), "<unnamed>", "unnamed function")

    var n : u16 = u16(99)
    var inscope nullNames <- GetFunctionNames(rt, -1, n)
    equal(t, length(nullNames), 0, "GetFunctionNames null function")   // Eden: the empty array is the null pointer
    equal(t, n, u16(99), "null GetFunctionNames modified count")
    // Eden: the upstream `GetFunctionNames(fn, null) == null` has no
    // counterpart: the count is a reference and cannot be null
}


def test_function_names_and_import_priority(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let fn = new_function(rt)
    rt.functions[fn].names[0] = "local0"
    rt.functions[fn].numNames = u16(1)
    equal_str(t, m3_GetFunctionName(rt, fn), "local0", "one own name")

    rt.functions[fn].names[1] = "local1"
    rt.functions[fn].names[2] = "local2"
    rt.functions[fn].numNames = u16(3)

    var count : u16 = u16(0)
    var inscope names <- GetFunctionNames(rt, fn, count)
    check(t, length(names) != 0, "own names pointer")   // Eden: a non-empty array is the non-null pointer
    equal(t, count, u16(3), "own names count")
    equal(t, length(names), 3, "own names copied")   // Eden: the copy holds the used names
    equal_str(t, names[0], "local0", "own name 0")
    equal_str(t, m3_GetFunctionName(rt, fn), names[0], "first own name parity")
    equal_str(t, names[1], "local1", "own name 1")
    equal_str(t, names[2], "local2", "own name 2")

    rt.functions[fn].import.moduleUtf8 = "env"
    rt.functions[fn].import.fieldUtf8 = "imported"
    equal_str(t, m3_GetFunctionName(rt, fn), "imported", "import name priority")
    equal_str(t, GetFunctionImportModuleName(rt, fn), "env", "import module name")

    var inscope importNames <- GetFunctionNames(rt, fn, count)
    equal(t, count, u16(1), "import names count")
    equal(t, length(importNames), 1, "import names copied")   // Eden: the copy holds the one import name
    equal_str(t, importNames[0], "imported", "import names pointer")

    rt.functions[fn].import.moduleUtf8 = ""
    equal_str(t, GetFunctionImportModuleName(rt, fn), "", "missing import module")
}


def test_function_module_and_signature_metadata(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let moduleValue = new_module(rt)
    let fn = new_function(rt)
    var ft : IM3FuncType = -1
    init_function_type(t, rt, fn, ft)

    equal(t, m3_GetFunctionModule(rt, fn), -1, "module initially absent")
    rt.functions[fn].moduleIdx = moduleValue
    equal(t, m3_GetFunctionModule(rt, fn), moduleValue, "module present")

    equal(t, GetFunctionNumArgs(rt, fn), u16(2), "function args count")
    equal(t, GetFunctionArgType(rt, fn, 0u), type_i32(), "function arg 0")
    equal(t, GetFunctionArgType(rt, fn, 1u), type_f64(), "function arg 1")
    equal(t, GetFunctionArgType(rt, fn, 2u), type_none(), "function arg out of range")
    equal(t, GetFunctionNumReturns(rt, fn), u16(2), "function returns count")
    equal(t, GetFunctionReturnType(rt, fn, u16(0)), type_i64(), "function return 0")
    equal(t, GetFunctionReturnType(rt, fn, u16(1)), type_f32(), "function return 1")
    equal(t, GetFunctionReturnType(rt, fn, u16(2)), type_unknown(), "function return out of range")
    equal(t, GetFunctionNumArgsAndLocals(rt, fn), 5u, "args plus locals")
}


def test_function_free_compiled_code_noop(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let fn = new_function(rt)
    rt.functions[fn].compiled = 7   // Eden: an index into rt.code (upstream: the address of a local)
    let before = rt.functions[fn].compiled
    Function_FreeCompiledCode(rt, fn)
    equal(t, rt.functions[fn].compiled, before, "compiled pointer changed with refcount disabled")
}


def test_function_release_raw_ownership_and_alias(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let fn = new_function(rt)
    // Eden: the upstream 32-byte block is eight 32-bit slots, one word each
    m3_Malloc_Impl(rt.functions[fn].constants, 8)
    rt.functions[fn].numConstantBytes = u16(32)
    equal(t, length(rt.functions[fn].constants), 8, "constants allocation")

    // Eden: the owned block is a range of the module's wasm array
    let moduleValue = new_module(rt)
    resize(rt.modules[moduleValue].wasm, 16)
    rt.functions[fn].wasm = 0
    rt.functions[fn].wasmEnd = 16
    rt.functions[fn].ownsWasmCode = true
    check(t, rt.functions[fn].wasm != -1, "owned wasm allocation")

    let ft = make_func_type(t, rt, u16(1), u16(1))
    set_type(rt, ft, 0u, type_i64())
    set_type(rt, ft, 1u, type_i32())

    rt.functions[fn].moduleIdx = moduleValue
    rt.functions[fn].funcTypeIdx = ft
    rt.functions[fn].compiled = 7   // Eden: an index into rt.code (upstream: the address of a local)
    rt.functions[fn].maxStackSlots = u16(9)
    rt.functions[fn].numRetSlots = u16(1)
    rt.functions[fn].numRetAndArgSlots = u16(2)
    rt.functions[fn].numLocals = u16(4)
    rt.functions[fn].numLocalBytes = u16(16)

    rt.functions[fn].import.moduleUtf8 = "env"
    rt.functions[fn].import.fieldUtf8 = "shared-name"
    rt.functions[fn].names[0] = rt.functions[fn].import.fieldUtf8
    rt.functions[fn].names[1] = "owned-name"
    rt.functions[fn].export_name = rt.functions[fn].names[1]
    rt.functions[fn].numNames = u16(2)

    let compiledBefore = rt.functions[fn].compiled
    let numFuncTypesBefore = length(rt.funcTypes)
    let numFunctionsBefore = length(rt.functions)
    Function_Release(rt, fn)

    equal(t, length(rt.functions[fn].constants), 0, "constants not cleared")
    equal(t, rt.functions[fn].wasm, -1, "owned wasm not cleared")
    equal_str(t, rt.functions[fn].import.moduleUtf8, "", "import module not released")
    equal_str(t, rt.functions[fn].import.fieldUtf8, "", "import field not released")
    equal_str(t, rt.functions[fn].names[0], "", "aliased name reference not released")
    equal_str(t, rt.functions[fn].names[1], "", "owned name reference not released")
    equal_str(t, rt.functions[fn].export_name, "", "export-name alias reference not released")
    equal(t, rt.functions[fn].funcTypeIdx, ft, "Function_Release must not own funcType")
    equal(t, rt.functions[fn].moduleIdx, moduleValue, "Function_Release changed module")
    equal(t, rt.functions[fn].compiled, compiledBefore, "Function_Release changed compiled pointer")

    // Eden: the arenas are untouched; the module keeps the bytes
    equal(t, length(rt.funcTypes), numFuncTypesBefore, "Function_Release leaves the func-type arena")
    equal(t, rt.funcTypes[ft].numRets, u16(1), "the released function's type is intact")
    equal(t, length(rt.functions), numFunctionsBefore, "Function_Release leaves the function arena")
    equal(t, length(rt.modules[moduleValue].wasm), 16, "the module keeps the wasm bytes")
}


def test_function_release_borrowed_wasm(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let fn = new_function(rt)
    // Eden: the borrowed block is a range of the module's wasm array
    let moduleValue = new_module(rt)
    resize(rt.modules[moduleValue].wasm, 4)
    rt.functions[fn].wasm = 0
    rt.functions[fn].wasmEnd = 4
    rt.functions[fn].ownsWasmCode = false

    let before = rt.functions[fn].wasm
    Function_Release(rt, fn)
    equal(t, rt.functions[fn].wasm, before, "borrowed wasm must not be freed or cleared")
    equal(t, rt.functions[fn].wasmEnd, 4, "borrowed wasm end must not be cleared")   // Eden
}


// ============================================================================
// Eden: the func-type arena
// ============================================================================


def test_func_type_arena(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    equal(t, length(rt.funcTypes), 0, "a new runtime has no func types")

    var first : IM3FuncType = -1
    is_ok(t, AllocFuncType(rt, first, 3u), "AllocFuncType(3)")
    equal(t, first, 0, "the first func type is handle 0")
    equal(t, length(rt.funcTypes), 1, "one arena slot")
    equal(t, length(rt.funcTypes[first].types), 3, "the tail has the requested length")
    equal(t, rt.funcTypes[first].next, -1, "a new func type has no next (calloc)")
    equal(t, rt.funcTypes[first].numRets, u16(0), "a new func type has no results (calloc)")
    equal(t, rt.funcTypes[first].numArgs, u16(0), "a new func type has no args (calloc)")
    var tail_zero = true
    for (b in rt.funcTypes[first].types) {
        if (b != 0u8) {
            tail_zero = false
        }
    }
    check(t, tail_zero, "the tail is zero (calloc)")

    rt.funcTypes[first].numRets = u16(1)
    rt.funcTypes[first].numArgs = u16(2)
    set_type(rt, first, 0u, type_f64())
    set_type(rt, first, 1u, type_i32())
    set_type(rt, first, 2u, type_i64())

    var second : IM3FuncType = -1
    is_ok(t, AllocFuncType(rt, second, 0u), "AllocFuncType(0)")
    equal(t, second, 1, "the second func type is handle 1")
    equal(t, length(rt.funcTypes[second].types), 0, "an empty signature has an empty tail")
    equal(t, length(rt.funcTypes), 2, "two arena slots")

    // the earlier handle and its bytes are stable across the append
    equal(t, get_raw_type(rt, first, 0u), type_f64(), "the first type's tail is stable")
    equal(t, get_raw_type(rt, first, 2u), type_i64(), "the first type's tail is stable (2)")
    equal(t, GetFuncTypeResultType(rt, first, u16(0)), type_f64(), "the first type's getters still work")
    equal(t, GetFuncTypeParamType(rt, first, u16(1)), type_i64(), "the first type's getters still work (2)")

    // a third type equal to the first by content is a different handle
    var third : IM3FuncType = -1
    is_ok(t, AllocFuncType(rt, third, 3u), "AllocFuncType(3) again")
    rt.funcTypes[third].numRets = u16(1)
    rt.funcTypes[third].numArgs = u16(2)
    set_type(rt, third, 0u, type_f64())
    set_type(rt, third, 1u, type_i32())
    set_type(rt, third, 2u, type_i64())
    equal(t, third, 2, "the third func type is handle 2")
    check(t, AreFuncTypesEqual(rt, first, third), "equal by content across handles")
    check(t, !AreFuncTypesEqual(rt, first, second), "unequal to the empty signature")
    check(t, AreFuncTypesEqual(rt, first, first), "a type equals itself")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_function(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_func_type_zero_and_null")
    test_func_type_zero_and_null(t, fx)
    begin_test(t, "test_func_type_order_and_getters")
    test_func_type_order_and_getters(t, fx)
    begin_test(t, "test_func_type_only_results_and_only_args")
    test_func_type_only_results_and_only_args(t, fx)
    begin_test(t, "test_func_type_equality")
    test_func_type_equality(t, fx)
    begin_test(t, "test_function_null_and_unnamed")
    test_function_null_and_unnamed(t, fx)
    begin_test(t, "test_function_names_and_import_priority")
    test_function_names_and_import_priority(t, fx)
    begin_test(t, "test_function_module_and_signature_metadata")
    test_function_module_and_signature_metadata(t, fx)
    begin_test(t, "test_function_free_compiled_code_noop")
    test_function_free_compiled_code_noop(t, fx)
    begin_test(t, "test_function_release_raw_ownership_and_alias")
    test_function_release_raw_ownership_and_alias(t, fx)
    begin_test(t, "test_function_release_borrowed_wasm")
    test_function_release_borrowed_wasm(t, fx)
    begin_test(t, "test_func_type_arena")
    test_func_type_arena(t, fx)
}
