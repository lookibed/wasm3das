options gen2
options indenting = 4

module m3_function shared public

require ./m3_types.das public


/*
    m3_function.h / m3_function.c helpers.

    Canonical M3ImportInfo, M3FuncType, M3Function and M3Module declarations
    live in m3_types.das so m3_function and m3_module can share one type graph.
    Production function bodies below are unchanged from the accepted review.
*/


// Address of the flexible-array anchor. Callers must respect numRets+numArgs.
def private m3_func_type_types(var i_funcType : IM3FuncType) : u8? {
    return unsafe(addr(i_funcType.types[0]))
}


// ============================================================================
// 1. AllocFuncType
// ============================================================================


def public AllocFuncType(var o_functionType : IM3FuncType&; i_numTypes : u32) : M3Result {
    o_functionType = null

    // Compute the actual field offset from a real structure instance rather
    // than assuming trailing padding. This is the beginning of C's types[].
    var layoutProbe : M3FuncType
    let typesOffset = (
        intptr(unsafe(addr(layoutProbe.types[0]))) - intptr(unsafe(addr(layoutProbe)))
    )

    let allocationSize = typesOffset + u64(i_numTypes)
    if (allocationSize < typesOffset) {
        return m3Err_mallocFailed
    }

    let memory = m3_Malloc_Impl(allocationSize)
    if (memory == null) {
        return m3Err_mallocFailed
    }

    o_functionType = unsafe(reinterpret<IM3FuncType>(memory))
    return m3Err_none
}


// ============================================================================
// 2. AreFuncTypesEqual
// ============================================================================


def public AreFuncTypesEqual(var i_typeA : IM3FuncType; var i_typeB : IM3FuncType) : bool {
    // C callers supply non-null function types; retain that contract rather
    // than inventing null equality semantics absent from the source.
    if (i_typeA.numRets != i_typeB.numRets || i_typeA.numArgs != i_typeB.numArgs) {
        return false
    }

    let numTypes = u32(i_typeA.numRets) + u32(i_typeA.numArgs)
    unsafe {
        let typesA = m3_func_type_types(i_typeA)
        let typesB = m3_func_type_types(i_typeB)

        for (i in urange(numTypes)) {
            if (typesA[i] != typesB[i]) {
                return false
            }
        }
    }
    return true
}


// ============================================================================
// 3. GetFuncTypeNumParams
// ============================================================================


def public GetFuncTypeNumParams(i_funcType : IM3FuncType) : u16 {
    return i_funcType != null ? i_funcType.numArgs : u16(0)
}


// ============================================================================
// 4. GetFuncTypeParamType
// ============================================================================


def public GetFuncTypeParamType(var i_funcType : IM3FuncType; i_index : u16) : u8 {
    var result = u8(M3ValueType.c_m3Type_unknown)

    if (i_funcType != null && u32(i_index) < u32(i_funcType.numArgs)) {
        let types = m3_func_type_types(i_funcType)
        result = unsafe(types[u32(i_funcType.numRets) + u32(i_index)])
    }

    return result
}


// ============================================================================
// 5. GetFuncTypeNumResults
// ============================================================================


def public GetFuncTypeNumResults(i_funcType : IM3FuncType) : u16 {
    return i_funcType != null ? i_funcType.numRets : u16(0)
}


// ============================================================================
// 6. GetFuncTypeResultType
// ============================================================================


def public GetFuncTypeResultType(var i_funcType : IM3FuncType; i_index : u16) : u8 {
    var result = u8(M3ValueType.c_m3Type_unknown)

    if (i_funcType != null && u32(i_index) < u32(i_funcType.numRets)) {
        let types = m3_func_type_types(i_funcType)
        result = unsafe(types[u32(i_index)])
    }

    return result
}


// ============================================================================
// 7. FreeImportInfo
// ============================================================================


def public FreeImportInfo(var i_info : M3ImportInfo&) {
    // C m3_Free also writes NULL back to each pointer. In the accepted core
    // string representation, empty string is the NULL-equivalent sentinel.
    i_info.moduleUtf8 = ""
    i_info.fieldUtf8 = ""
}


// ============================================================================
// 8. Function_Release
// ============================================================================


def public Function_Release(var i_function : IM3Function) {
    m3_Free_Impl(i_function.constants)
    i_function.constants = null

    // Managed strings cannot be raw-freed. Clear all owned-name references.
    // Doing this as references, rather than allocations, preserves the C alias
    // rule when a name aliases import.fieldUtf8 and prevents double free.
    for (i in range(int(i_function.numNames))) {
        i_function.names[i] = ""
    }
    // C export_name is expected to alias one of names. C can leave that alias
    // dangling because the containing function is being torn down; a managed
    // Daslang string reference would keep the allocation alive, so drop it.
    i_function.export_name = ""

    FreeImportInfo(i_function.import)

    if (i_function.ownsWasmCode) {
        m3_Free_Impl(unsafe(reinterpret<void?>(i_function.wasm)))
        i_function.wasm = null
    }
}


// ============================================================================
// 9. Function_FreeCompiledCode
// ============================================================================


[unused_argument(i_function)]
def public Function_FreeCompiledCode(var i_function : IM3Function) {
    // d_m3EnableCodePageRefCounting == false. The C function body is empty in
    // this configuration, so compiled and every other field remain unchanged.
}


// ============================================================================
// 10. m3_GetFunctionName
// ============================================================================


def public m3_GetFunctionName(var i_function : IM3Function) : cstr_t {
    var numNames : u16 = 0
    let names = GetFunctionNames(i_function, unsafe(addr(numNames)))

    if (u32(numNames) > 0u && names != null) {
        return *names
    }
    return "<unnamed>"
}


// ============================================================================
// 11. m3_GetFunctionModule
// ============================================================================


def public m3_GetFunctionModule(var i_function : IM3Function) : IM3Module {
    return i_function != null ? i_function._module : null
}


// ============================================================================
// 12. GetFunctionNames
// ============================================================================


def public GetFunctionNames(var i_function : IM3Function; var o_numNames : u16?) : cstr_t? {
    if (i_function == null || o_numNames == null) {
        return null
    }

    unsafe {
        if (!empty(i_function.import.fieldUtf8)) {
            *o_numNames = u16(1)
            return addr(i_function.import.fieldUtf8)
        }

        *o_numNames = i_function.numNames
        return addr(i_function.names[0])
    }
}


// ============================================================================
// 13. GetFunctionImportModuleName
// ============================================================================


def public GetFunctionImportModuleName(var i_function : IM3Function) : cstr_t {
    // Like C, i_function itself is required to be non-null here.
    return !empty(i_function.import.moduleUtf8) ? i_function.import.moduleUtf8 : ""
}


// ============================================================================
// 14. GetFunctionNumArgs
// ============================================================================


def public GetFunctionNumArgs(i_function : IM3Function) : u16 {
    if (i_function != null && i_function.funcType != null) {
        return i_function.funcType.numArgs
    }
    return u16(0)
}


// ============================================================================
// 15. GetFunctionArgType
// ============================================================================


def public GetFunctionArgType(var i_function : IM3Function; i_index : u32) : u8 {
    var result = u8(M3ValueType.c_m3Type_none)

    if (i_index < u32(GetFunctionNumArgs(i_function))) {
        let types = m3_func_type_types(i_function.funcType)
        result = unsafe(types[u32(i_function.funcType.numRets) + i_index])
    }

    return result
}


// ============================================================================
// 16. GetFunctionNumReturns
// ============================================================================


def public GetFunctionNumReturns(i_function : IM3Function) : u16 {
    if (i_function != null && i_function.funcType != null) {
        return i_function.funcType.numRets
    }
    return u16(0)
}


// ============================================================================
// 17. GetFunctionReturnType
// ============================================================================


def public GetFunctionReturnType(var i_function : IM3Function; i_index : u16) : u8 {
    if (i_function != null) {
        return GetFuncTypeResultType(i_function.funcType, i_index)
    }
    return u8(M3ValueType.c_m3Type_unknown)
}


// ============================================================================
// 18. GetFunctionNumArgsAndLocals
// ============================================================================


def public GetFunctionNumArgsAndLocals(i_function : IM3Function) : u32 {
    if (i_function != null) {
        return u32(i_function.numLocals) + u32(GetFunctionNumArgs(i_function))
    }
    return 0u
}
