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

/*
    test_m3_exec.das: Eden counterpart of
    .upstream/tests/integration/test_m3_exec.das (PART 1 of 3).

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

    Coverage of the upstream [test]s in this part:
      - test_exec_control_flow: the if/else (op_If_r, op_Branch), select
        (op_Select_i32_sss) and unreachable (op_Unreachable) cases are
        assembled; the loop-sum case needs op_i32_Add_* / op_i32_Subtract_*
        and waits for part 2 (marked inside the test).
      - the three other upstream tests exercise only the arithmetic and
        conversion families of parts 2 and 3 and are marked below.
    Tests added for the Eden shape (no upstream counterpart):
      - test_op_table: the registration count of this part, the
        m3_OpAt(m3_OpWord(name)) round trip, the registration order, the
        idempotent rebuild, and the d_m3Assert panic on an unknown name
        (caught with try / recover, DESIGN.md section 1);
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
        (success and failure), and op_Compile's in-place rewrite to op_Call.
*/


// PART 2: test_exec_operand_order_and_integer_arithmetic (needs the i32/i64
// Add, Subtract, Multiply, ShiftLeft, Rotl, Clz, Ctz, Popcnt, Extend and
// Wrap operations of the arithmetic families)
// PART 2: test_exec_division_traps_and_rem_s_quirk (needs the i32 Divide
// and Remainder operations)
// PART 3: test_exec_float_unary_ops (needs the f32/f64 Floor, Ceil, Nearest,
// Abs operations of part 2 and the Reinterpret / Trunc conversions of part 3)


// ============================================================================
// Helpers: a runtime built by hand, code assembled by name
// ============================================================================


// the number of operations this part registers (the `def public op_` count
// of source/m3_exec.das after part 1)
let PART1_OP_COUNT = 128


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


// an operation word by name
def private emit_op(var rt : M3Runtime; name : string) : int {
    return emit(rt, m3_OpWord(name))
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

    // PART 2: sum 1..n with a loop and br_if (op_Loop, op_ContinueLoopIf,
    // local.set/tee) needs op_i32_Add_ss / op_i32_Subtract_ss; the loop
    // machinery itself is covered by test_loops_and_branches below.

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
// Eden: the op table
// ============================================================================


def test_op_table(var t : TestRun; fx : FixtureSource) {
    m3_build_op_table()
    equal(t, m3_OpCount(), PART1_OP_COUNT, "part 1 registers {PART1_OP_COUNT} operations")
    equal(t, length(g_ops), length(g_opIndex), "one index entry per operation")

    // the registration order is the index: op_NoOp first, then file order
    equal(t, m3_OpWord("op_NoOp"), 0ul, "op_NoOp is word 0")
    equal(t, m3_OpWord("op_GetGlobal_s32"), 1ul, "op_GetGlobal_s32 follows op_NoOp (part 1 order)")
    equal(t, m3_OpWord("op_i64_Store_i64_ss"), u64(PART1_OP_COUNT - 1), "op_i64_Store_i64_ss is the last word of part 1")
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
    equal(t, m3_OpCount(), PART1_OP_COUNT, "a rebuild registers the same count")
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
def private raw_decrement(var rt : M3Runtime; sp : int) : M3Result {
    rawCallCount++
    rawSeenOrigin = rt.originStack
    let v = stack_i32(rt, sp + 1)
    set_stack_i32(rt, sp + 0, v - 1)
    return m3Err_none
}


def private raw_trap(var rt : M3Runtime; sp : int) : M3Result {
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


def public run_tests_m3_exec(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_exec_control_flow")
    test_exec_control_flow(t, fx)
    begin_test(t, "test_op_table")
    test_op_table(t, fx)
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
}
