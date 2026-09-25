options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (module accessors and
// release run outside the execution path, so inlining costs startup only) is
// dropped: the option is untested in the editor (DESIGN.md section 1) and the
// interpreter is the only tier of the Eden port.

module m3_module shared public

require modules/wasm3das/source/m3_core            // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types public    // Eden: project-root-relative path (upstream: ./m3_types.das)
require modules/wasm3das/source/m3_function        // Eden: project-root-relative path (upstream: ./m3_function.das)

// Conservative Gen2 port of m3_module.c.

/*
    m3_module.c: the module-level helpers of the parser and the public
    module accessors of wasm3.h. Function names, C order, control flow, the
    error string and the bound checks are C's.

    Eden: deviations from the upstream port (.upstream/source/m3_module.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md). The sandbox has no
    raw pointers, so a module, a function, a function type and a global are
    handles into the arenas of a runtime (DESIGN section 4.1, the decisions
    fixed by m3_types):
      - the requires are Eden-project-root relative (DESIGN section 6);
        m3_types stays a public re-export.
      - every function takes the runtime first (`var` when it writes an
        arena or a module, read-only otherwise), then the C parameters in C
        order; an IM3Module is a handle into rt.modules, an IM3Function into
        rt.functions, an IM3FuncType into rt.funcTypes, an IM3Global into
        rt.globals, -1 = NULL.
      - a module keeps `functions : array<int>` and `globals : array<int>`
        of handles into rt.functions / rt.globals in C order, and
        `numFunctions == length(module.functions)`, `numGlobals ==
        length(module.globals)` hold after every call here.
      - Module_FreeFunctions releases each function of the module through
        Function_Release; the arena slots stay (a handle is never reused).
      - m3_FreeModule frees what C frees, in C order: the functions, the
        handle arrays (functions, funcTypes), the data segments, table0, the
        globals' names and import info (and, Eden, their initExpr index into
        the binary that goes away below), the export names and the memory
        import. C's final `m3_Free (i_module)` releases the struct itself;
        here the slot stays in rt.modules in a released state: the module's
        copy of the binary (`wasm`, which C never owned) and its name are
        freed, the indices into the binary are dropped (-1), the counts of
        the freed arrays are zeroed and `runtime` is -1 again. Handles into
        rt.modules are never reused, so a released slot is never mistaken
        for a live module; `startFunction` returns to -1 (m3_types).
      - Module_AddGlobal: C's m3_ReallocArray of the module's global array
        becomes one new slot of rt.globals (m3_Realloc_Impl of m3_core, never
        `resize` on an array of structs) whose handle is pushed into
        module.globals; allocation cannot fail observably (m3_core), so the
        `_throwifnull` has no counterpart and the result is always
        m3Err_none. o_global is a reference and cannot be NULL, so C's
        `if (o_global)` has no counterpart: the handle is always written.
      - Module_PreallocFunctions reserves the module's handle array to
        i_totalFunctions (C: m3_ReallocArray of the M3Function array to
        allFunctions) and sets allFunctions; the arena slots themselves are
        appended by Module_AddFunction, so the reserve is a capacity hint,
        as C's realloc ahead of numFunctions is. Cannot fail.
      - Module_AddFunction: C tests `i_importInfo` (a pointer that "can be
        null") to tell an import from a local function. M3ImportInfo is
        passed by value here and cstr_t cannot tell NULL from "" (DESIGN
        section 4.1: the spec suite's names.wast has empty names), so the
        NULL test is an explicit `i_isImport : bool` after the C parameters,
        the same signal C's Module_AddGlobal takes as i_isImported. The
        parser passes `false` with `M3ImportInfo()` for C's NULL and `true`
        with the import for C's `&import`. The zeroed slot C's realloc
        provides at functions[index] is a new slot of rt.functions whose
        handle is pushed into module.functions, before the type-index check
        as in C (an out-of-range index leaves the counted, typeless slot
        behind, as C leaves its zeroed one); the slot's owner (moduleIdx)
        stays -1 here exactly as C leaves func->module NULL: ParseSection_Code
        (m3_parse.c) sets it for a local function with a body, and
        CompileRawFunction (m3_compile.c, on the m3_bind link path) for an
        import - Compile_Call branches on that NULL to report
        "function import missing" for an unlinked import.
        The func type is the handle module.funcTypes[i_typeIndex] (C: the
        element VALUE of the pointer array). C's DEBUG-only `func->index`
        is absent (as upstream).
      - Module_GenerateNames is C's DEBUG-only body, kept as upstream
        (m3_env.c calls it under DEBUG); a global's `name == NULL` test is
        `empty(name)` (the NULL-vs-"" caveat: a global whose name is ""
        would be renamed here, C would keep the empty name).
      - Module_GetFunction returns the handle module.functions[i] (C: the
        address of the element) or -1 past numFunctions.
      - m3_GetModuleName: C tests `!i_module->name` (NULL); `empty(name)`
        here also maps a module named "" to ".unnamed" (the caveat above).
      - m3_GetModuleRuntime returns the module's IM3Runtime handle (0 = the
        owning runtime once m3_LoadModule links it, -1 = NULL).
      - the upstream `options never_inline` is dropped (see the options).
*/


// ============================================================================
// 1. Module_FreeFunctions
// ============================================================================


def public Module_FreeFunctions(var i_runtime : M3Runtime; i_module : IM3Module) {
    for (i in range(int(i_runtime.modules[i_module].numFunctions))) {
        // C: IM3Function func = & i_module->functions [i]; Eden: the handle
        let func : IM3Function = i_runtime.modules[i_module].functions[i]
        Function_Release(i_runtime, func)
    }
}


// ============================================================================
// 2. m3_FreeModule
// ============================================================================


def public m3_FreeModule(var i_runtime : M3Runtime; i_module : IM3Module) {
    if (i_module != -1) {
        // compiled out under the active configuration: m3log module summary

        Module_FreeFunctions(i_runtime, i_module)

        // C: m3_Free (i_module->functions); Eden: the handle array, the arena slots stay
        m3_Free_Impl(i_runtime.modules[i_module].functions)
        //m3_Free (i_module->imports);
        m3_Free_Impl(i_runtime.modules[i_module].funcTypes)
        m3_Free_Impl(i_runtime.modules[i_module].dataSegments)
        m3_Free_Impl(i_runtime.modules[i_module].table0)

        for (i in range(int(i_runtime.modules[i_module].numGlobals))) {
            let globalIdx : IM3Global = i_runtime.modules[i_module].globals[i]
            // C: m3_Free (i_module->globals[i].name); strings own their storage
            i_runtime.globals[globalIdx].name = ""
            FreeImportInfo(i_runtime.globals[globalIdx].import)
            // Eden: the init expression is an index into the module's binary,
            // which goes away below; C's pointer into the caller's bytes stayed
            i_runtime.globals[globalIdx].initExpr = -1
        }
        // C: m3_Free (i_module->globals); Eden: the handle array, the arena slots stay
        m3_Free_Impl(i_runtime.modules[i_module].globals)
        i_runtime.modules[i_module].memoryExportName = ""
        i_runtime.modules[i_module].table0ExportName = ""

        FreeImportInfo(i_runtime.modules[i_module].memoryImport)

        // C: m3_Free (i_module) - the struct itself. Eden: the slot stays in
        // rt.modules (handles are never reused) in a released state, see the
        // header: the module's copy of the binary and its name are freed, the
        // indices into the binary dropped, the counts of the freed arrays
        // zeroed, the runtime link cleared.
        m3_Free_Impl(i_runtime.modules[i_module].wasm)
        i_runtime.modules[i_module].wasmStart = -1
        i_runtime.modules[i_module].wasmEnd = -1
        i_runtime.modules[i_module].name = ""
        i_runtime.modules[i_module].numFuncTypes = 0u
        i_runtime.modules[i_module].numFuncImports = 0u
        i_runtime.modules[i_module].numFunctions = 0u
        i_runtime.modules[i_module].allFunctions = 0u
        i_runtime.modules[i_module].startFunction = -1
        i_runtime.modules[i_module].numDataSegments = 0u
        i_runtime.modules[i_module].numGlobals = 0u
        i_runtime.modules[i_module].numElementSegments = 0u
        i_runtime.modules[i_module].elementSection = -1
        i_runtime.modules[i_module].elementSectionEnd = -1
        i_runtime.modules[i_module].table0Size = 0u
        i_runtime.modules[i_module].memoryInfo = M3MemoryInfo()
        i_runtime.modules[i_module].memoryImported = false
        i_runtime.modules[i_module].runtime = -1
    }
}


// ============================================================================
// 3. Module_AddGlobal
// ============================================================================


def public Module_AddGlobal(
                            var i_runtime : M3Runtime;
                            io_module : IM3Module;
                            var o_global : IM3Global&;
                            i_type : u8;
                            i_mutable : bool;
                            i_isImported : bool
                            ) : M3Result {
    let index = i_runtime.modules[io_module].numGlobals
    i_runtime.modules[io_module].numGlobals++

    // C: io_module->globals = m3_ReallocArray (M3Global, io_module->globals, io_module->numGlobals, index)
    // Eden: one new slot of the global arena (its defaults are calloc's zero
    // fill), its handle pushed into the module's handle array
    let numGlobals = length(i_runtime.globals)
    m3_Realloc_Impl(i_runtime.globals, numGlobals + 1, numGlobals)
    push(i_runtime.modules[io_module].globals, numGlobals)
    // C: _throwifnull (io_module->globals); Eden: allocation cannot fail observably (m3_core)
    let global : IM3Global = numGlobals   // C: M3Global * global = & io_module->globals [index]

    i_runtime.globals[global]._type = i_type
    i_runtime.globals[global].imported = i_isImported
    i_runtime.globals[global].isMutable = i_mutable

    // C: if (o_global) * o_global = global; Eden: a reference cannot be NULL
    o_global = global

    return m3Err_none
}


// ============================================================================
// 4. Module_PreallocFunctions
// ============================================================================


def public Module_PreallocFunctions(var i_runtime : M3Runtime; io_module : IM3Module; i_totalFunctions : u32) : M3Result {
    if (i_totalFunctions > i_runtime.modules[io_module].allFunctions) {
        // C: io_module->functions = m3_ReallocArray (M3Function, io_module->functions, i_totalFunctions, io_module->allFunctions)
        // Eden: the handle array grows its capacity; the arena slots are
        // appended by Module_AddFunction, one per counted function
        reserve(i_runtime.modules[io_module].functions, int(i_totalFunctions))
        i_runtime.modules[io_module].allFunctions = i_totalFunctions

        // C: _throwifnull (io_module->functions); Eden: allocation cannot fail observably (m3_core)
    }

    return m3Err_none
}


// ============================================================================
// 5. Module_AddFunction
// ============================================================================


// Eden: i_isImport is C's `i_importInfo != NULL` (see the header); the parser
// passes false with M3ImportInfo() for C's NULL, true with the import otherwise
def public Module_AddFunction(
                              var i_runtime : M3Runtime;
                              io_module : IM3Module;
                              i_typeIndex : u32;
                              i_importInfo : M3ImportInfo;
                              i_isImport : bool
                              ) : M3Result {
    let index = i_runtime.modules[io_module].numFunctions
    i_runtime.modules[io_module].numFunctions++

    let result = Module_PreallocFunctions(i_runtime, io_module, i_runtime.modules[io_module].numFunctions)
    if (result != m3Err_none) {
        return result
    }

    // Eden: the zeroed slot C's realloc provides at functions[index] is one
    // new slot of the function arena, its handle pushed into the module's
    // handle array (numFunctions == length(functions) holds again); moduleIdx
    // stays -1 as C leaves func->module NULL (set later by ParseSection_Code
    // for local functions and by CompileRawFunction for linked imports)
    let numFunctions = length(i_runtime.functions)
    m3_Realloc_Impl(i_runtime.functions, numFunctions + 1, numFunctions)
    push(i_runtime.modules[io_module].functions, numFunctions)

    if (i_typeIndex >= i_runtime.modules[io_module].numFuncTypes) {
        return "type sig index out of bounds"
    }

    // C: IM3FuncType ft = io_module->funcTypes [i_typeIndex] - funcTypes is an
    // ARRAY OF POINTERS (IM3FuncType *), so the element VALUE is the func type;
    // Eden: the element is the handle into rt.funcTypes
    let ft : IM3FuncType = i_runtime.modules[io_module].funcTypes[int(i_typeIndex)]
    let func : IM3Function = Module_GetFunction(i_runtime, io_module, index)
    i_runtime.functions[func].funcTypeIdx = ft

    // DEBUG inactive: func->index is absent.

    if (i_isImport && i_runtime.functions[func].numNames == u16(0)) {   // C: if (i_importInfo and func->numNames == 0)
        i_runtime.functions[func].import = i_importInfo   // C: func->import = * i_importInfo
        i_runtime.functions[func].names[0] = i_importInfo.fieldUtf8   // C: func->names[0] = i_importInfo->fieldUtf8
        i_runtime.functions[func].numNames = u16(1)
    }

    // compiled out under the active configuration: m3log added function

    return m3Err_none
}


// ============================================================================
// 6. Module_GenerateNames
// ============================================================================


// C: #ifdef DEBUG; kept as the upstream port keeps it
def public Module_GenerateNames(var i_runtime : M3Runtime; i_module : IM3Module) {
    for (i in range(int(i_runtime.modules[i_module].numFunctions))) {
        let func : IM3Function = i_runtime.modules[i_module].functions[i]   // C: & i_module->functions [i]

        if (i_runtime.functions[func].numNames == u16(0)) {
            // C: snprintf (buff, 16, "$func%d", i)
            let buff = "$func{i}"
            i_runtime.functions[func].names[0] = buff
            i_runtime.functions[func].numNames = u16(1)
        }
    }
    for (i in range(int(i_runtime.modules[i_module].numGlobals))) {
        let global : IM3Global = i_runtime.modules[i_module].globals[i]   // C: & i_module->globals [i]

        // C: if (global->name == NULL); Eden: a NULL name is "" (see the header)
        if (empty(i_runtime.globals[global].name)) {
            // C: snprintf (buff, 16, "$global%d", i)
            i_runtime.globals[global].name = "$global{i}"
        }
    }
}


// ============================================================================
// 7. Module_GetFunction
// ============================================================================


def public Module_GetFunction(i_runtime : M3Runtime; i_module : IM3Module; i_functionIndex : u32) : IM3Function {
    var func : IM3Function = -1

    if (i_functionIndex < i_runtime.modules[i_module].numFunctions) {
        func = i_runtime.modules[i_module].functions[int(i_functionIndex)]   // C: & i_module->functions [i_functionIndex]
        //func->module = i_module;
    }

    return func
}


// ============================================================================
// 8. m3_GetModuleName
// ============================================================================


def public m3_GetModuleName(i_runtime : M3Runtime; i_module : IM3Module) : string {
    // C: if (!i_module || !i_module->name); Eden: a NULL name is "" (see the header)
    if (i_module == -1 || empty(i_runtime.modules[i_module].name)) {
        return ".unnamed"
    }

    return i_runtime.modules[i_module].name
}


// ============================================================================
// 9. m3_SetModuleName
// ============================================================================


def public m3_SetModuleName(var i_runtime : M3Runtime; i_module : IM3Module; name : string) {
    if (i_module != -1) {
        i_runtime.modules[i_module].name = name
    }
}


// ============================================================================
// 10. m3_GetModuleRuntime
// ============================================================================


def public m3_GetModuleRuntime(i_runtime : M3Runtime; i_module : IM3Module) : IM3Runtime {
    // C: return i_module ? i_module->runtime : NULL
    if (i_module != -1) {
        return i_runtime.modules[i_module].runtime
    }
    return -1
}
