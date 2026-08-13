options gen2
options indenting = 4

module m3_bind shared public

require ./m3_function.das public
require strings


/*
    First m3_bind.c stage: signature character conversion and function-type
    construction only. ValidateSignature and linking stay out until the module
    and compiler layers exist.

    C accepts nullable pointers for both output and signature. A Daslang `var`
    output reference and `ccstr_t` string are not nullable in the same sense,
    so the two C null-pointer guards are intentionally not represented by fake
    runtime conditions. All representable parsing/error/cleanup behavior below
    follows the C function.
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

    if (!empty(result)) {
        m3_Free_Impl(unsafe(reinterpret<void?>(funcType)))
        funcType = null
    }

    o_functionType = funcType
    return result
}
