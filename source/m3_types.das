options gen2
options indenting = 4

module m3_types shared public

require ./m3_config.das public
require ./m3_core.das public
require ./m3_code.das public


/*
    Canonical shared data types for m3_function and m3_module.

    This module exists only to break the M3Function <-> M3Module dependency
    cycle in Daslang. It contains the active C-layout data declarations used by
    both layers; production algorithms remain in their original modules.

    Runtime/environment adaptation
    ------------------------------
    M3Runtime/IM3Runtime and pc_t already have accepted canonical declarations
    in m3_code.das, so this layer imports and reuses them without duplication.
    M3Environment is not ported yet; only its public pointer handle remains a
    raw pointer alias. The formerly opaque function/module fields are no longer
    raw: funcTypes, functions and table0 use their canonical types below.

    M3Global anonymous union adaptation
    -----------------------------------
    C overlays i32Value/i64Value/f64Value/f32Value in one anonymous union. The
    active configuration includes float and the union is exactly 8 bytes. Gen2
    has no untagged C union declaration, so `valueBits` is the sole 8-byte
    storage at that field position. The typed accessor functions below read and
    write that same address; 32-bit writes intentionally touch only the first
    four bytes, matching a C union member store on the active architecture.

    Inactive/commented C fields
    ---------------------------
    - M3Function.codePageRefs/numCodePageRefs: absent because
      d_m3EnableCodePageRefCounting == false.
    - M3Function.hits/index: absent because DEBUG is inactive.
    - M3Module.importedGlobals: commented out in C, absent here.
    - M3Module.hasWasmCodeCopy: commented out in C, absent here.
*/


// Full M3Environment is not part of review #6 yet.
typedef public IM3Environment = void?


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
typedef public IM3Module = M3Module?


// ============================================================================
// M3MemoryInfo / M3DataSegment from m3_env.h
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
    import : M3ImportInfo

    valueBits : u64                // exact 8-byte storage for C anonymous union

    name : cstr_t
    initExpr : bytes_t             // wasm code
    initExprSize : u32
    _type : u8                     // C field `type`; `type` is a gen2 keyword
    imported : bool
    isMutable : bool
}


typedef public IM3Global = M3Global?


// ============================================================================
// M3Function from m3_function.h
// ============================================================================


struct M3Function {
    _module : IM3Module             // C field `module`; keyword-safe Daslang spelling

    import : M3ImportInfo

    wasm : bytes_t
    wasmEnd : bytes_t

    names : cstr_t[d_m3MaxDuplicateFunctionImpl]
    export_name : cstr_t           // should be a part of "names"
    numNames : u16

    funcType : IM3FuncType

    compiled : pc_t                // canonical pc_t from m3_code.das

    // d_m3EnableCodePageRefCounting == false: codePageRefs fields absent.
    // DEBUG inactive: hits/index fields absent.

    maxStackSlots : u16

    numRetSlots : u16
    numRetAndArgSlots : u16

    numLocals : u16                // not including args
    numLocalBytes : u16

    ownsWasmCode : bool

    numConstantBytes : u16
    constants : void?
}


typedef public IM3Function = M3Function?


// ============================================================================
// M3Module from m3_env.h
// ============================================================================


struct M3Module {
    runtime : IM3Runtime
    environment : IM3Environment

    wasmStart : bytes_t
    wasmEnd : bytes_t

    name : cstr_t

    numFuncTypes : u32
    funcTypes : IM3FuncType?       // C: IM3FuncType *

    numFuncImports : u32
    numFunctions : u32
    allFunctions : u32
    functions : M3Function?        // C: contiguous M3Function * array

    startFunction : i32

    numDataSegments : u32
    dataSegments : M3DataSegment?

    // C source has a commented-out `importedGlobals`; intentionally absent.
    numGlobals : u32
    globals : M3Global?

    numElementSegments : u32
    elementSection : bytes_t
    elementSectionEnd : bytes_t

    table0 : IM3Function?          // C: IM3Function * array
    table0Size : u32
    table0ExportName : cstr_t

    memoryInfo : M3MemoryInfo
    memoryImport : M3ImportInfo
    memoryImported : bool
    memoryExportName : cstr_t

    // C source has a commented-out `hasWasmCodeCopy`; intentionally absent.
    next : M3Module?
}


// ============================================================================
// Typed views of M3Global's shared 8-byte union storage
// ============================================================================


def public M3Global_GetI32Value(var i_global : M3Global&) : i32 {
    var value : i32? = unsafe(addr<i32?>(i_global.valueBits))
    return *value
}


def public M3Global_SetI32Value(var i_global : M3Global&; i_value : i32) {
    var value : i32? = unsafe(addr<i32?>(i_global.valueBits))
    *value = i_value
}


def public M3Global_GetI64Value(i_global : M3Global&) : i64 {
    return unsafe(reinterpret<i64>(i_global.valueBits))
}


def public M3Global_SetI64Value(var i_global : M3Global&; i_value : i64) {
    i_global.valueBits = unsafe(reinterpret<u64>(i_value))
}


def public M3Global_GetF32Value(var i_global : M3Global&) : f32 {
    var value : f32? = unsafe(addr<f32?>(i_global.valueBits))
    return *value
}


def public M3Global_SetF32Value(var i_global : M3Global&; i_value : f32) {
    var value : f32? = unsafe(addr<f32?>(i_global.valueBits))
    *value = i_value
}


def public M3Global_GetF64Value(i_global : M3Global&) : f64 {
    return unsafe(reinterpret<f64>(i_global.valueBits))
}


def public M3Global_SetF64Value(var i_global : M3Global&; i_value : f64) {
    i_global.valueBits = unsafe(reinterpret<u64>(i_value))
}
