options gen2
options indenting = 4

module m3_types shared public

require modules/wasm3das/source/m3_config public   // Eden: project-root-relative path (upstream: ./m3_config.das)
require modules/wasm3das/source/m3_core public     // Eden: project-root-relative path (upstream: ./m3_core.das)
require daslib/math_bits                           // Eden: bit views of the M3Global union storage (DESIGN.md section 4.2)


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

    M3Environment is defined below (Eden: a value embedded in the runtime, no
    pointer alias). The formerly opaque function/module fields are no longer
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

    Eden: deviations from the upstream port (.upstream/source/m3_types.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md). The sandbox has no
    raw pointers, so the type hub is the handle model of DESIGN section 4.1:
    the runtime owns arenas, every C pointer field is an `int` handle into
    the arena named by its C type (-1 = NULL) or an array, and every struct
    is a value constructible with `S()` (every scalar field has an
    initializer; arrays start empty, C's zero fill). Struct names, field
    names and field order are C's; the suffix `Idx` is added only where the
    C name would read as a value (`moduleIdx` for `module`, `functionIdx`
    for `function`, `funcTypeIdx` for `funcType`, `typeIdx` for `type`).
      - requires are Eden-project-root relative (DESIGN section 6); m3_config
        and m3_core stay public re-exports; daslib/math_bits supplies the bit
        views of the M3Global union storage.
      - handle aliases: IM3Runtime, IM3Module, IM3Function, IM3FuncType and
        IM3Global are `int` handles (IM3CodePage comes from m3_core). The
        upstream pointer aliases of value types that have no arena
        (IM3Environment, IM3ImportInfo, IM3TaggedValue, IM3ImportContext,
        IM3MemoryHeader, IM3Memory, IM3CompilationScope, IM3Compilation)
        are not declared: those structs are passed by reference or embedded.
        IM3Runtime is the handle of a runtime as seen from inside its own
        arenas: 0 = the runtime that owns the object, -1 = NULL (a module's
        `runtime` is -1 until m3_LoadModule links it, as C's pointer is).
      - M3FuncType.types is `array<u8>` (C: the flexible tail `u8 types[]`,
        returns then args); `next` is a handle into rt.funcTypes.
      - M3Function: `module` -> moduleIdx (rt.modules), `funcType` ->
        funcTypeIdx (rt.funcTypes), `compiled` is an index into rt.code (-1
        = not compiled), wasm/wasmEnd are indices into the owning module's
        `wasm` array, `constants` is `array<u64>` (C: `void *`, the copied
        constant table: one 64-bit word per slot, DESIGN section 4.3;
        numConstantBytes keeps its C name and meaning). The added
        `isExported` flag is C's `export_name != NULL`, which a cstr_t
        ("" = NULL) cannot express: a function may be exported as "" (DESIGN
        4.1); m3_parse sets it with export_name, m3_env's lookups test it.
      - M3Global: the added `isExported` flag is C's `name != NULL` (a
        global may be exported as ""); m3_parse sets it with the export
        name, m3_FindGlobal tests it.
      - M3Module: `runtime` is an IM3Runtime handle; `environment` is absent
        (the runtime embeds its environment, see M3Runtime); the module owns
        `wasm : array<u8>`, a copy of the binary (DESIGN section 4.1), and
        wasmStart/wasmEnd/elementSection/elementSectionEnd are indices into
        it; funcTypes/functions/globals are `array<int>` of handles into
        rt.funcTypes/rt.functions/rt.globals in C order (imports first);
        dataSegments is `array<M3DataSegment>`; table0 is `array<int>` of
        function handles (-1 = NULL); `next` is absent (rt.modules is the
        arena).
      - M3DataSegment.initExpr/data and M3Global.initExpr are indices into
        the module's `wasm` array (-1 = NULL).
      - M3ErrorInfo: runtime/module/function are handles (runtime,
        moduleIdx, functionIdx).
      - M3ImportContext: `userdata` (C: `void *`) is an `int` token the
        linker stores (-1 = NULL) and `function` -> functionIdx. The Eden
        raw-call ABI does not receive a context (DESIGN section 4.5); the
        struct stays for m3_bind / m3_api_defs to hold one where they need
        it.
      - M3SectionHandler takes the runtime and a module handle; the section
        bytes are `rt.modules[i_module].wasm[i_start .. i_end)`.
      - M3RawCall is `function<(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result>`
        (DESIGN section 4.5): results then arguments, one 64-bit cell of
        two slot words each from rt.stack[sp] (m3_api_defs walks them),
        memory through rt.mem; the linked function values live in
        rt.rawCalls and a code word holds the handle. The upstream `_ctx`,
        `_sp` and `_mem` pointer parameters have no counterpart.
      - M3Op (C: IM3Operation of m3_exec_defs.h, declared here because the
        runtime's op table refers to it) is `function<(var rt : M3Runtime) :
        int>`, the return protocol of DESIGN section 4.4.
      - M3MemoryHeader is absent: the linear memory is rt.mem and M3Memory
        keeps numPages/maxPages/pageSize (its `mallocated` pointer is
        absent, DESIGN section 4.2).
      - M3Environment keeps only what C keeps outside a runtime: the
        `funcTypes` list head and `pagesReleased` are absent (the interned
        func types are rt.funcTypes, the code words rt.code, and the pool of
        released pages is M3Runtime.pagesReleased, DESIGN section 4.1);
        retFuncTypes are handles into rt.funcTypes (-1 = NULL) and are
        filled by m3_NewRuntime, which interns the basic types into the
        runtime it creates; customSectionHandler is a function value (null
        = none). The runtime embeds a copy of its environment
        (M3Runtime.environment, C: a pointer), so `module->environment->x`
        is `rt.environment.x`.
      - M3CompilationScope.outer is an index into the scope stack m3_compile
        keeps (C: a pointer to the caller's local scope); pc/patches are
        indices into rt.code; `type` -> typeIdx (rt.funcTypes).
      - M3Compilation: runtime/module/function are handles (runtime,
        moduleIdx, functionIdx), page is an IM3CodePage handle,
        wasm/wasmEnd/lastOpcodeStart are indices into the module's `wasm`,
        `constants` is `u64[d_m3MaxConstantTableSize]` (one entry per C
        32-bit slot, a 64-bit constant fills a pair as in C; layout in
        m3_compile's header and DESIGN 4.4a), the slot
        counters and slot arrays keep the upstream `int` widening;
        `scopeStack : array<M3CompilationScope>` (absent in C) holds the
        enclosing scopes C keeps on the native stack, indexed by
        M3CompilationScope.outer (DESIGN section 4.4a).
      - M3Compiler is `function<(var rt : M3Runtime; i_opcode : m3opcode_t)
        : M3Result>`: the compilation is rt.compilation and the compiler
        needs the runtime's arenas, so C's IM3Compilation argument is the
        runtime.
      - M3Runtime: the C fields come first in C order (environment embedded,
        pagesOpen/pagesFull handles into the Eden field `codePages`, the
        code-page arena m3_code manages, followed by pagesReleased, C's
        environment->pagesReleased, since the pool moved into the runtime;
        modules is the module arena; stack
        is `array<u64>`, originStack an index into it; lastCalled a function
        handle; userdata an `int` token; the C `error_message[256]` buffer
        is absent because strings own their storage, as upstream), then the
        Eden arenas funcTypes/functions/globals/rawCalls, then the execution
        state of DESIGN sections 4.2-4.4 (code, mem, pc, sp, r0, fp0, trap),
        then the stdio buffers of DESIGN section 4.7 (stdinBuffer,
        stdoutBuffer, stderrBuffer). Every index field of pointer origin
        starts at -1 (pc, sp, originStack included) until m3_NewRuntime
        allocates the stack.
      - the M3Global accessors read and write valueBits with arithmetic and
        daslib/math_bits instead of address views: the 32-bit views are the
        low four bytes (the little-endian union member), the 64-bit views
        are the whole word.
      - m3Error takes the runtime by reference (C: a pointer that may be
        NULL); the C `if (i_runtime)` test has no counterpart, so a caller
        that in C passes a NULL runtime (ErrorModule while a module is being
        parsed) records the error here; module and function are handles and
        error.runtime is set to 0 (this runtime).
*/


// ============================================================================
// Handle aliases (DESIGN.md section 4.1)
// ============================================================================


// Canonical runtime handle. The full M3Runtime layout from m3_env.h is
// defined below; the alias stays here because M3Module refers to it.
// Eden: the handle of a runtime as seen from inside its own arenas: 0 = the
// owning runtime, -1 = NULL (C: M3Runtime *)
typedef public IM3Runtime = int

// Eden: IM3Environment is not declared; the environment is embedded in its
// runtime (M3Runtime.environment), see the header.

typedef public IM3Module = int      // Eden: handle into rt.modules (C: M3Module *), -1 = NULL
typedef public IM3Function = int    // Eden: handle into rt.functions (C: M3Function *), -1 = NULL
typedef public IM3FuncType = int    // Eden: handle into rt.funcTypes (C: M3FuncType *), -1 = NULL
typedef public IM3Global = int      // Eden: handle into rt.globals (C: M3Global *), -1 = NULL


// ============================================================================
// M3ImportInfo from wasm3.h
// ============================================================================


struct M3ImportInfo {
    moduleUtf8 : cstr_t = ""
    fieldUtf8 : cstr_t = ""
}


// Eden: IM3ImportInfo is not declared; the struct is passed by reference.


// ============================================================================
// M3FuncType from m3_function.h
// ============================================================================


struct M3FuncType {
    next : IM3FuncType = -1        // Eden: handle into rt.funcTypes (C: struct M3FuncType *)

    numRets : u16 = u16(0)
    numArgs : u16 = u16(0)
    types : array<u8>              // returns, then args; Eden: C's flexible tail `u8 types[]`
}


// ============================================================================
// M3MemoryInfo / M3DataSegment from m3_env.h
// ============================================================================


struct M3MemoryInfo {
    initPages : u32 = 0u
    maxPages : u32 = 0u
    pageSize : u32 = 0u
}


struct M3DataSegment {
    initExpr : cbytes_t = -1       // Eden: index into the module's wasm array (C: const u8 *), -1 = NULL
    data : cbytes_t = -1           // Eden: index into the module's wasm array (C: const u8 *), -1 = NULL

    initExprSize : u32 = 0u
    memoryRegion : u32 = 0u
    size : u32 = 0u
}


// ============================================================================
// M3Global from m3_env.h
// ============================================================================


struct M3Global {
    import : M3ImportInfo = M3ImportInfo()

    valueBits : u64 = 0ul          // exact 8-byte storage for C anonymous union

    name : cstr_t = ""
    initExpr : bytes_t = -1        // wasm code; Eden: index into the module's wasm array, -1 = NULL
    initExprSize : u32 = 0u
    _type : u8 = 0u8               // C field `type`; `type` is a gen2 keyword
    imported : bool = false
    isMutable : bool = false
    isExported : bool = false      // Eden: C's `name != NULL` (cstr_t "" cannot tell NULL, DESIGN 4.1); set with every export name
}


// ============================================================================
// M3Function from m3_function.h
// ============================================================================


struct M3Function {
    moduleIdx : IM3Module = -1     // C field `module`; Eden: handle into rt.modules (DESIGN.md 4.1)

    import : M3ImportInfo = M3ImportInfo()

    wasm : bytes_t = -1            // Eden: index into the owning module's wasm array, -1 = NULL
    wasmEnd : bytes_t = -1         // Eden: index into the owning module's wasm array, -1 = NULL

    names : cstr_t[d_m3MaxDuplicateFunctionImpl]
    export_name : cstr_t = ""      // should be a part of "names"
    isExported : bool = false      // Eden: C's `export_name != NULL` (cstr_t "" cannot tell NULL, DESIGN 4.1); set with every export_name
    numNames : u16 = u16(0)

    funcTypeIdx : IM3FuncType = -1 // C field `funcType`; Eden: handle into rt.funcTypes (DESIGN.md 4.1)

    compiled : pc_t = -1           // canonical pc_t from m3_core.das; Eden: index into rt.code, -1 = not compiled

    // d_m3EnableCodePageRefCounting == false: codePageRefs fields absent.
    // DEBUG inactive: hits/index fields absent.

    maxStackSlots : u16 = u16(0)

    numRetSlots : u16 = u16(0)
    numRetAndArgSlots : u16 = u16(0)

    numLocals : u16 = u16(0)       // not including args
    numLocalBytes : u16 = u16(0)

    ownsWasmCode : bool = false

    numConstantBytes : u16 = u16(0)
    constants : array<u64>         // Eden: the copied constant table, one 64-bit word per slot (C: void *)
}


// ============================================================================
// M3Module from m3_env.h
// ============================================================================


struct M3Module {
    runtime : IM3Runtime = -1      // Eden: 0 once m3_LoadModule links the module, -1 before (C: a NULL pointer)
    // Eden: `environment` is absent; the runtime embeds its environment
    // (rt.environment), see the header.

    wasm : array<u8>               // Eden: the module's copy of the binary (DESIGN.md 4.1); the indices below refer to it
    wasmStart : bytes_t = -1       // Eden: index into wasm, -1 = NULL
    wasmEnd : bytes_t = -1         // Eden: index into wasm, -1 = NULL

    name : cstr_t = ""

    numFuncTypes : u32 = 0u
    funcTypes : array<int>         // C: IM3FuncType *; Eden: handles into rt.funcTypes

    numFuncImports : u32 = 0u
    numFunctions : u32 = 0u
    allFunctions : u32 = 0u
    functions : array<int>         // C: contiguous M3Function * array; Eden: handles into rt.functions, C order (imports first)

    startFunction : i32 = -1   // Eden: -1 from construction; C callocs 0 but every constructor (m3_parse.c:619) sets -1 before use, and m3_LoadModule runs any index >= 0

    numDataSegments : u32 = 0u
    dataSegments : array<M3DataSegment>   // C: M3DataSegment *; Eden: values owned by the module

    // C source has a commented-out `importedGlobals`; intentionally absent.
    numGlobals : u32 = 0u
    globals : array<int>           // C: M3Global *; Eden: handles into rt.globals

    numElementSegments : u32 = 0u
    elementSection : bytes_t = -1  // Eden: index into wasm, -1 = NULL
    elementSectionEnd : bytes_t = -1   // Eden: index into wasm, -1 = NULL

    table0 : array<int>            // C: IM3Function * array; Eden: function handles, -1 = NULL
    table0Size : u32 = 0u
    table0ExportName : cstr_t = ""

    memoryInfo : M3MemoryInfo = M3MemoryInfo()
    memoryImport : M3ImportInfo = M3ImportInfo()
    memoryImported : bool = false
    memoryExportName : cstr_t = ""

    // C source has a commented-out `hasWasmCodeCopy`; intentionally absent.
    // Eden: `next` is absent; rt.modules is the arena (DESIGN.md 4.1).
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
    result : M3Result = ""

    runtime : IM3Runtime = -1      // Eden: 0 once m3Error records an error (this runtime), -1 = NULL
    moduleIdx : IM3Module = -1     // C field `module`; Eden: handle into rt.modules
    functionIdx : IM3Function = -1 // C field `function`; Eden: handle into rt.functions

    file : cstr_t = ""
    line : u32 = 0u

    message : cstr_t = ""
}


/*
    C: typedef struct M3TaggedValue { M3ValueType type; union {...}; } M3TaggedValue;

    The C anonymous union is adapted as the same 8-byte valueBits storage
    used by M3Global; readers use the M3Global_* accessors' bit conventions
    (there are no separate M3TaggedValue accessors).
*/
struct M3TaggedValue {
    _type : M3ValueType = M3ValueType.c_m3Type_none   // C field `type`; keyword-safe Daslang spelling

    valueBits : u64 = 0ul          // exact 8-byte storage for the C anonymous union
}


// Eden: IM3TaggedValue is not declared; the struct is passed by reference.


// C: a zero-initialised M3TaggedValue is `{ c_m3Type_none, 0 }`. This is also
// what makes the daslang AOT emitter declare M3ValueType in this unit: it
// declares an enum of another module only when the unit's own code uses one
// of its values, and without it the generated M3TaggedValue does not compile.
def m3_TaggedValueNone() : M3TaggedValue {
    return M3TaggedValue(_type = M3ValueType.c_m3Type_none, valueBits = 0ul)
}


/* C: typedef M3Result (* M3SectionHandler) (IM3Module i_module, const char* name, const uint8_t * start, const uint8_t * end); */
// Eden: the handler receives the runtime and a module handle; the section is
// rt.modules[i_module].wasm[i_start .. i_end)
typedef public M3SectionHandler = function<(var rt : M3Runtime; i_module : IM3Module; i_name : cstr_t; i_start : cbytes_t; i_end : cbytes_t) : M3Result>


/* C wasm3.h: typedef struct M3ImportContext { void * userdata; IM3Function function; } M3ImportContext; */
struct M3ImportContext {
    userdata : int = -1            // Eden: an integer token the linker stores (C: void *), -1 = NULL
    functionIdx : IM3Function = -1 // C field `function`; Eden: handle into rt.functions
}


// Eden: IM3ImportContext is not declared; the struct is passed by reference.


/* C wasm3.h: typedef const void * (* M3RawCall) (IM3Runtime runtime, IM3ImportContext _ctx, uint64_t * _sp, void * _mem); */
// Eden: DESIGN.md section 4.5. A raw function reads its results' and
// arguments' cells (two slot words each, results first) from rt.stack[sp]
// on, through the m3_api_defs frame, and the memory through rt.mem; the linked values live in
// rt.rawCalls and a code word holds the handle. `rt` is `var`: every raw
// function writes the return slot and the guest buffers. `ctx` is C's
// IM3ImportContext by value (functionIdx, userdata token): the WASI host
// functions read ctx.userdata as C reads _ctx->userdata.
typedef public M3RawCall = function<(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result>


/* C m3_exec_defs.h: typedef m3ret_t (vectorcall * IM3Operation) (d_m3OpSig); */
// Eden: DESIGN.md section 4.4. An operation takes the runtime (pc, sp, r0,
// fp0 and the arenas are its fields) and returns the protocol value:
// M3_NEXT, M3_RETURN, M3_TRAP (rt.trap holds the M3Result) or a loop pc.
// Declared here, next to M3RawCall, because both are runtime-level function
// types; m3_exec_defs declares the protocol constants.
typedef public M3Op = function<(var rt : M3Runtime) : int>


// ============================================================================
// m3_env.h runtime structures
// ============================================================================


/*
    C declares M3MemoryHeader in m3_core.h while M3Runtime/M3Environment live
    in m3_env.h; the C headers resolve this circularly with forward typedefs.
    Daslang module graphs must stay acyclic, so the whole runtime layout is
    unified in this shared-types module. Field names, order, and the active
    configuration surface follow the C definitions exactly.

    Eden: M3MemoryHeader (C m3_core.h: runtime, maxStack, length) is absent.
    It was the header of the malloc'd linear memory block; the linear memory
    is rt.mem, its length is `length(rt.mem)`, and the stack limit
    (maxStack) is `rt.numStackSlots`; rt.stack has 4 spare words past it
    (DESIGN.md sections 4.2, 4.3).
*/


/* C m3_env.h: typedef struct M3Memory { M3MemoryHeader * mallocated; u32 numPages; u32 maxPages; u32 pageSize; } M3Memory; */
struct M3Memory {
    // Eden: `mallocated` is absent; the bytes are rt.mem (DESIGN.md 4.2)

    numPages : u32 = 0u
    maxPages : u32 = 0u
    pageSize : u32 = 0u
}


// Eden: IM3Memory is not declared; the struct is embedded in the runtime.


/* C m3_env.h: typedef struct M3Environment {...} M3Environment; */
struct M3Environment {
    // struct M3Runtime * runtimes: commented out in C, absent here.

    // Eden: `funcTypes` (C: the linked list of unique M3FuncType structs) is
    // absent; the interned types are rt.funcTypes (DESIGN.md 4.1).

    // C: IM3FuncType retFuncTypes[c_m3Type_unknown]; int(enum) folds only with
    // infer-time folding, but the lint-profile compile disables folding and the
    // dimension must stay a constant: spelled as the literal 6 = c_m3Type_unknown.
    // Eden: handles into rt.funcTypes, filled by m3_NewRuntime, -1 = NULL
    retFuncTypes : int[6] = fixed_array(-1, -1, -1, -1, -1, -1)   // these 'point' to elements in the interned list.

    // Eden: `pagesReleased` (C: M3CodePage *) is absent here; the page pool
    // moved into the runtime with the code words (M3Runtime.pagesReleased,
    // a handle into rt.codePages; DESIGN.md 4.1, 4.4).

    customSectionHandler : M3SectionHandler   // Eden: null = no handler (C: a NULL function pointer)
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
    represented as int (32-bit) here. Slot ARRAYS keep their exact C lengths
    (d_m3MaxFunctionStackHeight, d_m3MaxFunctionSlots) but their elements are
    widened to int as well; constants are 64-bit words, see the header.
*/


/* C m3_compile.h: typedef struct M3CompilationScope {...} M3CompilationScope; */
struct M3CompilationScope {
    outer : int = -1               // Eden: index of the enclosing scope in the scope stack m3_compile keeps (C: a pointer to the caller's local), -1 = NULL

    pc : pc_t = -1                 // used by ContinueLoop's; Eden: index into rt.code, -1 = NULL
    patches : pc_t = -1            // Eden: index into rt.code of the first patch word, -1 = NULL
    depth : i32 = 0
    exitStackIndex : int = 0
    blockStackIndex : int = 0
//    u16 topField: commented out in C, absent here.
    typeIdx : IM3FuncType = -1     // C field `type`; Eden: handle into rt.funcTypes
    opcode : m3opcode_t = m3opcode_t(0)
    isPolymorphic : bool = false
}


// Eden: IM3CompilationScope is not declared; the struct is passed by reference.


/* C m3_compile.h: typedef struct {...} M3Compilation; */
struct M3Compilation {
    runtime : IM3Runtime = -1      // Eden: 0 while a compilation runs (the runtime embedding this struct), -1 = NULL
    moduleIdx : IM3Module = -1     // C field `module`; Eden: handle into rt.modules

    wasm : bytes_t = -1            // Eden: index into the module's wasm array, -1 = NULL
    wasmEnd : bytes_t = -1         // Eden: index into the module's wasm array, -1 = NULL
    lastOpcodeStart : bytes_t = -1 // Eden: index into the module's wasm array, -1 = NULL

    _block : M3CompilationScope = M3CompilationScope()   // C field `block`; keyword-safe Daslang spelling

    functionIdx : IM3Function = -1 // C field `function`; Eden: handle into rt.functions

    page : IM3CodePage = -1        // Eden: handle into rt.codePages

    // DEBUG inactive: numEmits/numOpcodes fields absent.

    stackFirstDynamicIndex : int = 0    // args and locals are pushed to the stack so that their slot locations can be tracked. the wasm model itself doesn't
                                        // treat these values as being on the stack, so stackFirstDynamicIndex marks the start of the real Wasm stack
    stackIndex : int = 0                // current stack top

    slotFirstConstIndex : int = 0
    slotMaxConstIndex : int = 0         // as const's are encountered during compilation this tracks their location in the "real" stack

    slotFirstLocalIndex : int = 0
    slotFirstDynamicIndex : int = 0     // numArgs + numLocals + numReservedConstants. the first mutable slot available to the compiler.

    maxStackSlots : int = 0

    constants : u64[d_m3MaxConstantTableSize]   // Eden: one 64-bit word per slot (C: m3slot_t, a 64-bit constant spans two)

    // 'wasmStack' holds slot locations
    wasmStack : int[d_m3MaxFunctionStackHeight]
    typeStack : int[d_m3MaxFunctionStackHeight]

    // 'm3Slots' contains allocation usage counts
    m3Slots : int[d_m3MaxFunctionSlots]

    slotMaxAllocatedIndexPlusOne : int = 0

    regStackIndexPlusOne : int[2]

    previousOpcode : m3opcode_t = m3opcode_t(0)

    // Eden: the scope stack (DESIGN.md 4.4a). C keeps the enclosing scopes
    // on the native stack (CompileBlock's `outerScope` local) and links them
    // through `block.outer`; here CompileBlock pushes the enclosing scope on
    // this stack, `_block` stays the current scope and `_block.outer` is the
    // index of the enclosing one (m3_compile pushes and pops). An absent
    // C field.
    scopeStack : array<M3CompilationScope>
}


// Eden: IM3Compilation is not declared; the compilation is rt.compilation.


/* C m3_compile.h: typedef M3Result (* M3Compiler) (IM3Compilation, m3opcode_t); */
// Eden: the compilation is rt.compilation and a compiler needs the runtime's
// arenas and code words, so the IM3Compilation argument is the runtime.
typedef public M3Compiler = function<(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result>


// ============================================================================
// M3Runtime from m3_env.h
// ============================================================================


/* C m3_env.h: typedef struct M3Runtime {...} M3Runtime; */
struct M3Runtime {
    compilation : M3Compilation = M3Compilation()

    environment : M3Environment = M3Environment()   // Eden: an embedded copy of the environment (C: IM3Environment)

    codePages : array<M3CodePage>  // Eden: the code-page arena m3_code manages; pagesOpen, pagesFull and M3CodePageHeader.next index it
    pagesOpen : IM3CodePage = -1   // linked list of code pages with writable space on them
    pagesFull : IM3CodePage = -1   // linked list of at-capacity pages
    pagesReleased : IM3CodePage = -1   // Eden: C's M3Environment.pagesReleased; the page pool moved into the runtime (DESIGN.md 4.1), m3_code manages it

    numCodePages : u32 = 0u
    numActiveCodePages : u32 = 0u

    modules : array<M3Module>      // linked list of imported modules; Eden: the module arena (DESIGN.md 4.1)

    stack : array<u64>             // Eden: the operand stack, one 64-bit word per slot (DESIGN.md 4.3)
    originStack : int = -1         // Eden: index into stack (C: void *), -1 until m3_NewRuntime allocates the stack
    stackSize : u32 = 0u
    numStackSlots : u32 = 0u
    lastCalled : IM3Function = -1  // last function that successfully executed

    userdata : int = -1            // Eden: an integer token (C: void *), -1 = NULL

    memory : M3Memory = M3Memory()
    memoryLimit : u32 = 0u

    // d_m3EnableStrace < 2: callDepth field absent.

    error : M3ErrorInfo = M3ErrorInfo()
    // d_m3VerboseErrorMessages: the C error_message[256] buffer is absent,
    // M3ErrorInfo.message owns its string.

    // d_m3RecordBacktraces == false: backtrace field absent.

    newCodePageSequence : u32 = 0u

    // Eden: arenas (DESIGN.md 4.1); index = handle, -1 = NULL
    funcTypes : array<M3FuncType>  // interned by structural equality (C: the environment's list)
    functions : array<M3Function>  // every function of every module (C: module->functions arrays)
    globals : array<M3Global>      // every global of every module (C: module->globals arrays)
    rawCalls : array<M3RawCall>    // linked host functions (C: the function pointer in a code word)

    // Eden: execution state (DESIGN.md 4.2 - 4.4)
    code : array<u64>              // every compiled word of every function (C: the code pages)
    mem : array<u8>                // linear memory, length(mem) = current size (C: memory.mallocated)
    pc : pc_t = -1                 // C: _pc, index into code
    sp : m3stack_t = -1            // C: _sp, index into stack
    r0 : u64 = 0ul                 // C: _r0
    fp0 : f64 = 0.0lf              // C: _fp0
    trap : M3Result = ""           // the M3Result of the current trap ("" = none)

    // Eden: the in-memory stdio of the WASI layer (DESIGN.md 4.7)
    stdinBuffer : array<u8>        // fd 0 reads from here
    stdoutBuffer : array<u8>       // fd 1 appends here
    stderrBuffer : array<u8>       // fd 2 appends here
}


// ============================================================================
// Typed views of M3Global's shared 8-byte union storage
// ============================================================================


// Eden: the views are arithmetic on valueBits instead of address views; the
// 32-bit members are the low four bytes of the little-endian union.


def public M3Global_GetI32Value(i_global : M3Global) : i32 {
    return i32(u32(i_global.valueBits))
}


def public M3Global_SetI32Value(var i_global : M3Global&; i_value : i32) {
    i_global.valueBits = (i_global.valueBits & 0xffffffff00000000ul) | u64(u32(i_value))
}


def public M3Global_GetI64Value(i_global : M3Global) : i64 {
    return i64(i_global.valueBits)
}


def public M3Global_SetI64Value(var i_global : M3Global&; i_value : i64) {
    i_global.valueBits = u64(i_value)
}


def public M3Global_GetF32Value(i_global : M3Global) : f32 {
    return uint_bits_to_float(u32(i_global.valueBits))
}


def public M3Global_SetF32Value(var i_global : M3Global&; i_value : f32) {
    i_global.valueBits = (i_global.valueBits & 0xffffffff00000000ul) | u64(float_bits_to_uint(i_value))
}


def public M3Global_GetF64Value(i_global : M3Global) : f64 {
    return uint64_bits_to_double(i_global.valueBits)
}


def public M3Global_SetF64Value(var i_global : M3Global&; i_value : f64) {
    i_global.valueBits = double_bits_to_uint64(i_value)
}


// ============================================================================
// m3Error (C m3_core.c / m3_core.h)
// ============================================================================


/*
    Deviation note: C declares m3Error in m3_core.h with forward-declared
    runtime pointers; the Daslang definition needs the concrete runtime
    structures, so it lives in this shared-types module. Active because
    d_m3VerboseErrorMessages is true in the port configuration.

    Eden: the runtime is a reference and cannot be NULL, so the C
    `if (i_runtime)` guard has no counterpart (see the header); module and
    function are handles.
*/

def public m3Error(
                   i_result : M3Result;
                   var i_runtime : M3Runtime;
                   i_module : IM3Module;
                   i_function : IM3Function;
                   i_file : cstr_t;
                   i_lineNum : u32;
                   i_errorMessage : cstr_t
                   ) : M3Result {
    i_runtime.error.result = i_result
    i_runtime.error.runtime = 0   // Eden: this runtime (C: the pointer itself)
    i_runtime.error.moduleIdx = i_module
    i_runtime.error.functionIdx = i_function
    i_runtime.error.file = i_file
    i_runtime.error.line = i_lineNum
    i_runtime.error.message = i_errorMessage
    return i_result
}
