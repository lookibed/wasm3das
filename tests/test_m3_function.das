options gen2
options indenting = 4

module test_m3_function

require dastest/testing_boost
require ../source/m3_function.das


// Fail immediately on the first mismatch, as required by the acceptance spec.
def private check(condition : bool; message : string) {
    if (!condition) {
        panic("test_m3_function: {message}")
    }
}


def private function_ptr(var fn : M3Function&) : IM3Function {
    unsafe {
        return addr(fn)
    }
}


def private module_ptr(var moduleValue : M3Module&) : IM3Module {
    unsafe {
        return addr(moduleValue)
    }
}


def private u16_ptr(var value : u16&) : u16? {
    unsafe {
        return addr(value)
    }
}


def private string_at(values : cstr_t?; index : int) : cstr_t {
    return unsafe(values[index])
}


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


// Raw flexible-tail access used only by tests to initialize the C-layout type.
def private func_types(var ft : IM3FuncType) : u8? {
    unsafe {
        return addr(ft.types[0])
    }
}


def private make_func_type(numRets : u16; numArgs : u16) : IM3FuncType {
    var ft : IM3FuncType = null
    let total = u32(numRets) + u32(numArgs)
    check(AllocFuncType(ft, total) == m3Err_none, "AllocFuncType failed")
    check(ft != null, "AllocFuncType returned null")
    ft.numRets = numRets
    ft.numArgs = numArgs
    return ft
}


def private free_func_type(var ft : IM3FuncType&) {
    if (ft != null) {
        m3_Free_Impl(unsafe(reinterpret<void?>(ft)))
        ft = null
    }
}


def private set_type(var ft : IM3FuncType; index : u32; value : u8) {
    unsafe(func_types(ft)[index]) = value
}


def private get_raw_type(var ft : IM3FuncType; index : u32) : u8 {
    return unsafe(func_types(ft)[index])
}


[test]
def test_func_type_zero_and_null() {
    var zero = make_func_type(u16(0), u16(0))
    check(GetFuncTypeNumResults(zero) == u16(0), "zero results")
    check(GetFuncTypeNumParams(zero) == u16(0), "zero args")
    check(GetFuncTypeResultType(zero, u16(0)) == type_unknown(), "zero result sentinel")
    check(GetFuncTypeParamType(zero, u16(0)) == type_unknown(), "zero arg sentinel")

    check(GetFuncTypeNumResults(null) == u16(0), "null result count")
    check(GetFuncTypeNumParams(null) == u16(0), "null arg count")
    check(GetFuncTypeResultType(null, u16(0)) == type_unknown(), "null result type")
    check(GetFuncTypeParamType(null, u16(0)) == type_unknown(), "null arg type")
    free_func_type(zero)
}


[test]
def test_func_type_order_and_getters() {
    var ft = make_func_type(u16(2), u16(3))
    set_type(ft, 0u, type_i64())
    set_type(ft, 1u, type_f32())
    set_type(ft, 2u, type_i32())
    set_type(ft, 3u, type_f64())
    set_type(ft, 4u, type_i64())

    check(get_raw_type(ft, 0u) == type_i64(), "raw result[0]")
    check(get_raw_type(ft, 1u) == type_f32(), "raw result[1]")
    check(get_raw_type(ft, 2u) == type_i32(), "raw arg[0] follows results")
    check(GetFuncTypeResultType(ft, u16(0)) == type_i64(), "result getter 0")
    check(GetFuncTypeResultType(ft, u16(1)) == type_f32(), "result getter 1")
    check(GetFuncTypeResultType(ft, u16(2)) == type_unknown(), "result upper bound")
    check(GetFuncTypeParamType(ft, u16(0)) == type_i32(), "arg getter 0")
    check(GetFuncTypeParamType(ft, u16(2)) == type_i64(), "arg getter 2")
    check(GetFuncTypeParamType(ft, u16(3)) == type_unknown(), "arg upper bound")
    free_func_type(ft)
}


[test]
def test_func_type_only_results_and_only_args() {
    var onlyResults = make_func_type(u16(2), u16(0))
    set_type(onlyResults, 0u, type_i32())
    set_type(onlyResults, 1u, type_i64())
    check(GetFuncTypeNumResults(onlyResults) == u16(2), "only-results count")
    check(GetFuncTypeNumParams(onlyResults) == u16(0), "only-results args")

    var onlyArgs = make_func_type(u16(0), u16(2))
    set_type(onlyArgs, 0u, type_f32())
    set_type(onlyArgs, 1u, type_f64())
    check(GetFuncTypeNumResults(onlyArgs) == u16(0), "only-args results")
    check(GetFuncTypeNumParams(onlyArgs) == u16(2), "only-args count")
    check(GetFuncTypeParamType(onlyArgs, u16(0)) == type_f32(), "only-args first")

    free_func_type(onlyResults)
    free_func_type(onlyArgs)
}


[test]
def test_func_type_equality() {
    var a = make_func_type(u16(1), u16(2))
    var b = make_func_type(u16(1), u16(2))
    var countDiff = make_func_type(u16(2), u16(1))

    for (i in urange(3u)) {
        let value = i == 0u ? type_i64() : (i == 1u ? type_i32() : type_f64())
        set_type(a, i, value)
        set_type(b, i, value)
        set_type(countDiff, i, value)
    }

    check(AreFuncTypesEqual(a, b), "equal signatures")
    check(!AreFuncTypesEqual(a, countDiff), "different counts")
    set_type(b, 2u, type_f32())
    check(!AreFuncTypesEqual(a, b), "one differing type")

    free_func_type(a)
    free_func_type(b)
    free_func_type(countDiff)
}


def private init_function_type(var fn : M3Function; var ft : IM3FuncType&) {
    ft = make_func_type(u16(2), u16(2))
    set_type(ft, 0u, type_i64())
    set_type(ft, 1u, type_f32())
    set_type(ft, 2u, type_i32())
    set_type(ft, 3u, type_f64())
    fn.funcType = ft
    fn.numLocals = u16(3)
}


[test]
def test_function_null_and_unnamed() {
    check(m3_GetFunctionName(null) == "<unnamed>", "null function name")
    check(m3_GetFunctionModule(null) == null, "null module")
    check(GetFunctionNumArgs(null) == u16(0), "null args")
    check(GetFunctionArgType(null, 0u) == type_none(), "null arg sentinel")
    check(GetFunctionNumReturns(null) == u16(0), "null returns")
    check(GetFunctionReturnType(null, u16(0)) == type_unknown(), "null return sentinel")
    check(GetFunctionNumArgsAndLocals(null) == 0u, "null args+locals")

    var fn : M3Function
    check(m3_GetFunctionName(function_ptr(fn)) == "<unnamed>", "unnamed function")

    var n : u16 = u16(99)
    check(GetFunctionNames(null, u16_ptr(n)) == null, "GetFunctionNames null function")
    check(n == u16(99), "null GetFunctionNames modified count")
    check(GetFunctionNames(function_ptr(fn), null) == null, "GetFunctionNames null count pointer")
}


[test]
def test_function_names_and_import_priority() {
    var fn : M3Function
    fn.names[0] = "local0"
    fn.numNames = u16(1)
    check(m3_GetFunctionName(function_ptr(fn)) == "local0", "one own name")

    fn.names[1] = "local1"
    fn.names[2] = "local2"
    fn.numNames = u16(3)

    var count : u16 = 0
    let names = GetFunctionNames(function_ptr(fn), u16_ptr(count))
    check(names != null, "own names pointer")
    check(count == u16(3), "own names count")
    check(string_at(names, 0) == "local0", "own name 0")
    check(m3_GetFunctionName(function_ptr(fn)) == string_at(names, 0), "first own name parity")
    check(string_at(names, 1) == "local1", "own name 1")
    check(string_at(names, 2) == "local2", "own name 2")

    fn.import.moduleUtf8 = "env"
    fn.import.fieldUtf8 = "imported"
    check(m3_GetFunctionName(function_ptr(fn)) == "imported", "import name priority")
    check(GetFunctionImportModuleName(function_ptr(fn)) == "env", "import module name")

    let importNames = GetFunctionNames(function_ptr(fn), u16_ptr(count))
    check(count == u16(1), "import names count")
    check(string_at(importNames, 0) == "imported", "import names pointer")

    fn.import.moduleUtf8 = ""
    check(GetFunctionImportModuleName(function_ptr(fn)) == "", "missing import module")
}


[test]
def test_function_module_and_signature_metadata() {
    var moduleValue : M3Module
    var fn : M3Function
    var ft : IM3FuncType = null
    init_function_type(fn, ft)

    check(m3_GetFunctionModule(function_ptr(fn)) == null, "module initially absent")
    fn._module = module_ptr(moduleValue)
    check(m3_GetFunctionModule(function_ptr(fn)) == module_ptr(moduleValue), "module present")

    check(GetFunctionNumArgs(function_ptr(fn)) == u16(2), "function args count")
    check(GetFunctionArgType(function_ptr(fn), 0u) == type_i32(), "function arg 0")
    check(GetFunctionArgType(function_ptr(fn), 1u) == type_f64(), "function arg 1")
    check(GetFunctionArgType(function_ptr(fn), 2u) == type_none(), "function arg out of range")
    check(GetFunctionNumReturns(function_ptr(fn)) == u16(2), "function returns count")
    check(GetFunctionReturnType(function_ptr(fn), u16(0)) == type_i64(), "function return 0")
    check(GetFunctionReturnType(function_ptr(fn), u16(1)) == type_f32(), "function return 1")
    check(GetFunctionReturnType(function_ptr(fn), u16(2)) == type_unknown(), "function return out of range")
    check(GetFunctionNumArgsAndLocals(function_ptr(fn)) == 5u, "args plus locals")

    free_func_type(ft)
}


[test]
def test_function_free_compiled_code_noop() {
    var fn : M3Function
    var compiledSlot : void? = null
    fn.compiled = unsafe(addr(compiledSlot))
    let before = intptr(fn.compiled)
    Function_FreeCompiledCode(function_ptr(fn))
    check(intptr(fn.compiled) == before, "compiled pointer changed with refcount disabled")
}


[test]
def test_function_release_raw_ownership_and_alias() {
    var fn = M3Function(
        constants = m3_Malloc_Impl(32ul),
        numConstantBytes = u16(32)
    )
    check(fn.constants != null, "constants allocation")

    unsafe {
        fn.wasm = reinterpret<u8?>(m3_Malloc_Impl(16ul))
        fn.wasmEnd = fn.wasm + 16
    }
    fn.ownsWasmCode = true
    check(fn.wasm != null, "owned wasm allocation")

    var moduleValue : M3Module
    var ft = make_func_type(u16(1), u16(1))
    set_type(ft, 0u, type_i64())
    set_type(ft, 1u, type_i32())
    var compiledSlot : void? = null

    fn._module = module_ptr(moduleValue)
    fn.funcType = ft
    fn.compiled = unsafe(addr(compiledSlot))
    fn.maxStackSlots = u16(9)
    fn.numRetSlots = u16(1)
    fn.numRetAndArgSlots = u16(2)
    fn.numLocals = u16(4)
    fn.numLocalBytes = u16(16)

    fn.import.moduleUtf8 = "env"
    fn.import.fieldUtf8 = "shared-name"
    fn.names[0] = fn.import.fieldUtf8
    fn.names[1] = "owned-name"
    fn.export_name = fn.names[1]
    fn.numNames = u16(2)

    let compiledBefore = intptr(fn.compiled)
    Function_Release(function_ptr(fn))

    check(fn.constants == null, "constants not cleared")
    check(fn.wasm == null, "owned wasm not cleared")
    check(fn.import.moduleUtf8 == "", "import module not released")
    check(fn.import.fieldUtf8 == "", "import field not released")
    check(fn.names[0] == "", "aliased name reference not released")
    check(fn.names[1] == "", "owned name reference not released")
    check(fn.export_name == "", "export-name alias reference not released")
    check(fn.funcType == ft, "Function_Release must not own funcType")
    check(fn._module == module_ptr(moduleValue), "Function_Release changed module")
    check(intptr(fn.compiled) == compiledBefore, "Function_Release changed compiled pointer")

    free_func_type(ft)
}


[test]
def test_function_release_borrowed_wasm() {
    var fn : M3Function
    var borrowed : u8[4]
    unsafe {
        fn.wasm = addr(borrowed[0])
        fn.wasmEnd = fn.wasm + 4
    }
    fn.ownsWasmCode = false

    let before = intptr(fn.wasm)
    Function_Release(function_ptr(fn))
    check(intptr(fn.wasm) == before, "borrowed wasm must not be freed or cleared")
}


[export]
def main() {
    test_func_type_zero_and_null()
    test_func_type_order_and_getters()
    test_func_type_only_results_and_only_args()
    test_func_type_equality()
    test_function_null_and_unnamed()
    test_function_names_and_import_priority()
    test_function_module_and_signature_metadata()
    test_function_free_compiled_code_noop()
    test_function_release_raw_ownership_and_alias()
    test_function_release_borrowed_wasm()
    print("test_m3_function: all tests passed\n")
}
