options gen2
options indenting = 4
options no_global_variables = false

module m3_core shared public

require modules/wasm3das/source/wasm3_defs public   // Eden: project-root-relative path (upstream: ./wasm3_defs.das)
require modules/wasm3das/source/m3_config           // Eden: M3_SIZEOF_PTR for Is64BitType (C: m3_core.h includes m3_config.h)
require strings
require daslib/math_bits                            // Eden: bit casts of the float readers (DESIGN.md section 4.2)



/*
    m3_core.das

    Core types, error/trap infrastructure, allocation helpers and binary
    Wasm parsing utilities for the wasm3 port.

    В оригинальном wasm3:

        typedef const char * M3Result;

    NULL означает success.
    Любая другая строка означает error/trap.

    В pure Daslang вместо NULL string используется пустая строка:

        m3Err_none == ""

    Это позволяет сохранить практически ту же модель:

        M3Result result = ...
        if (result != m3Err_none) {
            return result
        }

    ВАЖНО:

        WebAssembly trap != Daslang panic.

    Trap является нормальным результатом выполнения wasm-функции,
    который должен подняться вверх до runtime boundary.

    panic используется только для внутренних фатальных ошибок самого
    порта/interpreter-а.

    Eden: deviations from the upstream port (.upstream/source/m3_core.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md). The sandbox has no
    raw pointers, no address-taking and no bit reinterpretation of its own;
    every pointer of the upstream port is an index here (DESIGN section 4).
      - requires are Eden-project-root relative (DESIGN section 6);
        wasm3_defs stays a public re-export; m3_config is required for
        M3_SIZEOF_PTR (C's m3_core.h includes m3_config.h), and
        daslib/math_bits supplies the bit casts of the float readers.
      - byte cursors: every reader that in C takes
        (o_value, bytes_t * io_bytes, cbytes_t i_end) takes
        (bytes : array<uint8>; var o_value : T&; var io_pos : int&; i_end : int):
        the source array first, then the C parameters in C order, positions
        as indices into that array. The bounds checks are C's
        (`io_pos + n <= i_end`), the error strings are C's. The upstream
        guard "cursor already beyond the end is m3Err_wasmOverrun" is kept
        (m3_check_read, ReadLebUnsigned, ReadLebSigned); the upstream
        null-cursor guard becomes a negative-index guard (an index has no
        null). The upstream helper m3_ptr_addr has no counterpart: the
        address of a cursor is the index itself.
      - fixed-width reads assemble the value from the bytes little-endian
        by arithmetic (wasm is little-endian by definition), so the host
        byte order is never observed and the M3_BIG_ENDIAN swap of the
        upstream port (C: M3_BSWAP_u32 / M3_BSWAP_u64 after memcpy) is not
        needed; f32 / f64 go through uint_bits_to_float /
        uint64_bits_to_double of daslib/math_bits; ReadLebSigned converts
        its bit pattern with i64(), a width-preserving cast.
      - pointer-typed aliases (DESIGN section 4.4, 4.3): bytes_t and
        cbytes_t are `int` (a byte index into a module's wasm array), pc_t
        is `int` (an index into rt.code), code_t is `u64` (one code word of
        rt.code), m3stack_t is `int` (an index into rt.stack), m3ret_t is
        `int` (the return protocol of an operation: M3_NEXT / M3_RETURN /
        M3_TRAP / a loop pc). The readers below use plain `int` positions,
        as the contract above says. voidptr_t (C: const void *) has no
        user in the port and is removed. cstr_t / ccstr_t stay `string`.
      - M3CodePageHeader.next and IM3CodePage are handles (`int`, -1 = null)
        into the code-page arena that m3_code owns; M3CodePage.code is the
        index in rt.code of the page's first word (C: the words themselves
        start at code[0]).
      - allocation: m3_Malloc_Impl, m3_Realloc_Impl, m3_Free_Impl and
        m3_CopyMem keep their names and C order as generic functions over
        `array<T>` (the array is the allocation, its length the size in
        elements, the element type what C's sizeof scaled by). The C macro
        family expands at each call site as upstream does:
        m3_AllocArray(STRUCT, NUM) -> m3_Malloc_Impl(arr, NUM),
        m3_ReallocArray(STRUCT, PTR, NEW, OLD) -> m3_Realloc_Impl(arr, NEW, OLD),
        m3_Free(P) -> m3_Free_Impl(arr), m3_Malloc(NAME, SIZE) and
        m3_Realloc(NAME, PTR, NEW, OLD) drop NAME (d_m3LogHeapOps is off);
        m3_AllocStruct(STRUCT) is `STRUCT()`, a value. C's zero fill is the
        element default `T()`, so a handle field declared `= -1` starts
        null (DESIGN section 4.1). Allocation cannot fail observably (the
        language panics when out of memory), so the C null checks after
        these calls have no counterpart. The private byte helpers of the
        upstream port (m3_zero_bytes, m3_copy_bytes, m3_mem_chunk_max) have
        none either. `resize` is not used on arrays of structs: the 0.6.3
        build refuses it for a struct with field initializers, so growing is
        reserve + push(T()) (emplace(T()) for an element type that cannot be
        copied, i.e. a struct holding an array, such as the arena structs of
        m3_types) and shrinking is pop.
      - the native stack diagnostics m3StackCheckInit / m3StackCheck /
        m3StackGetMax take the address of a local in C and upstream; the
        sandbox cannot, and d_m3LogNativeStack is off, so they are the C
        `#else` branch of m3_core.h: two empty functions and 0.
      - Is64BitType's pointer case reads M3_SIZEOF_PTR (m3_config) instead
        of typeinfo sizeof of a pointer type; the value is the same.
      - the [inline] annotation of m3ResultIsOk, m3ResultIsError and
        m3_Yield is dropped: it does not exist in the editor's 0.6.3.
    Everything else (names, order, control flow, the error table,
    M3ValueType, the sanity limits, m3_Yield, the timestamp, NormalizeType
    and the type predicates) is unchanged.
*/


// ============================================================================
// Short scalar types
// ============================================================================


typedef public u64 = uint64
typedef public i64 = int64

typedef public u32 = uint
typedef public i32 = int

typedef public u16 = uint16
typedef public i16 = int16

typedef public u8 = uint8
typedef public i8 = int8

typedef public f64 = double
typedef public f32 = float


// ============================================================================
// Core wasm3 scalar aliases
// ============================================================================


typedef public m3opcode_t = u16

/*
    Original wasm3:

        typedef i64 m3reg_t;
*/

typedef public m3reg_t = i64


/*
    wasm3 default:

        d_m3Use32BitSlots = 1

    therefore:

        typedef u32 m3slot_t;
*/

typedef public m3slot_t = u32


/*
    Raw stack pointer.

    Пока практически не нужен m3_math_utils,
    но понадобится m3_exec.

    Eden: an index into rt.stack (DESIGN.md section 4.3), not a pointer.
*/

typedef public m3stack_t = int   // Eden: C `m3slot_t *` is an index into rt.stack


// ============================================================================
// Pointer/string aliases
// ============================================================================


/*
    C:

        typedef const void * m3ret_t;
        typedef const void * voidptr_t;
        typedef const char * cstr_t;
        typedef const char * const ccstr_t;

    Daslang не нуждается в C const-pointer qualifiers в этой форме.

    Eden: m3ret_t is the return protocol of an operation (DESIGN.md
    section 4.4: M3_NEXT, M3_RETURN, M3_TRAP or a loop pc), an int.
    voidptr_t has no user in the port and is not declared.
*/

typedef public m3ret_t = int   // Eden: the operation return protocol, DESIGN.md 4.4

typedef public cstr_t = string
typedef public ccstr_t = string

typedef public bytes_t = int    // Eden: C `const u8 *` is a byte index into a wasm array (DESIGN.md 4.4)
typedef public cbytes_t = int   // Eden: same, C's `const u8 * const`


// ============================================================================
// Code-page types (m3_core.h)
// ============================================================================


/*
    C m3_core.h:

        typedef void * code_t;
        typedef code_t const * pc_t;

    Раньше эти типы жили в m3_code.das; перенесены сюда, потому что в C
    они объявлены в m3_core.h, а m3_types.das (общий слой типов) не может
    требовать m3_code.das без цикла в графе модулей.

    Eden: a code word is a u64 of rt.code and a pc is an index into it
    (DESIGN.md section 4.4).
*/

/* C: typedef void * code_t; */
typedef public code_t = u64   // Eden: one word of rt.code (an op index or an immediate)

/* C: typedef code_t const * pc_t; */
typedef public pc_t = int   // Eden: an index into rt.code


struct M3CodePageHeader {
    next : int = -1   // Eden: handle of the next page in the m3_code arena (C: M3CodePage *), -1 = null

    lineIndex : u32
    numLines : u32
    sequence : u32        // this is just used for debugging; could be removed
    usageCount : u32

    // d_m3RecordBacktraces == false: поле mapping отсутствует, слой
    // backtrace ещё не портирован.
}


struct M3CodePage {
    info : M3CodePageHeader = M3CodePageHeader()   // Eden: a field of a struct with initializers must be initialized
    code : int = -1   // Eden: index in rt.code of the page's first word (C: `code_t code[1]`, the words start here)

    /*
        Объявленное одноэлементное поле сохраняет C-имя/порядок полей и
        якорит code[0] ровно на границе заголовка. NewCodePage выделяет
        больше сырых байт после первого элемента, поэтому индексация за
        пределами code[0] выполняется через pc_t, а не через fixed-array тип.

        Eden: the words live in rt.code (DESIGN.md section 4.4); `code` is
        where this page's words begin, and pc_t values are indices past it.
    */
}


typedef public IM3CodePage = int   // Eden: handle into the code-page arena (C: M3CodePage *), -1 = null


/* C m3_core.h: #define d_m3CodePageFreeLinesThreshold 4+2 — max is: select _sss & CallIndirect + 2 for bridge */
let public d_m3CodePageFreeLinesThreshold : u32 = 4u + 2u


// ============================================================================
// M3Result
// ============================================================================


/*
    Оригинальный M3Result — const char *.

    Для Daslang сохраняем string representation.

    "" == success
    everything else == error
*/

typedef public M3Result = string


let public m3Err_none : M3Result = ""


// ============================================================================
// General errors
// ============================================================================


let public m3Err_mallocFailed : M3Result = "memory allocation failed"


// ============================================================================
// Parse errors
// ============================================================================


let public m3Err_incompatibleWasmVersion : M3Result = "incompatible Wasm binary version"

let public m3Err_wasmMalformed : M3Result = "malformed Wasm binary"

let public m3Err_misorderedWasmSection : M3Result = "out of order Wasm section"

let public m3Err_wasmUnderrun : M3Result = "underrun while parsing Wasm binary"

let public m3Err_wasmOverrun : M3Result = "overrun while parsing Wasm binary"

let public m3Err_wasmMissingInitExpr : M3Result = "missing init_expr in Wasm binary"

let public m3Err_lebOverflow : M3Result = "LEB encoded value overflow"

let public m3Err_missingUTF8 : M3Result = "invalid length UTF-8 string"

let public m3Err_wasmSectionUnderrun : M3Result = "section underrun while parsing Wasm binary"

let public m3Err_wasmSectionOverrun : M3Result = "section overrun while parsing Wasm binary"

let public m3Err_invalidTypeId : M3Result = "unknown value_type"

let public m3Err_tooManyMemorySections : M3Result = "only one memory per module is supported"

let public m3Err_tooManyArgsRets : M3Result = "too many arguments or return values"


// ============================================================================
// Link errors
// ============================================================================


let public m3Err_moduleNotLinked : M3Result = "attempting to use module that is not loaded"

let public m3Err_moduleAlreadyLinked : M3Result = "attempting to bind module to multiple runtimes"

let public m3Err_functionLookupFailed : M3Result = "function lookup failed"

let public m3Err_functionImportMissing : M3Result = "missing imported function"

let public m3Err_malformedFunctionSignature : M3Result = "malformed function signature"


// ============================================================================
// Compilation errors
// ============================================================================


let public m3Err_noCompiler : M3Result = "no compiler found for opcode"

let public m3Err_unknownOpcode : M3Result = "unknown opcode"

let public m3Err_restrictedOpcode : M3Result = "restricted opcode"

let public m3Err_functionStackOverflow : M3Result = "compiling function overran its stack height limit"

let public m3Err_functionStackUnderrun : M3Result = "compiling function underran the stack"

let public m3Err_mallocFailedCodePage : M3Result = "memory allocation failed when acquiring a new M3 code page"

let public m3Err_settingImmutableGlobal : M3Result = "attempting to set an immutable global"

let public m3Err_typeMismatch : M3Result = "incorrect type on stack"

let public m3Err_typeCountMismatch : M3Result = "incorrect value count on stack"


// ============================================================================
// Runtime errors
// ============================================================================


let public m3Err_missingCompiledCode : M3Result = "function is missing compiled m3 code"

let public m3Err_wasmMemoryOverflow : M3Result = "runtime ran out of memory"

let public m3Err_globalMemoryNotAllocated : M3Result = "global memory is missing from a module"

/*
    Имя намеренно оставлено как в оригинальном wasm3:
    globaIndexOutOfBounds (без 'l').
*/

let public m3Err_globaIndexOutOfBounds : M3Result = "global index is too large"

let public m3Err_argumentCountMismatch : M3Result = "argument count mismatch"

let public m3Err_argumentTypeMismatch : M3Result = "argument type mismatch"

let public m3Err_globalLookupFailed : M3Result = "global lookup failed"

let public m3Err_globalTypeMismatch : M3Result = "global type mismatch"

let public m3Err_globalNotMutable : M3Result = "global is not mutable"


// ============================================================================
// WebAssembly traps
// ============================================================================


let public m3Err_trapOutOfBoundsMemoryAccess : M3Result = "[trap] out of bounds memory access"

let public m3Err_trapDivisionByZero : M3Result = "[trap] integer divide by zero"

let public m3Err_trapIntegerOverflow : M3Result = "[trap] integer overflow"

let public m3Err_trapIntegerConversion : M3Result = "[trap] invalid conversion to integer"

let public m3Err_trapIndirectCallTypeMismatch : M3Result = "[trap] indirect call type mismatch"

let public m3Err_trapTableIndexOutOfRange : M3Result = "[trap] undefined element"

let public m3Err_trapTableElementIsNull : M3Result = "[trap] null table element"

let public m3Err_trapExit : M3Result = "[trap] program called exit"

let public m3Err_trapAbort : M3Result = "[trap] program called abort"

let public m3Err_trapUnreachable : M3Result = "[trap] unreachable executed"

let public m3Err_trapStackOverflow : M3Result = "[trap] stack overflow"


// ============================================================================
// Result helpers
// ============================================================================


// C tests an M3Result against NULL (`if (r)`, `if (!r)`): one pointer test.
// The port's M3Result is a string and m3Err_none is "", which every daslang
// tier represents as the null pointer (the AOT/ctx emitter writes `nullptr`
// for an empty constant, the interpreter, the JIT and the string builder
// produce null for an empty string). `empty(result)` is that test, AGENTS.md's
// spelling for C's `== NULL`, and not the content comparison `result ==
// m3Err_none` would be. The helpers are `empty` itself: the daslang
// interpreter evaluates the builtin as one node, where the open-coded
// pointer-and-first-byte test (`p == null || *p == 0u8`) splices a binding,
// two comparisons and a dereference into every call site and cost fib(30) about 8 % on the interpreter tier. The LLVM JIT reaches
// the runtime's string `empty` through a function pointer (llvm_jit_intrin.das
// lowers `empty` only for arrays and tables); measured on the exe tier the
// open-coded test gained about 3 % on fib(35) and lost about 3 % of the
// CoreMark score, so the interpreter's spelling is the one kept.
// Eden: no [inline]; the annotation does not exist in the editor's 0.6.3
def public m3ResultIsOk(result : M3Result) : bool {
    return empty(result)
}


// Eden: no [inline]; the annotation does not exist in the editor's 0.6.3
def public m3ResultIsError(result : M3Result) : bool {
    return !empty(result)
}



// ============================================================================
// Internal fatal/assert helpers
// ============================================================================


/*
    m3_Abort is a fatal interpreter error, not a WebAssembly trap.
*/

def public m3_Abort(message : string) {
    panic("wasm3: {message}")
}


/*
    C d_m3Assert is a conditional macro: assert() under DEBUG, nothing in a
    Release build. Eden: d_m3EnableAssertions (m3_config) is the DEBUG
    switch; it is off, as in the Release C wasm3 the port is measured
    against (docs/wasm-features). d_m3Check is the port's own invariant
    check (the op table, test fixtures), always on.
*/

def public d_m3Assert(
                      condition : bool;
                      message : string = "wasm3 assertion failed"
                      ) {
    if (d_m3EnableAssertions && !condition) {
        panic("wasm3: {message}")
    }
}


def public d_m3Check(
                     condition : bool;
                     message : string = "wasm3das invariant failed"
                     ) {
    if (!condition) {
        panic("wasm3: {message}")
    }
}


// ============================================================================
// Core constants
// ============================================================================


let public d_m3DefaultMemPageSize = 65536

let public d_m3Reg0SlotAlias = 60000
let public d_m3Fp0SlotAlias = d_m3Reg0SlotAlias + 2


let public d_m3MaxSaneTypesCount = 1000000
let public d_m3MaxSaneFunctionsCount = 1000000
let public d_m3MaxSaneImportsCount = 100000
let public d_m3MaxSaneExportsCount = 100000
let public d_m3MaxSaneGlobalsCount = 1000000

let public d_m3MaxSaneElementSegments = 10000000
let public d_m3MaxSaneDataSegments = 100000
let public d_m3MaxSaneTableSize = 10000000

let public d_m3MaxSaneUtf8Length = 10000

let public d_m3MaxSaneFunctionArgRetCount = 1000


// ============================================================================
// External kinds
// ============================================================================


let public d_externalKind_function : u8 = 0u8
let public d_externalKind_table : u8 = 1u8
let public d_externalKind_memory : u8 = 2u8
let public d_externalKind_global : u8 = 3u8


// ============================================================================
// Wasm value types
// ============================================================================


enum public M3ValueType {
    c_m3Type_none    = 0
    c_m3Type_i32     = 1
    c_m3Type_i64     = 2
    c_m3Type_f32     = 3
    c_m3Type_f64     = 4
    c_m3Type_v128    = 5
    c_m3Type_unknown = 6
}



// ============================================================================
// m3_core.c
// Ported through Read_utf8. Backtrace code intentionally starts after this file.
// ============================================================================


// M3_WEAK is a linker attribute in C and has no pure Daslang equivalent.
// [inline] because the body is `return m3Err_none` (d_m3Yield is not defined)
// and Call() runs it once per wasm call: a C compiler inlines it, the daslang
// interpreter would evaluate a call node per wasm call instead.
// Eden: no [inline]; the annotation does not exist in the editor's 0.6.3
def public m3_Yield() : M3Result {
    return m3Err_none
}


// ============================================================================
// Timestamp support
// ============================================================================


/*
    The C implementation only compiles this when d_m3LogTimestamps is enabled.
    Keeping the function available is harmless and avoids a parallel
    preprocessor/configuration system.

    ref_time_ticks() is the Daslang runtime monotonic nanosecond clock.
*/

var private initial_ts : i64 = -1l


def public m3_GetTimestamp() : u64 {
    let now_us = ref_time_ticks() / 1000l

    if (initial_ts < 0l) {
        initial_ts = now_us
        let after_init_us = ref_time_ticks() / 1000l
        return u64(after_init_us - initial_ts)
    }

    return u64(now_us - initial_ts)
}


// ============================================================================
// Memory allocation
// ============================================================================


/*
    wasm3's normal configuration has d_m3FixedHeap == false. The C-only
    d_m3FixedHeap compile-time branch is therefore not reproduced as a runtime
    switch here. Doing so would create a second configuration system before
    m3_config itself is ported.

    Eden: an allocation is an array<T> (DESIGN.md section 4.1): the array is
    the block, its length the size in elements, the element type what C's
    sizeof scaled by. The helpers below keep the C names and parameter
    order; the byte-copying helpers of the upstream port are not needed
    because elements are assigned, not copied byte-wise. Allocation cannot
    fail observably, so nothing returns null.

    `resize` is deliberately not used: the 0.6.3 build refuses it for an
    array of structs with field initializers. Growing is reserve + push of
    the element default `T()` (C's zero fill; a handle field declared `= -1`
    starts null), shrinking is pop. An element type that cannot be copied
    (a struct holding an array, as the arena structs of m3_types do) is
    moved in with emplace instead; static_if picks the form per type.
*/


/* C: void * m3_Malloc_Impl (size_t i_size) — calloc (i_size, 1) */
def public m3_Malloc_Impl(var o_array : array<auto(T)>; i_size : int) {
    // Eden: a fresh zero-filled block is an array of i_size default elements
    clear(o_array)
    reserve(o_array, i_size)
    for (i in range(i_size)) {
        // Eden: an element that holds an array (M3Module, M3FuncType, ...)
        // cannot be copied, so it is moved in; scalars and plain structs
        // cannot be moved in, so they are pushed
        static_if (typeinfo can_copy(type<T>)) {
            push(o_array, T())
        } else {
            emplace(o_array, T())
        }
    }
}


// ============================================================================
// Allocation macro family (m3_core.h)
// ============================================================================


/* C m3_core.h macro family: m3_Free(P) expands to m3_Free_Impl((void*)(P))
   plus (P) = NULL, m3_ReallocArray adds sizeof(STRUCT) scaling. The macros are
   expanded at each call site: Daslang function values cannot express the
   in-place NULL-ing generically without clashing with string fields, which the
   port resets to empty (strings own their storage; C frees malloc'd chars).
   Eden: the array is the pointer, so m3_Free_Impl empties it in place and
   the `(P) = NULL` half of the macro needs no separate step; sizeof(STRUCT)
   scaling is the array's element type. */

/* C: #define m3_ReallocArray(STRUCT, PTR, NEW, OLD) expands to a sized
   m3_Realloc_Impl call at each use site (sizeof(STRUCT) scaling).
   Eden: m3_Realloc_Impl(arr, NEW, OLD) with NEW and OLD in elements. */


/* C: void m3_Free_Impl (void * io_ptr) — free (io_ptr) */
def public m3_Free_Impl(var io_ptr : array<auto(T)>) {
    // Eden: an empty array is the null pointer. delete finalizes the
    // elements and hands the buffer back to the context heap (clear kept the
    // capacity, so a freed stack, linear memory or module binary stayed
    // allocated for the life of the process); the array is left empty, C's
    // "free then NULL" observable state (length 0). A delete of an array
    // value, not of a pointer: safe, and not the new/delete of M3* data that
    // DESIGN forbids.
    delete io_ptr
}


/* C: void * m3_Realloc_Impl (void * i_ptr, size_t i_newSize, size_t i_oldSize) */
def public m3_Realloc_Impl(
                           var i_ptr : array<auto(T)>;
                           i_newSize : int;
                           i_oldSize : int
                           ) {
    if (M3_UNLIKELY(i_newSize == i_oldSize)) {
        return
    }

    // Eden: realloc in place; the array keeps its first min(old, new)
    // elements as C's realloc keeps the block's bytes
    while (length(i_ptr) > i_newSize) {
        pop(i_ptr)
    }

    /*
        C zero-fills the grown tail (memset from i_oldSize): the pushed
        default elements are that fill.
    */

    reserve(i_ptr, i_newSize)
    while (length(i_ptr) < i_newSize) {
        // Eden: push or move in, by element type, as in m3_Malloc_Impl
        static_if (typeinfo can_copy(type<T>)) {
            push(i_ptr, T())
        } else {
            emplace(i_ptr, T())
        }
    }
}


/* C: void * m3_CopyMem (const void * i_from, size_t i_size) */
def public m3_CopyMem(i_from : array<auto(T)>; i_size : int) : array<T> {
    var ptr : array<T>
    m3_Malloc_Impl(ptr, i_size)

    // C: if (ptr) memcpy (ptr, i_from, i_size); Eden: the first i_size elements
    for (i in range(i_size)) {
        ptr[i] = i_from[i]
    }

    return <- ptr
}


// ============================================================================
// Native stack diagnostics
// ============================================================================


/*
    The C build exposes these only with d_m3LogNativeStack.
    Daslang keeps the same functions available; callers decide whether to use
    the diagnostic. No platform API or WASI dependency is involved.

    Eden: C and the upstream port measure the native stack through the
    address of a local, which the sandbox cannot take. d_m3LogNativeStack is
    off (m3_config), so these are the C `#else` branch of m3_core.h:
    m3StackCheckInit() and m3StackCheck() expand to nothing and
    m3StackGetMax() to 0. The names stay so m3_env and m3_exec call them as
    C does.
*/


def public m3StackCheckInit() {
    pass   // Eden: C `#define m3StackCheckInit()`
}


def public m3StackCheck() {
    pass   // Eden: C `#define m3StackCheck()`
}


def public m3StackGetMax() : int {
    return 0   // Eden: C `#define m3StackGetMax() 0`
}


// ============================================================================
// Type normalization and predicates
// ============================================================================


def public NormalizeType(
                         var o_type : u8&;
                         i_convolutedWasmType : i8
                         ) : M3Result {
    var result = m3Err_none

    var normalized_type = u8(-i32(i_convolutedWasmType))

    if (normalized_type == 0x40u8) {
        normalized_type = u8(M3ValueType.c_m3Type_none)
    } elif (
        u32(normalized_type) < u32(M3ValueType.c_m3Type_i32) ||
        u32(normalized_type) > u32(M3ValueType.c_m3Type_v128)
    ) {
        result = m3Err_invalidTypeId
    }

    o_type = normalized_type
    return result
}


def public IsFpType(i_m3Type : u8) : bool {
    return (
        i_m3Type == u8(M3ValueType.c_m3Type_f32) ||
        i_m3Type == u8(M3ValueType.c_m3Type_f64)
    )
}


def public IsIntType(i_m3Type : u8) : bool {
    return (
        i_m3Type == u8(M3ValueType.c_m3Type_i32) ||
        i_m3Type == u8(M3ValueType.c_m3Type_i64)
    )
}


def public Is64BitType(i_m3Type : u8) : bool {
    if (
        i_m3Type == u8(M3ValueType.c_m3Type_i64) ||
        i_m3Type == u8(M3ValueType.c_m3Type_f64)
    ) {
        return true
    } elif (
        i_m3Type == u8(M3ValueType.c_m3Type_i32) ||
        i_m3Type == u8(M3ValueType.c_m3Type_f32) ||
        i_m3Type == u8(M3ValueType.c_m3Type_none)
    ) {
        return false
    }

    // C: sizeof (voidptr_t) == 8, all other cases are pointers
    return M3_SIZEOF_PTR == 8u   // Eden: the configured pointer size instead of typeinfo sizeof of a pointer type
}


def public SizeOfType(i_m3Type : u8) : u32 {
    if (
        i_m3Type == u8(M3ValueType.c_m3Type_i32) ||
        i_m3Type == u8(M3ValueType.c_m3Type_f32)
    ) {
        return 4u
    }

    return 8u
}


// ============================================================================
// Binary Wasm parsing utils
// ============================================================================


/*
    Eden: the upstream helper m3_ptr_addr (pointer -> integer address) has
    no counterpart; a cursor is an index into the source array, so the
    address is the index itself.
*/


def private m3_check_read(
                          io_pos : int;
                          i_end : int;
                          i_size : int
                          ) : M3Result {
    // Eden: the upstream null-cursor test; an index before the array is
    // the null cursor
    if (i_size != 0 && io_pos < 0) {
        return m3Err_wasmUnderrun
    }

    /*
        A cursor already beyond the declared end is an overrun. A cursor at or
        before the end which lacks i_size bytes is the ordinary wasm underrun
        used by the original Read_* routines.
    */

    if (io_pos > i_end) {
        return m3Err_wasmOverrun
    }

    // C: `ptr += n; if (ptr <= i_end)` else m3Err_wasmUnderrun
    if (io_pos + i_size > i_end) {
        return m3Err_wasmUnderrun
    }

    return m3Err_none
}


def public Read_u64(
                    bytes : array<uint8>;
                    var o_value : u64&;
                    var io_pos : int&;
                    i_end : int
                    ) : M3Result {
    let result = m3_check_read(io_pos, i_end, 8)

    if (result != m3Err_none) {
        return result
    }

    var value : u64 = 0ul

    // Eden: C memcpy + M3_BSWAP_u64; the little-endian value is assembled
    // directly, so no host byte-order swap is needed
    for (i in range(8)) {
        value |= u64(bytes[io_pos + i]) << u64(i * 8)
    }
    io_pos += 8

    o_value = value
    return m3Err_none
}


def public Read_u32(
                    bytes : array<uint8>;
                    var o_value : u32&;
                    var io_pos : int&;
                    i_end : int
                    ) : M3Result {
    let result = m3_check_read(io_pos, i_end, 4)

    if (result != m3Err_none) {
        return result
    }

    var value : u32 = 0u

    // Eden: C memcpy + M3_BSWAP_u32; the little-endian value is assembled
    // directly, so no host byte-order swap is needed
    for (i in range(4)) {
        value |= u32(bytes[io_pos + i]) << u32(i * 8)
    }
    io_pos += 4

    o_value = value
    return m3Err_none
}


/*
    d_m3ImplementFloat is a C compile-time feature switch. f32/f64 are already
    part of the accepted m3_core.das type layer, so both readers are present.
*/

def public Read_f64(
                    bytes : array<uint8>;
                    var o_value : f64&;
                    var io_pos : int&;
                    i_end : int
                    ) : M3Result {
    var bits : u64 = 0ul
    let result = Read_u64(bytes, bits, io_pos, i_end)

    if (result != m3Err_none) {
        return result
    }

    o_value = uint64_bits_to_double(bits)   // Eden: daslib/math_bits, DESIGN.md 4.2

    return m3Err_none
}


def public Read_f32(
                    bytes : array<uint8>;
                    var o_value : f32&;
                    var io_pos : int&;
                    i_end : int
                    ) : M3Result {
    var bits : u32 = 0u
    let result = Read_u32(bytes, bits, io_pos, i_end)

    if (result != m3Err_none) {
        return result
    }

    o_value = uint_bits_to_float(bits)   // Eden: daslib/math_bits, DESIGN.md 4.2

    return m3Err_none
}


def public Read_u8(
                   bytes : array<uint8>;
                   var o_value : u8&;
                   var io_pos : int&;
                   i_end : int
                   ) : M3Result {
    let result = m3_check_read(io_pos, i_end, 1)

    if (result != m3Err_none) {
        return result
    }

    o_value = bytes[io_pos]
    io_pos = io_pos + 1

    return m3Err_none
}


def public Read_opcode(
                       bytes : array<uint8>;
                       var o_value : m3opcode_t&;
                       var io_pos : int&;
                       i_end : int
                       ) : M3Result {
    /*
        wasm3's default d_m3CascadedOpcodes is 1. In that configuration the
        #if d_m3CascadedOpcodes == 0 block in m3_core.c is not compiled and an
        opcode read consumes exactly one byte. We preserve that active source
        configuration instead of inventing a runtime preprocessor flag here.
    */

    var opcode : u8 = 0u8
    let result = Read_u8(bytes, opcode, io_pos, i_end)

    if (result != m3Err_none) {
        return result
    }

    o_value = m3opcode_t(opcode)
    return m3Err_none
}


def public ReadLebUnsigned(
                           bytes : array<uint8>;
                           var o_value : u64&;
                           i_maxNumBits : u32;
                           var io_pos : int&;
                           i_end : int
                           ) : M3Result {
    var result = m3Err_wasmUnderrun
    var value : u64 = 0ul
    var shift : u32 = 0u

    var ptr = io_pos

    // Eden: the upstream null-cursor test; an index before the array is
    // the null cursor
    if (ptr < 0) {
        o_value = value
        return m3Err_wasmUnderrun
    }

    if (ptr > i_end) {
        o_value = value
        return m3Err_wasmOverrun
    }

    while (ptr < i_end) {
        var byte : u64 = 0ul

        byte = u64(bytes[ptr])
        ptr = ptr + 1

        value |= (byte & 0x7ful) << u64(shift)
        shift += 7u

        if ((byte & 0x80ul) == 0ul) {
            result = m3Err_none
            break
        }

        if (shift >= i_maxNumBits) {
            result = m3Err_lebOverflow
            break
        }
    }

    o_value = value
    io_pos = ptr

    return result
}


def public ReadLebSigned(
                         bytes : array<uint8>;
                         var o_value : i64&;
                         i_maxNumBits : u32;
                         var io_pos : int&;
                         i_end : int
                         ) : M3Result {
    var result = m3Err_wasmUnderrun
    var value_bits : u64 = 0ul
    var shift : u32 = 0u

    var ptr = io_pos

    // Eden: the upstream null-cursor test; an index before the array is
    // the null cursor
    if (ptr < 0) {
        o_value = 0l
        return m3Err_wasmUnderrun
    }

    if (ptr > i_end) {
        o_value = 0l
        return m3Err_wasmOverrun
    }

    while (ptr < i_end) {
        var byte : u64 = 0ul

        byte = u64(bytes[ptr])
        ptr = ptr + 1

        value_bits |= (byte & 0x7ful) << u64(shift)
        shift += 7u

        if ((byte & 0x80ul) == 0ul) {
            result = m3Err_none

            if ((byte & 0x40ul) != 0ul && shift < 64u) {
                value_bits |= ~0ul << u64(shift)
            }

            break
        }

        if (shift >= i_maxNumBits) {
            result = m3Err_lebOverflow
            break
        }
    }

    o_value = i64(value_bits)   // Eden: a width-preserving cast, C's `i64 value` holds the same bits

    io_pos = ptr
    return result
}


def public ReadLEB_u32(
                       bytes : array<uint8>;
                       var o_value : u32&;
                       var io_pos : int&;
                       i_end : int
                       ) : M3Result {
    var value : u64 = 0ul
    let result = ReadLebUnsigned(bytes, value, 32u, io_pos, i_end)

    o_value = u32(value)
    return result
}


def public ReadLEB_u7(
                      bytes : array<uint8>;
                      var o_value : u8&;
                      var io_pos : int&;
                      i_end : int
                      ) : M3Result {
    var value : u64 = 0ul
    let result = ReadLebUnsigned(bytes, value, 7u, io_pos, i_end)

    o_value = u8(value)
    return result
}


def public ReadLEB_i7(
                      bytes : array<uint8>;
                      var o_value : i8&;
                      var io_pos : int&;
                      i_end : int
                      ) : M3Result {
    var value : i64 = 0l
    let result = ReadLebSigned(bytes, value, 7u, io_pos, i_end)

    o_value = i8(value)
    return result
}


def public ReadLEB_i32(
                       bytes : array<uint8>;
                       var o_value : i32&;
                       var io_pos : int&;
                       i_end : int
                       ) : M3Result {
    var value : i64 = 0l
    let result = ReadLebSigned(bytes, value, 32u, io_pos, i_end)

    o_value = i32(value)
    return result
}


def public ReadLEB_i64(
                       bytes : array<uint8>;
                       var o_value : i64&;
                       var io_pos : int&;
                       i_end : int
                       ) : M3Result {
    var value : i64 = 0l
    let result = ReadLebSigned(bytes, value, 64u, io_pos, i_end)

    o_value = value
    return result
}


def public Read_utf8(
                     bytes : array<uint8>;
                     var o_utf8 : cstr_t&;
                     var io_pos : int&;
                     i_end : int
                     ) : M3Result {
    o_utf8 = ""

    var utf8Length : u32 = 0u
    let length_result = ReadLEB_u32(bytes, utf8Length, io_pos, i_end)

    if (length_result != m3Err_none) {
        return length_result
    }

    if (utf8Length > u32(d_m3MaxSaneUtf8Length)) {
        return m3Err_missingUTF8
    }

    let payload_result = m3_check_read(io_pos, i_end, int(utf8Length))

    if (payload_result != m3Err_none) {
        return payload_result
    }

    var utf8_bytes : array<u8>
    m3_Malloc_Impl(utf8_bytes, int(utf8Length))   // C: m3_Malloc ("UTF8", utf8Length + 1)

    // C: memcpy (utf8, ptr, utf8Length); * io_bytes = end
    for (i in range(int(utf8Length))) {
        utf8_bytes[i] = bytes[io_pos + i]
    }
    io_pos += int(utf8Length)

    o_utf8 = string(utf8_bytes)
    delete utf8_bytes

    return m3Err_none
}


/*
    Backtrace functions from the following #if d_m3RecordBacktraces block in
    m3_core.c are intentionally not ported in this stage.
*/
