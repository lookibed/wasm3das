options gen2
options indenting = 4

module test_m3_types shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core     // the arena allocator helpers
require modules/wasm3das/source/m3_config   // the fixed-array dimensions of M3Compilation
require daslib/math_bits

/*
    test_m3_types.das: Eden counterpart of
    .upstream/tests/integration/test_m3_types_integration.das.

    The one upstream [test], test_m3_types_integration, runs five check
    groups; each group is kept as a helper below with the same checks in the
    same order. The fail-fast check helper of the upstream file becomes the
    recording checks of eden_test (check / equal / equal_str), so one failing
    value never hides the others.

    Eden: the upstream groups compare pointers built with addr(); here a
    pointer is a handle into a runtime arena (source/m3_types.das, DESIGN.md
    section 4.1), so
      - "canonical pointer" checks compare handles and follow them into the
        arena (rt.functions[handle], rt.funcTypes[handle]);
      - the sizeof stride of the function array becomes the handle stride of
        consecutive arena slots (1);
      - Module_GetFunction and m3_GetFunctionModule (m3_module, m3_env) are
        not ported yet, so the C bound check of Module_GetFunction is a
        private stand-in here (module_get_function) and the function-module
        link is the moduleIdx handle itself;
      - the bit views of the union accessors come from daslib/math_bits
        (float_bits_to_uint / double_bits_to_uint64) instead of a reinterpret.
    Four tests are added for the Eden shape of the type hub and have no
    upstream counterpart: test_handle_defaults (every handle field of every
    struct starts at -1, arena elements included), test_struct_construction
    (S() of every struct and the arena helpers over the structs that hold
    arrays), test_function_typedefs (an op table, a raw call, a section
    handler and a compiler built from the function typedefs and invoked) and
    test_error_info (m3Error records into rt.error).
*/


// ============================================================================
// Upstream check groups
// ============================================================================


def private check_function_module_identity(var t : TestRun) {
    var rt = M3Runtime()
    m3_Malloc_Impl(rt.modules, 2)
    m3_Malloc_Impl(rt.functions, 1)
    rt.modules[1].name = "owner"

    // Eden: the upstream `functionValue._module = modulePtr`
    rt.functions[0].moduleIdx = 1
    equal(t, rt.functions[0].moduleIdx, 1, "canonical function module handle")
    equal_str(t, rt.modules[rt.functions[0].moduleIdx].name, "owner", "the module handle reaches the owning module")
}


// Eden: stand-in for C's Module_GetFunction (m3_module is not ported yet):
// `if (i_functionIndex < i_module->numFunctions) return & i_module->functions [i_functionIndex]`
def private module_get_function(i_module : M3Module; i_functionIndex : u32) : IM3Function {
    var function_ : IM3Function = -1
    if (i_functionIndex < i_module.numFunctions) {
        function_ = i_module.functions[int(i_functionIndex)]
    }
    return function_
}


def private check_function_array_and_stride(var t : TestRun) {
    var rt = M3Runtime()
    m3_Malloc_Impl(rt.functions, 5)   // Eden: the upstream `M3Function[5]`
    for (i in range(5)) {
        rt.functions[i].export_name = "fn{i}"
    }

    var moduleValue = M3Module(numFunctions = 3u, allFunctions = 5u)
    // Eden: the upstream `functions = addr(functions[0])`; three consecutive handles
    for (i in range(3)) {
        push(moduleValue.functions, i)
    }

    let first = module_get_function(moduleValue, 0u)
    let middle = module_get_function(moduleValue, 1u)
    let last = module_get_function(moduleValue, 2u)

    equal(t, first, 0, "first canonical function")
    equal(t, middle, 1, "middle canonical function")
    equal(t, last, 2, "last canonical function")
    equal_str(t, rt.functions[first].export_name, "fn0", "first handle reaches its arena slot")
    equal_str(t, rt.functions[last].export_name, "fn2", "last handle reaches its arena slot")
    equal(t, module_get_function(moduleValue, 3u), -1, "index numFunctions rejected")
    equal(t, module_get_function(moduleValue, 4u), -1, "capacity does not extend logical bound")

    // Eden: the upstream sizeof stride is the handle stride of the arena
    let stride = middle - first
    equal(t, stride, 1, "function stride equals one arena slot")
    equal(t, last - middle, stride, "function array stride is stable")
}


def private check_func_type_and_table_arrays(var t : TestRun) {
    var rt = M3Runtime()
    m3_Malloc_Impl(rt.funcTypes, 2)   // Eden: the upstream ft0 / ft1
    rt.funcTypes[0].numArgs = u16(1)
    rt.funcTypes[1].numArgs = u16(2)

    m3_Malloc_Impl(rt.functions, 2)   // Eden: the upstream fn0 / fn1
    rt.functions[0].export_name = "fn0"
    rt.functions[1].export_name = "fn1"

    var moduleValue = M3Module(numFuncTypes = 2u, table0Size = 2u)
    push(moduleValue.funcTypes, 0)
    push(moduleValue.funcTypes, 1)
    push(moduleValue.table0, 0)
    push(moduleValue.table0, 1)

    equal(t, moduleValue.funcTypes[0], 0, "funcTypes[0] canonical handle")
    equal(t, moduleValue.funcTypes[1], 1, "funcTypes[1] canonical handle")
    equal(t, u32(rt.funcTypes[moduleValue.funcTypes[0]].numArgs), 1u, "funcTypes[0] reaches ft0")
    equal(t, u32(rt.funcTypes[moduleValue.funcTypes[1]].numArgs), 2u, "funcTypes[1] reaches ft1")
    equal(t, moduleValue.table0[0], 0, "table0[0] canonical function handle")
    equal(t, moduleValue.table0[1], 1, "table0[1] canonical function handle")
    equal_str(t, rt.functions[moduleValue.table0[0]].export_name, "fn0", "table0[0] reaches fn0")
    equal_str(t, rt.functions[moduleValue.table0[1]].export_name, "fn1", "table0[1] reaches fn1")
}


def private check_named_import_info(var t : TestRun) {
    var functionValue = M3Function()
    var globalValue = M3Global()
    var moduleValue = M3Module()

    functionValue.import.moduleUtf8 = "func-module"
    functionValue.import.fieldUtf8 = "func-field"
    globalValue.import.moduleUtf8 = "global-module"
    globalValue.import.fieldUtf8 = "global-field"
    moduleValue.memoryImport.moduleUtf8 = "memory-module"
    moduleValue.memoryImport.fieldUtf8 = "memory-field"

    equal_str(t, functionValue.import.moduleUtf8, "func-module", "function import module name")
    equal_str(t, functionValue.import.fieldUtf8, "func-field", "function import field name")
    equal_str(t, globalValue.import.moduleUtf8, "global-module", "global import module name")
    equal_str(t, globalValue.import.fieldUtf8, "global-field", "global import field name")
    equal_str(t, moduleValue.memoryImport.moduleUtf8, "memory-module", "memory import module name")
    equal_str(t, moduleValue.memoryImport.fieldUtf8, "memory-field", "memory import field name")
}


def private check_union_accessors(var t : TestRun) {
    var globalValue = M3Global()
    equal(t, typeinfo sizeof(globalValue.valueBits), 8, "one eight-byte union storage")

    let i64Bits = 0x0123456789abcdeful
    M3Global_SetI64Value(globalValue, i64(i64Bits))
    equal(t, globalValue.valueBits, i64Bits, "i64 setter writes shared bits")
    equal(t, double_bits_to_uint64(M3Global_GetF64Value(globalValue)), i64Bits, "f64 getter sees i64 bits")

    let f64Value = -13.25lf
    let f64Bits = double_bits_to_uint64(f64Value)
    M3Global_SetF64Value(globalValue, f64Value)
    equal(t, globalValue.valueBits, f64Bits, "f64 setter writes shared bits")
    equal(t, u64(M3Global_GetI64Value(globalValue)), f64Bits, "i64 getter sees f64 bits")

    let i32Bits = 0x12345678u
    M3Global_SetI32Value(globalValue, i32(i32Bits))
    equal(t, float_bits_to_uint(M3Global_GetF32Value(globalValue)), i32Bits, "f32 getter sees i32 bits")

    let f32Value = -7.5
    let f32Bits = float_bits_to_uint(f32Value)
    M3Global_SetF32Value(globalValue, f32Value)
    equal(t, u32(M3Global_GetI32Value(globalValue)), f32Bits, "i32 getter sees f32 bits")

    // Eden: a 32-bit store touches only the low four bytes (the C union
    // member on a little-endian host); the high bytes of the previous
    // 64-bit value stay
    M3Global_SetI64Value(globalValue, i64(0x1122334455667788ul))
    M3Global_SetI32Value(globalValue, i32(0x0badf00du))
    equal(t, globalValue.valueBits, 0x112233440badf00dul, "i32 setter keeps the high bytes")
    equal(t, u32(M3Global_GetI32Value(globalValue)), 0x0badf00du, "i32 getter reads the low bytes")
}


def test_m3_types_integration(var t : TestRun; fx : FixtureSource) {
    check_function_module_identity(t)
    check_function_array_and_stride(t)
    check_func_type_and_table_arrays(t)
    check_named_import_info(t)
    check_union_accessors(t)
}


// ============================================================================
// Eden: handle defaults
// ============================================================================


def test_handle_defaults(var t : TestRun; fx : FixtureSource) {
    let ft = M3FuncType()
    equal(t, ft.next, -1, "M3FuncType.next")

    let seg = M3DataSegment()
    equal(t, seg.initExpr, -1, "M3DataSegment.initExpr")
    equal(t, seg.data, -1, "M3DataSegment.data")

    let g = M3Global()
    equal(t, g.initExpr, -1, "M3Global.initExpr")

    let f = M3Function()
    equal(t, f.moduleIdx, -1, "M3Function.moduleIdx")
    equal(t, f.wasm, -1, "M3Function.wasm")
    equal(t, f.wasmEnd, -1, "M3Function.wasmEnd")
    equal(t, f.funcTypeIdx, -1, "M3Function.funcTypeIdx")
    equal(t, f.compiled, -1, "M3Function.compiled")

    let m = M3Module()
    equal(t, m.runtime, -1, "M3Module.runtime")
    equal(t, m.wasmStart, -1, "M3Module.wasmStart")
    equal(t, m.wasmEnd, -1, "M3Module.wasmEnd")
    equal(t, m.elementSection, -1, "M3Module.elementSection")
    equal(t, m.elementSectionEnd, -1, "M3Module.elementSectionEnd")

    let e = M3ErrorInfo()
    equal(t, e.runtime, -1, "M3ErrorInfo.runtime")
    equal(t, e.moduleIdx, -1, "M3ErrorInfo.moduleIdx")
    equal(t, e.functionIdx, -1, "M3ErrorInfo.functionIdx")

    let ctx = M3ImportContext()
    equal(t, ctx.userdata, -1, "M3ImportContext.userdata")
    equal(t, ctx.functionIdx, -1, "M3ImportContext.functionIdx")

    let env = M3Environment()
    equal(t, length(env.retFuncTypes), 6, "M3Environment.retFuncTypes has c_m3Type_unknown slots")
    for (i in range(6)) {
        equal(t, env.retFuncTypes[i], -1, "M3Environment.retFuncTypes[{i}]")
    }
    check(t, env.customSectionHandler == null, "M3Environment.customSectionHandler")

    let scope = M3CompilationScope()
    equal(t, scope.outer, -1, "M3CompilationScope.outer")
    equal(t, scope.pc, -1, "M3CompilationScope.pc")
    equal(t, scope.patches, -1, "M3CompilationScope.patches")
    equal(t, scope.typeIdx, -1, "M3CompilationScope.typeIdx")

    let c = M3Compilation()
    equal(t, c.runtime, -1, "M3Compilation.runtime")
    equal(t, c.moduleIdx, -1, "M3Compilation.moduleIdx")
    equal(t, c.wasm, -1, "M3Compilation.wasm")
    equal(t, c.wasmEnd, -1, "M3Compilation.wasmEnd")
    equal(t, c.lastOpcodeStart, -1, "M3Compilation.lastOpcodeStart")
    equal(t, c._block.outer, -1, "M3Compilation._block.outer")
    equal(t, c.functionIdx, -1, "M3Compilation.functionIdx")
    equal(t, c.page, -1, "M3Compilation.page")

    var rt = M3Runtime()
    equal(t, rt.compilation.runtime, -1, "M3Runtime.compilation.runtime")
    equal(t, rt.environment.retFuncTypes[0], -1, "M3Runtime.environment.retFuncTypes[0]")
    equal(t, rt.pagesOpen, -1, "M3Runtime.pagesOpen")
    equal(t, rt.pagesFull, -1, "M3Runtime.pagesFull")
    equal(t, rt.originStack, -1, "M3Runtime.originStack")
    equal(t, rt.lastCalled, -1, "M3Runtime.lastCalled")
    equal(t, rt.userdata, -1, "M3Runtime.userdata")
    equal(t, rt.error.runtime, -1, "M3Runtime.error.runtime")
    equal(t, rt.pc, -1, "M3Runtime.pc")
    equal(t, rt.sp, -1, "M3Runtime.sp")

    // an arena element is the struct default: its handles start null too
    m3_Malloc_Impl(rt.functions, 2)
    m3_Malloc_Impl(rt.modules, 1)
    m3_Malloc_Impl(rt.funcTypes, 1)
    m3_Malloc_Impl(rt.globals, 1)
    equal(t, rt.functions[1].moduleIdx, -1, "arena M3Function.moduleIdx")
    equal(t, rt.functions[1].funcTypeIdx, -1, "arena M3Function.funcTypeIdx")
    equal(t, rt.functions[1].compiled, -1, "arena M3Function.compiled")
    equal(t, rt.modules[0].runtime, -1, "arena M3Module.runtime")
    equal(t, rt.funcTypes[0].next, -1, "arena M3FuncType.next")
    equal(t, rt.globals[0].initExpr, -1, "arena M3Global.initExpr")
}


// ============================================================================
// Eden: S() construction of every struct
// ============================================================================


def test_struct_construction(var t : TestRun; fx : FixtureSource) {
    let info = M3ImportInfo()
    equal_str(t, info.moduleUtf8, "", "M3ImportInfo.moduleUtf8")
    equal_str(t, info.fieldUtf8, "", "M3ImportInfo.fieldUtf8")

    let ft = M3FuncType()
    equal(t, u32(ft.numRets), 0u, "M3FuncType.numRets")
    equal(t, u32(ft.numArgs), 0u, "M3FuncType.numArgs")
    equal(t, length(ft.types), 0, "M3FuncType.types is empty")

    let mi = M3MemoryInfo()
    equal(t, mi.initPages, 0u, "M3MemoryInfo.initPages")
    equal(t, mi.maxPages, 0u, "M3MemoryInfo.maxPages")
    equal(t, mi.pageSize, 0u, "M3MemoryInfo.pageSize")

    let seg = M3DataSegment()
    equal(t, seg.initExprSize, 0u, "M3DataSegment.initExprSize")
    equal(t, seg.memoryRegion, 0u, "M3DataSegment.memoryRegion")
    equal(t, seg.size, 0u, "M3DataSegment.size")

    let g = M3Global()
    equal(t, g.valueBits, 0ul, "M3Global.valueBits")
    equal_str(t, g.name, "", "M3Global.name")
    equal(t, g.initExprSize, 0u, "M3Global.initExprSize")
    equal(t, u32(g._type), 0u, "M3Global._type")
    check(t, !g.imported, "M3Global.imported")
    check(t, !g.isMutable, "M3Global.isMutable")

    let f = M3Function()
    equal(t, length(f.names), int(d_m3MaxDuplicateFunctionImpl), "M3Function.names dimension")
    equal_str(t, f.names[0], "", "M3Function.names[0]")
    equal_str(t, f.export_name, "", "M3Function.export_name")
    equal(t, u32(f.numNames), 0u, "M3Function.numNames")
    equal(t, u32(f.maxStackSlots), 0u, "M3Function.maxStackSlots")
    equal(t, u32(f.numRetSlots), 0u, "M3Function.numRetSlots")
    equal(t, u32(f.numRetAndArgSlots), 0u, "M3Function.numRetAndArgSlots")
    equal(t, u32(f.numLocals), 0u, "M3Function.numLocals")
    equal(t, u32(f.numLocalBytes), 0u, "M3Function.numLocalBytes")
    check(t, !f.ownsWasmCode, "M3Function.ownsWasmCode")
    equal(t, u32(f.numConstantBytes), 0u, "M3Function.numConstantBytes")
    equal(t, length(f.constants), 0, "M3Function.constants is empty")

    let m = M3Module()
    equal(t, length(m.wasm), 0, "M3Module.wasm is empty")
    equal_str(t, m.name, "", "M3Module.name")
    equal(t, m.numFuncTypes, 0u, "M3Module.numFuncTypes")
    equal(t, length(m.funcTypes), 0, "M3Module.funcTypes is empty")
    equal(t, m.numFuncImports, 0u, "M3Module.numFuncImports")
    equal(t, m.numFunctions, 0u, "M3Module.numFunctions")
    equal(t, m.allFunctions, 0u, "M3Module.allFunctions")
    equal(t, length(m.functions), 0, "M3Module.functions is empty")
    equal(t, m.startFunction, -1, "M3Module.startFunction is -1 (no start function) from construction")   // Eden: C sets -1 in m3_parse.c right after calloc
    equal(t, m.numDataSegments, 0u, "M3Module.numDataSegments")
    equal(t, length(m.dataSegments), 0, "M3Module.dataSegments is empty")
    equal(t, m.numGlobals, 0u, "M3Module.numGlobals")
    equal(t, length(m.globals), 0, "M3Module.globals is empty")
    equal(t, m.numElementSegments, 0u, "M3Module.numElementSegments")
    equal(t, length(m.table0), 0, "M3Module.table0 is empty")
    equal(t, m.table0Size, 0u, "M3Module.table0Size")
    equal_str(t, m.table0ExportName, "", "M3Module.table0ExportName")
    equal(t, m.memoryInfo.initPages, 0u, "M3Module.memoryInfo")
    equal_str(t, m.memoryImport.moduleUtf8, "", "M3Module.memoryImport")
    check(t, !m.memoryImported, "M3Module.memoryImported")
    equal_str(t, m.memoryExportName, "", "M3Module.memoryExportName")

    let e = M3ErrorInfo()
    equal_str(t, e.result, "", "M3ErrorInfo.result")
    equal_str(t, e.file, "", "M3ErrorInfo.file")
    equal(t, e.line, 0u, "M3ErrorInfo.line")
    equal_str(t, e.message, "", "M3ErrorInfo.message")

    let tv = M3TaggedValue()
    check(t, tv._type == M3ValueType.c_m3Type_none, "M3TaggedValue._type")
    equal(t, tv.valueBits, 0ul, "M3TaggedValue.valueBits")
    let none = m3_TaggedValueNone()
    check(t, none._type == M3ValueType.c_m3Type_none, "m3_TaggedValueNone type")
    equal(t, none.valueBits, 0ul, "m3_TaggedValueNone bits")

    let ctx = M3ImportContext()
    equal(t, ctx.userdata, -1, "M3ImportContext constructible")

    let mem = M3Memory()
    equal(t, mem.numPages, 0u, "M3Memory.numPages")
    equal(t, mem.maxPages, 0u, "M3Memory.maxPages")
    equal(t, mem.pageSize, 0u, "M3Memory.pageSize")

    let env = M3Environment()
    equal(t, env.retFuncTypes[5], -1, "M3Environment constructible")

    let scope = M3CompilationScope()
    equal(t, scope.depth, 0, "M3CompilationScope.depth")
    equal(t, scope.exitStackIndex, 0, "M3CompilationScope.exitStackIndex")
    equal(t, scope.blockStackIndex, 0, "M3CompilationScope.blockStackIndex")
    equal(t, u32(scope.opcode), 0u, "M3CompilationScope.opcode")
    check(t, !scope.isPolymorphic, "M3CompilationScope.isPolymorphic")

    let c = M3Compilation()
    equal(t, c.stackFirstDynamicIndex, 0, "M3Compilation.stackFirstDynamicIndex")
    equal(t, c.stackIndex, 0, "M3Compilation.stackIndex")
    equal(t, c.slotFirstConstIndex, 0, "M3Compilation.slotFirstConstIndex")
    equal(t, c.slotMaxConstIndex, 0, "M3Compilation.slotMaxConstIndex")
    equal(t, c.slotFirstLocalIndex, 0, "M3Compilation.slotFirstLocalIndex")
    equal(t, c.slotFirstDynamicIndex, 0, "M3Compilation.slotFirstDynamicIndex")
    equal(t, c.maxStackSlots, 0, "M3Compilation.maxStackSlots")
    equal(t, length(c.constants), int(d_m3MaxConstantTableSize), "M3Compilation.constants dimension")
    equal(t, c.constants[0], 0ul, "M3Compilation.constants zero fill")
    equal(t, length(c.wasmStack), int(d_m3MaxFunctionStackHeight), "M3Compilation.wasmStack dimension")
    equal(t, length(c.typeStack), int(d_m3MaxFunctionStackHeight), "M3Compilation.typeStack dimension")
    equal(t, length(c.m3Slots), int(d_m3MaxFunctionSlots), "M3Compilation.m3Slots dimension")
    equal(t, c.slotMaxAllocatedIndexPlusOne, 0, "M3Compilation.slotMaxAllocatedIndexPlusOne")
    equal(t, length(c.regStackIndexPlusOne), 2, "M3Compilation.regStackIndexPlusOne dimension")
    equal(t, c.regStackIndexPlusOne[1], 0, "M3Compilation.regStackIndexPlusOne zero fill")
    equal(t, u32(c.previousOpcode), 0u, "M3Compilation.previousOpcode")

    var rt = M3Runtime()
    equal(t, length(rt.codePages), 0, "M3Runtime.codePages is empty")
    equal(t, rt.numCodePages, 0u, "M3Runtime.numCodePages")
    equal(t, rt.numActiveCodePages, 0u, "M3Runtime.numActiveCodePages")
    equal(t, length(rt.modules), 0, "M3Runtime.modules is empty")
    equal(t, length(rt.stack), 0, "M3Runtime.stack is empty")
    equal(t, rt.stackSize, 0u, "M3Runtime.stackSize")
    equal(t, rt.numStackSlots, 0u, "M3Runtime.numStackSlots")
    equal(t, rt.memory.numPages, 0u, "M3Runtime.memory")
    equal(t, rt.memoryLimit, 0u, "M3Runtime.memoryLimit")
    equal_str(t, rt.error.result, "", "M3Runtime.error")
    equal(t, rt.newCodePageSequence, 0u, "M3Runtime.newCodePageSequence")
    equal(t, length(rt.funcTypes), 0, "M3Runtime.funcTypes is empty")
    equal(t, length(rt.functions), 0, "M3Runtime.functions is empty")
    equal(t, length(rt.globals), 0, "M3Runtime.globals is empty")
    equal(t, length(rt.rawCalls), 0, "M3Runtime.rawCalls is empty")
    equal(t, length(rt.code), 0, "M3Runtime.code is empty")
    equal(t, length(rt.mem), 0, "M3Runtime.mem is empty")
    equal(t, rt.r0, 0ul, "M3Runtime.r0")
    equal(t, rt.fp0, 0.0lf, "M3Runtime.fp0")
    equal_str(t, rt.trap, "", "M3Runtime.trap")
    equal(t, length(rt.stdinBuffer), 0, "M3Runtime.stdinBuffer is empty")
    equal(t, length(rt.stdoutBuffer), 0, "M3Runtime.stdoutBuffer is empty")
    equal(t, length(rt.stderrBuffer), 0, "M3Runtime.stderrBuffer is empty")

    // the arena helpers of m3_core over the structs that hold arrays
    m3_Malloc_Impl(rt.modules, 2)
    equal(t, length(rt.modules), 2, "m3_Malloc_Impl grows the module arena")
    push(rt.modules[1].functions, 4)
    m3_Realloc_Impl(rt.modules, 3, 2)
    equal(t, length(rt.modules), 3, "m3_Realloc_Impl grows the module arena")
    equal(t, length(rt.modules[1].functions), 1, "m3_Realloc_Impl keeps the head")
    equal(t, rt.modules[1].functions[0], 4, "m3_Realloc_Impl keeps the head's contents")
    equal(t, length(rt.modules[2].functions), 0, "m3_Realloc_Impl zero-fills the tail")
    m3_Realloc_Impl(rt.modules, 1, 3)
    equal(t, length(rt.modules), 1, "m3_Realloc_Impl shrinks the module arena")
    m3_Free_Impl(rt.modules)
    equal(t, length(rt.modules), 0, "m3_Free_Impl empties the module arena")

    m3_Malloc_Impl(rt.funcTypes, 1)
    push(rt.funcTypes[0].types, u8(M3ValueType.c_m3Type_i32))
    equal(t, length(rt.funcTypes[0].types), 1, "M3FuncType.types grows in the arena")
    m3_Malloc_Impl(rt.functions, 1)
    push(rt.functions[0].constants, 0x0123456789abcdeful)
    equal(t, rt.functions[0].constants[0], 0x0123456789abcdeful, "M3Function.constants grows in the arena")
    var segments : array<M3DataSegment>
    m3_Malloc_Impl(segments, 2)
    equal(t, length(segments), 2, "m3_Malloc_Impl over M3DataSegment")
    var codePages : array<M3CodePage>
    m3_Malloc_Impl(codePages, 1)
    equal(t, codePages[0].info.next, -1, "m3_Malloc_Impl over M3CodePage")
}


// ============================================================================
// Eden: the function typedefs
// ============================================================================


def private op_set_r0(var rt : M3Runtime) : int {
    rt.r0 = 0x2aul
    return -1
}


def private op_loop_pc(var rt : M3Runtime) : int {
    rt.pc = 5
    return 5
}


def private raw_return_slot(var rt : M3Runtime; sp : int) : M3Result {
    // the raw-call shape of DESIGN.md 4.5: read rt.stack[sp + i], write the
    // return slot
    rt.stack[sp] = rt.stack[sp + 1] + rt.stack[sp + 2]
    return m3Err_none
}


def private raw_trap(var rt : M3Runtime; sp : int) : M3Result {
    return m3Err_trapAbort
}


def private compile_record_opcode(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    rt.compilation.previousOpcode = i_opcode
    return m3Err_none
}


def test_function_typedefs(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()

    // an op table of two trivial ops (DESIGN.md 4.4)
    var ops : array<M3Op>
    push(ops, @@op_set_r0)
    push(ops, @@op_loop_pc)
    equal(t, length(ops), 2, "op table holds two ops")
    let r0 = invoke(ops[0], rt)
    equal(t, r0, -1, "op 0 returns the next protocol value")
    equal(t, rt.r0, 0x2aul, "op 0 wrote rt.r0")
    let r1 = invoke(ops[1], rt)
    equal(t, r1, 5, "op 1 returns a loop pc")
    equal(t, rt.pc, 5, "op 1 wrote rt.pc")

    // a raw call linked into rt.rawCalls (DESIGN.md 4.5)
    resize(rt.stack, 4)
    rt.stack[1] = 40ul
    rt.stack[2] = 2ul
    push(rt.rawCalls, @@raw_return_slot)
    push(rt.rawCalls, @@raw_trap)
    equal(t, length(rt.rawCalls), 2, "raw-call arena holds two functions")
    let call0 = rt.rawCalls[0]
    let result0 = invoke(call0, rt, 0)
    is_ok(t, result0, "raw call 0 succeeds")
    equal(t, rt.stack[0], 42ul, "raw call 0 wrote the return slot")
    let call1 = rt.rawCalls[1]
    let result1 = invoke(call1, rt, 0)
    is_err(t, result1, m3Err_trapAbort, "raw call 1 traps")

    // a custom section handler stored in the environment
    rt.environment.customSectionHandler = @@(var rt : M3Runtime; i_module : IM3Module; i_name : cstr_t; i_start : cbytes_t; i_end : cbytes_t) : M3Result {
        rt.modules[i_module].name = "{i_name}:{i_start}..{i_end}"
        return m3Err_none
    }
    check(t, rt.environment.customSectionHandler != null, "section handler stored")
    m3_Malloc_Impl(rt.modules, 1)
    let handler = rt.environment.customSectionHandler
    let sectionResult = invoke(handler, rt, 0, "name", 8, 24)
    is_ok(t, sectionResult, "section handler succeeds")
    equal_str(t, rt.modules[0].name, "name:8..24", "section handler saw the module and the range")

    // a compiler (DESIGN: the IM3Compilation argument is the runtime)
    let compiler : M3Compiler = @@compile_record_opcode
    let compileResult = invoke(compiler, rt, m3opcode_t(0x41))
    is_ok(t, compileResult, "compiler succeeds")
    equal(t, u32(rt.compilation.previousOpcode), 0x41u, "compiler wrote rt.compilation")
}


// ============================================================================
// Eden: m3Error
// ============================================================================


def test_error_info(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    let returned = m3Error(m3Err_wasmMalformed, rt, 2, 5, "m3_parse.das", 17u, "bad section")
    is_err(t, returned, m3Err_wasmMalformed, "m3Error returns its result")
    equal_str(t, rt.error.result, m3Err_wasmMalformed, "error.result")
    equal(t, rt.error.runtime, 0, "error.runtime is this runtime")
    equal(t, rt.error.moduleIdx, 2, "error.moduleIdx")
    equal(t, rt.error.functionIdx, 5, "error.functionIdx")
    equal_str(t, rt.error.file, "m3_parse.das", "error.file")
    equal(t, rt.error.line, 17u, "error.line")
    equal_str(t, rt.error.message, "bad section", "error.message")

    // a null module / function handle is recorded as such
    let again = m3Error(m3Err_functionLookupFailed, rt, -1, -1, "", 0u, "'main'")
    is_err(t, again, m3Err_functionLookupFailed, "m3Error returns its second result")
    equal(t, rt.error.moduleIdx, -1, "error.moduleIdx null")
    equal(t, rt.error.functionIdx, -1, "error.functionIdx null")
    equal_str(t, rt.error.message, "'main'", "error.message replaced")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_types(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_m3_types_integration")
    test_m3_types_integration(t, fx)
    begin_test(t, "test_handle_defaults")
    test_handle_defaults(t, fx)
    begin_test(t, "test_struct_construction")
    test_struct_construction(t, fx)
    begin_test(t, "test_function_typedefs")
    test_function_typedefs(t, fx)
    begin_test(t, "test_error_info")
    test_error_info(t, fx)
}
