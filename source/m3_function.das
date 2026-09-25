options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (function metadata is read
// by the parser, compiler and host API, not per wasm operation, so inlining
// costs startup only) is dropped: the option is untested in the editor
// (DESIGN.md section 1) and the interpreter is the only tier of the Eden port.

module m3_function shared public

require modules/wasm3das/source/m3_types public   // Eden: project-root-relative path (upstream: ./m3_types.das)


/*
    m3_function.h / m3_function.c helpers.

    Canonical M3ImportInfo, M3FuncType, M3Function and M3Module declarations
    live in m3_types.das so m3_function and m3_module can share one type graph.
    Production function bodies below are unchanged from the accepted review.

    Eden: deviations from the upstream port (.upstream/source/m3_function.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md). The sandbox has no
    raw pointers, so a function or a function type is a handle into a runtime
    arena (DESIGN section 4.1, the decisions fixed by m3_types):
      - the require is Eden-project-root relative (DESIGN section 6); m3_types
        stays a public re-export.
      - every function takes the runtime first (`var` when it writes an
        arena, read-only otherwise), then the C parameters in C order; an
        IM3FuncType is a handle into rt.funcTypes, an IM3Function a handle
        into rt.functions, an IM3Module a handle into rt.modules, -1 = NULL.
        FreeImportInfo is the one exception: C passes the M3ImportInfo struct
        itself by pointer and Eden passes it by reference, so it needs no
        runtime.
      - AllocFuncType appends one slot to rt.funcTypes (m3_Realloc_Impl of
        m3_core, never `resize` on an array of structs) and sizes its `types`
        tail to i_numTypes zero bytes (C: one calloc of the header plus the
        flexible tail). The handle is the slot index; allocation cannot fail
        observably (m3_core), so the C null test after m3_Malloc has no
        counterpart and the result is always m3Err_none. The upstream layout
        probe of the flexible-tail offset has no counterpart.
      - AreFuncTypesEqual compares the first numRets + numArgs bytes of the
        two `types` arrays one by one (C: memcmp over that length).
      - the private tail accessor of the upstream port (m3_func_type_types)
        has no counterpart: the tail is the `types` array of the arena slot.
      - Function_Release clears what C frees: the constant table
        (m3_Free_Impl empties the array), every name reference up to
        numNames (strings own their storage, so the C alias test against
        import.fieldUtf8 is not needed: clearing a reference frees nothing),
        export_name (the upstream deviation from C, kept: C leaves the alias
        dangling in a struct being torn down), the import names, and the
        owned wasm range (`wasm` becomes -1, the upstream `wasm = null`; the
        bytes belong to the module's `wasm` array and nothing is freed; the
        ported paths never set ownsWasmCode, only C's extensions do). The
        arenas are not touched: the slot keeps its handle, funcTypeIdx,
        moduleIdx and compiled.
      - Function_FreeCompiledCode is the C body under
        d_m3EnableCodePageRefCounting == false: nothing (as upstream).
      - GetFunctionNames returns a copy of the used names as an array<cstr_t>
        (C: a pointer to the fixed names array, or to import.fieldUtf8) and
        takes o_numNames by reference; the C `!o_numNames` null test has no
        counterpart, the `!i_function` test returns the empty array and
        leaves o_numNames untouched (C: NULL, count untouched).
      - the C test `if (i_function->import.fieldUtf8)` is a NULL test on a
        name; cstr_t is a string here and cannot tell NULL from "" (DESIGN
        section 4.1). The test is spelled once, in the private helper
        m3_func_import_field_is_set, as the upstream port's "the field name
        is not empty". It differs from C only for an import whose field name
        is "" (legal wasm): C reports that one name, Eden reports the
        function's own names, whose names[0] is that same "" (Module_AddFunction
        aliases the import name into names[0], m3_module.c), so
        m3_GetFunctionName agrees with C and only the count of an
        imported-and-exported function with an empty field name differs.
        The porters of m3_env and m3_bind own the explicit representation of
        "imported" (DESIGN section 4.1: a bool next to the string); when it
        exists, the helper is the one line to change.
      - GetFunctionImportModuleName: C's `moduleUtf8 ? moduleUtf8 : ""`
        yields the string itself in both branches here (a NULL name is "");
        the ternary is kept in the upstream form.
      - m3_GetFunctionModule returns the moduleIdx handle (C: the module
        pointer).
      - `type`, the C local of the type getters, is a gen2 keyword and is
        spelled `_type` (as m3_types spells the field).
      - the upstream `options never_inline` is dropped (see the options).
    Everything else (function names, C order, control flow, the sentinels
    c_m3Type_unknown / c_m3Type_none, the bound checks) is unchanged.
*/


// C: `if (i_function->import.fieldUtf8)`, a NULL test on the import field
// name (m3_function.c, GetFunctionNames). Eden: see the header; the one
// place the test is spelled, in the upstream port's form.
def private m3_func_import_field_is_set(i_function : M3Function) : bool {
    return !empty(i_function.import.fieldUtf8)
}


// ============================================================================
// 1. AllocFuncType
// ============================================================================


def public AllocFuncType(
                         var i_runtime : M3Runtime;
                         var o_functionType : IM3FuncType&;
                         i_numTypes : u32
                         ) : M3Result {
    // C: *o_functionType = m3_Malloc ("M3FuncType", sizeof (M3FuncType) + i_numTypes)
    // Eden: a new slot of the func-type arena (its defaults are calloc's
    // zero fill: next = -1, numRets = numArgs = 0) with a `types` tail of
    // i_numTypes zero bytes; the handle is the slot index
    let numFuncTypes = length(i_runtime.funcTypes)
    m3_Realloc_Impl(i_runtime.funcTypes, numFuncTypes + 1, numFuncTypes)
    o_functionType = numFuncTypes
    resize(i_runtime.funcTypes[o_functionType].types, int(i_numTypes))

    // C: return (*o_functionType) ? m3Err_none : m3Err_mallocFailed
    // Eden: allocation cannot fail observably (m3_core), the handle is never null
    return m3Err_none
}


// ============================================================================
// 2. AreFuncTypesEqual
// ============================================================================


def public AreFuncTypesEqual(i_runtime : M3Runtime; i_typeA : IM3FuncType; i_typeB : IM3FuncType) : bool {
    // C callers supply non-null function types; retain that contract rather
    // than inventing null equality semantics absent from the source.
    if (i_runtime.funcTypes[i_typeA].numRets == i_runtime.funcTypes[i_typeB].numRets && i_runtime.funcTypes[i_typeA].numArgs == i_runtime.funcTypes[i_typeB].numArgs) {
        // C: memcmp (i_typeA->types, i_typeB->types, i_typeA->numRets + i_typeA->numArgs) == 0
        // Eden: the first numRets + numArgs bytes of the two tails, one by one
        let numTypes = int(u32(i_runtime.funcTypes[i_typeA].numRets) + u32(i_runtime.funcTypes[i_typeA].numArgs))
        for (i in range(numTypes)) {
            if (i_runtime.funcTypes[i_typeA].types[i] != i_runtime.funcTypes[i_typeB].types[i]) {
                return false
            }
        }
        return true
    }

    return false
}


// ============================================================================
// 3. GetFuncTypeNumParams
// ============================================================================


def public GetFuncTypeNumParams(i_runtime : M3Runtime; i_funcType : IM3FuncType) : u16 {
    return i_funcType != -1 ? i_runtime.funcTypes[i_funcType].numArgs : u16(0)
}


// ============================================================================
// 4. GetFuncTypeParamType
// ============================================================================


def public GetFuncTypeParamType(i_runtime : M3Runtime; i_funcType : IM3FuncType; i_index : u16) : u8 {
    var _type = u8(M3ValueType.c_m3Type_unknown)   // C local `type`; a gen2 keyword

    if (i_funcType != -1) {
        if (u32(i_index) < u32(i_runtime.funcTypes[i_funcType].numArgs)) {
            _type = i_runtime.funcTypes[i_funcType].types[int(u32(i_runtime.funcTypes[i_funcType].numRets) + u32(i_index))]
        }
    }

    return _type
}


// ============================================================================
// 5. GetFuncTypeNumResults
// ============================================================================


def public GetFuncTypeNumResults(i_runtime : M3Runtime; i_funcType : IM3FuncType) : u16 {
    return i_funcType != -1 ? i_runtime.funcTypes[i_funcType].numRets : u16(0)
}


// ============================================================================
// 6. GetFuncTypeResultType
// ============================================================================


def public GetFuncTypeResultType(i_runtime : M3Runtime; i_funcType : IM3FuncType; i_index : u16) : u8 {
    var _type = u8(M3ValueType.c_m3Type_unknown)   // C local `type`; a gen2 keyword

    if (i_funcType != -1) {
        if (u32(i_index) < u32(i_runtime.funcTypes[i_funcType].numRets)) {
            _type = i_runtime.funcTypes[i_funcType].types[int(i_index)]
        }
    }

    return _type
}


// ============================================================================
// 7. FreeImportInfo
// ============================================================================


// Eden: no runtime parameter; the struct is passed by reference (C: by pointer)
def public FreeImportInfo(var i_info : M3ImportInfo&) {
    // C m3_Free also writes NULL back to each pointer. In the accepted core
    // string representation, empty string is the NULL-equivalent sentinel.
    i_info.moduleUtf8 = ""
    i_info.fieldUtf8 = ""
}


// ============================================================================
// 8. Function_Release
// ============================================================================


def public Function_Release(var i_runtime : M3Runtime; i_function : IM3Function) {
    // C: m3_Free (i_function->constants); Eden: the array is emptied in place
    m3_Free_Impl(i_runtime.functions[i_function].constants)

    // Managed strings cannot be raw-freed. Clear all owned-name references.
    // C skips a name that aliases import.fieldUtf8 to avoid a double free;
    // clearing a string reference frees nothing, so every name is cleared.
    for (i in range(int(i_runtime.functions[i_function].numNames))) {
        i_runtime.functions[i_function].names[i] = ""
    }
    // C export_name is expected to alias one of names. C can leave that alias
    // dangling because the containing function is being torn down; a managed
    // Daslang string reference would keep the allocation alive, so drop it.
    i_runtime.functions[i_function].export_name = ""

    FreeImportInfo(i_runtime.functions[i_function].import)

    if (i_runtime.functions[i_function].ownsWasmCode) {
        // C: m3_Free (i_function->wasm); Eden: the bytes are the module's
        // `wasm` array and stay there; the range is dropped (upstream: wasm = null)
        i_runtime.functions[i_function].wasm = -1
    }

    // C: Function_FreeCompiledCode (func) is commented out.
    // d_m3EnableCodePageRefCounting == false: the codePageRefs block is absent.
}


// ============================================================================
// 9. Function_FreeCompiledCode
// ============================================================================


def public Function_FreeCompiledCode(var i_runtime : M3Runtime; i_function : IM3Function) {
    // d_m3EnableCodePageRefCounting == false. The C function body is empty in
    // this configuration, so compiled and every other field remain unchanged.
    pass
}


// ============================================================================
// 10. m3_GetFunctionName
// ============================================================================


def public m3_GetFunctionName(i_runtime : M3Runtime; i_function : IM3Function) : cstr_t {
    var numNames : u16 = u16(0)
    var inscope names <- GetFunctionNames(i_runtime, i_function, numNames)   // Eden: a copy of the names, freed at scope exit

    if (u32(numNames) > 0u) {
        return names[0]
    } else {
        return "<unnamed>"
    }
}


// ============================================================================
// 11. m3_GetFunctionModule
// ============================================================================


def public m3_GetFunctionModule(i_runtime : M3Runtime; i_function : IM3Function) : IM3Module {
    return i_function != -1 ? i_runtime.functions[i_function].moduleIdx : -1
}


// ============================================================================
// 12. GetFunctionNames
// ============================================================================


// Eden: returns a copy of the used names (C: a pointer into the function);
// o_numNames is a reference, so C's `!o_numNames` test has no counterpart
def public GetFunctionNames(i_runtime : M3Runtime; i_function : IM3Function; var o_numNames : u16&) : array<cstr_t> {
    var names : array<cstr_t>

    // C: if (!i_function || !o_numNames) return NULL; the count stays untouched
    if (i_function == -1) {
        return <- names
    }

    if (m3_func_import_field_is_set(i_runtime.functions[i_function])) {   // C: if (i_function->import.fieldUtf8), see the header
        o_numNames = u16(1)
        push(names, i_runtime.functions[i_function].import.fieldUtf8)   // C: return &i_function->import.fieldUtf8
    } else {
        o_numNames = i_runtime.functions[i_function].numNames
        for (i in range(int(o_numNames))) {   // C: return i_function->names, numNames of them used
            push(names, i_runtime.functions[i_function].names[i])
        }
    }

    return <- names
}


// ============================================================================
// 13. GetFunctionImportModuleName
// ============================================================================


def public GetFunctionImportModuleName(i_runtime : M3Runtime; i_function : IM3Function) : cstr_t {
    // Like C, i_function itself is required to be non-null here.
    // C: (moduleUtf8) ? moduleUtf8 : ""; Eden: a NULL name is "", both branches are the string itself
    return !empty(i_runtime.functions[i_function].import.moduleUtf8) ? i_runtime.functions[i_function].import.moduleUtf8 : ""
}


// ============================================================================
// 14. GetFunctionNumArgs
// ============================================================================


def public GetFunctionNumArgs(i_runtime : M3Runtime; i_function : IM3Function) : u16 {
    var numArgs : u16 = u16(0)

    if (i_function != -1) {
        if (i_runtime.functions[i_function].funcTypeIdx != -1) {
            numArgs = i_runtime.funcTypes[i_runtime.functions[i_function].funcTypeIdx].numArgs
        }
    }

    return numArgs
}


// ============================================================================
// 15. GetFunctionArgType
// ============================================================================


def public GetFunctionArgType(i_runtime : M3Runtime; i_function : IM3Function; i_index : u32) : u8 {
    var _type = u8(M3ValueType.c_m3Type_none)   // C local `type`; a gen2 keyword

    if (i_index < u32(GetFunctionNumArgs(i_runtime, i_function))) {
        let funcType = i_runtime.functions[i_function].funcTypeIdx
        let numReturns : u32 = u32(i_runtime.funcTypes[funcType].numRets)

        _type = i_runtime.funcTypes[funcType].types[int(numReturns + i_index)]
    }

    return _type
}


// ============================================================================
// 16. GetFunctionNumReturns
// ============================================================================


def public GetFunctionNumReturns(i_runtime : M3Runtime; i_function : IM3Function) : u16 {
    var numReturns : u16 = u16(0)

    if (i_function != -1) {
        if (i_runtime.functions[i_function].funcTypeIdx != -1) {
            numReturns = i_runtime.funcTypes[i_runtime.functions[i_function].funcTypeIdx].numRets
        }
    }

    return numReturns
}


// ============================================================================
// 17. GetFunctionReturnType
// ============================================================================


def public GetFunctionReturnType(i_runtime : M3Runtime; i_function : IM3Function; i_index : u16) : u8 {
    return i_function != -1 ? GetFuncTypeResultType(i_runtime, i_runtime.functions[i_function].funcTypeIdx, i_index) : u8(M3ValueType.c_m3Type_unknown)
}


// ============================================================================
// 18. GetFunctionNumArgsAndLocals
// ============================================================================


def public GetFunctionNumArgsAndLocals(i_runtime : M3Runtime; i_function : IM3Function) : u32 {
    if (i_function != -1) {
        return u32(i_runtime.functions[i_function].numLocals) + u32(GetFunctionNumArgs(i_runtime, i_function))
    } else {
        return 0u
    }
}
