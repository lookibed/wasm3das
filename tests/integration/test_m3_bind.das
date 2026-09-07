options gen2
options indenting = 4
// The linking arms below execute wasm, and the executor nests one Daslang
// frame per executed op (no M3_MUSTTAIL); options stack counts only in the
// program root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/integration/test_m3_env.das: under dastest a test
// file that names its module does not run the [init] functions of required
// shared modules.

require dastest/testing_boost
require ../../source/m3_bind.das
require ../../source/m3_parse.das


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


// ============================================================================
// Linking: ValidateSignature, FindAndLinkFunction, m3_LinkRawFunction[Ex]
// ============================================================================


/*
    A hand-assembled module, so the linking arms need no external fixture:

        (module
          (import "spectest" "print_i32" (func $p (param i32)))
          (func (export "call_it") (param i32) (result i32)
            (call $p (local.get 0))
            (i32.add (local.get 0) (i32.const 1))))

    Sections in the order m3_ParseModule enforces: 1 type, 2 import,
    3 function, 7 export, 10 code.
*/
let IMPORTING_WASM = [
    0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
    // type: (i32)->() and (i32)->(i32)
    0x01u8, 0x0au8, 0x02u8, 0x60u8, 0x01u8, 0x7fu8, 0x00u8, 0x60u8, 0x01u8, 0x7fu8, 0x01u8, 0x7fu8,
    // import: "spectest" "print_i32" func type 0
    0x02u8, 0x16u8, 0x01u8,
    0x08u8, 0x73u8, 0x70u8, 0x65u8, 0x63u8, 0x74u8, 0x65u8, 0x73u8, 0x74u8,
    0x09u8, 0x70u8, 0x72u8, 0x69u8, 0x6eu8, 0x74u8, 0x5fu8, 0x69u8, 0x33u8, 0x32u8,
    0x00u8, 0x00u8,
    // function: one local function of type 1
    0x03u8, 0x02u8, 0x01u8, 0x01u8,
    // export: "call_it" -> func 1
    0x07u8, 0x0bu8, 0x01u8,
    0x07u8, 0x63u8, 0x61u8, 0x6cu8, 0x6cu8, 0x5fu8, 0x69u8, 0x74u8,
    0x00u8, 0x01u8,
    // code: local.get 0; call 0; local.get 0; i32.const 1; i32.add; end
    0x0au8, 0x0du8, 0x01u8, 0x0bu8,
    0x00u8, 0x20u8, 0x00u8, 0x10u8, 0x00u8, 0x20u8, 0x00u8, 0x41u8, 0x01u8, 0x6au8, 0x0bu8
]


struct BindFixture {
    env : IM3Environment
    runtime : IM3Runtime
    _module : IM3Module
}


var private g_calls = 0
var private g_lastArg = 0
var private g_lastUserdata : void? = null


// C: m3ApiRawFunction (recording_print_i32). m3ApiGetArg (int32_t, i_value)
// reads one slot off _sp; _ctx->userdata is the m3_LinkRawFunctionEx payload.
def private recording_print_i32(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    g_calls++
    unsafe {
        g_lastArg = *reinterpret<i32?>(_sp)
    }
    g_lastUserdata = _ctx != null ? _ctx.userdata : null
    return m3Err_none
}


def private trapping_print_i32(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    return m3Err_trapAbort
}


// The module bytes must outlive the module: m3_ParseModule stores wasm
// pointers into the caller's buffer, so the fixture keeps the array alive.
def private new_bind_fixture(var bytes : array<u8>) : BindFixture {
    var env = m3_NewEnvironment()
    var fx = BindFixture(env = env, runtime = m3_NewRuntime(env, 64u * 1024u, null))
    if (m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes))) != m3Err_none) {
        fx._module = null
    }
    return fx
}


def private free_bind_fixture(var fx : BindFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


def private module_bytes() : array<u8> {
    var bytes : array<u8>
    bytes |> push_from(IMPORTING_WASM)
    return <- bytes
}


// C FindAndLinkFunction: _throwif (m3Err_moduleNotLinked, !io_module->runtime).
[test]
def test_link_before_load_is_rejected(t : T?) {
    var bytes <- module_bytes()
    var fx = new_bind_fixture(bytes)
    t |> success(fx._module != null, "hand-built module parses")
    if (fx._module != null) {
        t |> equal(m3_LinkRawFunction(fx._module, "spectest", "print_i32", "v(i)", @@recording_print_i32),
            m3Err_moduleNotLinked, "link before m3_LoadModule")
        m3_FreeModule(fx._module)
        fx._module = null
    }
    free_bind_fixture(fx)
}


// C FindAndLinkFunction: result starts as m3Err_functionLookupFailed and is
// only cleared by a match; ValidateSignature rejects a mismatching signature.
[test]
def test_link_lookup_and_signature(t : T?) {
    var bytes <- module_bytes()
    var fx = new_bind_fixture(bytes)
    if (fx._module == null) return
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_none, "m3_LoadModule")

    t |> equal(m3_LinkRawFunction(fx._module, "spectest", "no_such_name", "v(i)", @@recording_print_i32),
        m3Err_functionLookupFailed, "unknown field name")
    t |> equal(m3_LinkRawFunction(fx._module, "other_module", "print_i32", "v(i)", @@recording_print_i32),
        m3Err_functionLookupFailed, "unknown module name")
    t |> equal(m3_LinkRawFunction(fx._module, "spectest", "print_i32", "v(I)", @@recording_print_i32),
        "function signature mismatch", "signature mismatch")
    t |> equal(m3_LinkRawFunction(fx._module, "spectest", "print_i32", "x(i)", @@recording_print_i32),
        "unknown argument type char", "malformed signature propagates")
    // C: if (i_signature) - the port spells C's NULL signature as "".
    t |> equal(m3_LinkRawFunction(fx._module, "spectest", "print_i32", "", @@recording_print_i32),
        m3Err_none, "no signature skips validation")
    // C: wildcardModule = (strcmp (i_moduleName, "*") == 0).
    t |> equal(m3_LinkRawFunction(fx._module, "*", "print_i32", "v(i)", @@recording_print_i32),
        m3Err_none, "wildcard module name")

    free_bind_fixture(fx)
}


// The linked import is reached through op_CallRawFunction at run time.
[test]
def test_linked_import_is_called_from_wasm(t : T?) {
    var bytes <- module_bytes()
    var fx = new_bind_fixture(bytes)
    if (fx._module == null) return
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_none, "m3_LoadModule")

    g_calls = 0
    g_lastArg = 0
    g_lastUserdata = null
    var userdata = 0xabcd
    t |> equal(m3_LinkRawFunctionEx(fx._module, "spectest", "print_i32", "v(i)",
        @@recording_print_i32, unsafe(addr<void const?>(userdata))), m3Err_none, "m3_LinkRawFunctionEx")

    var callIt : IM3Function
    t |> equal(m3_FindFunction(callIt, fx.runtime, "call_it"), m3Err_none, "m3_FindFunction call_it")
    if (callIt != null) {
        var args : array<M3TaggedValue>
        args |> resize(1)
        args[0]._type = M3ValueType.c_m3Type_i32
        tagged_set_i32(args[0], 41)
        t |> equal(m3_CallV(callIt, args), m3Err_none, "m3_CallV call_it(41)")

        var rets : array<M3TaggedValue>
        t |> equal(m3_GetResultsV(callIt, rets), m3Err_none, "m3_GetResultsV")
        if (length(rets) == 1) {
            t |> equal(tagged_get_i32(rets[0]), 42, "call_it(41)")
        }
        t |> equal(g_calls, 1, "host function called once")
        t |> equal(g_lastArg, 41, "host function saw the wasm argument")
        t |> success(g_lastUserdata == unsafe(addr<void?>(userdata)), "userdata reached M3ImportContext")
    }

    free_bind_fixture(fx)
}


// A trap returned by the host function propagates out of m3_CallV.
[test]
def test_linked_import_can_trap(t : T?) {
    var bytes <- module_bytes()
    var fx = new_bind_fixture(bytes)
    if (fx._module == null) return
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_none, "m3_LoadModule")
    t |> equal(m3_LinkRawFunction(fx._module, "spectest", "print_i32", "v(i)", @@trapping_print_i32),
        m3Err_none, "link trapping import")

    var callIt : IM3Function
    t |> equal(m3_FindFunction(callIt, fx.runtime, "call_it"), m3Err_none, "m3_FindFunction call_it")
    if (callIt != null) {
        var args : array<M3TaggedValue>
        args |> resize(1)
        args[0]._type = M3ValueType.c_m3Type_i32
        tagged_set_i32(args[0], 1)
        t |> equal(m3_CallV(callIt, args), m3Err_trapAbort, "trap from the host function")
    }

    free_bind_fixture(fx)
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
