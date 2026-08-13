options gen2
options indenting = 4

module m3_module shared public

require ./m3_config.das public
require ./m3_core.das public


/*
    m3_env.h (M3Global/M3Module) + simple accessors from m3_module.c
    ----------------------------------------------------------------

    This is the preparatory standalone data layer for m3_module. It does NOT
    import m3_function.das yet: that module currently owns a temporary empty
    M3Module used by Egor's accepted m3_function/m3_bind work. The two module
    representations will be unified only after that review is complete.

    Forward/adaptation types
    ------------------------
    M3Module stores pointers to M3Runtime, M3Environment, M3FuncType and a
    contiguous M3Function array, but the four accessors implemented at this
    stage only dereference M3Module itself and index the function array. Small
    opaque structs below therefore preserve pointer identity and pointer-array
    shape without copying the full foreign structures into this module.

    M3FunctionForward is intentionally one byte only. It is a temporary stride
    for this isolated module test, not a second implementation of M3Function.
    During the later merge it must be replaced by the canonical M3Function from
    m3_function.das; M3Module field order and Module_GetFunction logic stay the
    same. No ownership is attached to any forward pointer.

    C anonymous-union adaptation in M3Global
    ----------------------------------------
    Gen2 Daslang has no untagged C union declaration. The active union members
    are retained by name in M3GlobalValue and stored as a nested value object.
    This preparatory layer does not perform C interop or raw ABI casts, so the
    widened pure-Daslang storage does not change ownership. Future global-value
    access must select the member indicated by M3Global._type. d_m3HasFloat is
    true in the accepted configuration, therefore f64Value and f32Value are
    present. If float support is disabled later, those two members are removed
    to match the C #if d_m3HasFloat branch.

    String/null adaptation
    ----------------------
    Accepted m3_core maps C `const char *` to Daslang string and uses empty
    string as the null-equivalent sentinel. Consequently a module whose `name`
    is empty is treated like C name == NULL by m3_GetModuleName.

    Inactive/commented C fields
    ---------------------------
    - M3Module.importedGlobals is commented out in m3_env.h: absent here.
    - M3Module.hasWasmCodeCopy is commented out in m3_env.h: absent here.
    There are no active #if-controlled fields inside M3Module itself in the
    supplied header. M3Global's float members ARE active because d_m3HasFloat
    is true. No M3Runtime conditional fields are copied into this preparatory
    module; runtime is an opaque forward pointer only.
*/


// ============================================================================
// Forward/adaptation pointer types used directly by M3Module
// ============================================================================


struct M3RuntimeForward {
    _opaque : u8
}

typedef public IM3Runtime = M3RuntimeForward?


struct M3EnvironmentForward {
    _opaque : u8
}

typedef public IM3Environment = M3EnvironmentForward?


struct M3FuncTypeForward {
    _opaque : u8
}

typedef public IM3FuncType = M3FuncTypeForward?


struct M3FunctionForward {
    _opaque : u8
}

typedef public IM3Function = M3FunctionForward?


// ============================================================================
// Public value types used by M3Global/M3Module
// ============================================================================


struct M3ImportInfo {
    moduleUtf8 : cstr_t
    fieldUtf8 : cstr_t
}

typedef public IM3ImportInfo = M3ImportInfo?


struct M3MemoryInfo {
    initPages : u32
    maxPages : u32
    pageSize : u32
}


struct M3DataSegment {
    initExpr : cbytes_t
    data : cbytes_t

    initExprSize : u32
    memoryRegion : u32
    size : u32
}


// Pure-Daslang replacement for C's anonymous value union; see module comment.
struct M3GlobalValue {
    i32Value : i32
    i64Value : i64
    f64Value : f64              // active because d_m3HasFloat == true
    f32Value : f32              // active because d_m3HasFloat == true
}


// ============================================================================
// M3Global from m3_env.h
// ============================================================================


struct M3Global {
    import : M3ImportInfo

    value : M3GlobalValue

    name : cstr_t
    initExpr : bytes_t           // wasm code
    initExprSize : u32
    _type : u8                   // C field `type`; `type` is a gen2 keyword
    imported : bool
    isMutable : bool
}


typedef public IM3Global = M3Global?


// ============================================================================
// Full active M3Module field sequence from m3_env.h
// ============================================================================


struct M3Module {
    runtime : IM3Runtime
    environment : IM3Environment

    wasmStart : bytes_t
    wasmEnd : bytes_t

    name : cstr_t

    numFuncTypes : u32
    funcTypes : IM3FuncType?         // C: IM3FuncType *

    numFuncImports : u32
    numFunctions : u32
    allFunctions : u32
    functions : M3FunctionForward?   // C: M3Function *; temporary forward stride

    startFunction : i32

    numDataSegments : u32
    dataSegments : M3DataSegment?

    // C source has a commented-out `importedGlobals`; intentionally absent.
    numGlobals : u32
    globals : M3Global?

    numElementSegments : u32
    elementSection : bytes_t
    elementSectionEnd : bytes_t

    table0 : IM3Function?            // C: IM3Function *
    table0Size : u32
    table0ExportName : cstr_t

    memoryInfo : M3MemoryInfo
    memoryImport : M3ImportInfo
    memoryImported : bool
    memoryExportName : cstr_t

    // C source has a commented-out `hasWasmCodeCopy`; intentionally absent.
    next : M3Module?
}


typedef public IM3Module = M3Module?


// ============================================================================
// 1. Module_GetFunction
// ============================================================================


def public Module_GetFunction(var i_module : IM3Module; i_functionIndex : u32) : IM3Function {
    var func : IM3Function = null

    if (i_functionIndex < i_module.numFunctions) {
        // Bounds intentionally follow numFunctions, not backing capacity.
        unsafe {
            func = addr(i_module.functions[i_functionIndex])
        }
    }

    return func
}


// ============================================================================
// 2. m3_GetModuleName
// ============================================================================


def public m3_GetModuleName(i_module : IM3Module) : cstr_t {
    if (i_module == null || empty(i_module.name)) {
        return ".unnamed"
    }

    return i_module.name
}


// ============================================================================
// 3. m3_SetModuleName
// ============================================================================


def public m3_SetModuleName(var i_module : IM3Module; name : cstr_t) {
    if (i_module != null) {
        i_module.name = name
    }
}


// ============================================================================
// 4. m3_GetModuleRuntime
// ============================================================================


def public m3_GetModuleRuntime(var i_module : IM3Module) : IM3Runtime {
    return i_module != null ? i_module.runtime : null
}
