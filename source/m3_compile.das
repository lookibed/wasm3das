options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (the compiler runs once per
// wasm function, never on the execution path, so inlining costs startup only)
// is dropped: the option is untested in the editor (DESIGN.md section 1) and
// the interpreter is the only tier of the Eden port.

module m3_compile shared public

require math                                           // min / max (as upstream)
require modules/wasm3das/source/m3_core                // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types               // Eden: project-root-relative path (upstream: ./m3_types.das)
require modules/wasm3das/source/m3_code public         // Eden: project-root-relative path (upstream: ./m3_code.das)
require modules/wasm3das/source/m3_exec                // Eden: project-root-relative path (upstream: ./m3_exec.das)
require modules/wasm3das/source/m3_exec_defs public    // Eden: project-root-relative path (upstream: ./m3_exec_defs.das)
require modules/wasm3das/source/m3_function public     // Eden: project-root-relative path (upstream: ./m3_function.das)
require modules/wasm3das/source/m3_module              // Eden: project-root-relative path (upstream: ./m3_module.das)
require daslib/math_bits                               // Eden: the bits of the f32 / f64 constants (upstream: reinterpret)


/*
    m3_compile.h / m3_compile.c -> m3_compile.das

    Conservative Gen2 port of m3_compile.c: the wasm -> m3 code compiler.
    C preprocessor-only dispatch helpers are represented as local constructor
    helpers below; runtime/compiler semantics and public C names are preserved.

    Eden: deviations from the upstream port (.upstream/source/m3_compile.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.1, 4.3,
    4.4 and 4.4a). The sandbox has no raw pointers, so the compilation state
    is the runtime's and every pointer is a handle or an index:
      - requires are Eden-project-root relative (DESIGN section 6); m3_code,
        m3_exec_defs and m3_function stay public re-exports; daslib/math_bits
        supplies the bits of the float constants.
      - C's `IM3Compilation o` is rt.compilation: every function takes the
        runtime first (`var` when it emits, allocates or moves the stack,
        read-only otherwise), then the C parameters in C order, and reads
        `o->x` as rt.compilation.x. A compiler is `M3Compiler =
        function<(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result>`
        (m3_types); CompileFunction(rt, io_function) is the target of
        m3_exec's CompileFunctionHook.
      - the wasm cursor (o->wasm, o->wasmEnd, o->lastOpcodeStart) is an
        index into the module's `wasm` array (rt.modules[o.moduleIdx].wasm)
        and the readers are the m3_core byte cursors
        (ReadLEB_u32(bytes, o_value, io_pos, i_end) ...); pointer arithmetic
        on the cursor is index arithmetic.
      - scopes (DESIGN section 4.4a): C keeps the enclosing scopes on the
        native stack and links them with `block.outer` pointers. Here
        CompileBlock pushes the enclosing scope on rt.compilation.scopeStack
        and `_block` stays the current scope; a scope HANDLE is an int:
        length(scopeStack) is the current block (CurrentScope), 0 ..
        length - 1 an enclosing scope on the stack (the value of `outer`),
        -1 is NULL. GetBlockScope hands out a handle, GetScope reads a copy
        of the scope, SetScopePatches writes the one field the compiler
        changes through an outer pointer (EmitPatchingBranchPointer).
      - patch chains: a forward-branch patch list is a chain of pc indices
        stored in the code words themselves (the C pointer chain with
        indices), -1 ends it; PatchBranches walks rt.code.
      - operations and code words (DESIGN section 4.4): an operation is
        named; EmitOp(rt, name) writes m3_OpWord(name) and EmitOp(rt, idx)
        an op-table index (the M3OpInfo.operations entries, resolved by the
        table builder). C's NULL operation is c_opNull = -1 for an index
        and "" for a name; both emit op_NoOp (the upstream sentinel, which
        traps if reached) where C would emit NULL unguarded
        (Compile_Select on a polymorphic stack). EmitPointer emits a pc or
        a handle as u64(int) and returns the pc of the word; ReservePointer
        emits a null pc (-1; C: NULL) and returns its pc, and the
        `* jumpTo = pc` writes of C become rt.code[jumpTo] = u64(pc).
        EmitConstant32 / EmitSlotOffset are EmitWord32 of m3_code.
      - M3OpInfo (m3_compile.h): `operations : int[4]` hold op-table
        indices, c_opNull (-1) until resolved; `opNames : string[4]` hold
        the names the M3OP records are written with ("" = C's NULL);
        `compiler` is an M3Compiler (null or c_noCompiler = C's NULL, both
        read by IsNoCompiler). M3OP(name, stackOffset, type, o0 .. o3,
        compiler) takes the four op NAMES; M3OP_RESERVED and M3OP_F keep
        their C meaning. The tables c_operations (C's 0x00 .. 0xfc, 253
        rows) and c_operationsFC (the 0xfc prefix, 12 rows) are
        `array<M3OpInfo>` (a global fixed array of a struct with field
        initializers needs a full initializer in 0.6.3) filled by
        m3_build_operations_table, which builds the op table of m3_exec
        when it is empty, clears and refills both arrays in C order (so a
        second call rebuilds the same tables; the upstream
        c_operationsInitialized flag is not kept) and resolves every name
        through g_opIndex, an unknown name being a d_m3Assert failure;
        until it runs GetOpInfo finds no row (C: an opcode past the
        table), so nothing compiles before the tables exist. The
        zero-filled DEBUG-only rows 0xc5 .. 0xfb are pushed by a loop of
        M3OP_RESERVED rows up to C's designated index 0xfc. GetOpInfo(opcode, o_opInfo) returns whether the row exists
        and copies it (C: a pointer into the table, NULL past it); the
        upstream IM3OpInfo pointer alias is not declared.
      - constants (DESIGN section 4.4a): rt.compilation.constants and
        M3Function.constants hold one 64-bit word per constant SLOT; a
        64-bit constant occupies two entries (the second unused) so the
        C slot accounting (numConstantBytes, slotMaxConstIndex) is
        unchanged and length(constants) == numConstantBytes / 4. PushConst
        reads a 64-bit constant as the word of its first slot and a 32-bit
        one as the low 32 bits of its word (C: a memcpy of 8 or 4 bytes out
        of the 32-bit slot table); C's 64-bit search, which reads two
        adjacent 32-bit slots as one u64, therefore never matches two
        adjacent i32 constants here; the value semantics are the same
        because a slot is one word. CompileFunction copies the
        numConstantSlots words into the function (C: m3_CopyMem of
        numConstantBytes bytes; m3_CopyMem of m3_core takes an array<T> and
        the table is a fixed array, so the copy is spelled out) after
        dropping a previous table, which C leaves aliased and never reads
        when numConstantBytes is 0 (op_Entry copies length(constants)
        words here, so the invariant must hold after a recompilation).
      - handles: a function is an IM3Function into rt.functions, a module
        an IM3Module into rt.modules, a func type an IM3FuncType into
        rt.funcTypes, a global an IM3Global into rt.globals, a code page an
        IM3CodePage into rt.codePages, -1 = NULL. Compile_Call emits the
        compiled pc (op_Call) or the function handle (op_Compile);
        Compile_CallIndirect the module and func-type handles;
        Compile_GetGlobal / Compile_SetGlobal the global's handle (C: the
        address of its value); CompileRawFunction takes the raw-call handle
        (C: the function pointer) and the userdata token and emits them as
        words. `o->module->environment->retFuncTypes` is
        rt.environment.retFuncTypes. Compile_GetSetGlobal's
        `if (o->module->globals)` NULL test is `!empty(module.globals)`.
      - `_throwif` / `_try` expand as m3_exception says (early `return
        result`); the one `_catch` with code in this file (CompileFunction:
        ReleaseCompilationCodePage) is reached by falling through, as
        upstream (DESIGN section 4.7a). The C null tests after allocations
        (`_throwifnull`) have no counterpart, allocation cannot fail
        observably (m3_core), except the code-page acquisitions, which keep
        C's m3Err_mallocFailedCodePage when the page handle is -1.
      - CopyStackTopToSlot keeps the upstream narrowing of C's `(u16)
        stackTop` (-1 on a polymorphic stack becomes 65535, out of range
        for every index helper).
      - the upstream `options never_inline` is dropped (see the options);
        [inline] does not exist in 0.6.3.
      - d_m3Assert stays at every C site; the m3log, d_m3LogWasmStack,
        d_m3EnableOpTracing and DEBUG-only branches are compiled out as
        upstream.
    Everything else (function names, C order, control flow, the checks
    and their order, the error strings, the slot and register accounting)
    is the C of m3_compile.c.
*/


// ============================================================================
// m3_compile.h definitions
// ============================================================================


/* C m3_compile.h: anonymous enum with the opcode constants the compiler walks against */
let public c_waOp_block : m3opcode_t = m3opcode_t(0x02)
let public c_waOp_loop : m3opcode_t = m3opcode_t(0x03)
let public c_waOp_if : m3opcode_t = m3opcode_t(0x04)
let public c_waOp_else : m3opcode_t = m3opcode_t(0x05)
let public c_waOp_end : m3opcode_t = m3opcode_t(0x0b)
let public c_waOp_branch : m3opcode_t = m3opcode_t(0x0c)
let public c_waOp_branchTable : m3opcode_t = m3opcode_t(0x0e)
let public c_waOp_branchIf : m3opcode_t = m3opcode_t(0x0d)
let public c_waOp_call : m3opcode_t = m3opcode_t(0x10)
let public c_waOp_getLocal : m3opcode_t = m3opcode_t(0x20)
let public c_waOp_setLocal : m3opcode_t = m3opcode_t(0x21)
let public c_waOp_teeLocal : m3opcode_t = m3opcode_t(0x22)
let public c_waOp_getGlobal : m3opcode_t = m3opcode_t(0x23)
let public c_waOp_store_f32 : m3opcode_t = m3opcode_t(0x38)
let public c_waOp_store_f64 : m3opcode_t = m3opcode_t(0x39)
let public c_waOp_i32_const : m3opcode_t = m3opcode_t(0x41)
let public c_waOp_i64_const : m3opcode_t = m3opcode_t(0x42)
let public c_waOp_f32_const : m3opcode_t = m3opcode_t(0x43)
let public c_waOp_f64_const : m3opcode_t = m3opcode_t(0x44)
let public c_waOp_extended : m3opcode_t = m3opcode_t(0xfc)
let public c_waOp_memoryCopy : m3opcode_t = m3opcode_t(0xfc0a)
let public c_waOp_memoryFill : m3opcode_t = m3opcode_t(0xfc0b)

/* C m3_compile.h: static const u16 c_m3RegisterUnallocated / c_slotUnused */
let public c_m3RegisterUnallocated : int = 0
let public c_slotUnused : int = int(0xffff)


/* C m3_compile.h: typedef struct M3OpInfo {...} M3OpInfo; */
// Eden: see the header; the four operations are names, resolved to op-table
// indices by m3_build_operations_table, and the compiler an M3Compiler of
// m3_types (C: M3Compiler taking IM3Compilation; Eden: the runtime).
struct M3OpInfo {
    // DEBUG inactive: name field absent.

    stackOffset : int = 0
    _type : int = 0               // C field `type`; keyword-safe Daslang spelling (widened)

    // for most operations:
    // [0]= top operand in register, [1]= top operand in stack, [2]= both operands in stack
    opNames : string[4]           // Eden: the op names of the M3OP record ("" = C's NULL)
    operations : int[4] = fixed_array(-1, -1, -1, -1)   // Eden: op-table indices (m3_exec), c_opNull until resolved

    compiler : M3Compiler         // Eden: null = C's NULL (also c_noCompiler, the upstream sentinel)
}


/* C m3_compile.h: static const u16 + static inline helpers */
def public IsRegisterAllocated(rt : M3Runtime; i_register : u32) : bool {
    return rt.compilation.regStackIndexPlusOne[int(i_register)] != c_m3RegisterUnallocated
}

def public IsStackPolymorphic(rt : M3Runtime) : bool {
    return rt.compilation._block.isPolymorphic
}

def public IsRegisterSlotAlias(i_slot : int) : bool {
    return i_slot >= d_m3Reg0SlotAlias && i_slot != c_slotUnused
}

def public IsFpRegisterSlotAlias(i_slot : int) : bool {
    return i_slot == d_m3Fp0SlotAlias
}

def public IsIntRegisterSlotAlias(i_slot : int) : bool {
    return i_slot == d_m3Reg0SlotAlias
}




//
// Conservative Gen2 port of m3_compile.c.
// C preprocessor-only dispatch helpers are represented as local constructor
// helpers below; runtime/compiler semantics and public C names are preserved.
//

let d_indent = "     | %s"
let i_32 : int = int(u8(M3ValueType.c_m3Type_i32))
let i_64 : int = int(u8(M3ValueType.c_m3Type_i64))
let f_32 : int = int(u8(M3ValueType.c_m3Type_f32))
let f_64 : int = int(u8(M3ValueType.c_m3Type_f64))
let none : int = int(u8(M3ValueType.c_m3Type_none))
let any : int = int(0xff)

let c_ioSlotCount : int = int((d_m3Use32BitSlots ? 1u : 0u) + 1u)

/* C stores NULL in absent operation-table slots. Eden: an operation in a
   table row is its op-table index, and the absent entry is c_opNull = -1;
   an operation named in the compiler's own tables is a string, and the
   absent entry is "". Both emit op_NoOp (m3_exec) where C would emit its
   NULL unguarded: Compile_Select emits its NULL operation when the stack is
   polymorphic, so the word does reach a code page and must dispatch to a
   trapping operation, never execute (the upstream sentinel c_opNull =
   op_NoOp). The C `op == null` checks are IsNoOp(op) / IsNoCompiler(fn). */

let public c_opNull : int = -1

def public IsNoOp(i_operation : int) : bool {
    return i_operation == c_opNull
}

// Eden: the C NULL operation as a name (the entries of c_setSetOps ...)
def public IsNoOpName(i_operation : string) : bool {
    return empty(i_operation)
}

def public c_noCompilerImpl(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    return m3Err_noCompiler
}

let public c_noCompiler : M3Compiler = @@c_noCompilerImpl

// Eden: a row the table builder has not written (M3OpInfo()) has a null
// compiler, C's NULL as well; the upstream sentinel c_noCompiler stays for
// M3OP_RESERVED
def public IsNoCompiler(i_compiler : M3Compiler) : bool {
    if (i_compiler == null) {
        return true
    }
    return i_compiler == c_noCompiler
}


// Eden: IM3OpInfo (C: const M3OpInfo *) is not declared; GetOpInfo copies
// the row and reports whether it exists (see the header).


// C: `const M3OpInfo c_operations []` / `c_operationsFC []` (static
// initialisers, m3_compile.c). Eden: arrays filled by
// m3_build_operations_table (253 rows, C's 0x00 .. 0xfc, and the 12 rows
// of the 0xfc prefix); empty until then, so GetOpInfo finds no row.
var public c_operations : array<M3OpInfo>
var public c_operationsFC : array<M3OpInfo>


// ============================================================================
// Scope handles (Eden, see the header)
// ============================================================================


// C: `& o->block`; Eden: the handle of the current scope, one past the top
// of the scope stack (the enclosing scopes are 0 .. length - 1, -1 = NULL)
def private CurrentScope(rt : M3Runtime) : int {
    return length(rt.compilation.scopeStack)
}


// C: `* scope` through an IM3CompilationScope pointer; Eden: a copy of the
// scope a handle names
def private GetScope(rt : M3Runtime; i_scope : int) : M3CompilationScope {
    if (i_scope == length(rt.compilation.scopeStack)) {
        return rt.compilation._block
    }
    return rt.compilation.scopeStack[i_scope]
}


// C: `i_scope->patches = patch`; Eden: the one field written through a
// scope pointer (EmitPatchingBranchPointer), on the current block or on an
// enclosing scope of the stack
def private SetScopePatches(var rt : M3Runtime; i_scope : int; i_patches : pc_t) {
    if (i_scope == length(rt.compilation.scopeStack)) {
        rt.compilation._block.patches = i_patches
    } else {
        rt.compilation.scopeStack[i_scope].patches = i_patches
    }
}


// ============================================================================
// Emit helpers
// ============================================================================


def GetPC(rt : M3Runtime) : pc_t {
    let page = rt.compilation.page
    return GetPagePC(rt, page)
}


def EnsureCodePageNumLines(var rt : M3Runtime; i_numLines : u32) : M3Result {
    var result : M3Result = m3Err_none
    var numLines = i_numLines
    numLines += 2u

    if (NumFreeLines(rt, rt.compilation.page) < numLines) {
        let page = AcquireCodePageWithCapacity(rt, numLines)
        if (page != -1) {
            d_m3Assert(NumFreeLines(rt, rt.compilation.page) >= 2u)
            // C: EmitWord (o->page, op_Branch). Every operation word goes
            // through m3_OpWord; see the "Operation dispatch" section of
            // m3_exec.das.
            EmitWord(rt, rt.compilation.page, m3_OpWord("op_Branch"))
            // C: EmitWord (o->page, GetPagePC (page)); Eden: the pc as a word
            EmitWord(rt, rt.compilation.page, u64(GetPagePC(rt, page)))
            ReleaseCodePage(rt, rt.compilation.page)
            rt.compilation.page = page
        } else {
            result = m3Err_mallocFailedCodePage
        }
    }
    return result
}


// C: M3Result EmitOp (IM3Compilation o, IM3Operation i_operation) — the
// operation as an op-table index (an M3OpInfo.operations entry); c_opNull
// emits op_NoOp (see c_opNull)
def EmitOp(var rt : M3Runtime; i_operation : int) : M3Result {
    var result : M3Result = m3Err_none
    // C: d_m3Assert (i_operation or IsStackPolymorphic (o)); NULL is c_opNull here.
    d_m3Assert(!IsNoOp(i_operation) || IsStackPolymorphic(rt))

    // page may be null when compile-walking bytecode without emitting.
    if (rt.compilation.page != -1) {
        // DEBUG-only numEmits tracking is compiled out when DEBUG is inactive.

        result = EnsureCodePageNumLines(rt, d_m3CodePageFreeLinesThreshold)
        if (result == m3Err_none) {
            // d_m3LogEmit/d_m3RecordBacktraces are inactive: the C log_emit
            // and EmitMappingEntry calls are compiled out.
            // C: EmitWord (o->page, i_operation) — the operation word, the
            // op-table index (DESIGN.md 4.4); the NULL operation is op_NoOp
            let word = IsNoOp(i_operation) ? m3_OpWord("op_NoOp") : u64(i_operation)
            EmitWord(rt, rt.compilation.page, word)
        }
    }
    return result
}


// Eden: the same, with the operation named (the literal op_* of the C
// source and the entries of the name tables below); "" is C's NULL
def EmitOp(var rt : M3Runtime; i_operation : string) : M3Result {
    // C: d_m3Assert (i_operation or IsStackPolymorphic (o))
    d_m3Assert(!IsNoOpName(i_operation) || IsStackPolymorphic(rt))
    var op = c_opNull
    if (!IsNoOpName(i_operation)) {
        op = int(m3_OpWord(i_operation))
    }
    return EmitOp(rt, op)
}


def EmitConstant32(var rt : M3Runtime; i_immediate : u32) {
    if (rt.compilation.page != -1) {
        EmitWord32(rt, rt.compilation.page, i_immediate)
    }
}


def EmitSlotOffset(var rt : M3Runtime; i_offset : i32) {
    if (rt.compilation.page != -1) {
        EmitWord32(rt, rt.compilation.page, u32(i_offset))
    }
}


// C: pc_t EmitPointer (IM3Compilation o, const void * const i_pointer) — a
// pc, a function, module, func-type or global handle as a word (DESIGN.md
// 4.4: u64(int)); returns the pc of the word (-1 without a page)
def EmitPointer(var rt : M3Runtime; i_pointer : int) : pc_t {
    let ptr : pc_t = GetPagePC(rt, rt.compilation.page)
    if (rt.compilation.page != -1) {
        EmitWord_impl(rt, rt.compilation.page, u64(i_pointer))
    }
    return ptr
}


// C: void * ReservePointer (IM3Compilation o) — reserves one word (NULL)
// and returns its address; Eden: the word is a null pc (-1) and the pc of
// the word is returned; the caller writes rt.code[pc] = u64(target)
def ReservePointer(var rt : M3Runtime) : pc_t {
    let ptr : pc_t = GetPagePC(rt, rt.compilation.page)
    EmitPointer(rt, -1)
    return ptr
}


// Eden: the operation tables of the C source, as op names ("" = C's NULL);
// the index is the M3ValueType (none, i32, i64, f32, f64)
let c_preserveSetSlot = fixed_array("", "op_PreserveSetSlot_i32", "op_PreserveSetSlot_i64", "op_PreserveSetSlot_f32", "op_PreserveSetSlot_f64")
let c_setSetOps = fixed_array("", "op_SetSlot_i32", "op_SetSlot_i64", "op_SetSlot_f32", "op_SetSlot_f64")
let c_setGlobalOps = fixed_array("", "op_SetGlobal_i32", "op_SetGlobal_i64", "op_SetGlobal_f32", "op_SetGlobal_f64")
let c_setRegisterOps = fixed_array("", "op_SetRegister_i32", "op_SetRegister_i64", "op_SetRegister_f32", "op_SetRegister_f64")

let c_intSelectOps = fixed_array(
    fixed_array("op_Select_i32_rss", "op_Select_i32_srs", "op_Select_i32_ssr", "op_Select_i32_sss"),
    fixed_array("op_Select_i64_rss", "op_Select_i64_srs", "op_Select_i64_ssr", "op_Select_i64_sss"))

let c_fpSelectOps = fixed_array(
    fixed_array(
        fixed_array("op_Select_f32_sss", "op_Select_f32_srs", "op_Select_f32_ssr"),
        fixed_array("op_Select_f32_rss", "op_Select_f32_rrs", "op_Select_f32_rsr")),
    fixed_array(
        fixed_array("op_Select_f64_sss", "op_Select_f64_srs", "op_Select_f64_ssr"),
        fixed_array("op_Select_f64_rss", "op_Select_f64_rrs", "op_Select_f64_rsr")))


def AcquireCompilationCodePage(var rt : M3Runtime; var o_codePage : IM3CodePage&) : M3Result {
    var result : M3Result = m3Err_none
    let page = AcquireCodePage(rt)
    if (page != -1) {
        // d_m3EnableCodePageRefCounting == false: the C codePageRefs block is compiled out.
        pass
    } else {
        result = m3Err_mallocFailedCodePage
    }
    o_codePage = page
    return result
}


def ReleaseCompilationCodePage(var rt : M3Runtime) {
    ReleaseCodePage(rt, rt.compilation.page)
}


// ============================================================================
// Slot and type-stack accounting
// ============================================================================


def GetTypeNumSlots(i_type : int) : int {
    if (i_type == int(u8(M3ValueType.c_m3Type_v128))) {
        if (d_m3Use32BitSlots) {
            return 4
        }
        return 2
    }
    if (d_m3Use32BitSlots && Is64BitType(u8(i_type))) {
        return 2
    }
    return 1
}


def AlignSlotToType(var io_slot : int&; i_type : int) {
    let numSlots = GetTypeNumSlots(i_type)
    let mask = numSlots - 1
    io_slot = (io_slot + mask) & ~mask
}


def GetStackTopIndex(rt : M3Runtime) : int {
    d_m3Assert(rt.compilation.stackIndex > rt.compilation.stackFirstDynamicIndex || IsStackPolymorphic(rt))
    return rt.compilation.stackIndex - 1
}


def GetStackTypeFromTop(rt : M3Runtime; i_offset : int) : int {
    var _type : int = int(u8(M3ValueType.c_m3Type_none))
    var offset = i_offset
    offset++
    if (rt.compilation.stackIndex >= offset) {
        let index = rt.compilation.stackIndex - offset
        if (index >= rt.compilation.stackFirstDynamicIndex) {
            _type = rt.compilation.typeStack[index]
        }
    }
    return _type
}


def GetStackTopType(rt : M3Runtime) : int {
    return GetStackTypeFromTop(rt, 0)
}


def GetStackTypeFromBottom(rt : M3Runtime; i_offset : int) : int {
    var _type : int = int(u8(M3ValueType.c_m3Type_none))
    if (i_offset < rt.compilation.stackIndex) {
        _type = rt.compilation.typeStack[i_offset]
    }
    return _type
}


def IsConstantSlot(rt : M3Runtime; i_slot : int) : bool {
    return i_slot >= rt.compilation.slotFirstConstIndex && i_slot < rt.compilation.slotMaxConstIndex
}


def IsSlotAllocated(rt : M3Runtime; i_slot : int) : bool {
    return rt.compilation.m3Slots[i_slot] != 0
}


def IsStackIndexInRegister(rt : M3Runtime; i_stackIndex : i32) : bool {
    d_m3Assert(i_stackIndex < rt.compilation.stackIndex || IsStackPolymorphic(rt))
    if (i_stackIndex >= 0 && i_stackIndex < rt.compilation.stackIndex) {
        return rt.compilation.wasmStack[i_stackIndex] >= d_m3Reg0SlotAlias
    }
    return false
}


def GetNumBlockValuesOnStack(rt : M3Runtime) : int {
    return rt.compilation.stackIndex - rt.compilation._block.blockStackIndex
}

def IsStackTopInRegister(rt : M3Runtime) : bool {
    return IsStackIndexInRegister(rt, GetStackTopIndex(rt))
}

def IsStackTopMinus1InRegister(rt : M3Runtime) : bool {
    return IsStackIndexInRegister(rt, GetStackTopIndex(rt) - 1)
}

def IsStackTopMinus2InRegister(rt : M3Runtime) : bool {
    return IsStackIndexInRegister(rt, GetStackTopIndex(rt) - 2)
}

def IsStackTopInSlot(rt : M3Runtime) : bool {
    return !IsStackTopInRegister(rt)
}

def IsValidSlot(i_slot : int) : bool {
    return i_slot < int(d_m3MaxFunctionSlots)
}


def GetStackTopSlotNumber(rt : M3Runtime) : int {
    let i = GetStackTopIndex(rt)
    var slot : int = c_slotUnused
    if (i >= 0) {
        slot = rt.compilation.wasmStack[i]
    }
    return slot
}


def GetSlotForStackIndex(rt : M3Runtime; i_stackIndex : int) : int {
    d_m3Assert(i_stackIndex < rt.compilation.stackIndex || IsStackPolymorphic(rt))
    var slot : int = c_slotUnused
    if (i_stackIndex < rt.compilation.stackIndex) {
        slot = rt.compilation.wasmStack[i_stackIndex]
    }
    return slot
}


def GetExtraSlotForStackIndex(rt : M3Runtime; i_stackIndex : int) : int {
    var baseSlot = GetSlotForStackIndex(rt, i_stackIndex)
    if (baseSlot != c_slotUnused) {
        baseSlot += GetTypeNumSlots(GetStackTypeFromBottom(rt, i_stackIndex)) - 1
    }
    return baseSlot
}


def TouchSlot(var rt : M3Runtime; i_slot : int) {
    rt.compilation.maxStackSlots = max(rt.compilation.maxStackSlots, i_slot + 1)
}


def MarkSlotAllocated(var rt : M3Runtime; i_slot : int) {
    d_m3Assert(rt.compilation.m3Slots[i_slot] == 0)
    rt.compilation.m3Slots[i_slot] = 1
    rt.compilation.slotMaxAllocatedIndexPlusOne = max(rt.compilation.slotMaxAllocatedIndexPlusOne, i_slot + 1)
    TouchSlot(rt, i_slot)
}


def MarkSlotsAllocated(var rt : M3Runtime; i_slot : int; i_numSlots : int) : M3Result {
    if (i_slot + i_numSlots > int(d_m3MaxFunctionSlots)) {
        return m3Err_functionStackOverflow
    }
    var slot = i_slot
    var numSlots = i_numSlots
    while (numSlots != 0) {
        MarkSlotAllocated(rt, slot)
        slot++
        numSlots--
    }
    return m3Err_none
}


def MarkSlotsAllocatedByType(var rt : M3Runtime; i_slot : int; i_type : int) : M3Result {
    return MarkSlotsAllocated(rt, i_slot, GetTypeNumSlots(i_type))
}


def AllocateSlotsWithinRange(var rt : M3Runtime; var o_slot : int&; i_type : int; i_startSlot : int; i_endSlot : int) : M3Result {
    var result : M3Result = m3Err_functionStackOverflow
    let numSlots = GetTypeNumSlots(i_type)
    let searchOffset = numSlots - 1
    var startSlot = i_startSlot
    AlignSlotToType(startSlot, i_type)

    var i = startSlot
    while (i + searchOffset < i_endSlot) {
        let inRange = i + searchOffset < int(d_m3MaxFunctionSlots)
        if (inRange && rt.compilation.m3Slots[i] == 0 && rt.compilation.m3Slots[i + searchOffset] == 0) {
            result = MarkSlotsAllocated(rt, i, numSlots)
            if (result != m3Err_none) {
                return result
            }
            o_slot = i
            return m3Err_none
        }
        i += numSlots
    }
    return result
}


def AllocateSlots(var rt : M3Runtime; var o_slot : int&; i_type : int) : M3Result {
    return AllocateSlotsWithinRange(rt, o_slot, i_type, rt.compilation.slotFirstDynamicIndex, int(d_m3MaxFunctionSlots))
}


def AllocateConstantSlots(var rt : M3Runtime; var o_slot : int&; i_type : int) : M3Result {
    let maxTableIndex = rt.compilation.slotFirstConstIndex + int(d_m3MaxConstantTableSize)
    let endSlot = min(rt.compilation.slotFirstDynamicIndex, maxTableIndex)
    return AllocateSlotsWithinRange(rt, o_slot, i_type, rt.compilation.slotFirstConstIndex, endSlot)
}


def IncrementSlotUsageCount(var rt : M3Runtime; i_slot : int) : M3Result {
    d_m3Assert(i_slot < int(d_m3MaxFunctionSlots))
    d_m3Assert(rt.compilation.m3Slots[i_slot] > 0)
    if (rt.compilation.m3Slots[i_slot] < int(0xff)) {
        rt.compilation.m3Slots[i_slot]++
        return m3Err_none
    }
    return "slot usage count overflow"
}


def DeallocateSlot(var rt : M3Runtime; i_slot : int; i_type : int) {
    d_m3Assert(i_slot >= rt.compilation.slotFirstDynamicIndex)
    d_m3Assert(i_slot < rt.compilation.slotMaxAllocatedIndexPlusOne)
    var slot = i_slot
    var i : int = 0
    let count = GetTypeNumSlots(i_type)
    while (i < count) {
        d_m3Assert(rt.compilation.m3Slots[slot] != 0)
        rt.compilation.m3Slots[slot]--
        i++
        slot++
    }
}


def IsRegisterTypeAllocated(rt : M3Runtime; i_type : int) : bool {
    var regSelect : u32 = 0u
    if (IsFpType(u8(i_type))) {
        regSelect = 1u
    }
    return IsRegisterAllocated(rt, regSelect)
}


def AllocateRegister(var rt : M3Runtime; i_register : u32; i_stackIndex : int) {
    d_m3Assert(!IsRegisterAllocated(rt, i_register))
    rt.compilation.regStackIndexPlusOne[int(i_register)] = i_stackIndex + 1
}


def DeallocateRegister(var rt : M3Runtime; i_register : u32) {
    d_m3Assert(IsRegisterAllocated(rt, i_register))
    rt.compilation.regStackIndexPlusOne[int(i_register)] = c_m3RegisterUnallocated
}


def GetRegisterStackIndex(rt : M3Runtime; i_register : u32) : int {
    d_m3Assert(IsRegisterAllocated(rt, i_register))
    return rt.compilation.regStackIndexPlusOne[int(i_register)] - 1
}


def GetMaxUsedSlotPlusOne(var rt : M3Runtime) : int {
    while (rt.compilation.slotMaxAllocatedIndexPlusOne > rt.compilation.slotFirstDynamicIndex) {
        if (IsSlotAllocated(rt, rt.compilation.slotMaxAllocatedIndexPlusOne - 1)) {
            break
        }
        rt.compilation.slotMaxAllocatedIndexPlusOne--
    }
    return rt.compilation.slotMaxAllocatedIndexPlusOne
}


def PreserveRegisterIfOccupied(var rt : M3Runtime; i_registerType : int) : M3Result {
    var regSelect : u32 = 0u
    if (IsFpType(u8(i_registerType))) {
        regSelect = 1u
    }
    if (IsRegisterAllocated(rt, regSelect)) {
        let stackIndex = GetRegisterStackIndex(rt, regSelect)
        DeallocateRegister(rt, regSelect)
        let _type = GetStackTypeFromBottom(rt, stackIndex)
        var slot : int = c_slotUnused
        var result = AllocateSlots(rt, slot, _type)
        if (result != m3Err_none) {
            return result
        }
        rt.compilation.wasmStack[stackIndex] = slot

        if (_type < 5) {
            result = EmitOp(rt, c_setSetOps[_type])
            if (result != m3Err_none) {
                return result
            }
        } else {
            return m3Err_functionStackOverflow
        }
        EmitSlotOffset(rt, slot)
    }
    return m3Err_none
}


def PreserveRegisters(var rt : M3Runtime) : M3Result {
    var result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_f64)))
    if (result != m3Err_none) {
        return result
    }
    result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_i64)))
    return result
}


def PreserveNonTopRegisters(var rt : M3Runtime) : M3Result {
    let stackTop = GetStackTopIndex(rt)
    if (stackTop >= 0) {
        if (IsRegisterAllocated(rt, 0u) && GetRegisterStackIndex(rt, 0u) != stackTop) {
            let result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_i64)))
            if (result != m3Err_none) {
                return result
            }
        }
        if (IsRegisterAllocated(rt, 1u) && GetRegisterStackIndex(rt, 1u) != stackTop) {
            let result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_f64)))
            if (result != m3Err_none) {
                return result
            }
        }
    }
    return m3Err_none
}


def Push(var rt : M3Runtime; i_type : int; i_slot : int) : M3Result {
    let isFloat = i_type == int(u8(M3ValueType.c_m3Type_f32)) || i_type == int(u8(M3ValueType.c_m3Type_f64))
    if (!d_m3HasFloat && isFloat) {
        return m3Err_unknownOpcode
    }
    let stackIndex = rt.compilation.stackIndex
    rt.compilation.stackIndex++
    if (stackIndex < int(d_m3MaxFunctionStackHeight)) {
        rt.compilation.wasmStack[stackIndex] = i_slot
        rt.compilation.typeStack[stackIndex] = i_type
        if (IsRegisterSlotAlias(i_slot)) {
            var regSelect : u32 = 0u
            if (IsFpRegisterSlotAlias(i_slot)) {
                regSelect = 1u
            }
            AllocateRegister(rt, regSelect, stackIndex)
        }
        // compiled out under the active configuration: d_m3LogWasmStack == false
        return m3Err_none
    }
    return m3Err_functionStackOverflow
}


def PushRegister(var rt : M3Runtime; i_type : int) : M3Result {
    d_m3Assert(d_m3Reg0SlotAlias > int(d_m3MaxFunctionSlots))
    d_m3Assert(i_type != 0 || IsStackPolymorphic(rt))
    var slot : int = d_m3Reg0SlotAlias
    if (IsFpType(u8(i_type))) {
        slot = d_m3Fp0SlotAlias
    }
    return Push(rt, i_type, slot)
}


def Pop(var rt : M3Runtime) : M3Result {
    if (rt.compilation.stackIndex > rt.compilation._block.blockStackIndex) {
        rt.compilation.stackIndex--
        let slot = rt.compilation.wasmStack[rt.compilation.stackIndex]
        let _type = rt.compilation.typeStack[rt.compilation.stackIndex]
        if (IsRegisterSlotAlias(slot)) {
            var regSelect : u32 = 0u
            if (IsFpRegisterSlotAlias(slot)) {
                regSelect = 1u
            }
            DeallocateRegister(rt, regSelect)
        } elif (slot >= rt.compilation.slotMaxAllocatedIndexPlusOne) {
            return m3Err_functionStackUnderrun
        } elif (slot >= rt.compilation.slotFirstDynamicIndex) {
            DeallocateSlot(rt, slot, _type)
        }
    } elif (!IsStackPolymorphic(rt)) {
        return m3Err_functionStackUnderrun
    }
    return m3Err_none
}


def PopType(var rt : M3Runtime; i_type : int) : M3Result {
    let topType = GetStackTopType(rt)
    if (i_type == topType || rt.compilation._block.isPolymorphic) {
        return Pop(rt)
    }
    return m3Err_typeMismatch
}


def _PushAllocatedSlotAndEmit(var rt : M3Runtime; i_type : int; i_doEmit : bool) : M3Result {
    var slot : int = c_slotUnused
    var result = AllocateSlots(rt, slot, i_type)
    if (result != m3Err_none) {
        return result
    }
    result = Push(rt, i_type, slot)
    if (result != m3Err_none) {
        return result
    }
    if (i_doEmit) {
        EmitSlotOffset(rt, slot)
    }
    return m3Err_none
}


def PushAllocatedSlotAndEmit(var rt : M3Runtime; i_type : int) : M3Result {
    return _PushAllocatedSlotAndEmit(rt, i_type, true)
}

def PushAllocatedSlot(var rt : M3Runtime; i_type : int) : M3Result {
    return _PushAllocatedSlotAndEmit(rt, i_type, false)
}


def PushConst(var rt : M3Runtime; i_word : u64; i_type : int) : M3Result {
    if (rt.compilation.page == -1) {
        return m3Err_none
    }

    var matchFound = false
    let is64BitType = Is64BitType(u8(i_type))
    let numRequiredSlots = GetTypeNumSlots(i_type)
    let numUsedConstSlots = rt.compilation.slotMaxConstIndex - rt.compilation.slotFirstConstIndex

    if (numRequiredSlots == 2 && numUsedConstSlots >= 2) {
        var firstConstSlot = rt.compilation.slotFirstConstIndex
        AlignSlotToType(firstConstSlot, int(u8(M3ValueType.c_m3Type_i64)))
        var slot = firstConstSlot
        while (slot < rt.compilation.slotMaxConstIndex - 1) {
            if (IsSlotAllocated(rt, slot) && IsSlotAllocated(rt, slot + 1)) {
                // C: memcpy (& constant, & o->constants [slot - o->slotFirstConstIndex], sizeof (u64))
                // Eden: the word of the first slot of the pair (see the header)
                let constant : u64 = rt.compilation.constants[slot - rt.compilation.slotFirstConstIndex]
                if (constant == i_word) {
                    matchFound = true
                    let result = Push(rt, i_type, slot)
                    if (result != m3Err_none) {
                        return result
                    }
                    break
                }
            }
            slot += 2
        }
    } elif (numRequiredSlots == 1) {
        var i : int = 0
        while (i < numUsedConstSlots) {
            let slot = rt.compilation.slotFirstConstIndex + i
            if (IsSlotAllocated(rt, slot)) {
                var matches = false
                if (is64BitType) {
                    // C: memcpy (& constant, & o->constants [i], sizeof (u64)); Eden: the word
                    let constant : u64 = rt.compilation.constants[i]
                    matches = constant == i_word
                } else {
                    // C: memcpy (& constant, & o->constants [i], sizeof (u32)); Eden: the low 32 bits of the word
                    let constant : u32 = u32(rt.compilation.constants[i])
                    // C: matches = (constant == i_word) compares the zero-extended u32
                    // with the full u64, so a sign-extended negative i32 never matches.
                    matches = u64(constant) == i_word
                }
                if (matches) {
                    matchFound = true
                    let result = Push(rt, i_type, slot)
                    if (result != m3Err_none) {
                        return result
                    }
                    break
                }
            }
            i++
        }
    }

    if (!matchFound) {
        var slot : int = c_slotUnused
        var result = AllocateConstantSlots(rt, slot, i_type)
        if (result != m3Err_none || slot == c_slotUnused) {
            result = m3Err_none
            if (is64BitType) {
                result = EmitOp(rt, "op_Const64")
                if (result != m3Err_none) {
                    return result
                }
                EmitWord64(rt, rt.compilation.page, i_word)
            } else {
                result = EmitOp(rt, "op_Const32")
                if (result != m3Err_none) {
                    return result
                }
                EmitWord32(rt, rt.compilation.page, u32(i_word))
            }
            return PushAllocatedSlotAndEmit(rt, i_type)
        }

        let constTableIndex = slot - rt.compilation.slotFirstConstIndex
        d_m3Assert(constTableIndex < int(d_m3MaxConstantTableSize))
        if (is64BitType) {
            // C: memcpy (& o->constants [constTableIndex], & i_word, sizeof (u64)); Eden: the word of the first slot
            rt.compilation.constants[constTableIndex] = i_word
        } else {
            // C: memcpy (& o->constants [constTableIndex], & word32, sizeof (u32)); Eden: the low 32 bits, zero-extended
            let word32 = u32(i_word)
            rt.compilation.constants[constTableIndex] = u64(word32)
        }

        result = Push(rt, i_type, slot)
        if (result != m3Err_none) {
            return result
        }
        rt.compilation.slotMaxConstIndex = max(slot + numRequiredSlots, rt.compilation.slotMaxConstIndex)
    }

    return m3Err_none
}


def EmitSlotNumOfStackTopAndPop(var rt : M3Runtime) : M3Result {
    if (IsStackTopInSlot(rt)) {
        EmitSlotOffset(rt, GetStackTopSlotNumber(rt))
    }
    return Pop(rt)
}


def AddTrapRecord(var rt : M3Runtime) : M3Result {
    return m3Err_none
}


def UnwindBlockStack(var rt : M3Runtime) : M3Result {
    var popCount : u32 = 0u
    while (rt.compilation.stackIndex > rt.compilation._block.blockStackIndex) {
        let result = Pop(rt)
        if (result != m3Err_none) {
            return result
        }
        popCount++
    }
    // compiled out under the active configuration: m3log (compile, "unwound stack top: %d", popCount)
    return m3Err_none
}


def SetStackPolymorphic(var rt : M3Runtime) : M3Result {
    rt.compilation._block.isPolymorphic = true
    return UnwindBlockStack(rt)
}


def PatchBranches(var rt : M3Runtime) {
    let pc = GetPC(rt)
    var patches = rt.compilation._block.patches
    rt.compilation._block.patches = -1

    // Eden: the chain of pc indices in the code words, -1 ends it (see the header)
    while (patches != -1) {
        // compiled out under the active configuration: m3log (compile, "patching location: %p to pc: %p", patches, pc)
        let next : pc_t = int(rt.code[patches])   // C: pc_t next = * (pc_t *) patches
        rt.code[patches] = u64(pc)                // C: * (pc_t *) patches = pc
        patches = next
    }
}


def CopyStackIndexToSlot(var rt : M3Runtime; i_destSlot : int; i_stackIndex : int) : M3Result {
    let _type = GetStackTypeFromBottom(rt, i_stackIndex)
    let inRegister = IsStackIndexInRegister(rt, i_stackIndex)
    var op : string
    if (inRegister) {
        op = c_setSetOps[_type]
    } elif (Is64BitType(u8(_type))) {
        op = "op_CopySlot_64"
    } else {
        op = "op_CopySlot_32"
    }
    let result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    EmitSlotOffset(rt, i_destSlot)
    if (!inRegister) {
        EmitSlotOffset(rt, GetSlotForStackIndex(rt, i_stackIndex))
    }
    return m3Err_none
}


def CopyStackTopToSlot(var rt : M3Runtime; i_destSlot : int) : M3Result {
    // C: `i16 stackTop = GetStackTopIndex (o); CopyStackIndexToSlot (o, i_destSlot, (u16) stackTop)`.
    // On a polymorphic stack (after `unreachable`/`br`) the top index is -1 and the
    // C cast turns it into 65535, which every index helper then reads as out of
    // range: type c_m3Type_none, slot c_slotUnused, not in a register. Daslang ints
    // do not wrap, so the narrowing is spelled out; without it the -1 indexes
    // typeStack/wasmStack out of range.
    let stackTop = GetStackTopIndex(rt)
    return CopyStackIndexToSlot(rt, i_destSlot, stackTop & int(0xffff))
}


def PreservedCopyTopSlot(var rt : M3Runtime; i_destSlot : int; i_preserveSlot : int) : M3Result {
    d_m3Assert(i_destSlot != i_preserveSlot)
    let _type = GetStackTopType(rt)
    var op : string
    if (IsStackTopInRegister(rt)) {
        op = c_preserveSetSlot[_type]
    } elif (Is64BitType(u8(_type))) {
        op = "op_PreserveCopySlot_64"
    } else {
        op = "op_PreserveCopySlot_32"
    }
    let result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    EmitSlotOffset(rt, i_destSlot)
    if (IsStackTopInSlot(rt)) {
        EmitSlotOffset(rt, GetStackTopSlotNumber(rt))
    }
    EmitSlotOffset(rt, i_preserveSlot)
    return m3Err_none
}


def CopyStackTopToRegister(var rt : M3Runtime; i_updateStack : bool) : M3Result {
    if (IsStackTopInSlot(rt)) {
        let _type = GetStackTopType(rt)
        var result = PreserveRegisterIfOccupied(rt, _type)
        if (result != m3Err_none) {
            return result
        }
        result = EmitOp(rt, c_setRegisterOps[_type])
        if (result != m3Err_none) {
            return result
        }
        EmitSlotOffset(rt, GetStackTopSlotNumber(rt))
        if (i_updateStack) {
            result = PopType(rt, _type)
            if (result != m3Err_none) {
                return result
            }
            result = PushRegister(rt, _type)
            if (result != m3Err_none) {
                return result
            }
        }
    }
    return m3Err_none
}


def FindReferencedLocalWithinCurrentBlock(var rt : M3Runtime; var o_preservedSlotNumber : int&; i_localSlot : u32) : M3Result {
    // C: IM3CompilationScope scope = & o->block; Eden: the handle of the current scope
    var scope = CurrentScope(rt)
    var startIndex = GetScope(rt, scope).blockStackIndex

    while (GetScope(rt, scope).opcode == c_waOp_block) {
        scope = GetScope(rt, scope).outer
        if (scope == -1) {
            break
        }
        startIndex = GetScope(rt, scope).blockStackIndex
    }

    o_preservedSlotNumber = int(i_localSlot)
    var i = u32(startIndex)
    while (i < u32(rt.compilation.stackIndex)) {
        if (rt.compilation.wasmStack[int(i)] == int(i_localSlot)) {
            if (o_preservedSlotNumber == int(i_localSlot)) {
                let _type = GetStackTypeFromBottom(rt, int(i))
                d_m3Assert(_type != int(u8(M3ValueType.c_m3Type_none)))
                let result = AllocateSlots(rt, o_preservedSlotNumber, _type)
                if (result != m3Err_none) {
                    return result
                }
            } else {
                let result = IncrementSlotUsageCount(rt, o_preservedSlotNumber)
                if (result != m3Err_none) {
                    return result
                }
            }
            rt.compilation.wasmStack[int(i)] = o_preservedSlotNumber
        }
        i++
    }
    return m3Err_none
}


// C: M3Result GetBlockScope (IM3Compilation o, IM3CompilationScope * o_scope, u32 i_depth)
// Eden: o_scope is a scope handle (see the header)
def GetBlockScope(rt : M3Runtime; var o_scope : int&; i_depth : u32) : M3Result {
    var scope = CurrentScope(rt)   // C: IM3CompilationScope scope = & o->block
    var depth = i_depth
    while (depth != 0u) {
        scope = GetScope(rt, scope).outer
        if (scope == -1) {
            return "invalid block depth"
        }
        depth--
    }
    o_scope = scope
    return m3Err_none
}


def CopyStackSlotsR(var rt : M3Runtime; i_targetSlotStackIndex : int; i_stackIndex : int; i_endStackIndex : int; i_tempSlot : int) : M3Result {
    if (i_stackIndex < i_endStackIndex) {
        let srcSlot = GetSlotForStackIndex(rt, i_stackIndex)
        let _type = GetStackTypeFromBottom(rt, i_stackIndex)
        let numSlots = GetTypeNumSlots(_type)
        let extraSlot = numSlots - 1
        let targetSlot = GetSlotForStackIndex(rt, i_targetSlotStackIndex)
        var preserveIndex = i_stackIndex
        var collisionSlot = srcSlot
        var tempSlot = i_tempSlot

        if (targetSlot != srcSlot) {
            var checkIndex = i_stackIndex + 1
            while (checkIndex < i_endStackIndex) {
                let otherSlot1 = GetSlotForStackIndex(rt, checkIndex)
                let otherSlot2 = GetExtraSlotForStackIndex(rt, checkIndex)
                if (targetSlot == otherSlot1 || targetSlot == otherSlot2 || targetSlot + extraSlot == otherSlot1) {
                    if (tempSlot >= int(d_m3MaxFunctionSlots)) {
                        return m3Err_functionStackOverflow
                    }
                    let result = CopyStackIndexToSlot(rt, tempSlot, checkIndex)
                    if (result != m3Err_none) {
                        return result
                    }
                    rt.compilation.wasmStack[checkIndex] = tempSlot
                    tempSlot += GetTypeNumSlots(int(u8(M3ValueType.c_m3Type_i64)))
                    TouchSlot(rt, tempSlot - 1)
                    preserveIndex = checkIndex
                    collisionSlot = otherSlot1
                    break
                }
                checkIndex++
            }

            let result = CopyStackIndexToSlot(rt, targetSlot, i_stackIndex)
            if (result != m3Err_none) {
                return result
            }
            rt.compilation.wasmStack[i_stackIndex] = targetSlot
        }

        let result = CopyStackSlotsR(rt, i_targetSlotStackIndex + 1, i_stackIndex + 1, i_endStackIndex, tempSlot)
        if (result != m3Err_none) {
            return result
        }
        rt.compilation.wasmStack[i_stackIndex] = srcSlot
        rt.compilation.wasmStack[preserveIndex] = collisionSlot
    }
    return m3Err_none
}


// C: M3Result ResolveBlockResults (IM3Compilation o, IM3CompilationScope i_targetBlock, bool i_isBranch)
// Eden: i_targetBlock is a scope handle
def ResolveBlockResults(var rt : M3Runtime; i_targetBlock : int; i_isBranch : bool) : M3Result {
    // compiled out under the active configuration: d_m3LogWasmStack == false
    let targetBlock = GetScope(rt, i_targetBlock)
    let isLoop = targetBlock.opcode == c_waOp_loop && i_isBranch
    let numParams = int(GetFuncTypeNumParams(rt, targetBlock.typeIdx))
    let numResults = int(GetFuncTypeNumResults(rt, targetBlock.typeIdx))
    var slotRecords = targetBlock.exitStackIndex
    var numValues : int
    if (!isLoop) {
        numValues = numResults
        slotRecords += numParams
    } else {
        numValues = numParams
    }

    let blockHeight = GetNumBlockValuesOnStack(rt)
    if ((i_isBranch && blockHeight < numValues) || (!i_isBranch && blockHeight != numValues)) {
        return m3Err_typeCountMismatch
    }

    if (numValues != 0) {
        var endIndex = GetStackTopIndex(rt) + 1
        var numRemValues = numValues
        if (!isLoop && IsFpType(u8(GetStackTopType(rt)))) {
            let result = CopyStackTopToRegister(rt, false)
            if (result != m3Err_none) {
                return result
            }
            endIndex--
            numRemValues--
        }
        var tempSlot = rt.compilation.maxStackSlots
        AlignSlotToType(tempSlot, int(u8(M3ValueType.c_m3Type_i64)))
        let result = CopyStackSlotsR(rt, slotRecords, endIndex - numRemValues, endIndex, tempSlot)
        if (result != m3Err_none) {
            return result
        }
        // compiled out under the active configuration: d_m3LogWasmStack == false
    }
    return m3Err_none
}


// C: M3Result ReturnValues (IM3Compilation o, IM3CompilationScope i_functionBlock, bool i_isBranch)
// Eden: i_functionBlock is a scope handle
def ReturnValues(var rt : M3Runtime; i_functionBlock : int; i_isBranch : bool) : M3Result {
    // compiled out under the active configuration: d_m3LogWasmStack == false
    let functionBlock = GetScope(rt, i_functionBlock)
    var numReturns = int(GetFuncTypeNumResults(rt, functionBlock.typeIdx))
    let blockHeight = GetNumBlockValuesOnStack(rt)
    let countMismatch = (i_isBranch && blockHeight < numReturns) || (!i_isBranch && blockHeight != numReturns)
    if (!IsStackPolymorphic(rt) && countMismatch) {
        return m3Err_typeCountMismatch
    }

    if (numReturns != 0) {
        var returnSlot = numReturns * c_ioSlotCount
        var stackTop = GetStackTopIndex(rt)
        var i : int = 0
        while (i < numReturns) {
            let returnType : int = int(GetFuncTypeResultType(rt, functionBlock.typeIdx, u16(numReturns - 1 - i)))
            var stackType = GetStackTypeFromTop(rt, i)
            if (IsStackPolymorphic(rt) && stackType == int(u8(M3ValueType.c_m3Type_none))) {
                stackType = returnType
            }
            if (returnType != stackType) {
                return m3Err_typeMismatch
            }
            if (!IsStackPolymorphic(rt)) {
                returnSlot -= c_ioSlotCount
                let result = CopyStackIndexToSlot(rt, returnSlot, stackTop)
                if (result != m3Err_none) {
                    return result
                }
                stackTop--
            }
            i++
        }
        if (!i_isBranch) {
            while (numReturns != 0) {
                let result = Pop(rt)
                if (result != m3Err_none) {
                    return result
                }
                numReturns--
            }
        }
    }
    return m3Err_none
}


// ============================================================================
// Opcode compilers
// ============================================================================


def Compile_Const_i32(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var value : i32 = 0
    var result = ReadLEB_i32(rt.modules[rt.compilation.moduleIdx].wasm, value, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    // C passes the i32 to the u64 parameter of PushConst: integer promotion
    // sign-extends it, which is what makes the constant-slot search miss
    // negative i32 constants (see PushConst). Kept as in C.
    result = PushConst(rt, u64(i64(value)), int(u8(M3ValueType.c_m3Type_i32)))
    return result
}


def Compile_Const_i64(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var value : i64 = 0l
    var result = ReadLEB_i64(rt.modules[rt.compilation.moduleIdx].wasm, value, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    result = PushConst(rt, u64(value), int(u8(M3ValueType.c_m3Type_i64)))
    return result
}


def Compile_Const_f32(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    if (!d_m3ImplementFloat) {
        return m3Err_unknownOpcode
    }
    var value : f32 = 0.0
    let result = Read_f32(rt.modules[rt.compilation.moduleIdx].wasm, value, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    let bits = float_bits_to_uint(value)   // Eden: the bits through daslib/math_bits (upstream: reinterpret)
    return PushConst(rt, u64(bits), int(u8(M3ValueType.c_m3Type_f32)))
}


def Compile_Const_f64(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    if (!d_m3ImplementFloat) {
        return m3Err_unknownOpcode
    }
    var value : f64 = 0.0lf
    let result = Read_f64(rt.modules[rt.compilation.moduleIdx].wasm, value, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    let bits = double_bits_to_uint64(value)   // Eden: the bits through daslib/math_bits (upstream: reinterpret)
    return PushConst(rt, bits, int(u8(M3ValueType.c_m3Type_f64)))
}


def Compile_ExtendedOpcode(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    if (!d_m3CascadedOpcodes) {
        return m3Err_unknownOpcode
    }
    var opcode : u8 = 0u8
    var result = Read_u8(rt.modules[rt.compilation.moduleIdx].wasm, opcode, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    let extended = m3opcode_t((int(i_opcode) << 8) | int(opcode))   // C: i_opcode = (i_opcode << 8) | opcode
    var opInfo = M3OpInfo()
    if (!GetOpInfo(extended, opInfo)) {
        return m3Err_unknownOpcode
    }
    let compiler = opInfo.compiler
    // C: _throwif (m3Err_noCompiler, not compiler); NULL is IsNoCompiler here.
    if (IsNoCompiler(compiler)) {
        return m3Err_noCompiler
    }
    result = invoke(compiler, rt, extended)
    if (result == m3Err_none) {
        rt.compilation.previousOpcode = extended
    }
    return result
}


def Compile_Return(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    if (!IsStackPolymorphic(rt)) {
        var functionScope : int = -1
        var result = GetBlockScope(rt, functionScope, u32(rt.compilation._block.depth))
        if (result != m3Err_none) {
            return result
        }
        result = ReturnValues(rt, functionScope, true)
        if (result != m3Err_none) {
            return result
        }
        result = EmitOp(rt, "op_Return")
        if (result != m3Err_none) {
            return result
        }
        return SetStackPolymorphic(rt)
    }
    return m3Err_none
}


def ValidateBlockEnd(var rt : M3Runtime) : M3Result {
    return m3Err_none
}


def Compile_End(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    if (rt.compilation._block.depth == 0) {
        ValidateBlockEnd(rt)
        if (rt.compilation.functionIdx != -1) {
            let result = ReturnValues(rt, CurrentScope(rt), false)   // C: ReturnValues (o, & o->block, false)
            if (result != m3Err_none) {
                return result
            }
        }
        return EmitOp(rt, "op_Return")
    }
    return m3Err_none
}


def Compile_SetLocal(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var localIndex : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, localIndex, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    if (localIndex >= GetFunctionNumArgsAndLocals(rt, rt.compilation.functionIdx)) {
        return "local index out of bounds"
    }

    let localSlot = GetSlotForStackIndex(rt, int(localIndex))
    var preserveSlot : int = c_slotUnused
    result = FindReferencedLocalWithinCurrentBlock(rt, preserveSlot, u32(localSlot))
    if (result != m3Err_none) {
        return result
    }
    if (preserveSlot == localSlot) {
        result = CopyStackTopToSlot(rt, localSlot)
    } else {
        result = PreservedCopyTopSlot(rt, localSlot, preserveSlot)
    }
    if (result != m3Err_none) {
        return result
    }
    if (i_opcode != c_waOp_teeLocal) {
        return Pop(rt)
    }
    return m3Err_none
}


def Compile_GetLocal(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var localIndex : u32 = 0u
    let result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, localIndex, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    if (localIndex >= GetFunctionNumArgsAndLocals(rt, rt.compilation.functionIdx)) {
        return "local index out of bounds"
    }
    return Push(rt, GetStackTypeFromBottom(rt, int(localIndex)), GetSlotForStackIndex(rt, int(localIndex)))
}


// C: M3Result Compile_GetGlobal (IM3Compilation o, M3Global * i_global)
// Eden: the global's handle into rt.globals; its word is the handle (C: the
// address of its value)
def Compile_GetGlobal(var rt : M3Runtime; i_global : IM3Global) : M3Result {
    var op = "op_GetGlobal_s32"
    if (Is64BitType(rt.globals[i_global]._type)) {
        op = "op_GetGlobal_s64"
    }
    let result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    EmitPointer(rt, i_global)   // C: EmitPointer (o, & i_global->i64Value)
    return PushAllocatedSlotAndEmit(rt, int(rt.globals[i_global]._type))
}


def Compile_SetGlobal(var rt : M3Runtime; i_global : IM3Global) : M3Result {
    if (!rt.globals[i_global].isMutable) {
        return m3Err_settingImmutableGlobal
    }
    let _type = GetStackTopType(rt)
    var op : string
    if (IsStackTopInRegister(rt)) {
        op = c_setGlobalOps[_type]
    } elif (Is64BitType(u8(_type))) {
        op = "op_SetGlobal_s64"
    } else {
        op = "op_SetGlobal_s32"
    }
    let result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    EmitPointer(rt, i_global)   // C: EmitPointer (o, & i_global->i64Value)
    if (IsStackTopInSlot(rt)) {
        EmitSlotOffset(rt, GetStackTopSlotNumber(rt))
    }
    return Pop(rt)
}


def Compile_GetSetGlobal(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var globalIndex : u32 = 0u
    let result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, globalIndex, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    if (globalIndex >= rt.modules[rt.compilation.moduleIdx].numGlobals) {
        return m3Err_globaIndexOutOfBounds
    }
    // C: if (o->module->globals); Eden: the handle array is the allocation
    if (empty(rt.modules[rt.compilation.moduleIdx].globals)) {
        return ErrorCompile(m3Err_globalMemoryNotAllocated, rt, "module '{rt.modules[rt.compilation.moduleIdx].name}' is missing global memory")
    }
    // C: M3Global * global = & o->module->globals [globalIndex]; Eden: the handle
    let global : IM3Global = rt.modules[rt.compilation.moduleIdx].globals[int(globalIndex)]
    if (i_opcode == c_waOp_getGlobal) {
        return Compile_GetGlobal(rt, global)
    }
    return Compile_SetGlobal(rt, global)
}


// C: void EmitPatchingBranchPointer (IM3Compilation o, IM3CompilationScope i_scope)
// Eden: i_scope is a scope handle; the patch chain is threaded through the
// code words (see the header)
def EmitPatchingBranchPointer(var rt : M3Runtime; i_scope : int) {
    let patch = EmitPointer(rt, GetScope(rt, i_scope).patches)   // C: pc_t patch = EmitPointer (o, i_scope->patches)
    SetScopePatches(rt, i_scope, patch)                           // C: i_scope->patches = patch
}


def EmitPatchingBranch(var rt : M3Runtime; i_scope : int) : M3Result {
    let result = EmitOp(rt, "op_Branch")
    if (result != m3Err_none) {
        return result
    }
    EmitPatchingBranchPointer(rt, i_scope)
    return m3Err_none
}


def Compile_Branch(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var depth : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, depth, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    var scope : int = -1
    result = GetBlockScope(rt, scope, depth)
    if (result != m3Err_none) {
        return result
    }
    let target = GetScope(rt, scope)   // Eden: the fields C reads through the scope pointer

    if (target.opcode == c_waOp_loop) {
        if (i_opcode == c_waOp_branchIf) {
            if (int(GetFuncTypeNumParams(rt, target.typeIdx)) != 0) {
                var op = "op_BranchIfPrologue_s"
                if (IsStackTopInRegister(rt)) {
                    op = "op_BranchIfPrologue_r"
                }
                result = EmitOp(rt, op)
                if (result != m3Err_none) {
                    return result
                }
                result = EmitSlotNumOfStackTopAndPop(rt)
                if (result != m3Err_none) {
                    return result
                }
                let jumpTo : pc_t = ReservePointer(rt)   // C: pc_t * jumpTo = (pc_t *) ReservePointer (o)
                result = ResolveBlockResults(rt, scope, true)
                if (result != m3Err_none) {
                    return result
                }
                result = EmitOp(rt, "op_ContinueLoop")
                if (result != m3Err_none) {
                    return result
                }
                EmitPointer(rt, target.pc)
                rt.code[jumpTo] = u64(GetPC(rt))   // C: * jumpTo = GetPC (o)
            } else {
                result = CopyStackTopToRegister(rt, false)
                if (result != m3Err_none) {
                    return result
                }
                result = PopType(rt, int(u8(M3ValueType.c_m3Type_i32)))
                if (result != m3Err_none) {
                    return result
                }
                result = EmitOp(rt, "op_ContinueLoopIf")
                if (result != m3Err_none) {
                    return result
                }
                EmitPointer(rt, target.pc)
            }
        } else {
            result = EmitOp(rt, "op_ContinueLoop")
            if (result != m3Err_none) {
                return result
            }
            EmitPointer(rt, target.pc)
            rt.compilation._block.isPolymorphic = true
        }
        return m3Err_none
    }

    var jumpTo : pc_t = -1   // C: pc_t * jumpTo = NULL
    let isReturn = target.depth == 0
    let targetHasResults = int(GetFuncTypeNumResults(rt, target.typeIdx)) != 0

    if (i_opcode == c_waOp_branchIf) {
        if (targetHasResults || isReturn) {
            var op = "op_BranchIfPrologue_s"
            if (IsStackTopInRegister(rt)) {
                op = "op_BranchIfPrologue_r"
            }
            result = EmitOp(rt, op)
            if (result != m3Err_none) {
                return result
            }
            result = EmitSlotNumOfStackTopAndPop(rt)
            if (result != m3Err_none) {
                return result
            }
            jumpTo = ReservePointer(rt)
        } else {
            var op = "op_BranchIf_s"
            if (IsStackTopInRegister(rt)) {
                op = "op_BranchIf_r"
            }
            result = EmitOp(rt, op)
            if (result != m3Err_none) {
                return result
            }
            result = EmitSlotNumOfStackTopAndPop(rt)
            if (result != m3Err_none) {
                return result
            }
            EmitPatchingBranchPointer(rt, scope)
            return m3Err_none
        }
    }

    if (!IsStackPolymorphic(rt)) {
        if (isReturn) {
            result = ReturnValues(rt, scope, true)
            if (result != m3Err_none) {
                return result
            }
            result = EmitOp(rt, "op_Return")
        } else {
            result = ResolveBlockResults(rt, scope, true)
            if (result != m3Err_none) {
                return result
            }
            result = EmitPatchingBranch(rt, scope)
        }
        if (result != m3Err_none) {
            return result
        }
    }

    if (jumpTo != -1) {
        rt.code[jumpTo] = u64(GetPC(rt))   // C: * jumpTo = GetPC (o)
    }
    if (i_opcode == c_waOp_branch) {
        return SetStackPolymorphic(rt)
    }
    return m3Err_none
}


def Compile_BranchTable(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var targetCount : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, targetCount, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_i64)))
    if (result != m3Err_none) {
        return result
    }
    let slot = GetStackTopSlotNumber(rt)
    result = Pop(rt)
    if (result != m3Err_none) {
        return result
    }

    let numCodeLines = targetCount + 4u
    result = EnsureCodePageNumLines(rt, numCodeLines)
    if (result != m3Err_none) {
        return result
    }
    result = EmitOp(rt, "op_BranchTable")
    if (result != m3Err_none) {
        return result
    }
    EmitSlotOffset(rt, slot)
    EmitConstant32(rt, targetCount)

    var continueOpPage : IM3CodePage = -1
    targetCount++
    var i : u32 = 0u
    while (i < targetCount) {
        var target : u32 = 0u
        result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, target, rt.compilation.wasm, rt.compilation.wasmEnd)
        if (result != m3Err_none) {
            return result
        }
        var scope : int = -1
        result = GetBlockScope(rt, scope, target)
        if (result != m3Err_none) {
            return result
        }
        result = AcquireCompilationCodePage(rt, continueOpPage)
        if (result != m3Err_none) {
            return result
        }

        let startPC = GetPagePC(rt, continueOpPage)
        let savedPage = rt.compilation.page
        rt.compilation.page = continueOpPage
        let targetScope = GetScope(rt, scope)

        if (targetScope.opcode == c_waOp_loop) {
            result = ResolveBlockResults(rt, scope, true)
            if (result == m3Err_none) {
                result = EmitOp(rt, "op_ContinueLoop")
            }
            if (result == m3Err_none) {
                EmitPointer(rt, targetScope.pc)
            }
        } elif (!IsStackPolymorphic(rt)) {
            if (targetScope.depth == 0) {
                result = ReturnValues(rt, scope, true)
                if (result == m3Err_none) {
                    result = EmitOp(rt, "op_Return")
                }
            } else {
                result = ResolveBlockResults(rt, scope, true)
                if (result == m3Err_none) {
                    result = EmitPatchingBranch(rt, scope)
                }
            }
        }

        if (result != m3Err_none) {
            return result
        }
        ReleaseCompilationCodePage(rt)
        rt.compilation.page = savedPage
        EmitPointer(rt, startPC)
        i++
    }
    return SetStackPolymorphic(rt)
}


def CompileCallArgsAndReturn(var rt : M3Runtime; var o_stackOffset : int&; i_type : IM3FuncType; i_isIndirect : bool) : M3Result {
    var topSlot = GetMaxUsedSlotPlusOne(rt)
    topSlot = max(1, topSlot)
    AlignSlotToType(topSlot, int(u8(M3ValueType.c_m3Type_i64)))
    o_stackOffset = topSlot
    if (i_isIndirect) {
        let result = Pop(rt)
        if (result != m3Err_none) {
            return result
        }
    }

    var numArgs = int(GetFuncTypeNumParams(rt, i_type))
    var numRets = int(GetFuncTypeNumResults(rt, i_type))
    var argTop = topSlot + (numArgs + numRets) * c_ioSlotCount
    while (numArgs != 0) {
        argTop -= c_ioSlotCount
        var result = CopyStackTopToSlot(rt, argTop)
        if (result != m3Err_none) {
            return result
        }
        result = Pop(rt)
        if (result != m3Err_none) {
            return result
        }
        numArgs--
    }

    var i : int = 0
    while (numRets != 0) {
        let _type : int = int(GetFuncTypeResultType(rt, i_type, u16(i)))
        var result = Push(rt, _type, topSlot)
        if (result != m3Err_none) {
            return result
        }
        result = MarkSlotsAllocatedByType(rt, topSlot, _type)
        if (result != m3Err_none) {
            return result
        }
        topSlot += c_ioSlotCount
        i++
        numRets--
    }
    return m3Err_none
}


def Compile_Call(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var functionIndex : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, functionIndex, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    let _function = Module_GetFunction(rt, rt.compilation.moduleIdx, functionIndex)
    if (_function == -1) {
        return m3Err_functionLookupFailed
    }

    // C: if (function->module); Eden: an import whose link never ran keeps moduleIdx -1 (DESIGN.md 4.1)
    if (rt.functions[_function].moduleIdx == -1) {
        return ErrorCompile(m3Err_functionImportMissing, rt, "'{GetFunctionImportModuleName(rt, _function)}.{m3_GetFunctionName(rt, _function)}'")
    }

    var slotTop : int = 0
    result = CompileCallArgsAndReturn(rt, slotTop, rt.functions[_function].funcTypeIdx, false)
    if (result != m3Err_none) {
        return result
    }
    var op : string
    var operand : int   // Eden: the compiled pc (op_Call) or the function handle (op_Compile), DESIGN.md 4.4
    if (rt.functions[_function].compiled != -1) {
        op = "op_Call"
        operand = rt.functions[_function].compiled
    } else {
        op = "op_Compile"
        operand = _function
    }
    result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    EmitPointer(rt, operand)
    EmitSlotOffset(rt, slotTop)
    return m3Err_none
}


def Compile_CallIndirect(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var typeIndex : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, typeIndex, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    var tableIndex : u32 = 0u
    result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, tableIndex, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    if (typeIndex >= rt.modules[rt.compilation.moduleIdx].numFuncTypes) {
        return "function call type index out of range"
    }

    if (IsStackTopInRegister(rt)) {
        result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_i32)))
        if (result != m3Err_none) {
            return result
        }
    }
    let tableIndexSlot = GetStackTopSlotNumber(rt)
    var execTop : int = 0
    let _type : IM3FuncType = rt.modules[rt.compilation.moduleIdx].funcTypes[int(typeIndex)]   // C: IM3FuncType type = o->module->funcTypes [typeIndex]
    result = CompileCallArgsAndReturn(rt, execTop, _type, true)
    if (result != m3Err_none) {
        return result
    }
    result = EmitOp(rt, "op_CallIndirect")
    if (result != m3Err_none) {
        return result
    }
    EmitSlotOffset(rt, tableIndexSlot)
    EmitPointer(rt, rt.compilation.moduleIdx)   // C: EmitPointer (o, o->module); Eden: the module handle
    EmitPointer(rt, _type)                      // C: EmitPointer (o, type); Eden: the func-type handle
    EmitSlotOffset(rt, execTop)
    return m3Err_none
}


def Compile_Memory_Size(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var reserved : i8 = i8(0)
    var result = ReadLEB_i7(rt.modules[rt.compilation.moduleIdx].wasm, reserved, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_i32)))
    if (result != m3Err_none) {
        return result
    }
    result = EmitOp(rt, "op_MemSize")
    if (result != m3Err_none) {
        return result
    }
    return PushRegister(rt, int(u8(M3ValueType.c_m3Type_i32)))
}


def Compile_Memory_Grow(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var reserved : i8 = i8(0)
    var result = ReadLEB_i7(rt.modules[rt.compilation.moduleIdx].wasm, reserved, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    result = CopyStackTopToRegister(rt, false)
    if (result != m3Err_none) {
        return result
    }
    result = PopType(rt, int(u8(M3ValueType.c_m3Type_i32)))
    if (result != m3Err_none) {
        return result
    }
    result = EmitOp(rt, "op_MemGrow")
    if (result != m3Err_none) {
        return result
    }
    return PushRegister(rt, int(u8(M3ValueType.c_m3Type_i32)))
}


def Compile_Memory_CopyFill(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var sourceMemoryIdx : u32 = 0u
    var targetMemoryIdx : u32 = 0u
    var op : string
    var result : M3Result = m3Err_none
    if (i_opcode == c_waOp_memoryCopy) {
        result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, sourceMemoryIdx, rt.compilation.wasm, rt.compilation.wasmEnd)
        if (result != m3Err_none) {
            return result
        }
        op = "op_MemCopy"
    } else {
        op = "op_MemFill"
    }
    result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, targetMemoryIdx, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    result = CopyStackTopToRegister(rt, false)
    if (result != m3Err_none) {
        return result
    }
    result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    result = PopType(rt, int(u8(M3ValueType.c_m3Type_i32)))
    if (result != m3Err_none) {
        return result
    }
    result = EmitSlotNumOfStackTopAndPop(rt)
    if (result != m3Err_none) {
        return result
    }
    return EmitSlotNumOfStackTopAndPop(rt)
}


def ReadBlockType(var rt : M3Runtime; var o_blockType : IM3FuncType&) : M3Result {
    var _type : i64 = 0l
    var result = ReadLebSigned(rt.modules[rt.compilation.moduleIdx].wasm, _type, 33u, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    if (_type < 0l) {
        var valueType : u8 = 0u8
        result = NormalizeType(valueType, i8(_type))
        if (result != m3Err_none) {
            return result
        }
        // C: o->module->environment->retFuncTypes [valueType]; Eden: the runtime's embedded environment
        o_blockType = rt.environment.retFuncTypes[int(valueType)]
    } else {
        if (u64(_type) >= u64(rt.modules[rt.compilation.moduleIdx].numFuncTypes)) {
            return "func type out of bounds"
        }
        o_blockType = rt.modules[rt.compilation.moduleIdx].funcTypes[int(_type)]   // C: o->module->funcTypes [type]
    }
    return m3Err_none
}


def PreserveArgsAndLocals(var rt : M3Runtime) : M3Result {
    if (rt.compilation.stackIndex > rt.compilation.stackFirstDynamicIndex) {
        let numArgsAndLocals = GetFunctionNumArgsAndLocals(rt, rt.compilation.functionIdx)
        var i : u32 = 0u
        while (i < numArgsAndLocals) {
            let slot = GetSlotForStackIndex(rt, int(i))
            var preservedSlotNumber : int = c_slotUnused
            let result = FindReferencedLocalWithinCurrentBlock(rt, preservedSlotNumber, u32(slot))
            if (result != m3Err_none) {
                return result
            }
            if (preservedSlotNumber != slot) {
                let _type = GetStackTypeFromBottom(rt, int(i))
                d_m3Assert(_type != int(u8(M3ValueType.c_m3Type_none)))
                var op = "op_CopySlot_32"
                if (Is64BitType(u8(_type))) {
                    op = "op_CopySlot_64"
                }
                // Original C intentionally ignores EmitOp's result here.
                EmitOp(rt, op)
                EmitSlotOffset(rt, preservedSlotNumber)
                EmitSlotOffset(rt, slot)
            }
            i++
        }
    }
    return m3Err_none
}


def Compile_LoopOrBlock(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var result = PreserveRegisters(rt)
    if (result != m3Err_none) {
        return result
    }
    result = PreserveArgsAndLocals(rt)
    if (result != m3Err_none) {
        return result
    }
    var blockType : IM3FuncType = -1
    result = ReadBlockType(rt, blockType)
    if (result != m3Err_none) {
        return result
    }

    if (i_opcode == c_waOp_loop) {
        let numParams = int(GetFuncTypeNumParams(rt, blockType))
        if (numParams != 0) {
            let numValues = GetNumBlockValuesOnStack(rt)
            d_m3Assert(numValues >= numParams)
            if (numValues >= numParams) {
                let stackTop = GetStackTopIndex(rt) + 1
                var i = stackTop - numParams
                while (i < stackTop) {
                    let slot = GetSlotForStackIndex(rt, i)
                    let _type = GetStackTypeFromBottom(rt, i)
                    if (IsConstantSlot(rt, slot)) {
                        var newSlot : int = c_slotUnused
                        result = AllocateSlots(rt, newSlot, _type)
                        if (result != m3Err_none) {
                            return result
                        }
                        result = CopyStackIndexToSlot(rt, newSlot, i)
                        if (result != m3Err_none) {
                            return result
                        }
                        rt.compilation.wasmStack[i] = newSlot
                    }
                    i++
                }
            }
        }
        result = EmitOp(rt, "op_Loop")
        if (result != m3Err_none) {
            return result
        }
    }
    return CompileBlock(rt, blockType, i_opcode)
}


def CompileElseBlock(var rt : M3Runtime; var o_startPC : pc_t&; i_blockType : IM3FuncType) : M3Result {
    let savedPage = rt.compilation.page
    var elsePage : IM3CodePage = -1
    var result = AcquireCompilationCodePage(rt, elsePage)
    if (result != m3Err_none) {
        return result
    }
    o_startPC = GetPagePC(rt, elsePage)
    rt.compilation.page = elsePage
    result = CompileBlock(rt, i_blockType, c_waOp_else)
    if (result == m3Err_none) {
        result = EmitOp(rt, "op_Branch")
    }
    if (result == m3Err_none) {
        EmitPointer(rt, GetPagePC(rt, savedPage))
    }
    if (rt.compilation.page != savedPage) {
        ReleaseCompilationCodePage(rt)
    }
    rt.compilation.page = savedPage
    return result
}


def Compile_If(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var result = PreserveNonTopRegisters(rt)
    if (result != m3Err_none) {
        return result
    }
    result = PreserveArgsAndLocals(rt)
    if (result != m3Err_none) {
        return result
    }

    var op = "op_If_s"
    if (IsStackTopInRegister(rt)) {
        op = "op_If_r"
    }
    result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    result = EmitSlotNumOfStackTopAndPop(rt)
    if (result != m3Err_none) {
        return result
    }
    let pc : pc_t = ReservePointer(rt)   // C: pc_t * pc = (pc_t *) ReservePointer (o)

    var blockType : IM3FuncType = -1
    result = ReadBlockType(rt, blockType)
    if (result != m3Err_none) {
        return result
    }
    let stackIndex = rt.compilation.stackIndex
    result = CompileBlock(rt, blockType, i_opcode)
    if (result != m3Err_none) {
        return result
    }

    if (rt.compilation.previousOpcode == c_waOp_else) {
        rt.compilation.stackIndex = stackIndex
        var startPC : pc_t = -1
        result = CompileElseBlock(rt, startPC, blockType)
        if (result != m3Err_none) {
            return result
        }
        rt.code[pc] = u64(startPC)   // C: * pc = startPC
    } elif (int(GetFuncTypeNumResults(rt, blockType)) != 0) {
        rt.compilation.wasm = rt.compilation.wasm - 1   // C: o->wasm--; Eden: index arithmetic
        rt.compilation.stackIndex = stackIndex
        var startPC : pc_t = -1
        result = CompileElseBlock(rt, startPC, blockType)
        if (result != m3Err_none) {
            return result
        }
        rt.code[pc] = u64(startPC)   // C: * pc = startPC
    } else {
        rt.code[pc] = u64(GetPC(rt))   // C: * pc = GetPC (o)
    }
    return m3Err_none
}


def Compile_Select(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var slots : int[3] = fixed_array(c_slotUnused, c_slotUnused, c_slotUnused)
    let _type = GetStackTypeFromTop(rt, 1)
    var op : string = ""   // C: IM3Operation op = NULL
    var result : M3Result = m3Err_none

    if (IsFpType(u8(_type))) {
        if (!d_m3HasFloat) {
            return m3Err_unknownOpcode
        }
        if (!IsStackTopMinus1InRegister(rt) && !IsStackTopMinus2InRegister(rt)) {
            result = PreserveRegisterIfOccupied(rt, _type)
            if (result != m3Err_none) {
                return result
            }
        }
        let selectorInReg = IsStackTopInRegister(rt)
        slots[0] = GetStackTopSlotNumber(rt)
        result = Pop(rt)
        if (result != m3Err_none) {
            return result
        }
        var opIndex : u32 = 0u
        var i : u32 = 1u
        while (i <= 2u) {
            if (IsStackTopInRegister(rt)) {
                opIndex = i
            } else {
                slots[int(i)] = GetStackTopSlotNumber(rt)
            }
            result = Pop(rt)
            if (result != m3Err_none) {
                return result
            }
            i++
        }
        var selectorIndex : u32 = 0u
        if (selectorInReg) {
            selectorIndex = 1u
        }
        op = c_fpSelectOps[_type - int(u8(M3ValueType.c_m3Type_f32))][int(selectorIndex)][int(opIndex)]
    } elif (IsIntType(u8(_type))) {
        if (!IsStackTopInRegister(rt) && !IsStackTopMinus1InRegister(rt) && !IsStackTopMinus2InRegister(rt)) {
            result = PreserveRegisterIfOccupied(rt, _type)
            if (result != m3Err_none) {
                return result
            }
        }
        var opIndex : u32 = 3u
        var i : u32 = 0u
        while (i < 3u) {
            if (IsStackTopInRegister(rt)) {
                opIndex = i
            } else {
                slots[int(i)] = GetStackTopSlotNumber(rt)
            }
            result = Pop(rt)
            if (result != m3Err_none) {
                return result
            }
            i++
        }
        op = c_intSelectOps[_type - int(u8(M3ValueType.c_m3Type_i32))][int(opIndex)]
    } elif (!IsStackPolymorphic(rt)) {
        return m3Err_functionStackUnderrun
    }

    // Original C does not propagate EmitOp here.
    EmitOp(rt, op)
    var i : u32 = 0u
    while (i < 3u) {
        if (IsValidSlot(slots[int(i)])) {
            EmitSlotOffset(rt, slots[int(i)])
        }
        i++
    }
    return PushRegister(rt, _type)
}


def Compile_Drop(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    let result = Pop(rt)
    // compiled out under the active configuration: d_m3LogWasmStack == false
    return result
}


def Compile_Nop(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    return m3Err_none
}


def Compile_Unreachable(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var result = AddTrapRecord(rt)
    if (result != m3Err_none) {
        return result
    }
    result = EmitOp(rt, "op_Unreachable")
    if (result != m3Err_none) {
        return result
    }
    return SetStackPolymorphic(rt)
}


def Compile_Operator(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var opInfo = M3OpInfo()
    if (!GetOpInfo(i_opcode, opInfo)) {
        return m3Err_unknownOpcode
    }
    var result : M3Result = m3Err_none
    var op : int = c_opNull

    if (IsFpType(u8(GetStackTopType(rt))) && IsIntType(u8(opInfo._type))) {
        result = PreserveRegisterIfOccupied(rt, opInfo._type)
        if (result != m3Err_none) {
            return result
        }
    }

    if (opInfo.stackOffset == 0) {
        if (IsStackTopInRegister(rt)) {
            op = opInfo.operations[0]
        } else {
            result = PreserveRegisterIfOccupied(rt, opInfo._type)
            if (result != m3Err_none) {
                return result
            }
            op = opInfo.operations[1]
        }
    } else {
        if (IsStackTopInRegister(rt)) {
            op = opInfo.operations[0]
            if (IsStackTopMinus1InRegister(rt)) {
                d_m3Assert(i_opcode == c_waOp_store_f32 || i_opcode == c_waOp_store_f64)
                op = opInfo.operations[3]
            }
        } elif (IsStackTopMinus1InRegister(rt)) {
            op = opInfo.operations[1]
            if (IsNoOp(op)) {
                op = opInfo.operations[0]
            }
        } else {
            result = PreserveRegisterIfOccupied(rt, opInfo._type)
            if (result != m3Err_none) {
                return result
            }
            op = opInfo.operations[2]
        }
    }

    // C: if (op) ... ; an absent table entry is c_opNull here.
    if (!IsNoOp(op)) {
        result = EmitOp(rt, op)
        if (result != m3Err_none) {
            return result
        }
        result = EmitSlotNumOfStackTopAndPop(rt)
        if (result != m3Err_none) {
            return result
        }
        if (opInfo.stackOffset < 0) {
            result = EmitSlotNumOfStackTopAndPop(rt)
            if (result != m3Err_none) {
                return result
            }
        }
        if (opInfo._type != int(u8(M3ValueType.c_m3Type_none))) {
            result = PushRegister(rt, opInfo._type)
            if (result != m3Err_none) {
                return result
            }
        }
        return m3Err_none
    }

    // C (non-DEBUG): ErrorCompile ("no operation found for opcode", o, "%x", i_opcode)
    return ErrorCompile("no operation found for opcode", rt, "{int(i_opcode):x}")
}


def Compile_Convert(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var opInfo = M3OpInfo()
    if (!GetOpInfo(i_opcode, opInfo)) {
        return m3Err_unknownOpcode
    }
    let destInSlot = IsRegisterTypeAllocated(rt, opInfo._type)
    let sourceInSlot = IsStackTopInSlot(rt)
    var opIndex : u32 = 0u
    if (destInSlot) {
        opIndex += 2u
    }
    if (sourceInSlot) {
        opIndex++
    }
    let op = opInfo.operations[int(opIndex)]
    var result = EmitOp(rt, op)
    if (result != m3Err_none) {
        return result
    }
    result = EmitSlotNumOfStackTopAndPop(rt)
    if (result != m3Err_none) {
        return result
    }
    if (destInSlot) {
        return PushAllocatedSlotAndEmit(rt, opInfo._type)
    }
    return PushRegister(rt, opInfo._type)
}


def Compile_Load_Store(var rt : M3Runtime; i_opcode : m3opcode_t) : M3Result {
    var alignHint : u32 = 0u
    var memoryOffset : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, alignHint, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, memoryOffset, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }
    var opInfo = M3OpInfo()
    if (!GetOpInfo(i_opcode, opInfo)) {
        return m3Err_unknownOpcode
    }
    if (IsFpType(u8(opInfo._type))) {
        result = PreserveRegisterIfOccupied(rt, int(u8(M3ValueType.c_m3Type_f64)))
        if (result != m3Err_none) {
            return result
        }
    }
    result = Compile_Operator(rt, i_opcode)
    if (result != m3Err_none) {
        return result
    }
    EmitConstant32(rt, memoryOffset)
    return m3Err_none
}


// C: M3Result CompileRawFunction (IM3Module io_module, IM3Function io_function, const void * i_function, const void * i_userdata)
// Eden: i_function is the raw-call handle into rt.rawCalls (C: the M3RawCall
// pointer) and i_userdata the int token (C: void *); both are code words
// (DESIGN.md 4.4, 4.5), read back by op_CallRawFunction as handles.
def public CompileRawFunction(var rt : M3Runtime; io_module : IM3Module; io_function : IM3Function; i_function : int; i_userdata : int) : M3Result {
    d_m3Assert(rt.modules[io_module].runtime != -1)
    let page = AcquireCodePageWithCapacity(rt, 4u)   // C: AcquireCodePageWithCapacity (io_module->runtime, 4)
    if (page == -1) {
        return m3Err_mallocFailedCodePage
    }
    rt.functions[io_function].compiled = GetPagePC(rt, page)
    rt.functions[io_function].moduleIdx = io_module   // C: io_function->module = io_module
    // C: EmitWord (page, op_CallRawFunction) — the operation word, so m3_OpWord.
    EmitWord(rt, page, m3_OpWord("op_CallRawFunction"))
    EmitWord(rt, page, u64(i_function))    // C: EmitWord (page, i_function)
    EmitWord(rt, page, u64(io_function))   // C: EmitWord (page, io_function)
    EmitWord(rt, page, u64(i_userdata))    // C: EmitWord (page, i_userdata)
    ReleaseCodePage(rt, page)              // C: ReleaseCodePage (io_module->runtime, page)
    return m3Err_none
}


// ============================================================================
// Operation table records (C: the M3OP macro family)
// ============================================================================


// C preprocessor operation-list expansion, kept local to this table construction.
// Eden: the four operations are NAMES (the op_* of m3_exec, "" = C's NULL);
// the record keeps them in opNames and starts every index at c_opNull; the
// table builder m3_build_operations_table resolves the names through the
// op table.
def M3OP(name : string; stackOffset : int; _type : int; o0 : string; o1 : string; o2 : string; o3 : string; compiler : M3Compiler) : M3OpInfo {
    /* C: #define M3OP(NAME, ...) { __VA_ARGS__ } — the array literal becomes the fixed argument list above. */
    return M3OpInfo(stackOffset = stackOffset, _type = _type, opNames = fixed_array(o0, o1, o2, o3), operations = fixed_array(c_opNull, c_opNull, c_opNull, c_opNull), compiler = compiler)
}

def M3OP_RESERVED() : M3OpInfo {
    return M3OpInfo(stackOffset = 0, _type = int(u8(M3ValueType.c_m3Type_none)), opNames = fixed_array("", "", "", ""), operations = fixed_array(c_opNull, c_opNull, c_opNull, c_opNull), compiler = c_noCompiler)
}

def M3OP_F(name : string; stackOffset : int; _type : int; o0 : string; o1 : string; o2 : string; o3 : string; compiler : M3Compiler) : M3OpInfo {
    if (d_m3HasFloat) {
        return M3OP(name, stackOffset, _type, o0, o1, o2, o3, compiler)
    }
    if (d_m3NoFloatDynamic) {
        return M3OP(name, stackOffset, _type, "op_Unsupported", "op_Unsupported", "op_Unsupported", "op_Unsupported", compiler)
    }
    return M3OP_RESERVED()
}


// Eden: resolves the four op names of every row into op-table indices
// through g_opIndex (m3_exec); "" is C's NULL (c_opNull). An unknown name
// is a table bug and a d_m3Assert failure naming it (as m3_OpWord).
def private ResolveOperationNames(var io_rows : array<M3OpInfo>) {
    for (row in io_rows) {
        for (i in range(4)) {
            let name = row.opNames[i]
            if (empty(name)) {
                row.operations[i] = c_opNull
            } else {
                d_m3Assert(key_exists(g_opIndex, name), "m3_build_operations_table: not an m3_exec operation: {name}")
                row.operations[i] = g_opIndex[name]
            }
        }
    }
}


// C: `const M3OpInfo c_operations []` / `const M3OpInfo c_operationsFC []`,
// static initialisers of m3_compile.c (the release build: no names, no
// DEBUG rows). Eden (DESIGN.md 4.4a): the rows are pushed in C order with
// the op NAMES of the M3OP records, then every name is resolved through the
// op table of m3_exec (built first when it is still empty). The upstream
// port filled a fixed array guarded by c_operationsInitialized from
// m3_NewEnvironment; here the builder clears both arrays first, so a second
// call rebuilds the same tables (idempotent) and no flag is kept. C's NULL
// compiler is c_noCompiler, as upstream (IsNoCompiler reads both).
def public m3_build_operations_table() {
    if (m3_OpCount() == 0) {
        m3_build_op_table()
    }
    clear(c_operations)
    clear(c_operationsFC)
    reserve(c_operations, 253)
    reserve(c_operationsFC, 12)

    push(c_operations, M3OP("unreachable", 0, none, "op_Unreachable", "", "", "", @@Compile_Unreachable))   // 0x00
    push(c_operations, M3OP("nop", 0, none, "", "", "", "", @@Compile_Nop))   // 0x01
    push(c_operations, M3OP("block", 0, none, "", "", "", "", @@Compile_LoopOrBlock))   // 0x02
    push(c_operations, M3OP("loop", 0, none, "op_Loop", "", "", "", @@Compile_LoopOrBlock))   // 0x03
    push(c_operations, M3OP("if", -1, none, "", "", "", "", @@Compile_If))   // 0x04
    push(c_operations, M3OP("else", 0, none, "", "", "", "", @@Compile_Nop))   // 0x05
    push(c_operations, M3OP_RESERVED())   // 0x06
    push(c_operations, M3OP_RESERVED())   // 0x07
    push(c_operations, M3OP_RESERVED())   // 0x08
    push(c_operations, M3OP_RESERVED())   // 0x09
    push(c_operations, M3OP_RESERVED())   // 0x0a
    push(c_operations, M3OP("end", 0, none, "", "", "", "", @@Compile_End))   // 0x0b
    push(c_operations, M3OP("br", 0, none, "op_Branch", "", "", "", @@Compile_Branch))   // 0x0c
    push(c_operations, M3OP("br_if", -1, none, "op_BranchIf_r", "op_BranchIf_s", "", "", @@Compile_Branch))   // 0x0d
    push(c_operations, M3OP("br_table", -1, none, "op_BranchTable", "", "", "", @@Compile_BranchTable))   // 0x0e
    push(c_operations, M3OP("return", 0, any, "op_Return", "", "", "", @@Compile_Return))   // 0x0f
    push(c_operations, M3OP("call", 0, any, "op_Call", "", "", "", @@Compile_Call))   // 0x10
    push(c_operations, M3OP("call_indirect", 0, any, "op_CallIndirect", "", "", "", @@Compile_CallIndirect))   // 0x11
    push(c_operations, M3OP("return_call", 0, any, "", "", "", "", @@Compile_Call))   // 0x12
    push(c_operations, M3OP("return_call_indirect", 0, any, "", "", "", "", @@Compile_CallIndirect))   // 0x13
    push(c_operations, M3OP_RESERVED())   // 0x14
    push(c_operations, M3OP_RESERVED())   // 0x15
    push(c_operations, M3OP_RESERVED())   // 0x16
    push(c_operations, M3OP_RESERVED())   // 0x17
    push(c_operations, M3OP_RESERVED())   // 0x18
    push(c_operations, M3OP_RESERVED())   // 0x19
    push(c_operations, M3OP("drop", -1, none, "", "", "", "", @@Compile_Drop))   // 0x1a
    push(c_operations, M3OP("select", -2, any, "", "", "", "", @@Compile_Select))   // 0x1b
    push(c_operations, M3OP_RESERVED())   // 0x1c
    push(c_operations, M3OP_RESERVED())   // 0x1d
    push(c_operations, M3OP_RESERVED())   // 0x1e
    push(c_operations, M3OP_RESERVED())   // 0x1f
    push(c_operations, M3OP("local.get", 1, any, "", "", "", "", @@Compile_GetLocal))   // 0x20
    push(c_operations, M3OP("local.set", 1, none, "", "", "", "", @@Compile_SetLocal))   // 0x21
    push(c_operations, M3OP("local.tee", 0, any, "", "", "", "", @@Compile_SetLocal))   // 0x22
    push(c_operations, M3OP("global.get", 1, none, "", "", "", "", @@Compile_GetSetGlobal))   // 0x23
    push(c_operations, M3OP("global.set", 1, none, "", "", "", "", @@Compile_GetSetGlobal))   // 0x24
    push(c_operations, M3OP_RESERVED())   // 0x25
    push(c_operations, M3OP_RESERVED())   // 0x26
    push(c_operations, M3OP_RESERVED())   // 0x27
    push(c_operations, M3OP("i32.load", 0, i_32, "op_i32_Load_i32_r", "op_i32_Load_i32_s", "", "", @@Compile_Load_Store))   // 0x28
    push(c_operations, M3OP("i64.load", 0, i_64, "op_i64_Load_i64_r", "op_i64_Load_i64_s", "", "", @@Compile_Load_Store))   // 0x29
    push(c_operations, M3OP_F("f32.load", 0, f_32, "op_f32_Load_f32_r", "op_f32_Load_f32_s", "", "", @@Compile_Load_Store))   // 0x2a
    push(c_operations, M3OP_F("f64.load", 0, f_64, "op_f64_Load_f64_r", "op_f64_Load_f64_s", "", "", @@Compile_Load_Store))   // 0x2b
    push(c_operations, M3OP("i32.load8_s", 0, i_32, "op_i32_Load_i8_r", "op_i32_Load_i8_s", "", "", @@Compile_Load_Store))   // 0x2c
    push(c_operations, M3OP("i32.load8_u", 0, i_32, "op_i32_Load_u8_r", "op_i32_Load_u8_s", "", "", @@Compile_Load_Store))   // 0x2d
    push(c_operations, M3OP("i32.load16_s", 0, i_32, "op_i32_Load_i16_r", "op_i32_Load_i16_s", "", "", @@Compile_Load_Store))   // 0x2e
    push(c_operations, M3OP("i32.load16_u", 0, i_32, "op_i32_Load_u16_r", "op_i32_Load_u16_s", "", "", @@Compile_Load_Store))   // 0x2f
    push(c_operations, M3OP("i64.load8_s", 0, i_64, "op_i64_Load_i8_r", "op_i64_Load_i8_s", "", "", @@Compile_Load_Store))   // 0x30
    push(c_operations, M3OP("i64.load8_u", 0, i_64, "op_i64_Load_u8_r", "op_i64_Load_u8_s", "", "", @@Compile_Load_Store))   // 0x31
    push(c_operations, M3OP("i64.load16_s", 0, i_64, "op_i64_Load_i16_r", "op_i64_Load_i16_s", "", "", @@Compile_Load_Store))   // 0x32
    push(c_operations, M3OP("i64.load16_u", 0, i_64, "op_i64_Load_u16_r", "op_i64_Load_u16_s", "", "", @@Compile_Load_Store))   // 0x33
    push(c_operations, M3OP("i64.load32_s", 0, i_64, "op_i64_Load_i32_r", "op_i64_Load_i32_s", "", "", @@Compile_Load_Store))   // 0x34
    push(c_operations, M3OP("i64.load32_u", 0, i_64, "op_i64_Load_u32_r", "op_i64_Load_u32_s", "", "", @@Compile_Load_Store))   // 0x35
    push(c_operations, M3OP("i32.store", -2, none, "op_i32_Store_i32_rs", "op_i32_Store_i32_sr", "op_i32_Store_i32_ss", "", @@Compile_Load_Store))   // 0x36
    push(c_operations, M3OP("i64.store", -2, none, "op_i64_Store_i64_rs", "op_i64_Store_i64_sr", "op_i64_Store_i64_ss", "", @@Compile_Load_Store))   // 0x37
    push(c_operations, M3OP_F("f32.store", -2, none, "op_f32_Store_f32_rs", "op_f32_Store_f32_sr", "op_f32_Store_f32_ss", "op_f32_Store_f32_rr", @@Compile_Load_Store))   // 0x38
    push(c_operations, M3OP_F("f64.store", -2, none, "op_f64_Store_f64_rs", "op_f64_Store_f64_sr", "op_f64_Store_f64_ss", "op_f64_Store_f64_rr", @@Compile_Load_Store))   // 0x39
    push(c_operations, M3OP("i32.store8", -2, none, "op_i32_Store_u8_rs", "op_i32_Store_u8_sr", "op_i32_Store_u8_ss", "", @@Compile_Load_Store))   // 0x3a
    push(c_operations, M3OP("i32.store16", -2, none, "op_i32_Store_i16_rs", "op_i32_Store_i16_sr", "op_i32_Store_i16_ss", "", @@Compile_Load_Store))   // 0x3b
    push(c_operations, M3OP("i64.store8", -2, none, "op_i64_Store_u8_rs", "op_i64_Store_u8_sr", "op_i64_Store_u8_ss", "", @@Compile_Load_Store))   // 0x3c
    push(c_operations, M3OP("i64.store16", -2, none, "op_i64_Store_i16_rs", "op_i64_Store_i16_sr", "op_i64_Store_i16_ss", "", @@Compile_Load_Store))   // 0x3d
    push(c_operations, M3OP("i64.store32", -2, none, "op_i64_Store_i32_rs", "op_i64_Store_i32_sr", "op_i64_Store_i32_ss", "", @@Compile_Load_Store))   // 0x3e
    push(c_operations, M3OP("memory.size", 1, i_32, "op_MemSize", "", "", "", @@Compile_Memory_Size))   // 0x3f
    push(c_operations, M3OP("memory.grow", 1, i_32, "op_MemGrow", "", "", "", @@Compile_Memory_Grow))   // 0x40
    push(c_operations, M3OP("i32.const", 1, i_32, "op_Const32", "", "", "", @@Compile_Const_i32))   // 0x41
    push(c_operations, M3OP("i64.const", 1, i_64, "op_Const64", "", "", "", @@Compile_Const_i64))   // 0x42
    push(c_operations, M3OP_F("f32.const", 1, f_32, "", "", "", "", @@Compile_Const_f32))   // 0x43
    push(c_operations, M3OP_F("f64.const", 1, f_64, "", "", "", "", @@Compile_Const_f64))   // 0x44
    push(c_operations, M3OP("i32.eqz", 0, i_32, "op_i32_EqualToZero_r", "op_i32_EqualToZero_s", "", "", c_noCompiler))   // 0x45
    push(c_operations, M3OP("i32.eq", -1, i_32, "op_i32_Equal_rs", "", "op_i32_Equal_ss", "", c_noCompiler))   // 0x46
    push(c_operations, M3OP("i32.ne", -1, i_32, "op_i32_NotEqual_rs", "", "op_i32_NotEqual_ss", "", c_noCompiler))   // 0x47
    push(c_operations, M3OP("i32.lt_s", -1, i_32, "op_i32_LessThan_rs", "op_i32_LessThan_sr", "op_i32_LessThan_ss", "", c_noCompiler))   // 0x48
    push(c_operations, M3OP("i32.lt_u", -1, i_32, "op_u32_LessThan_rs", "op_u32_LessThan_sr", "op_u32_LessThan_ss", "", c_noCompiler))   // 0x49
    push(c_operations, M3OP("i32.gt_s", -1, i_32, "op_i32_GreaterThan_rs", "op_i32_GreaterThan_sr", "op_i32_GreaterThan_ss", "", c_noCompiler))   // 0x4a
    push(c_operations, M3OP("i32.gt_u", -1, i_32, "op_u32_GreaterThan_rs", "op_u32_GreaterThan_sr", "op_u32_GreaterThan_ss", "", c_noCompiler))   // 0x4b
    push(c_operations, M3OP("i32.le_s", -1, i_32, "op_i32_LessThanOrEqual_rs", "op_i32_LessThanOrEqual_sr", "op_i32_LessThanOrEqual_ss", "", c_noCompiler))   // 0x4c
    push(c_operations, M3OP("i32.le_u", -1, i_32, "op_u32_LessThanOrEqual_rs", "op_u32_LessThanOrEqual_sr", "op_u32_LessThanOrEqual_ss", "", c_noCompiler))   // 0x4d
    push(c_operations, M3OP("i32.ge_s", -1, i_32, "op_i32_GreaterThanOrEqual_rs", "op_i32_GreaterThanOrEqual_sr", "op_i32_GreaterThanOrEqual_ss", "", c_noCompiler))   // 0x4e
    push(c_operations, M3OP("i32.ge_u", -1, i_32, "op_u32_GreaterThanOrEqual_rs", "op_u32_GreaterThanOrEqual_sr", "op_u32_GreaterThanOrEqual_ss", "", c_noCompiler))   // 0x4f
    push(c_operations, M3OP("i64.eqz", 0, i_32, "op_i64_EqualToZero_r", "op_i64_EqualToZero_s", "", "", c_noCompiler))   // 0x50
    push(c_operations, M3OP("i64.eq", -1, i_32, "op_i64_Equal_rs", "", "op_i64_Equal_ss", "", c_noCompiler))   // 0x51
    push(c_operations, M3OP("i64.ne", -1, i_32, "op_i64_NotEqual_rs", "", "op_i64_NotEqual_ss", "", c_noCompiler))   // 0x52
    push(c_operations, M3OP("i64.lt_s", -1, i_32, "op_i64_LessThan_rs", "op_i64_LessThan_sr", "op_i64_LessThan_ss", "", c_noCompiler))   // 0x53
    push(c_operations, M3OP("i64.lt_u", -1, i_32, "op_u64_LessThan_rs", "op_u64_LessThan_sr", "op_u64_LessThan_ss", "", c_noCompiler))   // 0x54
    push(c_operations, M3OP("i64.gt_s", -1, i_32, "op_i64_GreaterThan_rs", "op_i64_GreaterThan_sr", "op_i64_GreaterThan_ss", "", c_noCompiler))   // 0x55
    push(c_operations, M3OP("i64.gt_u", -1, i_32, "op_u64_GreaterThan_rs", "op_u64_GreaterThan_sr", "op_u64_GreaterThan_ss", "", c_noCompiler))   // 0x56
    push(c_operations, M3OP("i64.le_s", -1, i_32, "op_i64_LessThanOrEqual_rs", "op_i64_LessThanOrEqual_sr", "op_i64_LessThanOrEqual_ss", "", c_noCompiler))   // 0x57
    push(c_operations, M3OP("i64.le_u", -1, i_32, "op_u64_LessThanOrEqual_rs", "op_u64_LessThanOrEqual_sr", "op_u64_LessThanOrEqual_ss", "", c_noCompiler))   // 0x58
    push(c_operations, M3OP("i64.ge_s", -1, i_32, "op_i64_GreaterThanOrEqual_rs", "op_i64_GreaterThanOrEqual_sr", "op_i64_GreaterThanOrEqual_ss", "", c_noCompiler))   // 0x59
    push(c_operations, M3OP("i64.ge_u", -1, i_32, "op_u64_GreaterThanOrEqual_rs", "op_u64_GreaterThanOrEqual_sr", "op_u64_GreaterThanOrEqual_ss", "", c_noCompiler))   // 0x5a
    push(c_operations, M3OP_F("f32.eq", -1, i_32, "op_f32_Equal_rs", "", "op_f32_Equal_ss", "", c_noCompiler))   // 0x5b
    push(c_operations, M3OP_F("f32.ne", -1, i_32, "op_f32_NotEqual_rs", "", "op_f32_NotEqual_ss", "", c_noCompiler))   // 0x5c
    push(c_operations, M3OP_F("f32.lt", -1, i_32, "op_f32_LessThan_rs", "op_f32_LessThan_sr", "op_f32_LessThan_ss", "", c_noCompiler))   // 0x5d
    push(c_operations, M3OP_F("f32.gt", -1, i_32, "op_f32_GreaterThan_rs", "op_f32_GreaterThan_sr", "op_f32_GreaterThan_ss", "", c_noCompiler))   // 0x5e
    push(c_operations, M3OP_F("f32.le", -1, i_32, "op_f32_LessThanOrEqual_rs", "op_f32_LessThanOrEqual_sr", "op_f32_LessThanOrEqual_ss", "", c_noCompiler))   // 0x5f
    push(c_operations, M3OP_F("f32.ge", -1, i_32, "op_f32_GreaterThanOrEqual_rs", "op_f32_GreaterThanOrEqual_sr", "op_f32_GreaterThanOrEqual_ss", "", c_noCompiler))   // 0x60
    push(c_operations, M3OP_F("f64.eq", -1, i_32, "op_f64_Equal_rs", "", "op_f64_Equal_ss", "", c_noCompiler))   // 0x61
    push(c_operations, M3OP_F("f64.ne", -1, i_32, "op_f64_NotEqual_rs", "", "op_f64_NotEqual_ss", "", c_noCompiler))   // 0x62
    push(c_operations, M3OP_F("f64.lt", -1, i_32, "op_f64_LessThan_rs", "op_f64_LessThan_sr", "op_f64_LessThan_ss", "", c_noCompiler))   // 0x63
    push(c_operations, M3OP_F("f64.gt", -1, i_32, "op_f64_GreaterThan_rs", "op_f64_GreaterThan_sr", "op_f64_GreaterThan_ss", "", c_noCompiler))   // 0x64
    push(c_operations, M3OP_F("f64.le", -1, i_32, "op_f64_LessThanOrEqual_rs", "op_f64_LessThanOrEqual_sr", "op_f64_LessThanOrEqual_ss", "", c_noCompiler))   // 0x65
    push(c_operations, M3OP_F("f64.ge", -1, i_32, "op_f64_GreaterThanOrEqual_rs", "op_f64_GreaterThanOrEqual_sr", "op_f64_GreaterThanOrEqual_ss", "", c_noCompiler))   // 0x66
    push(c_operations, M3OP("i32.clz", 0, i_32, "op_u32_Clz_r", "op_u32_Clz_s", "", "", c_noCompiler))   // 0x67
    push(c_operations, M3OP("i32.ctz", 0, i_32, "op_u32_Ctz_r", "op_u32_Ctz_s", "", "", c_noCompiler))   // 0x68
    push(c_operations, M3OP("i32.popcnt", 0, i_32, "op_u32_Popcnt_r", "op_u32_Popcnt_s", "", "", c_noCompiler))   // 0x69
    push(c_operations, M3OP("i32.add", -1, i_32, "op_i32_Add_rs", "", "op_i32_Add_ss", "", c_noCompiler))   // 0x6a
    push(c_operations, M3OP("i32.sub", -1, i_32, "op_i32_Subtract_rs", "op_i32_Subtract_sr", "op_i32_Subtract_ss", "", c_noCompiler))   // 0x6b
    push(c_operations, M3OP("i32.mul", -1, i_32, "op_i32_Multiply_rs", "", "op_i32_Multiply_ss", "", c_noCompiler))   // 0x6c
    push(c_operations, M3OP("i32.div_s", -1, i_32, "op_i32_Divide_rs", "op_i32_Divide_sr", "op_i32_Divide_ss", "", c_noCompiler))   // 0x6d
    push(c_operations, M3OP("i32.div_u", -1, i_32, "op_u32_Divide_rs", "op_u32_Divide_sr", "op_u32_Divide_ss", "", c_noCompiler))   // 0x6e
    push(c_operations, M3OP("i32.rem_s", -1, i_32, "op_i32_Remainder_rs", "op_i32_Remainder_sr", "op_i32_Remainder_ss", "", c_noCompiler))   // 0x6f
    push(c_operations, M3OP("i32.rem_u", -1, i_32, "op_u32_Remainder_rs", "op_u32_Remainder_sr", "op_u32_Remainder_ss", "", c_noCompiler))   // 0x70
    push(c_operations, M3OP("i32.and", -1, i_32, "op_u32_And_rs", "", "op_u32_And_ss", "", c_noCompiler))   // 0x71
    push(c_operations, M3OP("i32.or", -1, i_32, "op_u32_Or_rs", "", "op_u32_Or_ss", "", c_noCompiler))   // 0x72
    push(c_operations, M3OP("i32.xor", -1, i_32, "op_u32_Xor_rs", "", "op_u32_Xor_ss", "", c_noCompiler))   // 0x73
    push(c_operations, M3OP("i32.shl", -1, i_32, "op_u32_ShiftLeft_rs", "op_u32_ShiftLeft_sr", "op_u32_ShiftLeft_ss", "", c_noCompiler))   // 0x74
    push(c_operations, M3OP("i32.shr_s", -1, i_32, "op_i32_ShiftRight_rs", "op_i32_ShiftRight_sr", "op_i32_ShiftRight_ss", "", c_noCompiler))   // 0x75
    push(c_operations, M3OP("i32.shr_u", -1, i_32, "op_u32_ShiftRight_rs", "op_u32_ShiftRight_sr", "op_u32_ShiftRight_ss", "", c_noCompiler))   // 0x76
    push(c_operations, M3OP("i32.rotl", -1, i_32, "op_u32_Rotl_rs", "op_u32_Rotl_sr", "op_u32_Rotl_ss", "", c_noCompiler))   // 0x77
    push(c_operations, M3OP("i32.rotr", -1, i_32, "op_u32_Rotr_rs", "op_u32_Rotr_sr", "op_u32_Rotr_ss", "", c_noCompiler))   // 0x78
    push(c_operations, M3OP("i64.clz", 0, i_64, "op_u64_Clz_r", "op_u64_Clz_s", "", "", c_noCompiler))   // 0x79
    push(c_operations, M3OP("i64.ctz", 0, i_64, "op_u64_Ctz_r", "op_u64_Ctz_s", "", "", c_noCompiler))   // 0x7a
    push(c_operations, M3OP("i64.popcnt", 0, i_64, "op_u64_Popcnt_r", "op_u64_Popcnt_s", "", "", c_noCompiler))   // 0x7b
    push(c_operations, M3OP("i64.add", -1, i_64, "op_i64_Add_rs", "", "op_i64_Add_ss", "", c_noCompiler))   // 0x7c
    push(c_operations, M3OP("i64.sub", -1, i_64, "op_i64_Subtract_rs", "op_i64_Subtract_sr", "op_i64_Subtract_ss", "", c_noCompiler))   // 0x7d
    push(c_operations, M3OP("i64.mul", -1, i_64, "op_i64_Multiply_rs", "", "op_i64_Multiply_ss", "", c_noCompiler))   // 0x7e
    push(c_operations, M3OP("i64.div_s", -1, i_64, "op_i64_Divide_rs", "op_i64_Divide_sr", "op_i64_Divide_ss", "", c_noCompiler))   // 0x7f
    push(c_operations, M3OP("i64.div_u", -1, i_64, "op_u64_Divide_rs", "op_u64_Divide_sr", "op_u64_Divide_ss", "", c_noCompiler))   // 0x80
    push(c_operations, M3OP("i64.rem_s", -1, i_64, "op_i64_Remainder_rs", "op_i64_Remainder_sr", "op_i64_Remainder_ss", "", c_noCompiler))   // 0x81
    push(c_operations, M3OP("i64.rem_u", -1, i_64, "op_u64_Remainder_rs", "op_u64_Remainder_sr", "op_u64_Remainder_ss", "", c_noCompiler))   // 0x82
    push(c_operations, M3OP("i64.and", -1, i_64, "op_u64_And_rs", "", "op_u64_And_ss", "", c_noCompiler))   // 0x83
    push(c_operations, M3OP("i64.or", -1, i_64, "op_u64_Or_rs", "", "op_u64_Or_ss", "", c_noCompiler))   // 0x84
    push(c_operations, M3OP("i64.xor", -1, i_64, "op_u64_Xor_rs", "", "op_u64_Xor_ss", "", c_noCompiler))   // 0x85
    push(c_operations, M3OP("i64.shl", -1, i_64, "op_u64_ShiftLeft_rs", "op_u64_ShiftLeft_sr", "op_u64_ShiftLeft_ss", "", c_noCompiler))   // 0x86
    push(c_operations, M3OP("i64.shr_s", -1, i_64, "op_i64_ShiftRight_rs", "op_i64_ShiftRight_sr", "op_i64_ShiftRight_ss", "", c_noCompiler))   // 0x87
    push(c_operations, M3OP("i64.shr_u", -1, i_64, "op_u64_ShiftRight_rs", "op_u64_ShiftRight_sr", "op_u64_ShiftRight_ss", "", c_noCompiler))   // 0x88
    push(c_operations, M3OP("i64.rotl", -1, i_64, "op_u64_Rotl_rs", "op_u64_Rotl_sr", "op_u64_Rotl_ss", "", c_noCompiler))   // 0x89
    push(c_operations, M3OP("i64.rotr", -1, i_64, "op_u64_Rotr_rs", "op_u64_Rotr_sr", "op_u64_Rotr_ss", "", c_noCompiler))   // 0x8a
    push(c_operations, M3OP_F("f32.abs", 0, f_32, "op_f32_Abs_r", "op_f32_Abs_s", "", "", c_noCompiler))   // 0x8b
    push(c_operations, M3OP_F("f32.neg", 0, f_32, "op_f32_Negate_r", "op_f32_Negate_s", "", "", c_noCompiler))   // 0x8c
    push(c_operations, M3OP_F("f32.ceil", 0, f_32, "op_f32_Ceil_r", "op_f32_Ceil_s", "", "", c_noCompiler))   // 0x8d
    push(c_operations, M3OP_F("f32.floor", 0, f_32, "op_f32_Floor_r", "op_f32_Floor_s", "", "", c_noCompiler))   // 0x8e
    push(c_operations, M3OP_F("f32.trunc", 0, f_32, "op_f32_Trunc_r", "op_f32_Trunc_s", "", "", c_noCompiler))   // 0x8f
    push(c_operations, M3OP_F("f32.nearest", 0, f_32, "op_f32_Nearest_r", "op_f32_Nearest_s", "", "", c_noCompiler))   // 0x90
    push(c_operations, M3OP_F("f32.sqrt", 0, f_32, "op_f32_Sqrt_r", "op_f32_Sqrt_s", "", "", c_noCompiler))   // 0x91
    push(c_operations, M3OP_F("f32.add", -1, f_32, "op_f32_Add_rs", "", "op_f32_Add_ss", "", c_noCompiler))   // 0x92
    push(c_operations, M3OP_F("f32.sub", -1, f_32, "op_f32_Subtract_rs", "op_f32_Subtract_sr", "op_f32_Subtract_ss", "", c_noCompiler))   // 0x93
    push(c_operations, M3OP_F("f32.mul", -1, f_32, "op_f32_Multiply_rs", "", "op_f32_Multiply_ss", "", c_noCompiler))   // 0x94
    push(c_operations, M3OP_F("f32.div", -1, f_32, "op_f32_Divide_rs", "op_f32_Divide_sr", "op_f32_Divide_ss", "", c_noCompiler))   // 0x95
    push(c_operations, M3OP_F("f32.min", -1, f_32, "op_f32_Min_rs", "", "op_f32_Min_ss", "", c_noCompiler))   // 0x96
    push(c_operations, M3OP_F("f32.max", -1, f_32, "op_f32_Max_rs", "", "op_f32_Max_ss", "", c_noCompiler))   // 0x97
    push(c_operations, M3OP_F("f32.copysign", -1, f_32, "op_f32_CopySign_rs", "op_f32_CopySign_sr", "op_f32_CopySign_ss", "", c_noCompiler))   // 0x98
    push(c_operations, M3OP_F("f64.abs", 0, f_64, "op_f64_Abs_r", "op_f64_Abs_s", "", "", c_noCompiler))   // 0x99
    push(c_operations, M3OP_F("f64.neg", 0, f_64, "op_f64_Negate_r", "op_f64_Negate_s", "", "", c_noCompiler))   // 0x9a
    push(c_operations, M3OP_F("f64.ceil", 0, f_64, "op_f64_Ceil_r", "op_f64_Ceil_s", "", "", c_noCompiler))   // 0x9b
    push(c_operations, M3OP_F("f64.floor", 0, f_64, "op_f64_Floor_r", "op_f64_Floor_s", "", "", c_noCompiler))   // 0x9c
    push(c_operations, M3OP_F("f64.trunc", 0, f_64, "op_f64_Trunc_r", "op_f64_Trunc_s", "", "", c_noCompiler))   // 0x9d
    push(c_operations, M3OP_F("f64.nearest", 0, f_64, "op_f64_Nearest_r", "op_f64_Nearest_s", "", "", c_noCompiler))   // 0x9e
    push(c_operations, M3OP_F("f64.sqrt", 0, f_64, "op_f64_Sqrt_r", "op_f64_Sqrt_s", "", "", c_noCompiler))   // 0x9f
    push(c_operations, M3OP_F("f64.add", -1, f_64, "op_f64_Add_rs", "", "op_f64_Add_ss", "", c_noCompiler))   // 0xa0
    push(c_operations, M3OP_F("f64.sub", -1, f_64, "op_f64_Subtract_rs", "op_f64_Subtract_sr", "op_f64_Subtract_ss", "", c_noCompiler))   // 0xa1
    push(c_operations, M3OP_F("f64.mul", -1, f_64, "op_f64_Multiply_rs", "", "op_f64_Multiply_ss", "", c_noCompiler))   // 0xa2
    push(c_operations, M3OP_F("f64.div", -1, f_64, "op_f64_Divide_rs", "op_f64_Divide_sr", "op_f64_Divide_ss", "", c_noCompiler))   // 0xa3
    push(c_operations, M3OP_F("f64.min", -1, f_64, "op_f64_Min_rs", "", "op_f64_Min_ss", "", c_noCompiler))   // 0xa4
    push(c_operations, M3OP_F("f64.max", -1, f_64, "op_f64_Max_rs", "", "op_f64_Max_ss", "", c_noCompiler))   // 0xa5
    push(c_operations, M3OP_F("f64.copysign", -1, f_64, "op_f64_CopySign_rs", "op_f64_CopySign_sr", "op_f64_CopySign_ss", "", c_noCompiler))   // 0xa6
    push(c_operations, M3OP("i32.wrap/i64", 0, i_32, "op_i32_Wrap_i64_r", "op_i32_Wrap_i64_s", "", "", c_noCompiler))   // 0xa7
    push(c_operations, M3OP_F("i32.trunc_s/f32", 0, i_32, "op_i32_Trunc_f32_r_r", "op_i32_Trunc_f32_r_s", "op_i32_Trunc_f32_s_r", "op_i32_Trunc_f32_s_s", @@Compile_Convert))   // 0xa8
    push(c_operations, M3OP_F("i32.trunc_u/f32", 0, i_32, "op_u32_Trunc_f32_r_r", "op_u32_Trunc_f32_r_s", "op_u32_Trunc_f32_s_r", "op_u32_Trunc_f32_s_s", @@Compile_Convert))   // 0xa9
    push(c_operations, M3OP_F("i32.trunc_s/f64", 0, i_32, "op_i32_Trunc_f64_r_r", "op_i32_Trunc_f64_r_s", "op_i32_Trunc_f64_s_r", "op_i32_Trunc_f64_s_s", @@Compile_Convert))   // 0xaa
    push(c_operations, M3OP_F("i32.trunc_u/f64", 0, i_32, "op_u32_Trunc_f64_r_r", "op_u32_Trunc_f64_r_s", "op_u32_Trunc_f64_s_r", "op_u32_Trunc_f64_s_s", @@Compile_Convert))   // 0xab
    push(c_operations, M3OP("i64.extend_s/i32", 0, i_64, "op_i64_Extend_i32_r", "op_i64_Extend_i32_s", "", "", c_noCompiler))   // 0xac
    push(c_operations, M3OP("i64.extend_u/i32", 0, i_64, "op_i64_Extend_u32_r", "op_i64_Extend_u32_s", "", "", c_noCompiler))   // 0xad
    push(c_operations, M3OP_F("i64.trunc_s/f32", 0, i_64, "op_i64_Trunc_f32_r_r", "op_i64_Trunc_f32_r_s", "op_i64_Trunc_f32_s_r", "op_i64_Trunc_f32_s_s", @@Compile_Convert))   // 0xae
    push(c_operations, M3OP_F("i64.trunc_u/f32", 0, i_64, "op_u64_Trunc_f32_r_r", "op_u64_Trunc_f32_r_s", "op_u64_Trunc_f32_s_r", "op_u64_Trunc_f32_s_s", @@Compile_Convert))   // 0xaf
    push(c_operations, M3OP_F("i64.trunc_s/f64", 0, i_64, "op_i64_Trunc_f64_r_r", "op_i64_Trunc_f64_r_s", "op_i64_Trunc_f64_s_r", "op_i64_Trunc_f64_s_s", @@Compile_Convert))   // 0xb0
    push(c_operations, M3OP_F("i64.trunc_u/f64", 0, i_64, "op_u64_Trunc_f64_r_r", "op_u64_Trunc_f64_r_s", "op_u64_Trunc_f64_s_r", "op_u64_Trunc_f64_s_s", @@Compile_Convert))   // 0xb1
    push(c_operations, M3OP_F("f32.convert_s/i32", 0, f_32, "op_f32_Convert_i32_r_r", "op_f32_Convert_i32_r_s", "op_f32_Convert_i32_s_r", "op_f32_Convert_i32_s_s", @@Compile_Convert))   // 0xb2
    push(c_operations, M3OP_F("f32.convert_u/i32", 0, f_32, "op_f32_Convert_u32_r_r", "op_f32_Convert_u32_r_s", "op_f32_Convert_u32_s_r", "op_f32_Convert_u32_s_s", @@Compile_Convert))   // 0xb3
    push(c_operations, M3OP_F("f32.convert_s/i64", 0, f_32, "op_f32_Convert_i64_r_r", "op_f32_Convert_i64_r_s", "op_f32_Convert_i64_s_r", "op_f32_Convert_i64_s_s", @@Compile_Convert))   // 0xb4
    push(c_operations, M3OP_F("f32.convert_u/i64", 0, f_32, "op_f32_Convert_u64_r_r", "op_f32_Convert_u64_r_s", "op_f32_Convert_u64_s_r", "op_f32_Convert_u64_s_s", @@Compile_Convert))   // 0xb5
    push(c_operations, M3OP_F("f32.demote/f64", 0, f_32, "op_f32_Demote_f64_r", "op_f32_Demote_f64_s", "", "", c_noCompiler))   // 0xb6
    push(c_operations, M3OP_F("f64.convert_s/i32", 0, f_64, "op_f64_Convert_i32_r_r", "op_f64_Convert_i32_r_s", "op_f64_Convert_i32_s_r", "op_f64_Convert_i32_s_s", @@Compile_Convert))   // 0xb7
    push(c_operations, M3OP_F("f64.convert_u/i32", 0, f_64, "op_f64_Convert_u32_r_r", "op_f64_Convert_u32_r_s", "op_f64_Convert_u32_s_r", "op_f64_Convert_u32_s_s", @@Compile_Convert))   // 0xb8
    push(c_operations, M3OP_F("f64.convert_s/i64", 0, f_64, "op_f64_Convert_i64_r_r", "op_f64_Convert_i64_r_s", "op_f64_Convert_i64_s_r", "op_f64_Convert_i64_s_s", @@Compile_Convert))   // 0xb9
    push(c_operations, M3OP_F("f64.convert_u/i64", 0, f_64, "op_f64_Convert_u64_r_r", "op_f64_Convert_u64_r_s", "op_f64_Convert_u64_s_r", "op_f64_Convert_u64_s_s", @@Compile_Convert))   // 0xba
    push(c_operations, M3OP_F("f64.promote/f32", 0, f_64, "op_f64_Promote_f32_r", "op_f64_Promote_f32_s", "", "", c_noCompiler))   // 0xbb
    push(c_operations, M3OP_F("i32.reinterpret/f32", 0, i_32, "op_i32_Reinterpret_f32_r_r", "op_i32_Reinterpret_f32_r_s", "op_i32_Reinterpret_f32_s_r", "op_i32_Reinterpret_f32_s_s", @@Compile_Convert))   // 0xbc
    push(c_operations, M3OP_F("i64.reinterpret/f64", 0, i_64, "op_i64_Reinterpret_f64_r_r", "op_i64_Reinterpret_f64_r_s", "op_i64_Reinterpret_f64_s_r", "op_i64_Reinterpret_f64_s_s", @@Compile_Convert))   // 0xbd
    push(c_operations, M3OP_F("f32.reinterpret/i32", 0, f_32, "op_f32_Reinterpret_i32_r_r", "op_f32_Reinterpret_i32_r_s", "op_f32_Reinterpret_i32_s_r", "op_f32_Reinterpret_i32_s_s", @@Compile_Convert))   // 0xbe
    push(c_operations, M3OP_F("f64.reinterpret/i64", 0, f_64, "op_f64_Reinterpret_i64_r_r", "op_f64_Reinterpret_i64_r_s", "op_f64_Reinterpret_i64_s_r", "op_f64_Reinterpret_i64_s_s", @@Compile_Convert))   // 0xbf
    push(c_operations, M3OP("i32.extend8_s", 0, i_32, "op_i32_Extend8_s_r", "op_i32_Extend8_s_s", "", "", c_noCompiler))   // 0xc0
    push(c_operations, M3OP("i32.extend16_s", 0, i_32, "op_i32_Extend16_s_r", "op_i32_Extend16_s_s", "", "", c_noCompiler))   // 0xc1
    push(c_operations, M3OP("i64.extend8_s", 0, i_64, "op_i64_Extend8_s_r", "op_i64_Extend8_s_s", "", "", c_noCompiler))   // 0xc2
    push(c_operations, M3OP("i64.extend16_s", 0, i_64, "op_i64_Extend16_s_r", "op_i64_Extend16_s_s", "", "", c_noCompiler))   // 0xc3
    push(c_operations, M3OP("i64.extend32_s", 0, i_64, "op_i64_Extend32_s_r", "op_i64_Extend32_s_s", "", "", c_noCompiler))   // 0xc4

    // C: the d_m3DebugOp / d_m3DebugTypedOp rows that follow 0xc4 exist only
    // under `#ifdef DEBUG` for code-page logging ("the order doesn't matter").
    // In the release build the designated initialiser for 0xfc leaves
    // 0xc5..0xfb zero-filled: no operations, no compiler; every wasm opcode
    // in this range is invalid. Eden: the zero fill up to the designated
    // index is a loop of M3OP_RESERVED rows (upstream: one line per row).
    while (length(c_operations) < int(c_waOp_extended)) {
        push(c_operations, M3OP_RESERVED())   // 0xc5 .. 0xfb
    }

    // C: `# if d_m3CascadedOpcodes  [c_waOp_extended] = M3OP ("0xFC", ...)`
    push(c_operations, M3OP("0xFC", 0, int(u8(M3ValueType.c_m3Type_unknown)), "", "", "", "", @@Compile_ExtendedOpcode))   // 0xfc

    push(c_operationsFC, M3OP_F("i32.trunc_s:sat/f32", 0, i_32, "op_i32_TruncSat_f32_r_r", "op_i32_TruncSat_f32_r_s", "op_i32_TruncSat_f32_s_r", "op_i32_TruncSat_f32_s_s", @@Compile_Convert))   // 0x00
    push(c_operationsFC, M3OP_F("i32.trunc_u:sat/f32", 0, i_32, "op_u32_TruncSat_f32_r_r", "op_u32_TruncSat_f32_r_s", "op_u32_TruncSat_f32_s_r", "op_u32_TruncSat_f32_s_s", @@Compile_Convert))   // 0x01
    push(c_operationsFC, M3OP_F("i32.trunc_s:sat/f64", 0, i_32, "op_i32_TruncSat_f64_r_r", "op_i32_TruncSat_f64_r_s", "op_i32_TruncSat_f64_s_r", "op_i32_TruncSat_f64_s_s", @@Compile_Convert))   // 0x02
    push(c_operationsFC, M3OP_F("i32.trunc_u:sat/f64", 0, i_32, "op_u32_TruncSat_f64_r_r", "op_u32_TruncSat_f64_r_s", "op_u32_TruncSat_f64_s_r", "op_u32_TruncSat_f64_s_s", @@Compile_Convert))   // 0x03
    push(c_operationsFC, M3OP_F("i64.trunc_s:sat/f32", 0, i_64, "op_i64_TruncSat_f32_r_r", "op_i64_TruncSat_f32_r_s", "op_i64_TruncSat_f32_s_r", "op_i64_TruncSat_f32_s_s", @@Compile_Convert))   // 0x04
    push(c_operationsFC, M3OP_F("i64.trunc_u:sat/f32", 0, i_64, "op_u64_TruncSat_f32_r_r", "op_u64_TruncSat_f32_r_s", "op_u64_TruncSat_f32_s_r", "op_u64_TruncSat_f32_s_s", @@Compile_Convert))   // 0x05
    push(c_operationsFC, M3OP_F("i64.trunc_s:sat/f64", 0, i_64, "op_i64_TruncSat_f64_r_r", "op_i64_TruncSat_f64_r_s", "op_i64_TruncSat_f64_s_r", "op_i64_TruncSat_f64_s_s", @@Compile_Convert))   // 0x06
    push(c_operationsFC, M3OP_F("i64.trunc_u:sat/f64", 0, i_64, "op_u64_TruncSat_f64_r_r", "op_u64_TruncSat_f64_r_s", "op_u64_TruncSat_f64_s_r", "op_u64_TruncSat_f64_s_s", @@Compile_Convert))   // 0x07
    push(c_operationsFC, M3OP_RESERVED())   // 0x08
    push(c_operationsFC, M3OP_RESERVED())   // 0x09
    push(c_operationsFC, M3OP("memory.copy", 0, none, "", "", "", "", @@Compile_Memory_CopyFill))   // 0x0a
    push(c_operationsFC, M3OP("memory.fill", 0, none, "", "", "", "", @@Compile_Memory_CopyFill))   // 0x0b

    d_m3Assert(length(c_operations) == 253, "c_operations has C's 253 rows (0x00 .. 0xfc)")
    d_m3Assert(length(c_operationsFC) == 12, "c_operationsFC has C's 12 rows")

    // Eden: the op names become op-table indices (DESIGN.md 4.4a)
    ResolveOperationNames(c_operations)
    ResolveOperationNames(c_operationsFC)
}


// C: IM3OpInfo GetOpInfo (m3opcode_t opcode) — a pointer into the table, or
// NULL past it. Eden: copies the row into o_opInfo and returns whether it
// exists (the tables are empty until m3_build_operations_table runs, so
// every opcode is then "past the table", C's NULL).
def public GetOpInfo(opcode : m3opcode_t; var o_opInfo : M3OpInfo&) : bool {
    let opcodeValue = int(opcode)
    let prefix = opcodeValue >> 8
    if (prefix == 0) {
        if (opcodeValue < length(c_operations)) {   // C: opcode < M3_COUNT_OF (c_operations)
            o_opInfo = c_operations[opcodeValue]
            return true
        }
    } elif (prefix == int(c_waOp_extended)) {
        let extended = opcodeValue & 0xff
        if (extended < length(c_operationsFC)) {   // C: opcode < M3_COUNT_OF (c_operationsFC)
            o_opInfo = c_operationsFC[extended]
            return true
        }
    }
    return false
}


// ============================================================================
// Block and function compilation
// ============================================================================


def CompileBlockStatements(var rt : M3Runtime) : M3Result {
    var validEnd = false
    while (rt.compilation.wasm < rt.compilation.wasmEnd) {
        // compiled out under the active configuration: d_m3EnableOpTracing == false

        var opcode : m3opcode_t = m3opcode_t(0)
        rt.compilation.lastOpcodeStart = rt.compilation.wasm
        var result = Read_opcode(rt.modules[rt.compilation.moduleIdx].wasm, opcode, rt.compilation.wasm, rt.compilation.wasmEnd)
        if (result != m3Err_none) {
            return result
        }
        // compiled out under the active configuration: opcode logging disabled

        if (rt.compilation.functionIdx == -1) {
            let isConst = opcode == c_waOp_i32_const || opcode == c_waOp_i64_const || opcode == c_waOp_f32_const || opcode == c_waOp_f64_const
            let allowed = isConst || opcode == c_waOp_getGlobal || opcode == c_waOp_end
            if (!allowed) {
                return m3Err_restrictedOpcode
            }
        }

        var opinfo = M3OpInfo()
        if (!GetOpInfo(opcode, opinfo)) {
            return ErrorCompile(m3Err_unknownOpcode, rt, "opcode '{int(opcode):x}' not available")
        }
        if (!IsNoCompiler(opinfo.compiler)) {
            result = invoke(opinfo.compiler, rt, opcode)
        } else {
            result = Compile_Operator(rt, opcode)
        }
        if (result != m3Err_none) {
            return result
        }

        rt.compilation.previousOpcode = opcode
        if (opcode == c_waOp_else) {
            if (rt.compilation._block.opcode != c_waOp_if) {
                return m3Err_wasmMalformed
            }
            validEnd = true
            break
        } elif (opcode == c_waOp_end) {
            validEnd = true
            break
        }
    }
    if (!validEnd) {
        return m3Err_wasmMalformed
    }
    return m3Err_none
}


def PushBlockResults(var rt : M3Runtime) : M3Result {
    let numResults = int(GetFuncTypeNumResults(rt, rt.compilation._block.typeIdx))
    var i : int = 0
    while (i < numResults) {
        let _type : int = int(GetFuncTypeResultType(rt, rt.compilation._block.typeIdx, u16(i)))
        var result : M3Result = m3Err_none
        if (i == numResults - 1 && IsFpType(u8(_type))) {
            result = PushRegister(rt, _type)
        } else {
            result = PushAllocatedSlot(rt, _type)
        }
        if (result != m3Err_none) {
            return result
        }
        i++
    }
    return m3Err_none
}


def CompileBlock(var rt : M3Runtime; i_blockType : IM3FuncType; i_blockOpcode : m3opcode_t) : M3Result {
    d_m3Assert(!IsRegisterAllocated(rt, 0u))
    d_m3Assert(!IsRegisterAllocated(rt, 1u))

    // C: M3CompilationScope outerScope = o->block; IM3CompilationScope block = & o->block;
    //    block->outer = & outerScope;
    // Eden: the enclosing scope is pushed on the scope stack and `_block`
    // stays the current one; `outer` is its index (see the header)
    push(rt.compilation.scopeStack, rt.compilation._block)
    let outerScope = length(rt.compilation.scopeStack) - 1
    rt.compilation._block.outer = outerScope
    rt.compilation._block.pc = GetPagePC(rt, rt.compilation.page)
    rt.compilation._block.patches = -1
    rt.compilation._block.typeIdx = i_blockType
    rt.compilation._block.depth++
    rt.compilation._block.opcode = i_blockOpcode

    var stackIndex = rt.compilation.stackIndex
    let numParams = int(GetFuncTypeNumParams(rt, i_blockType))

    if (i_blockOpcode != c_waOp_else) {
        var i : int = 0
        while (i < numParams) {
            let _type : int = int(GetFuncTypeParamType(rt, i_blockType, u16(numParams - 1 - i)))
            let result = PopType(rt, _type)
            if (result != m3Err_none) {
                return result
            }
            i++
        }
    } else {
        if (IsStackPolymorphic(rt) && rt.compilation._block.blockStackIndex + numParams > rt.compilation.stackIndex) {
            rt.compilation.stackIndex = rt.compilation._block.blockStackIndex
        } else {
            rt.compilation.stackIndex -= numParams
        }
    }

    let paramIndex = rt.compilation.stackIndex
    rt.compilation._block.exitStackIndex = paramIndex
    rt.compilation.stackIndex = stackIndex

    // These three calls are deliberately unchecked in the C source.
    PushBlockResults(rt)
    stackIndex = rt.compilation.stackIndex
    var numResults = int(GetFuncTypeNumResults(rt, i_blockType))
    while (numResults != 0) {
        Pop(rt)
        numResults--
    }
    // C's while(numResults--) performs one final unsigned decrement on exit.
    numResults = int(0xffff)

    rt.compilation._block.blockStackIndex = stackIndex
    rt.compilation.stackIndex = stackIndex

    var i : int = 0
    while (i < numParams) {
        let _type : int = int(GetFuncTypeParamType(rt, i_blockType, u16(i)))
        let slot = GetSlotForStackIndex(rt, paramIndex + i)
        Push(rt, _type, slot)
        if (slot >= rt.compilation.slotFirstDynamicIndex && slot != c_slotUnused) {
            let result = MarkSlotsAllocatedByType(rt, slot, _type)
            if (result != m3Err_none) {
                return result
            }
        }
        i++
    }

    var result = CompileBlockStatements(rt)
    if (result != m3Err_none) {
        return result
    }
    result = ValidateBlockEnd(rt)
    if (result != m3Err_none) {
        return result
    }

    if (rt.compilation.functionIdx != -1) {
        if (!IsStackPolymorphic(rt)) {
            result = ResolveBlockResults(rt, CurrentScope(rt), false)   // C: ResolveBlockResults (o, & o->block, false)
            if (result != m3Err_none) {
                return result
            }
        }
        result = UnwindBlockStack(rt)
        if (result != m3Err_none) {
            return result
        }

        if (!((i_blockOpcode == c_waOp_if && numResults != 0) || rt.compilation.previousOpcode == c_waOp_else)) {
            rt.compilation.stackIndex = rt.compilation._block.exitStackIndex
            result = PushBlockResults(rt)
            if (result != m3Err_none) {
                return result
            }
        }
    }

    PatchBranches(rt)
    // C: o->block = outerScope; Eden: the enclosing scope comes back off the stack
    rt.compilation._block = rt.compilation.scopeStack[outerScope]
    pop(rt.compilation.scopeStack)
    return m3Err_none
}


def CompileLocals(var rt : M3Runtime) : M3Result {
    var numLocals : u32 = 0u
    var numLocalBlocks : u32 = 0u
    var result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, numLocalBlocks, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result != m3Err_none) {
        return result
    }

    var l : u32 = 0u
    while (l < numLocalBlocks) {
        var varCount : u32 = 0u
        var waType : i8 = i8(0)
        var localType : u8 = 0u8
        result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, varCount, rt.compilation.wasm, rt.compilation.wasmEnd)
        if (result != m3Err_none) {
            return result
        }
        result = ReadLEB_i7(rt.modules[rt.compilation.moduleIdx].wasm, waType, rt.compilation.wasm, rt.compilation.wasmEnd)
        if (result != m3Err_none) {
            return result
        }
        result = NormalizeType(localType, waType)
        if (result != m3Err_none) {
            return result
        }
        numLocals += varCount
        while (varCount != 0u) {
            result = PushAllocatedSlot(rt, int(localType))
            if (result != m3Err_none) {
                return result
            }
            varCount--
        }
        l++
    }

    if (rt.compilation.functionIdx != -1) {
        rt.functions[rt.compilation.functionIdx].numLocals = u16(numLocals)
    }
    return m3Err_none
}


def ReserveConstants(var rt : M3Runtime) : M3Result {
    var numConstantSlots : int = 0
    var wa = rt.compilation.wasm   // C: bytes_t wa = o->wasm; Eden: an index
    while (wa < rt.compilation.wasmEnd) {
        let code : m3opcode_t = m3opcode_t(rt.modules[rt.compilation.moduleIdx].wasm[wa])   // C: * wa++
        wa++
        var addSlots : int = 0
        if (code == c_waOp_i32_const || code == c_waOp_f32_const) {
            addSlots = 1
        } elif (code == c_waOp_i64_const || code == c_waOp_f64_const) {
            addSlots = GetTypeNumSlots(int(u8(M3ValueType.c_m3Type_i64)))
        }
        if (numConstantSlots + addSlots >= int(d_m3MaxConstantTableSize)) {
            break
        }
        numConstantSlots += addSlots
    }

    AlignSlotToType(numConstantSlots, int(u8(M3ValueType.c_m3Type_i64)))
    rt.compilation.slotFirstDynamicIndex = rt.compilation.slotFirstConstIndex + numConstantSlots
    if (rt.compilation.slotFirstDynamicIndex >= int(d_m3MaxFunctionSlots)) {
        return m3Err_functionStackOverflow
    }
    return m3Err_none
}


// C: M3Result CompileFunction (IM3Function io_function)
// Eden: takes the runtime (C: io_function->module->runtime) and the function
// handle; the target of m3_exec's CompileFunctionHook.
def public CompileFunction(var rt : M3Runtime; io_function : IM3Function) : M3Result {
    if (rt.functions[io_function].wasm == -1) {
        return "function body is missing"
    }

    let funcType = rt.functions[io_function].funcTypeIdx

    // C: IM3Runtime runtime = io_function->module->runtime; IM3Compilation o = & runtime->compilation;
    //    memset (o, 0x0, sizeof (M3Compilation));
    // Eden: the runtime is rt, its compilation is reset to the defaults
    rt.compilation <- M3Compilation()
    d_m3Assert(d_m3MaxFunctionSlots >= d_m3MaxFunctionStackHeight * ((d_m3Use32BitSlots ? 1u : 0u) + 1u))   // need twice as many slots in 32-bit mode
    rt.compilation.runtime = 0   // Eden: this runtime (C: o->runtime = runtime)
    rt.compilation.moduleIdx = rt.functions[io_function].moduleIdx
    rt.compilation.functionIdx = io_function
    rt.compilation.wasm = rt.functions[io_function].wasm
    rt.compilation.wasmEnd = rt.functions[io_function].wasmEnd
    rt.compilation._block.typeIdx = funcType

    var result : M3Result = m3Err_none
    var size : u32 = 0u
    var pc : pc_t = -1

    // skip over code size. the end was already calculated during parse phase
    result = ReadLEB_u32(rt.modules[rt.compilation.moduleIdx].wasm, size, rt.compilation.wasm, rt.compilation.wasmEnd)
    if (result == m3Err_none) {
        d_m3Assert(size == u32(rt.compilation.wasmEnd - rt.compilation.wasm))
        result = AcquireCompilationCodePage(rt, rt.compilation.page)
    }
    if (result == m3Err_none) {
        pc = GetPagePC(rt, rt.compilation.page)

        let numRetSlots = int(GetFunctionNumReturns(rt, rt.compilation.functionIdx)) * c_ioSlotCount
        var i : int = 0
        while (i < numRetSlots) {
            MarkSlotAllocated(rt, i)
            i++
        }
        rt.functions[rt.compilation.functionIdx].numRetSlots = u16(numRetSlots)
        rt.compilation.slotFirstDynamicIndex = numRetSlots

        let numArgs = int(GetFunctionNumArgs(rt, rt.compilation.functionIdx))
        // push the arg types to the type stack
        i = 0
        while (i < numArgs && result == m3Err_none) {
            let _type = GetFunctionArgType(rt, rt.compilation.functionIdx, u32(i))
            result = PushAllocatedSlot(rt, int(_type))
            if (result == m3Err_none) {
                // prevent allocator fill-in
                rt.compilation.slotFirstDynamicIndex += c_ioSlotCount
            }
            i++
        }

        if (result == m3Err_none) {
            rt.compilation.slotMaxAllocatedIndexPlusOne = rt.compilation.slotFirstDynamicIndex
            rt.functions[rt.compilation.functionIdx].numRetAndArgSlots = u16(rt.compilation.slotFirstDynamicIndex)
            rt.compilation.slotFirstLocalIndex = rt.compilation.slotFirstDynamicIndex
            result = CompileLocals(rt)
        }

        if (result == m3Err_none) {
            let maxSlot = GetMaxUsedSlotPlusOne(rt)
            rt.functions[rt.compilation.functionIdx].numLocalBytes = u16((maxSlot - rt.compilation.slotFirstLocalIndex) * int(typeinfo sizeof(type<m3slot_t>)))
            rt.compilation.slotFirstConstIndex = maxSlot
            rt.compilation.slotMaxConstIndex = maxSlot
            // ReserveConstants initializes o->firstDynamicSlotNumber
            result = ReserveConstants(rt)
        }

        if (result == m3Err_none) {
            // start tracking the max stack used (Push() also updates this value) so that op_Entry can precisely detect stack overflow
            rt.compilation.maxStackSlots = rt.compilation.slotFirstDynamicIndex
            rt.compilation.slotMaxAllocatedIndexPlusOne = rt.compilation.slotFirstDynamicIndex
            rt.compilation._block.blockStackIndex = rt.compilation.stackIndex
            rt.compilation.stackFirstDynamicIndex = rt.compilation.stackIndex

            result = EmitOp(rt, "op_Entry")
        }
        if (result == m3Err_none) {
            EmitPointer(rt, io_function)   // C: EmitPointer (o, io_function); Eden: the function handle
            result = CompileBlockStatements(rt)
        }
        // TODO: validate opcode sequences
        if (result == m3Err_none && rt.compilation.previousOpcode != c_waOp_end) {
            result = m3Err_wasmMalformed
        }

        if (result == m3Err_none) {
            rt.functions[io_function].compiled = pc
            rt.functions[io_function].maxStackSlots = u16(rt.compilation.maxStackSlots)

            let numConstantSlots = rt.compilation.slotMaxConstIndex - rt.compilation.slotFirstConstIndex

            rt.functions[io_function].numConstantBytes = u16(numConstantSlots * int(typeinfo sizeof(type<m3slot_t>)))
            // Eden: op_Entry copies length(constants) words (C: numConstantBytes
            // bytes), so a recompilation drops the previous table to keep
            // length(constants) == numConstantBytes / 4 (C leaves the old
            // pointer, which it never reads when numConstantBytes is 0)
            m3_Free_Impl(rt.functions[io_function].constants)
            if (numConstantSlots != 0) {
                // C: io_function->constants = m3_CopyMem (o->constants, io_function->numConstantBytes);
                // Eden: one word per slot, numConstantSlots of them (DESIGN.md 4.4a, 4.7b);
                // the table is a fixed array, so the copy of m3_CopyMem is spelled out
                m3_Malloc_Impl(rt.functions[io_function].constants, numConstantSlots)
                for (c in range(numConstantSlots)) {
                    rt.functions[io_function].constants[c] = rt.compilation.constants[c]
                }
                // C: _throwifnull (io_function->constants); Eden: allocation cannot fail observably (m3_core)
            }
        }
    }

    // Mirrors the C _catch path: release is reached for every failure after _try begins.
    ReleaseCompilationCodePage(rt)
    return result
}


// ============================================================================
// ErrorCompile (C m3_core.h macro family)
// ============================================================================


/* C: #define ErrorCompile(RESULT, COMP, FORMAT, ...) — C varargs formats are
   interpolated into the message at each call site; __FILE__/__LINE__ are
   dropped (Daslang has no equivalent). Eden: COMP is rt.compilation. */
def public ErrorCompile(i_result : M3Result; var rt : M3Runtime; i_errorMessage : cstr_t) : M3Result {
    return m3Error(i_result, rt, rt.compilation.moduleIdx, -1, "", 0u, i_errorMessage)
}
