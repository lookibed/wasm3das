options gen2
options indenting = 4

module m3_exec_defs shared public

require modules/wasm3das/source/m3_core public   // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types         // Eden: project-root-relative path (upstream: ./m3_types.das)
require daslib/math_bits                         // Eden: bit casts of the f32/f64 immediates, slots and memory words (DESIGN.md section 4.2)


/*
    Conservative Gen2 port of m3_exec_defs.h.

    The C header defines the threaded-interpreter ABI through preprocessor
    macros. The Daslang port spells the effective signature out once and
    keeps it identical for every operation:

        C d_m3BaseOpSig   ->  _pc : pc_t; _sp : m3stack_t; _mem : M3MemoryHeader?; _r0 : m3reg_t
        C d_m3OpSig       ->  d_m3BaseOpSig with f64 _fp0 appended (d_m3HasFloat is active)
        C d_m3OpArgs      ->  _sp, _mem, _r0, _fp0
        C d_m3OpAllArgs   ->  _pc, _sp, _mem, _r0, _fp0
        C d_m3RetSig      ->  M3Result

    Adaptation note: C op returns are m3ret_t (const void*), where a non-NULL
    value is the M3Result error string pointer. Daslang strings cannot be
    smuggled through a void? payload safely, so operations return M3Result
    directly: m3Err_none == success, any other string == trap. This matches
    every C return shape in the interpreter core (m3Err_xxx or nextOp
    passthrough).

    Trampoline deviation (docs/execution-design.md). Daslang has no
    M3_MUSTTAIL, so the C shape "every op tail-jumps to the next op" would nest
    one Daslang frame per executed operation. Instead the operation returns to
    a dispatch loop:

        C d_m3OpSig       ->  the same five inputs, taken BY REFERENCE, so the
                              operation updates the dispatcher's state in place
                              exactly where C would have passed the updated
                              values on to the next operation
        C nextOpImpl()    ->  RunLoop (m3_exec.das): run the code at _pc to
        C jumpOpImpl(PC)      completion and return its result, which is what
                              the C macro means once every operation below it
                              tail-jumps
        C nextOpDirect()  ->  return m3Ret_nextOp, the sentinel that tells the
        C jumpOpDirect(PC)    dispatching RunLoop to execute the word at _pc

    The three places where C makes a real (non-tail) call - Call() from op_Call
    and op_CallIndirect, op_Entry and op_Loop - keep calling nextOpImpl, so a
    nested wasm call still nests a bounded number of Daslang frames per wasm
    frame instead of per executed operation.

    Eden: deviations from the upstream port (.upstream/source/m3_exec_defs.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.2 - 4.4).
    The sandbox has no pointers, so the five C registers are fields of the
    runtime and the operation ABI is the handle model:
      - requires are Eden-project-root relative (DESIGN section 6); m3_core
        stays a public re-export; daslib/math_bits supplies the bit casts of
        the f32/f64 immediates, slots and memory words.
      - the operation signature is `M3Op = function<(var rt : M3Runtime) :
        int>` (m3_types, DESIGN section 4.4; C: IM3Operation of this header).
        C's registers are the runtime's fields, with C's names kept in the
        comments: _pc is rt.pc (an index into rt.code), _sp is rt.sp (an
        index into rt.stack), _mem is rt.mem (the bytes) with rt.memory
        (the M3Memory info), _r0 is rt.r0 (u64; C m3reg_t is i64, the
        operations convert) and _fp0 is rt.fp0 (f64). d_m3ClearRegisters is
        the function of that name below.
      - the return protocol replaces both the upstream m3Ret_nextOp sentinel
        and the M3Result return: an operation returns M3_NEXT (continue with
        the word at rt.pc), M3_RETURN (C: `return m3Err_none`, the function
        completed), M3_TRAP (rt.trap holds the M3Result) or a loop pc >= 0
        (C: op_ContinueLoop returning the loop's pc, consumed by op_Loop).
        nextOpDirect and jumpOpDirect take the runtime; newTrap and
        forwardTrap (C: m3_exec.h macros, hosted by the upstream m3_exec.das)
        and retOp live here because they spell the protocol. Nothing is
        compared by pointer identity any more (DESIGN section 4.6).
      - nextOpImpl() is `RunLoop(rt)` and jumpOpImpl(PC) is `rt.pc = PC`
        followed by `RunLoop(rt)`; RunLoop, RunCode (C: the inline function
        at the end of this header, `RunCode (d_m3OpSig) { nextOpDirect(); }`)
        and Call stay in m3_exec, which owns the op table. C passes _pc and
        _sp by value, so a nested call runs on copies; here they are shared
        fields, and the nesting sites (Call, op_Entry, op_Loop) save rt.pc
        and rt.sp before the nested RunLoop and restore them after it.
      - m3MemData, m3MemRuntime and m3MemInfo are absent: the bytes are
        rt.mem, the runtime is `rt` itself and the info is rt.memory. The
        memory accessors load_* / store_* below are the only place bytes of
        the linear memory are assembled (little-endian, no bounds check: the
        operation checks `address + n <= mem_size(rt)` as C does, with C's trap
        string); mem_size(rt) is C's `_mem->length`.
      - the operand readers of C's m3_exec.h (immediate(TYPE), slot(TYPE),
        slot_ptr(TYPE)), which the upstream port declared as [inline]
        functions in m3_exec.das and expanded at their use sites with the
        m3_exec_expand macro pass, are plain functions here (no [inline] in
        the editor's 0.6.3; the call per access is accepted, DESIGN section
        7). immediate_u64 is C's immediate(code_t) (upstream immediate_code);
        the typed readers decode the word per the table of DESIGN section
        4.4 (32-bit values zero-extended into the word, i64/f64 the bits, a
        pc or a handle `u64(int)`); immediate_handle stands for the upstream
        immediate_function / immediate_module / immediate_functype /
        immediate_rawcall and the global address (all handles);
        immediate_slot is the slot offset C reads as immediate(i32).
        Every read is one statement of its own at the use site
        (`let v = immediate_u32(rt)`), never nested in another expression,
        which is what the upstream macro pass guaranteed.
      - slot(TYPE) is split in two: slot_T(rt, off) is the deref of slot
        `off` of the current frame (rt.stack[rt.sp + off]), slot_T(rt) the
        whole macro (the immediate read, then the deref; the same rule as
        an immediate read: the sole side effect of its statement).
        slot_ptr(TYPE) becomes an index: slot_index(rt, off) is
        rt.sp + off, slot_index(rt) reads the offset immediate first, and
        stack_T / set_stack_T read and write rt.stack at a saved index.
        A slot is one 64-bit word (DESIGN section 4.3): the 32-bit setters
        write the whole word, zero-extended, because the word is the slot
        and no other value shares it (a 64-bit value's second slot is the
        NEXT word, untouched); a 64-bit read of a slot last written 32-bit
        therefore yields the zero-extended value where C would read four
        stale bytes of the neighbour slot, which no operation does.
        The i8/u8/i16/u16 slot views of the upstream port have no user in
        the operations and are not declared.
    Everything else (names, the C header's structure, the trap strings)
    is unchanged.
*/


// ============================================================================
// Memory accessors
// ============================================================================


// C spells these three as preprocessor macros over the M3MemoryHeader that
// precedes the malloc'd linear memory. Eden: the header is absent (m3_types);
// the bytes are rt.mem, the runtime is `rt` and the info is rt.memory.

/* C: #define m3MemData(mem) (u8*)(((M3MemoryHeader*)(mem))+1) */
// Eden: absent. The bytes are rt.mem; load_* / store_* below read and write
// them (DESIGN.md section 4.2).

/* C: #define m3MemRuntime(mem) (((M3MemoryHeader*)(mem))->runtime) */
// Eden: absent. The runtime is `rt`, the operation's own argument.

/* C: #define m3MemInfo(mem) (&(((M3MemoryHeader*)(mem))->runtime->memory)) */
// Eden: absent. The info is rt.memory (M3Memory: numPages, maxPages, pageSize).


// Eden: C's `_mem->length` (M3MemoryHeader.length, the size of the linear
// memory in bytes), which every load, store and bulk-memory operation checks
// its address against
[inline]
def public mem_size(rt : M3Runtime) : int {
    return length(rt.mem)
}


// Eden: the loads assemble the little-endian value from the bytes at `at`
// (C: a memcpy of sizeof (TYPE) bytes into a TYPE, then the register-width
// cast the operation applies). No bounds check: the operation tests
// `address + n <= mem_size(rt)` first, as C's m3MemCheck does.

[inline]
def public load_u8(rt : M3Runtime; at : int) : u8 {
    return rt.mem[at]
}


[inline]
def public load_s8(rt : M3Runtime; at : int) : i8 {
    return i8(rt.mem[at])
}


[inline]
def public load_u16(rt : M3Runtime; at : int) : u16 {
    // Eden: assembled in u32, gen2 has no arithmetic on 16-bit storage types
    let b0 = u32(rt.mem[at])
    let b1 = u32(rt.mem[at + 1])
    return u16(b0 | (b1 << 8u))
}


[inline]
def public load_s16(rt : M3Runtime; at : int) : i16 {
    return i16(load_u16(rt, at))
}


[inline]
def public load_u32(rt : M3Runtime; at : int) : u32 {
    let b0 = u32(rt.mem[at])
    let b1 = u32(rt.mem[at + 1])
    let b2 = u32(rt.mem[at + 2])
    let b3 = u32(rt.mem[at + 3])
    return b0 | (b1 << 8u) | (b2 << 16u) | (b3 << 24u)
}


[inline]
def public load_i32(rt : M3Runtime; at : int) : i32 {
    return i32(load_u32(rt, at))
}


[inline]
def public load_u64(rt : M3Runtime; at : int) : u64 {
    let lo = u64(load_u32(rt, at))
    let hi = u64(load_u32(rt, at + 4))
    return lo | (hi << 32ul)
}


[inline]
def public load_i64(rt : M3Runtime; at : int) : i64 {
    return i64(load_u64(rt, at))
}


[inline]
def public load_f32(rt : M3Runtime; at : int) : f32 {
    return uint_bits_to_float(load_u32(rt, at))
}


[inline]
def public load_f64(rt : M3Runtime; at : int) : f64 {
    return uint64_bits_to_double(load_u64(rt, at))
}


// Eden: the stores scatter the value little-endian into the bytes at `at`
// (C: a memcpy of sizeof (TYPE) bytes from the narrowed value). A signed
// value is stored through its unsigned width: store_u32(rt, at, u32(v)).

[inline]
def public store_u8(var rt : M3Runtime; at : int; v : u8) {
    rt.mem[at] = v
}


[inline]
def public store_u16(var rt : M3Runtime; at : int; v : u16) {
    let bits = u32(v)
    rt.mem[at] = u8(bits)
    rt.mem[at + 1] = u8(bits >> 8u)
}


[inline]
def public store_u32(var rt : M3Runtime; at : int; v : u32) {
    rt.mem[at] = u8(v)
    rt.mem[at + 1] = u8(v >> 8u)
    rt.mem[at + 2] = u8(v >> 16u)
    rt.mem[at + 3] = u8(v >> 24u)
}


[inline]
def public store_u64(var rt : M3Runtime; at : int; v : u64) {
    store_u32(rt, at, u32(v))
    store_u32(rt, at + 4, u32(v >> 32ul))
}


[inline]
def public store_f32(var rt : M3Runtime; at : int; v : f32) {
    store_u32(rt, at, float_bits_to_uint(v))
}


[inline]
def public store_f64(var rt : M3Runtime; at : int; v : f64) {
    store_u64(rt, at, double_bits_to_uint64(v))
}


// ============================================================================
// Operation ABI
// ============================================================================


/* C: typedef m3ret_t (vectorcall * IM3Operation) (d_m3OpSig); */
// Eden: `M3Op = function<(var rt : M3Runtime) : int>`, declared in m3_types
// next to M3RawCall because the runtime's op table refers to it (DESIGN.md
// section 4.4). The five registers of d_m3OpSig are the runtime's fields:
//     C _pc   ->  rt.pc      C _sp   ->  rt.sp      C _mem  ->  rt.mem
//     C _r0   ->  rt.r0      C _fp0  ->  rt.fp0


/* C: # define d_m3ClearRegisters d_m3ExpClearRegisters (_fp0 = 0.;) — _r0 = 0; _fp0 = 0.; */
// Eden: the registers are fields, so the macro is a function of the runtime
[inline]
def public d_m3ClearRegisters(var rt : M3Runtime) {
    rt.r0 = 0ul        // C: _r0 = 0
    rt.fp0 = 0.0lf     // C: _fp0 = 0.
}


/*
    The return protocol (DESIGN.md section 4.4). C's m3ret_t is a const void*
    that is NULL (the function completed), an error string (a trap) or the pc
    of a loop (op_ContinueLoop, consumed by op_Loop's `while (r == _pc)`);
    the upstream port added the m3Ret_nextOp sentinel for "dispatch the word
    at _pc" and told the cases apart by pointer identity. Eden: an operation
    returns an int; the three named values are negative and distinct, any
    value >= 0 is a loop pc, and the trap string travels in rt.trap.
*/

// Eden: continue with the word at rt.pc (C: the tail jump of nextOpDirect /
// jumpOpDirect; upstream: m3Ret_nextOp)
let public M3_NEXT : m3ret_t = -1

// Eden: the function completed normally (C: `return m3Err_none`, a NULL m3ret_t)
let public M3_RETURN : m3ret_t = -2

// Eden: a trap; rt.trap holds the M3Result (C: the error string as the m3ret_t)
let public M3_TRAP : m3ret_t = -3


// RunLoop, the trampoline that stands in for C's M3_MUSTTAIL threading, and
// nextOpImpl, jumpOpImpl and RunCode, which enter it, live in m3_exec.das with
// the operations and the op table:
//     C nextOpImpl()     ->  RunLoop(rt)                 (runs from rt.pc)
//     C jumpOpImpl(PC)   ->  rt.pc = PC; RunLoop(rt)
//     C RunCode          ->  RunLoop(rt)
// RunLoop reads rt.code[rt.pc], advances rt.pc, invokes the operation and
// repeats while the result is M3_NEXT; any other value is returned to the
// nesting site (Call, op_Entry, op_Loop).

// C: #define nextOpDirect() M3_MUSTTAIL return nextOpImpl()
// The operation has already written rt.pc/rt.sp/rt.r0/rt.fp0, so the tail
// jump is a return to the dispatching loop, which reads the word at rt.pc.
// Eden: `rt` is taken for the uniform spelling of every tail position; it is
// not read.
[inline]
def public nextOpDirect(var rt : M3Runtime) : m3ret_t {
    return M3_NEXT
}


// C: #define jumpOpDirect(PC) M3_MUSTTAIL return jumpOpImpl((pc_t)(PC))
// Only the branch target has to be handed over; the dispatching loop reads
// the word at the new rt.pc.
[inline]
def public jumpOpDirect(var rt : M3Runtime; PC : pc_t) : m3ret_t {
    rt.pc = PC
    return M3_NEXT
}


// C: `return m3Err_none` from an operation (op_Return): the function's code
// completed, control goes back to the nesting site's RunLoop caller.
// Eden: `rt` is taken for the uniform spelling; it is not read.
[inline]
def public retOp(var rt : M3Runtime) : m3ret_t {
    return M3_RETURN
}


// C m3_exec.h: #define newTrap(err) return err — d_m3RecordBacktraces is
// false, so the pushBacktraceFrame() half of the recording form is compiled
// out. Eden: the trap string is recorded in the runtime and the protocol
// value returned (upstream: `return err`, the string itself).
[inline]
def public newTrap(var rt : M3Runtime; err : M3Result) : m3ret_t {
    rt.trap = err
    return M3_TRAP
}


// C m3_exec.h: #define forwardTrap(err) return err — the result of a nested
// call (Call, nextOpImpl) passed on unchanged: M3_RETURN, M3_TRAP (rt.trap
// already set by the operation that trapped) or a loop pc.
[inline]
def public forwardTrap(err : m3ret_t) : m3ret_t {
    return err
}


// C m3_exec.h: forwardTrap (err) of an M3Result — op_CallRawFunction returns
// the host function's result as the operation's m3ret_t: NULL (m3Err_none)
// means the function completed, anything else is the trap. Eden: the
// M3Result form of forwardTrap maps that onto the protocol.
[inline]
def public forwardTrap(var rt : M3Runtime; err : M3Result) : m3ret_t {
    if (m3ResultIsError(err)) {
        return newTrap(rt, err)
    }
    return M3_RETURN
}


// ============================================================================
// Operand readers (C m3_exec.h: immediate / slot / slot_ptr)
// ============================================================================


/*
    C spells the operand readers as preprocessor macros in m3_exec.h:

        #define immediate(TYPE)     * ((TYPE *) _pc++)
        #define slot_ptr(TYPE)      (TYPE *)   (_sp + immediate (i32))
        #define slot(TYPE)          * (TYPE *) (_sp + immediate (i32))

    Eden: plain functions over rt.code and rt.stack (the header lists the
    mapping). Each immediate reader is the C macro written out once: one
    read of rt.code[rt.pc], one advance of rt.pc, one result. At the use
    site a read is a statement of its own (`let off = immediate_u32(rt)`),
    never an argument of another call, because the order in which daslang
    evaluates the arguments of a call is not the order C's `_pc++` side
    effects need.
*/


/* C: immediate (code_t) — the raw word (upstream: immediate_code) */
[inline]
def public immediate_u64(var rt : M3Runtime) : u64 {
    let value = rt.code[rt.pc]
    rt.pc++
    return value
}


/* C: immediate (u32) — Eden: the low 32 bits of the word (a 32-bit value is
   zero-extended into its word, DESIGN.md section 4.4) */
[inline]
def public immediate_u32(var rt : M3Runtime) : u32 {
    let value = u32(rt.code[rt.pc])
    rt.pc++
    return value
}


/* C: immediate (i32) — Eden: the low 32 bits of the word, sign as stored */
[inline]
def public immediate_i32(var rt : M3Runtime) : i32 {
    let value = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return value
}


/* C: immediate (i64) — Eden: the bits of the word */
[inline]
def public immediate_i64(var rt : M3Runtime) : i64 {
    let value = i64(rt.code[rt.pc])
    rt.pc++
    return value
}


/* C: immediate (f32) — Eden: the low 32 bits of the word are the float's bits */
[inline]
def public immediate_f32(var rt : M3Runtime) : f32 {
    let value = uint_bits_to_float(u32(rt.code[rt.pc]))
    rt.pc++
    return value
}


/* C: immediate (f64) — Eden: the bits of the word */
[inline]
def public immediate_f64(var rt : M3Runtime) : f64 {
    let value = uint64_bits_to_double(rt.code[rt.pc])
    rt.pc++
    return value
}


/* C: immediate (pc_t) — Eden: an index into rt.code stored as u64(int), so a
   null pc (-1) round-trips (upstream: immediate_pc) */
[inline]
def public immediate_pc(var rt : M3Runtime) : pc_t {
    let value = int(rt.code[rt.pc])
    rt.pc++
    return value
}


/* C: immediate (IM3Function) / (IM3Module) / (IM3FuncType) / (M3RawCall) and
   the global's address — Eden: a handle into the runtime's arena stored as
   u64(int), -1 = NULL (upstream: immediate_function, immediate_module,
   immediate_functype, immediate_rawcall, immediate_code for a global) */
[inline]
def public immediate_handle(var rt : M3Runtime) : int {
    let value = int(rt.code[rt.pc])
    rt.pc++
    return value
}


/* C: immediate (i32) inside slot () and slot_ptr () — the slot offset of an
   operand, in slots, relative to _sp; Eden: the same decode as immediate_i32,
   named for its use */
[inline]
def public immediate_slot(var rt : M3Runtime) : int {
    let value = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return value
}


/* C: _pc++ without a read (an operation that skips an operand it does not
   use); Eden: the advance alone */
[inline]
def public skip_immediate(var rt : M3Runtime) {
    rt.pc++
}


// ----------------------------------------------------------------------------
// C: slot_ptr (TYPE) — the address of an operand slot, kept for a later
// read or write. Eden: an index into rt.stack (DESIGN.md section 4.3).
// ----------------------------------------------------------------------------


/* C: _sp + off — the index of slot `off` of the current frame */
[inline]
def public slot_index(rt : M3Runtime; off : int) : int {
    return rt.sp + off
}


/* C: slot_ptr (TYPE) — the offset immediate, then the index (upstream:
   slot_ptr_u32 ... slot_ptr_f64; the type is the accessor's, below) */
[inline]
def public slot_index(var rt : M3Runtime) : int {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return rt.sp + off
}


// Eden: the typed views of the word at a saved index (C: `* ptr` through the
// slot_ptr (TYPE) pointer). One place per type decodes the word; the 32-bit
// views are the low 32 bits.

[inline]
def public stack_u32(rt : M3Runtime; idx : int) : u32 {
    return u32(rt.stack[idx])
}


[inline]
def public stack_i32(rt : M3Runtime; idx : int) : i32 {
    return i32(u32(rt.stack[idx]))
}


[inline]
def public stack_u64(rt : M3Runtime; idx : int) : u64 {
    return rt.stack[idx]
}


[inline]
def public stack_i64(rt : M3Runtime; idx : int) : i64 {
    return i64(rt.stack[idx])
}


[inline]
def public stack_f32(rt : M3Runtime; idx : int) : f32 {
    return uint_bits_to_float(u32(rt.stack[idx]))
}


[inline]
def public stack_f64(rt : M3Runtime; idx : int) : f64 {
    return uint64_bits_to_double(rt.stack[idx])
}


// Eden: the typed writes of the word at a saved index (C: `* ptr = value`).
// A 32-bit write is the whole word, zero-extended (see the header).

[inline]
def public set_stack_u32(var rt : M3Runtime; idx : int; v : u32) {
    rt.stack[idx] = u64(v)
}


[inline]
def public set_stack_i32(var rt : M3Runtime; idx : int; v : i32) {
    rt.stack[idx] = u64(u32(v))
}


[inline]
def public set_stack_u64(var rt : M3Runtime; idx : int; v : u64) {
    rt.stack[idx] = v
}


[inline]
def public set_stack_i64(var rt : M3Runtime; idx : int; v : i64) {
    rt.stack[idx] = u64(v)
}


[inline]
def public set_stack_f32(var rt : M3Runtime; idx : int; v : f32) {
    rt.stack[idx] = u64(float_bits_to_uint(v))
}


[inline]
def public set_stack_f64(var rt : M3Runtime; idx : int; v : f64) {
    rt.stack[idx] = double_bits_to_uint64(v)
}


// ----------------------------------------------------------------------------
// C: slot (TYPE) — the operand itself. Eden: slot_T(rt, off) is the deref
// half (slot `off` of the current frame), slot_T(rt) the whole macro (the
// offset immediate, then the deref); set_slot_T likewise for a write.
//
// Every reader and writer of this file is [inline], as its C original is a
// macro: in the daslang interpreter a call costs more than the work of
// these bodies, and the operations live in another module, where the
// compiler's automatic inlining does not reach. The one-argument forms
// (slot_T(rt), set_slot_T(rt, v), slot_index(rt)) are written out as leaves
// (the immediate read, the advance, the stack word) instead of calling the
// other readers: daslang 0.6.4 refuses a nested [inline] call taking the
// `var rt` parameter after a statement of the outer body ("local reference
// to non-local expression is unsafe", outside `unsafe`).
// ----------------------------------------------------------------------------


[inline]
def public slot_u32(rt : M3Runtime; off : int) : u32 {
    return stack_u32(rt, slot_index(rt, off))
}


[inline]
def public slot_u32(var rt : M3Runtime) : u32 {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return u32(rt.stack[rt.sp + off])
}


[inline]
def public slot_i32(rt : M3Runtime; off : int) : i32 {
    return stack_i32(rt, slot_index(rt, off))
}


[inline]
def public slot_i32(var rt : M3Runtime) : i32 {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return i32(u32(rt.stack[rt.sp + off]))
}


[inline]
def public slot_u64(rt : M3Runtime; off : int) : u64 {
    return stack_u64(rt, slot_index(rt, off))
}


[inline]
def public slot_u64(var rt : M3Runtime) : u64 {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return rt.stack[rt.sp + off]
}


[inline]
def public slot_i64(rt : M3Runtime; off : int) : i64 {
    return stack_i64(rt, slot_index(rt, off))
}


[inline]
def public slot_i64(var rt : M3Runtime) : i64 {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return i64(rt.stack[rt.sp + off])
}


[inline]
def public slot_f32(rt : M3Runtime; off : int) : f32 {
    return stack_f32(rt, slot_index(rt, off))
}


[inline]
def public slot_f32(var rt : M3Runtime) : f32 {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return uint_bits_to_float(u32(rt.stack[rt.sp + off]))
}


[inline]
def public slot_f64(rt : M3Runtime; off : int) : f64 {
    return stack_f64(rt, slot_index(rt, off))
}


[inline]
def public slot_f64(var rt : M3Runtime) : f64 {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    return uint64_bits_to_double(rt.stack[rt.sp + off])
}


/* C: slot (TYPE) = value — the write through the macro (upstream:
   `slot_ptr_T(_pc, _sp)[0] = value`) */

[inline]
def public set_slot_u32(var rt : M3Runtime; off : int; v : u32) {
    set_stack_u32(rt, slot_index(rt, off), v)
}


[inline]
def public set_slot_u32(var rt : M3Runtime; v : u32) {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    rt.stack[rt.sp + off] = u64(v)
}


[inline]
def public set_slot_i32(var rt : M3Runtime; off : int; v : i32) {
    set_stack_i32(rt, slot_index(rt, off), v)
}


[inline]
def public set_slot_i32(var rt : M3Runtime; v : i32) {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    rt.stack[rt.sp + off] = u64(u32(v))
}


[inline]
def public set_slot_u64(var rt : M3Runtime; off : int; v : u64) {
    set_stack_u64(rt, slot_index(rt, off), v)
}


[inline]
def public set_slot_u64(var rt : M3Runtime; v : u64) {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    rt.stack[rt.sp + off] = v
}


[inline]
def public set_slot_i64(var rt : M3Runtime; off : int; v : i64) {
    set_stack_i64(rt, slot_index(rt, off), v)
}


[inline]
def public set_slot_i64(var rt : M3Runtime; v : i64) {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    rt.stack[rt.sp + off] = u64(v)
}


[inline]
def public set_slot_f32(var rt : M3Runtime; off : int; v : f32) {
    set_stack_f32(rt, slot_index(rt, off), v)
}


[inline]
def public set_slot_f32(var rt : M3Runtime; v : f32) {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    rt.stack[rt.sp + off] = u64(float_bits_to_uint(v))
}


[inline]
def public set_slot_f64(var rt : M3Runtime; off : int; v : f64) {
    set_stack_f64(rt, slot_index(rt, off), v)
}


[inline]
def public set_slot_f64(var rt : M3Runtime; v : f64) {
    let off = i32(u32(rt.code[rt.pc]))
    rt.pc++
    rt.stack[rt.sp + off] = double_bits_to_uint64(v)
}
