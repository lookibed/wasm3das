options gen2
options indenting = 4

module test_m3_types_integration

require dastest/testing_boost
require ../../source/m3_function.das
require ../../source/m3_bind.das
require ../../source/m3_module.das


def private check(condition : bool; message : string) {
    if (!condition) {
        panic("test_m3_types_integration: {message}")
    }
}


def private check_function_module_identity() {
    var moduleValue : M3Module
    var functionValue : M3Function
    var modulePtr : IM3Module = unsafe(addr(moduleValue))
    var functionPtr : IM3Function = unsafe(addr(functionValue))

    functionValue._module = modulePtr
    check(m3_GetFunctionModule(functionPtr) == modulePtr, "canonical function module pointer")
}


def private check_function_array_and_stride() {
    var functions : M3Function[5]
    var moduleValue = M3Module(
        numFunctions = 3u,
        allFunctions = 5u,
        functions = unsafe(addr(functions[0]))
    )
    var modulePtr : IM3Module = unsafe(addr(moduleValue))

    let first = Module_GetFunction(modulePtr, 0u)
    let middle = Module_GetFunction(modulePtr, 1u)
    let last = Module_GetFunction(modulePtr, 2u)

    check(first == unsafe(addr(functions[0])), "first canonical function")
    check(middle == unsafe(addr(functions[1])), "middle canonical function")
    check(last == unsafe(addr(functions[2])), "last canonical function")
    check(Module_GetFunction(modulePtr, 3u) == null, "index numFunctions rejected")
    check(Module_GetFunction(modulePtr, 4u) == null, "capacity does not extend logical bound")

    let stride = int(intptr(middle) - intptr(first))
    check(stride == typeinfo sizeof(type<M3Function>), "function stride equals sizeof M3Function")
    check(int(intptr(last) - intptr(middle)) == stride, "function array stride is stable")
}


def private check_func_type_and_table_arrays() {
    var ft0 : M3FuncType
    var ft1 : M3FuncType
    var funcTypes : IM3FuncType[2]
    funcTypes[0] = unsafe(addr(ft0))
    funcTypes[1] = unsafe(addr(ft1))

    var fn0 : M3Function
    var fn1 : M3Function
    var tableEntries : IM3Function[2]
    tableEntries[0] = unsafe(addr(fn0))
    tableEntries[1] = unsafe(addr(fn1))

    var moduleValue = M3Module(
        numFuncTypes = 2u,
        funcTypes = unsafe(addr(funcTypes[0])),
        table0 = unsafe(addr(tableEntries[0])),
        table0Size = 2u
    )

    check(unsafe(moduleValue.funcTypes[0]) == unsafe(addr(ft0)), "funcTypes[0] canonical pointer")
    check(unsafe(moduleValue.funcTypes[1]) == unsafe(addr(ft1)), "funcTypes[1] canonical pointer")
    check(unsafe(moduleValue.table0[0]) == unsafe(addr(fn0)), "table0[0] canonical function pointer")
    check(unsafe(moduleValue.table0[1]) == unsafe(addr(fn1)), "table0[1] canonical function pointer")
}


def private check_named_import_info() {
    var functionValue : M3Function
    var globalValue : M3Global
    var moduleValue : M3Module

    functionValue.import.moduleUtf8 = "func-module"
    functionValue.import.fieldUtf8 = "func-field"
    globalValue.import.moduleUtf8 = "global-module"
    globalValue.import.fieldUtf8 = "global-field"
    moduleValue.memoryImport.moduleUtf8 = "memory-module"
    moduleValue.memoryImport.fieldUtf8 = "memory-field"

    check(functionValue.import.moduleUtf8 == "func-module", "function import module name")
    check(functionValue.import.fieldUtf8 == "func-field", "function import field name")
    check(globalValue.import.moduleUtf8 == "global-module", "global import module name")
    check(globalValue.import.fieldUtf8 == "global-field", "global import field name")
    check(moduleValue.memoryImport.moduleUtf8 == "memory-module", "memory import module name")
    check(moduleValue.memoryImport.fieldUtf8 == "memory-field", "memory import field name")
}


def private check_union_accessors() {
    var globalValue : M3Global
    check(typeinfo sizeof(globalValue.valueBits) == 8, "one eight-byte union storage")

    let i64Bits = 0x0123456789abcdeful
    M3Global_SetI64Value(globalValue, unsafe(reinterpret<i64>(i64Bits)))
    check(globalValue.valueBits == i64Bits, "i64 setter writes shared bits")
    check(
        unsafe(reinterpret<u64>(M3Global_GetF64Value(globalValue))) == i64Bits,
        "f64 getter sees i64 bits"
    )

    let f64Value = -13.25lf
    let f64Bits = unsafe(reinterpret<u64>(f64Value))
    M3Global_SetF64Value(globalValue, f64Value)
    check(globalValue.valueBits == f64Bits, "f64 setter writes shared bits")
    check(
        unsafe(reinterpret<u64>(M3Global_GetI64Value(globalValue))) == f64Bits,
        "i64 getter sees f64 bits"
    )

    let i32Bits = 0x12345678u
    M3Global_SetI32Value(globalValue, unsafe(reinterpret<i32>(i32Bits)))
    check(
        unsafe(reinterpret<u32>(M3Global_GetF32Value(globalValue))) == i32Bits,
        "f32 getter sees i32 bits"
    )

    let f32Value = -7.5
    let f32Bits = unsafe(reinterpret<u32>(f32Value))
    M3Global_SetF32Value(globalValue, f32Value)
    check(
        unsafe(reinterpret<u32>(M3Global_GetI32Value(globalValue))) == f32Bits,
        "i32 getter sees f32 bits"
    )
}


[test]
def test_m3_types_integration() {
    check_function_module_identity()
    check_function_array_and_stride()
    check_func_type_and_table_arrays()
    check_named_import_info()
    check_union_accessors()
}


[export]
def main() {
    test_m3_types_integration()
    print("test_m3_types_integration: all tests passed\n")
}
