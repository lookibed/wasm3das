options gen2
options indenting = 4

module test_m3_module shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_module
require modules/wasm3das/source/m3_function
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core     // the arena allocator helpers
require modules/wasm3das/source/m3_config   // the configuration flags the upstream test asserts
require daslib/math_bits

/*
    test_m3_module.das: Eden counterpart of
    .upstream/tests/integration/test_m3_module.das.

    The one upstream [test], test_m3_module, runs seven check groups; each
    group is kept as a helper below with the same checks in the same order.
    The fail-fast check helper of the upstream file becomes the recording
    checks of eden_test, so one failing value never hides the others.

    Eden: the upstream groups build M3Module / M3Function values on the
    stack and pass their addresses; here a module, a function or a global is
    a handle into an arena of a runtime (source/m3_module.das, DESIGN.md
    section 4.1), so
      - every group builds a local `M3Runtime()`; a module is a slot of
        rt.modules (new_module, the upstream `var moduleValue : M3Module`), a
        function a slot of rt.functions (new_function), a null pointer is -1
        and a pointer comparison a handle comparison;
      - the default-value checks read `M3Module()`; a NULL pointer field is
        -1 for an index and an empty array for an array, and
        `startFunction` starts at -1 (the decision of m3_types; the upstream
        expected C's calloc 0);
      - the upstream `environment == null` and `next == null` checks become
        absence checks: both fields are absent from the Eden M3Module (the
        runtime embeds its environment, rt.modules is the arena);
      - the module's function array of check_module_functions is five arena
        slots of which the module owns the first three handles, with the
        capacity set through Module_PreallocFunctions;
      - check_module_runtime stores the handle 0 (the owning runtime) instead
        of a heap-allocated M3Runtime; nothing is allocated or freed;
      - the bit views of check_global_union_and_defaults come from
        daslib/math_bits (float_bits_to_uint) instead of a reinterpret; the
        address-difference check that the name follows the eight-byte union
        has no counterpart (there are no addresses; the field order is that
        of m3_types) and is noted at its site.
    Five tests are added for the Eden shape and have no upstream counterpart:
    test_module_add_global_arena (Module_AddGlobal appends to rt.globals and
    records the handle in the module, across two modules), test_module_add_
    function_arena (Module_PreallocFunctions and Module_AddFunction: the
    handle lands in rt.functions with its owner, its func type is the
    module's handle at the type index, an import aliases its field name into
    names[0] through the explicit i_isImport signal, and Module_GetFunction
    returns the handle), test_module_add_function_rejects_type_index (an
    index >= numFuncTypes fails with C's "type sig index out of bounds" and
    leaves the counted, typeless slot behind, as C does),
    test_module_generate_names ($func / $global names for the unnamed only)
    and test_free_module (m3_FreeModule releases the module's functions and
    globals, empties the module slot and leaves every arena slot and every
    other module in place).
*/


// ============================================================================
// Helpers
// ============================================================================


def private type_i32() : u8 {
    return u8(M3ValueType.c_m3Type_i32)
}


def private type_i64() : u8 {
    return u8(M3ValueType.c_m3Type_i64)
}


def private type_f64() : u8 {
    return u8(M3ValueType.c_m3Type_f64)
}


// Eden: the upstream `var moduleValue : M3Module` local; a fresh slot of rt.modules
def private new_module(var rt : M3Runtime) : IM3Module {
    let numModules = length(rt.modules)
    m3_Realloc_Impl(rt.modules, numModules + 1, numModules)
    return numModules
}


// Eden: the upstream `var fn : M3Function` local; a fresh slot of rt.functions
def private new_function(var rt : M3Runtime) : IM3Function {
    let numFunctions = length(rt.functions)
    m3_Realloc_Impl(rt.functions, numFunctions + 1, numFunctions)
    return numFunctions
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


// a module that declares the given func-type handles, in that order
def private declare_func_types(var rt : M3Runtime; m : IM3Module; funcTypes : array<int>) {
    for (ft in funcTypes) {
        push(rt.modules[m].funcTypes, ft)
    }
    rt.modules[m].numFuncTypes = u32(length(funcTypes))
}


// ============================================================================
// Upstream check groups
// ============================================================================


def private check_default_module_head(var t : TestRun) {
    var rt = M3Runtime()
    var moduleValue = M3Module()
    let modulePtr = new_module(rt)   // Eden: the upstream `addr(moduleValue)`

    equal(t, moduleValue.runtime, -1, "default runtime")
    // Eden: `environment` is absent (the runtime embeds its environment)
    check(t, !typeinfo safe_has_field<environment>(default<M3Module>), "default environment: the field is absent")
    equal(t, moduleValue.wasmStart, -1, "default wasmStart")
    equal(t, moduleValue.wasmEnd, -1, "default wasmEnd")
    check(t, empty(moduleValue.name), "default name")
    equal(t, moduleValue.numFuncTypes, 0u, "default numFuncTypes")
    equal(t, length(moduleValue.funcTypes), 0, "default funcTypes")
    equal(t, moduleValue.numFuncImports, 0u, "default numFuncImports")
    equal(t, moduleValue.numFunctions, 0u, "default numFunctions")
    equal(t, moduleValue.allFunctions, 0u, "default allFunctions")
    equal(t, length(moduleValue.functions), 0, "default functions")
    equal(t, moduleValue.startFunction, -1, "default startFunction")   // Eden: -1 from construction (m3_types); upstream: C's calloc 0
    equal(t, moduleValue.numDataSegments, 0u, "default numDataSegments")
    equal(t, length(moduleValue.dataSegments), 0, "default dataSegments")
    equal(t, moduleValue.numGlobals, 0u, "default numGlobals")
    equal(t, length(moduleValue.globals), 0, "default globals")
    equal_str(t, m3_GetModuleName(rt, modulePtr), ".unnamed", "unnamed default module")
}


def private check_default_module_tail(var t : TestRun) {
    var moduleValue = M3Module()

    equal(t, moduleValue.numElementSegments, 0u, "default numElementSegments")
    equal(t, moduleValue.elementSection, -1, "default elementSection")
    equal(t, moduleValue.elementSectionEnd, -1, "default elementSectionEnd")
    equal(t, length(moduleValue.table0), 0, "default table0")
    equal(t, moduleValue.table0Size, 0u, "default table0Size")
    check(t, empty(moduleValue.table0ExportName), "default table0ExportName")
    equal(t, moduleValue.memoryInfo.initPages, 0u, "default memoryInfo.initPages")
    equal(t, moduleValue.memoryInfo.maxPages, 0u, "default memoryInfo.maxPages")
    equal(t, moduleValue.memoryInfo.pageSize, 0u, "default memoryInfo.pageSize")
    check(t, empty(moduleValue.memoryImport.moduleUtf8), "default memoryImport.moduleUtf8")
    check(t, empty(moduleValue.memoryImport.fieldUtf8), "default memoryImport.fieldUtf8")
    check(t, !moduleValue.memoryImported, "default memoryImported")
    check(t, empty(moduleValue.memoryExportName), "default memoryExportName")
    // Eden: `next` is absent (rt.modules is the arena)
    check(t, !typeinfo safe_has_field<next>(default<M3Module>), "default next: the field is absent")
}


def private check_module_functions(var t : TestRun) {
    var rt = M3Runtime()
    m3_Malloc_Impl(rt.functions, 5)   // Eden: the upstream `M3Function[5]`
    let modulePtr = new_module(rt)
    // Eden: the upstream `numFunctions = 3, allFunctions = 5, functions = addr(functions[0])`
    is_ok(t, Module_PreallocFunctions(rt, modulePtr, 5u), "prealloc five")
    for (i in range(3)) {
        push(rt.modules[modulePtr].functions, i)
    }
    rt.modules[modulePtr].numFunctions = 3u
    equal(t, rt.modules[modulePtr].allFunctions, 5u, "capacity five")

    equal(t, Module_GetFunction(rt, modulePtr, 0u), 0, "first function")
    equal(t, Module_GetFunction(rt, modulePtr, 1u), 1, "middle function")
    equal(t, Module_GetFunction(rt, modulePtr, 2u), 2, "last function")
    equal(t, Module_GetFunction(rt, modulePtr, 3u), -1, "index numFunctions")
    equal(t, Module_GetFunction(rt, modulePtr, 4u), -1, "capacity is not logical bound")
    equal(t, Module_GetFunction(rt, modulePtr, 1000u), -1, "large function index")
}


def private check_module_names(var t : TestRun) {
    var rt = M3Runtime()
    let modulePtr = new_module(rt)

    equal_str(t, m3_GetModuleName(rt, -1), ".unnamed", "null module name")
    equal_str(t, m3_GetModuleName(rt, modulePtr), ".unnamed", "missing module name")

    m3_SetModuleName(rt, modulePtr, "alpha")
    equal_str(t, m3_GetModuleName(rt, modulePtr), "alpha", "set module name")

    m3_SetModuleName(rt, modulePtr, "beta")
    equal_str(t, m3_GetModuleName(rt, modulePtr), "beta", "replace module name")

    m3_SetModuleName(rt, -1, "ignored")
    equal_str(t, m3_GetModuleName(rt, -1), ".unnamed", "set name on null module is ignored")
}


def private check_module_runtime(var t : TestRun) {
    // Eden: the upstream heap-allocates an M3Runtime and stores its address;
    // here a module's runtime is the handle 0, the runtime that owns the
    // module's slot, so nothing is allocated or freed
    var rt = M3Runtime()
    let runtimePtr : IM3Runtime = 0
    let modulePtr = new_module(rt)

    equal(t, m3_GetModuleRuntime(rt, -1), -1, "null module runtime")
    equal(t, m3_GetModuleRuntime(rt, modulePtr), -1, "default module runtime")

    rt.modules[modulePtr].runtime = runtimePtr
    equal(t, m3_GetModuleRuntime(rt, modulePtr), runtimePtr, "stored module runtime")
}


def private check_global_union_and_defaults(var t : TestRun) {
    var globalValue = M3Global()

    check(t, empty(globalValue.import.moduleUtf8), "default global import module")
    check(t, empty(globalValue.import.fieldUtf8), "default global import field")
    equal(t, typeinfo sizeof(globalValue.import), 2 * typeinfo sizeof(type<cstr_t>), "global import storage size")
    equal(t, globalValue.valueBits, 0ul, "default global union storage")
    equal(t, typeinfo sizeof(globalValue.valueBits), 8, "global union storage size")

    // Eden: the upstream "anonymous union occupies exactly 8 bytes" check
    // subtracted the address of `name` from the address of `valueBits`;
    // without addresses the same fact is the offset difference
    equal(t, typeinfo offsetof<name>(globalValue) - typeinfo offsetof<valueBits>(globalValue), 8, "anonymous union occupies exactly 8 bytes")

    M3Global_SetF64Value(globalValue, 3.5lf)
    equal(t, M3Global_GetF64Value(globalValue), 3.5lf, "f64 overlays union storage")
    equal(t, u64(M3Global_GetI64Value(globalValue)), globalValue.valueBits, "i64 reads the same f64 storage")

    M3Global_SetF32Value(globalValue, 1.25)
    equal(t, M3Global_GetF32Value(globalValue), 1.25, "f32 uses the same union storage")
    equal(t, u32(M3Global_GetI32Value(globalValue)), float_bits_to_uint(1.25), "i32 reads the same f32 storage")

    check(t, empty(globalValue.name), "default global name")
    equal(t, globalValue.initExpr, -1, "default global initExpr")
    equal(t, globalValue.initExprSize, 0u, "default global initExprSize")
    equal(t, globalValue._type, 0u8, "default global type")
    check(t, !globalValue.imported, "default global imported")
    check(t, !globalValue.isMutable, "default global isMutable")
}


def private check_config_and_absent_fields(var t : TestRun) {
    check(t, d_m3HasFloat, "accepted config requires float union views")
    check(t, !d_m3RecordBacktraces, "accepted config keeps backtraces disabled")
    equal(t, d_m3EnableStrace, 0u, "accepted config keeps strace disabled")
    check(t, !d_m3EnableCodePageRefCounting, "accepted config keeps code page refcount disabled")

    check(t, !typeinfo safe_has_field<importedGlobals>(default<M3Module>), "importedGlobals must stay absent")
    check(t, !typeinfo safe_has_field<hasWasmCodeCopy>(default<M3Module>), "hasWasmCodeCopy must stay absent")
    check(t, !typeinfo safe_has_field<value>(default<M3Global>), "widened nested union struct must stay absent")
}


def test_m3_module(var t : TestRun; fx : FixtureSource) {
    check_default_module_head(t)
    check_default_module_tail(t)
    check_module_functions(t)
    check_module_names(t)
    check_module_runtime(t)
    check_global_union_and_defaults(t)
    check_config_and_absent_fields(t)
}


// ============================================================================
// Eden: the arenas
// ============================================================================


def test_module_add_global_arena(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let a = new_module(rt)
    let b = new_module(rt)
    equal(t, length(rt.globals), 0, "a new runtime has no globals")

    var g0 : IM3Global = -1
    is_ok(t, Module_AddGlobal(rt, a, g0, type_i32(), false, false), "AddGlobal a0")
    equal(t, g0, 0, "the first global is handle 0")
    equal(t, length(rt.globals), 1, "one arena slot")
    equal(t, rt.modules[a].numGlobals, 1u, "module a counts one global")
    equal(t, length(rt.modules[a].globals), 1, "module a records one handle")
    equal(t, rt.modules[a].globals[0], g0, "module a records the handle")
    equal(t, rt.globals[g0]._type, type_i32(), "a0 type")
    check(t, !rt.globals[g0].imported, "a0 not imported")
    check(t, !rt.globals[g0].isMutable, "a0 not mutable")
    check(t, empty(rt.globals[g0].name), "a0 unnamed (calloc)")
    equal(t, rt.globals[g0].initExpr, -1, "a0 has no init expression (calloc)")

    var g1 : IM3Global = -1
    is_ok(t, Module_AddGlobal(rt, b, g1, type_f64(), true, true), "AddGlobal b0")
    equal(t, g1, 1, "the second global is handle 1")
    equal(t, rt.modules[b].numGlobals, 1u, "module b counts one global")
    equal(t, rt.modules[b].globals[0], g1, "module b records the handle")
    equal(t, rt.globals[g1]._type, type_f64(), "b0 type")
    check(t, rt.globals[g1].imported, "b0 imported")
    check(t, rt.globals[g1].isMutable, "b0 mutable")

    var g2 : IM3Global = -1
    is_ok(t, Module_AddGlobal(rt, a, g2, type_i64(), true, false), "AddGlobal a1")
    equal(t, g2, 2, "the third global is handle 2")
    equal(t, length(rt.globals), 3, "three arena slots")
    equal(t, rt.modules[a].numGlobals, 2u, "module a counts two globals")
    equal(t, length(rt.modules[a].globals), 2, "numGlobals == length(globals)")
    equal(t, rt.modules[a].globals[1], g2, "module a records the second handle after the first")
    equal(t, rt.modules[a].globals[0], g0, "module a keeps the first handle")
    equal(t, length(rt.modules[b].globals), 1, "module b is untouched")

    // the earlier slots are stable across the appends
    equal(t, rt.globals[g0]._type, type_i32(), "a0 type is stable")
    equal(t, rt.globals[g1]._type, type_f64(), "b0 type is stable")
    check(t, rt.globals[g2].isMutable && !rt.globals[g2].imported, "a1 flags")
}


def test_module_add_function_arena(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let a = new_module(rt)
    let b = new_module(rt)
    let ft0 = make_func_type(t, rt, u16(0), u16(1))
    let ft1 = make_func_type(t, rt, u16(1), u16(0))
    // module a declares the types in reverse, so a type index is not a handle
    declare_func_types(rt, a, [ft1, ft0])
    declare_func_types(rt, b, [ft0])

    // a slot of another owner shifts the handles away from the module's indices
    let stray = new_function(rt)
    equal(t, stray, 0, "the stray function is handle 0")

    is_ok(t, Module_PreallocFunctions(rt, a, 2u), "prealloc two")
    equal(t, rt.modules[a].allFunctions, 2u, "prealloc sets allFunctions")
    equal(t, rt.modules[a].numFunctions, 0u, "prealloc adds no function")
    equal(t, length(rt.modules[a].functions), 0, "prealloc records no handle")
    equal(t, length(rt.functions), 1, "prealloc appends no arena slot")
    is_ok(t, Module_PreallocFunctions(rt, a, 1u), "prealloc one")
    equal(t, rt.modules[a].allFunctions, 2u, "prealloc only grows")

    let importInfo = M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "imported")
    is_ok(t, Module_AddFunction(rt, a, 0u, importInfo, true), "add the import")
    equal(t, rt.modules[a].numFunctions, 1u, "module a counts one function")
    equal(t, length(rt.modules[a].functions), 1, "numFunctions == length(functions)")
    equal(t, length(rt.functions), 2, "one arena slot appended")
    equal(t, rt.modules[a].functions[0], 1, "the handle is the arena slot, not the module index")
    let f0 = Module_GetFunction(rt, a, 0u)
    equal(t, f0, 1, "Module_GetFunction returns the handle")
    equal(t, rt.functions[f0].moduleIdx, -1, "the slot's owner stays unset, as C leaves func->module NULL until ParseSection_Code / CompileRawFunction")
    equal(t, rt.functions[f0].funcTypeIdx, ft1, "type index 0 is the module's first func type (handle ft1)")
    equal_str(t, rt.functions[f0].import.moduleUtf8, "env", "import module copied")
    equal_str(t, rt.functions[f0].import.fieldUtf8, "imported", "import field copied")
    equal_str(t, rt.functions[f0].names[0], "imported", "names[0] aliases the import field")
    equal(t, rt.functions[f0].numNames, u16(1), "an import has one name")
    equal_str(t, m3_GetFunctionName(rt, f0), "imported", "m3_GetFunctionName sees the import name")

    is_ok(t, Module_AddFunction(rt, a, 1u, M3ImportInfo(), false), "add a local function")
    let f1 = Module_GetFunction(rt, a, 1u)
    equal(t, f1, 2, "the second function is the next arena slot")
    equal(t, rt.functions[f1].moduleIdx, -1, "a local function's owner is set later by ParseSection_Code, not here (C: func->module NULL)")
    equal(t, rt.functions[f1].funcTypeIdx, ft0, "type index 1 is the module's second func type (handle ft0)")
    equal(t, rt.functions[f1].numNames, u16(0), "a local function has no name yet")
    check(t, empty(rt.functions[f1].names[0]), "a local function has no names[0]")
    check(t, empty(rt.functions[f1].import.fieldUtf8), "a local function has no import")
    equal(t, rt.functions[f1].compiled, -1, "a new function is not compiled (calloc)")

    // the third function exceeds the prealloc: Module_AddFunction grows it
    is_ok(t, Module_AddFunction(rt, a, 1u, M3ImportInfo(), false), "add a third function")
    equal(t, rt.modules[a].numFunctions, 3u, "module a counts three functions")
    equal(t, rt.modules[a].allFunctions, 3u, "allFunctions grew with numFunctions")
    equal(t, Module_GetFunction(rt, a, 2u), 3, "the third function is handle 3")
    equal(t, Module_GetFunction(rt, a, 3u), -1, "index numFunctions is null")

    // module b gets the next slot; its type index 0 is ft0
    is_ok(t, Module_AddFunction(rt, b, 0u, importInfo, true), "add to module b")
    equal(t, rt.modules[b].functions[0], 4, "module b's function is handle 4")
    equal(t, rt.functions[4].moduleIdx, -1, "an import's owner stays unset until it is linked (C: func->module NULL)")
    equal(t, rt.functions[4].funcTypeIdx, ft0, "module b's type index 0 is ft0")
    equal(t, Module_GetFunction(rt, b, 0u), 4, "Module_GetFunction on module b")
    equal(t, Module_GetFunction(rt, b, 1u), -1, "module b has one function")
    equal(t, length(rt.modules[a].functions), 3, "module a is untouched by module b")

    // the explicit import signal: an import whose field name is "" is still
    // an import (C: a non-NULL i_importInfo)
    is_ok(t, Module_AddFunction(rt, b, 0u, M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = ""), true), "add an import with an empty field name")
    let fEmpty = Module_GetFunction(rt, b, 1u)
    equal(t, rt.functions[fEmpty].numNames, u16(1), "an empty-named import still has one name")
    check(t, empty(rt.functions[fEmpty].names[0]), "its names[0] is the empty field name")
    equal_str(t, rt.functions[fEmpty].import.moduleUtf8, "env", "its import module is kept")

    // the earlier slots are stable across the appends
    equal(t, rt.functions[f0].funcTypeIdx, ft1, "f0's type is stable")
    equal_str(t, rt.functions[f0].names[0], "imported", "f0's name is stable")
    equal(t, rt.functions[stray].moduleIdx, -1, "the stray slot has no owner")
}


def test_module_add_function_rejects_type_index(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let m = new_module(rt)
    let ft = make_func_type(t, rt, u16(0), u16(0))
    declare_func_types(rt, m, [ft])

    is_err(t, Module_AddFunction(rt, m, 1u, M3ImportInfo(), false), "type sig index out of bounds", "index numFuncTypes rejected")
    // C leaves the counted, zeroed slot behind (numFunctions++ and the
    // realloc run before the check); Eden: the counted, typeless slot
    equal(t, rt.modules[m].numFunctions, 1u, "the rejected function is counted (C)")
    equal(t, length(rt.modules[m].functions), 1, "numFunctions == length(functions) after the rejection")
    equal(t, length(rt.functions), 1, "the rejected function's slot exists")
    equal(t, rt.functions[rt.modules[m].functions[0]].funcTypeIdx, -1, "the rejected function has no type")
    equal(t, rt.functions[rt.modules[m].functions[0]].moduleIdx, -1, "the rejected function's slot has no owner, like C's zeroed slot")

    is_err(t, Module_AddFunction(rt, m, 1000u, M3ImportInfo(), false), "type sig index out of bounds", "large type index rejected")
    equal(t, rt.modules[m].numFunctions, 2u, "the second rejected function is counted (C)")

    // a module without func types rejects index 0
    let bare = new_module(rt)
    is_err(t, Module_AddFunction(rt, bare, 0u, M3ImportInfo(), false), "type sig index out of bounds", "index 0 of no func types rejected")

    // a valid index still works after the rejections
    is_ok(t, Module_AddFunction(rt, m, 0u, M3ImportInfo(), false), "index 0 accepted")
    equal(t, rt.modules[m].numFunctions, 3u, "three counted functions")
    let f2 = Module_GetFunction(rt, m, 2u)
    equal(t, rt.functions[f2].funcTypeIdx, ft, "the accepted function has the type")

    // the import path checks the type index too
    is_err(t, Module_AddFunction(rt, m, 1u, M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "f"), true), "type sig index out of bounds", "import with an out-of-range type index rejected")
    let f3 = Module_GetFunction(rt, m, 3u)
    equal(t, rt.functions[f3].numNames, u16(0), "the rejected import got no name (the check comes first)")
}


def test_module_generate_names(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let m = new_module(rt)
    let ft = make_func_type(t, rt, u16(0), u16(0))
    declare_func_types(rt, m, [ft])

    is_ok(t, Module_AddFunction(rt, m, 0u, M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "imported"), true), "add the import")
    is_ok(t, Module_AddFunction(rt, m, 0u, M3ImportInfo(), false), "add a local function")
    is_ok(t, Module_AddFunction(rt, m, 0u, M3ImportInfo(), false), "add another local function")
    let f2 = Module_GetFunction(rt, m, 2u)
    rt.functions[f2].names[0] = "exported"
    rt.functions[f2].numNames = u16(1)

    var g0 : IM3Global = -1
    var g1 : IM3Global = -1
    is_ok(t, Module_AddGlobal(rt, m, g0, type_i32(), false, false), "AddGlobal 0")
    is_ok(t, Module_AddGlobal(rt, m, g1, type_i32(), false, false), "AddGlobal 1")
    rt.globals[g0].name = "named"

    Module_GenerateNames(rt, m)

    let f0 = Module_GetFunction(rt, m, 0u)
    let f1 = Module_GetFunction(rt, m, 1u)
    equal_str(t, rt.functions[f0].names[0], "imported", "the import keeps its name")
    equal(t, rt.functions[f0].numNames, u16(1), "the import still has one name")
    equal_str(t, rt.functions[f1].names[0], "$func1", "the unnamed function is $func<index>")
    equal(t, rt.functions[f1].numNames, u16(1), "the generated name counts")
    equal_str(t, m3_GetFunctionName(rt, f1), "$func1", "m3_GetFunctionName sees the generated name")
    equal_str(t, rt.functions[f2].names[0], "exported", "the named function keeps its name")
    equal_str(t, rt.globals[g0].name, "named", "the named global keeps its name")
    equal_str(t, rt.globals[g1].name, "$global1", "the unnamed global is $global<index>")
}


def test_free_module(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let a = new_module(rt)
    let b = new_module(rt)
    let ft = make_func_type(t, rt, u16(0), u16(0))
    declare_func_types(rt, a, [ft])
    declare_func_types(rt, b, [ft])

    // module a: two functions, one global, one data segment, a table, a
    // binary, names and the runtime link
    is_ok(t, Module_AddFunction(rt, a, 0u, M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "imported"), true), "a: add the import")
    is_ok(t, Module_AddFunction(rt, a, 0u, M3ImportInfo(), false), "a: add a local function")
    let fa0 = Module_GetFunction(rt, a, 0u)
    let fa1 = Module_GetFunction(rt, a, 1u)
    rt.functions[fa1].names[0] = "local"
    rt.functions[fa1].numNames = u16(1)
    rt.functions[fa1].moduleIdx = a   // what ParseSection_Code does for a local function with a body
    m3_Malloc_Impl(rt.functions[fa1].constants, 2)
    var ga : IM3Global = -1
    is_ok(t, Module_AddGlobal(rt, a, ga, type_i32(), false, true), "a: add a global")
    rt.globals[ga].name = "g"
    rt.globals[ga].import = M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "g")
    rt.globals[ga].initExpr = 3
    push(rt.modules[a].dataSegments, M3DataSegment(initExpr = 4, data = 8, size = 2u))
    rt.modules[a].numDataSegments = 1u
    push(rt.modules[a].table0, fa1)
    push(rt.modules[a].table0, -1)
    rt.modules[a].table0Size = 2u
    resize(rt.modules[a].wasm, 16)
    rt.modules[a].wasmStart = 0
    rt.modules[a].wasmEnd = 16
    rt.modules[a].elementSection = 12
    rt.modules[a].elementSectionEnd = 14
    rt.modules[a].numElementSegments = 1u
    rt.modules[a].name = "alpha"
    rt.modules[a].memoryExportName = "memory"
    rt.modules[a].table0ExportName = "table"
    rt.modules[a].memoryImport = M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "memory")
    rt.modules[a].memoryImported = true
    rt.modules[a].memoryInfo = M3MemoryInfo(initPages = 1u, maxPages = 2u, pageSize = 65536u)
    rt.modules[a].numFuncImports = 1u
    rt.modules[a].startFunction = 1
    rt.modules[a].runtime = 0

    // module b: one function and one global that must survive
    is_ok(t, Module_AddFunction(rt, b, 0u, M3ImportInfo(), false), "b: add a function")
    let fb0 = Module_GetFunction(rt, b, 0u)
    rt.functions[fb0].names[0] = "keep"
    rt.functions[fb0].numNames = u16(1)
    var gb : IM3Global = -1
    is_ok(t, Module_AddGlobal(rt, b, gb, type_i64(), true, false), "b: add a global")
    rt.globals[gb].name = "keep"
    rt.modules[b].name = "beta"

    let numModulesBefore = length(rt.modules)
    let numFunctionsBefore = length(rt.functions)
    let numGlobalsBefore = length(rt.globals)
    let numFuncTypesBefore = length(rt.funcTypes)

    m3_FreeModule(rt, a)

    // the arenas keep every slot: handles are never reused
    equal(t, length(rt.modules), numModulesBefore, "the module arena keeps its slots")
    equal(t, length(rt.functions), numFunctionsBefore, "the function arena keeps its slots")
    equal(t, length(rt.globals), numGlobalsBefore, "the global arena keeps its slots")
    equal(t, length(rt.funcTypes), numFuncTypesBefore, "the func-type arena is untouched")

    // the module's functions are released (Function_Release)
    check(t, empty(rt.functions[fa0].names[0]), "a's import name released")
    check(t, empty(rt.functions[fa0].import.fieldUtf8), "a's import info released")
    check(t, empty(rt.functions[fa1].names[0]), "a's local name released")
    equal(t, length(rt.functions[fa1].constants), 0, "a's constants released")
    equal(t, rt.functions[fa1].moduleIdx, a, "a released function keeps its owner handle")

    // the module's global is released
    check(t, empty(rt.globals[ga].name), "a's global name released")
    check(t, empty(rt.globals[ga].import.moduleUtf8), "a's global import released")
    equal(t, rt.globals[ga].initExpr, -1, "a's global init expression dropped")

    // the module slot is in the released state
    equal(t, length(rt.modules[a].functions), 0, "functions freed")
    equal(t, rt.modules[a].numFunctions, 0u, "numFunctions zeroed")
    equal(t, rt.modules[a].allFunctions, 0u, "allFunctions zeroed")
    equal(t, rt.modules[a].numFuncImports, 0u, "numFuncImports zeroed")
    equal(t, length(rt.modules[a].funcTypes), 0, "funcTypes freed")
    equal(t, rt.modules[a].numFuncTypes, 0u, "numFuncTypes zeroed")
    equal(t, length(rt.modules[a].dataSegments), 0, "dataSegments freed")
    equal(t, rt.modules[a].numDataSegments, 0u, "numDataSegments zeroed")
    equal(t, length(rt.modules[a].table0), 0, "table0 freed")
    equal(t, rt.modules[a].table0Size, 0u, "table0Size zeroed")
    equal(t, length(rt.modules[a].globals), 0, "globals freed")
    equal(t, rt.modules[a].numGlobals, 0u, "numGlobals zeroed")
    equal(t, length(rt.modules[a].wasm), 0, "the binary freed")
    equal(t, rt.modules[a].wasmStart, -1, "wasmStart dropped")
    equal(t, rt.modules[a].wasmEnd, -1, "wasmEnd dropped")
    equal(t, rt.modules[a].elementSection, -1, "elementSection dropped")
    equal(t, rt.modules[a].elementSectionEnd, -1, "elementSectionEnd dropped")
    equal(t, rt.modules[a].numElementSegments, 0u, "numElementSegments zeroed")
    check(t, empty(rt.modules[a].name), "name freed")
    equal_str(t, m3_GetModuleName(rt, a), ".unnamed", "a released module is unnamed")
    check(t, empty(rt.modules[a].memoryExportName), "memoryExportName freed")
    check(t, empty(rt.modules[a].table0ExportName), "table0ExportName freed")
    check(t, empty(rt.modules[a].memoryImport.moduleUtf8), "memoryImport freed")
    check(t, empty(rt.modules[a].memoryImport.fieldUtf8), "memoryImport field freed")
    check(t, !rt.modules[a].memoryImported, "memoryImported cleared")
    equal(t, rt.modules[a].memoryInfo.initPages, 0u, "memoryInfo cleared")
    equal(t, rt.modules[a].startFunction, -1, "startFunction back to -1")
    equal(t, rt.modules[a].runtime, -1, "runtime link cleared")
    equal(t, m3_GetModuleRuntime(rt, a), -1, "a released module has no runtime")

    // module b is untouched
    equal(t, length(rt.modules[b].functions), 1, "b keeps its function")
    equal_str(t, rt.functions[fb0].names[0], "keep", "b's function keeps its name")
    equal_str(t, rt.globals[gb].name, "keep", "b's global keeps its name")
    equal(t, rt.globals[gb]._type, type_i64(), "b's global keeps its type")
    equal_str(t, m3_GetModuleName(rt, b), "beta", "b keeps its name")
    equal(t, rt.modules[b].funcTypes[0], ft, "b keeps its func type handle")

    // C: if (i_module) - a null module is ignored; freeing twice is harmless
    m3_FreeModule(rt, -1)
    m3_FreeModule(rt, a)
    equal(t, length(rt.modules), numModulesBefore, "null and repeated frees change nothing")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_module(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_m3_module")
    test_m3_module(t, fx)
    begin_test(t, "test_module_add_global_arena")
    test_module_add_global_arena(t, fx)
    begin_test(t, "test_module_add_function_arena")
    test_module_add_function_arena(t, fx)
    begin_test(t, "test_module_add_function_rejects_type_index")
    test_module_add_function_rejects_type_index(t, fx)
    begin_test(t, "test_module_generate_names")
    test_module_generate_names(t, fx)
    begin_test(t, "test_free_module")
    test_free_module(t, fx)
}
