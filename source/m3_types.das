options gen2
options indenting = 4

module m3_types shared public

require ./m3_config.das public
require ./m3_core.das public


/*
    Canonical shared data types for m3_function and m3_module.

    This module exists only to break the M3Function <-> M3Module dependency
    cycle in Daslang. It contains the active C-layout data declarations used by
    both layers; production algorithms remain in their original modules.

    Runtime/environment adaptation
    ------------------------------
    IM3Runtime and pc_t are canonical declarations: pc_t from m3_core.das and
    IM3Runtime defined below together with the full m3_env.h runtime layout.
    m3_code.das requires this module for them (the C header cycle between
    m3_core.h and m3_env.h becomes a one-way Daslang module graph).

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


// Canonical runtime handle. The full M3Runtime layout from m3_env.h is
// defined below; the pointer alias stays here because M3Module refers to it.
typedef public IM3Runtime = M3Runtime?

// Full M3Environment from m3_env.h is defined below.
typedef public IM3Environment = M3Environment?


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
// wasm3.h public structures required by the runtime layer
// ============================================================================


/*
    m3_env.h / m3_compile.h include wasm3.h; the runtime structures below
    therefore need these declarations before the public API facade exists.
    They are hosted here with the rest of the shared C-layout types.
*/


/* C: typedef struct M3ErrorInfo {...} M3ErrorInfo; (wasm3.h) */
struct M3ErrorInfo {
    result : M3Result

    runtime : IM3Runtime
    _module : IM3Module        // C field `module`; keyword-safe Daslang spelling
    _function : IM3Function        // C field `function`; keyword-safe Daslang spelling

    file : cstr_t
    line : u32

    message : cstr_t
}


/*
    C: typedef struct M3TaggedValue { M3ValueType type; union {...}; } M3TaggedValue;

    The C anonymous union is adapted as the same 8-byte valueBits storage
    used by M3Global; the typed accessors below read and write that address.
*/
struct M3TaggedValue {
    _type : M3ValueType             // C field `type`; keyword-safe Daslang spelling

    valueBits : u64             // exact 8-byte storage for the C anonymous union
}


typedef public IM3TaggedValue = M3TaggedValue?


/* C: typedef M3Result (* M3SectionHandler) (IM3Module i_module, const char* name, const uint8_t * start, const uint8_t * end); */
typedef public M3SectionHandler = function<(i_module : IM3Module; i_name : cstr_t; i_start : cbytes_t; i_end : cbytes_t) : M3Result>


/* C wasm3.h: typedef struct M3ImportContext { void * userdata; IM3Function function; } M3ImportContext; */
struct M3ImportContext {
    userdata : void?
    _function : IM3Function        // C field `function`; keyword-safe Daslang spelling
}


typedef public IM3ImportContext = M3ImportContext?


/* C wasm3.h: typedef const void * (* M3RawCall) (IM3Runtime runtime, IM3ImportContext _ctx, uint64_t * _sp, void * _mem); */
typedef public M3RawCall = function<(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result>


// ============================================================================
// m3_env.h runtime structures
// ============================================================================


/*
    C declares M3MemoryHeader in m3_core.h while M3Runtime/M3Environment live
    in m3_env.h; the C headers resolve this circularly with forward typedefs.
    Daslang module graphs must stay acyclic, so the whole runtime layout is
    unified in this shared-types module. Field names, order, and the active
    configuration surface follow the C definitions exactly.
*/


/* C m3_core.h: typedef struct M3MemoryHeader { IM3Runtime runtime; void * maxStack; size_t length; } M3MemoryHeader; */
struct M3MemoryHeader {
    runtime : IM3Runtime
    maxStack : void?
    length : u64
}


typedef public IM3MemoryHeader = M3MemoryHeader?


/* C m3_env.h: typedef struct M3Memory { M3MemoryHeader * mallocated; u32 numPages; u32 maxPages; u32 pageSize; } M3Memory; */
struct M3Memory {
    mallocated : IM3MemoryHeader

    numPages : u32
    maxPages : u32
    pageSize : u32
}


typedef public IM3Memory = M3Memory?


/* C m3_env.h: typedef struct M3Environment {...} M3Environment; */
struct M3Environment {
    // struct M3Runtime * runtimes: commented out in C, absent here.

    funcTypes : IM3FuncType                    // linked list of unique M3FuncType structs

    // C: IM3FuncType retFuncTypes[c_m3Type_unknown]; int(enum) folds only with
    // infer-time folding, but the lint-profile compile disables folding and the
    // dimension must stay a constant: spelled as the literal 6 = c_m3Type_unknown.
    retFuncTypes : IM3FuncType[6]                  // these 'point' to elements in the linked list above.

    pagesReleased : IM3CodePage

    customSectionHandler : M3SectionHandler
}


// ============================================================================
// m3_compile.h compilation structures
// ============================================================================


/*
    Daslang width adaptation
    ------------------------
    M3Compilation/M3CompilationScope slot counters use C u16 storage. Daslang
    gen2 does not define arithmetic on 8/16-bit storage types, and the compiler
    performs slot arithmetic on them constantly, so those scalars are
    represented as int (32-bit) here. Slot ARRAYS keep their exact C widths
    (wasmStack, typeStack, m3Slots, constants are also widened to int elements).
*/




/* C m3_compile.h: typedef struct M3CompilationScope {...} M3CompilationScope; */
struct M3CompilationScope {
    outer : M3CompilationScope?

    pc : pc_t                 // used by ContinueLoop's
    patches : pc_t
    depth : i32
    exitStackIndex : int
    blockStackIndex : int
//    u16 topField: commented out in C, absent here.
    _type : IM3FuncType           // C field `type`; keyword-safe Daslang spelling
    opcode : m3opcode_t
    isPolymorphic : bool
}


typedef public IM3CompilationScope = M3CompilationScope?


/* C m3_compile.h: typedef struct {...} M3Compilation; */
struct M3Compilation {
    runtime : IM3Runtime
    _module : IM3Module

    wasm : bytes_t
    wasmEnd : bytes_t
    lastOpcodeStart : bytes_t

    _block : M3CompilationScope      // C field `block`; keyword-safe Daslang spelling

    _function : IM3Function        // C field `function`; keyword-safe Daslang spelling

    page : IM3CodePage

    // DEBUG inactive: numEmits/numOpcodes fields absent.

    stackFirstDynamicIndex : int    // args and locals are pushed to the stack so that their slot locations can be tracked. the wasm model itself doesn't
                                    // treat these values as being on the stack, so stackFirstDynamicIndex marks the start of the real Wasm stack
    stackIndex : int                // current stack top

    slotFirstConstIndex : int
    slotMaxConstIndex : int         // as const's are encountered during compilation this tracks their location in the "real" stack

    slotFirstLocalIndex : int
    slotFirstDynamicIndex : int     // numArgs + numLocals + numReservedConstants. the first mutable slot available to the compiler.

    maxStackSlots : int

    constants : int[d_m3MaxConstantTableSize]

    // 'wasmStack' holds slot locations
    wasmStack : int[d_m3MaxFunctionStackHeight]
    typeStack : int[d_m3MaxFunctionStackHeight]

    // 'm3Slots' contains allocation usage counts
    m3Slots : int[d_m3MaxFunctionSlots]

    slotMaxAllocatedIndexPlusOne : int

    regStackIndexPlusOne : int[2]

    previousOpcode : m3opcode_t
}


typedef public IM3Compilation = M3Compilation?


/* C m3_compile.h: typedef M3Result (* M3Compiler) (IM3Compilation, m3opcode_t); */
typedef public M3Compiler = function<(io_compilation : IM3Compilation; i_opcode : m3opcode_t) : M3Result>


// ============================================================================
// M3Runtime from m3_env.h
// ============================================================================


/* C m3_env.h: typedef struct M3Runtime {...} M3Runtime; */
struct M3Runtime {
    compilation : M3Compilation

    environment : IM3Environment

    pagesOpen : IM3CodePage     // linked list of code pages with writable space on them
    pagesFull : IM3CodePage     // linked list of at-capacity pages

    numCodePages : u32
    numActiveCodePages : u32

    modules : IM3Module         // linked list of imported modules

    stack : void?
    originStack : void?
    stackSize : u32
    numStackSlots : u32
    lastCalled : IM3Function    // last function that successfully executed

    userdata : void?

    memory : M3Memory
    memoryLimit : u32

    // d_m3EnableStrace < 2: callDepth field absent.

    error : M3ErrorInfo

    // d_m3RecordBacktraces == false: backtrace field absent.

    newCodePageSequence : u32
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

// ============================================================================
// m3Error (C m3_core.c / m3_core.h)
// ============================================================================


/*
    Deviation note: C declares m3Error in m3_core.h with forward-declared
    runtime pointers; the Daslang definition needs the concrete runtime
    structures, so it lives in this shared-types module. Active because
    d_m3VerboseErrorMessages is true in the port configuration.
*/

def public m3Error(i_result : M3Result; var i_runtime : IM3Runtime; i_module : IM3Module; i_function : IM3Function; i_file : cstr_t; i_lineNum : u32; i_errorMessage : cstr_t) : M3Result {
    if (i_runtime != null) {
        unsafe {
            i_runtime.error.result = i_result
            i_runtime.error.runtime = i_runtime
            i_runtime.error._module = reinterpret<IM3Module>(i_module)
            i_runtime.error._function = reinterpret<IM3Function>(i_function)
            i_runtime.error.file = i_file
            i_runtime.error.line = i_lineNum
            i_runtime.error.message = i_errorMessage
        }
    }
    return i_result
}