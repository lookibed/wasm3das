options gen2
options indenting = 4

module m3_bind shared public

require ./m3_function.das public
require ./m3_compile.das
require strings


/*
    Conservative Gen2 port of m3_bind.c: signature character conversion,
    function-type construction, signature validation and raw-function linking.

    C accepts nullable pointers for both output and signature. A Daslang `var`
    output reference and `ccstr_t` string are not nullable in the same sense,
    so the two C null-pointer guards in SignatureToFuncType are intentionally
    not represented by fake runtime conditions. FindAndLinkFunction keeps C's
    optional signature by treating the empty string as C's NULL i_signature,
    which is the only value a caller can pass for "do not validate" (a wasm
    signature is never empty; the shortest legal one is "v()").

    All representable parsing/error/cleanup behavior below follows the C
    functions.
*/


// ============================================================================
// 1. ConvertTypeCharToTypeId
// ============================================================================


def public ConvertTypeCharToTypeId(i_code : int) : u8 {
    if (i_code == 'v') {
        return u8(M3ValueType.c_m3Type_none)
    }
    if (i_code == 'i') {
        return u8(M3ValueType.c_m3Type_i32)
    }
    if (i_code == 'I') {
        return u8(M3ValueType.c_m3Type_i64)
    }
    if (i_code == 'f') {
        return u8(M3ValueType.c_m3Type_f32)
    }
    if (i_code == 'F') {
        return u8(M3ValueType.c_m3Type_f64)
    }
    if (i_code == '*') {
        return u8(M3ValueType.c_m3Type_i32)
    }
    return u8(M3ValueType.c_m3Type_unknown)
}


def private ParseSignatureTypeList(
                                   var funcType : IM3FuncType;
                                   i_signature : ccstr_t;
                                   maxNumTypes : u32;
                                   var sig : int&;
                                   var typelist : u8?&
                                   ) : M3Result {
    var result = m3Err_none
    var parsingRets = true

    peek_data(i_signature) $(data : array<uint8> const#) {
        while (sig < length(data)) {
            let typeChar = int(data[sig])
            sig++

            if (typeChar == '(') {
                parsingRets = false
                continue
            } elif (typeChar == ' ') {
                continue
            } elif (typeChar == ')') {
                break
            }

            // C local `type`; `type` is a gen2 keyword, so only the spelling changes.
            let typeId = ConvertTypeCharToTypeId(typeChar)

            if (typeId == u8(M3ValueType.c_m3Type_unknown)) {
                result = "unknown argument type char"
                break
            }
            if (typeId == u8(M3ValueType.c_m3Type_none)) {
                continue
            }

            if (parsingRets) {
                if (u32(funcType.numRets) >= maxNumTypes) {
                    result = "malformed signature; return count overflow"
                    break
                }
                funcType.numRets = u16(u32(funcType.numRets) + 1u)
                *typelist = typeId
                typelist = unsafe(reinterpret<u8?>(intptr(typelist) + 1))
            } else {
                if (u32(funcType.numRets) + u32(funcType.numArgs) >= maxNumTypes) {
                    result = "malformed signature; arg count overflow"
                    break
                }
                funcType.numArgs = u16(u32(funcType.numArgs) + 1u)
                *typelist = typeId
                typelist = unsafe(reinterpret<u8?>(intptr(typelist) + 1))
            }
        }
    }

    return result
}


// ============================================================================
// 2. SignatureToFuncType
// ============================================================================


def public SignatureToFuncType(var o_functionType : IM3FuncType&; i_signature : ccstr_t) : M3Result {
    var funcType : IM3FuncType = null
    o_functionType = null

    // C's `sig` is a moving char pointer. In Daslang the same cursor is an
    // integer into one byte-view obtained up front, avoiding repeated strlen.
    var sig = 0
    var maxNumTypes = u32(length(i_signature))

    // assume min signature is "()"
    if (maxNumTypes < 2u) {
        return m3Err_malformedFunctionSignature
    }
    maxNumTypes -= 2u

    if (maxNumTypes > u32(d_m3MaxSaneFunctionArgRetCount)) {
        return m3Err_tooManyArgsRets
    }

    var result : M3Result = AllocFuncType(funcType, maxNumTypes)
    if (!empty(result)) {
        return result
    }

    var typelist = unsafe(addr(funcType.types[0]))
    result = ParseSignatureTypeList(funcType, i_signature, maxNumTypes, sig, typelist)

    if (!empty(result)) {
        m3_Free_Impl(unsafe(reinterpret<void?>(funcType)))
        funcType = null
    }

    o_functionType = funcType
    return result
}


// ============================================================================
// 3. ValidateSignature
// ============================================================================


def private ValidateSignature(var i_function : IM3Function; i_linkingSignature : ccstr_t) : M3Result {
    var ftype : IM3FuncType = null
    var result : M3Result = SignatureToFuncType(ftype, i_linkingSignature)

    if (result == m3Err_none) {
        if (!AreFuncTypesEqual(ftype, i_function.funcType)) {
            // compiled out under the active configuration: the two m3log
            // (module) lines printing SPrintFuncTypeSignature of both types.
            result = "function signature mismatch"
        }
    }

    // C: m3_Free (ftype) - reached from both the try body and the catch label.
    m3_Free_Impl(unsafe(reinterpret<void?>(ftype)))
    ftype = null

    return result
}


// ============================================================================
// 4. FindAndLinkFunction
// ============================================================================


def public FindAndLinkFunction(
                               var io_module : IM3Module;
                               i_moduleName : ccstr_t;
                               i_functionName : ccstr_t;
                               i_signature : ccstr_t;
                               i_function : M3RawCall;
                               i_userdata : void const?
                               ) : M3Result {
    if (io_module.runtime == null) {
        return m3Err_moduleNotLinked
    }

    let wildcardModule = i_moduleName == "*"

    var result : M3Result = m3Err_functionLookupFailed

    for (i in 0u..io_module.numFunctions) {
        var f : IM3Function
        unsafe { f = addr(io_module.functions[i]) }

        // C: f->import.moduleUtf8 and f->import.fieldUtf8 - a non-NULL check.
        // cstr_t is a Daslang string here, so C's NULL is the empty string
        // (docs/memory-ownership.md, "Strings stay Daslang strings").
        if (!empty(f.import.moduleUtf8) && !empty(f.import.fieldUtf8)) {
            if (f.import.fieldUtf8 == i_functionName &&
                (wildcardModule || f.import.moduleUtf8 == i_moduleName)) {
                // C: if (i_signature) - an empty signature stands for C NULL.
                if (!empty(i_signature)) {
                    result = ValidateSignature(f, i_signature)
                    if (result != m3Err_none) { return result }
                }
                result = CompileRawFunction(io_module, f, unsafe(reinterpret<void const?>(i_function)), i_userdata)
                if (result != m3Err_none) { return result }
            }
        }
    }

    return result
}


// ============================================================================
// 5. m3_LinkRawFunctionEx / m3_LinkRawFunction
// ============================================================================


def public m3_LinkRawFunctionEx(
                                var io_module : IM3Module;
                                i_moduleName : ccstr_t;
                                i_functionName : ccstr_t;
                                i_signature : ccstr_t;
                                i_function : M3RawCall;
                                i_userdata : void const?
                                ) : M3Result {
    return FindAndLinkFunction(io_module, i_moduleName, i_functionName, i_signature, i_function, i_userdata)
}


def public m3_LinkRawFunction(
                              var io_module : IM3Module;
                              i_moduleName : ccstr_t;
                              i_functionName : ccstr_t;
                              i_signature : ccstr_t;
                              i_function : M3RawCall
                              ) : M3Result {
    return FindAndLinkFunction(io_module, i_moduleName, i_functionName, i_signature, i_function, null)
}
