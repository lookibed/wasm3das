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
    check(empty(moduleValue.memoryImport.moduleUtf8), "default memoryImport.moduleUtf8")
    check(empty(moduleValue.memoryImport.fieldUtf8), "default memoryImport.fieldUtf8")
    check(!moduleValue.memoryImported, "default memoryImported")
    check(empty(moduleValue.memoryExportName), "default memoryExportName")
    check(moduleValue.next == null, "default next")
    check(m3_GetModuleName(modulePtr) == ".unnamed", "unnamed default module")
}


def private check_module_get_function() {
    var functions : M3FunctionForward[5]
    var functionsPtr : M3FunctionForward? = unsafe(addr(functions[0]))
    var moduleValue = M3Module(
        functions = functionsPtr,
        allFunctions = 5u,
        numFunctions = 5u
    )

    var modulePtr : IM3Module = unsafe(addr(moduleValue))
    let first = Module_GetFunction(modulePtr, 0u)
    let middle = Module_GetFunction(modulePtr, 2u)
    let last = Module_GetFunction(modulePtr, 4u)

    var firstExpected : IM3Function = unsafe(addr(functions[0]))
    var middleExpected : IM3Function = unsafe(addr(functions[2]))
    var lastExpected : IM3Function = unsafe(addr(functions[4]))
    check(first == firstExpected, "first function")
    check(middle == middleExpected, "middle function")
    check(last == lastExpected, "last function")

    check(Module_GetFunction(modulePtr, 5u) == null, "index numFunctions")
    check(Module_GetFunction(modulePtr, 100000u) == null, "large out-of-range index")

    // Backing capacity remains five, but logical function count is three.
    moduleValue.numFunctions = 3u
    check(Module_GetFunction(modulePtr, 2u) == middleExpected, "logical last function")
    check(Module_GetFunction(modulePtr, 3u) == null, "bounds use numFunctions not capacity")
    check(Module_GetFunction(modulePtr, 4u) == null, "hidden backing-capacity element")
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
    var runtimeValue : M3RuntimeForward
    var moduleValue : M3Module
    var modulePtr : IM3Module = unsafe(addr(moduleValue))
    var runtimePtr : IM3Runtime = unsafe(addr(runtimeValue))

    check(m3_GetModuleRuntime(null) == null, "null module runtime")
    check(m3_GetModuleRuntime(modulePtr) == null, "default module runtime")

    moduleValue.runtime = runtimePtr
    check(m3_GetModuleRuntime(modulePtr) == runtimePtr, "stored module runtime")
}


def private check_global_defaults_and_config() {
    var globalValue : M3Global

    check(empty(globalValue.import.moduleUtf8), "default global import module")
    check(empty(globalValue.import.fieldUtf8), "default global import field")
    check(globalValue.value.i32Value == 0, "default global i32Value")
    check(globalValue.value.i64Value == 0l, "default global i64Value")
    check(globalValue.value.f64Value == 0.0lf, "default global f64Value")
    check(globalValue.value.f32Value == 0.0, "default global f32Value")
    check(empty(globalValue.name), "default global name")
    check(globalValue.initExpr == null, "default global initExpr")
    check(globalValue.initExprSize == 0u, "default global initExprSize")
    check(globalValue._type == 0u, "default global type")
    check(!globalValue.imported, "default global imported")
    check(!globalValue.isMutable, "default global isMutable")

    check(d_m3HasFloat, "accepted config requires float members")
    check(!d_m3RecordBacktraces, "accepted config keeps backtraces disabled")
    check(d_m3EnableStrace == 0u, "accepted config keeps strace disabled")
    check(!d_m3EnableCodePageRefCounting, "accepted config keeps code page refcount disabled")
}


def private check_intentionally_absent_fields() {
    check(!typeinfo safe_has_field<importedGlobals>(default<M3Module>), "importedGlobals must stay absent")
    check(!typeinfo safe_has_field<hasWasmCodeCopy>(default<M3Module>), "hasWasmCodeCopy must stay absent")
    check(typeinfo safe_has_field<f64Value>(default<M3GlobalValue>), "f64Value active with floats")
    check(typeinfo safe_has_field<f32Value>(default<M3GlobalValue>), "f32Value active with floats")
}


[test]
def test_m3_module() {
    check_default_module()
    check_module_get_function()
    check_module_names()
    check_module_runtime()
    check_global_defaults_and_config()
    check_intentionally_absent_fields()
}


[export]
def main() {
    test_m3_module()
    print("test_m3_module: all tests passed\n")
}
