options gen2
options indenting = 4

module test_m3_bind

require dastest/testing_boost
require ../source/m3_bind.das


def private check(condition : bool; message : string) {
    if (!condition) {
        panic("test_m3_bind: {message}")
    }
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


def private type_unknown() : u8 {
    return u8(M3ValueType.c_m3Type_unknown)
}


// m3_function owns the raw M3FuncType allocation but exposes no release helper
// at this stage. Tests name this ownership operation FreeFuncType as required by
// the acceptance contract; production SignatureToFuncType performs the same
// m3_Free_Impl + null cleanup on its error path.
def private FreeFuncType(var funcType : IM3FuncType&) {
    if (funcType != null) {
        m3_Free_Impl(unsafe(reinterpret<void?>(funcType)))
        funcType = null
    }
}


def private raw_type(var funcType : IM3FuncType; index : u32) : u8 {
    let types = unsafe(addr(funcType.types[0]))
    return unsafe(types[index])
}


def private expect_error(signature : string; expected : M3Result; testLabel : string) {
    var funcType : IM3FuncType = null
    let result = SignatureToFuncType(funcType, signature)
    check(result == expected, "{testLabel}: wrong error '{result}'")
    check(funcType == null, "{testLabel}: output must be null after error")
}


[test]
def test_convert_type_char_to_type_id() {
    check(ConvertTypeCharToTypeId('v') == type_none(), "v mapping")
    check(ConvertTypeCharToTypeId('i') == type_i32(), "i mapping")
    check(ConvertTypeCharToTypeId('I') == type_i64(), "I mapping")
    check(ConvertTypeCharToTypeId('f') == type_f32(), "f mapping")
    check(ConvertTypeCharToTypeId('F') == type_f64(), "F mapping")
    check(ConvertTypeCharToTypeId('*') == type_i32(), "pointer mapping")
    check(ConvertTypeCharToTypeId('?') == type_unknown(), "unknown mapping")
}


[test]
def test_empty_signatures() {
    expect_error("", m3Err_malformedFunctionSignature, "empty")

    var funcType : IM3FuncType = null
    check(SignatureToFuncType(funcType, "()") == m3Err_none, "() result")
    check(funcType != null, "() allocation")
    check(GetFuncTypeNumResults(funcType) == u16(0), "() results")
    check(GetFuncTypeNumParams(funcType) == u16(0), "() args")
    FreeFuncType(funcType)

    check(SignatureToFuncType(funcType, " v () ") == m3Err_none, "spaced void result")
    check(GetFuncTypeNumResults(funcType) == u16(0), "spaced void results")
    check(GetFuncTypeNumParams(funcType) == u16(0), "spaced void args")
    FreeFuncType(funcType)
}


[test]
def test_signature_basic_and_spaces() {
    var funcType : IM3FuncType = null
    check(SignatureToFuncType(funcType, "f(IiF)") == m3Err_none, "basic parse")
    check(GetFuncTypeNumResults(funcType) == u16(1), "basic result count")
    check(GetFuncTypeNumParams(funcType) == u16(3), "basic arg count")
    check(GetFuncTypeResultType(funcType, u16(0)) == type_f32(), "basic result type")
    check(GetFuncTypeParamType(funcType, u16(0)) == type_i64(), "basic arg 0")
    check(GetFuncTypeParamType(funcType, u16(1)) == type_i32(), "basic arg 1")
    check(GetFuncTypeParamType(funcType, u16(2)) == type_f64(), "basic arg 2")
    FreeFuncType(funcType)

    check(SignatureToFuncType(funcType, "f(I i F)") == m3Err_none, "spaced parse")
    check(GetFuncTypeNumResults(funcType) == u16(1), "spaced result count")
    check(GetFuncTypeNumParams(funcType) == u16(3), "spaced arg count")
    check(GetFuncTypeResultType(funcType, u16(0)) == type_f32(), "spaced result type")
    check(GetFuncTypeParamType(funcType, u16(0)) == type_i64(), "spaced arg 0")
    check(GetFuncTypeParamType(funcType, u16(1)) == type_i32(), "spaced arg 1")
    check(GetFuncTypeParamType(funcType, u16(2)) == type_f64(), "spaced arg 2")
    FreeFuncType(funcType)
}


[test]
def test_multiple_results_and_physical_order() {
    var funcType : IM3FuncType = null
    check(SignatureToFuncType(funcType, "if(I*)") == m3Err_none, "multi-result parse")
    check(GetFuncTypeNumResults(funcType) == u16(2), "multi result count")
    check(GetFuncTypeNumParams(funcType) == u16(2), "multi arg count")
    check(raw_type(funcType, 0u) == type_i32(), "physical result 0")
    check(raw_type(funcType, 1u) == type_f32(), "physical result 1")
    check(raw_type(funcType, 2u) == type_i64(), "physical arg 0")
    check(raw_type(funcType, 3u) == type_i32(), "physical pointer arg")
    FreeFuncType(funcType)
}


[test]
def test_void_is_not_stored() {
    var funcType : IM3FuncType = null
    check(SignatureToFuncType(funcType, "v(ivI)") == m3Err_none, "void positions parse")
    check(GetFuncTypeNumResults(funcType) == u16(0), "void result skipped")
    check(GetFuncTypeNumParams(funcType) == u16(2), "void arg skipped")
    check(raw_type(funcType, 0u) == type_i32(), "void args physical 0")
    check(raw_type(funcType, 1u) == type_i64(), "void args physical 1")
    FreeFuncType(funcType)
}


[test]
def test_unknown_and_count_overflow_errors() {
    expect_error("x()", "unknown argument type char", "unknown result char")
    expect_error("(x)", "unknown argument type char", "unknown arg char")
    expect_error("iii", "malformed signature; return count overflow", "return overflow")
    expect_error("(ii", "malformed signature; arg count overflow", "arg overflow")
}


[test]
def test_sane_count_limit() {
    let signature = "(iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii)"
    expect_error(signature, m3Err_tooManyArgsRets, "sane count limit")
}


[test]
def test_first_close_parenthesis_stops_parsing() {
    var funcType : IM3FuncType = null
    check(SignatureToFuncType(funcType, "i()ignored") == m3Err_none, "ignored tail parse")
    check(GetFuncTypeNumResults(funcType) == u16(1), "ignored tail result count")
    check(GetFuncTypeNumParams(funcType) == u16(0), "ignored tail arg count")
    check(GetFuncTypeResultType(funcType, u16(0)) == type_i32(), "ignored tail result type")
    FreeFuncType(funcType)
}


[export]
def main() {
    test_convert_type_char_to_type_id()
    test_empty_signatures()
    test_signature_basic_and_spaces()
    test_multiple_results_and_physical_order()
    test_void_is_not_stored()
    test_unknown_and_count_overflow_errors()
    test_sane_count_limit()
    test_first_close_parenthesis_stops_parsing()
    print("test_m3_bind: all tests passed\n")
}
