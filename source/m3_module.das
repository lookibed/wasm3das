options gen2
options indenting = 4

module m3_module shared public

require ./m3_config.das public
require ./m3_core.das public


/*
    Preparatory m3_module data layer.

    This stage intentionally does not import m3_function.das. That file still
    owns the temporary M3Module used by the function/bind work, so the canonical
    structures are not merged here. In particular, this module does NOT declare
    M3Function, M3FuncType, M3ImportInfo or aliases for them.

    Standalone pointer/storage adaptations used until the merge step:
    - runtime/environment are opaque pointers: their pointees are never read here;
    - funcTypes/functions/table0 are opaque raw pointers with the same pointer-size
      storage as their C pointer fields;
    - M3ImportInfo is a by-value pair of const-char pointers in C. Until the
      canonical type can be imported without a M3Module collision, `import` and
      `memoryImport` use fixed cstr_t[2] storage in the same field position:
      index 0 = moduleUtf8, index 1 = fieldUtf8. No duplicate M3ImportInfo type
      is declared.

    M3Global anonymous union adaptation:
    C overlays i32Value/i64Value/f64Value/f32Value in one union whose size and
    alignment are 8 bytes for the active d_m3HasFloat configuration. Gen2 has no
    untagged union declaration, so `i64Value` is kept as the single 8-byte
    storage anchor at the union position. The other C members are views of this
    same storage, not separate fields. Future global accessors must reinterpret
    this storage according to `_type`; no ownership is introduced.

    Inactive/commented C fields:
    - M3Module.importedGlobals is commented out in m3_env.h: absent here.
    - M3Module.hasWasmCodeCopy is commented out in m3_env.h: absent here.
    M3Global's float union views are active because d_m3HasFloat == true, but
    they share the same `i64Value` storage anchor rather than widening the struct.
*/


// ============================================================================
// Minimal forward/adaptation pointer aliases used directly by M3Module
// ============================================================================


typedef public IM3Runtime = void?
typedef public IM3Environment = void?


// ============================================================================
// Public value types used by M3Global/M3Module
// ============================================================================


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


// ============================================================================
// M3Global from m3_env.h
// ============================================================================


struct M3Global {
    import : cstr_t[2]           // C M3ImportInfo: [moduleUtf8, fieldUtf8]

    i64Value : i64               // 8-byte anchor for C anonymous union
                                 // i32Value/f64Value/f32Value overlay this address

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
    funcTypes : void?                 // C: IM3FuncType *; opaque until canonical merge

    numFuncImports : u32
    numFunctions : u32
    allFunctions : u32
    functions : void?                 // C: M3Function *; opaque until canonical merge

    startFunction : i32

    numDataSegments : u32
    dataSegments : M3DataSegment?

    // C source has a commented-out `importedGlobals`; intentionally absent.
    numGlobals : u32
    globals : M3Global?

    numElementSegments : u32
    elementSection : bytes_t
    elementSectionEnd : bytes_t

    table0 : void?                     // C: IM3Function *; opaque until canonical merge
    table0Size : u32
    table0ExportName : cstr_t

    memoryInfo : M3MemoryInfo
    memoryImport : cstr_t[2]           // C M3ImportInfo: [moduleUtf8, fieldUtf8]
    memoryImported : bool
    memoryExportName : cstr_t

    // C source has a commented-out `hasWasmCodeCopy`; intentionally absent.
    next : M3Module?
}


typedef public IM3Module = M3Module?


// The function-index accessor is intentionally deferred in review 5.1.
// Its C implementation requires canonical M3Function stride/indexing; opaque
// pointer storage is not sufficient for correct element-address arithmetic.
// It will be restored only after the canonical module/function models merge.


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
