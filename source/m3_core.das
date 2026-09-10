options gen2
options indenting = 4
options no_global_variables = false

module m3_core shared public

require ./wasm3_defs.das public
require strings



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
*/

typedef public m3stack_t = m3slot_t?


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
*/

typedef public m3ret_t = void?
typedef public voidptr_t = void?

typedef public cstr_t = string
typedef public ccstr_t = string

typedef public bytes_t = u8?
typedef public cbytes_t = u8?


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
*/

/* C: typedef void * code_t; */
typedef public code_t = void?

/* C: typedef code_t const * pc_t; */
typedef public pc_t = code_t?


struct M3CodePageHeader {
    next : M3CodePage?

    lineIndex : u32
    numLines : u32
    sequence : u32        // this is just used for debugging; could be removed
    usageCount : u32

    // d_m3RecordBacktraces == false: поле mapping отсутствует, слой
    // backtrace ещё не портирован.
}


struct M3CodePage {
    info : M3CodePageHeader
    code : code_t[1]

    /*
        Объявленное одноэлементное поле сохраняет C-имя/порядок полей и
        якорит code[0] ровно на границе заголовка. NewCodePage выделяет
        больше сырых байт после первого элемента, поэтому индексация за
        пределами code[0] выполняется через pc_t, а не через fixed-array тип.
    */
}


typedef public IM3CodePage = M3CodePage?


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


def public m3ResultIsOk(result : M3Result) : bool {
    return result == m3Err_none
}


def public m3ResultIsError(result : M3Result) : bool {
    return result != m3Err_none
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
    C d_m3Assert is a conditional macro. In pure Daslang this helper keeps the
    accepted fail-fast behavior without reproducing the C preprocessor.
*/

def public d_m3Assert(
                      condition : bool;
                      message : string = "wasm3 assertion failed"
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
[inline]
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

    These helpers use Daslang's builtin raw-memory operations. They are language
    runtime builtins, not C interop.
*/

let private m3_mem_chunk_max : u64 = 0x7ffffffful


// `i_ptr` and `i_to` are the destinations of the fill and the copy, so both are
// `var`: the daslang JIT gives a non-`var` pointer parameter the LLVM
// `readonly` attribute (upstream #3991), which folds the caller's read of the
// filled memory from `--jit-opt-level=1` upwards.
def private m3_zero_bytes(var i_ptr : void?; i_size : u64) {
    if (i_ptr == null || i_size == 0ul) {
        return
    }

    unsafe {
        var ptr = reinterpret<u8?>(i_ptr)
        var remaining = i_size

        while (remaining != 0ul) {
            var chunk = remaining
            if (chunk > m3_mem_chunk_max) {
                chunk = m3_mem_chunk_max
            }

            memset8(reinterpret<void?>(ptr), 0u8, int(chunk))
            ptr += int(chunk)
            remaining -= chunk
        }
    }
}


def private m3_copy_bytes(var i_to : void?; i_from : void?; i_size : u64) {
    if (i_size == 0ul) {
        return
    }

    unsafe {
        var dst = reinterpret<u8?>(i_to)
        var src = reinterpret<u8?>(i_from)
        var remaining = i_size

        while (remaining != 0ul) {
            var chunk = remaining
            if (chunk > m3_mem_chunk_max) {
                chunk = m3_mem_chunk_max
            }

            memcpy(
                reinterpret<void?>(dst),
                reinterpret<void?>(src),
                chunk
            )

            dst += int(chunk)
            src += int(chunk)
            remaining -= chunk
        }
    }
}


def public m3_Malloc_Impl(i_size : u64) : void? {
    unsafe {
        var ptr = malloc(i_size)

        if (ptr != null) {
            m3_zero_bytes(ptr, i_size)
        }

        return ptr
    }
}


// ============================================================================
// Allocation macro family (m3_core.h)
// ============================================================================


/* C m3_core.h macro family: m3_Free(P) expands to m3_Free_Impl((void*)(P))
   plus (P) = NULL, m3_ReallocArray adds sizeof(STRUCT) scaling. The macros are
   expanded at each call site: Daslang function values cannot express the
   in-place NULL-ing generically without clashing with string fields, which the
   port resets to empty (strings own their storage; C frees malloc'd chars). */

/* C: #define m3_ReallocArray(STRUCT, PTR, NEW, OLD) expands to a sized
   m3_Realloc_Impl call at each use site (sizeof(STRUCT) scaling). */


def public m3_Free_Impl(i_ptr : void?) {
    if (i_ptr == null) {
        return
    }

    unsafe {
        free(i_ptr)
    }
}


def public m3_Realloc_Impl(
                           i_ptr : void?;
                           i_newSize : u64;
                           i_oldSize : u64
                           ) : void? {
    if (i_newSize == i_oldSize) {
        return i_ptr
    }

    if (i_newSize == 0ul) {
        m3_Free_Impl(i_ptr)
        return null
    }

    var newPtr = m3_Malloc_Impl(i_newSize)

    if (newPtr == null) {
        return null
    }

    if (i_ptr != null) {
        var copySize = i_oldSize
        if (i_newSize < copySize) {
            copySize = i_newSize
        }
        m3_copy_bytes(newPtr, i_ptr, copySize)
        m3_Free_Impl(i_ptr)
    }

    /*
        m3_Malloc_Impl already zeroes the whole new allocation, which is
        equivalent to the C realloc path's explicit zero-fill of the grown tail.
    */

    return newPtr
}


def public m3_CopyMem(i_from : voidptr_t; i_size : u64) : void? {
    var ptr = m3_Malloc_Impl(i_size)

    if (ptr != null && i_size != 0ul) {
        m3_copy_bytes(ptr, i_from, i_size)
    }

    return ptr
}


// ============================================================================
// Native stack diagnostics
// ============================================================================


/*
    The C build exposes these only with d_m3LogNativeStack.
    Daslang keeps the same functions available; callers decide whether to use
    the diagnostic. No platform API or WASI dependency is involved.
*/

var private stack_start : u64 = 0ul
var private stack_end : u64 = 0ul


def public m3StackCheckInit() {
    var stack : u8 = 0u8

    unsafe {
        let addr_value = intptr(addr(stack))
        stack_start = addr_value
        stack_end = addr_value
    }
}


def public m3StackCheck() {
    var stack : u8 = 0u8

    unsafe {
        let addr_value = intptr(addr(stack))

        if (addr_value < stack_end) {
            stack_end = addr_value
        }
    }
}


def public m3StackGetMax() : int {
    return int(stack_start - stack_end)
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

    return typeinfo sizeof(type<void?>) > 4
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


def public m3_ptr_addr(ptr : cbytes_t) : u64 {
    if (ptr == null) {
        return 0ul
    }

    unsafe {
        return intptr(ptr)
    }
}


def private m3_check_read(
                          io_bytes : cbytes_t;
                          i_end : cbytes_t;
                          i_size : u64
                          ) : M3Result {
    if (i_size != 0ul && io_bytes == null) {
        return m3Err_wasmUnderrun
    }

    let pos = m3_ptr_addr(io_bytes)
    let end = m3_ptr_addr(i_end)

    /*
        A cursor already beyond the declared end is an overrun. A cursor at or
        before the end which lacks i_size bytes is the ordinary wasm underrun
        used by the original Read_* routines.
    */

    if (pos > end) {
        return m3Err_wasmOverrun
    }

    if (i_size > end - pos) {
        return m3Err_wasmUnderrun
    }

    return m3Err_none
}


def public Read_u64(
                    var o_value : u64&;
                    var io_bytes : bytes_t&;
                    i_end : cbytes_t
                    ) : M3Result {
    let result = m3_check_read(io_bytes, i_end, 8ul)

    if (result != m3Err_none) {
        return result
    }

    var value : u64 = 0ul

    unsafe {
        memcpy(
            addr<void?>(value),
            reinterpret<void?>(io_bytes),
            8
        )
        io_bytes += 8
    }

    if (M3_BIG_ENDIAN) {
        value = m3_bswap64(value)
    }

    o_value = value
    return m3Err_none
}


def public Read_u32(
                    var o_value : u32&;
                    var io_bytes : bytes_t&;
                    i_end : cbytes_t
                    ) : M3Result {
    let result = m3_check_read(io_bytes, i_end, 4ul)

    if (result != m3Err_none) {
        return result
    }

    var value : u32 = 0u

    unsafe {
        memcpy(
            addr<void?>(value),
            reinterpret<void?>(io_bytes),
            4
        )
        io_bytes += 4
    }

    if (M3_BIG_ENDIAN) {
        value = m3_bswap32(value)
    }

    o_value = value
    return m3Err_none
}


/*
    d_m3ImplementFloat is a C compile-time feature switch. f32/f64 are already
    part of the accepted m3_core.das type layer, so both readers are present.
*/

def public Read_f64(
                    var o_value : f64&;
                    var io_bytes : bytes_t&;
                    i_end : cbytes_t
                    ) : M3Result {
    var bits : u64 = 0ul
    let result = Read_u64(bits, io_bytes, i_end)

    if (result != m3Err_none) {
        return result
    }

    unsafe {
        o_value = reinterpret<f64>(bits)
    }

    return m3Err_none
}


def public Read_f32(
                    var o_value : f32&;
                    var io_bytes : bytes_t&;
                    i_end : cbytes_t
                    ) : M3Result {
    var bits : u32 = 0u
    let result = Read_u32(bits, io_bytes, i_end)

    if (result != m3Err_none) {
        return result
    }

    unsafe {
        o_value = reinterpret<f32>(bits)
    }

    return m3Err_none
}


def public Read_u8(
                   var o_value : u8&;
                   var io_bytes : bytes_t&;
                   i_end : cbytes_t
                   ) : M3Result {
    let result = m3_check_read(io_bytes, i_end, 1ul)

    if (result != m3Err_none) {
        return result
    }

    unsafe {
        o_value = *io_bytes
        io_bytes += 1
    }

    return m3Err_none
}


def public Read_opcode(
                       var o_value : m3opcode_t&;
                       var io_bytes : bytes_t&;
                       i_end : cbytes_t
                       ) : M3Result {
    /*
        wasm3's default d_m3CascadedOpcodes is 1. In that configuration the
        #if d_m3CascadedOpcodes == 0 block in m3_core.c is not compiled and an
        opcode read consumes exactly one byte. We preserve that active source
        configuration instead of inventing a runtime preprocessor flag here.
    */

    var opcode : u8 = 0u8
    let result = Read_u8(opcode, io_bytes, i_end)

    if (result != m3Err_none) {
        return result
    }

    o_value = m3opcode_t(opcode)
    return m3Err_none
}


def public ReadLebUnsigned(
                           var o_value : u64&;
                           i_maxNumBits : u32;
                           var io_bytes : bytes_t&;
                           i_end : cbytes_t
                           ) : M3Result {
    var result = m3Err_wasmUnderrun
    var value : u64 = 0ul
    var shift : u32 = 0u

    var ptr = io_bytes
    let end_addr = m3_ptr_addr(i_end)

    if (ptr == null) {
        o_value = value
        return m3Err_wasmUnderrun
    }

    if (m3_ptr_addr(ptr) > end_addr) {
        o_value = value
        return m3Err_wasmOverrun
    }

    while (m3_ptr_addr(ptr) < end_addr) {
        var byte : u64 = 0ul

        unsafe {
            byte = u64(*ptr)
            ptr += 1
        }

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
    io_bytes = ptr

    return result
}


def public ReadLebSigned(
                         var o_value : i64&;
                         i_maxNumBits : u32;
                         var io_bytes : bytes_t&;
                         i_end : cbytes_t
                         ) : M3Result {
    var result = m3Err_wasmUnderrun
    var value_bits : u64 = 0ul
    var shift : u32 = 0u

    var ptr = io_bytes
    let end_addr = m3_ptr_addr(i_end)

    if (ptr == null) {
        o_value = 0l
        return m3Err_wasmUnderrun
    }

    if (m3_ptr_addr(ptr) > end_addr) {
        o_value = 0l
        return m3Err_wasmOverrun
    }

    while (m3_ptr_addr(ptr) < end_addr) {
        var byte : u64 = 0ul

        unsafe {
            byte = u64(*ptr)
            ptr += 1
        }

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

    unsafe {
        o_value = reinterpret<i64>(value_bits)
    }

    io_bytes = ptr
    return result
}


def public ReadLEB_u32(
                       var o_value : u32&;
                       var io_bytes : bytes_t&;
                       i_end : cbytes_t
                       ) : M3Result {
    var value : u64 = 0ul
    let result = ReadLebUnsigned(value, 32u, io_bytes, i_end)

    o_value = u32(value)
    return result
}


def public ReadLEB_u7(
                      var o_value : u8&;
                      var io_bytes : bytes_t&;
                      i_end : cbytes_t
                      ) : M3Result {
    var value : u64 = 0ul
    let result = ReadLebUnsigned(value, 7u, io_bytes, i_end)

    o_value = u8(value)
    return result
}


def public ReadLEB_i7(
                      var o_value : i8&;
                      var io_bytes : bytes_t&;
                      i_end : cbytes_t
                      ) : M3Result {
    var value : i64 = 0l
    let result = ReadLebSigned(value, 7u, io_bytes, i_end)

    o_value = i8(value)
    return result
}


def public ReadLEB_i32(
                       var o_value : i32&;
                       var io_bytes : bytes_t&;
                       i_end : cbytes_t
                       ) : M3Result {
    var value : i64 = 0l
    let result = ReadLebSigned(value, 32u, io_bytes, i_end)

    o_value = i32(value)
    return result
}


def public ReadLEB_i64(
                       var o_value : i64&;
                       var io_bytes : bytes_t&;
                       i_end : cbytes_t
                       ) : M3Result {
    var value : i64 = 0l
    let result = ReadLebSigned(value, 64u, io_bytes, i_end)

    o_value = value
    return result
}


def public Read_utf8(
                     var o_utf8 : cstr_t&;
                     var io_bytes : bytes_t&;
                     i_end : cbytes_t
                     ) : M3Result {
    o_utf8 = ""

    var utf8Length : u32 = 0u
    let length_result = ReadLEB_u32(utf8Length, io_bytes, i_end)

    if (length_result != m3Err_none) {
        return length_result
    }

    if (utf8Length > u32(d_m3MaxSaneUtf8Length)) {
        return m3Err_missingUTF8
    }

    let payload_result = m3_check_read(io_bytes, i_end, u64(utf8Length))

    if (payload_result != m3Err_none) {
        return payload_result
    }

    var utf8_bytes : array<u8>
    resize(utf8_bytes, int(utf8Length))

    if (utf8Length != 0u) {
        unsafe {
            memcpy(
                addr<void?>(utf8_bytes[0]),
                reinterpret<void?>(io_bytes),
                utf8Length
            )
            io_bytes += int(utf8Length)
        }
    }

    o_utf8 = string(utf8_bytes)
    delete utf8_bytes

    return m3Err_none
}


/*
    Backtrace functions from the following #if d_m3RecordBacktraces block in
    m3_core.c are intentionally not ported in this stage.
*/
