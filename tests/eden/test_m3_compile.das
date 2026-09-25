options gen2
options indenting = 4

module test_m3_compile shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_compile
require modules/wasm3das/source/m3_exec        // m3_build_op_table, m3_OpWord, RunCode
require modules/wasm3das/source/m3_exec_defs   // the stack accessors, the return protocol
require modules/wasm3das/source/m3_code        // NumFreeLines, EmitWord, GetPagePC
require modules/wasm3das/source/m3_function    // AllocFuncType
require modules/wasm3das/source/m3_module      // Module_AddFunction
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core

/*
    test_m3_compile.das: Eden counterpart of
    .upstream/tests/integration/test_m3_compile.das (PART 1 of the port:
    everything of m3_compile.c before the operation tables).

    The upstream tests load fib32.wasm through m3_ParseModule / m3_LoadModule
    (m3_env, m3_parse: later modules) to get a loaded module whose only
    function has the type (i32) -> i32, replace its body with hand-written
    bytes and compile them. Eden: the fixture builds that module by hand in
    the runtime's arenas (a func type interned with AllocFuncType, a module
    slot with `runtime = 0`, a function added with Module_AddFunction whose
    body is the module's `wasm` array), so the same bodies compile through
    the same CompileFunction; the compiled code is then run through RunCode
    (m3_Call's entry, as tests/eden/test_m3_exec.das does) to check the
    values the compiler's words produce.

    The operation tables c_operations / c_operationsFC and their builder
    m3_build_operations_table are PART 2 of the port. Until they exist, the
    fixture installs the rows its bodies need (the C rows of the opcodes
    used, names resolved through m3_OpWord exactly as the builder will) with
    install_part1_table; PART 2 replaces that helper with a call to
    m3_build_operations_table and keeps the checks.

    Coverage of the upstream [test]s (3 of 4 ported, 1 deferred):
      - test_compile_negative_i32_constants_keep_the_c_slot_behaviour: the
        same two bodies and the same numConstantBytes checks (8 for two
        i32.const -1, 4 for two i32.const 1), plus the Eden shape of the
        constant table (one word per slot, length == numConstantBytes / 4)
        and the compiled function run.
      - test_compile_stack_top_after_unreachable: the same two bodies.
      - test_compile_rejects_reserved_and_unknown_opcodes: the same three
        bodies and error strings (0x06 reserved, 0xc5 DEBUG-only, 0xfd past
        the table).
    // PART 2: test_operation_table_after_new_environment -- needs the
    // c_operations table, m3_build_operations_table and m3_NewEnvironment
    // (m3_env); ported with the tables.
    Tests added for the Eden shape (no upstream counterpart):
      - test_slot_and_type_stack: the slot and register accounting
        (AllocateSlots with alignment, MarkSlotAllocated / DeallocateSlot,
        Push / Pop / PopType / PushRegister, the register aliases, the
        underrun and overflow results, GetMaxUsedSlotPlusOne) and the
        polymorphic stack (SetStackPolymorphic unwinds, Pop / PopType on it,
        the -1 top index);
      - test_emit_words: EmitOp by name and by index writes the op word,
        EmitConstant32 / EmitSlotOffset / EmitPointer / ReservePointer write
        the words of DESIGN.md 4.4 at the pc they report, nothing is emitted
        without a page, the null-operation assert, op_NoOp on a polymorphic
        stack, and the page bridge of EnsureCodePageNumLines (op_Branch +
        the pc of the new page);
      - test_patch_chain_and_scopes: a forward-branch patch chain threaded
        through the code words is resolved by PatchBranches, and
        GetBlockScope / EmitPatchingBranchPointer walk and write the scope
        stack by handle;
      - test_compile_function_trivial_bodies: CompileFunction on
        `i32.const 42; end`, `local.get 0; end`, `local.get 0; i32.const 1;
        i32.add; end` (Compile_Operator through the resolved table row) with
        the emitted words and the executed results, `unreachable; end`
        trapping when run, and the failures "function body is missing",
        m3Err_typeCountMismatch (`end` alone on an (i32) -> i32 function)
        and m3Err_wasmMalformed (no `end`);
      - test_compile_raw_function: CompileRawFunction's four words and the
        module link.
*/


// ============================================================================
// Helpers: the fixture module and the part-1 operation table
// ============================================================================


// resolves the four op names of a row into op-table indices, as
// m3_build_operations_table (PART 2) will
def private resolve_row(var row : M3OpInfo&) {
    for (i in range(4)) {
        if (!empty(row.opNames[i])) {
            row.operations[i] = int(m3_OpWord(row.opNames[i]))
        } else {
            row.operations[i] = c_opNull
        }
    }
}


// PART 2: replaced by m3_build_operations_table(). The rows below are the C
// rows (wasm3c/source/m3_compile.c) of the opcodes the bodies of this file
// use; every other row is left as C's zero-filled release table leaves the
// DEBUG-only rows (no operations, no compiler), 0x06 is M3OP_RESERVED.
def private install_part1_table() {
    let i32Type = int(u8(M3ValueType.c_m3Type_i32))
    let noneType = int(u8(M3ValueType.c_m3Type_none))
    let anyType = int(0xff)
    m3_Malloc_Impl(c_operations, 253)
    m3_Malloc_Impl(c_operationsFC, 12)
    c_operations[0x00] = M3OP("unreachable", 0, noneType, "op_Unreachable", "", "", "", @@Compile_Unreachable)
    c_operations[0x01] = M3OP("nop", 0, noneType, "", "", "", "", @@Compile_Nop)
    c_operations[0x06] = M3OP_RESERVED()
    c_operations[0x0b] = M3OP("end", 0, noneType, "", "", "", "", @@Compile_End)
    c_operations[0x0f] = M3OP("return", 0, anyType, "op_Return", "", "", "", @@Compile_Return)
    c_operations[0x10] = M3OP("call", 0, anyType, "op_Call", "", "", "", @@Compile_Call)
    c_operations[0x1a] = M3OP("drop", -1, noneType, "", "", "", "", @@Compile_Drop)
    c_operations[0x20] = M3OP("local.get", 1, anyType, "", "", "", "", @@Compile_GetLocal)
    c_operations[0x21] = M3OP("local.set", 1, noneType, "", "", "", "", @@Compile_SetLocal)
    c_operations[0x22] = M3OP("local.tee", 0, anyType, "", "", "", "", @@Compile_SetLocal)
    c_operations[0x41] = M3OP("i32.const", 1, i32Type, "op_Const32", "", "", "", @@Compile_Const_i32)
    // C: M3OP ("i32.add", -1, i_32, d_commutativeBinOpList (i32, Add), NULL) - no compiler: Compile_Operator
    c_operations[0x6a] = M3OP("i32.add", -1, i32Type, "op_i32_Add_rs", "", "op_i32_Add_ss", "", c_noCompiler)
    for (i in range(length(c_operations))) {
        resolve_row(c_operations[i])
    }
}


// a runtime with the op table built, the part-1 operation rows installed,
// `slots` stack words, one module (handle 0, linked: runtime = 0) with one
// interned func type (i32) -> i32 and one function of that type (handle 0)
// whose body the tests write with compile_body
def private compile_runtime(slots : int) : M3Runtime {
    m3_build_op_table()
    install_part1_table()
    var rt = M3Runtime()
    resize(rt.stack, slots)
    rt.numStackSlots = u32(slots)
    rt.originStack = 0
    rt.sp = 0
    rt.pc = 0
    rt.trap = m3Err_none

    // the func type (i32) -> i32: types = [ret i32, arg i32]
    var funcType : IM3FuncType = -1
    AllocFuncType(rt, funcType, 2u)
    rt.funcTypes[funcType].numRets = u16(1)
    rt.funcTypes[funcType].numArgs = u16(1)
    rt.funcTypes[funcType].types[0] = u8(M3ValueType.c_m3Type_i32)
    rt.funcTypes[funcType].types[1] = u8(M3ValueType.c_m3Type_i32)

    // the module, loaded (C: module->runtime set by m3_LoadModule)
    m3_Realloc_Impl(rt.modules, 1, 0)
    rt.modules[0].runtime = 0
    rt.modules[0].name = "fixture"
    push(rt.modules[0].funcTypes, funcType)
    rt.modules[0].numFuncTypes = 1u

    // the function (C: ParseSection_Code sets func->module for a local function)
    Module_AddFunction(rt, 0, 0u, M3ImportInfo(), false)
    rt.functions[0].moduleIdx = 0
    rt.functions[0].names[0] = "fib"
    rt.functions[0].numNames = u16(1)
    return <- rt
}


// C CompileFunction reads the body size first, then the locals, then the
// code; `body` holds exactly what follows the size byte. Eden: the module's
// `wasm` array is the body, the function's range is all of it.
def private compile_body(var rt : M3Runtime; f : IM3Function; body : array<u8>) : M3Result {
    clear(rt.modules[0].wasm)
    push(rt.modules[0].wasm, u8(length(body)))
    for (b in body) {
        push(rt.modules[0].wasm, b)
    }
    rt.functions[f].wasm = 0
    rt.functions[f].wasmEnd = length(rt.modules[0].wasm)
    rt.functions[f].compiled = -1
    return CompileFunction(rt, f)
}


// Calls the (i32) -> i32 function; returns the trap, or m3Err_none with the value in `out`.
// The compiler's frame (C: c_ioSlotCount = sizeof (u64) / sizeof (m3slot_t) = 2):
// every return and argument value occupies a pair of 32-bit slots, so the
// result is slot 0 (pair 0..1) and the argument slot 2 (pair 2..3).
def private call_i32(var rt : M3Runtime; f : IM3Function; n : int; var out : int&) : M3Result {
    for (i in range(length(rt.stack))) {
        rt.stack[i] = 0xfffffffffffffffful
    }
    set_stack_i32(rt, 2, n)
    rt.trap = m3Err_none
    rt.pc = rt.functions[f].compiled
    rt.sp = 0
    let r = RunCode(rt)
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


// a compilation state for the slot tests: `firstDynamic` reserved slots
// (ret + args), an empty dynamic stack, no page
def private slot_state(var rt : M3Runtime; firstDynamic : int) {
    rt.compilation <- M3Compilation()
    rt.compilation.runtime = 0
    rt.compilation.slotFirstDynamicIndex = firstDynamic
    rt.compilation.slotMaxAllocatedIndexPlusOne = firstDynamic
    rt.compilation.slotFirstConstIndex = firstDynamic
    rt.compilation.slotMaxConstIndex = firstDynamic
    rt.compilation.maxStackSlots = firstDynamic
    rt.compilation.stackFirstDynamicIndex = 0
    rt.compilation._block.blockStackIndex = 0
    for (i in range(firstDynamic)) {
        rt.compilation.m3Slots[i] = 1
    }
}


// a compilation state with a fresh code page (the emit tests)
def private page_state(var rt : M3Runtime) : M3Result {
    slot_state(rt, 2)
    return AcquireCompilationCodePage(rt, rt.compilation.page)
}


// ============================================================================
// Upstream: test_compile_negative_i32_constants_keep_the_c_slot_behaviour
// ============================================================================


def test_compile_negative_i32_constants_keep_the_c_slot_behaviour(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(64)
    let f : IM3Function = 0

    // i32.const -1; drop; i32.const -1; drop; local.get 0; end
    // C promotes the i32 -1 to the u64 PushConst parameter by sign extension,
    // so the constant-slot search never matches it against the stored u32:
    // two slots, numConstantBytes = 2 * sizeof (m3slot_t).
    var negative <- [u8(0x00), u8(0x41), u8(0x7f), u8(0x1a), u8(0x41), u8(0x7f), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, negative), m3Err_none, "compile negative constants")
    equal(t, int(rt.functions[f].numConstantBytes), 8, "two constant slots for two -1 (C quirk)")
    // Eden: one word per slot, length == numConstantBytes / 4, the low 32 bits hold the constant
    equal(t, length(rt.functions[f].constants), 2, "two constant words for two -1")
    equal(t, rt.functions[f].constants[0], 0xfffffffful, "constant word 0 is the zero-extended -1")
    equal(t, rt.functions[f].constants[1], 0xfffffffful, "constant word 1 is the zero-extended -1")
    expect_value(t, rt, f, 7, 7, "negative constants body returns its argument")

    // i32.const 1 twice: the search matches and the slot is shared.
    var positive <- [u8(0x00), u8(0x41), u8(0x01), u8(0x1a), u8(0x41), u8(0x01), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, positive), m3Err_none, "compile positive constants")
    equal(t, int(rt.functions[f].numConstantBytes), 4, "one constant slot for two 1")
    equal(t, length(rt.functions[f].constants), 1, "one constant word for two 1")
    equal(t, rt.functions[f].constants[0], 1ul, "the constant word is 1")
    expect_value(t, rt, f, -5, -5, "positive constants body returns its argument")
}


// ============================================================================
// Upstream: test_compile_stack_top_after_unreachable
// ============================================================================


// C CopyStackTopToSlot narrows the i16 GetStackTopIndex result to u16:
// `CopyStackIndexToSlot (o, i_destSlot, (u16) stackTop)`. On a polymorphic
// stack the top index is -1 and the cast makes it 65535, so every index helper
// reads it as out of range. Both bodies below reach that path; without the
// narrowing the port indexed typeStack[-1] and aborted the compilation.
def test_compile_stack_top_after_unreachable(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(64)
    let f : IM3Function = 0

    // unreachable; local.set 0; local.get 0; end -> Compile_SetLocal takes the
    // CopyStackTopToSlot branch (the local is not referenced in this block).
    var setLocal <- [u8(0x00), u8(0x00), u8(0x21), u8(0x00), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, setLocal), m3Err_none, "local.set after unreachable")

    // unreachable; call 0; end -> the argument copy in CompileCallArgsAndReturn.
    var call <- [u8(0x00), u8(0x00), u8(0x10), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, call), m3Err_none, "call after unreachable")
}


// ============================================================================
// Upstream: test_compile_rejects_reserved_and_unknown_opcodes
// ============================================================================


def test_compile_rejects_reserved_and_unknown_opcodes(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(64)
    let f : IM3Function = 0

    // Each body first pushes local 0 so the dynamic stack is not empty when the
    // bad opcode is compiled (the port's d_m3Assert is always on, unlike C's).

    // 0x06 is a reserved row: GetOpInfo finds it, no compiler, Compile_Operator
    // finds no operation. C: ErrorCompile ("no operation found for opcode", ...).
    var reserved <- [u8(0x00), u8(0x20), u8(0x00), u8(0x06), u8(0x0b)]
    equal_str(t, compile_body(rt, f, reserved), "no operation found for opcode", "reserved 0x06")
    equal_str(t, rt.error.result, "no operation found for opcode", "ErrorCompile recorded the result")
    equal_str(t, rt.error.message, "6", "ErrorCompile recorded the opcode")
    equal(t, rt.error.moduleIdx, 0, "ErrorCompile recorded the module")

    // 0xc5 is one of the DEBUG-only rows in C and must behave like 0x06.
    var debugOnly <- [u8(0x00), u8(0x20), u8(0x00), u8(0xc5), u8(0x0b)]
    equal_str(t, compile_body(rt, f, debugOnly), "no operation found for opcode", "DEBUG-only 0xc5")

    // 0xfd is past the table: GetOpInfo returns NULL. C: m3Err_unknownOpcode.
    var unknown <- [u8(0x00), u8(0x20), u8(0x00), u8(0xfd), u8(0x0b)]
    equal_str(t, compile_body(rt, f, unknown), m3Err_unknownOpcode, "unknown 0xfd")
    equal_str(t, rt.error.message, "opcode 'fd' not available", "ErrorCompile message of the unknown opcode")
}


// ============================================================================
// Eden: the slot and type-stack accounting
// ============================================================================


def test_slot_and_type_stack(var t : TestRun; fx : FixtureSource) {
    var rt = M3Runtime()
    slot_state(rt, 2)   // slots 0 and 1 are the ret and the arg
    let i32Type = int(u8(M3ValueType.c_m3Type_i32))
    let i64Type = int(u8(M3ValueType.c_m3Type_i64))
    let f64Type = int(u8(M3ValueType.c_m3Type_f64))

    // the slot predicates
    check(t, IsRegisterSlotAlias(d_m3Reg0SlotAlias), "d_m3Reg0SlotAlias is a register alias")
    check(t, IsIntRegisterSlotAlias(d_m3Reg0SlotAlias), "d_m3Reg0SlotAlias is the int register")
    check(t, IsFpRegisterSlotAlias(d_m3Fp0SlotAlias), "d_m3Fp0SlotAlias is the fp register")
    check(t, !IsRegisterSlotAlias(c_slotUnused), "c_slotUnused is not a register alias")
    check(t, !IsRegisterSlotAlias(3), "slot 3 is not a register alias")
    check(t, IsValidSlot(int(d_m3MaxFunctionSlots) - 1), "the last slot is valid")
    check(t, !IsValidSlot(c_slotUnused), "c_slotUnused is not a valid slot")
    equal(t, GetTypeNumSlots(i32Type), 1, "an i32 takes one slot")
    equal(t, GetTypeNumSlots(i64Type), 2, "an i64 takes two slots (d_m3Use32BitSlots)")
    equal(t, GetTypeNumSlots(f64Type), 2, "an f64 takes two slots")
    var aligned = 3
    AlignSlotToType(aligned, i64Type)
    equal(t, aligned, 4, "AlignSlotToType rounds an i64 slot up to even")
    aligned = 3
    AlignSlotToType(aligned, i32Type)
    equal(t, aligned, 3, "AlignSlotToType leaves an i32 slot")

    // allocation: the first free slot, then an aligned pair
    var slotA = c_slotUnused
    equal_str(t, AllocateSlots(rt, slotA, i32Type), m3Err_none, "AllocateSlots i32")
    equal(t, slotA, 2, "the first dynamic slot")
    check(t, IsSlotAllocated(rt, 2), "slot 2 allocated")
    equal(t, rt.compilation.maxStackSlots, 3, "maxStackSlots touched")
    var slotB = c_slotUnused
    equal_str(t, AllocateSlots(rt, slotB, i64Type), m3Err_none, "AllocateSlots i64")
    equal(t, slotB, 4, "the i64 pair is aligned past slot 3")
    check(t, IsSlotAllocated(rt, 4) && IsSlotAllocated(rt, 5), "slots 4 and 5 allocated")
    check(t, !IsSlotAllocated(rt, 3), "slot 3 stays free")
    equal(t, rt.compilation.slotMaxAllocatedIndexPlusOne, 6, "slotMaxAllocatedIndexPlusOne")
    equal(t, GetMaxUsedSlotPlusOne(rt), 6, "GetMaxUsedSlotPlusOne with slots in use")

    // the type stack
    equal_str(t, Push(rt, i32Type, slotA), m3Err_none, "Push i32 in slot 2")
    equal_str(t, Push(rt, i64Type, slotB), m3Err_none, "Push i64 in slot 4")
    equal(t, rt.compilation.stackIndex, 2, "two values on the stack")
    equal(t, GetStackTopIndex(rt), 1, "GetStackTopIndex")
    equal(t, GetStackTopType(rt), i64Type, "GetStackTopType")
    equal(t, GetStackTypeFromTop(rt, 1), i32Type, "GetStackTypeFromTop(1)")
    equal(t, GetStackTypeFromBottom(rt, 0), i32Type, "GetStackTypeFromBottom(0)")
    equal(t, GetStackTypeFromBottom(rt, 5), int(u8(M3ValueType.c_m3Type_none)), "GetStackTypeFromBottom past the top is none")
    equal(t, GetStackTopSlotNumber(rt), 4, "GetStackTopSlotNumber")
    equal(t, GetSlotForStackIndex(rt, 0), 2, "GetSlotForStackIndex(0)")
    equal(t, GetExtraSlotForStackIndex(rt, 1), 5, "GetExtraSlotForStackIndex of the i64")
    check(t, IsStackTopInSlot(rt), "the top is in a slot")
    equal(t, GetNumBlockValuesOnStack(rt), 2, "GetNumBlockValuesOnStack")

    // the registers
    check(t, !IsRegisterAllocated(rt, 0u), "r0 free")
    equal_str(t, PushRegister(rt, i32Type), m3Err_none, "PushRegister i32")
    check(t, IsRegisterAllocated(rt, 0u), "r0 allocated")
    check(t, !IsRegisterAllocated(rt, 1u), "fp0 free")
    check(t, IsRegisterTypeAllocated(rt, i32Type), "IsRegisterTypeAllocated i32")
    check(t, !IsRegisterTypeAllocated(rt, f64Type), "IsRegisterTypeAllocated f64")
    equal(t, GetRegisterStackIndex(rt, 0u), 2, "the register holds stack index 2")
    check(t, IsStackTopInRegister(rt), "the top is in the register")
    check(t, !IsStackTopMinus1InRegister(rt), "top - 1 is in a slot")
    equal(t, GetStackTopSlotNumber(rt), d_m3Reg0SlotAlias, "the top slot number is the register alias")
    equal_str(t, PushRegister(rt, f64Type), m3Err_none, "PushRegister f64")
    check(t, IsRegisterAllocated(rt, 1u), "fp0 allocated")
    equal(t, rt.compilation.wasmStack[3], d_m3Fp0SlotAlias, "the f64 sits in the fp register alias")

    // pops free the registers, then the slots
    equal_str(t, PopType(rt, i32Type), m3Err_typeMismatch, "PopType with the wrong type")
    equal_str(t, PopType(rt, f64Type), m3Err_none, "PopType f64")
    check(t, !IsRegisterAllocated(rt, 1u), "fp0 freed by the pop")
    equal_str(t, Pop(rt), m3Err_none, "Pop the register value")
    check(t, !IsRegisterAllocated(rt, 0u), "r0 freed by the pop")
    equal_str(t, Pop(rt), m3Err_none, "Pop the i64")
    check(t, !IsSlotAllocated(rt, 4) && !IsSlotAllocated(rt, 5), "slots 4 and 5 freed")
    equal(t, GetMaxUsedSlotPlusOne(rt), 3, "GetMaxUsedSlotPlusOne shrinks to the i32")
    equal_str(t, Pop(rt), m3Err_none, "Pop the i32")
    check(t, !IsSlotAllocated(rt, 2), "slot 2 freed")
    equal(t, GetMaxUsedSlotPlusOne(rt), 2, "GetMaxUsedSlotPlusOne back to the first dynamic slot")
    equal(t, rt.compilation.stackIndex, 0, "the stack is empty")
    equal_str(t, Pop(rt), m3Err_functionStackUnderrun, "Pop on an empty stack underruns")

    // usage counts and the shared-slot path
    equal_str(t, AllocateSlots(rt, slotA, i32Type), m3Err_none, "AllocateSlots again")
    equal_str(t, IncrementSlotUsageCount(rt, slotA), m3Err_none, "IncrementSlotUsageCount")
    equal(t, rt.compilation.m3Slots[slotA], 2, "usage count 2")
    DeallocateSlot(rt, slotA, i32Type)
    check(t, IsSlotAllocated(rt, slotA), "one use left")
    DeallocateSlot(rt, slotA, i32Type)
    check(t, !IsSlotAllocated(rt, slotA), "freed after the second deallocation")

    // the limits
    equal_str(t, MarkSlotsAllocated(rt, int(d_m3MaxFunctionSlots) - 1, 2), m3Err_functionStackOverflow, "MarkSlotsAllocated past the last slot")
    var noSlot = c_slotUnused
    equal_str(t, AllocateSlotsWithinRange(rt, noSlot, i32Type, 10, 10), m3Err_functionStackOverflow, "AllocateSlotsWithinRange with an empty range")
    equal(t, noSlot, c_slotUnused, "no slot written")
    rt.compilation.stackIndex = int(d_m3MaxFunctionStackHeight)
    equal_str(t, Push(rt, i32Type, 2), m3Err_functionStackOverflow, "Push past d_m3MaxFunctionStackHeight")
    rt.compilation.stackIndex = 0

    // the polymorphic stack: unwinds, then pops freely, the top index is -1
    equal_str(t, AllocateSlots(rt, slotA, i32Type), m3Err_none, "AllocateSlots before the unwind")
    equal_str(t, Push(rt, i32Type, slotA), m3Err_none, "Push before the unwind")
    equal_str(t, PushRegister(rt, i32Type), m3Err_none, "PushRegister before the unwind")
    check(t, !IsStackPolymorphic(rt), "not polymorphic yet")
    equal_str(t, SetStackPolymorphic(rt), m3Err_none, "SetStackPolymorphic")
    check(t, IsStackPolymorphic(rt), "polymorphic")
    equal(t, rt.compilation.stackIndex, 0, "the block stack was unwound")
    check(t, !IsRegisterAllocated(rt, 0u), "the unwind freed the register")
    equal_str(t, Pop(rt), m3Err_none, "Pop on a polymorphic stack succeeds")
    equal_str(t, PopType(rt, f64Type), m3Err_none, "PopType of anything on a polymorphic stack")
    equal(t, GetStackTopIndex(rt), -1, "GetStackTopIndex is -1 on the empty polymorphic stack")
    equal(t, GetStackTopSlotNumber(rt), c_slotUnused, "GetStackTopSlotNumber is c_slotUnused")
    check(t, !IsStackTopInRegister(rt), "IsStackTopInRegister is false on the empty polymorphic stack")
    equal(t, GetStackTopType(rt), int(u8(M3ValueType.c_m3Type_none)), "GetStackTopType is none")
    equal(t, GetStackTopIndex(rt) & int(0xffff), int(0xffff), "the (u16) stackTop narrowing of CopyStackTopToSlot")
}


// ============================================================================
// Eden: the emitted words
// ============================================================================


def test_emit_words(var t : TestRun; fx : FixtureSource) {
    m3_build_op_table()
    var rt = M3Runtime()
    equal_str(t, page_state(rt), m3Err_none, "AcquireCompilationCodePage")
    check(t, rt.compilation.page != -1, "a page was acquired")
    let page = rt.compilation.page

    // an operation by name and by index
    let pc0 = GetPC(rt)
    equal(t, pc0, GetPagePC(rt, page), "GetPC is the page's pc")
    equal_str(t, EmitOp(rt, "op_Return"), m3Err_none, "EmitOp by name")
    equal(t, rt.code[pc0], m3_OpWord("op_Return"), "the op word by name")
    let constIdx = int(m3_OpWord("op_Const32"))
    equal_str(t, EmitOp(rt, constIdx), m3Err_none, "EmitOp by index")
    equal(t, rt.code[pc0 + 1], u64(constIdx), "the op word by index")
    check(t, !IsNoOp(constIdx), "a resolved index is not the null operation")
    check(t, IsNoOp(c_opNull), "c_opNull is the null operation")

    // the immediates of DESIGN.md 4.4
    EmitConstant32(rt, 42u)
    equal(t, rt.code[pc0 + 2], 42ul, "EmitConstant32 writes the zero-extended u32")
    EmitSlotOffset(rt, -1)
    equal(t, i32(u32(rt.code[pc0 + 3])), -1, "EmitSlotOffset writes the i32 offset as immediate_slot reads it")
    let ptrPC = EmitPointer(rt, 7)
    equal(t, ptrPC, pc0 + 4, "EmitPointer returns the pc of its word")
    equal(t, int(rt.code[ptrPC]), 7, "EmitPointer writes the handle")
    let nullPC = EmitPointer(rt, -1)
    equal(t, int(rt.code[nullPC]), -1, "a null handle round-trips through the word")
    let reserved = ReservePointer(rt)
    equal(t, reserved, pc0 + 6, "ReservePointer returns the pc of the reserved word")
    equal(t, int(rt.code[reserved]), -1, "the reserved word is a null pc")
    rt.code[reserved] = u64(GetPC(rt))
    equal(t, int(rt.code[reserved]), pc0 + 7, "the reserved word patched to the next pc")
    equal(t, GetPC(rt), pc0 + 7, "seven words emitted")

    // the null operation: asserted on a regular stack, op_NoOp on a polymorphic one
    var asserted = false
    try {
        EmitOp(rt, c_opNull)
    } recover {
        asserted = true
    }
    check(t, asserted, "EmitOp of the null operation asserts on a regular stack")
    equal(t, GetPC(rt), pc0 + 7, "nothing emitted by the asserted EmitOp")
    rt.compilation._block.isPolymorphic = true
    equal_str(t, EmitOp(rt, c_opNull), m3Err_none, "EmitOp of the null operation on a polymorphic stack")
    equal(t, rt.code[pc0 + 7], m3_OpWord("op_NoOp"), "the null operation emits op_NoOp")
    equal_str(t, EmitOp(rt, ""), m3Err_none, "EmitOp of the null name on a polymorphic stack")
    equal(t, rt.code[pc0 + 8], m3_OpWord("op_NoOp"), "the null name emits op_NoOp")
    rt.compilation._block.isPolymorphic = false

    // no page: nothing is emitted, the results stay m3Err_none
    let codeLength = length(rt.code)
    rt.compilation.page = -1
    equal_str(t, EmitOp(rt, "op_Return"), m3Err_none, "EmitOp without a page")
    EmitConstant32(rt, 1u)
    EmitSlotOffset(rt, 1)
    equal(t, EmitPointer(rt, 1), -1, "EmitPointer without a page returns -1")
    equal(t, ReservePointer(rt), -1, "ReservePointer without a page returns -1")
    equal(t, length(rt.code), codeLength, "no word written without a page")
    equal(t, int(rt.codePages[page].info.lineIndex), 9, "the page's lineIndex unchanged")
    rt.compilation.page = page

    // the page bridge: the last free lines get op_Branch + the pc of a new page
    while (NumFreeLines(rt, page) > 8u) {
        EmitWord(rt, page, 0ul)
    }
    equal_str(t, EmitOp(rt, "op_Return"), m3Err_none, "EmitOp with exactly threshold + 2 free lines")
    equal(t, rt.compilation.page, page, "no bridge yet")
    EmitWord(rt, page, 0ul)
    let bridgePC = GetPagePC(rt, page)
    equal_str(t, EmitOp(rt, "op_Return"), m3Err_none, "EmitOp below the threshold bridges")
    check(t, rt.compilation.page != page, "a new page is current")
    equal(t, rt.code[bridgePC], m3_OpWord("op_Branch"), "the bridge is op_Branch")
    equal(t, int(rt.code[bridgePC + 1]), GetPagePC(rt, rt.compilation.page) - 1, "the bridge target is the new page's first word")
    equal(t, rt.code[GetPC(rt) - 1], m3_OpWord("op_Return"), "the operation landed on the new page")
    equal(t, rt.pagesFull, page, "the old page was released to the full list")
    ReleaseCompilationCodePage(rt)
}


// ============================================================================
// Eden: patch chains and scope handles
// ============================================================================


def test_patch_chain_and_scopes(var t : TestRun; fx : FixtureSource) {
    m3_build_op_table()
    var rt = M3Runtime()
    equal_str(t, page_state(rt), m3Err_none, "AcquireCompilationCodePage")

    // the scope chain: two enclosing scopes on the stack, the current block above them
    var outer = M3CompilationScope()
    outer.depth = 0
    outer.opcode = m3opcode_t(0)
    push(rt.compilation.scopeStack, outer)
    var middle = M3CompilationScope()
    middle.outer = 0
    middle.depth = 1
    middle.opcode = c_waOp_block
    push(rt.compilation.scopeStack, middle)
    rt.compilation._block.outer = 1
    rt.compilation._block.depth = 2
    rt.compilation._block.opcode = c_waOp_loop

    var scope = -1
    equal_str(t, GetBlockScope(rt, scope, 0u), m3Err_none, "GetBlockScope depth 0")
    equal(t, scope, 2, "depth 0 is the current block (one past the stack)")
    equal_str(t, GetBlockScope(rt, scope, 1u), m3Err_none, "GetBlockScope depth 1")
    equal(t, scope, 1, "depth 1 is the middle scope")
    equal_str(t, GetBlockScope(rt, scope, 2u), m3Err_none, "GetBlockScope depth 2")
    equal(t, scope, 0, "depth 2 is the function scope")
    equal_str(t, GetBlockScope(rt, scope, 3u), "invalid block depth", "GetBlockScope past the function scope")

    // a patch chain on the current block, threaded through the code words
    let pc0 = GetPC(rt)
    equal(t, rt.compilation._block.patches, -1, "no patches yet")
    equal_str(t, EmitPatchingBranch(rt, 2), m3Err_none, "EmitPatchingBranch 1")
    equal(t, rt.code[pc0], m3_OpWord("op_Branch"), "the first branch")
    equal(t, int(rt.code[pc0 + 1]), -1, "the first patch word ends the chain")
    equal(t, rt.compilation._block.patches, pc0 + 1, "the chain head is the first patch word")
    equal_str(t, EmitPatchingBranch(rt, 2), m3Err_none, "EmitPatchingBranch 2")
    equal(t, int(rt.code[pc0 + 3]), pc0 + 1, "the second patch word links to the first")
    equal(t, rt.compilation._block.patches, pc0 + 3, "the chain head is the second patch word")
    EmitConstant32(rt, 99u)   // a word between the branches and the target
    let target = GetPC(rt)
    PatchBranches(rt)
    equal(t, int(rt.code[pc0 + 1]), target, "the first branch patched to the block end")
    equal(t, int(rt.code[pc0 + 3]), target, "the second branch patched to the block end")
    equal(t, rt.compilation._block.patches, -1, "the chain is reset")
    equal(t, rt.code[pc0 + 4], 99ul, "the word between is untouched")

    // a patch on an enclosing scope goes to the scope stack
    EmitPatchingBranchPointer(rt, 1)
    equal(t, rt.compilation.scopeStack[1].patches, target, "the middle scope's chain head is the new word")
    equal(t, int(rt.code[target]), -1, "the new word ends the middle scope's chain")
    EmitPatchingBranchPointer(rt, 0)
    equal(t, rt.compilation.scopeStack[0].patches, target + 1, "the function scope's chain head")
    equal(t, rt.compilation._block.patches, -1, "the current block's chain untouched")
    ReleaseCompilationCodePage(rt)
}


// ============================================================================
// Eden: CompileFunction on trivial bodies, then run
// ============================================================================


def test_compile_function_trivial_bodies(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(64)
    let f : IM3Function = 0

    // i32.const 42; end -> the constant sits in a constant slot, `end` copies it to the return slot
    var const42 <- [u8(0x00), u8(0x41), u8(0x2a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, const42), m3Err_none, "compile i32.const 42; end")
    let pc = rt.functions[f].compiled
    check(t, pc != -1, "the function is compiled")
    equal(t, rt.code[pc], m3_OpWord("op_Entry"), "the first word is op_Entry")
    equal(t, int(rt.code[pc + 1]), f, "the second word is the function handle")
    equal(t, rt.code[pc + 2], m3_OpWord("op_CopySlot_32"), "the return copies the constant slot")
    equal(t, int(rt.code[pc + 3]), 0, "into the return slot")
    equal(t, int(rt.code[pc + 4]), 4, "from constant slot 4 (after the ret and arg pairs)")
    equal(t, rt.code[pc + 5], m3_OpWord("op_Return"), "then op_Return")
    equal(t, int(rt.functions[f].numRetSlots), 2, "numRetSlots (one value, c_ioSlotCount slots)")
    equal(t, int(rt.functions[f].numRetAndArgSlots), 4, "numRetAndArgSlots")
    equal(t, int(rt.functions[f].numLocals), 0, "numLocals")
    equal(t, int(rt.functions[f].numLocalBytes), 0, "numLocalBytes")
    equal(t, int(rt.functions[f].numConstantBytes), 4, "one constant slot")
    equal(t, length(rt.functions[f].constants), 1, "one constant word")
    equal(t, rt.functions[f].constants[0], 42ul, "the constant word")
    // ReserveConstants aligns the one constant slot to an i64 pair, so the
    // first dynamic slot (the initial maxStackSlots) is 4 + 2
    equal(t, int(rt.functions[f].maxStackSlots), 6, "maxStackSlots covers the aligned constant area")
    expect_value(t, rt, f, 0, 42, "i32.const 42")
    equal(t, rt.numActiveCodePages, 0u, "no active code page after the compile")

    // local.get 0; end -> the argument is the result
    var getLocal <- [u8(0x00), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, getLocal), m3Err_none, "compile local.get 0; end")
    equal(t, int(rt.functions[f].numConstantBytes), 0, "no constants")
    equal(t, length(rt.functions[f].constants), 0, "no constant words")
    expect_value(t, rt, f, 1234, 1234, "local.get 0")
    expect_value(t, rt, f, -1, -1, "local.get 0 negative")

    // local.get 0; i32.const 1; i32.add; end -> Compile_Operator through the table row
    var addOne <- [u8(0x00), u8(0x20), u8(0x00), u8(0x41), u8(0x01), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, addOne), m3Err_none, "compile local.get 0; i32.const 1; i32.add; end")
    let addPC = rt.functions[f].compiled
    equal(t, rt.code[addPC + 2], m3_OpWord("op_i32_Add_ss"), "both operands in slots: the _ss form")
    equal(t, rt.code[addPC + 5], m3_OpWord("op_SetSlot_i32"), "the register result is stored to the return slot")
    expect_value(t, rt, f, 41, 42, "n + 1")
    expect_value(t, rt, f, -1, 0, "n + 1 wraps")

    // a local: (local i32) local.get 1; end -> zeroed by op_Entry
    var withLocal <- [u8(0x01), u8(0x01), u8(0x7f), u8(0x20), u8(0x01), u8(0x0b)]
    equal_str(t, compile_body(rt, f, withLocal), m3Err_none, "compile (local i32) local.get 1; end")
    equal(t, int(rt.functions[f].numLocals), 1, "one local")
    equal(t, int(rt.functions[f].numLocalBytes), 4, "numLocalBytes of one i32 local")
    expect_value(t, rt, f, 9, 0, "a fresh local is zero")

    // unreachable; end -> compiles, traps when run
    var trap <- [u8(0x00), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, trap), m3Err_none, "compile unreachable; end")
    var out = 0
    equal_str(t, call_i32(rt, f, 0, out), m3Err_trapUnreachable, "unreachable traps")

    // the failures
    var endOnly <- [u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, endOnly), m3Err_typeCountMismatch, "end alone on an (i32) -> i32 function")
    equal(t, rt.functions[f].compiled, -1, "not compiled after the failure")
    equal(t, rt.numActiveCodePages, 0u, "the page was released after the failure")
    var noEnd <- [u8(0x00), u8(0x41), u8(0x2a)]
    equal_str(t, compile_body(rt, f, noEnd), m3Err_wasmMalformed, "a body without end")
    rt.functions[f].wasm = -1
    equal_str(t, CompileFunction(rt, f), "function body is missing", "a function without a body")
}


// ============================================================================
// Eden: CompileRawFunction
// ============================================================================


def test_compile_raw_function(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(16)
    Module_AddFunction(rt, 0, 0u, M3ImportInfo(moduleUtf8 = "env", fieldUtf8 = "host"), true)
    let f : IM3Function = 1
    equal(t, rt.functions[f].moduleIdx, -1, "an import has no module until it is linked")
    equal_str(t, CompileRawFunction(rt, 0, f, 3, 9), m3Err_none, "CompileRawFunction")
    equal(t, rt.functions[f].moduleIdx, 0, "the link sets the module")
    let pc = rt.functions[f].compiled
    check(t, pc != -1, "the import is compiled")
    equal(t, rt.code[pc], m3_OpWord("op_CallRawFunction"), "op_CallRawFunction")
    equal(t, int(rt.code[pc + 1]), 3, "the raw-call handle")
    equal(t, int(rt.code[pc + 2]), f, "the function handle")
    equal(t, int(rt.code[pc + 3]), 9, "the userdata token")
    equal(t, rt.numActiveCodePages, 0u, "the page was released")
}


// ============================================================================
// The runner
// ============================================================================


def public run_tests_m3_compile(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_compile_negative_i32_constants_keep_the_c_slot_behaviour")
    test_compile_negative_i32_constants_keep_the_c_slot_behaviour(t, fx)
    begin_test(t, "test_compile_stack_top_after_unreachable")
    test_compile_stack_top_after_unreachable(t, fx)
    begin_test(t, "test_compile_rejects_reserved_and_unknown_opcodes")
    test_compile_rejects_reserved_and_unknown_opcodes(t, fx)
    begin_test(t, "test_slot_and_type_stack")
    test_slot_and_type_stack(t, fx)
    begin_test(t, "test_emit_words")
    test_emit_words(t, fx)
    begin_test(t, "test_patch_chain_and_scopes")
    test_patch_chain_and_scopes(t, fx)
    begin_test(t, "test_compile_function_trivial_bodies")
    test_compile_function_trivial_bodies(t, fx)
    begin_test(t, "test_compile_raw_function")
    test_compile_raw_function(t, fx)
}
