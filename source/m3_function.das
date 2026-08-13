options gen2
options indenting = 4

module m3_function shared public

require ./m3_config.das public
require ./m3_core.das public


/*
    m3_function.h / m3_function.c + M3ImportInfo from wasm3.h -> m3_function.das

    Pure gen2 Daslang port of Wasm3 function signature metadata and function
    ownership helpers.

    M3FuncType memory adaptation
    ----------------------------
    C ends M3FuncType with the flexible array member `u8 types[]`.  A normal
    Daslang dynamic array would introduce a second allocation and independent
    ownership, which would break the layout expected by later parser/runtime
    stages.  Instead `types[1]` below is only a layout anchor. AllocFuncType
    allocates one raw block beginning at the structure address and extending
    exactly `i_numTypes` bytes from the real address of types[0]. Consumers use
    a raw u8 pointer rooted at that field; no container owns the tail.

    String ownership adaptation
    ---------------------------
    Accepted m3_core maps C `const char *` to Daslang `string`. Such strings are
    context-managed and must not be passed to m3_Free_Impl. Consequently
    FreeImportInfo/Function_Release release their ownership by clearing the
    stored string references. Raw allocations (`constants` and owned `wasm`)
    still use m3_Free_Impl exactly like C. This also makes an alias from
    names[i] to import.fieldUtf8 intrinsically double-free safe: there is only
    one managed string allocation and all references are dropped, never raw-
    freed twice.

    Reserved identifier adaptation
    ------------------------------
    C names the M3Function module pointer `module`. `module` is a reserved
    Daslang keyword and cannot be used as a structure field identifier, so the
    sole spelling adaptation is `_module`. m3_GetFunctionModule preserves the
    public C API and hides this syntax-only difference.

    Inactive C fields
    -----------------
    d_m3EnableCodePageRefCounting is false, so codePageRefs and
    numCodePageRefs are intentionally absent. DEBUG is inactive, so hits/index
    are absent. If those capabilities are enabled later, the corresponding C
    fields must be inserted at their original positions before maxStackSlots.
*/


// ============================================================================
// M3ImportInfo from wasm3.h
// ============================================================================


struct M3ImportInfo {
    moduleUtf8 : cstr_t
    fieldUtf8 : cstr_t
}


typedef public IM3ImportInfo = M3ImportInfo?


// ============================================================================
// M3FuncType from m3_function.h
// ============================================================================


struct M3FuncType {
    next : M3FuncType?

    numRets : u16
    numArgs : u16
    types : u8[1]                 // returns, then args; flexible raw tail anchor
}


typedef public IM3FuncType = M3FuncType?


/*
    Minimal forward-stage module representation. m3_function only stores and
    returns this pointer; no M3Module field is consumed here. The full structure
    belongs to the future m3_module/m3_env layer.
*/
struct M3Module {
}


typedef public IM3Module = M3Module?


// C `pc_t` is only stored by this stage. With code-page refcounting disabled,
// no function in m3_function reads or mutates the compiled code pointer.
typedef private m3_function_code_t = void?
typedef private m3_function_pc_t = m3_function_code_t?


struct M3Function {
    _module : IM3Module            // C field `module`; keyword-safe Daslang spelling

    import : M3ImportInfo

    wasm : bytes_t
    wasmEnd : bytes_t

    names : cstr_t[d_m3MaxDuplicateFunctionImpl]
    export_name : cstr_t          // should be a part of "names"
    numNames : u16

    funcType : IM3FuncType

    compiled : m3_function_pc_t

    // d_m3EnableCodePageRefCounting == false: codePageRefs fields absent.
    // DEBUG inactive: hits/index fields absent.

    maxStackSlots : u16

    numRetSlots : u16
    numRetAndArgSlots : u16

    numLocals : u16               // not including args
    numLocalBytes : u16

    ownsWasmCode : bool

    numConstantBytes : u16
    constants : void?
}


typedef public IM3Function = M3Function?


// Address of the flexible-array anchor. Callers must respect numRets+numArgs.
def private m3_func_type_types(var i_funcType : IM3FuncType) : u8? {
    unsafe {
        return addr(i_funcType.types[0])
    }
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
