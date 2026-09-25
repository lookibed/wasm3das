options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (linking runs once per
// import, so inlining costs startup only) is dropped: the option is untested
// in the editor (DESIGN.md section 1) and the interpreter is the only tier of
// the Eden port.

module m3_bind shared public

require modules/wasm3das/source/m3_function public   // Eden: project-root-relative path (upstream: ./m3_function.das)
require modules/wasm3das/source/m3_compile           // Eden: project-root-relative path (upstream: ./m3_compile.das)
require strings


/*
    Conservative Gen2 port of m3_bind.c: signature character conversion,
    function-type construction, signature validation and raw-function linking.

    C accepts nullable pointers for both output and signature. A Daslang `var`
    output reference and `ccstr_t` string are not nullable in the same sense,
    so the two C null-pointer guards in SignatureToFuncType are intentionally
    not represented by fake runtime conditions. FindAndLinkFunction always
    validates the signature: C's `if (i_signature)` is true for every string
    a caller can pass (no C caller passes NULL), and an empty signature is
    rejected by SignatureToFuncType with m3Err_malformedFunctionSignature,
    as in C.

    All representable parsing/error/cleanup behavior below follows the C
    functions.

    Eden: deviations from the upstream port (.upstream/source/m3_bind.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md). The sandbox has no
    raw pointers, so a function type, a function and a module are handles
    into the arenas of a runtime (DESIGN section 4.1) and a host function is
    a function value in rt.rawCalls (DESIGN section 4.5):
      - the requires are Eden-project-root relative (DESIGN section 6);
        m3_function stays a public re-export.
      - every function takes the runtime first (`var`: SignatureToFuncType
        appends to rt.funcTypes, linking appends to rt.rawCalls and emits
        code), then the C parameters in C order. IM3FuncType is a handle
        into rt.funcTypes, IM3Function into rt.functions, IM3Module into
        rt.modules, -1 = NULL.
      - SignatureToFuncType: AllocFuncType appends one slot to rt.funcTypes;
        C's `u8 * typelist` cursor is an index into that slot's `types`, and
        C's `sig` char pointer is an index into the signature read with
        character_at (upstream: peek_data). C's `m3_Free (funcType)` on the
        error path, and ValidateSignature's unconditional `m3_Free (ftype)`,
        pop the just-appended last slot of rt.funcTypes (DESIGN 4.1, the
        func-type interning rule), so a failed parse or a validation leaves
        the arena as it was and every existing handle survives. The helper
        m3_bind_free_func_type is that one release, spelled once.
      - `_catch:` with code after it (SignatureToFuncType: the free and the
        output store; ValidateSignature: the free) is reached by falling
        through, never by an early return (DESIGN 4.7a, as upstream).
      - FindAndLinkFunction: C's `!io_module->runtime` is
        `rt.modules[io_module].runtime == -1`. C's test that an entry is an
        import, `f->import.moduleUtf8 and f->import.fieldUtf8` (two non-NULL
        tests), is `index < numFuncImports`: the parser adds every import,
        and only imports, first (DESIGN 4.1, as m3_env's v_FindFunction),
        with both names always set. An import whose field (or module) name
        is "" (names.wast) is therefore linkable, as in C; the upstream
        `!empty(...)` spelling refused it.
      - linking a host function: the M3RawCall function value is pushed
        into rt.rawCalls once per FindAndLinkFunction call, at the first
        matching import, and its handle is what CompileRawFunction emits
        (C: the function pointer itself, DESIGN 4.4 / 4.5). i_userdata is
        an int token (C: `const void *`), -1 = NULL; m3_LinkRawFunction
        passes -1 for C's NULL. The upstream u64 hop of the function value
        (an AOT workaround) has no counterpart.
      - rt.rawCalls holds function values, which a hot reload of the
        scripts cannot carry over (DESIGN section 1): a runtime linked
        before a reload must be recreated and relinked after it.
      - the upstream `options never_inline` is dropped (see the options).
    Everything else (function names, C order, control flow, the error
    strings and the order of the checks) is the C of m3_bind.c.
*/


// C: m3_Free (funcType) of a type just built by SignatureToFuncType.
// Eden: the type is the last slot of rt.funcTypes, which is popped (DESIGN
// 4.1); a handle that is not the last slot is left alone (see the header)
def private m3_bind_free_func_type(var rt : M3Runtime; i_funcType : IM3FuncType) {
    if (i_funcType != -1 && i_funcType == length(rt.funcTypes) - 1) {
        pop(rt.funcTypes)
    }
}


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


// Eden: the runtime first; o_functionType is a handle into rt.funcTypes
def public SignatureToFuncType(var rt : M3Runtime; var o_functionType : IM3FuncType&; i_signature : ccstr_t) : M3Result {
    var funcType : IM3FuncType = -1
    var result : M3Result = m3Err_none

    // C: _try {
    // C: if (not o_functionType) _throw ("null function type"); if (not
    // i_signature) _throw ("null function signature"); Eden: a reference and
    // a string are never NULL (see the header)

    // C's `sig` is a moving char pointer; Eden: an index into i_signature
    var sig = 0

    var maxNumTypes = u32(length(i_signature))   // C: strlen (i_signature)

    // assume min signature is "()"
    if (maxNumTypes < 2u) {
        result = m3Err_malformedFunctionSignature   // C: _throwif
    }

    if (result == m3Err_none) {
        maxNumTypes -= 2u

        if (maxNumTypes > u32(d_m3MaxSaneFunctionArgRetCount)) {
            result = m3Err_tooManyArgsRets   // C: _throwif
        }
    }

    if (result == m3Err_none) {
        result = AllocFuncType(rt, funcType, maxNumTypes)   // C: _ (AllocFuncType (& funcType, (u32) maxNumTypes))
    }

    if (result == m3Err_none) {
        var typelist = 0   // C: u8 * typelist = funcType->types; Eden: an index into the slot's types

        var parsingRets = true
        while (sig < length(i_signature)) {   // C: while (* sig)
            let typeChar = character_at(i_signature, sig)   // C: char typeChar = * sig++
            sig++

            if (typeChar == '(') {
                parsingRets = false
                continue
            } elif (typeChar == ' ') {
                continue
            } elif (typeChar == ')') {
                break
            }

            // C local `type`; a gen2 keyword, so only the spelling changes
            let _type = ConvertTypeCharToTypeId(typeChar)

            if (u8(M3ValueType.c_m3Type_unknown) == _type) {
                result = "unknown argument type char"   // C: _throwif
                break
            }

            if (_type == u8(M3ValueType.c_m3Type_none)) {
                continue
            }

            if (parsingRets) {
                if (u32(rt.funcTypes[funcType].numRets) >= maxNumTypes) {
                    result = "malformed signature; return count overflow"   // C: _throwif
                    break
                }
                rt.funcTypes[funcType].numRets = u16(u32(rt.funcTypes[funcType].numRets) + 1u)
                rt.funcTypes[funcType].types[typelist] = _type   // C: *typelist++ = type
                typelist++
            } else {
                if (u32(rt.funcTypes[funcType].numRets) + u32(rt.funcTypes[funcType].numArgs) >= maxNumTypes) {
                    result = "malformed signature; arg count overflow"   // C: _throwif
                    break
                }
                rt.funcTypes[funcType].numArgs = u16(u32(rt.funcTypes[funcType].numArgs) + 1u)
                rt.funcTypes[funcType].types[typelist] = _type   // C: *typelist++ = type
                typelist++
            }
        }
    }

    // C: } _catch:  Eden: reached by falling through (DESIGN 4.7a)

    if (result != m3Err_none) {
        m3_bind_free_func_type(rt, funcType)   // C: m3_Free (funcType); Eden: pops the slot (see the header)
        funcType = -1
    }

    o_functionType = funcType

    return result
}


// ============================================================================
// 3. ValidateSignature
// ============================================================================


// Eden: the runtime first; i_function is a handle into rt.functions
def private ValidateSignature(var rt : M3Runtime; i_function : IM3Function; i_linkingSignature : ccstr_t) : M3Result {
    var result : M3Result = m3Err_none

    var ftype : IM3FuncType = -1
    result = SignatureToFuncType(rt, ftype, i_linkingSignature)   // C: _ (SignatureToFuncType (& ftype, i_linkingSignature))

    if (result == m3Err_none) {
        if (!AreFuncTypesEqual(rt, ftype, rt.functions[i_function].funcTypeIdx)) {
            // compiled out under the active configuration: the two m3log
            // (module) lines printing SPrintFuncTypeSignature of both types.
            result = "function signature mismatch"   // C: _throw
        }
    }

    // C: _catch:  Eden: reached by falling through from both the body and
    // the failed SignatureToFuncType (DESIGN 4.7a)

    m3_bind_free_func_type(rt, ftype)   // C: m3_Free (ftype); Eden: pops the slot (see the header)

    return result
}


// ============================================================================
// 4. FindAndLinkFunction
// ============================================================================


// Eden: the runtime first; io_module is a handle into rt.modules, i_function
// the host function value (C: voidptr_t) and i_userdata an int token (C:
// voidptr_t), -1 = NULL (see the header)
def public FindAndLinkFunction(
                               var rt : M3Runtime;
                               io_module : IM3Module;
                               i_moduleName : ccstr_t;
                               i_functionName : ccstr_t;
                               i_signature : ccstr_t;
                               i_function : M3RawCall;
                               i_userdata : int
                               ) : M3Result {
    // C: _try {
    if (rt.modules[io_module].runtime == -1) {   // C: _throwif (m3Err_moduleNotLinked, !io_module->runtime)
        return m3Err_moduleNotLinked
    }

    let wildcardModule = i_moduleName == "*"   // C: strcmp (i_moduleName, "*") == 0

    var result : M3Result = m3Err_functionLookupFailed

    var rawCall = -1   // Eden: the handle of i_function in rt.rawCalls, pushed at the first match (see the header)

    for (i in range(int(rt.modules[io_module].numFunctions))) {
        let f : IM3Function = rt.modules[io_module].functions[i]   // C: const IM3Function f = & io_module->functions [i]

        // C: if (f->import.moduleUtf8 and f->import.fieldUtf8)
        // Eden: the entry is an import (see the header)
        if (u32(i) < rt.modules[io_module].numFuncImports) {
            if (rt.functions[f].import.fieldUtf8 == i_functionName && (wildcardModule || rt.functions[f].import.moduleUtf8 == i_moduleName)) {
                // C: if (i_signature) - Eden: always true (a string is never
                // NULL); "" goes on to C's malformed-signature error
                result = ValidateSignature(rt, f, i_signature)   // C: _ (ValidateSignature (f, i_signature))
                if (result != m3Err_none) {
                    return result
                }
                // Eden: the function value goes into rt.rawCalls once; the
                // code word holds its handle (DESIGN 4.5)
                if (rawCall == -1) {
                    rawCall = length(rt.rawCalls)
                    push(rt.rawCalls, i_function)
                }
                result = CompileRawFunction(rt, io_module, f, rawCall, i_userdata)   // C: _ (CompileRawFunction (io_module, f, i_function, i_userdata))
                if (result != m3Err_none) {
                    return result
                }
            }
        }
    }

    // C: } _catch:
    return result
}


// ============================================================================
// 5. m3_LinkRawFunctionEx / m3_LinkRawFunction
// ============================================================================


// Eden: the runtime first; i_userdata is an int token (C: const void *)
def public m3_LinkRawFunctionEx(
                                var rt : M3Runtime;
                                io_module : IM3Module;
                                i_moduleName : ccstr_t;
                                i_functionName : ccstr_t;
                                i_signature : ccstr_t;
                                i_function : M3RawCall;
                                i_userdata : int
                                ) : M3Result {
    return FindAndLinkFunction(rt, io_module, i_moduleName, i_functionName, i_signature, i_function, i_userdata)
}


// Eden: the runtime first; C's NULL userdata is the token -1
def public m3_LinkRawFunction(
                              var rt : M3Runtime;
                              io_module : IM3Module;
                              i_moduleName : ccstr_t;
                              i_functionName : ccstr_t;
                              i_signature : ccstr_t;
                              i_function : M3RawCall
                              ) : M3Result {
    return FindAndLinkFunction(rt, io_module, i_moduleName, i_functionName, i_signature, i_function, -1)
}
