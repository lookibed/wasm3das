options gen2
options indenting = 4

module test_m3_bind shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_bind
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core
require strings

/*
    test_m3_bind.das: Eden counterpart of
    .upstream/tests/integration/test_m3_bind.das.

    Coverage of the upstream [test]s (12 of 12 ported):
      - test_convert_type_char_to_type_id, test_empty_signatures,
        test_signature_basic_and_spaces, test_multiple_results_and_physical_order,
        test_void_is_not_stored, test_unknown_and_count_overflow_errors,
        test_sane_count_limit, test_first_close_parenthesis_stops_parsing:
        the same signatures and expectations on a runtime's func-type arena
        (Eden: the type is a handle into rt.funcTypes, -1 after an error; the
        upstream FreeFuncType pops the slot; raw_type reads the slot's
        `types`). Eden adds: a failed parse leaves rt.funcTypes as it was,
        and the sane limit's boundary ("(" + 1000 x "i" + ")") parses.
      - test_link_before_load_is_rejected, test_link_lookup_and_signature,
        test_linked_import_is_called_from_wasm, test_linked_import_can_trap:
        the same hand-assembled module (import "spectest" "print_i32") and
        the same results (Eden: the runtime first, a module handle, the host
        function reads its argument from rt.stack at sp, the userdata is an
        int token). Eden adds: a failed validation leaves rt.funcTypes as it
        was, the linked import's moduleIdx is the module and one raw call is
        pushed per link.
    Tests added for the Eden shape (no upstream counterpart):
      - test_link_env_add: import "env" "add" (i32, i32) -> i32 linked with
        m3_LinkRawFunction to a daslang function that reads both arguments
        at sp and writes the result; the export "sum" returns it.
      - test_link_userdata: the host function reads ctx.userdata (the
        m3_LinkRawFunctionEx token) and ctx.functionIdx.
      - test_link_host_trap_message: a host function's own result string
        propagates out of m3_Call.
      - test_link_errors: a wrong signature gives "function signature
        mismatch", an unknown field or module name m3Err_functionLookupFailed
        (C's strings), with rt.funcTypes and rt.rawCalls unchanged.
      - test_unlinked_import_missing: a module whose import is not linked
        fails to compile its caller with m3Err_functionImportMissing
        (DESIGN 4.1: the import's moduleIdx stays -1).
      - test_link_empty_field_name: a names.wast-style import whose field
        name is "" is linked by "" (C tests NULL, not emptiness).
*/


// ============================================================================
// Helpers
// ============================================================================


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


// a runtime of `stackBytes` bytes of stack from a fresh environment
def private new_runtime(stackBytes : u32) : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, stackBytes, -1)
    return <- rt
}


// upstream FreeFuncType: releases a type SignatureToFuncType built. Eden:
// the type is the last slot of rt.funcTypes, which is popped
def private FreeFuncType(var t : TestRun; var rt : M3Runtime; var funcType : IM3FuncType&) {
    if (funcType != -1) {
        equal(t, funcType, length(rt.funcTypes) - 1, "the built type is the last slot")
        if (funcType == length(rt.funcTypes) - 1) {
            pop(rt.funcTypes)
        }
        funcType = -1
    }
}


// upstream raw_type: the index-th byte of the type's tail (results first)
def private raw_type(rt : M3Runtime; funcType : IM3FuncType; index : int) : u8 {
    return rt.funcTypes[funcType].types[index]
}


def private expect_error(var t : TestRun; var rt : M3Runtime; signature : string; expected : M3Result; testLabel : string) {
    let before = length(rt.funcTypes)
    var funcType : IM3FuncType = 7   // Eden: any value; the error must write -1
    let result = SignatureToFuncType(rt, funcType, signature)
    is_err(t, result, expected, "{testLabel}: error")
    equal(t, funcType, -1, "{testLabel}: output must be -1 (C: NULL) after error")
    equal(t, length(rt.funcTypes), before, "{testLabel}: the failed type is released")
}


// ============================================================================
// Upstream: signature parsing
// ============================================================================


def test_convert_type_char_to_type_id(var t : TestRun; fx : FixtureSource) {
    equal(t, ConvertTypeCharToTypeId('v'), type_none(), "v mapping")
    equal(t, ConvertTypeCharToTypeId('i'), type_i32(), "i mapping")
    equal(t, ConvertTypeCharToTypeId('I'), type_i64(), "I mapping")
    equal(t, ConvertTypeCharToTypeId('f'), type_f32(), "f mapping")
    equal(t, ConvertTypeCharToTypeId('F'), type_f64(), "F mapping")
    equal(t, ConvertTypeCharToTypeId('*'), type_i32(), "pointer mapping")
    equal(t, ConvertTypeCharToTypeId('?'), type_unknown(), "unknown mapping")
}


def test_empty_signatures(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    expect_error(t, rt, "", m3Err_malformedFunctionSignature, "empty")

    var funcType : IM3FuncType = -1
    is_ok(t, SignatureToFuncType(rt, funcType, "()"), "() result")
    check(t, funcType != -1, "() allocation")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(0), "() results")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(0), "() args")
    FreeFuncType(t, rt, funcType)

    is_ok(t, SignatureToFuncType(rt, funcType, " v () "), "spaced void result")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(0), "spaced void results")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(0), "spaced void args")
    FreeFuncType(t, rt, funcType)
    m3_FreeRuntime(rt)
}


def test_signature_basic_and_spaces(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    var funcType : IM3FuncType = -1
    is_ok(t, SignatureToFuncType(rt, funcType, "f(IiF)"), "basic parse")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(1), "basic result count")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(3), "basic arg count")
    equal(t, GetFuncTypeResultType(rt, funcType, u16(0)), type_f32(), "basic result type")
    equal(t, GetFuncTypeParamType(rt, funcType, u16(0)), type_i64(), "basic arg 0")
    equal(t, GetFuncTypeParamType(rt, funcType, u16(1)), type_i32(), "basic arg 1")
    equal(t, GetFuncTypeParamType(rt, funcType, u16(2)), type_f64(), "basic arg 2")
    FreeFuncType(t, rt, funcType)

    is_ok(t, SignatureToFuncType(rt, funcType, "f(I i F)"), "spaced parse")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(1), "spaced result count")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(3), "spaced arg count")
    equal(t, GetFuncTypeResultType(rt, funcType, u16(0)), type_f32(), "spaced result type")
    equal(t, GetFuncTypeParamType(rt, funcType, u16(0)), type_i64(), "spaced arg 0")
    equal(t, GetFuncTypeParamType(rt, funcType, u16(1)), type_i32(), "spaced arg 1")
    equal(t, GetFuncTypeParamType(rt, funcType, u16(2)), type_f64(), "spaced arg 2")
    FreeFuncType(t, rt, funcType)
    m3_FreeRuntime(rt)
}


def test_multiple_results_and_physical_order(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    var funcType : IM3FuncType = -1
    is_ok(t, SignatureToFuncType(rt, funcType, "if(I*)"), "multi-result parse")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(2), "multi result count")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(2), "multi arg count")
    if (funcType != -1) {
        equal(t, raw_type(rt, funcType, 0), type_i32(), "physical result 0")
        equal(t, raw_type(rt, funcType, 1), type_f32(), "physical result 1")
        equal(t, raw_type(rt, funcType, 2), type_i64(), "physical arg 0")
        equal(t, raw_type(rt, funcType, 3), type_i32(), "physical pointer arg")
    }
    FreeFuncType(t, rt, funcType)
    m3_FreeRuntime(rt)
}


def test_void_is_not_stored(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    var funcType : IM3FuncType = -1
    is_ok(t, SignatureToFuncType(rt, funcType, "v(ivI)"), "void positions parse")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(0), "void result skipped")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(2), "void arg skipped")
    if (funcType != -1) {
        equal(t, raw_type(rt, funcType, 0), type_i32(), "void args physical 0")
        equal(t, raw_type(rt, funcType, 1), type_i64(), "void args physical 1")
    }
    FreeFuncType(t, rt, funcType)
    m3_FreeRuntime(rt)
}


def test_unknown_and_count_overflow_errors(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    expect_error(t, rt, "x()", "unknown argument type char", "unknown result char")
    expect_error(t, rt, "(x)", "unknown argument type char", "unknown arg char")
    expect_error(t, rt, "iii", "malformed signature; return count overflow", "return overflow")
    expect_error(t, rt, "(ii", "malformed signature; arg count overflow", "arg overflow")
    m3_FreeRuntime(rt)
}


def test_sane_count_limit(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    // upstream: a literal of "(", 1001 x "i", ")": 1001 types > d_m3MaxSaneFunctionArgRetCount
    let tooMany = repeat("i", d_m3MaxSaneFunctionArgRetCount + 1)
    let signature = "({tooMany})"
    equal(t, length(signature), 1003, "the upstream signature length")
    expect_error(t, rt, signature, m3Err_tooManyArgsRets, "sane count limit")

    // Eden: the boundary, 1000 types, is accepted
    let atLimit = repeat("i", d_m3MaxSaneFunctionArgRetCount)
    var funcType : IM3FuncType = -1
    is_ok(t, SignatureToFuncType(rt, funcType, "({atLimit})"), "the sane limit itself parses")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(d_m3MaxSaneFunctionArgRetCount), "the sane limit arg count")
    FreeFuncType(t, rt, funcType)
    m3_FreeRuntime(rt)
}


def test_first_close_parenthesis_stops_parsing(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    var funcType : IM3FuncType = -1
    is_ok(t, SignatureToFuncType(rt, funcType, "i()ignored"), "ignored tail parse")
    equal(t, GetFuncTypeNumResults(rt, funcType), u16(1), "ignored tail result count")
    equal(t, GetFuncTypeNumParams(rt, funcType), u16(0), "ignored tail arg count")
    equal(t, GetFuncTypeResultType(rt, funcType, u16(0)), type_i32(), "ignored tail result type")
    FreeFuncType(t, rt, funcType)
    m3_FreeRuntime(rt)
}


// ============================================================================
// Upstream: linking (ValidateSignature, FindAndLinkFunction, m3_LinkRawFunction[Ex])
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
def private importing_wasm() : array<u8> {
    var bytes <- [
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
    return <- bytes
}


/*
    (module
      (import "env" "add" (func $add (param i32 i32) (result i32)))
      (func (export "sum") (param i32 i32) (result i32)
        (call $add (local.get 0) (local.get 1))))
*/
def private env_add_wasm() : array<u8> {
    var bytes <- [
        0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
        // type: (i32, i32)->(i32)
        0x01u8, 0x07u8, 0x01u8, 0x60u8, 0x02u8, 0x7fu8, 0x7fu8, 0x01u8, 0x7fu8,
        // import: "env" "add" func type 0
        0x02u8, 0x0bu8, 0x01u8,
        0x03u8, 0x65u8, 0x6eu8, 0x76u8,
        0x03u8, 0x61u8, 0x64u8, 0x64u8,
        0x00u8, 0x00u8,
        // function: one local function of type 0
        0x03u8, 0x02u8, 0x01u8, 0x00u8,
        // export: "sum" -> func 1
        0x07u8, 0x07u8, 0x01u8,
        0x03u8, 0x73u8, 0x75u8, 0x6du8,
        0x00u8, 0x01u8,
        // code: local.get 0; local.get 1; call 0; end
        0x0au8, 0x0au8, 0x01u8, 0x08u8,
        0x00u8, 0x20u8, 0x00u8, 0x20u8, 0x01u8, 0x10u8, 0x00u8, 0x0bu8
    ]
    return <- bytes
}


/*
    names.wast shape: an import whose field name is "".
    (module
      (import "env" "" (func $e (result i32)))
      (func (export "get") (result i32) (call $e)))
*/
def private empty_field_wasm() : array<u8> {
    var bytes <- [
        0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
        // type: () -> i32
        0x01u8, 0x05u8, 0x01u8, 0x60u8, 0x00u8, 0x01u8, 0x7fu8,
        // import: "env" "" func type 0
        0x02u8, 0x08u8, 0x01u8, 0x03u8, 0x65u8, 0x6eu8, 0x76u8, 0x00u8, 0x00u8, 0x00u8,
        // function: one of type 0
        0x03u8, 0x02u8, 0x01u8, 0x00u8,
        // export: "get" func 1
        0x07u8, 0x07u8, 0x01u8, 0x03u8, 0x67u8, 0x65u8, 0x74u8, 0x00u8, 0x01u8,
        // code: call 0; end
        0x0au8, 0x06u8, 0x01u8, 0x04u8, 0x00u8, 0x10u8, 0x00u8, 0x0bu8
    ]
    return <- bytes
}


var private g_calls = 0
var private g_lastArg = 0
var private g_lastUserdata = -1
var private g_lastFunction = -1


// C: m3ApiRawFunction (recording_print_i32). m3ApiGetArg (int32_t, i_value)
// reads the first u64 cell at _sp (no return cell for a void function);
// _ctx->userdata is the m3_LinkRawFunctionEx payload. Eden: the cell is
// rt.stack[sp], the userdata an int token
def private recording_print_i32(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    g_calls++
    g_lastArg = stack_i32(rt, sp)
    g_lastUserdata = ctx.userdata
    g_lastFunction = ctx.functionIdx
    return m3Err_none
}


def private trapping_print_i32(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    return m3Err_trapAbort
}


// parse and (when `load`) load `bytes` into rt; -1 when the parse fails
def private parse_module(var t : TestRun; var rt : M3Runtime; bytes : array<u8>; load : bool) : IM3Module {
    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "hand-built module parses")
    if (parsed._0 != m3Err_none) {
        return -1
    }
    if (load) {
        is_ok(t, m3_LoadModule(rt, parsed._1), "m3_LoadModule")
    }
    return parsed._1
}


// C FindAndLinkFunction: _throwif (m3Err_moduleNotLinked, !io_module->runtime).
def test_link_before_load_is_rejected(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, importing_wasm(), false)
    check(t, m != -1, "hand-built module parses")
    if (m != -1) {
        is_err(t, m3_LinkRawFunction(rt, m, "spectest", "print_i32", "v(i)", @@recording_print_i32),
            m3Err_moduleNotLinked, "link before m3_LoadModule")
        equal(t, length(rt.rawCalls), 0, "nothing linked")
        m3_FreeModule(rt, m)
    }
    m3_FreeRuntime(rt)
}


// C FindAndLinkFunction: result starts as m3Err_functionLookupFailed and is
// only cleared by a match; ValidateSignature rejects a mismatching signature.
def test_link_lookup_and_signature(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, importing_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    let numTypes = length(rt.funcTypes)

    is_err(t, m3_LinkRawFunction(rt, m, "spectest", "no_such_name", "v(i)", @@recording_print_i32),
        m3Err_functionLookupFailed, "unknown field name")
    is_err(t, m3_LinkRawFunction(rt, m, "other_module", "print_i32", "v(i)", @@recording_print_i32),
        m3Err_functionLookupFailed, "unknown module name")
    is_err(t, m3_LinkRawFunction(rt, m, "spectest", "print_i32", "v(I)", @@recording_print_i32),
        "function signature mismatch", "signature mismatch")
    is_err(t, m3_LinkRawFunction(rt, m, "spectest", "print_i32", "x(i)", @@recording_print_i32),
        "unknown argument type char", "malformed signature propagates")
    equal(t, length(rt.funcTypes), numTypes, "validation leaves the func-type arena as it was")
    equal(t, length(rt.rawCalls), 0, "a failed link pushes no raw call")
    // C: if (i_signature) - the port spells C's NULL signature as "".
    is_ok(t, m3_LinkRawFunction(rt, m, "spectest", "print_i32", "", @@recording_print_i32),
        "no signature skips validation")
    // C: wildcardModule = (strcmp (i_moduleName, "*") == 0).
    is_ok(t, m3_LinkRawFunction(rt, m, "*", "print_i32", "v(i)", @@recording_print_i32),
        "wildcard module name")
    equal(t, length(rt.funcTypes), numTypes, "a matching signature is released too")
    equal(t, length(rt.rawCalls), 2, "one raw call per successful link")
    let imp = rt.modules[m].functions[0]
    equal(t, rt.functions[imp].moduleIdx, m, "the linked import belongs to the module")
    check(t, rt.functions[imp].compiled != -1, "the linked import is compiled")

    m3_FreeRuntime(rt)
}


// The linked import is reached through op_CallRawFunction at run time.
def test_linked_import_is_called_from_wasm(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, importing_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    g_calls = 0
    g_lastArg = 0
    g_lastUserdata = -1
    g_lastFunction = -1
    let userdata = 43981   // 0xabcd; Eden: the token (upstream: the address of a local holding 0xabcd)
    is_ok(t, m3_LinkRawFunctionEx(rt, m, "spectest", "print_i32", "v(i)", @@recording_print_i32, userdata),
        "m3_LinkRawFunctionEx")

    var callIt : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, callIt, "call_it"), "m3_FindFunction call_it")
    if (callIt != -1) {
        var args : array<M3TaggedValue>
        push(args, M3TaggedValue(_type = M3ValueType.c_m3Type_i32))
        tagged_set_i32(args[0], 41)
        is_ok(t, m3_CallV(rt, callIt, args), "m3_CallV call_it(41)")

        var rets : array<M3TaggedValue>
        is_ok(t, m3_GetResultsV(rt, callIt, rets), "m3_GetResultsV")
        equal(t, length(rets), 1, "one result")
        if (length(rets) == 1) {
            equal(t, tagged_get_i32(rets[0]), 42, "call_it(41)")
        }
        equal(t, g_calls, 1, "host function called once")
        equal(t, g_lastArg, 41, "host function saw the wasm argument")
        equal(t, g_lastUserdata, userdata, "userdata reached M3ImportContext")
        equal(t, g_lastFunction, rt.modules[m].functions[0], "ctx.functionIdx is the import")
    }

    m3_FreeRuntime(rt)
}


// A trap returned by the host function propagates out of m3_CallV.
def test_linked_import_can_trap(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, importing_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LinkRawFunction(rt, m, "spectest", "print_i32", "v(i)", @@trapping_print_i32),
        "link trapping import")

    var callIt : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, callIt, "call_it"), "m3_FindFunction call_it")
    if (callIt != -1) {
        var args : array<M3TaggedValue>
        push(args, M3TaggedValue(_type = M3ValueType.c_m3Type_i32))
        tagged_set_i32(args[0], 1)
        is_err(t, m3_CallV(rt, callIt, args), m3Err_trapAbort, "trap from the host function")
    }

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: host functions through the Eden raw-call ABI
// ============================================================================


// env.add (i32, i32) -> i32. The frame at sp is C's: the return cell first,
// then one u64 cell per argument (C: m3ApiReturnType, m3ApiGetArg advance a
// u64 *), and a u64 cell is two slot words here (DESIGN 4.3)
def private host_add(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    let a = stack_i32(rt, sp + 2)
    let b = stack_i32(rt, sp + 4)
    set_stack_i32(rt, sp, a + b)
    return m3Err_none
}


// env.add that adds the userdata token of its link
def private host_add_userdata(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    g_lastFunction = ctx.functionIdx
    let a = stack_i32(rt, sp + 2)
    let b = stack_i32(rt, sp + 4)
    set_stack_i32(rt, sp, a + b + ctx.userdata)
    return m3Err_none
}


def private host_add_traps(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    return "host add refused"
}


def private host_forty_two(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    set_stack_i32(rt, sp, 42)
    return m3Err_none
}


// calls "sum"(a, b) of a loaded module; the i32 result, or `fallback`
def private call_sum(var t : TestRun; var rt : M3Runtime; a : int; b : int; fallback : int) : int {
    var result = fallback
    var sum : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, sum, "sum"), "m3_FindFunction sum")
    if (sum != -1) {
        is_ok(t, m3_Call(rt, sum, [m3_bits_from_i32(a), m3_bits_from_i32(b)]), "m3_Call sum({a}, {b})")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, sum, 1u, out), "m3_GetResults sum({a}, {b})")
        if (length(out) == 1) {
            result = m3_bits_to_i32(out[0])
        }
    }
    return result
}


def test_link_env_add(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, env_add_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LinkRawFunction(rt, m, "env", "add", "i(ii)", @@host_add), "link env.add")
    equal(t, call_sum(t, rt, 40, 2, -999), 42, "sum(40, 2) through env.add")
    equal(t, call_sum(t, rt, -5, 3, -999), -2, "sum(-5, 3) through env.add")
    equal(t, call_sum(t, rt, 2147483647, 1, -999), -2147483647 - 1, "sum wraps as i32")
    m3_FreeRuntime(rt)
}


def test_link_userdata(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, env_add_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    g_lastFunction = -1
    is_ok(t, m3_LinkRawFunctionEx(rt, m, "env", "add", "i(ii)", @@host_add_userdata, 100), "link env.add with userdata 100")
    equal(t, call_sum(t, rt, 1, 2, -999), 103, "the host function read ctx.userdata")
    equal(t, g_lastFunction, rt.modules[m].functions[0], "ctx.functionIdx is the linked import")
    m3_FreeRuntime(rt)
}


def test_link_host_trap_message(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, env_add_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LinkRawFunction(rt, m, "env", "add", "i(ii)", @@host_add_traps), "link a trapping env.add")
    var sum : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, sum, "sum"), "m3_FindFunction sum")
    if (sum != -1) {
        is_err(t, m3_Call(rt, sum, [m3_bits_from_i32(1), m3_bits_from_i32(2)]), "host add refused", "the host result string propagates")
    }
    m3_FreeRuntime(rt)
}


def test_link_errors(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, env_add_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    let numTypes = length(rt.funcTypes)
    is_err(t, m3_LinkRawFunction(rt, m, "env", "add", "i(iI)", @@host_add), "function signature mismatch", "wrong argument type")
    is_err(t, m3_LinkRawFunction(rt, m, "env", "add", "v(ii)", @@host_add), "function signature mismatch", "wrong result count")
    is_err(t, m3_LinkRawFunction(rt, m, "env", "add", "i(i)", @@host_add), "function signature mismatch", "wrong argument count")
    is_err(t, m3_LinkRawFunction(rt, m, "env", "sub", "i(ii)", @@host_add), m3Err_functionLookupFailed, "a field name that does not exist")
    is_err(t, m3_LinkRawFunction(rt, m, "wasi", "add", "i(ii)", @@host_add), m3Err_functionLookupFailed, "a module name that does not exist")
    is_err(t, m3_LinkRawFunction(rt, m, "env", "sum", "i(ii)", @@host_add), m3Err_functionLookupFailed, "an export is not an import")
    is_err(t, m3_LinkRawFunction(rt, m, "env", "add", "i", @@host_add), m3Err_malformedFunctionSignature, "a signature shorter than ()")
    equal(t, length(rt.funcTypes), numTypes, "failed links leave the func-type arena as it was")
    equal(t, length(rt.rawCalls), 0, "failed links push no raw call")
    equal(t, rt.functions[rt.modules[m].functions[0]].moduleIdx, -1, "the import is still unlinked")
    m3_FreeRuntime(rt)
}


def test_unlinked_import_missing(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, env_add_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    var sum : IM3Function = 5   // Eden: any value; the failure writes -1
    is_err(t, m3_FindFunction(rt, sum, "sum"), m3Err_functionImportMissing, "the caller of an unlinked import does not compile")
    equal(t, sum, -1, "no function on failure")
    equal(t, rt.functions[rt.modules[m].functions[0]].moduleIdx, -1, "the unlinked import has no module")
    m3_FreeRuntime(rt)
}


def test_link_empty_field_name(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let m = parse_module(t, rt, empty_field_wasm(), true)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    is_err(t, m3_LinkRawFunction(rt, m, "env", "x", "i()", @@host_forty_two), m3Err_functionLookupFailed, "a non-empty name does not match the field \"\"")
    is_ok(t, m3_LinkRawFunction(rt, m, "env", "", "i()", @@host_forty_two), "the field \"\" is linked by \"\"")
    var get : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, get, "get"), "m3_FindFunction get")
    if (get != -1) {
        var none : array<u64>
        is_ok(t, m3_Call(rt, get, none), "m3_Call get")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, get, 1u, out), "m3_GetResults get")
        if (length(out) == 1) {
            equal(t, m3_bits_to_i32(out[0]), 42, "the import with an empty field name is called")
        }
    }
    m3_FreeRuntime(rt)
}


def public run_tests_m3_bind(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_convert_type_char_to_type_id")
    test_convert_type_char_to_type_id(t, fx)
    begin_test(t, "test_empty_signatures")
    test_empty_signatures(t, fx)
    begin_test(t, "test_signature_basic_and_spaces")
    test_signature_basic_and_spaces(t, fx)
    begin_test(t, "test_multiple_results_and_physical_order")
    test_multiple_results_and_physical_order(t, fx)
    begin_test(t, "test_void_is_not_stored")
    test_void_is_not_stored(t, fx)
    begin_test(t, "test_unknown_and_count_overflow_errors")
    test_unknown_and_count_overflow_errors(t, fx)
    begin_test(t, "test_sane_count_limit")
    test_sane_count_limit(t, fx)
    begin_test(t, "test_first_close_parenthesis_stops_parsing")
    test_first_close_parenthesis_stops_parsing(t, fx)
    begin_test(t, "test_link_before_load_is_rejected")
    test_link_before_load_is_rejected(t, fx)
    begin_test(t, "test_link_lookup_and_signature")
    test_link_lookup_and_signature(t, fx)
    begin_test(t, "test_linked_import_is_called_from_wasm")
    test_linked_import_is_called_from_wasm(t, fx)
    begin_test(t, "test_linked_import_can_trap")
    test_linked_import_can_trap(t, fx)
    begin_test(t, "test_link_env_add")
    test_link_env_add(t, fx)
    begin_test(t, "test_link_userdata")
    test_link_userdata(t, fx)
    begin_test(t, "test_link_host_trap_message")
    test_link_host_trap_message(t, fx)
    begin_test(t, "test_link_errors")
    test_link_errors(t, fx)
    begin_test(t, "test_unlinked_import_missing")
    test_unlinked_import_missing(t, fx)
    begin_test(t, "test_link_empty_field_name")
    test_link_empty_field_name(t, fx)
}
