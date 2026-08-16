options gen2
options indenting = 4

module m3_module shared public

require ./m3_types.das public


/*
    m3_module.c preparatory accessors over the canonical data declarations in
    m3_types.das. No allocation or additional m3_module algorithms are added in
    this merge task.
*/


// ============================================================================
// Module_GetFunction
// ============================================================================


def public Module_GetFunction(var i_module : IM3Module; i_functionIndex : u32) : IM3Function {
    var func : IM3Function = null

    if (i_functionIndex < i_module.numFunctions) {
        unsafe {
            func = addr(i_module.functions[i_functionIndex])
        }
    }

    return func
}


// ============================================================================
// m3_GetModuleName
// ============================================================================


def public m3_GetModuleName(i_module : IM3Module) : cstr_t {
    if (i_module == null || empty(i_module.name)) {
        return ".unnamed"
    }

    return i_module.name
}


// ============================================================================
// m3_SetModuleName
// ============================================================================


def public m3_SetModuleName(var i_module : IM3Module; name : cstr_t) {
    if (i_module != null) {
        i_module.name = name
    }
}


// ============================================================================
// m3_GetModuleRuntime
// ============================================================================


def public m3_GetModuleRuntime(var i_module : IM3Module) : IM3Runtime {
    return i_module != null ? i_module.runtime : null
}
