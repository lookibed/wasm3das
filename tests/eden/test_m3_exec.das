options gen2
options indenting = 4

module test_m3_exec shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_exec
require modules/wasm3das/source/m3_exec_defs
require modules/wasm3das/source/m3_function   // AllocFuncType for the CallIndirect types
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core       // the arena allocator helpers, the error strings
require daslib/math_bits
require strings                               // starts_with / ends_with / find: the op-name forms of test_arithmetic_families

/*
    test_m3_exec.das: Eden counterpart of
    .upstream/tests/integration/test_m3_exec.das (all three parts).

    The upstream tests load fib32.wasm, replace the body of its (i32) -> i32
    function with hand-written WebAssembly bytes, compile them and call the
    function through m3_CallV. Eden: the compiler, the environment and the
    parser are later modules of the port, so each test builds the runtime by
    hand and assembles the code words the compiler would emit (an operation
    word is m3_OpWord(name), an immediate its word of DESIGN.md section 4.4)
    into rt.code, then runs the function through RunCode (m3_Call's entry) as
    the fixture function of the upstream file: frame slot 0 holds the i32
    result, slot 1 the i32 argument, the locals follow (C's numRetSlots = 1,
    numRetAndArgSlots = 2 for (i32) -> i32). The checks are the upstream
    ones: the values and the trap strings.

    Coverage of the upstream [test]s (4 of 4):
      - test_exec_control_flow: all four cases (the loop sum through
        op_Loop / op_ContinueLoopIf with op_i32_Add_ss / op_i32_Subtract_ss,
        the if/else, the select and the unreachable) are assembled.
      - test_exec_operand_order_and_integer_arithmetic: the same programs
        and expected values, the three 64-bit cases through the real
        i64.extend_i32_s / i32.wrap_i64 pair (op_i64_Extend_i32_s on the
        arg slot, op_i32_Wrap_i64_r on the register).
      - test_exec_division_traps_and_rem_s_quirk: the same programs and
        expected values.
      - test_exec_float_unary_ops: the same eight programs and expected
        bits, the f32 / f64 constant in a slot, the unary operation's _s
        form, the reinterpret / trunc conversion's _r_r form and the
        i64.const 63; i64.shr_u; i32.wrap_i64 tail of the sign-bit cases.
    Tests added for the Eden shape (no upstream counterpart):
      - test_op_table: the registration count of the complete table (510)
        and the word layout of its three parts, the m3_OpAt(m3_OpWord(name))
        round trip, the registration order, the idempotent rebuild, and the
        d_m3Assert panic on an unknown name (caught with try / recover,
        DESIGN.md section 1);
      - test_arithmetic_families: every operation of part 2 once through
        the dispatcher (a table of op name, operands and expected register
        bits, the operands installed as the operation's form reads them),
        with the operand order of the _rs / _sr / _ss forms, the traps of
        the integer division, the wasm NaN / signed-zero rules of min /
        max, a NaN on either side (and on both sides for eq / ne) of every
        float compare form with the IEEE unordered result (0 for eq and the
        ordered compares, 1 for ne; DESIGN.md section 1: the editor's == is
        not IEEE on NaN, the port guards with isnan), and the sign / zero
        extension of a 32-bit result into rt.r0;
        the table must name every word of the part-2 range, so a missing
        registration or a missing row fails;
      - test_conversion_families: every conversion operation of part 3 once
        through the dispatcher (the same table shape: op name, source word,
        expected result word or trap), with the destination-slot forms, the
        trapping truncations at both range ends, on NaN and on the
        infinities, the saturating truncations at the same inputs, the
        round-to-nearest-even cases of the integer -> float conversions
        (u64 -> f32 above 2^61 and above the sign bit, i64 / i32 / u32 ->
        f32 at 2^24 + 1, u64 / i64 -> f64 at 2^53 + 1), demote's halfway
        cases, overflow to inf and NaN payload, and the reinterpret round
        trips with NaN payloads; the table must name every word of the
        part-3 range;
      - test_nested_call: op_Entry -> op_Call -> op_Return with rt.sp, rt.pc
        and the registers restored by Call (the protocol of the m3_exec
        header), a trap unwinding two levels with rt.sp restored, the
        op_Entry stack-overflow trap, and op_Entry's zeroing of the locals
        and copy of the constants;
      - test_loops_and_branches: op_Loop with op_ContinueLoopIf and
        op_ContinueLoop, op_BranchIf_s, op_BranchIfPrologue_s, op_If_s and
        op_BranchTable, the loop counter driven by a raw function
        (op_CallRawFunction, which also checks the rt.originStack swap and a
        host trap);
      - test_slots_and_globals: the SetRegister / SetSlot / PreserveSetSlot,
        CopySlot / PreserveCopySlot, Const32 / Const64, Select and the global
        operations, bit-exact;
      - test_memory_ops: every load and store width at unaligned addresses
        with the sign / zero extension C applies, the bounds check at the
        exact boundary, op_MemSize, op_MemGrow through the ResizeMemoryHook,
        op_MemCopy (overlapping both ways) and op_MemFill with their traps;
      - test_call_indirect_and_compile: the three op_CallIndirect traps, the
        call through the table, the lazy compile through CompileFunctionHook
        (success and failure), and op_Compile's in-place rewrite to op_Call;
      - test_every_op_executed: the sweep over the whole table, run last:
        every word 0..509 of g_opIndex was marked by mark_executed, from a
        program this file assembled and ran (emit_op) or from a table
        invoke (run_op_case / run_conv_case), so a registered operation
        without a test fails here.
*/


// ============================================================================
// Helpers: a runtime built by hand, code assembled by name
// ============================================================================


// the number of operations registered (the `def public op_` count of
// source/m3_exec.das: 128 of part 1, 250 of part 2 and 132 of part 3), and
// the words of the part-2 and part-3 ranges, registered right after op_NoOp
// in file order, before the part-1 operations
let OP_COUNT = 510
let PART2_FIRST_WORD = 1
let PART2_LAST_WORD = 250
let PART3_FIRST_WORD = 251
let PART3_LAST_WORD = 382


// Eden: a function variable cannot be assigned `null`; an empty value of the
// hook's type resets it (the bridge tests its hook against null)
var private noResizeHook : function<(var rt : M3Runtime; i_numPages : u32) : M3Result>
var private noCompileHook : function<(var rt : M3Runtime; io_function : IM3Function) : M3Result>


// a runtime with `slots` stack words (every bit set, so a write that
// touches fewer bits than a word is visible), the op table built
def private exec_runtime(slots : int) : M3Runtime {
    m3_build_op_table()
    var rt = M3Runtime()
    resize(rt.stack, slots)
    for (i in range(slots)) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    rt.numStackSlots = u32(slots)
    rt.originStack = 0
    rt.sp = 0
    rt.pc = 0
    rt.trap = m3Err_none
    return <- rt
}


// one code word; returns its index (the pc of the word)
def private emit(var rt : M3Runtime; word : u64) : int {
    let pc = length(rt.code)
    push(rt.code, word)
    return pc
}


// Eden: the per-word coverage of this file. mark_executed records a word
// when a hand-assembled program emits it (every program of this file is run,
// both arms of every branch are driven) and when a table test invokes it;
// test_every_op_executed asserts that no word 0..OP_COUNT-1 is left at
// false, so a registered operation without a test fails there.
var private executedWords : array<bool>


def private mark_executed(word : int) {
    if (length(executedWords) < OP_COUNT) {
        resize(executedWords, OP_COUNT)   // an array of bool: resize is fine on scalars (DESIGN section 6)
    }
    if (word >= 0 && word < length(executedWords)) {
        executedWords[word] = true
    }
}


// an operation word by name
def private emit_op(var rt : M3Runtime; name : string) : int {
    let word = m3_OpWord(name)
    mark_executed(int(word))
    return emit(rt, word)
}


// a pc, a handle, a slot offset or an i32 immediate: u64(int), DESIGN 4.4
def private emit_int(var rt : M3Runtime; value : int) : int {
    return emit(rt, u64(value))
}


// a u32 immediate, zero-extended into its word
def private emit_u32(var rt : M3Runtime; value : u32) : int {
    return emit(rt, u64(value))
}


// a fresh function slot of the arena; `compiled` is set by the test
def private new_function(var rt : M3Runtime; maxStackSlots : int; numRetAndArgSlots : int; numLocalBytes : int) : IM3Function {
    let n = length(rt.functions)
    m3_Realloc_Impl(rt.functions, n + 1, n)
    rt.functions[n].maxStackSlots = u16(maxStackSlots)
    rt.functions[n].numRetSlots = u16(1)
    rt.functions[n].numRetAndArgSlots = u16(numRetAndArgSlots)
    rt.functions[n].numLocalBytes = u16(numLocalBytes)
    return n
}


// the fixture function of the upstream tests: (i32) -> i32, ret in slot 0,
// arg in slot 1, `locals` i32 locals after them, compiled at `pc`
def private fixture_function(var rt : M3Runtime; pc : pc_t; locals : int) : IM3Function {
    let f = new_function(rt, 2 + locals + 8, 2, locals * 4)
    rt.functions[f].compiled = pc
    return f
}


// runs the code at `pc` with the frame at `sp` (m3_Call's RunCode entry)
def private run(var rt : M3Runtime; pc : pc_t; sp : m3stack_t) : m3ret_t {
    rt.trap = m3Err_none
    rt.pc = pc
    rt.sp = sp
    return RunCode(rt)
}


// Calls the (i32) -> i32 function; returns the trap, or m3Err_none with the value in `out`.
def private call_i32(var rt : M3Runtime; f : IM3Function; n : int; var out : int&) : M3Result {
    for (i in range(length(rt.stack))) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    set_stack_i32(rt, 1, n)
    let r = run(rt, rt.functions[f].compiled, 0)
    if (r == M3_TRAP) {
        return rt.trap
    }
    if (r != M3_RETURN) {
        return "unexpected protocol value {r}"
    }
    out = stack_i32(rt, 0)
    return m3Err_none
}


def private expect_value(var t : TestRun; var rt : M3Runtime; f : IM3Function; n : int; expected : int; name : string) {
    var out = 0
    equal_str(t, call_i32(rt, f, n, out), m3Err_none, "{name}({n}) result")
    equal(t, out, expected, "{name}({n})")
}


def private expect_trap(var t : TestRun; var rt : M3Runtime; f : IM3Function; n : int; expected : M3Result; name : string) {
    var out = 0
    equal_str(t, call_i32(rt, f, n, out), expected, "{name}({n}) trap")
}


// ============================================================================
// Upstream: test_exec_control_flow
// ============================================================================


def test_exec_control_flow(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)

    // sum 1..n with a loop and br_if: op_Loop, op_ContinueLoopIf, local.set/tee.
    // locals: one i32 (sum). loop { sum += i; i -= 1; br_if i } ; sum
    // Eden: the compiler's shape: sum is slot 2 (zeroed by op_Entry), the
    // constant 1 sits in slot 3; op_i32_Add_ss leaves sum + i in the
    // register and op_SetSlot_i32 is the local.set; op_i32_Subtract_ss
    // leaves i - 1 in the register, op_SetSlot_i32 is the local.tee (the
    // register keeps the value) and op_ContinueLoopIf tests it; the exit
    // copies sum into the result slot.
    let loopPC = emit_op(rt, "op_Entry")
    let loopFunc = fixture_function(rt, loopPC, 2)
    emit_int(rt, loopFunc)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 3)
    emit_op(rt, "op_Loop")
    let loopBodyPC = emit_op(rt, "op_i32_Add_ss")
    emit_int(rt, 1)   // operand2: i
    emit_int(rt, 2)   // operand1: sum
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 2)
    emit_op(rt, "op_i32_Subtract_ss")
    emit_int(rt, 3)   // operand2: the constant 1
    emit_int(rt, 1)   // operand1: i
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 1)
    emit_op(rt, "op_ContinueLoopIf")
    emit_int(rt, loopBodyPC)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 0)   // the result slot
    emit_int(rt, 2)   // sum
    emit_op(rt, "op_Return")
    expect_value(t, rt, loopFunc, 10, 55, "loop sum")
    expect_value(t, rt, loopFunc, 100, 5050, "loop sum")

    // local.get 0; if (result i32) { 1 } else { 2 }: op_If, the else page and op_Branch back.
    // Eden: the compiler's shape: the condition moves to the register
    // (op_SetRegister_i32 of the arg slot), op_If_r jumps to the else page,
    // each arm leaves its constant in the result slot, the then arm branches
    // over the else arm to the shared op_Return.
    let ifPC = emit_op(rt, "op_Entry")
    let ifFunc = fixture_function(rt, ifPC, 0)
    emit_int(rt, ifFunc)
    emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 1)
    emit_op(rt, "op_If_r")
    let elsePatch = emit_int(rt, -1)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 0)
    emit_op(rt, "op_Branch")
    let endPatch = emit_int(rt, -1)
    let elsePC = emit_op(rt, "op_Const32")
    emit_u32(rt, 2u)
    emit_int(rt, 0)
    let endPC = emit_op(rt, "op_Return")
    rt.code[elsePatch] = u64(elsePC)
    rt.code[endPatch] = u64(endPC)
    expect_value(t, rt, ifFunc, 5, 1, "if/else")
    expect_value(t, rt, ifFunc, 0, 2, "if/else")

    // i32.const 100; i32.const 200; local.get 0; select -> op_Select picks operand1 when true.
    // Eden: the two constants land in slots 2 and 3, op_Select_i32_sss reads
    // the condition (the arg slot), operand2 and operand1 and leaves the
    // result in the register, op_SetSlot_i32 stores it in the result slot.
    let selPC = emit_op(rt, "op_Entry")
    let selFunc = fixture_function(rt, selPC, 2)
    emit_int(rt, selFunc)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 100u)
    emit_int(rt, 2)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 200u)
    emit_int(rt, 3)
    emit_op(rt, "op_Select_i32_sss")
    emit_int(rt, 1)   // condition
    emit_int(rt, 3)   // operand2
    emit_int(rt, 2)   // operand1
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    expect_value(t, rt, selFunc, 1, 100, "select")
    expect_value(t, rt, selFunc, 0, 200, "select")

    // unreachable -> op_Unreachable traps.
    let unreachablePC = emit_op(rt, "op_Entry")
    let unreachableFunc = fixture_function(rt, unreachablePC, 0)
    emit_int(rt, unreachableFunc)
    emit_op(rt, "op_Unreachable")
    expect_trap(t, rt, unreachableFunc, 0, m3Err_trapUnreachable, "unreachable")
}


// ============================================================================
// Upstream: test_exec_operand_order_and_integer_arithmetic
// ============================================================================


// local.get 0; <op> ; the result into the return slot: the shape of the
// unary cases (clz, ctz, popcnt and their 64-bit forms). Eden: the operation
// reads the arg slot (its _s form) and op_SetSlot_i32 stores the register.
def private unary_on_arg(var rt : M3Runtime; op : string) : IM3Function {
    let pc = emit_op(rt, "op_Entry")
    let f = fixture_function(rt, pc, 0)
    emit_int(rt, f)
    emit_op(rt, op)
    emit_int(rt, 1)
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    return f
}


// local.get 0; i64.extend_i32_s; <op>; i32.wrap_i64; the result into the
// return slot: the shape of the 64-bit unary cases (i64.clz, i64.ctz).
// Eden: op_i64_Extend_i32_s reads the arg slot into the register, the
// operation's _r form works on the register, op_i32_Wrap_i64_r keeps its
// low 32 bits and op_SetSlot_i32 stores them.
def private unary64_on_arg(var rt : M3Runtime; op : string) : IM3Function {
    let pc = emit_op(rt, "op_Entry")
    let f = fixture_function(rt, pc, 0)
    emit_int(rt, f)
    emit_op(rt, "op_i64_Extend_i32_s")
    emit_int(rt, 1)
    emit_op(rt, op)
    emit_op(rt, "op_i32_Wrap_i64_r")
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    return f
}


def test_exec_operand_order_and_integer_arithmetic(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)

    // local.get 0; i32.const 3; i32.sub -> the slot operand is the left side.
    // Eden: the constant lands in slot 2; op_i32_Subtract_ss reads operand2
    // (the constant) then operand1 (the arg) and op_SetSlot_i32 stores the
    // register into the result slot.
    let subPC = emit_op(rt, "op_Entry")
    let subFunc = fixture_function(rt, subPC, 1)
    emit_int(rt, subFunc)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 3u)
    emit_int(rt, 2)
    emit_op(rt, "op_i32_Subtract_ss")
    emit_int(rt, 2)   // operand2: 3
    emit_int(rt, 1)   // operand1: the arg
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    expect_value(t, rt, subFunc, 10, 7, "sub")
    expect_value(t, rt, subFunc, 0, -3, "sub")

    // i32.const 1; i32.const 33; i32.shl -> OP_SHL_32 masks the count to 5 bits.
    let shlPC = emit_op(rt, "op_Entry")
    let shlFunc = fixture_function(rt, shlPC, 2)
    emit_int(rt, shlFunc)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 2)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 33u)
    emit_int(rt, 3)
    emit_op(rt, "op_u32_ShiftLeft_ss")
    emit_int(rt, 3)   // operand2: the count
    emit_int(rt, 2)   // operand1: 1
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    expect_value(t, rt, shlFunc, 0, 2, "shl")

    // i32.const 0x80000000; i32.const 1; i32.rotl -> 1.
    let rotlPC = emit_op(rt, "op_Entry")
    let rotlFunc = fixture_function(rt, rotlPC, 2)
    emit_int(rt, rotlFunc)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 0x80000000u)
    emit_int(rt, 2)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 3)
    emit_op(rt, "op_u32_Rotl_ss")
    emit_int(rt, 3)   // operand2: the count
    emit_int(rt, 2)   // operand1: 0x80000000
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    expect_value(t, rt, rotlFunc, 0, 1, "rotl")

    // OP_CLZ_32 / OP_CTZ_32 special-case zero: clz(0) = ctz(0) = 32; popcnt(0) = 0.
    // local.get 0 feeds each unary op so the argument chooses the value.
    let clzFunc = unary_on_arg(rt, "op_u32_Clz_s")
    expect_value(t, rt, clzFunc, 0, 32, "clz")
    expect_value(t, rt, clzFunc, 1, 31, "clz")
    expect_value(t, rt, clzFunc, -1, 0, "clz")
    let ctzFunc = unary_on_arg(rt, "op_u32_Ctz_s")
    expect_value(t, rt, ctzFunc, 0, 32, "ctz")
    expect_value(t, rt, ctzFunc, 8, 3, "ctz")
    expect_value(t, rt, ctzFunc, -1, 0, "ctz")
    let popFunc = unary_on_arg(rt, "op_u32_Popcnt_s")
    expect_value(t, rt, popFunc, 0, 0, "popcnt")
    expect_value(t, rt, popFunc, 7, 3, "popcnt")
    expect_value(t, rt, popFunc, -1, 32, "popcnt")

    // 64-bit clz/ctz of zero through extend + wrap: i64.clz(0) = i64.ctz(0) = 64.
    // Eden: the sign extension of a negative argument fills the high half
    // (clz64(-1) = 0, ctz64(-16) = 4), which the wrap then drops.
    let clz64Func = unary64_on_arg(rt, "op_u64_Clz_r")
    expect_value(t, rt, clz64Func, 0, 64, "clz64")
    expect_value(t, rt, clz64Func, 1, 63, "clz64")
    expect_value(t, rt, clz64Func, -1, 0, "clz64")
    let ctz64Func = unary64_on_arg(rt, "op_u64_Ctz_r")
    expect_value(t, rt, ctz64Func, 0, 64, "ctz64")
    expect_value(t, rt, ctz64Func, 16, 4, "ctz64")
    expect_value(t, rt, ctz64Func, -16, 4, "ctz64")

    // local.get 0; i64.extend_i32_s; i64.const 3; i64.mul; i32.wrap_i64.
    // Eden: the extend reads the arg slot into the register, the constant
    // lands in slot 2, op_i64_Multiply_rs multiplies the slot by the
    // register and the wrap keeps the low 32 bits of the product.
    let i64PC = emit_op(rt, "op_Entry")
    let i64Func = fixture_function(rt, i64PC, 2)
    emit_int(rt, i64Func)
    emit_op(rt, "op_i64_Extend_i32_s")
    emit_int(rt, 1)
    emit_op(rt, "op_Const64")
    emit(rt, 3ul)
    emit_int(rt, 2)
    emit_op(rt, "op_i64_Multiply_rs")
    emit_int(rt, 2)   // the slot operand: 3
    emit_op(rt, "op_i32_Wrap_i64_r")
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    expect_value(t, rt, i64Func, 10, 30, "i64 mul wrap")
    expect_value(t, rt, i64Func, -4, -12, "i64 mul wrap")
}


// ============================================================================
// Upstream: test_exec_division_traps_and_rem_s_quirk
// ============================================================================


// i32.const a; i32.const b; <op> (or local.get 0 in place of a when
// `argIsLeft`): the two operands in slots 2 and 3, the _ss form, the
// register into the result slot
def private binary_const(var rt : M3Runtime; op : string; argIsLeft : bool; a : u32; b : u32) : IM3Function {
    let pc = emit_op(rt, "op_Entry")
    let f = fixture_function(rt, pc, 2)
    emit_int(rt, f)
    if (!argIsLeft) {
        emit_op(rt, "op_Const32")
        emit_u32(rt, a)
        emit_int(rt, 2)
    }
    emit_op(rt, "op_Const32")
    emit_u32(rt, b)
    emit_int(rt, 3)
    emit_op(rt, op)
    emit_int(rt, 3)                   // operand2: b
    emit_int(rt, argIsLeft ? 1 : 2)   // operand1: the arg or a
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    return f
}


def test_exec_division_traps_and_rem_s_quirk(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)

    // local.get 0; i32.const 0; i32.div_s -> OP_DIV_S traps on a zero divisor.
    let divZero = binary_const(rt, "op_i32_Divide_ss", true, 0u, 0u)
    expect_trap(t, rt, divZero, 7, m3Err_trapDivisionByZero, "div_s by zero")

    // i32.const INT32_MIN; i32.const -1; i32.div_s -> OP_DIV_S integer overflow.
    let divMin = binary_const(rt, "op_i32_Divide_ss", false, 0x80000000u, 0xffffffffu)
    expect_trap(t, rt, divMin, 0, m3Err_trapIntegerOverflow, "div_s overflow")

    // i32.const INT32_MIN; i32.const -1; i32.rem_s -> OP_REM_S yields 0 instead of trapping.
    let remMin = binary_const(rt, "op_i32_Remainder_ss", false, 0x80000000u, 0xffffffffu)
    expect_value(t, rt, remMin, 0, 0, "rem_s INT_MIN % -1")

    // local.get 0; i32.const 7; i32.rem_u -> unsigned remainder.
    let remU = binary_const(rt, "op_u32_Remainder_ss", true, 0u, 7u)
    expect_value(t, rt, remU, 30, 2, "rem_u")
}


// ============================================================================
// Upstream: test_exec_float_unary_ops
// ============================================================================


// <const> into slot 2; <unary>_s on it; <conversion>_r_r into the register;
// the register into the result slot: the shape of the upstream programs
// `f32.const c; f32.floor; i32.reinterpret_f32` and `f64.const c;
// f64.nearest; i32.trunc_f64_s` (a 64-bit constant takes slots 2 and 3, as
// the compiler reserves them)
def private float_unary_program(var rt : M3Runtime; wide : bool; bits : u64; unaryOp : string; convOp : string) : IM3Function {
    let pc = emit_op(rt, "op_Entry")
    let f = fixture_function(rt, pc, 2)
    emit_int(rt, f)
    if (wide) {
        emit_op(rt, "op_Const64")
        emit(rt, bits)
    } else {
        emit_op(rt, "op_Const32")
        emit_u32(rt, u32(bits))
    }
    emit_int(rt, 2)
    emit_op(rt, unaryOp)
    emit_int(rt, 2)
    emit_op(rt, convOp)
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    return f
}


// f64.const c; f64.<unary>; i64.reinterpret_f64; i64.const 63; i64.shr_u;
// i32.wrap_i64: the sign bit of the unary result (the two 64-bit constants
// in slots 2 and 4)
def private sign_bit_program(var rt : M3Runtime; bits : u64; unaryOp : string) : IM3Function {
    let pc = emit_op(rt, "op_Entry")
    let f = fixture_function(rt, pc, 4)
    emit_int(rt, f)
    emit_op(rt, "op_Const64")
    emit(rt, bits)
    emit_int(rt, 2)
    emit_op(rt, unaryOp)
    emit_int(rt, 2)
    emit_op(rt, "op_i64_Reinterpret_f64_r_r")
    emit_op(rt, "op_Const64")
    emit(rt, 63ul)
    emit_int(rt, 4)
    emit_op(rt, "op_u64_ShiftRight_sr")   // the register shifted by the slot
    emit_int(rt, 4)
    emit_op(rt, "op_i32_Wrap_i64_r")
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    return f
}


def test_exec_float_unary_ops(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)

    // f32.const -0.0; f32.floor; i32.reinterpret_f32 -> floorf keeps -0.0.
    let floorNegZero = float_unary_program(rt, false, 0x80000000ul, "op_f32_Floor_s", "op_i32_Reinterpret_f32_r_r")
    expect_value(t, rt, floorNegZero, 0, int(0x80000000u), "f32.floor(-0.0)")

    // f32.const inf; f32.floor -> floorf returns the infinity unchanged.
    let floorInf = float_unary_program(rt, false, 0x7f800000ul, "op_f32_Floor_s", "op_i32_Reinterpret_f32_r_r")
    expect_value(t, rt, floorInf, 0, 2139095040, "f32.floor(inf)")

    // f32.const -0.5; f32.ceil -> ceilf returns -0.0, not +0.0.
    let ceilHalf = float_unary_program(rt, false, 0xbf000000ul, "op_f32_Ceil_s", "op_i32_Reinterpret_f32_r_r")
    expect_value(t, rt, ceilHalf, 0, int(0x80000000u), "f32.ceil(-0.5)")

    // f32.const 2.5; f32.nearest -> rintf rounds the half to even: 2.0.
    let nearest25 = float_unary_program(rt, false, 0x40200000ul, "op_f32_Nearest_s", "op_i32_Reinterpret_f32_r_r")
    expect_value(t, rt, nearest25, 0, 1073741824, "f32.nearest(2.5)")

    // f32.const -0.5; f32.nearest -> -0.0.
    let nearestNegHalf = float_unary_program(rt, false, 0xbf000000ul, "op_f32_Nearest_s", "op_i32_Reinterpret_f32_r_r")
    expect_value(t, rt, nearestNegHalf, 0, int(0x80000000u), "f32.nearest(-0.5)")

    // f64.const -0.0; f64.abs; i64.reinterpret_f64; i64.const 63; i64.shr_u;
    // i32.wrap_i64 -> the sign bit fabs clears.
    let absNegZero = sign_bit_program(rt, 0x8000000000000000ul, "op_f64_Abs_s")
    expect_value(t, rt, absNegZero, 0, 0, "f64.abs(-0.0) sign bit")

    // f64.const 2.5; f64.nearest; i32.trunc_f64_s -> rint rounds the half to even.
    let nearest25d = float_unary_program(rt, true, 0x4004000000000000ul, "op_f64_Nearest_s", "op_i32_Trunc_f64_r_r")
    expect_value(t, rt, nearest25d, 0, 2, "f64.nearest(2.5)")

    // f64.const -0.5; f64.nearest -> -0.0: the sign bit survives.
    let nearestNegHalfD = sign_bit_program(rt, 0xbfe0000000000000ul, "op_f64_Nearest_s")
    expect_value(t, rt, nearestNegHalfD, 0, 1, "f64.nearest(-0.5) sign bit")
}


// ============================================================================
// Eden: the op table
// ============================================================================


def test_op_table(var t : TestRun; fx : FixtureSource) {
    m3_build_op_table()
    equal(t, m3_OpCount(), OP_COUNT, "the three parts register {OP_COUNT} operations")
    equal(t, length(g_ops), length(g_opIndex), "one index entry per operation")

    // the registration order is the index: op_NoOp first, then file order
    // (the part-2 families and the part-3 conversions precede the part-1
    // operations in the upstream file)
    equal(t, m3_OpWord("op_NoOp"), 0ul, "op_NoOp is word 0")
    equal(t, m3_OpWord("op_i32_Equal_rs"), u64(PART2_FIRST_WORD), "op_i32_Equal_rs follows op_NoOp (file order)")
    equal(t, m3_OpWord("op_u64_Popcnt_s"), u64(PART2_LAST_WORD), "op_u64_Popcnt_s is the last word of part 2")
    equal(t, m3_OpWord("op_i32_Wrap_i64_r"), u64(PART3_FIRST_WORD), "op_i32_Wrap_i64_r follows the part-2 range")
    equal(t, m3_OpWord("op_f64_Reinterpret_i64_s_s"), u64(PART3_LAST_WORD), "op_f64_Reinterpret_i64_s_s is the last word of part 3")
    equal(t, m3_OpWord("op_GetGlobal_s32"), u64(PART3_LAST_WORD + 1), "op_GetGlobal_s32 follows the part-3 range")
    equal(t, m3_OpWord("op_i64_Store_i64_ss"), u64(OP_COUNT - 1), "op_i64_Store_i64_ss is the last word")
    check(t, m3_OpWord("op_i32_Add_rs") < m3_OpWord("op_u32_Divide_sr"), "op_i32_Add_rs precedes op_u32_Divide_sr")
    check(t, m3_OpWord("op_i32_Trunc_f32_r_r") < m3_OpWord("op_i32_TruncSat_f32_r_r"), "op_i32_Trunc_f32_r_r precedes op_i32_TruncSat_f32_r_r")
    check(t, m3_OpWord("op_f32_Convert_i32_r_r") < m3_OpWord("op_f32_Convert_i32_s_r"), "the Convert forms register r_r, s_r, r_s, s_s (C's macro order)")
    check(t, m3_OpWord("op_f32_Convert_i32_s_r") < m3_OpWord("op_f32_Convert_i32_r_s"), "... s_r before r_s")
    check(t, m3_OpWord("op_i32_Reinterpret_f32_r_s") < m3_OpWord("op_i32_Reinterpret_f32_s_r"), "the Reinterpret forms register r_r, r_s, s_r, s_s")
    check(t, m3_OpWord("op_Entry") < m3_OpWord("op_Loop"), "op_Entry precedes op_Loop")
    check(t, m3_OpWord("op_Return") < m3_OpWord("op_Const32"), "op_Return precedes op_Const32")

    // the round trip: the operation behind a word is the named one
    var rt = M3Runtime()
    rt.trap = m3Err_none
    let unreachable = m3_OpAt(int(m3_OpWord("op_Unreachable")))
    let r = invoke(unreachable, rt)
    equal(t, r, M3_TRAP, "m3_OpAt(m3_OpWord(op_Unreachable)) traps")
    equal_str(t, rt.trap, m3Err_trapUnreachable, "... with the unreachable trap string")
    let noOp = m3_OpAt(int(m3_OpWord("op_NoOp")))
    let r2 = invoke(noOp, rt)
    equal(t, r2, M3_TRAP, "op_NoOp is the c_opNull sentinel and traps")
    equal_str(t, rt.trap, m3Err_noCompiler, "... with m3Err_noCompiler")
    let ret = m3_OpAt(int(m3_OpWord("op_Return")))
    equal(t, invoke(ret, rt), M3_RETURN, "m3_OpAt(m3_OpWord(op_Return)) returns M3_RETURN")

    // idempotent: a rebuild gives the same table
    let entryBefore = m3_OpWord("op_Entry")
    m3_build_op_table()
    equal(t, m3_OpCount(), OP_COUNT, "a rebuild registers the same count")
    equal(t, m3_OpWord("op_Entry"), entryBefore, "a rebuild keeps the words")

    // an unknown name is a d_m3Assert panic (the header's decision)
    var panicked = false
    try {
        let w = m3_OpWord("op_DoesNotExist")
        check(t, w == 0ul, "unreachable: m3_OpWord must not return for an unknown name")
    } recover {
        panicked = true
    }
    check(t, panicked, "m3_OpWord panics on an unknown name")
}


// ============================================================================
// Eden: every operation of part 2 once through the dispatcher
// ============================================================================


// One row of the table: the operation, its operands as register / slot
// words (a 32-bit integer zero-extended, an i64 / u64 its bits, an f32 its
// float bits, an f64 its double bits), the expected result word (the same
// encoding) or the trap string. `a` is the LEFT operand of the C macro
// (`a OP b`): the slot of an _rs form, the register of an _sr form,
// operand1 of an _ss form, the single operand of a unary form.
struct OpCase {
    name : string
    a : u64 = 0ul
    b : u64 = 0ul
    want : u64 = 0ul
    trap : string = ""
}


def private oc(name : string; a : u64; b : u64; want : u64) : OpCase {
    return OpCase(name = name, a = a, b = b, want = want)
}


def private oct(name : string; a : u64; b : u64; trap : string) : OpCase {
    return OpCase(name = name, a = a, b = b, trap = trap)
}


// Runs one operation: installs the operands as the operation's form reads
// them (the register for the _r side, slot 2 / slot 3 of a frame at sp = 4
// with the slot immediates emitted in the order the body reads them), then
// checks the register the C macro family writes: fp0 for a float result
// (bit-exact), r0 for the rest with the extension convention of the
// m3_exec header (an i32 result sign-extended, a u32 / bit-count result
// zero-extended, a compare 0 / 1, a 64-bit result its bits).
def private run_op_case(var t : TestRun; var rt : M3Runtime; c : OpCase) {
    let name = c.name
    let isF32 = starts_with(name, "op_f32_")
    let isF64 = starts_with(name, "op_f64_")
    let isI32 = starts_with(name, "op_i32_")
    let isU32 = starts_with(name, "op_u32_")
    let isCompare = find(name, "Equal") >= 0 || find(name, "LessThan") >= 0 || find(name, "GreaterThan") >= 0
    let floatResult = (isF32 || isF64) && !isCompare

    for (i in range(length(rt.stack))) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    rt.sp = 4
    rt.r0 = 0ul
    rt.fp0 = 0.0lf
    rt.trap = m3Err_none
    clear(rt.code)
    var regWord = 0ul
    var hasReg = false
    if (ends_with(name, "_ss")) {
        rt.stack[rt.sp + 2] = c.a
        rt.stack[rt.sp + 3] = c.b
        emit_int(rt, 3)   // operand2, read first
        emit_int(rt, 2)   // operand1
    } elif (ends_with(name, "_rs")) {
        rt.stack[rt.sp + 2] = c.a   // the slot operand is the left side
        regWord = c.b
        hasReg = true
        emit_int(rt, 2)
    } elif (ends_with(name, "_sr")) {
        regWord = c.a               // the register is the left side
        hasReg = true
        rt.stack[rt.sp + 2] = c.b
        emit_int(rt, 2)
    } elif (ends_with(name, "_r")) {
        regWord = c.a
        hasReg = true
    } else {
        rt.stack[rt.sp + 2] = c.a   // the _s form
        emit_int(rt, 2)
    }
    if (hasReg) {
        if (isF32) {
            rt.fp0 = f64(uint_bits_to_float(u32(regWord)))
        } elif (isF64) {
            rt.fp0 = uint64_bits_to_double(regWord)
        } else {
            rt.r0 = regWord
        }
    }
    rt.pc = 0
    let opWord = int(m3_OpWord(name))
    mark_executed(opWord)
    let op = m3_OpAt(opWord)
    let r = invoke(op, rt)
    if (c.trap != "") {
        equal(t, r, M3_TRAP, "{name} traps")
        equal_str(t, rt.trap, c.trap, "{name} trap string")
        return
    }
    equal(t, r, M3_NEXT, "{name} continues")
    equal(t, rt.pc, length(rt.code), "{name} consumed its immediates")
    if (floatResult) {
        if (isF32) {
            equal(t, float_bits_to_uint(f32(rt.fp0)), u32(c.want), "{name} f32 result bits")
        } else {
            equal(t, double_bits_to_uint64(rt.fp0), c.want, "{name} f64 result bits")
        }
    } elif (isI32 && !isCompare) {
        equal(t, rt.r0, u64(i64(i32(u32(c.want)))), "{name} i32 result, sign-extended")
    } elif (isU32 && !isCompare) {
        equal(t, rt.r0, u64(u32(c.want)), "{name} u32 result, zero-extended")
    } else {
        equal(t, rt.r0, c.want, "{name} result")
    }
}


def test_arithmetic_families(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(16)
    var cases : array<OpCase>

    // the compares: -2 against 3 as signed words, the same words unsigned
    // (0xfffffffe against 3), 1.5 / -2.0 / 3.0 and a NaN as floats; the
    // operands are asymmetric so a swapped _rs / _sr order fails; every
    // float compare form also has its NaN rows (DESIGN section 1)
    push(cases, oc("op_i32_Equal_rs", 5ul, 5ul, 1ul))
    push(cases, oc("op_i32_Equal_ss", 5ul, 6ul, 0ul))
    push(cases, oc("op_i32_NotEqual_rs", 5ul, 6ul, 1ul))
    push(cases, oc("op_i32_NotEqual_ss", 5ul, 5ul, 0ul))
    push(cases, oc("op_i32_LessThan_sr", 0xfffffffeul, 3ul, 1ul))
    push(cases, oc("op_i32_LessThan_rs", 3ul, 0xfffffffeul, 0ul))
    push(cases, oc("op_i32_LessThan_ss", 0xfffffffeul, 3ul, 1ul))
    push(cases, oc("op_i32_GreaterThan_sr", 0xfffffffeul, 3ul, 0ul))
    push(cases, oc("op_i32_GreaterThan_rs", 3ul, 0xfffffffeul, 1ul))
    push(cases, oc("op_i32_GreaterThan_ss", 3ul, 0xfffffffeul, 1ul))
    push(cases, oc("op_i32_LessThanOrEqual_sr", 0xfffffffeul, 3ul, 1ul))
    push(cases, oc("op_i32_LessThanOrEqual_rs", 3ul, 0xfffffffeul, 0ul))
    push(cases, oc("op_i32_LessThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_i32_GreaterThanOrEqual_sr", 0xfffffffeul, 3ul, 0ul))
    push(cases, oc("op_i32_GreaterThanOrEqual_rs", 3ul, 0xfffffffeul, 1ul))
    push(cases, oc("op_i32_GreaterThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_i64_Equal_rs", 5ul, 5ul, 1ul))
    push(cases, oc("op_i64_Equal_ss", 5ul, 6ul, 0ul))
    push(cases, oc("op_i64_NotEqual_rs", 5ul, 6ul, 1ul))
    push(cases, oc("op_i64_NotEqual_ss", 5ul, 5ul, 0ul))
    push(cases, oc("op_i64_LessThan_sr", 0xfffffffffffffffeul, 3ul, 1ul))
    push(cases, oc("op_i64_LessThan_rs", 3ul, 0xfffffffffffffffeul, 0ul))
    push(cases, oc("op_i64_LessThan_ss", 0xfffffffffffffffeul, 3ul, 1ul))
    push(cases, oc("op_i64_GreaterThan_sr", 0xfffffffffffffffeul, 3ul, 0ul))
    push(cases, oc("op_i64_GreaterThan_rs", 3ul, 0xfffffffffffffffeul, 1ul))
    push(cases, oc("op_i64_GreaterThan_ss", 3ul, 0xfffffffffffffffeul, 1ul))
    push(cases, oc("op_i64_LessThanOrEqual_sr", 0xfffffffffffffffeul, 3ul, 1ul))
    push(cases, oc("op_i64_LessThanOrEqual_rs", 3ul, 0xfffffffffffffffeul, 0ul))
    push(cases, oc("op_i64_LessThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_i64_GreaterThanOrEqual_sr", 0xfffffffffffffffeul, 3ul, 0ul))
    push(cases, oc("op_i64_GreaterThanOrEqual_rs", 3ul, 0xfffffffffffffffeul, 1ul))
    push(cases, oc("op_i64_GreaterThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_u32_LessThan_sr", 0xfffffffeul, 3ul, 0ul))
    push(cases, oc("op_u32_LessThan_rs", 3ul, 0xfffffffeul, 1ul))
    push(cases, oc("op_u32_LessThan_ss", 0xfffffffeul, 3ul, 0ul))
    push(cases, oc("op_u32_GreaterThan_sr", 0xfffffffeul, 3ul, 1ul))
    push(cases, oc("op_u32_GreaterThan_rs", 3ul, 0xfffffffeul, 0ul))
    push(cases, oc("op_u32_GreaterThan_ss", 0xfffffffeul, 3ul, 1ul))
    push(cases, oc("op_u32_LessThanOrEqual_sr", 0xfffffffeul, 3ul, 0ul))
    push(cases, oc("op_u32_LessThanOrEqual_rs", 3ul, 0xfffffffeul, 1ul))
    push(cases, oc("op_u32_LessThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_u32_GreaterThanOrEqual_sr", 0xfffffffeul, 3ul, 1ul))
    push(cases, oc("op_u32_GreaterThanOrEqual_rs", 3ul, 0xfffffffeul, 0ul))
    push(cases, oc("op_u32_GreaterThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_u64_LessThan_sr", 0xfffffffffffffffeul, 3ul, 0ul))
    push(cases, oc("op_u64_LessThan_rs", 3ul, 0xfffffffffffffffeul, 1ul))
    push(cases, oc("op_u64_LessThan_ss", 0xfffffffffffffffeul, 3ul, 0ul))
    push(cases, oc("op_u64_GreaterThan_sr", 0xfffffffffffffffeul, 3ul, 1ul))
    push(cases, oc("op_u64_GreaterThan_rs", 3ul, 0xfffffffffffffffeul, 0ul))
    push(cases, oc("op_u64_GreaterThan_ss", 0xfffffffffffffffeul, 3ul, 1ul))
    push(cases, oc("op_u64_LessThanOrEqual_sr", 0xfffffffffffffffeul, 3ul, 0ul))
    push(cases, oc("op_u64_LessThanOrEqual_rs", 3ul, 0xfffffffffffffffeul, 1ul))
    push(cases, oc("op_u64_LessThanOrEqual_ss", 3ul, 3ul, 1ul))
    push(cases, oc("op_u64_GreaterThanOrEqual_sr", 0xfffffffffffffffeul, 3ul, 1ul))
    push(cases, oc("op_u64_GreaterThanOrEqual_rs", 3ul, 0xfffffffffffffffeul, 0ul))
    push(cases, oc("op_u64_GreaterThanOrEqual_ss", 3ul, 3ul, 1ul))
    // f32: 1.5 = 0x3fc00000, -2.0 = 0xc0000000, 3.0 = 0x40400000, NaN = 0x7fc00000
    push(cases, oc("op_f32_Equal_rs", 0x3fc00000ul, 0x3fc00000ul, 1ul))
    push(cases, oc("op_f32_Equal_ss", 0x7fc00000ul, 0x7fc00000ul, 0ul))   // NaN == NaN is false
    push(cases, oc("op_f32_NotEqual_rs", 0x7fc00000ul, 0x7fc00000ul, 1ul))   // NaN != NaN is true
    push(cases, oc("op_f32_NotEqual_ss", 0x3fc00000ul, 0x3fc00000ul, 0ul))
    push(cases, oc("op_f32_LessThan_sr", 0xc0000000ul, 0x40400000ul, 1ul))
    push(cases, oc("op_f32_LessThan_rs", 0x40400000ul, 0xc0000000ul, 0ul))
    push(cases, oc("op_f32_LessThan_ss", 0xc0000000ul, 0x40400000ul, 1ul))
    push(cases, oc("op_f32_GreaterThan_sr", 0xc0000000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_rs", 0x40400000ul, 0xc0000000ul, 1ul))
    push(cases, oc("op_f32_GreaterThan_ss", 0x40400000ul, 0xc0000000ul, 1ul))
    push(cases, oc("op_f32_LessThanOrEqual_sr", 0xc0000000ul, 0x40400000ul, 1ul))
    push(cases, oc("op_f32_LessThanOrEqual_rs", 0x40400000ul, 0xc0000000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_ss", 0x40400000ul, 0x40400000ul, 1ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_sr", 0xc0000000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_rs", 0x40400000ul, 0xc0000000ul, 1ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_ss", 0x40400000ul, 0x40400000ul, 1ul))
    // f32 NaN rows (DESIGN section 1): a NaN on either side of every form and
    // on both sides of eq / ne; wasm f32.eq / lt / gt / le / ge are 0 on a
    // NaN, f32.ne is 1 (C: the IEEE unordered compare)
    push(cases, oc("op_f32_Equal_rs", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_Equal_rs", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_Equal_rs", 0x7fc00000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_Equal_ss", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_Equal_ss", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_NotEqual_rs", 0x7fc00000ul, 0x40400000ul, 1ul))
    push(cases, oc("op_f32_NotEqual_rs", 0x40400000ul, 0x7fc00000ul, 1ul))
    push(cases, oc("op_f32_NotEqual_ss", 0x7fc00000ul, 0x40400000ul, 1ul))
    push(cases, oc("op_f32_NotEqual_ss", 0x40400000ul, 0x7fc00000ul, 1ul))
    push(cases, oc("op_f32_NotEqual_ss", 0x7fc00000ul, 0x7fc00000ul, 1ul))
    push(cases, oc("op_f32_LessThan_sr", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_LessThan_sr", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_LessThan_rs", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_LessThan_rs", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_LessThan_ss", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_LessThan_ss", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_sr", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_sr", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_rs", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_rs", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_ss", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThan_ss", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_sr", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_sr", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_rs", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_rs", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_ss", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_LessThanOrEqual_ss", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_sr", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_sr", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_rs", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_rs", 0x40400000ul, 0x7fc00000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_ss", 0x7fc00000ul, 0x40400000ul, 0ul))
    push(cases, oc("op_f32_GreaterThanOrEqual_ss", 0x40400000ul, 0x7fc00000ul, 0ul))
    // f64: 1.5 = 0x3ff8..., -2.0 = 0xc000..., 3.0 = 0x4008..., NaN = 0x7ff8...
    push(cases, oc("op_f64_Equal_rs", 0x3ff8000000000000ul, 0x3ff8000000000000ul, 1ul))
    push(cases, oc("op_f64_Equal_ss", 0x7ff8000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_NotEqual_rs", 0x7ff8000000000000ul, 0x7ff8000000000000ul, 1ul))
    push(cases, oc("op_f64_NotEqual_ss", 0x3ff8000000000000ul, 0x3ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_sr", 0xc000000000000000ul, 0x4008000000000000ul, 1ul))
    push(cases, oc("op_f64_LessThan_rs", 0x4008000000000000ul, 0xc000000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_ss", 0xc000000000000000ul, 0x4008000000000000ul, 1ul))
    push(cases, oc("op_f64_GreaterThan_sr", 0xc000000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_rs", 0x4008000000000000ul, 0xc000000000000000ul, 1ul))
    push(cases, oc("op_f64_GreaterThan_ss", 0x4008000000000000ul, 0xc000000000000000ul, 1ul))
    push(cases, oc("op_f64_LessThanOrEqual_sr", 0xc000000000000000ul, 0x4008000000000000ul, 1ul))
    push(cases, oc("op_f64_LessThanOrEqual_rs", 0x4008000000000000ul, 0xc000000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_ss", 0x4008000000000000ul, 0x4008000000000000ul, 1ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_sr", 0xc000000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_rs", 0x4008000000000000ul, 0xc000000000000000ul, 1ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_ss", 0x4008000000000000ul, 0x4008000000000000ul, 1ul))
    // f64 NaN rows, the same shape as the f32 ones
    push(cases, oc("op_f64_Equal_rs", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_Equal_rs", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_Equal_rs", 0x7ff8000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_Equal_ss", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_Equal_ss", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_NotEqual_rs", 0x7ff8000000000000ul, 0x4008000000000000ul, 1ul))
    push(cases, oc("op_f64_NotEqual_rs", 0x4008000000000000ul, 0x7ff8000000000000ul, 1ul))
    push(cases, oc("op_f64_NotEqual_ss", 0x7ff8000000000000ul, 0x4008000000000000ul, 1ul))
    push(cases, oc("op_f64_NotEqual_ss", 0x4008000000000000ul, 0x7ff8000000000000ul, 1ul))
    push(cases, oc("op_f64_NotEqual_ss", 0x7ff8000000000000ul, 0x7ff8000000000000ul, 1ul))
    push(cases, oc("op_f64_LessThan_sr", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_sr", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_rs", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_rs", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_ss", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThan_ss", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_sr", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_sr", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_rs", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_rs", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_ss", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThan_ss", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_sr", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_sr", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_rs", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_rs", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_ss", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_LessThanOrEqual_ss", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_sr", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_sr", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_rs", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_rs", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_ss", 0x7ff8000000000000ul, 0x4008000000000000ul, 0ul))
    push(cases, oc("op_f64_GreaterThanOrEqual_ss", 0x4008000000000000ul, 0x7ff8000000000000ul, 0ul))

    // the integer arithmetic: wrapping add / multiply, the operand order
    // of subtract, the masked shift counts, the arithmetic shift of a
    // negative value
    push(cases, oc("op_i32_Add_rs", 0x7ffffffful, 1ul, 0x80000000ul))
    push(cases, oc("op_i32_Add_ss", 2ul, 3ul, 5ul))
    push(cases, oc("op_i64_Add_rs", 0x7ffffffffffffffful, 1ul, 0x8000000000000000ul))
    push(cases, oc("op_i64_Add_ss", 2ul, 3ul, 5ul))
    push(cases, oc("op_i32_Multiply_rs", 0x10000ul, 0x10000ul, 0ul))
    push(cases, oc("op_i32_Multiply_ss", 0xfffffffdul, 4ul, 0xfffffff4ul))
    push(cases, oc("op_i64_Multiply_rs", 0x100000000ul, 0x100000000ul, 0ul))
    push(cases, oc("op_i64_Multiply_ss", 0xfffffffffffffffdul, 4ul, 0xfffffffffffffff4ul))
    push(cases, oc("op_i32_Subtract_sr", 10ul, 3ul, 7ul))
    push(cases, oc("op_i32_Subtract_rs", 3ul, 10ul, 0xfffffff9ul))
    push(cases, oc("op_i32_Subtract_ss", 0ul, 1ul, 0xfffffffful))
    push(cases, oc("op_i64_Subtract_sr", 10ul, 3ul, 7ul))
    push(cases, oc("op_i64_Subtract_rs", 3ul, 10ul, 0xfffffffffffffff9ul))
    push(cases, oc("op_i64_Subtract_ss", 0ul, 1ul, 0xfffffffffffffffful))
    push(cases, oc("op_u32_ShiftLeft_sr", 1ul, 33ul, 2ul))
    push(cases, oc("op_u32_ShiftLeft_rs", 1ul, 4ul, 16ul))
    push(cases, oc("op_u32_ShiftLeft_ss", 0x80000001ul, 1ul, 2ul))
    push(cases, oc("op_u64_ShiftLeft_sr", 1ul, 65ul, 2ul))
    push(cases, oc("op_u64_ShiftLeft_rs", 1ul, 40ul, 0x10000000000ul))
    push(cases, oc("op_u64_ShiftLeft_ss", 0x8000000000000001ul, 1ul, 2ul))
    push(cases, oc("op_i32_ShiftRight_sr", 0xfffffff8ul, 1ul, 0xfffffffcul))
    push(cases, oc("op_i32_ShiftRight_rs", 0xfffffff8ul, 33ul, 0xfffffffcul))
    push(cases, oc("op_i32_ShiftRight_ss", 0x80000000ul, 31ul, 0xfffffffful))
    push(cases, oc("op_i64_ShiftRight_sr", 0xfffffffffffffff8ul, 1ul, 0xfffffffffffffffcul))
    push(cases, oc("op_i64_ShiftRight_rs", 0xfffffffffffffff8ul, 65ul, 0xfffffffffffffffcul))
    push(cases, oc("op_i64_ShiftRight_ss", 0x8000000000000000ul, 63ul, 0xfffffffffffffffful))
    push(cases, oc("op_u32_ShiftRight_sr", 0x80000000ul, 31ul, 1ul))
    push(cases, oc("op_u32_ShiftRight_rs", 0xfffffff8ul, 1ul, 0x7ffffffcul))
    push(cases, oc("op_u32_ShiftRight_ss", 0x80000000ul, 33ul, 0x40000000ul))
    push(cases, oc("op_u64_ShiftRight_sr", 0x8000000000000000ul, 63ul, 1ul))
    push(cases, oc("op_u64_ShiftRight_rs", 0xfffffffffffffff8ul, 1ul, 0x7ffffffffffffffcul))
    push(cases, oc("op_u64_ShiftRight_ss", 0x8000000000000000ul, 65ul, 0x4000000000000000ul))
    push(cases, oc("op_u32_And_rs", 0xff00ff00ul, 0x0ff00ff0ul, 0x0f000f00ul))
    push(cases, oc("op_u32_And_ss", 0xfffffffful, 0x12345678ul, 0x12345678ul))
    push(cases, oc("op_u32_Or_rs", 0xff00ul, 0x00fful, 0xfffful))
    push(cases, oc("op_u32_Or_ss", 0x80000000ul, 1ul, 0x80000001ul))
    push(cases, oc("op_u32_Xor_rs", 0xfffffffful, 0x0f0f0f0ful, 0xf0f0f0f0ul))
    push(cases, oc("op_u32_Xor_ss", 0x1234ul, 0x1234ul, 0ul))
    push(cases, oc("op_u64_And_rs", 0xff00ff00ff00ff00ul, 0x0ff00ff00ff00ff0ul, 0x0f000f000f000f00ul))
    push(cases, oc("op_u64_And_ss", 0xfffffffffffffffful, 0x123456789abcdef0ul, 0x123456789abcdef0ul))
    push(cases, oc("op_u64_Or_rs", 0xff00000000000000ul, 0xfful, 0xff000000000000fful))
    push(cases, oc("op_u64_Or_ss", 0x8000000000000000ul, 1ul, 0x8000000000000001ul))
    push(cases, oc("op_u64_Xor_rs", 0xfffffffffffffffful, 0x0f0f0f0f0f0f0f0ful, 0xf0f0f0f0f0f0f0f0ul))
    push(cases, oc("op_u64_Xor_ss", 0x123456789abcdef0ul, 0x123456789abcdef0ul, 0ul))

    // the float arithmetic, bit-exact: 1.5 + 3.0 = 4.5, 1.5 + -2.0 = -0.5,
    // -2.0 * 3.0 = -6.0, 1.5 - 3.0 = -1.5, -2.0 - 3.0 = -5.0, 3.0 / -2.0 =
    // -1.5, 1.5 / 3.0 = 0.5, 1.0 / 0.0 = +inf
    push(cases, oc("op_f32_Add_rs", 0x3fc00000ul, 0x40400000ul, 0x40900000ul))
    push(cases, oc("op_f32_Add_ss", 0x3fc00000ul, 0xc0000000ul, 0xbf000000ul))
    push(cases, oc("op_f32_Multiply_rs", 0x3fc00000ul, 0x40400000ul, 0x40900000ul))
    push(cases, oc("op_f32_Multiply_ss", 0xc0000000ul, 0x40400000ul, 0xc0c00000ul))
    push(cases, oc("op_f32_Subtract_sr", 0x3fc00000ul, 0x40400000ul, 0xbfc00000ul))
    push(cases, oc("op_f32_Subtract_rs", 0x40400000ul, 0x3fc00000ul, 0x3fc00000ul))
    push(cases, oc("op_f32_Subtract_ss", 0xc0000000ul, 0x40400000ul, 0xc0a00000ul))
    push(cases, oc("op_f32_Divide_sr", 0x40400000ul, 0xc0000000ul, 0xbfc00000ul))
    push(cases, oc("op_f32_Divide_rs", 0x3fc00000ul, 0x40400000ul, 0x3f000000ul))
    push(cases, oc("op_f32_Divide_ss", 0x3f800000ul, 0ul, 0x7f800000ul))
    push(cases, oc("op_f64_Add_rs", 0x3ff8000000000000ul, 0x4008000000000000ul, 0x4012000000000000ul))
    push(cases, oc("op_f64_Add_ss", 0x3ff8000000000000ul, 0xc000000000000000ul, 0xbfe0000000000000ul))
    push(cases, oc("op_f64_Multiply_rs", 0x3ff8000000000000ul, 0x4008000000000000ul, 0x4012000000000000ul))
    push(cases, oc("op_f64_Multiply_ss", 0xc000000000000000ul, 0x4008000000000000ul, 0xc018000000000000ul))
    push(cases, oc("op_f64_Subtract_sr", 0x3ff8000000000000ul, 0x4008000000000000ul, 0xbff8000000000000ul))
    push(cases, oc("op_f64_Subtract_rs", 0x4008000000000000ul, 0x3ff8000000000000ul, 0x3ff8000000000000ul))
    push(cases, oc("op_f64_Subtract_ss", 0xc000000000000000ul, 0x4008000000000000ul, 0xc014000000000000ul))
    push(cases, oc("op_f64_Divide_sr", 0x4008000000000000ul, 0xc000000000000000ul, 0xbff8000000000000ul))
    push(cases, oc("op_f64_Divide_rs", 0x3ff8000000000000ul, 0x4008000000000000ul, 0x3fe0000000000000ul))
    push(cases, oc("op_f64_Divide_ss", 0x3ff0000000000000ul, 0ul, 0x7ff0000000000000ul))

    // the rotations, the count masked to the width
    push(cases, oc("op_u32_Rotl_sr", 0x80000000ul, 1ul, 1ul))
    push(cases, oc("op_u32_Rotl_rs", 0x80000000ul, 33ul, 1ul))
    push(cases, oc("op_u32_Rotl_ss", 0x12345678ul, 4ul, 0x23456781ul))
    push(cases, oc("op_u32_Rotr_sr", 1ul, 1ul, 0x80000000ul))
    push(cases, oc("op_u32_Rotr_rs", 1ul, 33ul, 0x80000000ul))
    push(cases, oc("op_u32_Rotr_ss", 0x12345678ul, 4ul, 0x81234567ul))
    push(cases, oc("op_u64_Rotl_sr", 0x8000000000000000ul, 1ul, 1ul))
    push(cases, oc("op_u64_Rotl_rs", 0x8000000000000000ul, 65ul, 1ul))
    push(cases, oc("op_u64_Rotl_ss", 0x123456789abcdef0ul, 8ul, 0x3456789abcdef012ul))
    push(cases, oc("op_u64_Rotr_sr", 1ul, 1ul, 0x8000000000000000ul))
    push(cases, oc("op_u64_Rotr_rs", 1ul, 65ul, 0x8000000000000000ul))
    push(cases, oc("op_u64_Rotr_ss", 0x123456789abcdef0ul, 8ul, 0xf0123456789abcdeul))

    // the division: truncation toward zero, the zero-divisor trap on every
    // width, the INT_MIN / -1 overflow trap and the INT_MIN % -1 = 0 quirk
    push(cases, oc("op_u32_Divide_sr", 7ul, 2ul, 3ul))
    push(cases, oc("op_u32_Divide_rs", 0xfffffffeul, 2ul, 0x7ffffffful))
    push(cases, oct("op_u32_Divide_ss", 1ul, 0ul, m3Err_trapDivisionByZero))
    push(cases, oc("op_u32_Remainder_sr", 7ul, 3ul, 1ul))
    push(cases, oc("op_u32_Remainder_rs", 0xfffffffful, 16ul, 15ul))
    push(cases, oct("op_u32_Remainder_ss", 5ul, 0ul, m3Err_trapDivisionByZero))
    push(cases, oc("op_i32_Divide_sr", 0xfffffff9ul, 2ul, 0xfffffffdul))
    push(cases, oct("op_i32_Divide_rs", 0x80000000ul, 0xfffffffful, m3Err_trapIntegerOverflow))
    push(cases, oc("op_i32_Divide_ss", 7ul, 0xfffffffeul, 0xfffffffdul))
    push(cases, oc("op_i32_Remainder_sr", 0xfffffff9ul, 2ul, 0xfffffffful))
    push(cases, oc("op_i32_Remainder_rs", 0x80000000ul, 0xfffffffful, 0ul))
    push(cases, oct("op_i32_Remainder_ss", 7ul, 0ul, m3Err_trapDivisionByZero))
    push(cases, oc("op_u64_Divide_sr", 7ul, 2ul, 3ul))
    push(cases, oc("op_u64_Divide_rs", 0xfffffffffffffffeul, 2ul, 0x7ffffffffffffffful))
    push(cases, oct("op_u64_Divide_ss", 1ul, 0ul, m3Err_trapDivisionByZero))
    push(cases, oc("op_u64_Remainder_sr", 7ul, 3ul, 1ul))
    push(cases, oc("op_u64_Remainder_rs", 0xfffffffffffffffful, 16ul, 15ul))
    push(cases, oct("op_u64_Remainder_ss", 5ul, 0ul, m3Err_trapDivisionByZero))
    push(cases, oc("op_i64_Divide_sr", 0xfffffffffffffff9ul, 2ul, 0xfffffffffffffffdul))
    push(cases, oct("op_i64_Divide_rs", 0x8000000000000000ul, 0xfffffffffffffffful, m3Err_trapIntegerOverflow))
    push(cases, oc("op_i64_Divide_ss", 7ul, 0xfffffffffffffffeul, 0xfffffffffffffffdul))
    push(cases, oc("op_i64_Remainder_sr", 0xfffffffffffffff9ul, 2ul, 0xfffffffffffffffful))
    push(cases, oc("op_i64_Remainder_rs", 0x8000000000000000ul, 0xfffffffffffffffful, 0ul))
    push(cases, oct("op_i64_Remainder_ss", 7ul, 0ul, m3Err_trapDivisionByZero))

    // min / max with the wasm signed-zero rule (min(+0, -0) = -0, max(-0,
    // +0) = +0), copysign as a bit copy (the sign of -0.0 is copied)
    push(cases, oc("op_f32_Min_sr", 0x3fc00000ul, 0xc0000000ul, 0xc0000000ul))
    push(cases, oc("op_f32_Min_rs", 0ul, 0x80000000ul, 0x80000000ul))
    push(cases, oc("op_f32_Min_ss", 0x40400000ul, 0x3fc00000ul, 0x3fc00000ul))
    push(cases, oc("op_f32_Max_sr", 0x3fc00000ul, 0xc0000000ul, 0x3fc00000ul))
    push(cases, oc("op_f32_Max_rs", 0x80000000ul, 0ul, 0ul))
    push(cases, oc("op_f32_Max_ss", 0x40400000ul, 0x3fc00000ul, 0x40400000ul))
    push(cases, oc("op_f32_CopySign_sr", 0x3fc00000ul, 0xc0000000ul, 0xbfc00000ul))
    push(cases, oc("op_f32_CopySign_rs", 0xc0000000ul, 0x3fc00000ul, 0x40000000ul))
    push(cases, oc("op_f32_CopySign_ss", 0x40400000ul, 0x80000000ul, 0xc0400000ul))
    push(cases, oc("op_f64_Min_sr", 0x3ff8000000000000ul, 0xc000000000000000ul, 0xc000000000000000ul))
    push(cases, oc("op_f64_Min_rs", 0ul, 0x8000000000000000ul, 0x8000000000000000ul))
    push(cases, oc("op_f64_Min_ss", 0x4008000000000000ul, 0x3ff8000000000000ul, 0x3ff8000000000000ul))
    push(cases, oc("op_f64_Max_sr", 0x3ff8000000000000ul, 0xc000000000000000ul, 0x3ff8000000000000ul))
    push(cases, oc("op_f64_Max_rs", 0x8000000000000000ul, 0ul, 0ul))
    push(cases, oc("op_f64_Max_ss", 0x4008000000000000ul, 0x3ff8000000000000ul, 0x4008000000000000ul))
    push(cases, oc("op_f64_CopySign_sr", 0x3ff8000000000000ul, 0xc000000000000000ul, 0xbff8000000000000ul))
    push(cases, oc("op_f64_CopySign_rs", 0xc000000000000000ul, 0x3ff8000000000000ul, 0x4000000000000000ul))
    push(cases, oc("op_f64_CopySign_ss", 0x4008000000000000ul, 0x8000000000000000ul, 0xc008000000000000ul))

    // the unary float operations: the signed zero of ceil(-0.5),
    // floor(-0.0), nearest(-0.5) and negate(0.0), the half-to-even of
    // nearest(2.5), trunc(-1.5) = -1.0, sqrt(2.25) = 1.5
    push(cases, oc("op_f32_Abs_r", 0xc0000000ul, 0ul, 0x40000000ul))
    push(cases, oc("op_f32_Abs_s", 0x80000000ul, 0ul, 0ul))
    push(cases, oc("op_f32_Ceil_r", 0xbf000000ul, 0ul, 0x80000000ul))
    push(cases, oc("op_f32_Ceil_s", 0x3fc00000ul, 0ul, 0x40000000ul))
    push(cases, oc("op_f32_Floor_r", 0x80000000ul, 0ul, 0x80000000ul))
    push(cases, oc("op_f32_Floor_s", 0x3fc00000ul, 0ul, 0x3f800000ul))
    push(cases, oc("op_f32_Trunc_r", 0xbfc00000ul, 0ul, 0xbf800000ul))
    push(cases, oc("op_f32_Trunc_s", 0x3fc00000ul, 0ul, 0x3f800000ul))
    push(cases, oc("op_f32_Sqrt_r", 0x40800000ul, 0ul, 0x40000000ul))
    push(cases, oc("op_f32_Sqrt_s", 0x40100000ul, 0ul, 0x3fc00000ul))
    push(cases, oc("op_f32_Nearest_r", 0x40200000ul, 0ul, 0x40000000ul))
    push(cases, oc("op_f32_Nearest_s", 0xbf000000ul, 0ul, 0x80000000ul))
    push(cases, oc("op_f32_Negate_r", 0x3fc00000ul, 0ul, 0xbfc00000ul))
    push(cases, oc("op_f32_Negate_s", 0ul, 0ul, 0x80000000ul))
    push(cases, oc("op_f64_Abs_r", 0xc000000000000000ul, 0ul, 0x4000000000000000ul))
    push(cases, oc("op_f64_Abs_s", 0x8000000000000000ul, 0ul, 0ul))
    push(cases, oc("op_f64_Ceil_r", 0xbfe0000000000000ul, 0ul, 0x8000000000000000ul))
    push(cases, oc("op_f64_Ceil_s", 0x3ff8000000000000ul, 0ul, 0x4000000000000000ul))
    push(cases, oc("op_f64_Floor_r", 0x8000000000000000ul, 0ul, 0x8000000000000000ul))
    push(cases, oc("op_f64_Floor_s", 0x3ff8000000000000ul, 0ul, 0x3ff0000000000000ul))
    push(cases, oc("op_f64_Trunc_r", 0xbff8000000000000ul, 0ul, 0xbff0000000000000ul))
    push(cases, oc("op_f64_Trunc_s", 0x3ff8000000000000ul, 0ul, 0x3ff0000000000000ul))
    push(cases, oc("op_f64_Sqrt_r", 0x4010000000000000ul, 0ul, 0x4000000000000000ul))
    push(cases, oc("op_f64_Sqrt_s", 0x4002000000000000ul, 0ul, 0x3ff8000000000000ul))
    push(cases, oc("op_f64_Nearest_r", 0x4004000000000000ul, 0ul, 0x4000000000000000ul))
    push(cases, oc("op_f64_Nearest_s", 0xbfe0000000000000ul, 0ul, 0x8000000000000000ul))
    push(cases, oc("op_f64_Negate_r", 0x3ff8000000000000ul, 0ul, 0xbff8000000000000ul))
    push(cases, oc("op_f64_Negate_s", 0ul, 0ul, 0x8000000000000000ul))

    // eqz on the full width (a 64-bit value with a zero low half is not
    // zero), the bit counts with their zero guards
    push(cases, oc("op_i32_EqualToZero_r", 0ul, 0ul, 1ul))
    push(cases, oc("op_i32_EqualToZero_s", 5ul, 0ul, 0ul))
    push(cases, oc("op_i64_EqualToZero_r", 0x100000000ul, 0ul, 0ul))
    push(cases, oc("op_i64_EqualToZero_s", 0ul, 0ul, 1ul))
    push(cases, oc("op_u32_Clz_r", 0ul, 0ul, 32ul))
    push(cases, oc("op_u32_Clz_s", 1ul, 0ul, 31ul))
    push(cases, oc("op_u32_Ctz_r", 0ul, 0ul, 32ul))
    push(cases, oc("op_u32_Ctz_s", 8ul, 0ul, 3ul))
    push(cases, oc("op_u32_Popcnt_r", 0xfffffffful, 0ul, 32ul))
    push(cases, oc("op_u32_Popcnt_s", 7ul, 0ul, 3ul))
    push(cases, oc("op_u64_Clz_r", 0ul, 0ul, 64ul))
    push(cases, oc("op_u64_Clz_s", 1ul, 0ul, 63ul))
    push(cases, oc("op_u64_Ctz_r", 0ul, 0ul, 64ul))
    push(cases, oc("op_u64_Ctz_s", 16ul, 0ul, 4ul))
    push(cases, oc("op_u64_Popcnt_r", 0xfffffffffffffffful, 0ul, 64ul))
    push(cases, oc("op_u64_Popcnt_s", 7ul, 0ul, 3ul))

    var invoked : table<string; bool>
    for (c in cases) {
        run_op_case(t, rt, c)
        invoked[c.name] = true
    }

    // every word of the part-2 range ran: a missing row (or a registration
    // the table does not know) fails here, a missing registration panics
    // in m3_OpWord above
    var missing = 0
    for (name, idx in keys(g_opIndex), values(g_opIndex)) {
        if (idx >= PART2_FIRST_WORD && idx <= PART2_LAST_WORD) {
            if (!(invoked?[name] ?? false)) {
                check(t, false, "no case for {name}")
                missing++
            }
        }
    }
    equal(t, missing, 0, "every part-2 operation has a case")
    equal(t, length(invoked), PART2_LAST_WORD - PART2_FIRST_WORD + 1, "the table names exactly the part-2 range")
}


// ============================================================================
// Eden: every conversion operation of part 3 once through the dispatcher
// ============================================================================


// One row of the table: the operation, its source word (a 32-bit integer or
// an f32 pattern zero-extended, an i64 / u64 its bits, an f64 its double
// bits) and the expected result word (the same encoding) or the trap
// string. The two-letter forms name the destination then the source (C's
// d_m3TruncMacro / d_m3TypeConvertOp / d_m3ReinterpretOp: _r_r, _r_s, _s_r,
// _s_s); the wrap, the sign extensions, the extends and demote / promote
// have the one-letter source form (_r, _s) with the register as the
// destination (op_i32_Extend8_s_s is Extend8_s in its _s form).
struct ConvCase {
    name : string
    src : u64 = 0ul
    want : u64 = 0ul
    trap : string = ""
}


def private cc(name : string; src : u64; want : u64) : ConvCase {
    return ConvCase(name = name, src = src, want = want)
}


def private cct(name : string; src : u64; trap : string) : ConvCase {
    return ConvCase(name = name, src = src, trap = trap)
}


// Runs one conversion: installs the source as the operation reads it (the
// register for an _r source: the widened f32 or the f64 in rt.fp0, the word
// in rt.r0; slot 2 of a frame at sp = 4 for an _s source), emits the slot
// immediates in the order the body reads them (the source slot, then slot 3
// for an _s destination), then checks the destination: the slot word (a
// 32-bit store zero-extends), fp0 for a float register result (bit-exact,
// through f32 for an f32), r0 with the conventions of the m3_exec header
// (an i32 result sign-extended except the wrap's, which C masks; a u32
// result zero-extended; 64 bits as they are).
def private run_conv_case(var t : TestRun; var rt : M3Runtime; c : ConvCase) {
    let name = c.name
    let twoLetter = find(name, "Trunc") >= 0 || find(name, "Convert") >= 0 || find(name, "Reinterpret") >= 0
    let srcSlot = ends_with(name, "_s")
    let dstSlot = twoLetter && (ends_with(name, "_s_r") || ends_with(name, "_s_s"))
    // the source type is the token after the family name, past the seven
    // characters of the "op_TO_" prefix; the sign extensions name none and
    // read their own type from the register or the slot
    let srcF32 = find(name, "_f32_") >= 7
    let srcF64 = find(name, "_f64_") >= 7
    let dstF32 = starts_with(name, "op_f32_")
    let dstF64 = starts_with(name, "op_f64_")
    let dstI32 = starts_with(name, "op_i32_")
    let dstU32 = starts_with(name, "op_u32_")
    let dst32 = dstF32 || dstI32 || dstU32

    for (i in range(length(rt.stack))) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    rt.sp = 4
    rt.r0 = 0ul
    rt.fp0 = 0.0lf
    rt.trap = m3Err_none
    clear(rt.code)
    if (srcSlot) {
        rt.stack[rt.sp + 2] = c.src
        emit_int(rt, 2)
    } elif (srcF32) {
        rt.fp0 = f64(uint_bits_to_float(u32(c.src)))
    } elif (srcF64) {
        rt.fp0 = uint64_bits_to_double(c.src)
    } else {
        rt.r0 = c.src
    }
    if (dstSlot) {
        emit_int(rt, 3)
    }
    rt.pc = 0
    let opWord = int(m3_OpWord(name))
    mark_executed(opWord)
    let op = m3_OpAt(opWord)
    let r = invoke(op, rt)
    if (c.trap != "") {
        equal(t, r, M3_TRAP, "{name} traps")
        equal_str(t, rt.trap, c.trap, "{name} trap string")
        return
    }
    equal(t, r, M3_NEXT, "{name} continues")
    equal(t, rt.pc, length(rt.code), "{name} consumed its immediates")
    if (dstSlot) {
        let word = (dst32 ? u64(u32(c.want)) : c.want)
        equal(t, rt.stack[rt.sp + 3], word, "{name} slot result")
    } elif (dstF32) {
        equal(t, float_bits_to_uint(f32(rt.fp0)), u32(c.want), "{name} f32 result bits")
    } elif (dstF64) {
        equal(t, double_bits_to_uint64(rt.fp0), c.want, "{name} f64 result bits")
    } elif (dstI32 && find(name, "Wrap") < 0) {
        equal(t, rt.r0, u64(i64(i32(u32(c.want)))), "{name} i32 result, sign-extended")
    } elif (dst32) {
        equal(t, rt.r0, u64(u32(c.want)), "{name} 32-bit result, zero-extended")
    } else {
        equal(t, rt.r0, c.want, "{name} result")
    }
}


def test_conversion_families(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(16)
    var cases : array<ConvCase>

    // the wrap keeps the low 32 bits, zero-extended in the register (C's
    // OP_WRAP_I64 mask); the sign extensions read the low 8 / 16 / 32 bits
    // of their own type, whatever the bits above them
    push(cases, cc("op_i32_Wrap_i64_r", 0xdeadbeefcafebabeul, 0xcafebabeul))
    push(cases, cc("op_i32_Wrap_i64_s", 0xfffffffffffffff4ul, 0xfffffff4ul))
    push(cases, cc("op_i32_Extend8_s_r", 0x17ful, 0x7ful))
    push(cases, cc("op_i32_Extend8_s_s", 0x80ul, 0xffffff80ul))
    push(cases, cc("op_i32_Extend16_s_r", 0x18000ul, 0xffff8000ul))
    push(cases, cc("op_i32_Extend16_s_s", 0x7ffful, 0x7ffful))
    push(cases, cc("op_i64_Extend8_s_r", 0x7f80ul, 0xffffffffffffff80ul))
    push(cases, cc("op_i64_Extend8_s_s", 0x7ful, 0x7ful))
    push(cases, cc("op_i64_Extend16_s_r", 0x18000ul, 0xffffffffffff8000ul))
    push(cases, cc("op_i64_Extend16_s_s", 0x7ffful, 0x7ffful))
    push(cases, cc("op_i64_Extend32_s_r", 0x180000000ul, 0xffffffff80000000ul))
    push(cases, cc("op_i64_Extend32_s_s", 0x7ffffffful, 0x7ffffffful))

    // the trapping truncations: a NaN is the conversion trap, C's RMIN /
    // RMAX constants and the infinities the overflow trap, the values just
    // inside the range convert (i32 from f32: -2147483904 and 2^31 trap,
    // -2^31 and 2147483520 convert; u32 from f32: -1 and 2^32 trap, -0.5
    // and 4294967040 convert; i32 from f64: -2147483649 and 2^31 trap,
    // -2147483648.5 and 2147483647.9 convert; u32 from f64: -1 and 2^32
    // trap, 4294967295.5 converts; i64 from f32: -9223373136366403584 and
    // 2^63 trap, -2^63 and 9223371487098961920 convert; u64 from f32: -1
    // and 2^64 trap, 18446742974197923840 converts; i64 from f64:
    // -9223372036854777856 and 2^63 trap, -2^63 and 9223372036854774784
    // convert; u64 from f64: -1 and 2^64 trap, 18446744073709549568
    // converts); every form once, the destination-slot forms on a value
    // and on a trap
    push(cases, cct("op_i32_Trunc_f32_r_r", 0x7fc00000ul, m3Err_trapIntegerConversion))
    push(cases, cct("op_i32_Trunc_f32_r_r", 0xcf000001ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i32_Trunc_f32_r_r", 0x4f000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i32_Trunc_f32_r_r", 0x7f800000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i32_Trunc_f32_r_r", 0xff800000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_i32_Trunc_f32_r_r", 0xcf000000ul, 0x80000000ul))
    push(cases, cc("op_i32_Trunc_f32_r_s", 0x4efffffful, 0x7fffff80ul))
    push(cases, cc("op_i32_Trunc_f32_s_r", 0xc02ccccdul, 0xfffffffeul))
    push(cases, cct("op_i32_Trunc_f32_s_r", 0x7fc00000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_i32_Trunc_f32_s_s", 0x3fc00000ul, 1ul))
    push(cases, cct("op_i32_Trunc_f32_s_s", 0x4f000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_u32_Trunc_f32_r_r", 0xbf800000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_u32_Trunc_f32_r_r", 0x4f800000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_u32_Trunc_f32_r_r", 0x7fc00000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_u32_Trunc_f32_r_r", 0xbf000000ul, 0ul))
    push(cases, cc("op_u32_Trunc_f32_r_s", 0x4f7ffffful, 0xffffff00ul))
    push(cases, cc("op_u32_Trunc_f32_s_r", 0x4079999aul, 3ul))
    push(cases, cc("op_u32_Trunc_f32_s_s", 0x4f7ffffful, 0xffffff00ul))
    push(cases, cct("op_u32_Trunc_f32_s_s", 0xbf800000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i32_Trunc_f64_r_r", 0x7ff8000000000000ul, m3Err_trapIntegerConversion))
    push(cases, cct("op_i32_Trunc_f64_r_r", 0xc1e0000000200000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i32_Trunc_f64_r_r", 0x41e0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_i32_Trunc_f64_r_r", 0xc1e0000000100000ul, 0x80000000ul))
    push(cases, cc("op_i32_Trunc_f64_r_s", 0x41dffffffff9999aul, 0x7ffffffful))
    push(cases, cc("op_i32_Trunc_f64_s_r", 0xc000000000000000ul, 0xfffffffeul))
    push(cases, cct("op_i32_Trunc_f64_s_r", 0xfff0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_i32_Trunc_f64_s_s", 0x4004000000000000ul, 2ul))
    push(cases, cct("op_i32_Trunc_f64_s_s", 0x7ff8000000000000ul, m3Err_trapIntegerConversion))
    push(cases, cct("op_u32_Trunc_f64_r_r", 0xbff0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_u32_Trunc_f64_r_r", 0x41f0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_u32_Trunc_f64_r_r", 0x41effffffff00000ul, 0xfffffffful))
    push(cases, cc("op_u32_Trunc_f64_r_s", 0xbfe0000000000000ul, 0ul))
    push(cases, cct("op_u32_Trunc_f64_r_s", 0x7ff8000000000000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_u32_Trunc_f64_s_r", 0x400f333333333333ul, 3ul))
    push(cases, cc("op_u32_Trunc_f64_s_s", 0x41effffffff00000ul, 0xfffffffful))
    push(cases, cct("op_u32_Trunc_f64_s_s", 0x7ff0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i64_Trunc_f32_r_r", 0xdf000001ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i64_Trunc_f32_r_r", 0x5f000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i64_Trunc_f32_r_r", 0x7fc00000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_i64_Trunc_f32_r_r", 0xdf000000ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_Trunc_f32_r_s", 0x5efffffful, 0x7fffff8000000000ul))
    push(cases, cc("op_i64_Trunc_f32_s_r", 0xc02ccccdul, 0xfffffffffffffffeul))
    push(cases, cct("op_i64_Trunc_f32_s_r", 0x7f800000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_i64_Trunc_f32_s_s", 0x3fc00000ul, 1ul))
    push(cases, cct("op_i64_Trunc_f32_s_s", 0x7fc00000ul, m3Err_trapIntegerConversion))
    push(cases, cct("op_u64_Trunc_f32_r_r", 0xbf800000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_u64_Trunc_f32_r_r", 0x5f800000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_u64_Trunc_f32_r_r", 0x5f7ffffful, 0xffffff0000000000ul))
    push(cases, cc("op_u64_Trunc_f32_r_s", 0xbf000000ul, 0ul))
    push(cases, cct("op_u64_Trunc_f32_r_s", 0x7fc00000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_u64_Trunc_f32_s_r", 0x4079999aul, 3ul))
    push(cases, cc("op_u64_Trunc_f32_s_s", 0x5f7ffffful, 0xffffff0000000000ul))
    push(cases, cct("op_u64_Trunc_f32_s_s", 0xff800000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i64_Trunc_f64_r_r", 0xc3e0000000000001ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i64_Trunc_f64_r_r", 0x43e0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_i64_Trunc_f64_r_r", 0x7ff8000000000000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_i64_Trunc_f64_r_r", 0xc3e0000000000000ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_Trunc_f64_r_s", 0x43dffffffffffffful, 0x7ffffffffffffc00ul))
    push(cases, cc("op_i64_Trunc_f64_s_r", 0xc000000000000000ul, 0xfffffffffffffffeul))
    push(cases, cct("op_i64_Trunc_f64_s_r", 0x7ff0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_i64_Trunc_f64_s_s", 0x4004000000000000ul, 2ul))
    push(cases, cct("op_i64_Trunc_f64_s_s", 0x7ff8000000000000ul, m3Err_trapIntegerConversion))
    push(cases, cct("op_u64_Trunc_f64_r_r", 0xbff0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cct("op_u64_Trunc_f64_r_r", 0x43f0000000000000ul, m3Err_trapIntegerOverflow))
    push(cases, cc("op_u64_Trunc_f64_r_r", 0x43effffffffffffful, 0xfffffffffffff800ul))
    push(cases, cc("op_u64_Trunc_f64_r_s", 0xbfe0000000000000ul, 0ul))
    push(cases, cct("op_u64_Trunc_f64_r_s", 0x7ff8000000000000ul, m3Err_trapIntegerConversion))
    push(cases, cc("op_u64_Trunc_f64_s_r", 0x400f333333333333ul, 3ul))
    push(cases, cc("op_u64_Trunc_f64_s_s", 0x43effffffffffffful, 0xfffffffffffff800ul))
    push(cases, cct("op_u64_Trunc_f64_s_s", 0xfff0000000000000ul, m3Err_trapIntegerOverflow))

    // the saturating truncations on the same inputs: a NaN gives 0, the
    // range ends and the infinities the type's limits, the values inside
    // the range convert
    push(cases, cc("op_i32_TruncSat_f32_r_r", 0x7fc00000ul, 0ul))
    push(cases, cc("op_i32_TruncSat_f32_r_r", 0xff800000ul, 0x80000000ul))
    push(cases, cc("op_i32_TruncSat_f32_r_r", 0x7f800000ul, 0x7ffffffful))
    push(cases, cc("op_i32_TruncSat_f32_r_s", 0xcf000001ul, 0x80000000ul))
    push(cases, cc("op_i32_TruncSat_f32_r_s", 0x4f000000ul, 0x7ffffffful))
    push(cases, cc("op_i32_TruncSat_f32_s_r", 0xc02ccccdul, 0xfffffffeul))
    push(cases, cc("op_i32_TruncSat_f32_s_r", 0x7fc00000ul, 0ul))
    push(cases, cc("op_i32_TruncSat_f32_s_s", 0x4efffffful, 0x7fffff80ul))
    push(cases, cc("op_i32_TruncSat_f32_s_s", 0xcf000000ul, 0x80000000ul))
    push(cases, cc("op_u32_TruncSat_f32_r_r", 0x7fc00000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f32_r_r", 0xbf800000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f32_r_r", 0x4f800000ul, 0xfffffffful))
    push(cases, cc("op_u32_TruncSat_f32_r_s", 0xff800000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f32_r_s", 0x4f7ffffful, 0xffffff00ul))
    push(cases, cc("op_u32_TruncSat_f32_s_r", 0x7f800000ul, 0xfffffffful))
    push(cases, cc("op_u32_TruncSat_f32_s_r", 0xbf000000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f32_s_s", 0x4079999aul, 3ul))
    push(cases, cc("op_u32_TruncSat_f32_s_s", 0x7fc00000ul, 0ul))
    push(cases, cc("op_i32_TruncSat_f64_r_r", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_i32_TruncSat_f64_r_r", 0xfff0000000000000ul, 0x80000000ul))
    push(cases, cc("op_i32_TruncSat_f64_r_r", 0x7ff0000000000000ul, 0x7ffffffful))
    push(cases, cc("op_i32_TruncSat_f64_r_s", 0xc1e0000000200000ul, 0x80000000ul))
    push(cases, cc("op_i32_TruncSat_f64_r_s", 0x41e0000000000000ul, 0x7ffffffful))
    push(cases, cc("op_i32_TruncSat_f64_s_r", 0xc1e0000000100000ul, 0x80000000ul))
    push(cases, cc("op_i32_TruncSat_f64_s_r", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_i32_TruncSat_f64_s_s", 0x41dffffffff9999aul, 0x7ffffffful))
    push(cases, cc("op_i32_TruncSat_f64_s_s", 0xc000000000000000ul, 0xfffffffeul))
    push(cases, cc("op_u32_TruncSat_f64_r_r", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f64_r_r", 0xbff0000000000000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f64_r_r", 0x41f0000000000000ul, 0xfffffffful))
    push(cases, cc("op_u32_TruncSat_f64_r_s", 0xfff0000000000000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f64_r_s", 0x41effffffff00000ul, 0xfffffffful))
    push(cases, cc("op_u32_TruncSat_f64_s_r", 0x7ff0000000000000ul, 0xfffffffful))
    push(cases, cc("op_u32_TruncSat_f64_s_r", 0x400f333333333333ul, 3ul))
    push(cases, cc("op_u32_TruncSat_f64_s_s", 0xbfe0000000000000ul, 0ul))
    push(cases, cc("op_u32_TruncSat_f64_s_s", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_i64_TruncSat_f32_r_r", 0x7fc00000ul, 0ul))
    push(cases, cc("op_i64_TruncSat_f32_r_r", 0xff800000ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_TruncSat_f32_r_r", 0x7f800000ul, 0x7ffffffffffffffful))
    push(cases, cc("op_i64_TruncSat_f32_r_s", 0xdf000001ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_TruncSat_f32_r_s", 0x5f000000ul, 0x7ffffffffffffffful))
    push(cases, cc("op_i64_TruncSat_f32_s_r", 0x5efffffful, 0x7fffff8000000000ul))
    push(cases, cc("op_i64_TruncSat_f32_s_r", 0x7fc00000ul, 0ul))
    push(cases, cc("op_i64_TruncSat_f32_s_s", 0xc02ccccdul, 0xfffffffffffffffeul))
    push(cases, cc("op_i64_TruncSat_f32_s_s", 0xdf000000ul, 0x8000000000000000ul))
    push(cases, cc("op_u64_TruncSat_f32_r_r", 0x7fc00000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f32_r_r", 0xbf800000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f32_r_r", 0x5f800000ul, 0xfffffffffffffffful))
    push(cases, cc("op_u64_TruncSat_f32_r_s", 0xff800000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f32_r_s", 0x5f7ffffful, 0xffffff0000000000ul))
    push(cases, cc("op_u64_TruncSat_f32_s_r", 0x7f800000ul, 0xfffffffffffffffful))
    push(cases, cc("op_u64_TruncSat_f32_s_r", 0xbf000000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f32_s_s", 0x4079999aul, 3ul))
    push(cases, cc("op_u64_TruncSat_f32_s_s", 0x7fc00000ul, 0ul))
    push(cases, cc("op_i64_TruncSat_f64_r_r", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_i64_TruncSat_f64_r_r", 0xfff0000000000000ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_TruncSat_f64_r_r", 0x7ff0000000000000ul, 0x7ffffffffffffffful))
    push(cases, cc("op_i64_TruncSat_f64_r_s", 0xc3e0000000000001ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_TruncSat_f64_r_s", 0x43e0000000000000ul, 0x7ffffffffffffffful))
    push(cases, cc("op_i64_TruncSat_f64_s_r", 0x43dffffffffffffful, 0x7ffffffffffffc00ul))
    push(cases, cc("op_i64_TruncSat_f64_s_r", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_i64_TruncSat_f64_s_s", 0xc000000000000000ul, 0xfffffffffffffffeul))
    push(cases, cc("op_i64_TruncSat_f64_s_s", 0xc3e0000000000000ul, 0x8000000000000000ul))
    push(cases, cc("op_u64_TruncSat_f64_r_r", 0x7ff8000000000000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f64_r_r", 0xbff0000000000000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f64_r_r", 0x43f0000000000000ul, 0xfffffffffffffffful))
    push(cases, cc("op_u64_TruncSat_f64_r_s", 0xfff0000000000000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f64_r_s", 0x43effffffffffffful, 0xfffffffffffff800ul))
    push(cases, cc("op_u64_TruncSat_f64_s_r", 0x7ff0000000000000ul, 0xfffffffffffffffful))
    push(cases, cc("op_u64_TruncSat_f64_s_r", 0xbfe0000000000000ul, 0ul))
    push(cases, cc("op_u64_TruncSat_f64_s_s", 0x400f333333333333ul, 3ul))
    push(cases, cc("op_u64_TruncSat_f64_s_s", 0x7ff8000000000000ul, 0ul))

    // the extends read the low half of the register only (a word from a
    // wrap, zero-extended, or one with the high half set); demote's halfway
    // cases round to even, its overflow gives inf and its NaN keeps the
    // high payload bits; promote widens exactly (1.5, -0, -inf, a NaN
    // payload shifted up)
    push(cases, cc("op_i64_Extend_i32_r", 0xfffffffeul, 0xfffffffffffffffeul))
    push(cases, cc("op_i64_Extend_i32_s", 0x7ffffffful, 0x7ffffffful))
    push(cases, cc("op_i64_Extend_u32_r", 0xfffffffffffffffeul, 0xfffffffeul))
    push(cases, cc("op_i64_Extend_u32_s", 0x80000000ul, 0x80000000ul))
    push(cases, cc("op_f32_Demote_f64_r", 0x3ff0000010000000ul, 0x3f800000ul))
    push(cases, cc("op_f32_Demote_f64_r", 0x47f0000000000000ul, 0x7f800000ul))
    push(cases, cc("op_f32_Demote_f64_r", 0x47efffffe0000000ul, 0x7f7ffffful))
    push(cases, cc("op_f32_Demote_f64_s", 0x3ff0000030000000ul, 0x3f800002ul))
    push(cases, cc("op_f32_Demote_f64_s", 0x7ff8123456789abcul, 0x7fc091a2ul))
    push(cases, cc("op_f32_Demote_f64_s", 0xbfe0000000000000ul, 0xbf000000ul))
    push(cases, cc("op_f64_Promote_f32_r", 0x3fc00000ul, 0x3ff8000000000000ul))
    push(cases, cc("op_f64_Promote_f32_r", 0x7fc12345ul, 0x7ff82468a0000000ul))
    push(cases, cc("op_f64_Promote_f32_s", 0x80000000ul, 0x8000000000000000ul))
    push(cases, cc("op_f64_Promote_f32_s", 0xff800000ul, 0xfff0000000000000ul))

    // the conversions to float: the register's high half is ignored for a
    // 32-bit source (-2 sign-extended, u32 max with the high half set), the
    // signedness of the source chooses the value (0x80000000 is -2^31 or
    // 2^31), and the rounding is to nearest even: 2^24 + 1 -> 2^24 and 2^24
    // + 3 -> 2^24 + 4 in f32, 2^53 + 1 -> 2^53 in f64, 2^31 - 1 and 2^63 - 1
    // up to the power of two, u64 max to 2^64, and the u64 cases with the
    // top bit set (2^63 + 2^39 + 1 -> 2^63 + 2^40 in f32, 2^63 + 2^10 + 1 ->
    // 2^63 + 2^11 in f64) and 2^61 + 2^37 + 1 -> 2^61 + 2^38 in f32, where a
    // halving path without the sticky bit would round down
    push(cases, cc("op_f32_Convert_i32_r_r", 0xfffffffffffffffeul, 0xc0000000ul))
    push(cases, cc("op_f32_Convert_i32_s_r", 0x80000000ul, 0xcf000000ul))
    push(cases, cc("op_f32_Convert_i32_r_s", 0x01000001ul, 0x4b800000ul))
    push(cases, cc("op_f32_Convert_i32_s_s", 0x7ffffffful, 0x4f000000ul))
    push(cases, cc("op_f32_Convert_u32_r_r", 0xfffffffffffffffful, 0x4f800000ul))
    push(cases, cc("op_f32_Convert_u32_s_r", 0x80000000ul, 0x4f000000ul))
    push(cases, cc("op_f32_Convert_u32_r_s", 0x01000003ul, 0x4b800002ul))
    push(cases, cc("op_f32_Convert_u32_s_s", 3ul, 0x40400000ul))
    push(cases, cc("op_f32_Convert_i64_r_r", 0x8000000000000000ul, 0xdf000000ul))
    push(cases, cc("op_f32_Convert_i64_s_r", 0xfffffffffffffffeul, 0xc0000000ul))
    push(cases, cc("op_f32_Convert_i64_r_s", 0x1000003ul, 0x4b800002ul))
    push(cases, cc("op_f32_Convert_i64_s_s", 0x7ffffffffffffffful, 0x5f000000ul))
    push(cases, cc("op_f32_Convert_u64_r_r", 0x2000002000000001ul, 0x5e000001ul))
    push(cases, cc("op_f32_Convert_u64_r_r", 0x8000008000000001ul, 0x5f000001ul))
    push(cases, cc("op_f32_Convert_u64_s_r", 0xfffffffffffffffful, 0x5f800000ul))
    push(cases, cc("op_f32_Convert_u64_r_s", 0x8000000000000000ul, 0x5f000000ul))
    push(cases, cc("op_f32_Convert_u64_s_s", 0x2000002000000001ul, 0x5e000001ul))
    push(cases, cc("op_f64_Convert_i32_r_r", 0xfffffffffffffffeul, 0xc000000000000000ul))
    push(cases, cc("op_f64_Convert_i32_s_r", 0x80000000ul, 0xc1e0000000000000ul))
    push(cases, cc("op_f64_Convert_i32_r_s", 0x7ffffffful, 0x41dfffffffc00000ul))
    push(cases, cc("op_f64_Convert_i32_s_s", 3ul, 0x4008000000000000ul))
    push(cases, cc("op_f64_Convert_u32_r_r", 0xfffffffffffffffful, 0x41efffffffe00000ul))
    push(cases, cc("op_f64_Convert_u32_s_r", 0x80000000ul, 0x41e0000000000000ul))
    push(cases, cc("op_f64_Convert_u32_r_s", 0xfffffffeul, 0x41efffffffc00000ul))
    push(cases, cc("op_f64_Convert_u32_s_s", 0ul, 0ul))
    push(cases, cc("op_f64_Convert_i64_r_r", 0x8000000000000000ul, 0xc3e0000000000000ul))
    push(cases, cc("op_f64_Convert_i64_s_r", 0xfffffffffffffffeul, 0xc000000000000000ul))
    push(cases, cc("op_f64_Convert_i64_r_s", 0x20000000000001ul, 0x4340000000000000ul))
    push(cases, cc("op_f64_Convert_i64_s_s", 0x7ffffffffffffffful, 0x43e0000000000000ul))
    push(cases, cc("op_f64_Convert_u64_r_r", 0x8000000000000401ul, 0x43e0000000000001ul))
    push(cases, cc("op_f64_Convert_u64_s_r", 0xfffffffffffffffful, 0x43f0000000000000ul))
    push(cases, cc("op_f64_Convert_u64_r_s", 0x8000000000000000ul, 0x43e0000000000000ul))
    push(cases, cc("op_f64_Convert_u64_s_s", 0x8000000000000401ul, 0x43e0000000000001ul))

    // the reinterprets, bit-exact: quiet NaNs with payloads of both signs
    // (an i32 pattern with the sign bit set is sign-extended into the
    // register, an f32 pattern survives the widening into rt.fp0), the
    // signed zero, 1.5
    push(cases, cc("op_i32_Reinterpret_f32_r_r", 0x7fc12345ul, 0x7fc12345ul))
    push(cases, cc("op_i32_Reinterpret_f32_r_r", 0xffc12345ul, 0xffc12345ul))
    push(cases, cc("op_i32_Reinterpret_f32_r_s", 0x80000000ul, 0x80000000ul))
    push(cases, cc("op_i32_Reinterpret_f32_s_r", 0x3fc00000ul, 0x3fc00000ul))
    push(cases, cc("op_i32_Reinterpret_f32_s_s", 0xffc12345ul, 0xffc12345ul))
    push(cases, cc("op_i64_Reinterpret_f64_r_r", 0x7ff8123456789abcul, 0x7ff8123456789abcul))
    push(cases, cc("op_i64_Reinterpret_f64_r_s", 0xfff8123456789abcul, 0xfff8123456789abcul))
    push(cases, cc("op_i64_Reinterpret_f64_s_r", 0x8000000000000000ul, 0x8000000000000000ul))
    push(cases, cc("op_i64_Reinterpret_f64_s_s", 0x3ff8000000000000ul, 0x3ff8000000000000ul))
    push(cases, cc("op_f32_Reinterpret_i32_r_r", 0xffffffffffc12345ul, 0xffc12345ul))
    push(cases, cc("op_f32_Reinterpret_i32_r_s", 0x7fc12345ul, 0x7fc12345ul))
    push(cases, cc("op_f32_Reinterpret_i32_s_r", 0x80000000ul, 0x80000000ul))
    push(cases, cc("op_f32_Reinterpret_i32_s_s", 0x3fc00000ul, 0x3fc00000ul))
    push(cases, cc("op_f64_Reinterpret_i64_r_r", 0xfff8123456789abcul, 0xfff8123456789abcul))
    push(cases, cc("op_f64_Reinterpret_i64_r_s", 0x7ff8123456789abcul, 0x7ff8123456789abcul))
    push(cases, cc("op_f64_Reinterpret_i64_s_r", 0x8000000000000000ul, 0x8000000000000000ul))
    push(cases, cc("op_f64_Reinterpret_i64_s_s", 0x3ff8000000000000ul, 0x3ff8000000000000ul))

    var invoked : table<string; bool>
    for (c in cases) {
        run_conv_case(t, rt, c)
        invoked[c.name] = true
    }

    // every word of the part-3 range ran: a missing row (or a registration
    // the table does not know) fails here, a missing registration panics
    // in m3_OpWord above
    var missing = 0
    for (name, idx in keys(g_opIndex), values(g_opIndex)) {
        if (idx >= PART3_FIRST_WORD && idx <= PART3_LAST_WORD) {
            if (!(invoked?[name] ?? false)) {
                check(t, false, "no case for {name}")
                missing++
            }
        }
    }
    equal(t, missing, 0, "every part-3 operation has a case")
    equal(t, length(invoked), PART3_LAST_WORD - PART3_FIRST_WORD + 1, "the table names exactly the part-3 range")
}


// ============================================================================
// Eden: nested calls (the Call / RunLoop protocol)
// ============================================================================


def test_nested_call(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)

    // callee: (i32) -> i32 returning 77; it also leaves 77 in the register
    let calleePC = emit_op(rt, "op_Entry")
    let callee = fixture_function(rt, calleePC, 0)
    emit_int(rt, callee)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 77u)
    emit_int(rt, 0)
    emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 0)
    emit_op(rt, "op_Return")

    // caller: puts 5 in the register, calls the callee on the frame at
    // slot 4, copies the callee's result (frame slot 4) into its own slot 0
    // and stores the register into slot 2: C's by-value registers make it
    // the caller's 5, not the callee's 77
    let callerPC = emit_op(rt, "op_Entry")
    let caller = fixture_function(rt, callerPC, 1)
    emit_int(rt, caller)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 5u)
    emit_int(rt, 3)
    emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 3)
    emit_op(rt, "op_Call")
    emit_int(rt, calleePC)
    emit_int(rt, 4)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 0)
    emit_int(rt, 4)
    emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 2)
    let callerReturnPC = emit_op(rt, "op_Return")

    let r = run(rt, callerPC, 0)
    equal(t, r, M3_RETURN, "Entry -> Call -> Return completes with M3_RETURN")
    equal_str(t, rt.trap, m3Err_none, "no trap recorded")
    equal(t, stack_i32(rt, 0), 77, "the callee's result reached the caller's slot 0")
    equal(t, stack_i32(rt, 4), 77, "the callee wrote its own frame slot 0 (caller slot 4)")
    equal(t, stack_i32(rt, 2), 5, "the caller's register survived the call (C by-value registers)")
    equal(t, rt.sp, 0, "rt.sp is the caller's frame after the call")
    equal(t, rt.pc, callerReturnPC + 1, "rt.pc is past the caller's op_Return")

    // a trap two levels down unwinds every RunLoop, rt.trap set once,
    // rt.sp restored by Call on the way up
    let trapCalleePC = emit_op(rt, "op_Entry")
    let trapCallee = fixture_function(rt, trapCalleePC, 0)
    emit_int(rt, trapCallee)
    emit_op(rt, "op_Unreachable")
    let trapCallerPC = emit_op(rt, "op_Entry")
    let trapCaller = fixture_function(rt, trapCallerPC, 0)
    emit_int(rt, trapCaller)
    emit_op(rt, "op_Call")
    emit_int(rt, trapCalleePC)
    emit_int(rt, 6)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    set_stack_i32(rt, 0, 0)
    let rTrap = run(rt, trapCallerPC, 0)
    equal(t, rTrap, M3_TRAP, "a nested trap reaches RunCode as M3_TRAP")
    equal_str(t, rt.trap, m3Err_trapUnreachable, "rt.trap holds the callee's trap")
    equal(t, rt.sp, 0, "rt.sp restored by Call after a trap")
    equal(t, stack_i32(rt, 0), 0, "the caller did not continue after the trap")

    // op_Entry: stack overflow when sp + maxStackSlots reaches the stack end
    let bigPC = emit_op(rt, "op_Entry")
    let big = new_function(rt, length(rt.stack), 2, 0)
    rt.functions[big].compiled = bigPC
    emit_int(rt, big)
    emit_op(rt, "op_Return")
    let rBig = run(rt, bigPC, 0)
    equal(t, rBig, M3_TRAP, "op_Entry traps when the frame does not fit")
    equal_str(t, rt.trap, m3Err_trapStackOverflow, "... with the stack overflow trap")
    let fitPC = emit_op(rt, "op_Entry")
    let fit = new_function(rt, length(rt.stack) - 1, 2, 0)
    rt.functions[fit].compiled = fitPC
    emit_int(rt, fit)
    emit_op(rt, "op_Return")
    equal(t, run(rt, fitPC, 0), M3_RETURN, "op_Entry accepts a frame ending one below the stack end (C: strict <)")

    // op_Entry zeroes the locals and copies the constants after the ret+arg slots
    let localsPC = emit_op(rt, "op_Entry")
    let withLocals = new_function(rt, 16, 2, 8)   // two i32 locals
    rt.functions[withLocals].compiled = localsPC
    push(rt.functions[withLocals].constants, 0xdeadul)
    push(rt.functions[withLocals].constants, 0xbeef0000beeful)
    rt.functions[withLocals].numConstantBytes = u16(8)
    emit_int(rt, withLocals)
    emit_op(rt, "op_Return")
    for (i in range(length(rt.stack))) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    rt.r0 = 9ul
    rt.fp0 = 9.0lf
    equal(t, run(rt, localsPC, 3), M3_RETURN, "op_Entry with locals and constants")
    equal(t, rt.stack[3], 0xfffffffffffffffful, "ret slot untouched")
    equal(t, rt.stack[4], 0xfffffffffffffffful, "arg slot untouched")
    equal(t, rt.stack[5], 0ul, "local 0 zeroed")
    equal(t, rt.stack[6], 0ul, "local 1 zeroed")
    equal(t, rt.stack[7], 0xdeadul, "constant 0 copied")
    equal(t, rt.stack[8], 0xbeef0000beeful, "constant 1 copied")
    equal(t, rt.stack[9], 0xfffffffffffffffful, "the slot after the constants untouched")
    equal(t, rt.r0, 0ul, "op_Entry cleared _r0")
    equal(t, rt.fp0, 0.0lf, "op_Entry cleared _fp0")
}


// ============================================================================
// Eden: loops and branches, the counter driven by a raw function
// ============================================================================


var private rawCallCount : int = 0
var private rawSeenOrigin : int = -1


// the raw function dec : (i32) -> i32; its frame is C's: the argument in
// slot 1 of the frame at `sp`, the result written to slot 0
def private raw_decrement(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    rawCallCount++
    rawSeenOrigin = rt.originStack
    let v = stack_i32(rt, sp + 1)
    set_stack_i32(rt, sp + 0, v - 1)
    return m3Err_none
}


def private raw_trap(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    return "host function trap"
}


def test_loops_and_branches(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)
    push(rt.rawCalls, @@raw_decrement)
    push(rt.rawCalls, @@raw_trap)

    // dec : (i32) -> i32, the raw function as m3_bind's CompileRawFunction
    // emits it: op_CallRawFunction, the raw-call handle, the function, the
    // userdata. It is a whole function body: a caller reaches it through
    // op_Call on a fresh frame and its forwardTrap of m3Err_none ends that
    // function (C: `return NULL` back to Call)
    let decPC = emit_op(rt, "op_CallRawFunction")
    let decFn = fixture_function(rt, decPC, 0)
    emit_int(rt, 0)      // rt.rawCalls[0]
    emit_int(rt, decFn)  // ctx.function
    emit_int(rt, -1)     // ctx.userdata
    set_stack_i32(rt, 1, 9)
    equal(t, run(rt, decPC, 0), M3_RETURN, "op_CallRawFunction completes the function (M3_RETURN)")
    equal(t, stack_i32(rt, 0), 8, "the raw function wrote its result slot")

    // loop { counter = dec (counter); br_if counter } ; 42
    // Eden: the compiler's shape for br_if to a loop: the condition moves to
    // the register, op_ContinueLoopIf returns the loop's pc to op_Loop; the
    // call passes the counter (slot 2) as the callee's argument (frame 4,
    // slot 5) and takes the result back from the callee's slot 0 (slot 4)
    let loopFnPC = emit_op(rt, "op_Entry")
    let loopFn = fixture_function(rt, loopFnPC, 1)
    emit_int(rt, loopFn)
    emit_op(rt, "op_CopySlot_32")   // local = arg
    emit_int(rt, 2)
    emit_int(rt, 1)
    emit_op(rt, "op_Loop")
    let loopBodyPC = emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 5)
    emit_int(rt, 2)
    emit_op(rt, "op_Call")
    emit_int(rt, decPC)
    emit_int(rt, 4)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 2)
    emit_int(rt, 4)
    emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 2)
    emit_op(rt, "op_ContinueLoopIf")
    emit_int(rt, loopBodyPC)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 42u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    rawCallCount = 0
    expect_value(t, rt, loopFn, 10, 42, "loop with ContinueLoopIf")
    equal(t, rawCallCount, 10, "the loop body ran 10 times")
    equal(t, rawSeenOrigin, 4, "op_CallRawFunction swapped rt.originStack to the callee's frame base")
    equal(t, rt.originStack, 0, "rt.originStack restored after the raw call")
    rawCallCount = 0
    expect_value(t, rt, loopFn, 1, 42, "loop with ContinueLoopIf, one iteration")
    equal(t, rawCallCount, 1, "the loop body ran once")

    // the same loop with an unconditional op_ContinueLoop and an exit branch:
    // loop { if (counter == 0) break; counter = dec (counter) } through
    // op_BranchIfPrologue_r on the register (C: 0 = jump over the prologue),
    // the exit lands past the loop
    let loop2PC = emit_op(rt, "op_Entry")
    let loop2 = fixture_function(rt, loop2PC, 1)
    emit_int(rt, loop2)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 2)
    emit_int(rt, 1)
    emit_op(rt, "op_Loop")
    let loop2BodyPC = emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 2)
    emit_op(rt, "op_BranchIfPrologue_r")   // counter != 0: run the body; 0: jump out
    let exitPatch = emit_int(rt, -1)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 5)
    emit_int(rt, 2)
    emit_op(rt, "op_Call")
    emit_int(rt, decPC)
    emit_int(rt, 4)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 2)
    emit_int(rt, 4)
    emit_op(rt, "op_ContinueLoop")
    emit_int(rt, loop2BodyPC)
    let exitPC = emit_op(rt, "op_Const32")
    emit_u32(rt, 7u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    rt.code[exitPatch] = u64(exitPC)
    rawCallCount = 0
    expect_value(t, rt, loop2, 3, 7, "loop with ContinueLoop and BranchIfPrologue_r exit")
    equal(t, rawCallCount, 3, "the body ran 3 times before the exit")
    rawCallCount = 0
    expect_value(t, rt, loop2, 0, 7, "the exit branch taken at once")
    equal(t, rawCallCount, 0, "the body never ran")

    // a raw function's trap: forwardTrap of its M3Result through op_Call,
    // rt.originStack restored
    let trapBlockPC = emit_op(rt, "op_CallRawFunction")
    let trapBlockFn = fixture_function(rt, trapBlockPC, 0)
    emit_int(rt, 1)
    emit_int(rt, trapBlockFn)
    emit_int(rt, -1)
    let rawTrapPC = emit_op(rt, "op_Entry")
    let rawTrapFn = fixture_function(rt, rawTrapPC, 0)
    emit_int(rt, rawTrapFn)
    emit_op(rt, "op_Call")
    emit_int(rt, trapBlockPC)
    emit_int(rt, 4)
    emit_op(rt, "op_Return")
    expect_trap(t, rt, rawTrapFn, 0, "host function trap", "raw function trap")
    equal(t, rt.originStack, 0, "rt.originStack restored after the trapping raw call")
    equal(t, rt.sp, 0, "rt.sp restored after the trapping raw call")

    // op_BranchIf_s: br_if on a slot; the target lands on a second return
    let brIfPC = emit_op(rt, "op_Entry")
    let brIf = fixture_function(rt, brIfPC, 0)
    emit_int(rt, brIf)
    emit_op(rt, "op_BranchIf_s")
    emit_int(rt, 1)
    let brIfPatch = emit_int(rt, -1)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    let brIfTarget = emit_op(rt, "op_Const32")
    emit_u32(rt, 2u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    rt.code[brIfPatch] = u64(brIfTarget)
    expect_value(t, rt, brIf, 3, 2, "BranchIf_s taken")
    expect_value(t, rt, brIf, 0, 1, "BranchIf_s not taken")

    // op_BranchIf_r: br_if on the register (the condition moved there by
    // op_SetRegister_i32 from the arg slot), the same two targets
    let brIfRPC = emit_op(rt, "op_Entry")
    let brIfR = fixture_function(rt, brIfRPC, 0)
    emit_int(rt, brIfR)
    emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 1)
    emit_op(rt, "op_BranchIf_r")
    let brIfRPatch = emit_int(rt, -1)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    let brIfRTarget = emit_op(rt, "op_Const32")
    emit_u32(rt, 2u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    rt.code[brIfRPatch] = u64(brIfRTarget)
    expect_value(t, rt, brIfR, 3, 2, "BranchIf_r taken")
    expect_value(t, rt, brIfR, 0, 1, "BranchIf_r not taken")

    // op_BranchIfPrologue_s: the prologue runs when the condition holds,
    // a zero condition jumps over it
    let proPC = emit_op(rt, "op_Entry")
    let pro = fixture_function(rt, proPC, 0)
    emit_int(rt, pro)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 9u)
    emit_int(rt, 0)
    emit_op(rt, "op_BranchIfPrologue_s")
    emit_int(rt, 1)
    let proPatch = emit_int(rt, -1)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 1u)
    emit_int(rt, 0)
    let proSkip = emit_op(rt, "op_Return")
    rt.code[proPatch] = u64(proSkip)
    expect_value(t, rt, pro, 5, 1, "BranchIfPrologue_s runs the prologue")
    expect_value(t, rt, pro, 0, 9, "BranchIfPrologue_s jumps over the prologue")

    // op_If_s on the arg slot, else page through op_Branch
    let ifsPC = emit_op(rt, "op_Entry")
    let ifs = fixture_function(rt, ifsPC, 0)
    emit_int(rt, ifs)
    emit_op(rt, "op_If_s")
    emit_int(rt, 1)
    let ifsElsePatch = emit_int(rt, -1)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 11u)
    emit_int(rt, 0)
    emit_op(rt, "op_Branch")
    let ifsEndPatch = emit_int(rt, -1)
    let ifsElse = emit_op(rt, "op_Const32")
    emit_u32(rt, 22u)
    emit_int(rt, 0)
    let ifsEnd = emit_op(rt, "op_Return")
    rt.code[ifsElsePatch] = u64(ifsElse)
    rt.code[ifsEndPatch] = u64(ifsEnd)
    expect_value(t, rt, ifs, -1, 11, "If_s then")
    expect_value(t, rt, ifs, 0, 22, "If_s else")

    // op_BranchTable: two targets and the default, index from the arg slot
    let btPC = emit_op(rt, "op_Entry")
    let bt = fixture_function(rt, btPC, 0)
    emit_int(rt, bt)
    emit_op(rt, "op_BranchTable")
    emit_int(rt, 1)
    emit_u32(rt, 2u)
    let bt0 = emit_int(rt, -1)
    let bt1 = emit_int(rt, -1)
    let btDefault = emit_int(rt, -1)
    let target0 = emit_op(rt, "op_Const32")
    emit_u32(rt, 10u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    let target1 = emit_op(rt, "op_Const32")
    emit_u32(rt, 20u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    let targetDefault = emit_op(rt, "op_Const32")
    emit_u32(rt, 30u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")
    rt.code[bt0] = u64(target0)
    rt.code[bt1] = u64(target1)
    rt.code[btDefault] = u64(targetDefault)
    expect_value(t, rt, bt, 0, 10, "BranchTable[0]")
    expect_value(t, rt, bt, 1, 20, "BranchTable[1]")
    expect_value(t, rt, bt, 2, 30, "BranchTable[2] = default")
    expect_value(t, rt, bt, 1000, 30, "BranchTable[1000] clamps to the default")
    expect_value(t, rt, bt, -1, 30, "BranchTable[u32 max] clamps to the default")

    // op_End ends the code like op_Return
    let endPC = emit_op(rt, "op_Entry")
    let endFn = fixture_function(rt, endPC, 0)
    emit_int(rt, endFn)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 3u)
    emit_int(rt, 0)
    emit_op(rt, "op_End")
    expect_value(t, rt, endFn, 0, 3, "op_End")

    // op_Unsupported traps with its own string
    let unsPC = emit_op(rt, "op_Entry")
    let uns = fixture_function(rt, unsPC, 0)
    emit_int(rt, uns)
    emit_op(rt, "op_Unsupported")
    expect_trap(t, rt, uns, 0, "unsupported instruction executed", "op_Unsupported")
}


// ============================================================================
// Eden: slot, register, constant, select and global operations
// ============================================================================


// runs one operation (plus its immediates, already emitted at `pc`) followed
// by op_Return, on the frame at rt.sp
def private run_single(var rt : M3Runtime; pc : pc_t) : m3ret_t {
    emit_op(rt, "op_Return")
    rt.trap = m3Err_none
    rt.pc = pc
    return RunCode(rt)
}


def test_slots_and_globals(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(32)
    rt.sp = 4   // the frame base, so slot offsets are relative

    // Const32 / Const64 write the slot (32-bit: the whole word, zero-extended)
    var pc = emit_op(rt, "op_Const32")
    emit_u32(rt, 0x80000001u)
    emit_int(rt, 0)
    equal(t, run_single(rt, pc), M3_RETURN, "Const32 runs")
    equal(t, rt.stack[4], 0x80000001ul, "Const32 wrote slot 0 zero-extended")
    pc = emit_op(rt, "op_Const64")
    emit(rt, 0x8000000000000001ul)
    emit_int(rt, 2)
    run_single(rt, pc)
    equal(t, rt.stack[6], 0x8000000000000001ul, "Const64 wrote slot 2")
    equal(t, rt.stack[7], 0xfffffffffffffffful, "Const64 left slot 3 alone")

    // SetRegister_i32 sign-extends into the register; SetSlot_i32 writes the low half
    rt.stack[4] = u64(0xfffffff0u)   // -16 as i32
    pc = emit_op(rt, "op_SetRegister_i32")
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffff0ul, "SetRegister_i32 sign-extended -16 (C: m3reg_t)")
    pc = emit_op(rt, "op_SetSlot_i32")
    emit_int(rt, 1)
    run_single(rt, pc)
    equal(t, rt.stack[5], 0xfffffff0ul, "SetSlot_i32 wrote the i32 zero-extended into the word")

    // PreserveSetSlot_i32: the old value goes to the preserve slot
    rt.r0 = 123ul
    rt.stack[5] = 0xabcdul
    pc = emit_op(rt, "op_PreserveSetSlot_i32")
    emit_int(rt, 1)   // stack
    emit_int(rt, 3)   // preserve
    run_single(rt, pc)
    equal(t, rt.stack[7], 0xabcdul, "PreserveSetSlot_i32 preserved the old value")
    equal(t, rt.stack[5], 123ul, "PreserveSetSlot_i32 stored the register")

    // i64 family
    rt.stack[8] = 0x8000000000000005ul
    pc = emit_op(rt, "op_SetRegister_i64")
    emit_int(rt, 4)
    run_single(rt, pc)
    equal(t, rt.r0, 0x8000000000000005ul, "SetRegister_i64")
    pc = emit_op(rt, "op_SetSlot_i64")
    emit_int(rt, 5)
    run_single(rt, pc)
    equal(t, rt.stack[9], 0x8000000000000005ul, "SetSlot_i64")
    rt.r0 = 77ul
    pc = emit_op(rt, "op_PreserveSetSlot_i64")
    emit_int(rt, 5)
    emit_int(rt, 6)
    run_single(rt, pc)
    equal(t, rt.stack[10], 0x8000000000000005ul, "PreserveSetSlot_i64 preserved")
    equal(t, rt.stack[9], 77ul, "PreserveSetSlot_i64 stored")

    // f32 family: the register is f64, the slot keeps the f32 bits
    set_stack_f32(rt, 4, -1.5f)
    pc = emit_op(rt, "op_SetRegister_f32")
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, rt.fp0, -1.5lf, "SetRegister_f32 widened into _fp0")
    rt.fp0 = 2.25lf
    pc = emit_op(rt, "op_SetSlot_f32")
    emit_int(rt, 1)
    run_single(rt, pc)
    equal(t, stack_u32(rt, 5), float_bits_to_uint(2.25f), "SetSlot_f32 stored the f32 bits")
    rt.fp0 = 8.0lf
    pc = emit_op(rt, "op_PreserveSetSlot_f32")
    emit_int(rt, 1)
    emit_int(rt, 2)
    run_single(rt, pc)
    equal(t, stack_f32(rt, 6), 2.25f, "PreserveSetSlot_f32 preserved")
    equal(t, stack_f32(rt, 5), 8.0f, "PreserveSetSlot_f32 stored")

    // f64 family
    set_stack_f64(rt, 4, -0.125lf)
    pc = emit_op(rt, "op_SetRegister_f64")
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, rt.fp0, -0.125lf, "SetRegister_f64")
    rt.fp0 = 3.5lf
    pc = emit_op(rt, "op_SetSlot_f64")
    emit_int(rt, 1)
    run_single(rt, pc)
    equal(t, stack_f64(rt, 5), 3.5lf, "SetSlot_f64")
    rt.fp0 = 4.5lf
    pc = emit_op(rt, "op_PreserveSetSlot_f64")
    emit_int(rt, 1)
    emit_int(rt, 2)
    run_single(rt, pc)
    equal(t, stack_f64(rt, 6), 3.5lf, "PreserveSetSlot_f64 preserved")
    equal(t, stack_f64(rt, 5), 4.5lf, "PreserveSetSlot_f64 stored")

    // CopySlot / PreserveCopySlot
    rt.stack[4] = 0x1111111122222222ul
    rt.stack[5] = 0ul
    pc = emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 1)   // dst
    emit_int(rt, 0)   // src
    run_single(rt, pc)
    equal(t, rt.stack[5], 0x22222222ul, "CopySlot_32 copies the low 32 bits")
    pc = emit_op(rt, "op_CopySlot_64")
    emit_int(rt, 2)
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, rt.stack[6], 0x1111111122222222ul, "CopySlot_64 copies the word")
    rt.stack[7] = 0x33333333ul
    pc = emit_op(rt, "op_PreserveCopySlot_32")
    emit_int(rt, 3)   // dest
    emit_int(rt, 0)   // src
    emit_int(rt, 8)   // preserve
    run_single(rt, pc)
    equal(t, rt.stack[12], 0x33333333ul, "PreserveCopySlot_32 preserved the destination")
    equal(t, rt.stack[7], 0x22222222ul, "PreserveCopySlot_32 copied")
    rt.stack[7] = 0x4444444455555555ul
    pc = emit_op(rt, "op_PreserveCopySlot_64")
    emit_int(rt, 3)
    emit_int(rt, 0)
    emit_int(rt, 9)
    run_single(rt, pc)
    equal(t, rt.stack[13], 0x4444444455555555ul, "PreserveCopySlot_64 preserved the destination")
    equal(t, rt.stack[7], 0x1111111122222222ul, "PreserveCopySlot_64 copied")

    // Select: the register forms
    set_stack_i32(rt, 4, 100)
    set_stack_i32(rt, 5, 200)
    rt.r0 = 1ul
    pc = emit_op(rt, "op_Select_i32_rss")
    emit_int(rt, 1)   // operand2
    emit_int(rt, 0)   // operand1
    run_single(rt, pc)
    equal(t, i32(u32(rt.r0)), 100, "Select_i32_rss true picks operand1")
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_i32_rss")
    emit_int(rt, 1)
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, i32(u32(rt.r0)), 200, "Select_i32_rss false picks operand2")
    // the condition lives in frame slot 2 (stack index 6, rt.sp = 4)
    set_stack_i32(rt, 6, 0)   // condition
    rt.r0 = u64(u32(-7))
    pc = emit_op(rt, "op_Select_i32_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 0)   // operand1
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffff9ul, "Select_i32_srs false keeps the register, sign-extended")
    set_stack_i32(rt, 6, 1)
    pc = emit_op(rt, "op_Select_i32_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 1)   // operand2
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffff9ul, "Select_i32_ssr true keeps the register")
    set_stack_i64(rt, 8, -5l)
    set_stack_i64(rt, 10, 9l)
    set_stack_i32(rt, 6, 0)
    pc = emit_op(rt, "op_Select_i64_sss")
    emit_int(rt, 2)   // condition
    emit_int(rt, 6)   // operand2 = slot 6 (index 10)
    emit_int(rt, 4)   // operand1 = slot 4 (index 8)
    run_single(rt, pc)
    equal(t, i64(rt.r0), 9l, "Select_i64_sss false picks operand2")
    set_stack_f32(rt, 8, 1.5f)
    set_stack_f32(rt, 9, 2.5f)
    rt.r0 = 1ul
    pc = emit_op(rt, "op_Select_f32_rss")
    emit_int(rt, 5)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 1.5lf, "Select_f32_rss true")
    rt.fp0 = 7.0lf
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_f32_rrs")
    emit_int(rt, 5)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 7.0lf, "Select_f32_rrs false keeps _fp0")
    set_stack_f64(rt, 8, 1.25lf)
    set_stack_f64(rt, 10, 2.75lf)
    set_stack_i32(rt, 6, 3)
    pc = emit_op(rt, "op_Select_f64_sss")
    emit_int(rt, 2)   // condition
    emit_int(rt, 6)   // operand2 = slot 6 (index 10)
    emit_int(rt, 4)   // operand1 = slot 4 (index 8)
    run_single(rt, pc)
    equal(t, rt.fp0, 1.25lf, "Select_f64_sss true")
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_f64_rsr")
    emit_int(rt, 6)   // operand2 = slot 10
    run_single(rt, pc)
    equal(t, rt.fp0, 2.75lf, "Select_f64_rsr false picks operand2")

    // the remaining Select forms, both arms of each: the f32 operands in
    // slots 4 / 5 (indexes 8 / 9), the f64 and i64 operands in slots 4 / 6
    // (indexes 8 / 10), the condition in slot 2 (index 6) or in _r0
    // op_Select_f32_rsr: condition in _r0, operand2 in a slot, operand1 is _fp0
    set_stack_f32(rt, 9, 2.5f)
    rt.fp0 = 7.0lf
    rt.r0 = 1ul
    pc = emit_op(rt, "op_Select_f32_rsr")
    emit_int(rt, 5)   // operand2
    run_single(rt, pc)
    equal(t, rt.fp0, 7.0lf, "Select_f32_rsr true keeps _fp0")
    rt.fp0 = 7.0lf
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_f32_rsr")
    emit_int(rt, 5)   // operand2
    run_single(rt, pc)
    equal(t, rt.fp0, 2.5lf, "Select_f32_rsr false picks operand2")
    // op_Select_f32_srs: condition and operand1 in slots, operand2 is _fp0
    set_stack_f32(rt, 8, 1.5f)
    set_stack_i32(rt, 6, 1)
    rt.fp0 = 7.0lf
    pc = emit_op(rt, "op_Select_f32_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 1.5lf, "Select_f32_srs true picks operand1")
    set_stack_i32(rt, 6, 0)
    rt.fp0 = 7.0lf
    pc = emit_op(rt, "op_Select_f32_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 7.0lf, "Select_f32_srs false keeps _fp0")
    // op_Select_f32_ssr: condition and operand2 in slots, operand1 is _fp0
    set_stack_i32(rt, 6, 1)
    rt.fp0 = 7.0lf
    pc = emit_op(rt, "op_Select_f32_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 5)   // operand2
    run_single(rt, pc)
    equal(t, rt.fp0, 7.0lf, "Select_f32_ssr true keeps _fp0")
    set_stack_i32(rt, 6, 0)
    rt.fp0 = 7.0lf
    pc = emit_op(rt, "op_Select_f32_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 5)   // operand2
    run_single(rt, pc)
    equal(t, rt.fp0, 2.5lf, "Select_f32_ssr false picks operand2")
    // op_Select_f32_sss: the three in slots
    set_stack_i32(rt, 6, 1)
    pc = emit_op(rt, "op_Select_f32_sss")
    emit_int(rt, 2)   // condition
    emit_int(rt, 5)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 1.5lf, "Select_f32_sss true picks operand1")
    set_stack_i32(rt, 6, 0)
    pc = emit_op(rt, "op_Select_f32_sss")
    emit_int(rt, 2)   // condition
    emit_int(rt, 5)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 2.5lf, "Select_f32_sss false picks operand2")
    // op_Select_f64_rrs: condition in _r0, operand1 in a slot, operand2 is _fp0
    set_stack_f64(rt, 8, 1.25lf)
    set_stack_f64(rt, 10, 2.75lf)
    rt.fp0 = 9.5lf
    rt.r0 = 1ul
    pc = emit_op(rt, "op_Select_f64_rrs")
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 1.25lf, "Select_f64_rrs true picks operand1")
    rt.fp0 = 9.5lf
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_f64_rrs")
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 9.5lf, "Select_f64_rrs false keeps _fp0")
    // op_Select_f64_rss: condition in _r0, both operands in slots
    rt.r0 = 1ul
    pc = emit_op(rt, "op_Select_f64_rss")
    emit_int(rt, 6)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 1.25lf, "Select_f64_rss true picks operand1")
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_f64_rss")
    emit_int(rt, 6)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 2.75lf, "Select_f64_rss false picks operand2")
    // op_Select_f64_srs: condition and operand1 in slots, operand2 is _fp0
    set_stack_i32(rt, 6, 1)
    rt.fp0 = 9.5lf
    pc = emit_op(rt, "op_Select_f64_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 1.25lf, "Select_f64_srs true picks operand1")
    set_stack_i32(rt, 6, 0)
    rt.fp0 = 9.5lf
    pc = emit_op(rt, "op_Select_f64_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.fp0, 9.5lf, "Select_f64_srs false keeps _fp0")
    // op_Select_f64_ssr: condition and operand2 in slots, operand1 is _fp0
    set_stack_i32(rt, 6, 1)
    rt.fp0 = 9.5lf
    pc = emit_op(rt, "op_Select_f64_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 6)   // operand2
    run_single(rt, pc)
    equal(t, rt.fp0, 9.5lf, "Select_f64_ssr true keeps _fp0")
    set_stack_i32(rt, 6, 0)
    rt.fp0 = 9.5lf
    pc = emit_op(rt, "op_Select_f64_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 6)   // operand2
    run_single(rt, pc)
    equal(t, rt.fp0, 2.75lf, "Select_f64_ssr false picks operand2")
    // op_Select_i64_rss: condition in _r0 (read before the result lands
    // there), both operands in slots
    set_stack_i64(rt, 8, -5l)
    set_stack_i64(rt, 10, 9l)
    rt.r0 = 1ul
    pc = emit_op(rt, "op_Select_i64_rss")
    emit_int(rt, 6)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, i64(rt.r0), -5l, "Select_i64_rss true picks operand1")
    rt.r0 = 0ul
    pc = emit_op(rt, "op_Select_i64_rss")
    emit_int(rt, 6)   // operand2
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, i64(rt.r0), 9l, "Select_i64_rss false picks operand2")
    // op_Select_i64_srs: condition and operand1 in slots, operand2 is _r0
    set_stack_i32(rt, 6, 1)
    rt.r0 = 0x1122334455667788ul
    pc = emit_op(rt, "op_Select_i64_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, i64(rt.r0), -5l, "Select_i64_srs true picks operand1")
    set_stack_i32(rt, 6, 0)
    rt.r0 = 0x1122334455667788ul
    pc = emit_op(rt, "op_Select_i64_srs")
    emit_int(rt, 2)   // condition
    emit_int(rt, 4)   // operand1
    run_single(rt, pc)
    equal(t, rt.r0, 0x1122334455667788ul, "Select_i64_srs false keeps _r0")
    // op_Select_i64_ssr: condition and operand2 in slots, operand1 is _r0
    set_stack_i32(rt, 6, 1)
    rt.r0 = 0x1122334455667788ul
    pc = emit_op(rt, "op_Select_i64_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 6)   // operand2
    run_single(rt, pc)
    equal(t, rt.r0, 0x1122334455667788ul, "Select_i64_ssr true keeps _r0")
    set_stack_i32(rt, 6, 0)
    rt.r0 = 0x1122334455667788ul
    pc = emit_op(rt, "op_Select_i64_ssr")
    emit_int(rt, 2)   // condition
    emit_int(rt, 6)   // operand2
    run_single(rt, pc)
    equal(t, i64(rt.r0), 9l, "Select_i64_ssr false picks operand2")

    // op_NoOp (word 0): the placeholder of an uncompiled function, no
    // immediates, traps with m3Err_noCompiler
    pc = emit_op(rt, "op_NoOp")
    equal(t, run_single(rt, pc), M3_TRAP, "NoOp traps")
    equal_str(t, rt.trap, m3Err_noCompiler, "NoOp trap string")
    equal(t, rt.pc, pc + 1, "NoOp reads no immediate")

    // globals: the immediate is the handle into rt.globals
    m3_Realloc_Impl(rt.globals, 2, 0)
    rt.globals[0].valueBits = 0xaaaaaaaa00000042ul
    pc = emit_op(rt, "op_GetGlobal_s32")
    emit_int(rt, 0)
    emit_int(rt, 0)   // slot
    run_single(rt, pc)
    equal(t, rt.stack[4], 0x42ul, "GetGlobal_s32 reads the low four bytes")
    pc = emit_op(rt, "op_GetGlobal_s64")
    emit_int(rt, 0)
    emit_int(rt, 1)
    run_single(rt, pc)
    equal(t, rt.stack[5], 0xaaaaaaaa00000042ul, "GetGlobal_s64 reads the word")
    rt.r0 = 0x1234567800000001ul
    pc = emit_op(rt, "op_SetGlobal_i32")
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, rt.globals[0].valueBits, 0xaaaaaaaa00000001ul, "SetGlobal_i32 writes the low four bytes from _r0")
    pc = emit_op(rt, "op_SetGlobal_i64")
    emit_int(rt, 1)
    run_single(rt, pc)
    equal(t, rt.globals[1].valueBits, 0x1234567800000001ul, "SetGlobal_i64 writes the word from _r0")
    rt.stack[6] = 0x5555555500000099ul
    pc = emit_op(rt, "op_SetGlobal_s32")
    emit_int(rt, 0)
    emit_int(rt, 2)
    run_single(rt, pc)
    equal(t, rt.globals[0].valueBits, 0xaaaaaaaa00000099ul, "SetGlobal_s32 writes the low four bytes from the slot")
    pc = emit_op(rt, "op_SetGlobal_s64")
    emit_int(rt, 1)
    emit_int(rt, 2)
    run_single(rt, pc)
    equal(t, rt.globals[1].valueBits, 0x5555555500000099ul, "SetGlobal_s64 writes the word from the slot")
    rt.fp0 = -2.5lf
    pc = emit_op(rt, "op_SetGlobal_f32")
    emit_int(rt, 0)
    run_single(rt, pc)
    equal(t, M3Global_GetF32Value(rt.globals[0]), -2.5f, "SetGlobal_f32")
    equal(t, rt.globals[0].valueBits >> 32ul, 0xaaaaaaaaul, "SetGlobal_f32 keeps the high four bytes")
    pc = emit_op(rt, "op_SetGlobal_f64")
    emit_int(rt, 1)
    run_single(rt, pc)
    equal(t, M3Global_GetF64Value(rt.globals[1]), -2.5lf, "SetGlobal_f64")
}


// ============================================================================
// Eden: memory operations
// ============================================================================


// the test's ResizeMemory: grows rt.mem by whole pages of 16 bytes, fails
// above 8 pages (C's maxPages check)
def private test_resize_memory(var rt : M3Runtime; i_numPages : u32) : M3Result {
    if (i_numPages > 8u) {
        return m3Err_wasmMemoryOverflow
    }
    rt.memory.numPages = i_numPages
    resize(rt.mem, int(i_numPages) * 16)
    return m3Err_none
}


def test_memory_ops(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(32)
    rt.sp = 2
    resize(rt.mem, 32)
    for (i in range(32)) {
        rt.mem[i] = u8(i)
    }
    rt.mem[3] = 0x80u8
    rt.mem[4] = 0xffu8
    rt.mem[5] = 0x7fu8

    // loads through the register address (_r) with an offset, unaligned
    rt.r0 = 1ul
    var pc = emit_op(rt, "op_i32_Load_i8_r")
    emit_u32(rt, 2u)   // address 3: 0x80
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i32_Load_i8_r sign-extends -128")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i32_Load_u8_r")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0x80ul, "i32_Load_u8_r zero-extends")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i32_Load_i16_r")
    emit_u32(rt, 0u)   // bytes 80 ff -> 0xff80 = -128
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i32_Load_i16_r little-endian, sign-extended")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i32_Load_u16_r")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xff80ul, "i32_Load_u16_r zero-extended")
    rt.r0 = 2ul
    pc = emit_op(rt, "op_i32_Load_i32_r")
    emit_u32(rt, 0u)   // bytes 02 80 ff 7f -> 0x7fff8002
    run_single(rt, pc)
    equal(t, rt.r0, 0x7fff8002ul, "i32_Load_i32_r")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i32_Load_i32_r")
    emit_u32(rt, 0u)   // bytes 80 ff 7f 06 -> 0x067fff80
    run_single(rt, pc)
    equal(t, rt.r0, 0x067fff80ul, "i32_Load_i32_r unaligned")

    // the i32 loads through a slot address (_s), the same bytes
    set_stack_u32(rt, 2, 3u)
    pc = emit_op(rt, "op_i32_Load_i8_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)   // address 3: 0x80
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i32_Load_i8_s sign-extends -128")
    pc = emit_op(rt, "op_i32_Load_u8_s")
    emit_int(rt, 0)
    emit_u32(rt, 1u)   // address 4: 0xff
    run_single(rt, pc)
    equal(t, rt.r0, 0xfful, "i32_Load_u8_s zero-extends")
    pc = emit_op(rt, "op_i32_Load_i16_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)   // bytes 80 ff -> 0xff80
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i32_Load_i16_s little-endian, sign-extended")
    pc = emit_op(rt, "op_i32_Load_u16_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xff80ul, "i32_Load_u16_s zero-extended")
    pc = emit_op(rt, "op_i32_Load_i32_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)   // bytes 80 ff 7f 06 -> 0x067fff80
    run_single(rt, pc)
    equal(t, rt.r0, 0x067fff80ul, "i32_Load_i32_s unaligned")
    set_stack_u32(rt, 2, 0u)
    pc = emit_op(rt, "op_i32_Load_i32_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)   // bytes 00 01 02 80 -> 0x80020100, negative
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffff80020100ul, "i32_Load_i32_s sign-extends into the register")

    // loads through a slot address (_s)
    set_stack_u32(rt, 2, 3u)
    pc = emit_op(rt, "op_i64_Load_i8_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i64_Load_i8_s sign-extends")
    pc = emit_op(rt, "op_i64_Load_u8_s")
    emit_int(rt, 0)
    emit_u32(rt, 1u)   // address 4: 0xff
    run_single(rt, pc)
    equal(t, rt.r0, 0xfful, "i64_Load_u8_s zero-extends")
    pc = emit_op(rt, "op_i64_Load_i16_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i64_Load_i16_s sign-extends")
    pc = emit_op(rt, "op_i64_Load_u16_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xff80ul, "i64_Load_u16_s zero-extends")
    pc = emit_op(rt, "op_i64_Load_i32_s")
    emit_int(rt, 0)
    emit_u32(rt, 1u)   // address 4: ff 7f 06 07 -> 0x07067fff
    run_single(rt, pc)
    equal(t, rt.r0, 0x07067ffful, "i64_Load_i32_s positive")
    set_stack_u32(rt, 2, 1u)
    pc = emit_op(rt, "op_i64_Load_i32_s")
    emit_int(rt, 0)
    emit_u32(rt, 2u)   // address 3: 80 ff 7f 06 -> 0x067fff80
    run_single(rt, pc)
    equal(t, rt.r0, 0x067fff80ul, "i64_Load_i32_s")
    rt.mem[8] = 0xfeu8
    rt.mem[9] = 0xffu8
    rt.mem[10] = 0xffu8
    rt.mem[11] = 0xffu8
    set_stack_u32(rt, 2, 8u)
    pc = emit_op(rt, "op_i64_Load_i32_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffffeul, "i64_Load_i32_s sign-extends -2")
    pc = emit_op(rt, "op_i64_Load_u32_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffeul, "i64_Load_u32_s zero-extends")
    rt.r0 = 8ul
    pc = emit_op(rt, "op_i64_Load_u32_r")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffeul, "i64_Load_u32_r zero-extends")
    // the i64 loads through the register address (_r)
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i64_Load_i8_r")
    emit_u32(rt, 0u)   // address 3: 0x80
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i64_Load_i8_r sign-extends")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i64_Load_u8_r")
    emit_u32(rt, 1u)   // address 4: 0xff
    run_single(rt, pc)
    equal(t, rt.r0, 0xfful, "i64_Load_u8_r zero-extends")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i64_Load_i16_r")
    emit_u32(rt, 0u)   // bytes 80 ff -> 0xff80
    run_single(rt, pc)
    equal(t, rt.r0, 0xffffffffffffff80ul, "i64_Load_i16_r sign-extends")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i64_Load_u16_r")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.r0, 0xff80ul, "i64_Load_u16_r zero-extends")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_i64_Load_i32_r")
    emit_u32(rt, 0u)   // bytes 80 ff 7f 06 -> 0x067fff80
    run_single(rt, pc)
    equal(t, rt.r0, 0x067fff80ul, "i64_Load_i32_r positive")
    rt.r0 = 8ul
    pc = emit_op(rt, "op_i64_Load_i32_r")
    emit_u32(rt, 0u)   // bytes fe ff ff ff
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffffeul, "i64_Load_i32_r sign-extends -2")
    pc = emit_op(rt, "op_i64_Load_i64_s")
    emit_int(rt, 0)
    emit_u32(rt, 0u)   // address 8: fe ff ff ff 0c 0d 0e 0f
    run_single(rt, pc)
    equal(t, rt.r0, 0x0f0e0d0cfffffffeul, "i64_Load_i64_s")
    rt.r0 = 7ul
    pc = emit_op(rt, "op_i64_Load_i64_r")
    emit_u32(rt, 1u)
    run_single(rt, pc)
    equal(t, rt.r0, 0x0f0e0d0cfffffffeul, "i64_Load_i64_r with offset")

    // float loads
    store_f32(rt, 16, -3.75f)
    store_f64(rt, 20, 1234.5lf)
    rt.r0 = 16ul
    pc = emit_op(rt, "op_f32_Load_f32_r")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.fp0, -3.75lf, "f32_Load_f32_r widens")
    set_stack_u32(rt, 2, 10u)
    pc = emit_op(rt, "op_f32_Load_f32_s")
    emit_int(rt, 0)
    emit_u32(rt, 6u)
    run_single(rt, pc)
    equal(t, rt.fp0, -3.75lf, "f32_Load_f32_s")
    rt.r0 = 20ul
    pc = emit_op(rt, "op_f64_Load_f64_r")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.fp0, 1234.5lf, "f64_Load_f64_r")
    set_stack_u32(rt, 2, 19u)
    pc = emit_op(rt, "op_f64_Load_f64_s")
    emit_int(rt, 0)
    emit_u32(rt, 1u)
    run_single(rt, pc)
    equal(t, rt.fp0, 1234.5lf, "f64_Load_f64_s")

    // the bounds check: the last byte in range passes, one past traps
    rt.r0 = 28ul
    pc = emit_op(rt, "op_i32_Load_i32_r")
    emit_u32(rt, 0u)
    equal(t, run_single(rt, pc), M3_RETURN, "a load ending at mem_size passes")
    rt.r0 = 29ul
    pc = emit_op(rt, "op_i32_Load_i32_r")
    emit_u32(rt, 0u)
    equal(t, run_single(rt, pc), M3_TRAP, "a load ending past mem_size traps")
    equal_str(t, rt.trap, m3Err_trapOutOfBoundsMemoryAccess, "... with the out-of-bounds trap")
    rt.r0 = 0xffffffffful
    pc = emit_op(rt, "op_i32_Load_u8_r")
    emit_u32(rt, 1u)
    equal(t, run_single(rt, pc), M3_TRAP, "address + offset past 4 GiB traps (no u32 wrap)")
    set_stack_u32(rt, 2, 24u)
    pc = emit_op(rt, "op_i64_Load_i64_s")
    emit_int(rt, 0)
    emit_u32(rt, 1u)
    equal(t, run_single(rt, pc), M3_TRAP, "an i64 load one past the end traps")

    // stores: each width from the register and from a slot
    rt.r0 = u64(u32(-2))   // (i32) _r0 = -2
    set_stack_u32(rt, 2, 0u)
    pc = emit_op(rt, "op_i32_Store_u8_rs")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.mem[0], 0xfeu8, "i32_Store_u8_rs")
    set_stack_i32(rt, 3, int(0x1234))
    rt.r0 = 1ul
    pc = emit_op(rt, "op_i32_Store_i16_sr")
    emit_int(rt, 1)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.mem[1], 0x34u8, "i32_Store_i16_sr low byte")
    equal(t, rt.mem[2], 0x12u8, "i32_Store_i16_sr high byte")
    set_stack_i32(rt, 3, -305419897)   // 0xedcba987
    set_stack_u32(rt, 2, 4u)
    pc = emit_op(rt, "op_i32_Store_i32_ss")
    emit_int(rt, 1)
    emit_int(rt, 0)
    emit_u32(rt, 1u)   // address 5
    run_single(rt, pc)
    equal(t, load_u32(rt, 5), 0xedcba987u, "i32_Store_i32_ss")
    rt.r0 = 0x1122334455667788ul
    set_stack_u32(rt, 2, 12u)
    pc = emit_op(rt, "op_i64_Store_i64_rs")
    emit_int(rt, 0)
    emit_u32(rt, 1u)   // address 13
    run_single(rt, pc)
    equal(t, load_u64(rt, 13), 0x1122334455667788ul, "i64_Store_i64_rs")
    pc = emit_op(rt, "op_i64_Store_i32_rs")
    emit_int(rt, 0)
    emit_u32(rt, 0u)   // address 12
    run_single(rt, pc)
    equal(t, load_u32(rt, 12), 0x55667788u, "i64_Store_i32_rs truncates")
    set_stack_i64(rt, 4, i64(0x0102030480706050ul))   // slot 2: the value
    set_stack_u32(rt, 2, 12u)                          // slot 0: the address
    pc = emit_op(rt, "op_i64_Store_i32_ss")
    emit_int(rt, 2)   // value
    emit_int(rt, 0)   // address
    emit_u32(rt, 0u)   // address 12
    run_single(rt, pc)
    equal(t, load_u32(rt, 12), 0x80706050u, "i64_Store_i32_ss truncates")
    equal(t, load_u32(rt, 16), 0x22334455u, "i64_Store_i32_ss writes four bytes (the i64_Store_i64_rs bytes 16..19 kept)")
    pc = emit_op(rt, "op_i64_Store_i16_rs")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_u16(rt, 12), u16(0x7788), "i64_Store_i16_rs truncates")
    pc = emit_op(rt, "op_i64_Store_u8_rs")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.mem[12], 0x88u8, "i64_Store_u8_rs truncates")
    set_stack_i64(rt, 4, -1l)
    rt.r0 = 20ul
    pc = emit_op(rt, "op_i64_Store_i64_sr")
    emit_int(rt, 2)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_u64(rt, 20), 0xfffffffffffffffful, "i64_Store_i64_sr")
    set_stack_i64(rt, 4, int64(0x0102030405060708ul))
    set_stack_u32(rt, 2, 20u)
    pc = emit_op(rt, "op_i64_Store_i64_ss")
    emit_int(rt, 2)
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_u64(rt, 20), 0x0102030405060708ul, "i64_Store_i64_ss")
    pc = emit_op(rt, "op_i64_Store_u8_ss")
    emit_int(rt, 2)
    emit_int(rt, 0)
    emit_u32(rt, 8u)
    run_single(rt, pc)
    equal(t, rt.mem[28], 0x08u8, "i64_Store_u8_ss")
    pc = emit_op(rt, "op_i64_Store_i16_ss")
    emit_int(rt, 2)
    emit_int(rt, 0)
    emit_u32(rt, 9u)
    run_single(rt, pc)
    equal(t, load_u16(rt, 29), u16(0x0708), "i64_Store_i16_ss")
    rt.r0 = 28ul
    pc = emit_op(rt, "op_i64_Store_i32_sr")
    emit_int(rt, 2)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_u32(rt, 28), 0x05060708u, "i64_Store_i32_sr")
    rt.r0 = 27ul
    pc = emit_op(rt, "op_i64_Store_u8_sr")
    emit_int(rt, 2)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.mem[27], 0x08u8, "i64_Store_u8_sr")
    rt.r0 = 26ul
    pc = emit_op(rt, "op_i64_Store_i16_sr")
    emit_int(rt, 2)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_u16(rt, 26), u16(0x0708), "i64_Store_i16_sr")
    set_stack_i32(rt, 3, int(0x7eadbeef))
    rt.r0 = 0ul
    pc = emit_op(rt, "op_i32_Store_i32_sr")
    emit_int(rt, 1)
    emit_u32(rt, 24u)
    run_single(rt, pc)
    equal(t, load_u32(rt, 24), 0x7eadbeefu, "i32_Store_i32_sr")
    rt.r0 = u64(u32(0x7eadbeef))
    set_stack_u32(rt, 2, 0u)
    pc = emit_op(rt, "op_i32_Store_i32_rs")
    emit_int(rt, 0)
    emit_u32(rt, 8u)
    run_single(rt, pc)
    equal(t, load_u32(rt, 8), 0x7eadbeefu, "i32_Store_i32_rs")
    pc = emit_op(rt, "op_i32_Store_i16_rs")
    emit_int(rt, 0)
    emit_u32(rt, 12u)
    run_single(rt, pc)
    equal(t, load_u16(rt, 12), u16(0xbeef), "i32_Store_i16_rs")
    pc = emit_op(rt, "op_i32_Store_u8_sr")
    emit_int(rt, 1)
    emit_u32(rt, 0u)   // address _r0 = 0x7eadbeef + 0: out of bounds
    equal(t, run_single(rt, pc), M3_TRAP, "i32_Store_u8_sr out of bounds traps")
    rt.r0 = 14ul
    pc = emit_op(rt, "op_i32_Store_u8_sr")
    emit_int(rt, 1)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.mem[14], 0xefu8, "i32_Store_u8_sr")
    set_stack_u32(rt, 2, 15u)
    pc = emit_op(rt, "op_i32_Store_u8_ss")
    emit_int(rt, 1)
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, rt.mem[15], 0xefu8, "i32_Store_u8_ss")
    pc = emit_op(rt, "op_i32_Store_i16_ss")
    emit_int(rt, 1)
    emit_int(rt, 0)
    emit_u32(rt, 1u)
    run_single(rt, pc)
    equal(t, load_u16(rt, 16), u16(0xbeef), "i32_Store_i16_ss")

    // float stores
    rt.fp0 = -6.5lf
    set_stack_u32(rt, 2, 0u)
    pc = emit_op(rt, "op_f32_Store_f32_rs")
    emit_int(rt, 0)
    emit_u32(rt, 1u)
    run_single(rt, pc)
    equal(t, load_f32(rt, 1), -6.5f, "f32_Store_f32_rs narrows _fp0")
    rt.r0 = 5ul
    pc = emit_op(rt, "op_f32_Store_f32_rr")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_f32(rt, 5), -6.5f, "f32_Store_f32_rr")
    set_stack_f32(rt, 3, 9.25f)
    rt.r0 = 9ul
    pc = emit_op(rt, "op_f32_Store_f32_sr")
    emit_int(rt, 1)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_f32(rt, 9), 9.25f, "f32_Store_f32_sr")
    set_stack_u32(rt, 2, 13u)
    pc = emit_op(rt, "op_f32_Store_f32_ss")
    emit_int(rt, 1)
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_f32(rt, 13), 9.25f, "f32_Store_f32_ss")
    rt.fp0 = 1e100lf
    set_stack_u32(rt, 2, 17u)
    pc = emit_op(rt, "op_f64_Store_f64_rs")
    emit_int(rt, 0)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_f64(rt, 17), 1e100lf, "f64_Store_f64_rs")
    rt.r0 = 1ul
    pc = emit_op(rt, "op_f64_Store_f64_rr")
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_f64(rt, 1), 1e100lf, "f64_Store_f64_rr")
    set_stack_f64(rt, 4, -0.0lf)
    rt.r0 = 9ul
    pc = emit_op(rt, "op_f64_Store_f64_sr")
    emit_int(rt, 2)
    emit_u32(rt, 0u)
    run_single(rt, pc)
    equal(t, load_u64(rt, 9), 0x8000000000000000ul, "f64_Store_f64_sr keeps -0.0")
    set_stack_u32(rt, 2, 20u)
    pc = emit_op(rt, "op_f64_Store_f64_ss")
    emit_int(rt, 2)
    emit_int(rt, 0)
    emit_u32(rt, 4u)   // address 24, the last 8 bytes
    equal(t, run_single(rt, pc), M3_RETURN, "f64_Store_f64_ss ending at mem_size passes")
    equal(t, load_u64(rt, 24), 0x8000000000000000ul, "f64_Store_f64_ss")
    pc = emit_op(rt, "op_f64_Store_f64_ss")
    emit_int(rt, 2)
    emit_int(rt, 0)
    emit_u32(rt, 5u)
    equal(t, run_single(rt, pc), M3_TRAP, "f64_Store_f64_ss one past the end traps")
    equal_str(t, rt.trap, m3Err_trapOutOfBoundsMemoryAccess, "... with the out-of-bounds trap")

    // MemSize / MemGrow through the hook
    rt.memory.numPages = 2u
    resize(rt.mem, 32)
    ResizeMemoryHook = @@test_resize_memory
    pc = emit_op(rt, "op_MemSize")
    run_single(rt, pc)
    equal(t, rt.r0, 2ul, "MemSize returns numPages")
    rt.r0 = 3ul
    pc = emit_op(rt, "op_MemGrow")
    run_single(rt, pc)
    equal(t, rt.r0, 2ul, "MemGrow returns the previous page count")
    equal(t, rt.memory.numPages, 5u, "MemGrow grew to 5 pages")
    equal(t, mem_size(rt), 80, "MemGrow resized rt.mem")
    rt.r0 = 0ul
    pc = emit_op(rt, "op_MemGrow")
    run_single(rt, pc)
    equal(t, rt.r0, 5ul, "MemGrow by 0 returns the page count and does not resize")
    equal(t, mem_size(rt), 80, "... rt.mem unchanged")
    rt.r0 = u64(u32(-1))
    pc = emit_op(rt, "op_MemGrow")
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffffful, "MemGrow by a negative count returns -1")
    rt.r0 = 100ul
    pc = emit_op(rt, "op_MemGrow")
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffffful, "MemGrow past the limit returns -1")
    equal(t, rt.memory.numPages, 5u, "... and leaves the page count")
    ResizeMemoryHook = noResizeHook
    rt.r0 = 1ul
    pc = emit_op(rt, "op_MemGrow")
    run_single(rt, pc)
    equal(t, rt.r0, 0xfffffffffffffffful, "MemGrow without the hook returns -1")

    // MemCopy: overlapping both ways (memmove), then the traps
    for (i in range(80)) {
        rt.mem[i] = u8(i)
    }
    rt.r0 = 8ul                  // size
    set_stack_u32(rt, 2, 4u)     // source
    set_stack_u32(rt, 3, 8u)     // destination (above the source, overlapping)
    pc = emit_op(rt, "op_MemCopy")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_RETURN, "MemCopy forward overlap")
    var ok = true
    for (i in range(8)) {
        if (rt.mem[8 + i] != u8(4 + i)) {
            ok = false
        }
    }
    check(t, ok, "MemCopy to a higher address copied the original bytes")
    for (i in range(80)) {
        rt.mem[i] = u8(i)
    }
    set_stack_u32(rt, 2, 8u)     // source
    set_stack_u32(rt, 3, 4u)     // destination below the source
    pc = emit_op(rt, "op_MemCopy")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_RETURN, "MemCopy backward overlap")
    ok = true
    for (i in range(8)) {
        if (rt.mem[4 + i] != u8(8 + i)) {
            ok = false
        }
    }
    check(t, ok, "MemCopy to a lower address copied the original bytes")
    set_stack_u32(rt, 2, 0u)
    set_stack_u32(rt, 3, 72u)
    pc = emit_op(rt, "op_MemCopy")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_RETURN, "MemCopy ending at mem_size passes")
    set_stack_u32(rt, 3, 73u)
    pc = emit_op(rt, "op_MemCopy")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_TRAP, "MemCopy destination past the end traps")
    equal_str(t, rt.trap, m3Err_trapOutOfBoundsMemoryAccess, "... out of bounds")
    set_stack_u32(rt, 2, 73u)
    set_stack_u32(rt, 3, 0u)
    pc = emit_op(rt, "op_MemCopy")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_TRAP, "MemCopy source past the end traps")
    rt.r0 = 0ul
    set_stack_u32(rt, 2, 80u)
    set_stack_u32(rt, 3, 80u)
    pc = emit_op(rt, "op_MemCopy")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_RETURN, "MemCopy of size 0 at mem_size passes")

    // MemFill
    rt.r0 = 4ul                  // size
    set_stack_u32(rt, 2, 0x1abu) // byte (truncated to 0xab)
    set_stack_u32(rt, 3, 76u)    // destination
    pc = emit_op(rt, "op_MemFill")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_RETURN, "MemFill ending at mem_size passes")
    ok = true
    for (i in range(4)) {
        if (rt.mem[76 + i] != 0xabu8) {
            ok = false
        }
    }
    check(t, ok, "MemFill wrote the byte")
    equal(t, rt.mem[75], 3u8, "MemFill left the byte before alone (3, from the MemCopy above)")
    set_stack_u32(rt, 3, 77u)
    pc = emit_op(rt, "op_MemFill")
    emit_int(rt, 0)
    emit_int(rt, 1)
    equal(t, run_single(rt, pc), M3_TRAP, "MemFill past the end traps")
    equal_str(t, rt.trap, m3Err_trapOutOfBoundsMemoryAccess, "... out of bounds")
}


// ============================================================================
// Eden: op_CallIndirect and op_Compile with the lazy compile hook
// ============================================================================


var private compileCalls : int = 0
var private compileTargetPC : pc_t = -1
var private compileFails : bool = false


// the test's CompileFunction: "compiles" by pointing the function at the
// code the test assembled beforehand, or fails
def private test_compile_function(var rt : M3Runtime; io_function : IM3Function) : M3Result {
    compileCalls++
    if (compileFails) {
        return m3Err_functionStackOverflow
    }
    rt.functions[io_function].compiled = compileTargetPC
    return m3Err_none
}


// a caller doing call_indirect on module 0 with the table index in slot 1
// (the arg), the expected type `typeIdx`, the callee frame at slot 4 and
// the result copied to slot 0
def private emit_indirect_caller(var rt : M3Runtime; typeIdx : IM3FuncType) : IM3Function {
    let callerPC = emit_op(rt, "op_Entry")
    let caller = fixture_function(rt, callerPC, 2)
    emit_int(rt, caller)
    emit_op(rt, "op_CallIndirect")
    emit_int(rt, 1)        // tableIndex slot
    emit_int(rt, 0)        // module handle
    emit_int(rt, typeIdx)  // expected type
    emit_int(rt, 4)        // stackOffset
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 0)
    emit_int(rt, 4)
    emit_op(rt, "op_Return")
    return caller
}


def test_call_indirect_and_compile(var t : TestRun; fx : FixtureSource) {
    var rt <- exec_runtime(64)

    // two func types: (i32) -> i32 and () -> i32
    var typeA : IM3FuncType = -1
    var typeB : IM3FuncType = -1
    AllocFuncType(rt, typeA, 2u)
    rt.funcTypes[typeA].numRets = u16(1)
    rt.funcTypes[typeA].numArgs = u16(1)
    AllocFuncType(rt, typeB, 1u)
    rt.funcTypes[typeB].numRets = u16(1)

    // the callee: (i32) -> i32 returning 55, compiled
    let calleePC = emit_op(rt, "op_Entry")
    let callee = fixture_function(rt, calleePC, 0)
    rt.functions[callee].funcTypeIdx = typeA
    emit_int(rt, callee)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 55u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")

    // a not yet compiled function of the same type; its code is assembled
    // here and the hook points the function at it
    let lazyPC = emit_op(rt, "op_Entry")
    let lazy = fixture_function(rt, lazyPC, 0)
    rt.functions[lazy].funcTypeIdx = typeA
    rt.functions[lazy].compiled = -1
    emit_int(rt, lazy)
    emit_op(rt, "op_Const32")
    emit_u32(rt, 66u)
    emit_int(rt, 0)
    emit_op(rt, "op_Return")

    // the module's table: [callee, null, lazy]
    m3_Realloc_Impl(rt.modules, 1, 0)
    push(rt.modules[0].table0, callee)
    push(rt.modules[0].table0, -1)
    push(rt.modules[0].table0, lazy)
    rt.modules[0].table0Size = 3u

    // the caller: call_indirect with the table index in slot 1 (the arg),
    // the callee frame at slot 4, the result copied to slot 0
    let callerA = emit_indirect_caller(rt, typeA)
    let callerB = emit_indirect_caller(rt, typeB)

    expect_value(t, rt, callerA, 0, 55, "call_indirect through the table")
    equal(t, rt.sp, 0, "rt.sp restored after call_indirect")
    expect_trap(t, rt, callerA, 3, m3Err_trapTableIndexOutOfRange, "call_indirect index == table0Size")
    expect_trap(t, rt, callerA, -1, m3Err_trapTableIndexOutOfRange, "call_indirect index u32 max")
    expect_trap(t, rt, callerA, 1, m3Err_trapTableElementIsNull, "call_indirect null element")
    expect_trap(t, rt, callerB, 0, m3Err_trapIndirectCallTypeMismatch, "call_indirect type mismatch by handle")

    // the lazy path: the hook compiles on the first call only
    CompileFunctionHook = @@test_compile_function
    compileCalls = 0
    compileTargetPC = lazyPC
    compileFails = false
    expect_value(t, rt, callerA, 2, 66, "call_indirect compiles a function lazily")
    equal(t, compileCalls, 1, "the hook ran once")
    equal(t, rt.functions[lazy].compiled, lazyPC, "the hook set function.compiled")
    expect_value(t, rt, callerA, 2, 66, "call_indirect of the now compiled function")
    equal(t, compileCalls, 1, "the hook did not run again")

    // a failing compile is the trap
    rt.functions[lazy].compiled = -1
    compileFails = true
    expect_trap(t, rt, callerA, 2, m3Err_functionStackOverflow, "call_indirect with a failing compile")
    equal(t, compileCalls, 2, "the hook ran for the failing compile")

    // no hook: the bridge's own error
    CompileFunctionHook = noCompileHook
    expect_trap(t, rt, callerA, 2, "lazy compilation hook is not wired", "call_indirect without the hook")

    // op_Compile: emitted in place of op_Call for a function not yet
    // compiled; it rewrites itself to op_Call with the compiled pc and runs it
    let compileCallerPC = emit_op(rt, "op_Entry")
    let compileCaller = fixture_function(rt, compileCallerPC, 2)
    emit_int(rt, compileCaller)
    let compileWord = emit_op(rt, "op_Compile")
    let functionWord = emit_int(rt, lazy)
    emit_int(rt, 4)   // stackOffset, read by the rewritten op_Call
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 0)
    emit_int(rt, 4)
    emit_op(rt, "op_Return")
    CompileFunctionHook = @@test_compile_function
    compileCalls = 0
    compileFails = false
    expect_value(t, rt, compileCaller, 0, 66, "op_Compile compiles and calls")
    equal(t, compileCalls, 1, "op_Compile ran the hook once")
    equal(t, rt.code[compileWord], m3_OpWord("op_Call"), "op_Compile rewrote its word to op_Call")
    equal(t, rt.code[functionWord], u64(lazyPC), "op_Compile patched the compiled pc into the immediate")
    expect_value(t, rt, compileCaller, 0, 66, "the rewritten op_Call runs")
    equal(t, compileCalls, 1, "the rewritten op_Call does not compile again")

    // op_Compile of an already compiled function skips the hook
    let compile2PC = emit_op(rt, "op_Entry")
    let compile2 = fixture_function(rt, compile2PC, 2)
    emit_int(rt, compile2)
    emit_op(rt, "op_Compile")
    emit_int(rt, callee)
    emit_int(rt, 4)
    emit_op(rt, "op_CopySlot_32")
    emit_int(rt, 0)
    emit_int(rt, 4)
    emit_op(rt, "op_Return")
    compileCalls = 0
    expect_value(t, rt, compile2, 0, 55, "op_Compile of a compiled function")
    equal(t, compileCalls, 0, "... skips the hook")

    // op_Compile with a failing compile traps and leaves the rewrite done
    let compile3PC = emit_op(rt, "op_Entry")
    let compile3 = fixture_function(rt, compile3PC, 2)
    emit_int(rt, compile3)
    let compile3Word = emit_op(rt, "op_Compile")
    emit_int(rt, lazy)
    emit_int(rt, 4)
    emit_op(rt, "op_Return")
    rt.functions[lazy].compiled = -1
    compileFails = true
    expect_trap(t, rt, compile3, 0, m3Err_functionStackOverflow, "op_Compile with a failing compile")
    equal(t, rt.code[compile3Word], m3_OpWord("op_Call"), "op_Compile rewrote its word before compiling (C: rewrite_op first)")
    CompileFunctionHook = noCompileHook
}


// ============================================================================
// Runner
// ============================================================================


// Eden: the sweep over the whole table (the part-2 / part-3 sweeps of the
// family tables cover their ranges; this one covers part 1 too): every word
// 0..OP_COUNT-1 of g_opIndex was marked by mark_executed, from a program this
// file assembled and ran or from a table invoke. Runs last.
def test_every_op_executed(var t : TestRun; fx : FixtureSource) {
    m3_build_op_table()
    equal(t, m3_OpCount(), OP_COUNT, "the table registers {OP_COUNT} operations")
    var named = 0
    var missing = 0
    for (name, idx in keys(g_opIndex), values(g_opIndex)) {
        named++
        var ran = false
        if (idx >= 0 && idx < length(executedWords)) {
            ran = executedWords[idx]
        }
        if (!ran) {
            check(t, false, "never executed: word {idx} {name}")
            missing++
        }
    }
    equal(t, named, OP_COUNT, "g_opIndex names every word 0..{OP_COUNT - 1}")
    equal(t, missing, 0, "every operation word is executed by this file")
}


// ============================================================================
// The runner
// ============================================================================


def public run_tests_m3_exec(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_exec_control_flow")
    test_exec_control_flow(t, fx)
    begin_test(t, "test_exec_operand_order_and_integer_arithmetic")
    test_exec_operand_order_and_integer_arithmetic(t, fx)
    begin_test(t, "test_exec_division_traps_and_rem_s_quirk")
    test_exec_division_traps_and_rem_s_quirk(t, fx)
    begin_test(t, "test_exec_float_unary_ops")
    test_exec_float_unary_ops(t, fx)
    begin_test(t, "test_op_table")
    test_op_table(t, fx)
    begin_test(t, "test_arithmetic_families")
    test_arithmetic_families(t, fx)
    begin_test(t, "test_conversion_families")
    test_conversion_families(t, fx)
    begin_test(t, "test_nested_call")
    test_nested_call(t, fx)
    begin_test(t, "test_loops_and_branches")
    test_loops_and_branches(t, fx)
    begin_test(t, "test_slots_and_globals")
    test_slots_and_globals(t, fx)
    begin_test(t, "test_memory_ops")
    test_memory_ops(t, fx)
    begin_test(t, "test_call_indirect_and_compile")
    test_call_indirect_and_compile(t, fx)
    begin_test(t, "test_every_op_executed")
    test_every_op_executed(t, fx)
}
