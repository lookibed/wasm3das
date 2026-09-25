options gen2
options indenting = 4

module m3_api_defs shared public

require modules/wasm3das/source/m3_env public         // Eden: project-root-relative path (upstream: ./m3_env.das)
require modules/wasm3das/source/m3_exec_defs public   // Eden: the load_* / store_* / stack_* accessors (DESIGN.md sections 4.2, 4.5)
require strings                                       // Eden: string (array<uint8>) and character_at for the byte helpers


/*
    Port of the m3Api* macro family of wasm3.h (lines 347-385) that host
    functions (m3_api_libc.c, m3_api_wasi.c) use to read their arguments and
    the linear memory.

    C macros work on the raw-function parameters by name: `_sp` is advanced
    with `_sp++` as arguments are consumed, `_mem` is the linear memory base,
    `runtime` gives the memory size. The port spells every macro as a
    function; the raw function keeps its own cursor:

        def m3_libc_memset(runtime : IM3Runtime; _ctx : IM3ImportContext; var _sp : u64?; var _mem : void?) : M3Result {
            var sp = _sp
            var raw_return = m3ApiReturnType(sp)        // m3ApiReturnType (int32_t)
            var i_ptr = m3ApiGetArgMem(sp, _mem)       // m3ApiGetArgMem (void*, i_ptr)
            let i_value = m3ApiGetArg_i32(sp)          // m3ApiGetArg (int32_t, i_value)
            let i_size = m3ApiGetArg_u32(sp)           // m3ApiGetArg (uint32_t, i_size)
            let check = m3ApiCheckMem(runtime, _mem, i_ptr, u64(i_size))
            if (check != m3Err_none) { return check }  // m3ApiCheckMem traps
            ...
            m3ApiReturn_i32(raw_return, i32(result))   // m3ApiReturn (result)
            return m3Err_none
        }

    m3ApiTrap(VALUE) is `return VALUE`, m3ApiSuccess() is `return m3Err_none`.
    Little-endian hosts only: the M3_BIG_ENDIAN branch of the ReadMem/WriteMem
    macros is not represented (as everywhere in this port).

    Eden: deviations from the upstream port (.upstream/source/m3_api_defs.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.2, 4.5,
    4.6). The sandbox has no pointers: the stack is rt.stack, the memory is
    rt.mem, and a host function is an M3RawCall value
    `(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result`:
      - the requires are Eden-project-root relative (DESIGN section 6);
        m3_env stays a public re-export and m3_exec_defs is re-exported too,
        because the host functions use its load_* / store_* accessors.
      - m3ApiRawFunction(NAME) is that M3RawCall parameter list (C:
        `runtime, _ctx, _sp, _mem`): `rt` is the runtime and the memory,
        `ctx` is C's `*_ctx` by value, `sp` is C's `_sp` as an index into
        rt.stack. It stays a naming convention, as upstream.
      - the `_sp` cursor is a value, M3ApiFrame { sp, cur }, built once per
        raw function with `var f = m3ApiFrame(sp)`; every m3Api* helper that
        C writes with `_sp++` takes it `var`. The host frame (DESIGN 4.5) is
        C's: one 64-bit cell per value, results first then the arguments,
        and a cell is TWO slot words of rt.stack (DESIGN 4.3), so the
        cursor steps 2 where C steps one u64. `f.sp` keeps the frame base
        for assertions; nothing reads it.
      - m3ApiReturnType / m3ApiMultiValueReturnType return the INDEX of the
        result cell in rt.stack (C: the TYPE* raw_return pointer). The C
        TYPE is not needed to reserve the cell (a cell is a cell); it is the
        suffix of the m3ApiReturn_* / m3ApiMultiValueReturn_* that writes it.
      - m3ApiReturn_T(rt, raw_return, value) writes the cell and returns
        nothing, as upstream; the caller then `return m3Err_none` (C's
        m3ApiReturn does both). A 32-bit value is written as the whole slot
        word, zero-extended (m3_exec_defs set_stack_*), where C stores four
        bytes and leaves the other four; every reader takes the low 32 bits.
      - m3ApiGetArg_T(rt, f) reads the cell with the m3_exec_defs stack_*
        views (a 32-bit argument is the low 32 bits, as C's `*(TYPE*)_sp`).
        C's narrow-type branch (sizeof(TYPE) < 4: read a uint32_t, then cast)
        is m3ApiGetArg_u8 / m3ApiGetArg_u16.
      - a linear-memory pointer is its OFFSET into rt.mem (int), so
        m3ApiGetArgMem returns the offset (C: `_mem + (uint32_t) offset`),
        m3ApiOffsetToPtr / m3ApiPtrToOffset convert u32 <-> int, and every
        memory access goes through the offset (the m3ApiReadMem* /
        m3ApiWriteMem* functions over load_* / store_*, DESIGN 4.2). An
        offset read from a u32 at or above 2^31 is a negative int here
        (the u32 bits, C cast).
      - m3ApiIsNullPtr(offset) is `offset == 0`: C's `addr <= _mem` for an
        address built as `_mem + (uint32_t) offset` holds exactly at offset
        0. (A negative Eden offset is a u32 at or above 2^31, which C places
        above _mem: not NULL.)
      - m3ApiCheckMem(rt, offset, len) returns the M3Result (C: the macro
        returns from the raw function); the caller writes
        `if (r != m3Err_none) { return r }`, as upstream. C's two tests stay:
        `addr < _mem` is `offset < 0`, and the upper bound is computed in
        u64 against m3_GetMemorySize(rt). A negative offset is also a u32 at
        or above 2^31, which is always out of bounds in Eden because the
        memory is capped at 0x7fffffff bytes (DESIGN section 1, array size
        limit); C traps on it through the upper bound for every memory
        smaller than 2 GiB, so the trap string is the same.
      - m3ApiTrap(VALUE) and m3ApiSuccess() are functions returning the
        M3Result (`return m3ApiTrap(v)`, `return m3ApiSuccess()`); upstream
        spelled them only in comments.
      - added byte helpers for the libc and WASI host functions, which in C
        use the linear memory as a C `char *` (strnlen, memcpy, fwrite):
        m3ApiStrnlen, m3ApiReadBytes, m3ApiReadString, m3ApiWriteBytes,
        m3ApiWriteString. They take an offset and a length already checked
        with m3ApiCheckMem (like C, they do not check again), except
        m3ApiStrnlen, which stops at the end of rt.mem where C's strnlen
        would read past the linear memory (undefined behaviour in C, a
        panic here).
    The example above, in the Eden shape:

        def m3_libc_memset(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
            var f = m3ApiFrame(sp)
            let raw_return = m3ApiReturnType(f)        // m3ApiReturnType (int32_t)
            let i_ptr = m3ApiGetArgMem(rt, f)          // m3ApiGetArgMem (void*, i_ptr)
            let i_value = m3ApiGetArg_i32(rt, f)       // m3ApiGetArg (int32_t, i_value)
            let i_size = m3ApiGetArg_u32(rt, f)        // m3ApiGetArg (uint32_t, i_size)
            let check = m3ApiCheckMem(rt, i_ptr, u64(i_size))
            if (check != m3Err_none) { return check }  // m3ApiCheckMem traps
            ...
            m3ApiReturn_i32(rt, raw_return, i32(result))   // m3ApiReturn (result)
            return m3Err_none
        }

    Everything else (the names, the upstream order, the trap string) is
    unchanged.
*/


// ============================================================================
// The raw-function frame (C: the `_sp` cursor)
// ============================================================================


// C: # define m3ApiRawFunction(NAME)  const void * NAME (IM3Runtime runtime, IM3ImportContext _ctx, uint64_t * _sp, void * _mem)
// Eden: a raw function is an M3RawCall (m3_types):
//     def NAME(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result
// and starts with `var f = m3ApiFrame(sp)`, the cursor C's macros advance.


// Eden: C's `_sp` as a cursor into rt.stack (see the header)
struct M3ApiFrame {
    sp : int = 0    // the frame base, C's `_sp` on entry (first result cell, or first argument of a void function)
    cur : int = 0   // C's `_sp` as the macros advance it
}


// Eden: one C u64 cell of the host frame is two slot words (DESIGN 4.3, 4.5)
let public M3API_CELL_SLOTS = 2


// Eden: the frame of a raw function whose `sp` op_CallRawFunction passed
def public m3ApiFrame(sp : int) : M3ApiFrame {
    return M3ApiFrame(sp = sp, cur = sp)
}


// Eden: C's `_sp++` (one u64 cell); returns the index of the consumed cell
def private m3ApiNextCell(var f : M3ApiFrame) : int {
    let at = f.cur
    f.cur += M3API_CELL_SLOTS
    return at
}


// ============================================================================
// Offsets and pointers
// ============================================================================


// C: # define m3ApiOffsetToPtr(offset)   (void*)((uint8_t*)_mem + (uint32_t)(offset))
// Eden: the "pointer" is the offset into rt.mem (the u32 bits as an int)
def public m3ApiOffsetToPtr(offset : u32) : int {
    return int(offset)
}


// C: # define m3ApiPtrToOffset(ptr)      (uint32_t)((uint8_t*)ptr - (uint8_t*)_mem)
// Eden: the offset back as the u32 the guest sees
def public m3ApiPtrToOffset(ptr : int) : u32 {
    return u32(ptr)
}


// C: # define m3ApiIsNullPtr(addr)       ((void*)(addr) <= _mem)
// Eden: offset 0 (see the header)
def public m3ApiIsNullPtr(offset : int) : bool {
    return offset == 0
}


// C: # define m3ApiCheckMem(addr, len)   { if (M3_UNLIKELY(((void*)(addr) < _mem) ||
//        ((uint64_t)(uintptr_t)(addr) + (len)) > ((uint64_t)(uintptr_t)(_mem)+m3_GetMemorySize(runtime))))
//        m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess); }
// The caller returns the result when it is not m3Err_none.
// Eden: `addr < _mem` is `offset < 0`, the upper bound is in u64 (see the header)
def public m3ApiCheckMem(rt : M3Runtime; offset : int; len : u64) : M3Result {
    if (offset < 0) {
        return m3Err_trapOutOfBoundsMemoryAccess
    }
    let end = u64(offset) + len
    if (end > u64(m3_GetMemorySize(rt))) {
        return m3Err_trapOutOfBoundsMemoryAccess
    }
    return m3Err_none
}


// ============================================================================
// Stack slots: return value and arguments (each consumes one 64-bit cell)
// ============================================================================


// C: # define m3ApiReturnType(TYPE)                 TYPE* raw_return = ((TYPE*) (_sp++));
// Eden: returns the index of the result cell in rt.stack (see the header)
def public m3ApiReturnType(var f : M3ApiFrame) : int {
    return m3ApiNextCell(f)
}


// C: # define m3ApiMultiValueReturnType(TYPE, NAME) TYPE* NAME = ((TYPE*) (_sp++));
// Eden: as m3ApiReturnType; not in the upstream port (no C host module uses it)
def public m3ApiMultiValueReturnType(var f : M3ApiFrame) : int {
    return m3ApiNextCell(f)
}


// C: # define m3ApiGetArg(TYPE, NAME)  TYPE NAME = (sizeof(TYPE) >= sizeof(uint32_t)) ? (*((TYPE *)(_sp++))) : ...
// Only the instantiations wasm3's host modules use are spelled out.
// Eden: rt first, the cursor `var` (see the header)
def public m3ApiGetArg_i32(rt : M3Runtime; var f : M3ApiFrame) : i32 {
    let at = m3ApiNextCell(f)
    return stack_i32(rt, at)
}


def public m3ApiGetArg_u32(rt : M3Runtime; var f : M3ApiFrame) : u32 {
    let at = m3ApiNextCell(f)
    return stack_u32(rt, at)
}


def public m3ApiGetArg_i64(rt : M3Runtime; var f : M3ApiFrame) : i64 {
    let at = m3ApiNextCell(f)
    return stack_i64(rt, at)
}


def public m3ApiGetArg_u64(rt : M3Runtime; var f : M3ApiFrame) : u64 {
    let at = m3ApiNextCell(f)
    return stack_u64(rt, at)
}


def public m3ApiGetArg_f32(rt : M3Runtime; var f : M3ApiFrame) : f32 {
    let at = m3ApiNextCell(f)
    return stack_f32(rt, at)
}


def public m3ApiGetArg_f64(rt : M3Runtime; var f : M3ApiFrame) : f64 {
    let at = m3ApiNextCell(f)
    return stack_f64(rt, at)
}


// C: the narrow branch of m3ApiGetArg, `((TYPE)(*((uint32_t *)(_sp++))))`
// Eden: added (the upstream port spelled no narrow instantiation; the WASI
// host functions take u8 / u16 flags this way)
def public m3ApiGetArg_u8(rt : M3Runtime; var f : M3ApiFrame) : u8 {
    let at = m3ApiNextCell(f)
    return u8(stack_u32(rt, at))
}


def public m3ApiGetArg_u16(rt : M3Runtime; var f : M3ApiFrame) : u16 {
    let at = m3ApiNextCell(f)
    return u16(stack_u32(rt, at))
}


// C: # define m3ApiGetArgMem(TYPE, NAME)            TYPE NAME = (TYPE)m3ApiOffsetToPtr(* ((uint32_t *) (_sp++)));
// Eden: returns the offset into rt.mem (see the header)
def public m3ApiGetArgMem(rt : M3Runtime; var f : M3ApiFrame) : int {
    let offset = m3ApiGetArg_u32(rt, f)
    return m3ApiOffsetToPtr(offset)
}


// C: # define m3ApiReturn(VALUE)                   { *raw_return = (VALUE); return m3Err_none;}
// The store keeps the C type in the suffix. Eden: `raw_return` is the cell
// index m3ApiReturnType gave; the caller returns m3Err_none (see the header)
def public m3ApiReturn_i32(var rt : M3Runtime; raw_return : int; value : i32) {
    set_stack_i32(rt, raw_return, value)
}


def public m3ApiReturn_u32(var rt : M3Runtime; raw_return : int; value : u32) {
    set_stack_u32(rt, raw_return, value)
}


def public m3ApiReturn_i64(var rt : M3Runtime; raw_return : int; value : i64) {
    set_stack_i64(rt, raw_return, value)
}


def public m3ApiReturn_u64(var rt : M3Runtime; raw_return : int; value : u64) {
    set_stack_u64(rt, raw_return, value)
}


def public m3ApiReturn_f32(var rt : M3Runtime; raw_return : int; value : f32) {
    set_stack_f32(rt, raw_return, value)
}


def public m3ApiReturn_f64(var rt : M3Runtime; raw_return : int; value : f64) {
    set_stack_f64(rt, raw_return, value)
}


// C: # define m3ApiMultiValueReturn(NAME, VALUE)   { *NAME = (VALUE); }
// Eden: not in the upstream port; the same store as m3ApiReturn_T, under
// C's name, for a cell m3ApiMultiValueReturnType gave
def public m3ApiMultiValueReturn_i32(var rt : M3Runtime; name : int; value : i32) {
    set_stack_i32(rt, name, value)
}


def public m3ApiMultiValueReturn_u32(var rt : M3Runtime; name : int; value : u32) {
    set_stack_u32(rt, name, value)
}


def public m3ApiMultiValueReturn_i64(var rt : M3Runtime; name : int; value : i64) {
    set_stack_i64(rt, name, value)
}


def public m3ApiMultiValueReturn_u64(var rt : M3Runtime; name : int; value : u64) {
    set_stack_u64(rt, name, value)
}


def public m3ApiMultiValueReturn_f32(var rt : M3Runtime; name : int; value : f32) {
    set_stack_f32(rt, name, value)
}


def public m3ApiMultiValueReturn_f64(var rt : M3Runtime; name : int; value : f64) {
    set_stack_f64(rt, name, value)
}


// C: # define m3ApiTrap(VALUE)                     { return VALUE; }
// Eden: `return m3ApiTrap(VALUE)`
def public m3ApiTrap(value : M3Result) : M3Result {
    return value
}


// C: # define m3ApiSuccess()                       { return m3Err_none; }
// Eden: `return m3ApiSuccess()`
def public m3ApiSuccess() : M3Result {
    return m3Err_none
}


// ============================================================================
// Linear memory reads and writes (little-endian branch of wasm3.h)
// ============================================================================


// Eden: `ptr` is an offset into rt.mem; the bytes are assembled by the
// m3_exec_defs accessors (DESIGN 4.2). No bounds check, as C: the caller
// ran m3ApiCheckMem.
def public m3ApiReadMem8(rt : M3Runtime; ptr : int) : u8 {
    return load_u8(rt, ptr)
}


def public m3ApiReadMem16(rt : M3Runtime; ptr : int) : u16 {
    return load_u16(rt, ptr)
}


def public m3ApiReadMem32(rt : M3Runtime; ptr : int) : u32 {
    return load_u32(rt, ptr)
}


def public m3ApiReadMem64(rt : M3Runtime; ptr : int) : u64 {
    return load_u64(rt, ptr)
}


def public m3ApiWriteMem8(var rt : M3Runtime; ptr : int; val : u8) {
    store_u8(rt, ptr, val)
}


def public m3ApiWriteMem16(var rt : M3Runtime; ptr : int; val : u16) {
    store_u16(rt, ptr, val)
}


def public m3ApiWriteMem32(var rt : M3Runtime; ptr : int; val : u32) {
    store_u32(rt, ptr, val)
}


def public m3ApiWriteMem64(var rt : M3Runtime; ptr : int; val : u64) {
    store_u64(rt, ptr, val)
}


// ============================================================================
// Eden: byte helpers (C uses the linear memory as a `char *` directly)
// ============================================================================


// Eden: C strnlen (ptr, maxlen) over the linear memory. Also stops at the
// end of rt.mem, where C would read past the linear memory (see the header)
def public m3ApiStrnlen(rt : M3Runtime; ptr : int; maxlen : int) : int {
    var n = 0
    let size = length(rt.mem)
    while (n < maxlen && ptr + n < size && rt.mem[ptr + n] != 0u8) {
        n++
    }
    return n
}


// Eden: a copy of rt.mem[ptr .. ptr + len) (C: the `(ptr, len)` buffer read
// in place). The range was checked with m3ApiCheckMem
def public m3ApiReadBytes(rt : M3Runtime; ptr : int; len : int) : array<u8> {
    var bytes : array<u8>
    resize(bytes, len)
    for (i in range(len)) {
        bytes[i] = rt.mem[ptr + i]
    }
    return <- bytes
}


// Eden: rt.mem[ptr .. ptr + len) as a string (C: the `(ptr, len)` char
// buffer passed to fwrite / printf). The range was checked with m3ApiCheckMem
def public m3ApiReadString(rt : M3Runtime; ptr : int; len : int) : string {
    let bytes <- m3ApiReadBytes(rt, ptr, len)
    return string(bytes)
}


// Eden: copies `bytes` to rt.mem[ptr ..) (C: memcpy into the linear memory).
// The range was checked with m3ApiCheckMem
def public m3ApiWriteBytes(var rt : M3Runtime; ptr : int; bytes : array<u8>) {
    for (b, i in bytes, count()) {
        rt.mem[ptr + i] = b
    }
}


// Eden: copies the bytes of `text` to rt.mem[ptr ..), without a terminating
// NUL (C: memcpy of strlen bytes; a caller that copies the NUL writes it
// with m3ApiWriteMem8). The range was checked with m3ApiCheckMem
def public m3ApiWriteString(var rt : M3Runtime; ptr : int; text : string) {
    for (i in range(length(text))) {
        rt.mem[ptr + i] = u8(character_at(text, i))
    }
}
