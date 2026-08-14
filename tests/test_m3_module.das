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


def private check_default_module() {
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
    check(moduleValue.numElementSegments == 0u, "default numElementSegments")
    check(moduleValue.elementSection == null, "default elementSection")
    check(moduleValue.elementSectionEnd == null, "default elementSectionEnd")
    check(moduleValue.table0 == null, "default table0")
    check(moduleValue.table0Size == 0u, "default table0Size")
    check(empty(moduleValue.table0ExportName), "default table0ExportName")
    check(moduleValue.memoryInfo.initPages == 0u, "default memoryInfo.initPages")
    check(moduleValue.memoryInfo.maxPages == 0u, "default memoryInfo.maxPages")
    check(moduleValue.memoryInfo.pageSize == 0u, "default memoryInfo.pageSize")
    check(empty(moduleValue.memoryImport[0]), "default memoryImport.moduleUtf8 storage")
    check(empty(moduleValue.memoryImport[1]), "default memoryImport.fieldUtf8 storage")
    check(!moduleValue.memoryImported, "default memoryImported")
    check(empty(moduleValue.memoryExportName), "default memoryExportName")
    check(moduleValue.next == null, "default next")
    check(m3_GetModuleName(modulePtr) == ".unnamed", "unnamed default module")
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
    var runtimeMarker : u8 = 1u
    var moduleValue : M3Module
    var modulePtr : IM3Module = unsafe(addr(moduleValue))
    let runtimePtr : IM3Runtime = unsafe(addr(runtimeMarker))

    check(m3_GetModuleRuntime(null) == null, "null module runtime")
    check(m3_GetModuleRuntime(modulePtr) == null, "default module runtime")

    moduleValue.runtime = runtimePtr
    check(m3_GetModuleRuntime(modulePtr) == runtimePtr, "stored module runtime")
}


def private check_global_union_and_defaults() {
    var globalValue : M3Global

    check(empty(globalValue.import[0]), "default global import module storage")
    check(empty(globalValue.import[1]), "default global import field storage")
    check(typeinfo sizeof(globalValue.import) == 2 * typeinfo sizeof(type<cstr_t>), "global import storage size")
    check(globalValue.i64Value == 0l, "default global union storage")
    check(typeinfo sizeof(globalValue.i64Value) == 8, "global union storage size")

    let unionAddress = intptr(unsafe(addr(globalValue.i64Value)))
    let nameAddress = intptr(unsafe(addr(globalValue.name)))
    check(nameAddress - unionAddress == 8, "anonymous union occupies exactly 8 bytes")

    globalValue.i64Value = unsafe(reinterpret<i64>(3.5lf))
    check(unsafe(reinterpret<f64>(globalValue.i64Value)) == 3.5lf, "f64 overlays union storage")

    let f32Bits = unsafe(reinterpret<u32>(1.25))
    let storedF32Bits = M3_LITTLE_ENDIAN ? u64(f32Bits) : (u64(f32Bits) << 32u)
    globalValue.i64Value = i64(storedF32Bits)
    let selectedF32Bits = (
        M3_LITTLE_ENDIAN
            ? u32(globalValue.i64Value)
            : u32(u64(globalValue.i64Value) >> 32u)
    )
    check(unsafe(reinterpret<f32>(selectedF32Bits)) == 1.25, "f32 uses the same union storage")

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
    check_default_module()
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
