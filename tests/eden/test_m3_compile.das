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
    .upstream/tests/integration/test_m3_compile.das.

    The upstream tests load fib32.wasm through m3_ParseModule / m3_LoadModule
    (m3_env, m3_parse: later modules) to get a loaded module whose only
    function has the type (i32) -> i32, replace its body with hand-written
    bytes and compile them. Eden: the fixture builds that module by hand in
    the runtime's arenas (a func type interned with AllocFuncType, the
    block-result func types of m3_NewEnvironment in
    rt.environment.retFuncTypes, a module slot with `runtime = 0`, a
    function added with Module_AddFunction whose body is the module's `wasm`
    array), so the same bodies compile through the same CompileFunction; the
    compiled code is then run through RunCode (m3_Call's entry, as
    tests/eden/test_m3_exec.das does) to check the values the compiler's
    words produce. The operation tables come from m3_build_operations_table.

    Coverage of the upstream [test]s (4 of 4 ported):
      - test_operation_table_after_new_environment: m3_build_operations_table
        stands in for the table fill of m3_NewEnvironment (m3_env, a later
        module); every assertion is kept (no null compiler, i32.lt_u routes
        to Compile_Operator with a register form, call has Compile_Call,
        0xfd and 0xfc0c have no row, a second build leaves the table intact,
        0xc5 / 0xfb empty, 0xfc dispatches), plus the row counts and the
        op table being built by the builder when it is empty.
      - test_compile_negative_i32_constants_keep_the_c_slot_behaviour: the
        same two bodies and the same numConstantBytes checks (8 for two
        i32.const -1, 4 for two i32.const 1), plus the Eden shape of the
        constant table (one word per slot, length == numConstantBytes / 4)
        and the compiled function run; the Eden-only
        test_compile_constant_table_keeps_the_c_32bit_slots (below) checks
        the table against C's 32-bit slots with mixed i32 / i64 constants.
      - test_compile_stack_top_after_unreachable: the same two bodies.
      - test_compile_rejects_reserved_and_unknown_opcodes: the same three
        bodies and error strings (0x06 reserved, 0xc5 DEBUG-only, 0xfd past
        the table).
    Tests added for the Eden shape (no upstream counterpart):
      - test_operation_tables_resolve: both tables walked row by row: every
        non-empty op name resolved to an index below m3_OpCount whose
        m3_OpWord(name) round-trips, every empty name c_opNull, a compiler
        on exactly the rows where C has one (72 + 10), the reserved rows
        empty, and the names / rows counted;
      - test_compile_and_run_opcodes: bodies compiled through the full
        table and run: `i32.const 7; i32.const 5; i32.add` (12), a
        `block (result i32) / br_if / end`, `local.set` / `local.get` on a
        declared local, `i32.load` with an offset from a one-page memory
        (and its out-of-bounds trap), `call` of a second function, and
        `select`;
      - test_compile_constant_table_keeps_the_c_32bit_slots: the
        verifier's three mixed i32 / i64 bodies (numConstantBytes 8, 12, 16
        as C, the constant words), the same layouts with the constants used
        by the result, and a pair of i32 constants reused by an i64 (8
        bytes, the runtime word holds the i64);
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
// Helpers: the fixture module
// ============================================================================


// a runtime with the op table and the operation tables built, `slots` stack
// words, the block-result func types of m3_NewEnvironment, one module
// (handle 0, linked: runtime = 0) with one interned func type (i32) -> i32
// and one function of that type (handle 0) whose body the tests write with
// compile_body
def private compile_runtime(slots : int) : M3Runtime {
    m3_build_op_table()
    m3_build_operations_table()
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

    // C m3_NewEnvironment: a func type for every simple block result type
    // (none .. f64) in environment->retFuncTypes, read by ReadBlockType
    for (t in range(int(u8(M3ValueType.c_m3Type_none)), int(u8(M3ValueType.c_m3Type_f64)) + 1)) {
        var ftype : IM3FuncType = -1
        AllocFuncType(rt, ftype, 1u)
        rt.funcTypes[ftype].numArgs = u16(0)
        rt.funcTypes[ftype].numRets = u16(t == int(u8(M3ValueType.c_m3Type_none)) ? 0 : 1)
        rt.funcTypes[ftype].types[0] = u8(t)
        rt.environment.retFuncTypes[t] = ftype
    }

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
// Upstream: test_operation_table_after_new_environment
// ============================================================================


def private null_compiler_count() : int {
    var count = 0
    for (i in range(253)) {
        if (c_operations[i].compiler == null) {
            count++
        }
    }
    return count
}


// Upstream: m3_NewEnvironment fills the table (init_compile_operation_tables)
// and the test checks the entries it hands out. Eden: the environment is a
// later module; m3_build_operations_table is the table fill, started here
// from an empty op table so the builder builds that too.
def test_operation_table_after_new_environment(var t : TestRun; fx : FixtureSource) {
    clear(g_ops)
    clear(g_opIndex)
    clear(c_operations)
    clear(c_operationsFC)
    var absent = M3OpInfo()
    check(t, !GetOpInfo(m3opcode_t(0x41), absent), "no row before the tables are built")
    m3_build_operations_table()
    check(t, m3_OpCount() > 0, "m3_build_operations_table built the empty op table")
    equal(t, m3_OpCount(), 515, "the op table has every m3_exec operation (510 + 5 optional fused)")
    equal(t, length(c_operations), 253, "c_operations has C's 253 rows")
    equal(t, length(c_operationsFC), 12, "c_operationsFC has C's 12 rows")

    equal(t, null_compiler_count(), 0, "entries with a null compiler pointer")

    // i32.lt_u (0x49) has no dedicated compiler in C: NULL, so Compile_Operator runs.
    var ltU = M3OpInfo()
    let hasLtU = GetOpInfo(m3opcode_t(0x49), ltU)
    check(t, hasLtU, "GetOpInfo i32.lt_u")
    if (hasLtU) {
        check(t, IsNoCompiler(ltU.compiler), "i32.lt_u routes to Compile_Operator")
        check(t, !IsNoOp(ltU.operations[0]), "i32.lt_u has a register-form operation")
    }

    // call (0x10) has Compile_Call.
    var callInfo = M3OpInfo()
    let hasCall = GetOpInfo(m3opcode_t(0x10), callInfo)
    check(t, hasCall, "GetOpInfo call")
    if (hasCall) {
        check(t, callInfo.compiler != null && !IsNoCompiler(callInfo.compiler), "call has a dedicated compiler")
    }

    // Opcodes past the table and unknown prefixes yield no entry, as in C.
    var past = M3OpInfo()
    check(t, !GetOpInfo(m3opcode_t(0xfd), past), "0xfd has no opinfo")
    check(t, !GetOpInfo(m3opcode_t(0xfc0c), past), "extended 0x0c has no opinfo")

    // Calling the initialiser again must not disturb the table.
    m3_build_operations_table()
    equal(t, null_compiler_count(), 0, "table intact after a second initialisation")
    equal(t, length(c_operations), 253, "a second build keeps 253 rows (cleared first)")
    equal(t, length(c_operationsFC), 12, "a second build keeps 12 extended rows")
    var ltUAgain = M3OpInfo()
    GetOpInfo(m3opcode_t(0x49), ltUAgain)
    equal(t, ltUAgain.operations[0], ltU.operations[0], "a second build resolves the same index")

    // C: the rows after 0xc4 are DEBUG-only logging entries; the release
    // table is zero-filled up to the 0xfc dispatcher. GetOpInfo hands them
    // out without operations or compiler, exactly like the reserved 0x06.
    var debugRow = M3OpInfo()
    let hasDebugRow = GetOpInfo(m3opcode_t(0xc5), debugRow)
    check(t, hasDebugRow && IsNoCompiler(debugRow.compiler) && IsNoOp(debugRow.operations[0]), "0xc5 is empty like a reserved row")
    var lastGap = M3OpInfo()
    let hasLastGap = GetOpInfo(m3opcode_t(0xfb), lastGap)
    check(t, hasLastGap && IsNoCompiler(lastGap.compiler), "0xfb is empty")
    var extended = M3OpInfo()
    let hasExtended = GetOpInfo(m3opcode_t(0xfc), extended)
    check(t, hasExtended && !IsNoCompiler(extended.compiler), "0xfc dispatches extended opcodes")
}


// ============================================================================
// Eden: both tables walked, every name resolved
// ============================================================================


// the opcodes whose C row names a compiler (wasm3c/source/m3_compile.c);
// every other row has C's NULL (c_noCompiler here)
def private c_compiler_rows() : array<int> {
    var rows : array<int>
    for (op in range(int(0x00), int(0x06))) {
        push(rows, op)                 // unreachable .. else
    }
    for (op in range(int(0x0b), int(0x14))) {
        push(rows, op)                 // end .. return_call_indirect
    }
    push(rows, int(0x1a))              // drop
    push(rows, int(0x1b))              // select
    for (op in range(int(0x20), int(0x25))) {
        push(rows, op)                 // local.get .. global.set
    }
    for (op in range(int(0x28), int(0x45))) {
        push(rows, op)                 // the loads, stores, memory.size / grow, the consts
    }
    for (op in [0xa8, 0xa9, 0xaa, 0xab, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb7, 0xb8, 0xb9, 0xba, 0xbc, 0xbd, 0xbe, 0xbf]) {
        push(rows, int(op))            // Compile_Convert
    }
    push(rows, int(0xfc))              // Compile_ExtendedOpcode
    return <- rows
}


def private c_compiler_rows_fc() : array<int> {
    var rows : array<int>
    for (op in range(int(0x00), int(0x08))) {
        push(rows, op)                 // the saturating truncations
    }
    push(rows, int(0x0a))              // memory.copy
    push(rows, int(0x0b))              // memory.fill
    return <- rows
}


// walks one table; returns the number of resolved names
def private check_table(var t : TestRun; rows : array<M3OpInfo>; withCompiler : array<int>; tableName : string) : int {
    var resolved = 0
    for (row, idx in rows, count()) {
        for (i in range(4)) {
            let name = row.opNames[i]
            if (empty(name)) {
                equal(t, row.operations[i], c_opNull, "{tableName}[{idx}] operation {i} is c_opNull")
            } else {
                let op = row.operations[i]
                check(t, op >= 0 && op < m3_OpCount(), "{tableName}[{idx}] {name} resolved to an op-table index")
                equal(t, m3_OpWord(name), u64(op), "{tableName}[{idx}] {name} round-trips through m3_OpWord")
                resolved++
            }
        }
        let expectCompiler = has_value(withCompiler, idx)
        equal(t, !IsNoCompiler(row.compiler), expectCompiler, "{tableName}[{idx}] has a compiler exactly where C has one")
    }
    return resolved
}


def test_operation_tables_resolve(var t : TestRun; fx : FixtureSource) {
    m3_build_op_table()
    m3_build_operations_table()
    var compilers <- c_compiler_rows()
    var compilersFC <- c_compiler_rows_fc()
    equal(t, length(compilers), 72, "72 rows of c_operations name a compiler in C")
    equal(t, length(compilersFC), 10, "10 rows of c_operationsFC name a compiler in C")
    equal(t, check_table(t, c_operations, compilers, "c_operations"), 416, "op names resolved in c_operations")
    equal(t, check_table(t, c_operationsFC, compilersFC, "c_operationsFC"), 32, "op names resolved in c_operationsFC")

    // the reserved rows (M3OP_RESERVED, C's `{ 0 }`)
    for (op in [0x06, 0x0a, 0x14, 0x19, 0x1c, 0x1f, 0x25, 0x27, 0xc5, 0xe0, 0xfb]) {
        let row = c_operations[int(op)]
        check(t, IsNoCompiler(row.compiler) && IsNoOp(row.operations[0]) && empty(row.opNames[0]), "row {op} is reserved")
        equal(t, row.stackOffset, 0, "row {op} stackOffset")
    }
    check(t, IsNoCompiler(c_operationsFC[0x08].compiler) && IsNoCompiler(c_operationsFC[0x09].compiler), "extended 0x08 / 0x09 are reserved")

    // a few rows field by field against C
    equal(t, c_operations[0x1b].stackOffset, -2, "select stackOffset")
    equal(t, c_operations[0x1b]._type, int(0xff), "select type any")
    check(t, c_operations[0x1b].compiler == @@Compile_Select, "select compiler")
    equal(t, c_operations[0x6a].opNames[0], "op_i32_Add_rs", "i32.add [0]")
    equal(t, c_operations[0x6a].opNames[1], "", "i32.add [1] (commutative: NULL)")
    equal(t, c_operations[0x6a].opNames[2], "op_i32_Add_ss", "i32.add [2]")
    equal(t, c_operations[0x38].opNames[3], "op_f32_Store_f32_rr", "f32.store [3] (d_storeFpOpList)")
    equal(t, c_operations[0x50]._type, int(u8(M3ValueType.c_m3Type_i32)), "i64.eqz yields an i32")
    equal(t, c_operations[0xfc]._type, int(u8(M3ValueType.c_m3Type_unknown)), "0xfc type unknown")
    check(t, c_operations[0xfc].compiler == @@Compile_ExtendedOpcode, "0xfc compiler")
    check(t, c_operationsFC[0x0a].compiler == @@Compile_Memory_CopyFill, "memory.copy compiler")
    equal(t, c_operationsFC[0x07].opNames[3], "op_u64_TruncSat_f64_s_s", "i64.trunc_u:sat/f64 [3]")
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
// Eden: the constant table keeps C's 32-bit slots
// ============================================================================


// C's constant table is an array of 32-bit slots: an i64 constant fills an
// aligned pair (low half, high half), the 64-bit search reads a pair as one
// u64 and the 32-bit search scans every slot, halves of pairs included. The
// first three bodies are the verifier's cases (numConstantBytes as C: 8, 12,
// 16), then the same layouts with the constants used, then a pair of i32
// constants reused as an i64 (C: 8 bytes), whose runtime word must be the i64.
def test_compile_constant_table_keeps_the_c_32bit_slots(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(64)
    let f : IM3Function = 0

    // A: i64.const 0x1_00000000; drop; i32.const 1; drop; local.get 0; end
    // C: the pair holds (0, 1); the i32 search finds 1 in the high half -> 8 bytes
    var a <- [u8(0x00), u8(0x42), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x10), u8(0x1a), u8(0x41), u8(0x01), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, a), m3Err_none, "compile A")
    equal(t, int(rt.functions[f].numConstantBytes), 8, "A: the i32 1 reuses the high half of the i64 (C: 8)")
    equal(t, length(rt.functions[f].constants), 2, "A: two constant words")
    equal(t, rt.functions[f].constants[0], 0x100000000ul, "A: word 0 is the i64")
    equal(t, rt.functions[f].constants[1], 1ul, "A: word 1 is the high half, the i32 1")
    expect_value(t, rt, f, 9, 9, "A returns its argument")

    // B: i64.const 0x1_00000002; drop; i32.const 0; drop; local.get 0; end
    // C: the pair holds (2, 1); no slot holds 0 -> a third slot, 12 bytes
    var b <- [u8(0x00), u8(0x42), u8(0x82), u8(0x80), u8(0x80), u8(0x80), u8(0x10), u8(0x1a), u8(0x41), u8(0x00), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, b), m3Err_none, "compile B")
    equal(t, int(rt.functions[f].numConstantBytes), 12, "B: the i32 0 matches no 32-bit slot (C: 12)")
    equal(t, length(rt.functions[f].constants), 3, "B: three constant words")
    equal(t, rt.functions[f].constants[0], 0x100000002ul, "B: word 0 is the i64")
    equal(t, rt.functions[f].constants[1], 1ul, "B: word 1 is the high half")
    equal(t, rt.functions[f].constants[2], 0ul, "B: word 2 is the i32 0")
    expect_value(t, rt, f, 9, 9, "B returns its argument")

    // C: i32.const 5; drop; i32.const 7; drop; i64.const 5; drop; local.get 0; end
    // C: the 64-bit search reads (5, 7) as 0x0000000700000005 != 5 -> a new pair, 16 bytes
    var c <- [u8(0x00), u8(0x41), u8(0x05), u8(0x1a), u8(0x41), u8(0x07), u8(0x1a), u8(0x42), u8(0x05), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    equal_str(t, compile_body(rt, f, c), m3Err_none, "compile C")
    equal(t, int(rt.functions[f].numConstantBytes), 16, "C: the i64 5 does not match the pair (5, 7) (C: 16)")
    equal(t, length(rt.functions[f].constants), 4, "C: four constant words")
    equal(t, rt.functions[f].constants[0], 5ul, "C: word 0 is the i32 5")
    equal(t, rt.functions[f].constants[1], 7ul, "C: word 1 is the i32 7")
    equal(t, rt.functions[f].constants[2], 5ul, "C: word 2 is the i64 5")
    equal(t, rt.functions[f].constants[3], 0ul, "C: word 3 is its high half")
    expect_value(t, rt, f, 9, 9, "C returns its argument")

    // A used: i64.const 0x1_00000000; local.get 0; i64.extend_i32_u; i64.shr_u;
    // i32.wrap_i64; i32.const 1; i32.add; end -> (0x1_00000000 >> n) + 1
    var aUsed <- [u8(0x00), u8(0x42), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x10), u8(0x20), u8(0x00), u8(0xad), u8(0x88), u8(0xa7), u8(0x41), u8(0x01), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, aUsed), m3Err_none, "compile A used")
    equal(t, int(rt.functions[f].numConstantBytes), 8, "A used: 8 bytes")
    expect_value(t, rt, f, 0, 1, "A used: low half 0, plus the i32 1")
    expect_value(t, rt, f, 32, 2, "A used: high half 1, plus the i32 1")
    expect_value(t, rt, f, 31, 3, "A used: bit 32 shifted to bit 1, plus the i32 1")

    // B used: i64.const 0x1_00000002; local.get 0; i64.extend_i32_u; i64.shr_u;
    // i32.wrap_i64; i32.const 0; i32.add; end -> (0x1_00000002 >> n) + 0
    var bUsed <- [u8(0x00), u8(0x42), u8(0x82), u8(0x80), u8(0x80), u8(0x80), u8(0x10), u8(0x20), u8(0x00), u8(0xad), u8(0x88), u8(0xa7), u8(0x41), u8(0x00), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, bUsed), m3Err_none, "compile B used")
    equal(t, int(rt.functions[f].numConstantBytes), 12, "B used: 12 bytes")
    expect_value(t, rt, f, 0, 2, "B used: low half 2")
    expect_value(t, rt, f, 32, 1, "B used: high half 1")
    expect_value(t, rt, f, 1, int(0x80000001), "B used: 0x1_00000002 >> 1")

    // C used: i32.const 5; i32.const 7; i32.add; i64.const 5; local.get 0;
    // i64.extend_i32_u; i64.shl; i32.wrap_i64; i32.add; end -> 12 + (5 << n)
    var cUsed <- [u8(0x00), u8(0x41), u8(0x05), u8(0x41), u8(0x07), u8(0x6a), u8(0x42), u8(0x05), u8(0x20), u8(0x00), u8(0xad), u8(0x86), u8(0xa7), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, cUsed), m3Err_none, "compile C used")
    equal(t, int(rt.functions[f].numConstantBytes), 16, "C used: 16 bytes")
    expect_value(t, rt, f, 0, 17, "C used: 5 + 7 + 5")
    expect_value(t, rt, f, 2, 32, "C used: 5 + 7 + (5 << 2)")

    // D: i32.const 5; i32.const 7; i32.add; i64.const 0x7_00000005; local.get 0;
    // i64.extend_i32_u; i64.shr_u; i32.wrap_i64; i32.add; end -> 12 + (0x7_00000005 >> n)
    // C: the 64-bit search reads (5, 7) as 0x0000000700000005 and reuses the pair -> 8 bytes
    var d <- [u8(0x00), u8(0x41), u8(0x05), u8(0x41), u8(0x07), u8(0x6a), u8(0x42), u8(0x85), u8(0x80), u8(0x80), u8(0x80), u8(0xf0), u8(0x00), u8(0x20), u8(0x00), u8(0xad), u8(0x88), u8(0xa7), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, d), m3Err_none, "compile D")
    equal(t, int(rt.functions[f].numConstantBytes), 8, "D: the i64 reuses the pair of i32 constants (C: 8)")
    equal(t, length(rt.functions[f].constants), 2, "D: two constant words")
    equal(t, rt.functions[f].constants[0], 0x700000005ul, "D: word 0 is the i64 (its low half the i32 5)")
    equal(t, rt.functions[f].constants[1], 7ul, "D: word 1 is the i32 7, the high half")
    expect_value(t, rt, f, 0, 17, "D: 5 + 7 + low half 5")
    expect_value(t, rt, f, 32, 19, "D: 5 + 7 + high half 7")
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
// Eden: real opcodes through the full table, then run
// ============================================================================


def test_compile_and_run_opcodes(var t : TestRun; fx : FixtureSource) {
    var rt <- compile_runtime(64)
    let f : IM3Function = 0

    // i32.const 7; i32.const 5; i32.add; end -> 12 (Compile_Operator, both constants in slots)
    var add <- [u8(0x00), u8(0x41), u8(0x07), u8(0x41), u8(0x05), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, add), m3Err_none, "compile i32.const 7; i32.const 5; i32.add; end")
    equal(t, rt.code[rt.functions[f].compiled + 2], m3_OpWord("op_i32_Add_ss"), "i32.add of two constant slots is the _ss form")
    expect_value(t, rt, f, 0, 12, "7 + 5")

    // block (result i32) i32.const 100; local.get 0; br_if 0; drop; i32.const 200; end; end
    // -> 100 when the argument is non-zero (the branch leaves the block with 100), else 200
    var brIf <- [u8(0x00), u8(0x02), u8(0x7f), u8(0x41), u8(0xe4), u8(0x00), u8(0x20), u8(0x00), u8(0x0d), u8(0x00), u8(0x1a), u8(0x41), u8(0xc8), u8(0x01), u8(0x0b), u8(0x0b)]
    equal_str(t, compile_body(rt, f, brIf), m3Err_none, "compile block / br_if / end")
    expect_value(t, rt, f, 1, 100, "br_if taken")
    expect_value(t, rt, f, -7, 100, "br_if taken on a negative")
    expect_value(t, rt, f, 0, 200, "br_if not taken")

    // (local i32) local.get 0; i32.const 3; i32.add; local.set 1; local.get 1; local.get 1; i32.mul; end
    // -> (n + 3) * (n + 3)
    var locals <- [u8(0x01), u8(0x01), u8(0x7f), u8(0x20), u8(0x00), u8(0x41), u8(0x03), u8(0x6a), u8(0x21), u8(0x01), u8(0x20), u8(0x01), u8(0x20), u8(0x01), u8(0x6c), u8(0x0b)]
    equal_str(t, compile_body(rt, f, locals), m3Err_none, "compile local.set / local.get")
    expect_value(t, rt, f, 2, 25, "(2 + 3)^2")
    expect_value(t, rt, f, -3, 0, "(-3 + 3)^2")
    expect_value(t, rt, f, 7, 100, "(7 + 3)^2")

    // local.get 0; i32.load align=2 offset=4; end -> the i32 at n + 4 of a one-page memory
    resize(rt.mem, 65536)
    rt.memory.numPages = 1u
    rt.mem[12] = u8(0x78)
    rt.mem[13] = u8(0x56)
    rt.mem[14] = u8(0x34)
    rt.mem[15] = u8(0x12)
    var load <- [u8(0x00), u8(0x20), u8(0x00), u8(0x28), u8(0x02), u8(0x04), u8(0x0b)]
    equal_str(t, compile_body(rt, f, load), m3Err_none, "compile i32.load offset=4")
    expect_value(t, rt, f, 8, int(0x12345678), "i32.load of the little-endian word at 12")
    expect_value(t, rt, f, 0, 0, "i32.load of zeroed memory")
    rt.mem[65535] = u8(0x7f)
    expect_value(t, rt, f, 65528, int(0x7f000000), "i32.load of the last word (65528 + 4)")
    var out = 0
    equal_str(t, call_i32(rt, f, 65529, out), m3Err_trapOutOfBoundsMemoryAccess, "i32.load one byte past the end traps")

    // call: function 1 (i32) -> i32 is local.get 0; i32.const 10; i32.mul; end,
    // function 0 is local.get 0; call 1; i32.const 1; i32.add; end -> n * 10 + 1
    Module_AddFunction(rt, 0, 0u, M3ImportInfo(), false)
    let g : IM3Function = 1
    rt.functions[g].moduleIdx = 0
    rt.functions[g].names[0] = "times10"
    rt.functions[g].numNames = u16(1)
    var callee <- [u8(0x00), u8(0x20), u8(0x00), u8(0x41), u8(0x0a), u8(0x6c), u8(0x0b)]
    equal_str(t, compile_body(rt, g, callee), m3Err_none, "compile the callee")
    expect_value(t, rt, g, 4, 40, "the callee alone")
    var caller <- [u8(0x00), u8(0x20), u8(0x00), u8(0x10), u8(0x01), u8(0x41), u8(0x01), u8(0x6a), u8(0x0b)]
    equal_str(t, compile_body(rt, f, caller), m3Err_none, "compile the caller")
    var sawCall = false
    for (pc in range(rt.functions[f].compiled, length(rt.code) - 1)) {
        if (rt.code[pc] == m3_OpWord("op_Call") && int(rt.code[pc + 1]) == rt.functions[g].compiled) {
            sawCall = true
        }
    }
    check(t, sawCall, "the caller emits op_Call with the callee's compiled pc")
    expect_value(t, rt, f, 4, 41, "call: 4 * 10 + 1")
    expect_value(t, rt, f, -2, -19, "call: -2 * 10 + 1")

    // i32.const 11; i32.const 22; local.get 0; select; end -> 11 if n != 0, else 22
    var sel <- [u8(0x00), u8(0x41), u8(0x0b), u8(0x41), u8(0x16), u8(0x20), u8(0x00), u8(0x1b), u8(0x0b)]
    equal_str(t, compile_body(rt, f, sel), m3Err_none, "compile select")
    expect_value(t, rt, f, 5, 11, "select the first")
    expect_value(t, rt, f, 0, 22, "select the second")
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
    begin_test(t, "test_operation_table_after_new_environment")
    test_operation_table_after_new_environment(t, fx)
    begin_test(t, "test_operation_tables_resolve")
    test_operation_tables_resolve(t, fx)
    begin_test(t, "test_compile_negative_i32_constants_keep_the_c_slot_behaviour")
    test_compile_negative_i32_constants_keep_the_c_slot_behaviour(t, fx)
    begin_test(t, "test_compile_constant_table_keeps_the_c_32bit_slots")
    test_compile_constant_table_keeps_the_c_32bit_slots(t, fx)
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
    begin_test(t, "test_compile_and_run_opcodes")
    test_compile_and_run_opcodes(t, fx)
    begin_test(t, "test_compile_raw_function")
    test_compile_raw_function(t, fx)
}
