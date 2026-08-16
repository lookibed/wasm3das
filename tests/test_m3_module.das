options gen2
options indenting = 4

module test_m3_module

require dastest/testing_boost
require ../source/m3_module.das


def private check(condition : bool; message : string) {
    if (!condition) {
        panic("test_m3_module: {message}")
    }
}


def private check_default_module_head() {
    var moduleValue : M3Module
    var modulePtr : IM3Module = unsafe(addr(moduleValue))

    check(moduleValue.runtime == null, "default runtime")
    check(moduleValue.environment == null, "default environment")
    check(moduleValue.wasmStart == null, "default wasmStart")
    check(moduleValue.wasmEnd == null, "default wasmEnd")
    check(empty(moduleValue.name), "default name")
    check(moduleValue.numFuncTypes == 0u, "default numFuncTypes")
    check(moduleValue.funcTypes == null, "default funcTypes")
    check(moduleValue.numFuncImports == 0u, "default numFuncImports")
    check(moduleValue.numFunctions == 0u, "default numFunctions")
    check(moduleValue.allFunctions == 0u, "default allFunctions")
    check(moduleValue.functions == null, "default functions")
    check(moduleValue.startFunction == 0, "default startFunction")
    check(moduleValue.numDataSegments == 0u, "default numDataSegments")
    check(moduleValue.dataSegments == null, "default dataSegments")
    check(moduleValue.numGlobals == 0u, "default numGlobals")
    check(moduleValue.globals == null, "default globals")
    check(m3_GetModuleName(modulePtr) == ".unnamed", "unnamed default module")
}


def private check_default_module_tail() {
    var moduleValue : M3Module

    check(moduleValue.numElementSegments == 0u, "default numElementSegments")
    check(moduleValue.elementSection == null, "default elementSection")
    check(moduleValue.elementSectionEnd == null, "default elementSectionEnd")
    check(moduleValue.table0 == null, "default table0")
    check(moduleValue.table0Size == 0u, "default table0Size")
    check(empty(moduleValue.table0ExportName), "default table0ExportName")
    check(moduleValue.memoryInfo.initPages == 0u, "default memoryInfo.initPages")
    check(moduleValue.memoryInfo.maxPages == 0u, "default memoryInfo.maxPages")
    check(moduleValue.memoryInfo.pageSize == 0u, "default memoryInfo.pageSize")
    check(empty(moduleValue.memoryImport.moduleUtf8), "default memoryImport.moduleUtf8")
    check(empty(moduleValue.memoryImport.fieldUtf8), "default memoryImport.fieldUtf8")
    check(!moduleValue.memoryImported, "default memoryImported")
    check(empty(moduleValue.memoryExportName), "default memoryExportName")
    check(moduleValue.next == null, "default next")
}



def private check_module_functions() {
    var functions : M3Function[5]
    var moduleValue = M3Module(
        numFunctions = 3u,
        allFunctions = 5u,
        functions = unsafe(addr(functions[0]))
    )
    var modulePtr : IM3Module = unsafe(addr(moduleValue))

    check(Module_GetFunction(modulePtr, 0u) == unsafe(addr(functions[0])), "first function")
    check(Module_GetFunction(modulePtr, 1u) == unsafe(addr(functions[1])), "middle function")
    check(Module_GetFunction(modulePtr, 2u) == unsafe(addr(functions[2])), "last function")
    check(Module_GetFunction(modulePtr, 3u) == null, "index numFunctions")
    check(Module_GetFunction(modulePtr, 4u) == null, "capacity is not logical bound")
    check(Module_GetFunction(modulePtr, 1000u) == null, "large function index")
}


def private check_module_names() {
    var moduleValue : M3Module
    var modulePtr : IM3Module = unsafe(addr(moduleValue))

    check(m3_GetModuleName(null) == ".unnamed", "null module name")
    check(m3_GetModuleName(modulePtr) == ".unnamed", "missing module name")

    m3_SetModuleName(modulePtr, "alpha")
    check(m3_GetModuleName(modulePtr) == "alpha", "set module name")

    m3_SetModuleName(modulePtr, "beta")
    check(m3_GetModuleName(modulePtr) == "beta", "replace module name")

    m3_SetModuleName(null, "ignored")
    check(m3_GetModuleName(null) == ".unnamed", "set name on null module is ignored")
}


def private check_module_runtime() {
    var runtimeValue : M3Runtime
    var moduleValue : M3Module
    var modulePtr : IM3Module = unsafe(addr(moduleValue))
    var runtimePtr : IM3Runtime = unsafe(addr(runtimeValue))

    check(m3_GetModuleRuntime(null) == null, "null module runtime")
    check(m3_GetModuleRuntime(modulePtr) == null, "default module runtime")

    moduleValue.runtime = runtimePtr
    check(m3_GetModuleRuntime(modulePtr) == runtimePtr, "stored module runtime")
}


def private check_global_union_and_defaults() {
    var globalValue : M3Global

    check(empty(globalValue.import.moduleUtf8), "default global import module")
    check(empty(globalValue.import.fieldUtf8), "default global import field")
    check(typeinfo sizeof(globalValue.import) == 2 * typeinfo sizeof(type<cstr_t>), "global import storage size")
    check(globalValue.valueBits == 0ul, "default global union storage")
    check(typeinfo sizeof(globalValue.valueBits) == 8, "global union storage size")

    let unionAddress = intptr(unsafe(addr(globalValue.valueBits)))
    let nameAddress = intptr(unsafe(addr(globalValue.name)))
    check(nameAddress - unionAddress == 8, "anonymous union occupies exactly 8 bytes")

    M3Global_SetF64Value(globalValue, 3.5lf)
    check(M3Global_GetF64Value(globalValue) == 3.5lf, "f64 overlays union storage")
    check(
        unsafe(reinterpret<u64>(M3Global_GetI64Value(globalValue))) == globalValue.valueBits,
        "i64 reads the same f64 storage"
    )

    M3Global_SetF32Value(globalValue, 1.25)
    check(M3Global_GetF32Value(globalValue) == 1.25, "f32 uses the same union storage")
    check(
        unsafe(reinterpret<u32>(M3Global_GetI32Value(globalValue))) == unsafe(reinterpret<u32>(1.25)),
        "i32 reads the same f32 storage"
    )

    check(empty(globalValue.name), "default global name")
    check(globalValue.initExpr == null, "default global initExpr")
    check(globalValue.initExprSize == 0u, "default global initExprSize")
    check(globalValue._type == 0u, "default global type")
    check(!globalValue.imported, "default global imported")
    check(!globalValue.isMutable, "default global isMutable")
}


def private check_config_and_absent_fields() {
    check(d_m3HasFloat, "accepted config requires float union views")
    check(!d_m3RecordBacktraces, "accepted config keeps backtraces disabled")
    check(d_m3EnableStrace == 0u, "accepted config keeps strace disabled")
    check(!d_m3EnableCodePageRefCounting, "accepted config keeps code page refcount disabled")

    check(!typeinfo safe_has_field<importedGlobals>(default<M3Module>), "importedGlobals must stay absent")
    check(!typeinfo safe_has_field<hasWasmCodeCopy>(default<M3Module>), "hasWasmCodeCopy must stay absent")
    check(!typeinfo safe_has_field<value>(default<M3Global>), "widened nested union struct must stay absent")
}


[test]
def test_m3_module() {
    check_default_module_head()
    check_default_module_tail()
    check_module_functions()
    check_module_names()
    check_module_runtime()
    check_global_union_and_defaults()
    check_config_and_absent_fields()
}


[export]
def main() {
    test_m3_module()
    print("test_m3_module: all tests passed\n")
}
