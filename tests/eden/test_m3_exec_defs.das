options gen2
options indenting = 4

module test_m3_exec_defs shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_exec_defs
require modules/wasm3das/source/m3_types
require daslib/math_bits

/*
    test_m3_exec_defs.das: the Eden tests of source/m3_exec_defs.das.

    There is no upstream test file for this module (the upstream
    m3_exec_defs.das held two macro-shaped [inline] accessors and the
    dispatcher sentinel, and its operand readers lived in m3_exec.das, whose
    tests run whole functions). The accessors of DESIGN.md sections 4.2 - 4.4
    are tested directly here, against a runtime built by hand:
      - the return protocol: the three named values are negative and
        distinct, nextOpDirect leaves rt.pc alone, jumpOpDirect sets it,
        retOp is M3_RETURN, newTrap records the trap string, forwardTrap
        passes an int through (a loop pc included) and maps an M3Result;
      - every immediate reader advances rt.pc by exactly one word and
        decodes the encoding of DESIGN section 4.4 (a negative i32 and i64,
        f32 and f64 bit patterns with a NaN payload, a pc and a null pc, a
        handle and a null handle, a slot offset), and skip_immediate only
        advances;
      - every slot accessor reads and writes the word rt.stack[rt.sp + off]
        (a negative offset included): a 32-bit write is the whole word,
        zero-extended (the choice the header of m3_exec_defs documents), a
        64-bit value in slot i leaves slot i + 1 alone, f32/f64 keep their
        bits, slot_index / stack_T / set_stack_T work with a saved index,
        and the combined forms read the offset immediate first;
      - every memory accessor assembles little-endian bytes and scatters
        them back: round trips at unaligned offsets for every width, the
        sign extension of s8 / s16 / i32 through the register-width cast,
        f32/f64 bits kept, neighbours untouched, mem_size following resize.
    Every value is compared by its bits (float_bits_to_uint /
    double_bits_to_uint64), so a NaN payload is checked exactly.
*/


// ============================================================================
// Helpers
// ============================================================================


// a code word, as m3_code's EmitWord leaves it in rt.code
def private emit(var rt : M3Runtime; word : u64) {
    push(rt.code, word)
}


// a runtime whose stack is `slots` words of the sentinel (every bit set),
// so a write that touches fewer bits than a word is visible
def private stack_runtime(slots : int; sp : int) : M3Runtime {
    var rt = M3Runtime()
    resize(rt.stack, slots)
    for (i in range(slots)) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    rt.sp = sp
    return <- rt
}


// a runtime whose linear memory is `size` bytes of 0xcc
def private mem_runtime(size : int) : M3Runtime {
    var rt = M3Runtime()
    resize(rt.mem, size)
    for (i in range(size)) {
        rt.mem[i] = 0xccu8
    }
    return <- rt
}


def private bits_f32(v : f32) : u32 {
    return float_bits_to_uint(v)
}


def private bits_f64(v : f64) : u64 {
    return double_bits_to_uint64(v)
}


def private as_f32(bits : u32) : f32 {
    return uint_bits_to_float(bits)
}


def private as_f64(bits : u64) : f64 {
    return uint64_bits_to_double(bits)
}


// ============================================================================
// Return protocol
// ============================================================================


def test_return_protocol(var t : TestRun; fx : FixtureSource) {
    check(t, M3_NEXT < 0, "M3_NEXT is negative")
    check(t, M3_RETURN < 0, "M3_RETURN is negative")
    check(t, M3_TRAP < 0, "M3_TRAP is negative")
    not_equal(t, M3_NEXT, M3_RETURN, "M3_NEXT differs from M3_RETURN")
    not_equal(t, M3_NEXT, M3_TRAP, "M3_NEXT differs from M3_TRAP")
    not_equal(t, M3_RETURN, M3_TRAP, "M3_RETURN differs from M3_TRAP")

    var rt = M3Runtime()
    rt.pc = 17
    rt.sp = 4
    rt.trap = m3Err_none

    // nextOpDirect: the dispatcher continues at rt.pc, which is untouched
    let next = nextOpDirect(rt)
    equal(t, next, M3_NEXT, "nextOpDirect returns M3_NEXT")
    equal(t, rt.pc, 17, "nextOpDirect leaves rt.pc alone")
    equal(t, rt.sp, 4, "nextOpDirect leaves rt.sp alone")

    // jumpOpDirect: the branch target becomes rt.pc
    let jumped = jumpOpDirect(rt, 42)
    equal(t, jumped, M3_NEXT, "jumpOpDirect returns M3_NEXT")
    equal(t, rt.pc, 42, "jumpOpDirect sets rt.pc to the target")
    let jumpedNull = jumpOpDirect(rt, -1)
    equal(t, jumpedNull, M3_NEXT, "jumpOpDirect(-1) returns M3_NEXT")
    equal(t, rt.pc, -1, "jumpOpDirect stores a null pc as -1")

    // retOp: C's `return m3Err_none` from an operation
    rt.pc = 5
    let ret = retOp(rt)
    equal(t, ret, M3_RETURN, "retOp returns M3_RETURN")
    equal(t, rt.pc, 5, "retOp leaves rt.pc alone")
    equal_str(t, rt.trap, "", "retOp leaves rt.trap empty")

    // newTrap: the trap string is recorded, the protocol value returned
    let trapped = newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
    equal(t, trapped, M3_TRAP, "newTrap returns M3_TRAP")
    equal_str(t, rt.trap, m3Err_trapOutOfBoundsMemoryAccess, "newTrap records the trap string")
    equal(t, rt.pc, 5, "newTrap leaves rt.pc alone")
    let trappedAgain = newTrap(rt, m3Err_trapDivisionByZero)
    equal(t, trappedAgain, M3_TRAP, "newTrap returns M3_TRAP (2)")
    equal_str(t, rt.trap, m3Err_trapDivisionByZero, "a later newTrap overwrites rt.trap")

    // forwardTrap of an int: every protocol value passes through unchanged
    equal(t, forwardTrap(M3_RETURN), M3_RETURN, "forwardTrap passes M3_RETURN through")
    equal(t, forwardTrap(M3_TRAP), M3_TRAP, "forwardTrap passes M3_TRAP through")
    equal(t, forwardTrap(M3_NEXT), M3_NEXT, "forwardTrap passes M3_NEXT through")
    equal(t, forwardTrap(123), 123, "forwardTrap passes a loop pc through")
    equal(t, forwardTrap(0), 0, "forwardTrap passes loop pc 0 through")
    equal_str(t, rt.trap, m3Err_trapDivisionByZero, "forwardTrap of an int does not touch rt.trap")

    // forwardTrap of an M3Result: m3Err_none completes, anything else traps
    rt.trap = m3Err_none
    let hostOk = forwardTrap(rt, m3Err_none)
    equal(t, hostOk, M3_RETURN, "forwardTrap(rt, m3Err_none) is M3_RETURN")
    equal_str(t, rt.trap, "", "forwardTrap(rt, m3Err_none) leaves rt.trap empty")
    let hostTrap = forwardTrap(rt, m3Err_trapExit)
    equal(t, hostTrap, M3_TRAP, "forwardTrap(rt, error) is M3_TRAP")
    equal_str(t, rt.trap, m3Err_trapExit, "forwardTrap(rt, error) records the trap string")

    // d_m3ClearRegisters: C `_r0 = 0; _fp0 = 0.;`
    rt.r0 = 0xdeadbeefcafef00dul
    rt.fp0 = 3.5lf
    d_m3ClearRegisters(rt)
    equal(t, rt.r0, 0ul, "d_m3ClearRegisters clears _r0")
    equal(t, bits_f64(rt.fp0), 0ul, "d_m3ClearRegisters clears _fp0 to +0.0")
}


// ============================================================================
// Immediate readers
// ============================================================================


def test_immediate_readers(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()

    // the words, in the order the readers below consume them
    emit(rt, 0x0123456789abcdeful)             // 0: immediate_u64, the raw word
    emit(rt, u64(0xdeadbeefu))                 // 1: immediate_u32
    emit(rt, u64(u32(-7)))                     // 2: immediate_i32, negative, zero-extended into the word
    emit(rt, u64(-5l))                         // 3: immediate_i64, negative, the bits
    emit(rt, u64(0x3f800000u))                 // 4: immediate_f32, 1.0f
    emit(rt, u64(0xffc00001u))                 // 5: immediate_f32, a NaN with sign and payload
    emit(rt, 0x400921fb54442d18ul)             // 6: immediate_f64, pi
    emit(rt, 0x7ff8000000000123ul)             // 7: immediate_f64, a NaN with payload
    emit(rt, u64(1234))                        // 8: immediate_pc
    emit(rt, u64(-1))                          // 9: immediate_pc, a null pc
    emit(rt, u64(3))                           // 10: immediate_handle
    emit(rt, u64(-1))                          // 11: immediate_handle, a null handle
    emit(rt, u64(u32(6)))                      // 12: immediate_slot
    emit(rt, u64(u32(-2)))                     // 13: immediate_slot, a negative offset
    emit(rt, 0x5555555555555555ul)             // 14: skip_immediate
    emit(rt, 0xffffffff00000009ul)             // 15: immediate_u32 reads the low half only
    emit(rt, 0xffffffff00000009ul)             // 16: immediate_i32 reads the low half only
    emit(rt, 0xffffffff3f800000ul)             // 17: immediate_f32 reads the low half only
    equal(t, length(rt.code), 18, "18 words emitted")

    rt.pc = 0

    let raw = immediate_u64(rt)
    equal(t, raw, 0x0123456789abcdeful, "immediate_u64 returns the raw word")
    equal(t, rt.pc, 1, "immediate_u64 advances rt.pc by one")

    let u = immediate_u32(rt)
    equal(t, u, 0xdeadbeefu, "immediate_u32 decodes the zero-extended u32")
    equal(t, rt.pc, 2, "immediate_u32 advances rt.pc by one")

    let i = immediate_i32(rt)
    equal(t, i, -7, "immediate_i32 decodes a negative i32")
    equal(t, rt.pc, 3, "immediate_i32 advances rt.pc by one")

    let l = immediate_i64(rt)
    equal(t, l, -5l, "immediate_i64 decodes a negative i64")
    equal(t, rt.pc, 4, "immediate_i64 advances rt.pc by one")

    let f = immediate_f32(rt)
    equal(t, bits_f32(f), 0x3f800000u, "immediate_f32 decodes 1.0f")
    equal(t, rt.pc, 5, "immediate_f32 advances rt.pc by one")
    let fnan = immediate_f32(rt)
    equal(t, bits_f32(fnan), 0xffc00001u, "immediate_f32 keeps a NaN payload and sign")
    equal(t, rt.pc, 6, "immediate_f32 advances rt.pc by one (2)")

    let d = immediate_f64(rt)
    equal(t, bits_f64(d), 0x400921fb54442d18ul, "immediate_f64 decodes pi")
    equal(t, rt.pc, 7, "immediate_f64 advances rt.pc by one")
    let dnan = immediate_f64(rt)
    equal(t, bits_f64(dnan), 0x7ff8000000000123ul, "immediate_f64 keeps a NaN payload")
    equal(t, rt.pc, 8, "immediate_f64 advances rt.pc by one (2)")

    let pc = immediate_pc(rt)
    equal(t, pc, 1234, "immediate_pc decodes a pc")
    equal(t, rt.pc, 9, "immediate_pc advances rt.pc by one")
    let nullPc = immediate_pc(rt)
    equal(t, nullPc, -1, "immediate_pc decodes a null pc as -1")
    equal(t, rt.pc, 10, "immediate_pc advances rt.pc by one (2)")

    let handle = immediate_handle(rt)
    equal(t, handle, 3, "immediate_handle decodes a handle")
    equal(t, rt.pc, 11, "immediate_handle advances rt.pc by one")
    let nullHandle = immediate_handle(rt)
    equal(t, nullHandle, -1, "immediate_handle decodes a null handle as -1")
    equal(t, rt.pc, 12, "immediate_handle advances rt.pc by one (2)")

    let slot = immediate_slot(rt)
    equal(t, slot, 6, "immediate_slot decodes a slot offset")
    equal(t, rt.pc, 13, "immediate_slot advances rt.pc by one")
    let negSlot = immediate_slot(rt)
    equal(t, negSlot, -2, "immediate_slot decodes a negative offset as C's immediate (i32)")
    equal(t, rt.pc, 14, "immediate_slot advances rt.pc by one (2)")

    skip_immediate(rt)
    equal(t, rt.pc, 15, "skip_immediate advances rt.pc by one")
    equal(t, rt.code[14], 0x5555555555555555ul, "skip_immediate does not touch the word")

    // the 32-bit readers see the low half of the word only
    let lowU = immediate_u32(rt)
    equal(t, lowU, 9u, "immediate_u32 reads the low 32 bits")
    let lowI = immediate_i32(rt)
    equal(t, lowI, 9, "immediate_i32 reads the low 32 bits")
    let lowF = immediate_f32(rt)
    equal(t, bits_f32(lowF), 0x3f800000u, "immediate_f32 reads the low 32 bits")
    equal(t, rt.pc, 18, "every reader consumed exactly one word")

    // reading is not writing
    equal(t, rt.code[0], 0x0123456789abcdeful, "the readers leave rt.code untouched (0)")
    equal(t, rt.code[9], u64(-1), "the readers leave rt.code untouched (9)")

    // the readers start wherever rt.pc points
    rt.pc = 6
    let again = immediate_f64(rt)
    equal(t, bits_f64(again), 0x400921fb54442d18ul, "a reader reads at rt.pc, not from the start")
    equal(t, rt.pc, 7, "and advances from there")
}


// ============================================================================
// Slot accessors
// ============================================================================


def test_slot_accessors(var t : TestRun; fx : FixtureSource) {
    var rt <- stack_runtime(16, 4)

    // the frame starts at rt.sp: slot `off` is the word rt.stack[rt.sp + off]
    equal(t, slot_index(rt, 0), 4, "slot_index(0) is rt.sp")
    equal(t, slot_index(rt, 3), 7, "slot_index(off) is rt.sp + off")
    equal(t, slot_index(rt, -1), 3, "slot_index of a negative offset is below rt.sp")

    // u32: the write is the whole word, zero-extended; the read the low half
    set_slot_u32(rt, 1, 0xdeadbeefu)
    equal(t, rt.stack[5], 0x00000000deadbeeful, "set_slot_u32 writes slot 1 as a zero-extended word")
    equal(t, rt.stack[4], 0xfffffffffffffffful, "set_slot_u32 leaves slot 0 alone")
    equal(t, rt.stack[6], 0xfffffffffffffffful, "set_slot_u32 leaves slot 2 alone")
    equal(t, slot_u32(rt, 1), 0xdeadbeefu, "slot_u32 reads the word back")
    equal(t, slot_u32(rt, 0), 0xffffffffu, "slot_u32 reads the low 32 bits of a full word")
    equal(t, slot_u64(rt, 1), 0x00000000deadbeeful, "slot_u64 of a slot written 32-bit is the zero-extended value")

    // i32: negative values are their 32-bit pattern, zero-extended in the word
    set_slot_i32(rt, 2, -7)
    equal(t, rt.stack[6], 0x00000000fffffff9ul, "set_slot_i32 stores the 32-bit two's complement, zero-extended")
    equal(t, slot_i32(rt, 2), -7, "slot_i32 reads a negative value back")
    equal(t, slot_u32(rt, 2), 0xfffffff9u, "slot_u32 of the same slot is the pattern")
    equal(t, slot_i32(rt, 0), -1, "slot_i32 of a full word is -1")

    // u64 / i64: the whole word; the second slot a 64-bit value reserves is untouched
    set_slot_u64(rt, 3, 0x0123456789abcdeful)
    equal(t, rt.stack[7], 0x0123456789abcdeful, "set_slot_u64 writes the word")
    equal(t, rt.stack[8], 0xfffffffffffffffful, "a 64-bit value in slot i leaves slot i + 1 alone")
    equal(t, slot_u64(rt, 3), 0x0123456789abcdeful, "slot_u64 reads the word back")
    equal(t, slot_u32(rt, 3), 0x89abcdefu, "slot_u32 of a 64-bit slot is its low half")
    set_slot_i64(rt, 5, -5l)
    equal(t, rt.stack[9], 0xfffffffffffffffbul, "set_slot_i64 stores the two's complement")
    equal(t, slot_i64(rt, 5), -5l, "slot_i64 reads a negative value back")
    equal(t, slot_u64(rt, 5), 0xfffffffffffffffbul, "slot_u64 of the same slot is the pattern")
    equal(t, rt.stack[10], 0xfffffffffffffffful, "a 64-bit value in slot 5 leaves slot 6 alone")

    // f32 / f64: the bits, NaN payloads included
    set_slot_f32(rt, 7, 1.0f)
    equal(t, rt.stack[11], 0x000000003f800000ul, "set_slot_f32 stores the float's bits, zero-extended")
    equal(t, bits_f32(slot_f32(rt, 7)), 0x3f800000u, "slot_f32 reads 1.0f back")
    set_slot_f32(rt, 7, as_f32(0xffc00001u))
    equal(t, bits_f32(slot_f32(rt, 7)), 0xffc00001u, "slot_f32 keeps a NaN payload and sign")
    equal(t, slot_u32(rt, 7), 0xffc00001u, "slot_u32 of an f32 slot is its bits")
    set_slot_f64(rt, 8, 2.5lf)
    equal(t, rt.stack[12], 0x4004000000000000ul, "set_slot_f64 stores the double's bits")
    equal(t, bits_f64(slot_f64(rt, 8)), 0x4004000000000000ul, "slot_f64 reads 2.5 back")
    set_slot_f64(rt, 8, as_f64(0x7ff8000000000123ul))
    equal(t, bits_f64(slot_f64(rt, 8)), 0x7ff8000000000123ul, "slot_f64 keeps a NaN payload")
    equal(t, rt.stack[13], 0xfffffffffffffffful, "a 64-bit value in slot 8 leaves slot 9 alone")

    // a negative offset addresses the caller's frame below rt.sp
    set_slot_u32(rt, -1, 77u)
    equal(t, rt.stack[3], 77ul, "set_slot_u32 with a negative offset writes below rt.sp")
    equal(t, slot_u32(rt, -1), 77u, "slot_u32 with a negative offset reads below rt.sp")

    // the accessors follow rt.sp
    rt.sp = 0
    equal(t, slot_u32(rt, 3), 77u, "the slot accessors follow rt.sp")
    rt.sp = 4

    // stack_T / set_stack_T at a saved index (C: through a slot_ptr pointer)
    let saved = slot_index(rt, 2)
    equal(t, stack_i32(rt, saved), -7, "stack_i32 reads at a saved index")
    equal(t, stack_u32(rt, saved), 0xfffffff9u, "stack_u32 reads at a saved index")
    set_stack_u32(rt, saved, 0x10u)
    equal(t, rt.stack[6], 0x10ul, "set_stack_u32 writes the word at the index, zero-extended")
    set_stack_i32(rt, saved, -2)
    equal(t, rt.stack[6], 0x00000000fffffffeul, "set_stack_i32 writes the pattern, zero-extended")
    set_stack_u64(rt, saved, 0x1122334455667788ul)
    equal(t, stack_u64(rt, saved), 0x1122334455667788ul, "set_stack_u64 / stack_u64 round-trip")
    set_stack_i64(rt, saved, -9l)
    equal(t, stack_i64(rt, saved), -9l, "set_stack_i64 / stack_i64 round-trip")
    equal(t, rt.stack[6], 0xfffffffffffffff7ul, "set_stack_i64 stores the two's complement")
    set_stack_f32(rt, saved, as_f32(0x7fc00000u))
    equal(t, bits_f32(stack_f32(rt, saved)), 0x7fc00000u, "set_stack_f32 / stack_f32 round-trip a NaN")
    equal(t, rt.stack[6], 0x000000007fc00000ul, "set_stack_f32 writes the bits, zero-extended")
    set_stack_f64(rt, saved, as_f64(0xfff8000000000000ul))
    equal(t, bits_f64(stack_f64(rt, saved)), 0xfff8000000000000ul, "set_stack_f64 / stack_f64 round-trip a NaN")
    equal(t, rt.stack[5], 0x00000000deadbeeful, "the saved-index writes leave the neighbour below alone")
    equal(t, rt.stack[7], 0x0123456789abcdeful, "the saved-index writes leave the neighbour above alone")

    // the combined forms: the offset immediate first, then the slot
    emit(rt, u64(u32(1)))      // 0: slot_u32
    emit(rt, u64(u32(2)))      // 1: slot_i32
    emit(rt, u64(u32(3)))      // 2: slot_u64
    emit(rt, u64(u32(5)))      // 3: slot_i64
    emit(rt, u64(u32(7)))      // 4: slot_f32
    emit(rt, u64(u32(8)))      // 5: slot_f64
    emit(rt, u64(u32(9)))      // 6: slot_index
    emit(rt, u64(u32(10)))     // 7: set_slot_u32
    emit(rt, u64(u32(10)))     // 8: set_slot_i32
    emit(rt, u64(u32(11)))     // 9: set_slot_u64
    emit(rt, u64(u32(11)))     // 10: set_slot_i64
    emit(rt, u64(u32(-1)))     // 11: set_slot_f32, a negative offset
    emit(rt, u64(u32(0)))      // 12: set_slot_f64
    rt.pc = 0
    set_stack_i64(rt, saved, -9l)

    let c_u32 = slot_u32(rt)
    equal(t, c_u32, 0xdeadbeefu, "slot_u32(rt) reads the slot at the offset immediate")
    equal(t, rt.pc, 1, "slot_u32(rt) consumed one word")
    let c_i32 = slot_i32(rt)
    equal(t, c_i32, -9, "slot_i32(rt) reads the slot at the offset immediate")
    equal(t, rt.pc, 2, "slot_i32(rt) consumed one word")
    let c_u64 = slot_u64(rt)
    equal(t, c_u64, 0x0123456789abcdeful, "slot_u64(rt) reads the slot at the offset immediate")
    equal(t, rt.pc, 3, "slot_u64(rt) consumed one word")
    let c_i64 = slot_i64(rt)
    equal(t, c_i64, -5l, "slot_i64(rt) reads the slot at the offset immediate")
    equal(t, rt.pc, 4, "slot_i64(rt) consumed one word")
    let c_f32 = slot_f32(rt)
    equal(t, bits_f32(c_f32), 0xffc00001u, "slot_f32(rt) reads the slot at the offset immediate")
    equal(t, rt.pc, 5, "slot_f32(rt) consumed one word")
    let c_f64 = slot_f64(rt)
    equal(t, bits_f64(c_f64), 0x7ff8000000000123ul, "slot_f64(rt) reads the slot at the offset immediate")
    equal(t, rt.pc, 6, "slot_f64(rt) consumed one word")
    let c_idx = slot_index(rt)
    equal(t, c_idx, 13, "slot_index(rt) is rt.sp + the offset immediate")
    equal(t, rt.pc, 7, "slot_index(rt) consumed one word")

    set_slot_u32(rt, 0xabcdu)
    equal(t, rt.stack[14], 0xabcdul, "set_slot_u32(rt, v) writes the slot at the offset immediate")
    equal(t, rt.pc, 8, "set_slot_u32(rt, v) consumed one word")
    set_slot_i32(rt, -3)
    equal(t, rt.stack[14], 0x00000000fffffffdul, "set_slot_i32(rt, v) writes the slot at the offset immediate")
    equal(t, rt.pc, 9, "set_slot_i32(rt, v) consumed one word")
    set_slot_u64(rt, 0xfedcba9876543210ul)
    equal(t, rt.stack[15], 0xfedcba9876543210ul, "set_slot_u64(rt, v) writes the slot at the offset immediate")
    equal(t, rt.pc, 10, "set_slot_u64(rt, v) consumed one word")
    set_slot_i64(rt, -11l)
    equal(t, rt.stack[15], 0xfffffffffffffff5ul, "set_slot_i64(rt, v) writes the slot at the offset immediate")
    equal(t, rt.pc, 11, "set_slot_i64(rt, v) consumed one word")
    set_slot_f32(rt, 0.5f)
    equal(t, rt.stack[3], 0x000000003f000000ul, "set_slot_f32(rt, v) writes the slot at a negative offset immediate")
    equal(t, rt.pc, 12, "set_slot_f32(rt, v) consumed one word")
    set_slot_f64(rt, -0.0lf)
    equal(t, rt.stack[4], 0x8000000000000000ul, "set_slot_f64(rt, v) writes the slot at the offset immediate")
    equal(t, rt.pc, 13, "set_slot_f64(rt, v) consumed one word")
}


// ============================================================================
// Memory accessors
// ============================================================================


def test_memory_accessors(var t : TestRun; fx : FixtureSource) {
    var rt <- mem_runtime(32)
    equal(t, mem_size(rt), 32, "mem_size is length(rt.mem)")

    // u32 at an unaligned address: little-endian bytes
    store_u32(rt, 5, 0x11223344u)
    equal(t, u32(rt.mem[5]), 0x44u, "store_u32 byte 0 is the low byte")
    equal(t, u32(rt.mem[6]), 0x33u, "store_u32 byte 1")
    equal(t, u32(rt.mem[7]), 0x22u, "store_u32 byte 2")
    equal(t, u32(rt.mem[8]), 0x11u, "store_u32 byte 3 is the high byte")
    equal(t, u32(rt.mem[4]), 0xccu, "store_u32 leaves the byte below alone")
    equal(t, u32(rt.mem[9]), 0xccu, "store_u32 leaves the byte above alone")
    equal(t, load_u32(rt, 5), 0x11223344u, "load_u32 assembles the bytes back")
    equal(t, load_u32(rt, 6), 0xcc112233u, "load_u32 at another address sees the overlap")
    equal(t, load_i32(rt, 5), int(0x11223344u), "load_i32 of a positive pattern")

    // i32 sign: the bytes of a negative value read back negative
    store_u32(rt, 1, u32(-7))
    equal(t, u32(rt.mem[1]), 0xf9u, "store_u32 of a negative i32: low byte")
    equal(t, u32(rt.mem[4]), 0xffu, "store_u32 of a negative i32: high byte")
    equal(t, load_i32(rt, 1), -7, "load_i32 reads a negative value back")
    equal(t, load_u32(rt, 1), 0xfffffff9u, "load_u32 of the same bytes is the pattern")
    equal(t, i64(load_i32(rt, 1)), -7l, "an i32 widened to i64 sign-extends (C: (i64)(i32) value)")
    equal(t, u64(load_u32(rt, 1)), 0x00000000fffffff9ul, "a u32 widened to u64 zero-extends (C: (u64)(u32) value)")

    // u8 / s8
    store_u8(rt, 10, 0xf3u8)
    equal(t, u32(rt.mem[10]), 0xf3u, "store_u8 writes the byte")
    equal(t, u32(load_u8(rt, 10)), 0xf3u, "load_u8 reads the byte")
    equal(t, int(load_s8(rt, 10)), -13, "load_s8 sign-extends 0xf3 to -13 (C: (i32)(i8) value)")
    equal(t, i64(load_s8(rt, 10)), -13l, "load_s8 widened to i64 is -13")
    equal(t, u32(load_u8(rt, 9)), 0xccu, "store_u8 leaves the neighbours alone")
    store_u8(rt, 11, 0x7fu8)
    equal(t, int(load_s8(rt, 11)), 127, "load_s8 of 0x7f is 127")

    // u16 / s16 at an odd address
    store_u16(rt, 13, u16(0xbeefu))
    equal(t, u32(rt.mem[13]), 0xefu, "store_u16 byte 0 is the low byte")
    equal(t, u32(rt.mem[14]), 0xbeu, "store_u16 byte 1 is the high byte")
    equal(t, u32(rt.mem[12]), 0xccu, "store_u16 leaves the byte below alone")
    equal(t, u32(rt.mem[15]), 0xccu, "store_u16 leaves the byte above alone")
    equal(t, u32(load_u16(rt, 13)), 0xbeefu, "load_u16 assembles the bytes back")
    equal(t, int(load_s16(rt, 13)), -16657, "load_s16 sign-extends 0xbeef (C: (i32)(i16) value)")
    store_u16(rt, 13, u16(0x7fffu))
    equal(t, int(load_s16(rt, 13)), 32767, "load_s16 of 0x7fff is 32767")
    equal(t, int(load_u16(rt, 13)), 32767, "load_u16 of 0x7fff is 32767")

    // u64 / i64 at an unaligned address
    store_u64(rt, 17, 0x0123456789abcdeful)
    equal(t, u32(rt.mem[17]), 0xefu, "store_u64 byte 0 is the low byte")
    equal(t, u32(rt.mem[20]), 0x89u, "store_u64 byte 3")
    equal(t, u32(rt.mem[21]), 0x67u, "store_u64 byte 4")
    equal(t, u32(rt.mem[24]), 0x01u, "store_u64 byte 7 is the high byte")
    equal(t, u32(rt.mem[16]), 0xccu, "store_u64 leaves the byte below alone")
    equal(t, u32(rt.mem[25]), 0xccu, "store_u64 leaves the byte above alone")
    equal(t, load_u64(rt, 17), 0x0123456789abcdeful, "load_u64 assembles the bytes back")
    equal(t, load_u32(rt, 17), 0x89abcdefu, "load_u32 of the low half of a u64")
    equal(t, load_u32(rt, 21), 0x01234567u, "load_u32 of the high half of a u64")
    equal(t, load_i64(rt, 17), i64(0x0123456789abcdeful), "load_i64 of a positive pattern")
    store_u64(rt, 17, u64(-5l))
    equal(t, load_i64(rt, 17), -5l, "load_i64 reads a negative value back")
    equal(t, load_u64(rt, 17), 0xfffffffffffffffbul, "load_u64 of the same bytes is the pattern")

    // f32 / f64: the bits, NaN payloads included
    store_f32(rt, 3, 1.0f)
    equal(t, load_u32(rt, 3), 0x3f800000u, "store_f32 writes the float's bits little-endian")
    equal(t, bits_f32(load_f32(rt, 3)), 0x3f800000u, "load_f32 reads 1.0f back")
    store_f32(rt, 3, as_f32(0xffc00001u))
    equal(t, bits_f32(load_f32(rt, 3)), 0xffc00001u, "load_f32 keeps a NaN payload and sign")
    equal(t, u32(rt.mem[3]), 0x01u, "the NaN payload's low byte is byte 0")
    store_f64(rt, 21, 2.5lf)
    equal(t, load_u64(rt, 21), 0x4004000000000000ul, "store_f64 writes the double's bits little-endian")
    equal(t, bits_f64(load_f64(rt, 21)), 0x4004000000000000ul, "load_f64 reads 2.5 back")
    store_f64(rt, 21, as_f64(0x7ff8000000000123ul))
    equal(t, bits_f64(load_f64(rt, 21)), 0x7ff8000000000123ul, "load_f64 keeps a NaN payload")
    equal(t, u32(rt.mem[21]), 0x23u, "the NaN payload's low byte is byte 0 (f64)")
    equal(t, u32(rt.mem[28]), 0x7fu, "the f64's sign byte is byte 7")

    // the last bytes of the memory are addressable; the size follows resize
    store_u32(rt, 28, 0xa5a5a5a5u)
    equal(t, load_u32(rt, 28), 0xa5a5a5a5u, "a u32 at mem_size - 4 round-trips")
    store_u8(rt, 31, 0x99u8)
    equal(t, u32(load_u8(rt, 31)), 0x99u, "the last byte round-trips")
    resize(rt.mem, 64)
    equal(t, mem_size(rt), 64, "mem_size follows a resize (ResizeMemory)")
    equal(t, u32(load_u8(rt, 31)), 0x99u, "a resize keeps the bytes")
    equal(t, u32(load_u8(rt, 63)), 0u, "the grown tail is zero")
    store_u64(rt, 56, 0xfffffffffffffffful)
    equal(t, load_u64(rt, 56), 0xfffffffffffffffful, "a u64 at the new mem_size - 8 round-trips")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_exec_defs(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_return_protocol")
    test_return_protocol(t, fx)
    begin_test(t, "test_immediate_readers")
    test_immediate_readers(t, fx)
    begin_test(t, "test_slot_accessors")
    test_slot_accessors(t, fx)
    begin_test(t, "test_memory_accessors")
    test_memory_accessors(t, fx)
}
