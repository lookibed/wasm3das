options gen2
options indenting = 4

module m3_exec shared public

require math
require modules/wasm3das/source/m3_core                // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types public        // Eden: project-root-relative path (upstream: ./m3_types.das)
require modules/wasm3das/source/m3_math_utils public   // Eden: project-root-relative path (upstream: ./m3_math_utils.das)
require modules/wasm3das/source/m3_exec_defs public    // Eden: project-root-relative path (upstream: ./m3_exec_defs.das)
require daslib/math_bits                               // Eden: bit casts of copysign and of the register views (DESIGN.md section 4.2)

// Conservative Gen2 port of m3_exec.h.
// The threaded-interpreter ABI, op_* names, register/slot forms, trap propagation,
// memory checks, and immediate layout are intentionally kept close to wasm3.
//
// One architectural deviation, documented in full in m3_exec_defs.das and
// docs/execution-design.md: Daslang has no M3_MUSTTAIL, so an operation
// does not call its successor. Every operation updates the interpreter
// registers in place - which is what C's "pass the updated values to the next
// operation" means - and `return nextOpDirect (...)` hands control back to the
// dispatching RunLoop ("Operation dispatch" below). The bodies below are
// otherwise the C bodies: the C spelling of every tail position, of
// jumpOpDirect and of nextOpImpl is preserved.

/*
    Eden: deviations from the upstream port (.upstream/source/m3_exec.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.2 - 4.6).
    The upstream file copies C's raw-pointer ABI; here the five registers are
    fields of the runtime and every pointer is a handle or an index:
      - requires are Eden-project-root relative (DESIGN section 6); m3_types,
        m3_math_utils and m3_exec_defs stay public re-exports; the
        m3_exec_expand macro pass has no counterpart (the operand readers are
        the plain functions of m3_exec_defs, called at the use site).
      - an operation is `def public op_X(var rt : M3Runtime) : m3ret_t`
        (M3Op of m3_types). C's registers: _pc is rt.pc, _sp is rt.sp, _mem is
        rt.mem with rt.memory, _r0 is rt.r0 (u64; C's m3reg_t is i64, so an
        i32 result is stored sign-extended, `u64(i64(value))`, and read back
        as `i32(u32(rt.r0))`), _fp0 is rt.fp0. The `_mem = memory->mallocated`
        reload after every nested call and the m3MemInfo/m3MemRuntime reads
        are absent: rt.mem IS the memory and cannot move (DESIGN 4.2).
      - the return protocol is the one of m3_exec_defs: M3_NEXT, M3_RETURN,
        M3_TRAP (rt.trap holds the M3Result) or a loop pc >= 0. newTrap,
        forwardTrap and retOp live in m3_exec_defs; pushBacktraceFrame and
        fillBacktraceFrame (d_m3RecordBacktraces == false) are compiled out
        and noted at their sites.
      - the op table (DESIGN 4.4): a code word that names an operation is
        the operation's index in g_ops, registered by name through
        m3_register_op in m3_build_op_table (registration order = index; the
        table is built in three parts, later parts append to the same
        function, keeping the upstream file order). m3_OpWord(name) is the
        word for a name (C: the function pointer cast of EmitWord; upstream:
        the reinterpret of the function value), m3_OpAt(idx) the operation
        of a word, m3_OpCount() the number registered. An unknown name in
        m3_OpWord is a d_m3Assert panic, as the upstream m3_OpIndex asserts:
        a name only comes from the compiler's tables, so a miss is a bug in
        those, never a runtime condition. m3_DispatchOp, RunLoopIndexed and
        m3_OpIndex of the upstream JIT tier are absent (DESIGN section 7).
      - the Call / RunLoop protocol. RunLoop(rt) reads rt.code[rt.pc],
        advances rt.pc, invokes the operation and repeats while the result
        is M3_NEXT; any other value is returned to the nesting site. C's
        nesting sites make real calls with _pc and _sp BY VALUE and the
        registers cleared (d_m3OpDefaultArgs), so the caller's registers
        survive the callee; here they are shared fields:
          * Call(rt, pc, sp, r0, fp0) saves rt.pc, rt.sp, rt.r0 and rt.fp0,
            installs its arguments, runs nextOpImpl (one nested RunLoop) and
            restores the four saved fields before returning the loop's
            result, so op_Call / op_CallIndirect continue exactly where C's
            by-value copies leave them. Call returns M3_RETURN when the
            callee's op_Return ran (C: NULL), M3_TRAP when an operation
            trapped (C: the error string; rt.trap holds it), or a loop pc
            that escaped, which C forwards the same way.
          * op_Entry runs one nested RunLoop for the body and returns its
            result (forwardTrap) to the RunLoop of the Call that entered it;
            it restores nothing, as C's op_Entry returns without continuing.
          * op_Loop remembers rt.pc (C: its by-value _pc) and, per iteration,
            resets rt.pc to it, clears the registers (C clears once and
            passes the cleared copies to every iteration) and runs one nested
            RunLoop; it iterates while the result is that pc (C: `while (r ==
            _pc)`) and forwards anything else.
          * op_Return / op_End return retOp = M3_RETURN, which ends the
            innermost RunLoop only: the nesting site that started it decides
            what the value means (op_Loop stops looping and forwards it,
            op_Entry forwards it, Call hands it to op_Call which continues).
          * a trap is newTrap(rt, err): rt.trap = err once, M3_TRAP returned;
            every RunLoop level exits on it, every nesting site forwards it
            (forwardTrap), Call restores the caller's registers on the way
            up, and the outermost caller (m3_Call in m3_env) reads rt.trap.
            Nothing in this module clears rt.trap; the caller of RunCode
            resets it before running.
          * RunCode(rt) is RunLoop(rt) (C: RunCode (d_m3OpSig) { nextOpDirect(); }),
            the entry used by m3_Call with rt.pc = function.compiled and
            rt.sp = the frame base.
      - op_Entry's stack check is C's `_sp + maxStackSlots < _mem->maxStack`
        with length(rt.stack) as maxStack (DESIGN 4.3, same trap string); the
        memset of numLocalBytes zeroes numLocalBytes / sizeof (m3slot_t)
        words after the ret+arg slots (one word per slot) and the memcpy of
        the constants copies the function's `constants` words after them.
      - op_CallRawFunction: the raw call is rt.rawCalls[handle], invoked as
        (rt, sp) (DESIGN 4.5; the M3ImportContext C builds is read from the
        two immediates but not passed, the ABI has no context). C swaps
        runtime->stack (the frame base m3_Call uses) for the raw function's
        frame so a host function may re-enter m3_Call; the Eden runtime keeps
        that base in rt.originStack (C sets runtime->stack = originStack and
        only frees through originStack, which the arena model does not need),
        so the swap is on rt.originStack.
      - op_Compile rewrites rt.code[rt.pc - 1] to m3_OpWord("op_Call")
        (C: rewrite_op (op_Call), the running operation's own word) and the
        function's compiled pc into the immediate word, exactly as C patches
        the two words in place.
      - op_MemGrow calls the ResizeMemory bridge (ResizeMemoryHook, wired by
        m3_env) with the runtime; op_MemSize reads rt.memory.numPages.
      - the load and store operations check `address + sizeof (TYPE) <=
        mem_size(rt)` (C: `_mem->length`), then read or write through the
        little-endian accessors load_T / store_T of m3_exec_defs (C: the
        constant-size memcpy; upstream: a typed access).
      - the globals: a global's address immediate is the handle into
        rt.globals; the 32-bit views are the low four bytes of valueBits and
        the 64-bit views the whole word, through the M3Global accessors of
        m3_types where a typed write exists (the union's member store).
      - the arithmetic helpers OP_ADD/SUB/MUL use wrapping unsigned
        arithmetic with numeric bit casts (upstream: reinterpret); OP_CLZ /
        OP_CTZ keep the zero guard (DESIGN 4.6b); copysign is a mask of the
        bits through daslib/math_bits; bool_reg yields the u64 register
        value. [inline] is dropped everywhere (not in 0.6.3).
      - op_Loop's body, op_BranchTable's target read (C: branches
        [branchIndex], a word past the numTargets immediate) and op_Branch's
        `* _pc` peek read rt.code directly where C indexes the code page.
      - the file is ported in three parts (DESIGN 4.4): part 1 holds the
        infrastructure, the calls and the control, slot, global and memory
        operations; part 2 the compare, arithmetic, bit and float families
        of the upstream file (op_i32_Equal_rs ... op_u64_Popcnt_s, in file
        order around the OP_* helpers, as upstream); part 3 the conversion
        families (op_i32_Wrap_i64_r ... op_f64_Reinterpret_i64_s_s: Wrap,
        the sign extensions, Trunc, TruncSat, Extend, Demote, Promote,
        Convert, Reinterpret), which follow part 2 in file order.
      - part 2's register conventions: a compare stores bool_reg, an i32
        result u64(i64(v)) (sign-extended, C's m3reg_t conversion of an
        i32), a u32 / bit-count result u64(v) (zero-extended, as C converts
        a u32), an i64 / u64 result its bits, an f32 result f64(v) in
        rt.fp0 (C: the f64 register holds the widened f32). The trapping
        integer division reads the M3Result of OP_DIV_U / OP_REM_U /
        OP_DIV_S / OP_REM_S (m3_math_utils) and raises it with newTrap (C:
        the macro's own newTrap); the signed ShiftRight spells C's
        OP_SHR_32 / OP_SHR_64 on a signed X inline (an arithmetic shift by
        the masked count), as the upstream file does.
      - part 3's conversions: the wrap is u64(u32(x)), the bits of C's
        OP_WRAP_I64 mask on the i64 register, so its i32 result is the one
        zero-extended in rt.r0; the sign extensions narrow with the i8 /
        i16 / i32 casts and widen back; the trapping truncations read the
        M3Result of OP_*_TRUNC_* and the saturating ones call
        OP_*_TRUNC_SAT_* (m3_math_utils, C's range constants), the trap
        raised here with newTrap; a destination slot (the _s_r / _s_s
        forms, C's slot_ptr (TYPE)) is read as its index before the
        conversion and written with set_stack_T; Convert, Demote and
        Promote are daslang's numeric casts, measured on 0.6.3 and 0.6.4
        to round as C's (a u64 -> f32 / f64 conversion is correctly
        rounded, not lowered through a signed path; f64 -> f32 keeps a
        NaN's high payload bits and overflows to inf like the hardware
        conversion); Reinterpret goes through the bit casts of
        daslib/math_bits (the upstream reinterpret<T>), bit-exact, a NaN
        payload kept.
    Everything else (names, order, control flow, checks, trap strings) is
    the C of m3_exec.h.
*/

let INT32_MIN : i32 = -2147483647 - 1
let INT64_MIN : i64 = -9223372036854775807l - 1l


// C spells the three as macros (d_m3RecordBacktraces == false makes them
// empty / a plain passthrough). Eden: newTrap and forwardTrap moved to
// m3_exec_defs with the protocol; pushBacktraceFrame / fillBacktraceFrame are
// compiled out and noted at their sites, the backtrace layer is not ported.


/*
    C m3_exec.h calls CompileFunction (m3_compile.c) for lazy compilation on
    the op_Entry/op_Call paths. The C header cycle between m3_exec.h and
    m3_compile.h cannot be expressed in an acyclic Daslang module graph, so
    the compiler implementation is registered in this hook; m3_env.das wires
    it when the full module set loads.
*/

// Eden: the compiler takes the runtime (its arenas and code) and a function handle
var public CompileFunctionHook : function<(var rt : M3Runtime; io_function : IM3Function) : M3Result>

// Eden: the resize takes the runtime (rt.mem, rt.memory), no runtime handle
var public ResizeMemoryHook : function<(var rt : M3Runtime; i_numPages : u32) : M3Result>


// C: M3Result ResizeMemory (IM3Runtime io_runtime, u32 i_numPages) — m3_env.c,
// registered by m3_env.das (see CompileFunctionHook note). Private: m3_env.das
// defines the real ResizeMemory and must not see this bridge as a second candidate.
def private ResizeMemory(var rt : M3Runtime; i_numPages : u32) : M3Result {
    if (ResizeMemoryHook == null) {
        return "memory resize hook is not wired"
    }
    return ResizeMemoryHook(rt, i_numPages)
}


def private CompileFunction(var rt : M3Runtime; io_function : IM3Function) : M3Result {
    if (CompileFunctionHook == null) {
        return "lazy compilation hook is not wired"
    }
    return CompileFunctionHook(rt, io_function)
}


// ============================================================================
// C string.h in op_MemCopy / op_MemFill / op_Entry
// ============================================================================


// C's `memmove`, `memset` and `memcpy` act on the linear memory and the
// stack. Eden: rt.mem and rt.stack are arrays, so op_MemCopy, op_MemFill and
// op_Entry write the words and bytes one by one (a memmove copies from the
// end when the regions overlap and the destination is above the source).

// ============================================================================
// libm replacements (C copysignf/copysign)
//
// fabsf/fabs/floorf/ceilf/rintf/rint live in m3_math_utils.das next to the
// other libm-shaped helpers; see the comment there for why the `math` module
// cannot be used for them.
// ============================================================================


// Eden: the bit masks through daslib/math_bits (upstream: reinterpret)
def copysign_f32(a : f32; b : f32) : f32 {
    let abits = float_bits_to_uint(a)
    let bbits = float_bits_to_uint(b)
    return uint_bits_to_float((abits & 0x7fffffffu) | (bbits & 0x80000000u))
}


def copysign_f64(a : f64; b : f64) : f64 {
    let abits = double_bits_to_uint64(a)
    let bbits = double_bits_to_uint64(b)
    return uint64_bits_to_double((abits & 0x7ffffffffffffffful) | (bbits & 0x8000000000000000ul))
}


/*
    Operand readers. C spells them as preprocessor macros in m3_exec_defs.h
    (immediate (TYPE), slot (TYPE), slot_ptr (TYPE)); the upstream port kept
    them as [inline] functions here and expanded them with a macro pass.
    Eden: they are the plain functions of m3_exec_defs (immediate_T,
    slot_T, slot_index, stack_T, set_stack_T and the set_slot_T writes), and
    every read is a statement of its own at the use site, see that header.
*/


// C: _r0 = (operand1 == operand2) - the bool-to-m3reg_t conversion.
// Eden: the register is u64, so the value is 1ul / 0ul
def bool_reg(value : bool) : u64 {
    return value ? 1ul : 0ul
}


// ============================================================================
// Operation dispatch
// ============================================================================


/*
    C stores an operation as the function pointer itself and calls it back
    through the word:

        EmitWord (page, op)                       // the function pointer
        ((IM3Operation)(* _pc))(_pc + 1, ...)     // the indirect call back

    Eden (DESIGN.md section 4.4): the word is the operation's index in the op
    table g_ops, filled once by m3_build_op_table, which registers every
    operation by name. The index is the registration order and only
    consistency matters: the compiler's tables carry op names and resolve
    them through m3_OpWord, the same table, so the table can be built part
    by part. RunLoop's `invoke (g_ops[word], rt)` is C's cast and call.
*/

/* C stores NULL in absent operation-table slots; m3_compile.das holds the
   explicit sentinel c_opNull = op_NoOp instead, because Daslang function
   values are non-nullable. The operation itself lives here, with the other
   operations: C's Compile_Select emits its NULL operation unguarded when the
   stack is polymorphic, so the sentinel does reach a code page and needs a
   dispatch index like every other op_*. It is never meant to execute. */
def public op_NoOp(var rt : M3Runtime) : m3ret_t {
    return newTrap(rt, m3Err_noCompiler)   // Eden: upstream returned the string itself
}


// Eden: the op table. g_ops[i] is the operation whose word is i; g_opIndex
// maps the name to that word.
var public g_ops : array<M3Op>
var public g_opIndex : table<string; int>


// Eden: registration by name; the word is the position in g_ops
def public m3_register_op(name : string; op : M3Op) {
    g_opIndex[name] = length(g_ops)
    push(g_ops, op)
}


/* C: (const void *) op, the cast inside EmitWord. Eden: the word is the
   operation's index in g_ops, looked up by name; an unknown name is a
   d_m3Assert panic (a compiler-table bug, see the header). */
def public m3_OpWord(name : string) : u64 {
    var idx = -1
    if (key_exists(g_opIndex, name)) {
        idx = g_opIndex[name]
    }
    d_m3Assert(idx >= 0, "m3_OpWord: not an m3_exec operation: {name}")
    return u64(idx)
}


/* Eden: the operation of a word (upstream: the JIT pass's tree over the
   function values). */
def public m3_OpAt(idx : int) : M3Op {
    return g_ops[idx]
}


/* Eden: the number of registered operations (upstream: the number of op_*
   functions of this module under the JIT). */
def public m3_OpCount() : int {
    return length(g_ops)
}


// The trampoline that stands in for C's M3_MUSTTAIL threading: every
// operation updates the runtime's registers in place and returns the
// protocol value. The sentinel test is the loop condition rather than an
// `if`/`break` pair in the body: one operation costs one iteration. `r`
// starts at the sentinel, which is the state "the word at rt.pc still has to
// be dispatched"; C's threaded form has the same shape, because there the
// first operation is entered unconditionally.
def public RunLoop(var rt : M3Runtime) : m3ret_t {
    var r : m3ret_t = M3_NEXT
    while (r == M3_NEXT) {
        let word = rt.code[rt.pc]   // C: (IM3Operation)(* _pc), unchecked; Eden: the array's bounds check
        rt.pc = rt.pc + 1
        r = invoke(g_ops[int(word)], rt)
    }
    return r
}


// C: #define nextOpImpl() ((IM3Operation)(* _pc))(_pc + 1, d_m3OpArgs)
def public nextOpImpl(var rt : M3Runtime) : m3ret_t {
    return RunLoop(rt)
}


// C: #define jumpOpImpl(PC) ((IM3Operation)(* PC))( PC + 1, d_m3OpArgs)
def public jumpOpImpl(var rt : M3Runtime; pc : pc_t) : m3ret_t {
    rt.pc = pc
    return RunLoop(rt)
}


// C: d_m3RetSig RunCode (d_m3OpSig) { nextOpDirect(); }
def public RunCode(var rt : M3Runtime) : m3ret_t {
    return RunLoop(rt)
}


// C: static inline m3ret_t Call (d_m3OpSig) — takes the operation signature by
// value and its callers (op_Call, op_CallIndirect) pass a fresh stack pointer
// and cleared registers. C ends it with nextOpDirect(), a MUSTTAIL return of
// nextOpImpl(): Call's result is the completed result of the callee's operation
// chain, so the trampoline form is nextOpImpl, one nested RunLoop per wasm call.
// C tests the M3Result against NULL, one pointer comparison; the m3_Yield
// result is tested with m3ResultIsError (m3_core.das), `empty`'s contract.
// Eden: _pc, _sp, _r0 and _fp0 are the runtime's fields, so the by-value
// semantics of C's arguments are made explicit: the four fields are saved,
// the arguments installed, and the fields restored after the nested loop
// (the protocol in the header). A yield that traps is newTrap (C: return
// possible_trap, the error string).
def public Call(var rt : M3Runtime; _pc : pc_t; _sp : m3stack_t; _r0 : m3reg_t; _fp0 : f64) : m3ret_t {
    let possible_trap = m3_Yield()
    if (m3ResultIsError(possible_trap)) {
        return newTrap(rt, possible_trap)
    }
    let savedPC = rt.pc
    let savedSP = rt.sp
    let savedR0 = rt.r0
    let savedFP0 = rt.fp0
    rt.pc = _pc
    rt.sp = _sp
    rt.r0 = u64(_r0)
    rt.fp0 = _fp0
    let r = nextOpImpl(rt)
    rt.pc = savedPC
    rt.sp = savedSP
    rt.r0 = savedR0
    rt.fp0 = savedFP0
    return r
}


// ============================================================================
// Operations
// ============================================================================


// The compare, arithmetic, bit and float families of the upstream file
// (op_i32_Equal_rs ... op_u64_Popcnt_s, upstream lines 621 - 2282):
// the compare operations (C: d_m3CommutativeOp_i / d_m3Op_i for the
// integers, d_m3CommutativeCmpOp_f / d_m3CompareOp_f for the floats, the
// result is a bool in _r0) precede the OP_* helpers as in the upstream
// file; the arithmetic, bit and float operations follow them.
// Eden: the register reads spell C's (TYPE) REG casts on rt.r0 / rt.fp0
// (i32(u32(rt.r0)), i64(rt.r0), u32(rt.r0), f32(rt.fp0)); the operand
// order of every body is the C one (_rs: slot OP register, _sr: register
// OP slot, _ss: operand1 OP operand2).


def public op_i32_Equal_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand == i32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i32_Equal_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(rt)
}


def public op_i32_NotEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand != i32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i32_NotEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(rt)
}


def public op_i32_LessThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(i32(u32(rt.r0)) < operand)
    return nextOpDirect(rt)
}


def public op_i32_LessThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand < i32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i32_LessThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(rt)
}


def public op_i32_GreaterThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(i32(u32(rt.r0)) > operand)
    return nextOpDirect(rt)
}


def public op_i32_GreaterThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand > i32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i32_GreaterThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(rt)
}


def public op_i32_LessThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(i32(u32(rt.r0)) <= operand)
    return nextOpDirect(rt)
}


def public op_i32_LessThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand <= i32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i32_LessThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(rt)
}


def public op_i32_GreaterThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(i32(u32(rt.r0)) >= operand)
    return nextOpDirect(rt)
}


def public op_i32_GreaterThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand >= i32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i32_GreaterThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(rt)
}


def public op_i64_Equal_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand == i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_i64_Equal_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(rt)
}


def public op_i64_NotEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand != i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_i64_NotEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(rt)
}


def public op_i64_LessThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(i64(rt.r0) < operand)
    return nextOpDirect(rt)
}


def public op_i64_LessThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand < i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_i64_LessThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(rt)
}


def public op_i64_GreaterThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(i64(rt.r0) > operand)
    return nextOpDirect(rt)
}


def public op_i64_GreaterThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand > i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_i64_GreaterThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(rt)
}


def public op_i64_LessThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(i64(rt.r0) <= operand)
    return nextOpDirect(rt)
}


def public op_i64_LessThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand <= i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_i64_LessThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(rt)
}


def public op_i64_GreaterThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(i64(rt.r0) >= operand)
    return nextOpDirect(rt)
}


def public op_i64_GreaterThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand >= i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_i64_GreaterThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(rt)
}


def public op_u32_LessThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(u32(rt.r0) < operand)
    return nextOpDirect(rt)
}


def public op_u32_LessThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(operand < u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_LessThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(rt)
}


def public op_u32_GreaterThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(u32(rt.r0) > operand)
    return nextOpDirect(rt)
}


def public op_u32_GreaterThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(operand > u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_GreaterThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(rt)
}


def public op_u32_LessThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(u32(rt.r0) <= operand)
    return nextOpDirect(rt)
}


def public op_u32_LessThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(operand <= u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_LessThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(rt)
}


def public op_u32_GreaterThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(u32(rt.r0) >= operand)
    return nextOpDirect(rt)
}


def public op_u32_GreaterThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = bool_reg(operand >= u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_GreaterThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(rt)
}


def public op_u64_LessThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(rt.r0 < operand)
    return nextOpDirect(rt)
}


def public op_u64_LessThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(operand < rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_LessThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(rt)
}


def public op_u64_GreaterThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(rt.r0 > operand)
    return nextOpDirect(rt)
}


def public op_u64_GreaterThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(operand > rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_GreaterThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(rt)
}


def public op_u64_LessThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(rt.r0 <= operand)
    return nextOpDirect(rt)
}


def public op_u64_LessThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(operand <= rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_LessThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(rt)
}


def public op_u64_GreaterThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(rt.r0 >= operand)
    return nextOpDirect(rt)
}


def public op_u64_GreaterThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = bool_reg(operand >= rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_GreaterThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(rt)
}


def public op_f32_Equal_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(operand == f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_Equal_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(rt)
}


def public op_f32_NotEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(operand != f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_NotEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(rt)
}


def public op_f32_LessThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(f32(rt.fp0) < operand)
    return nextOpDirect(rt)
}


def public op_f32_LessThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(operand < f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_LessThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(rt)
}


def public op_f32_GreaterThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(f32(rt.fp0) > operand)
    return nextOpDirect(rt)
}


def public op_f32_GreaterThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(operand > f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_GreaterThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(rt)
}


def public op_f32_LessThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(f32(rt.fp0) <= operand)
    return nextOpDirect(rt)
}


def public op_f32_LessThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(operand <= f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_LessThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(rt)
}


def public op_f32_GreaterThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(f32(rt.fp0) >= operand)
    return nextOpDirect(rt)
}


def public op_f32_GreaterThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.r0 = bool_reg(operand >= f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_GreaterThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(rt)
}


def public op_f64_Equal_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(operand == rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Equal_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(rt)
}


def public op_f64_NotEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(operand != rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_NotEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(rt)
}


def public op_f64_LessThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(rt.fp0 < operand)
    return nextOpDirect(rt)
}


def public op_f64_LessThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(operand < rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_LessThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(rt)
}


def public op_f64_GreaterThan_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(rt.fp0 > operand)
    return nextOpDirect(rt)
}


def public op_f64_GreaterThan_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(operand > rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_GreaterThan_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(rt)
}


def public op_f64_LessThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(rt.fp0 <= operand)
    return nextOpDirect(rt)
}


def public op_f64_LessThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(operand <= rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_LessThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(rt)
}


def public op_f64_GreaterThanOrEqual_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(rt.fp0 >= operand)
    return nextOpDirect(rt)
}


def public op_f64_GreaterThanOrEqual_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.r0 = bool_reg(operand >= rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_GreaterThanOrEqual_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(rt)
}


// C m3_math_utils.h spells these as preprocessor macros, so they cost nothing
// at the use site. Eden: no [inline] (not in 0.6.3); wrapping unsigned
// arithmetic with numeric bit casts (upstream: reinterpret).
def OP_ADD_32(a, b : i32) : i32 {
    return i32(u32(a) + u32(b))
}


def OP_ADD_64(a, b : i64) : i64 {
    return i64(u64(a) + u64(b))
}


def OP_SUB_32(a, b : i32) : i32 {
    return i32(u32(a) - u32(b))
}


def OP_SUB_64(a, b : i64) : i64 {
    return i64(u64(a) - u64(b))
}


def OP_MUL_32(a, b : i32) : i32 {
    return i32(u32(a) * u32(b))
}


def OP_MUL_64(a, b : i64) : i64 {
    return i64(u64(a) * u64(b))
}


def OP_SHL_32(x, n : u32) : u32 {
    return x << (n % 32u)
}


def OP_SHL_64(x, n : u64) : u64 {
    return x << (n % 64ul)
}


def OP_SHR_32(x, n : u32) : u32 {
    return x >> (n % 32u)
}


def OP_SHR_64(x, n : u64) : u64 {
    return x >> (n % 64ul)
}


// C: "clz(0), ctz(0) results are undefined for rest platforms, fix it" - the
// portable branch of the OP_CLZ_*/OP_CTZ_* macros. The Daslang builtins share
// the hardware quirk (clz(0u) is 31 here), so the guard is mandatory (DESIGN 4.6b).
def OP_CLZ_32(x : u32) : u32 {
    return x == 0u ? 32u : clz(x)
}


def OP_CTZ_32(x : u32) : u32 {
    return x == 0u ? 32u : ctz(x)
}


def OP_CLZ_64(x : u64) : u64 {
    return x == 0ul ? 64ul : clz(x)
}


def OP_CTZ_64(x : u64) : u64 {
    return x == 0ul ? 64ul : ctz(x)
}


// C: d_m3CommutativeOpFunc_i / d_m3OpFunc_i (i32, i64: Add, Multiply,
// Subtract) through the OP_ADD/MUL/SUB macros above. Eden: an i32 result is
// stored sign-extended (u64(i64(v)), C's m3reg_t conversion of an i32), an
// i64 result as its bits.
def public op_i32_Add_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(OP_ADD_32(operand, i32(u32(rt.r0)))))
    return nextOpDirect(rt)
}


def public op_i32_Add_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = u64(i64(OP_ADD_32(operand1, operand2)))
    return nextOpDirect(rt)
}


def public op_i64_Add_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(OP_ADD_64(operand, i64(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i64_Add_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = u64(OP_ADD_64(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_i32_Multiply_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(OP_MUL_32(operand, i32(u32(rt.r0)))))
    return nextOpDirect(rt)
}


def public op_i32_Multiply_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = u64(i64(OP_MUL_32(operand1, operand2)))
    return nextOpDirect(rt)
}


def public op_i64_Multiply_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(OP_MUL_64(operand, i64(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i64_Multiply_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = u64(OP_MUL_64(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_i32_Subtract_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(OP_SUB_32(i32(u32(rt.r0)), operand)))
    return nextOpDirect(rt)
}


def public op_i32_Subtract_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(OP_SUB_32(operand, i32(u32(rt.r0)))))
    return nextOpDirect(rt)
}


def public op_i32_Subtract_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = u64(i64(OP_SUB_32(operand1, operand2)))
    return nextOpDirect(rt)
}


def public op_i64_Subtract_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(OP_SUB_64(i64(rt.r0), operand))
    return nextOpDirect(rt)
}


def public op_i64_Subtract_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(OP_SUB_64(operand, i64(rt.r0)))
    return nextOpDirect(rt)
}


def public op_i64_Subtract_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = u64(OP_SUB_64(operand1, operand2))
    return nextOpDirect(rt)
}


// C: d_m3OpFunc_i (u32/u64 ShiftLeft, i32/i64/u32/u64 ShiftRight) through
// OP_SHL_* / OP_SHR_*, the count masked to the width. Eden: a u32 result is
// stored zero-extended (C's m3reg_t conversion of a u32); the signed
// ShiftRight keeps the upstream spelling of C's OP_SHR_32 / OP_SHR_64 on a
// signed X (an arithmetic shift by the masked count), as the u32 / u64
// helpers above take the unsigned X of the other rows.
def public op_u32_ShiftLeft_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(OP_SHL_32(u32(rt.r0), operand))
    return nextOpDirect(rt)
}


def public op_u32_ShiftLeft_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(OP_SHL_32(operand, u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_ShiftLeft_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(OP_SHL_32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_u64_ShiftLeft_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = OP_SHL_64(rt.r0, operand)
    return nextOpDirect(rt)
}


def public op_u64_ShiftLeft_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = OP_SHL_64(operand, rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_ShiftLeft_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = OP_SHL_64(operand1, operand2)
    return nextOpDirect(rt)
}


def public op_i32_ShiftRight_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(i32(u32(rt.r0)) >> i32(u32(operand) % 32u)))   // C: OP_SHR_32 (i32 X)
    return nextOpDirect(rt)
}


def public op_i32_ShiftRight_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(operand >> i32(u32(rt.r0) % 32u)))   // C: OP_SHR_32 (i32 X)
    return nextOpDirect(rt)
}


def public op_i32_ShiftRight_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    rt.r0 = u64(i64(operand1 >> i32(u32(operand2) % 32u)))   // C: OP_SHR_32 (i32 X)
    return nextOpDirect(rt)
}


def public op_i64_ShiftRight_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(i64(rt.r0) >> i64(u64(operand) % 64ul))   // C: OP_SHR_64 (i64 X)
    return nextOpDirect(rt)
}


def public op_i64_ShiftRight_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(operand >> i64(rt.r0 % 64ul))   // C: OP_SHR_64 (i64 X)
    return nextOpDirect(rt)
}


def public op_i64_ShiftRight_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    rt.r0 = u64(operand1 >> i64(u64(operand2) % 64ul))   // C: OP_SHR_64 (i64 X)
    return nextOpDirect(rt)
}


def public op_u32_ShiftRight_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(OP_SHR_32(u32(rt.r0), operand))
    return nextOpDirect(rt)
}


def public op_u32_ShiftRight_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(OP_SHR_32(operand, u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_ShiftRight_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(OP_SHR_32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_u64_ShiftRight_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = OP_SHR_64(rt.r0, operand)
    return nextOpDirect(rt)
}


def public op_u64_ShiftRight_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = OP_SHR_64(operand, rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_ShiftRight_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = OP_SHR_64(operand1, operand2)
    return nextOpDirect(rt)
}


// C: d_m3CommutativeOp_i (u32 / u64 And, Or, Xor)
def public op_u32_And_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(operand & u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_And_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(operand1 & operand2)
    return nextOpDirect(rt)
}


def public op_u32_Or_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(operand | u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_Or_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(operand1 | operand2)
    return nextOpDirect(rt)
}


def public op_u32_Xor_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(operand ^ u32(rt.r0))
    return nextOpDirect(rt)
}


def public op_u32_Xor_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(operand1 ^ operand2)
    return nextOpDirect(rt)
}


def public op_u64_And_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = operand & rt.r0
    return nextOpDirect(rt)
}


def public op_u64_And_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = operand1 & operand2
    return nextOpDirect(rt)
}


def public op_u64_Or_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = operand | rt.r0
    return nextOpDirect(rt)
}


def public op_u64_Or_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = operand1 | operand2
    return nextOpDirect(rt)
}


def public op_u64_Xor_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = operand ^ rt.r0
    return nextOpDirect(rt)
}


def public op_u64_Xor_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = operand1 ^ operand2
    return nextOpDirect(rt)
}


// C: d_m3CommutativeOp_f / d_m3Op_f (f32 / f64 Add, Multiply, Subtract,
// Divide); an f32 result widens into _fp0 (C: the f64 register)
def public op_f32_Add_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(operand + f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_Add_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(operand1 + operand2)
    return nextOpDirect(rt)
}


def public op_f32_Multiply_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(operand * f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_Multiply_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(operand1 * operand2)
    return nextOpDirect(rt)
}


def public op_f32_Subtract_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(f32(rt.fp0) - operand)
    return nextOpDirect(rt)
}


def public op_f32_Subtract_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(operand - f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_Subtract_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(operand1 - operand2)
    return nextOpDirect(rt)
}


def public op_f32_Divide_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(f32(rt.fp0) / operand)
    return nextOpDirect(rt)
}


def public op_f32_Divide_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(operand / f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f32_Divide_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(operand1 / operand2)
    return nextOpDirect(rt)
}


def public op_f64_Add_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (operand + rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Add_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = (operand1 + operand2)
    return nextOpDirect(rt)
}


def public op_f64_Multiply_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (operand * rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Multiply_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = (operand1 * operand2)
    return nextOpDirect(rt)
}


def public op_f64_Subtract_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (rt.fp0 - operand)
    return nextOpDirect(rt)
}


def public op_f64_Subtract_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (operand - rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Subtract_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = (operand1 - operand2)
    return nextOpDirect(rt)
}


def public op_f64_Divide_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (rt.fp0 / operand)
    return nextOpDirect(rt)
}


def public op_f64_Divide_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (operand / rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Divide_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = (operand1 / operand2)
    return nextOpDirect(rt)
}


// C: d_m3OpFunc_i (u32 / u64 Rotl, Rotr) through rotl32 / rotr32 / rotl64 /
// rotr64 of m3_math_utils (the count argument is a uint, the helpers mask it)
def public op_u32_Rotl_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(rotl32(u32(rt.r0), operand))
    return nextOpDirect(rt)
}


def public op_u32_Rotl_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(rotl32(operand, u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_Rotl_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(rotl32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_u32_Rotr_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(rotr32(u32(rt.r0), operand))
    return nextOpDirect(rt)
}


def public op_u32_Rotr_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(rotr32(operand, u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_Rotr_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    rt.r0 = u64(rotr32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_u64_Rotl_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = rotl64(rt.r0, u32(operand))
    return nextOpDirect(rt)
}


def public op_u64_Rotl_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = rotl64(operand, u32(rt.r0 % 64ul))
    return nextOpDirect(rt)
}


def public op_u64_Rotl_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = rotl64(operand1, u32(operand2 % 64ul))
    return nextOpDirect(rt)
}


def public op_u64_Rotr_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = rotr64(rt.r0, u32(operand))
    return nextOpDirect(rt)
}


def public op_u64_Rotr_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = rotr64(operand, u32(rt.r0 % 64ul))
    return nextOpDirect(rt)
}


def public op_u64_Rotr_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    rt.r0 = rotr64(operand1, u32(operand2 % 64ul))
    return nextOpDirect(rt)
}


// C: d_m3OpMacro_i (u32 / i32 / u64 / i64 Divide, Remainder) through the
// OP_DIV_U / OP_REM_U / OP_DIV_S / OP_REM_S macros, which trap
// (newTrap (m3Err_trapDivisionByZero / m3Err_trapIntegerOverflow)) instead
// of storing a result. Eden (as upstream): the helper of m3_math_utils
// returns the M3Result and fills RES; the trap is raised here with newTrap.
def public op_u32_Divide_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    var RES : u32
    let result = OP_DIV_U(RES, u32(rt.r0), operand)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Divide_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    var RES : u32
    let result = OP_DIV_U(RES, operand, u32(rt.r0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Divide_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    var RES : u32
    let result = OP_DIV_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Remainder_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    var RES : u32
    let result = OP_REM_U(RES, u32(rt.r0), operand)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Remainder_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    var RES : u32
    let result = OP_REM_U(RES, operand, u32(rt.r0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Remainder_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u32(rt)
    let operand1 = slot_u32(rt)
    var RES : u32
    let result = OP_REM_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i32_Divide_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    var RES : i32
    let result = OP_DIV_S(RES, i32(u32(rt.r0)), operand, INT32_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Divide_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    var RES : i32
    let result = OP_DIV_S(RES, operand, i32(u32(rt.r0)), INT32_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Divide_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    var RES : i32
    let result = OP_DIV_S(RES, operand1, operand2, INT32_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Remainder_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    var RES : i32
    let result = OP_REM_S(RES, i32(u32(rt.r0)), operand, INT32_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Remainder_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    var RES : i32
    let result = OP_REM_S(RES, operand, i32(u32(rt.r0)), INT32_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Remainder_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    var RES : i32
    let result = OP_REM_S(RES, operand1, operand2, INT32_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_u64_Divide_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    var RES : u64
    let result = OP_DIV_U(RES, rt.r0, operand)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Divide_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    var RES : u64
    let result = OP_DIV_U(RES, operand, rt.r0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Divide_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    var RES : u64
    let result = OP_DIV_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Remainder_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    var RES : u64
    let result = OP_REM_U(RES, rt.r0, operand)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Remainder_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    var RES : u64
    let result = OP_REM_U(RES, operand, rt.r0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Remainder_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_u64(rt)
    let operand1 = slot_u64(rt)
    var RES : u64
    let result = OP_REM_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_i64_Divide_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    var RES : i64
    let result = OP_DIV_S(RES, i64(rt.r0), operand, INT64_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Divide_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    var RES : i64
    let result = OP_DIV_S(RES, operand, i64(rt.r0), INT64_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Divide_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    var RES : i64
    let result = OP_DIV_S(RES, operand1, operand2, INT64_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Remainder_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    var RES : i64
    let result = OP_REM_S(RES, i64(rt.r0), operand, INT64_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Remainder_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    var RES : i64
    let result = OP_REM_S(RES, operand, i64(rt.r0), INT64_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Remainder_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    var RES : i64
    let result = OP_REM_S(RES, operand1, operand2, INT64_MIN)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


// C: d_m3OpFunc_f (f32 / f64 Min, Max through min_f32 ... max_f64 of
// m3_math_utils, the wasm NaN and signed-zero rules; CopySign through
// copysignf / copysign, the bit masks copysign_f32 / copysign_f64 above)
def public op_f32_Min_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(min_f32(f32(rt.fp0), operand))
    return nextOpDirect(rt)
}


def public op_f32_Min_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(min_f32(operand, f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Min_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(min_f32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_f32_Max_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(max_f32(f32(rt.fp0), operand))
    return nextOpDirect(rt)
}


def public op_f32_Max_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(max_f32(operand, f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Max_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(max_f32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_f32_CopySign_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(copysign_f32(f32(rt.fp0), operand))
    return nextOpDirect(rt)
}


def public op_f32_CopySign_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(copysign_f32(operand, f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_CopySign_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    rt.fp0 = f64(copysign_f32(operand1, operand2))
    return nextOpDirect(rt)
}


def public op_f64_Min_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = min_f64(rt.fp0, operand)
    return nextOpDirect(rt)
}


def public op_f64_Min_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = min_f64(operand, rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Min_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = min_f64(operand1, operand2)
    return nextOpDirect(rt)
}


def public op_f64_Max_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = max_f64(rt.fp0, operand)
    return nextOpDirect(rt)
}


def public op_f64_Max_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = max_f64(operand, rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Max_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = max_f64(operand1, operand2)
    return nextOpDirect(rt)
}


def public op_f64_CopySign_sr(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = copysign_f64(rt.fp0, operand)
    return nextOpDirect(rt)
}


def public op_f64_CopySign_rs(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = copysign_f64(operand, rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_CopySign_ss(var rt : M3Runtime) : m3ret_t {
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    rt.fp0 = copysign_f64(operand1, operand2)
    return nextOpDirect(rt)
}


// C: d_m3UnaryOp_f (f32 / f64 Abs, Ceil, Floor, Trunc, Sqrt, Nearest,
// Negate): the _r form works on the register, the _s form on a slot. The
// libm calls are the m3_math_utils ports (fabsf / fabs, the musl floorf /
// ceilf, rintf / rint) and the `math` module (trunc, sqrt and the f64
// ceil / floor), as upstream.
def public op_f32_Abs_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(fabsf(f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Abs_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(fabsf(operand))
    return nextOpDirect(rt)
}


def public op_f32_Ceil_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(ceilf(f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Ceil_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(ceilf(operand))
    return nextOpDirect(rt)
}


def public op_f32_Floor_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(floorf(f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Floor_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(floorf(operand))
    return nextOpDirect(rt)
}


def public op_f32_Trunc_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64((math::trunc(f32(rt.fp0))))
    return nextOpDirect(rt)
}


def public op_f32_Trunc_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64((math::trunc(operand)))
    return nextOpDirect(rt)
}


def public op_f32_Sqrt_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64((math::sqrt(f32(rt.fp0))))
    return nextOpDirect(rt)
}


def public op_f32_Sqrt_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64((math::sqrt(operand)))
    return nextOpDirect(rt)
}


def public op_f32_Nearest_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(rintf(f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Nearest_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(rintf(operand))
    return nextOpDirect(rt)
}


def public op_f32_Negate_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(-(f32(rt.fp0)))
    return nextOpDirect(rt)
}


def public op_f32_Negate_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f32(rt)
    rt.fp0 = f64(-(operand))
    return nextOpDirect(rt)
}


def public op_f64_Abs_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = fabs(rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Abs_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = fabs(operand)
    return nextOpDirect(rt)
}


def public op_f64_Ceil_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = (math::ceil(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f64_Ceil_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (math::ceil(operand))
    return nextOpDirect(rt)
}


def public op_f64_Floor_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = (math::floor(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f64_Floor_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (math::floor(operand))
    return nextOpDirect(rt)
}


def public op_f64_Trunc_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = (math::trunc(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f64_Trunc_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (math::trunc(operand))
    return nextOpDirect(rt)
}


def public op_f64_Sqrt_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = (math::sqrt(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f64_Sqrt_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (math::sqrt(operand))
    return nextOpDirect(rt)
}


def public op_f64_Nearest_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = rint(rt.fp0)
    return nextOpDirect(rt)
}


def public op_f64_Nearest_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = rint(operand)
    return nextOpDirect(rt)
}


def public op_f64_Negate_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = (-(rt.fp0))
    return nextOpDirect(rt)
}


def public op_f64_Negate_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_f64(rt)
    rt.fp0 = (-(operand))
    return nextOpDirect(rt)
}


// C: d_m3UnaryOp_i (i32 / i64 EqualToZero through OP_EQZ; u32 / u64 Clz,
// Ctz through the guarded OP_CLZ_* / OP_CTZ_* above, Popcnt through
// __builtin_popcount / __builtin_popcountll: the popcnt intrinsic, as
// upstream). Eden: a bit count is stored zero-extended (a u32 / u64 result).
def public op_i32_EqualToZero_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = bool_reg(i32(u32(rt.r0)) == 0)
    return nextOpDirect(rt)
}


def public op_i32_EqualToZero_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = bool_reg(operand == 0)
    return nextOpDirect(rt)
}


def public op_i64_EqualToZero_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = bool_reg(i64(rt.r0) == 0l)
    return nextOpDirect(rt)
}


def public op_i64_EqualToZero_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = bool_reg(operand == 0l)
    return nextOpDirect(rt)
}


def public op_u32_Clz_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(OP_CLZ_32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_Clz_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(OP_CLZ_32(operand))
    return nextOpDirect(rt)
}


def public op_u32_Ctz_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(OP_CTZ_32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_Ctz_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(OP_CTZ_32(operand))
    return nextOpDirect(rt)
}


def public op_u32_Popcnt_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(popcnt(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_u32_Popcnt_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u32(rt)
    rt.r0 = u64(popcnt(operand))
    return nextOpDirect(rt)
}


def public op_u64_Clz_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = OP_CLZ_64(rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_Clz_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = OP_CLZ_64(operand)
    return nextOpDirect(rt)
}


def public op_u64_Ctz_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = OP_CTZ_64(rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_Ctz_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = OP_CTZ_64(operand)
    return nextOpDirect(rt)
}


def public op_u64_Popcnt_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = popcnt(rt.r0)
    return nextOpDirect(rt)
}


def public op_u64_Popcnt_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_u64(rt)
    rt.r0 = popcnt(operand)
    return nextOpDirect(rt)
}


// The conversion families of the upstream file (op_i32_Wrap_i64_r ...
// op_f64_Reinterpret_i64_s_s: Wrap, the sign extensions, Trunc, TruncSat,
// Extend, Demote, Promote, Convert, Reinterpret; upstream lines 2284 - 3220),
// in file order.


// C: op_i32_Wrap_i64_r / _s through OP_WRAP_I64 (`(X) & 0x00000000ffffffff`
// on the i64 register: the low 32 bits stay zero-extended in _r0, the one
// i32 result C does not sign-extend), then d_m3UnaryOp_i (i32 Extend8_s /
// Extend16_s, i64 Extend8_s / Extend16_s / Extend32_s) through the
// OP_EXTEND*_S_* macros (`(int32_t)(int8_t)(X)`, `(int64_t)(int8_t)(X)` and
// so on). Eden: the wrap is u64(u32(x)), the same bits as C's mask; the
// extensions narrow with the i8 / i16 / i32 casts and widen back, an i32
// result sign-extended into rt.r0, an i64 result its bits.


def public op_i32_Wrap_i64_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(u32(rt.r0))   // C: _r0 = OP_WRAP_I64 ((i64) _r0)
    return nextOpDirect(rt)
}


def public op_i32_Wrap_i64_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(u32(operand))   // C: _r0 = OP_WRAP_I64 (operand)
    return nextOpDirect(rt)
}


def public op_i32_Extend8_s_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(i32(i8(i32(u32(rt.r0))))))   // C: _r0 = OP_EXTEND8_S_I32 ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_i32_Extend8_s_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(i32(i8(operand))))
    return nextOpDirect(rt)
}


def public op_i32_Extend16_s_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(i32(i16(i32(u32(rt.r0))))))   // C: _r0 = OP_EXTEND16_S_I32 ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_i32_Extend16_s_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i32(rt)
    rt.r0 = u64(i64(i32(i16(operand))))
    return nextOpDirect(rt)
}


def public op_i64_Extend8_s_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(i8(i64(rt.r0))))   // C: _r0 = OP_EXTEND8_S_I64 ((i64) _r0)
    return nextOpDirect(rt)
}


def public op_i64_Extend8_s_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(i64(i8(operand)))
    return nextOpDirect(rt)
}


def public op_i64_Extend16_s_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(i16(i64(rt.r0))))   // C: _r0 = OP_EXTEND16_S_I64 ((i64) _r0)
    return nextOpDirect(rt)
}


def public op_i64_Extend16_s_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(i64(i16(operand)))
    return nextOpDirect(rt)
}


def public op_i64_Extend32_s_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(i32(i64(rt.r0))))   // C: _r0 = OP_EXTEND32_S_I64 ((i64) _r0)
    return nextOpDirect(rt)
}


def public op_i64_Extend32_s_s(var rt : M3Runtime) : m3ret_t {
    let operand = slot_i64(rt)
    rt.r0 = u64(i64(i32(operand)))
    return nextOpDirect(rt)
}


// C: d_m3TruncMacro (i32 / u32 / i64 / u64 Trunc from f32 / f64) through
// OP_I32_TRUNC_F32 ... OP_U64_TRUNC_F64 of m3_math_utils, which trap
// (m3Err_trapIntegerConversion on a NaN, m3Err_trapIntegerOverflow outside
// C's range constants) instead of storing a result; the _s_r / _s_s forms
// read the destination slot (C: slot_ptr (TYPE)) before the conversion.
// Eden (as upstream): the helper returns the M3Result and fills RES; the
// trap is raised here with newTrap; the destination slot is its index
// (slot_index) written with set_stack_T; the register stores follow the
// part-2 conventions (an i32 sign-extended, a u32 zero-extended, 64 bits
// as they are).


def public op_i32_Trunc_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i32_Trunc_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_Trunc_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, f32(rt.fp0))
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_Trunc_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, rt.fp0)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_Trunc_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) {
        return newTrap(rt, result)
    }
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


// C: d_m3TruncMacro (i32 / u32 / i64 / u64 TruncSat from f32 / f64) through
// OP_I32_TRUNC_SAT_F32 ... OP_U64_TRUNC_SAT_F64 of m3_math_utils (a NaN
// gives 0, the range ends saturate to the type's limits; no trap). Eden:
// the same shapes as the trapping family above, without the result check.


def public op_i32_TruncSat_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, f32(rt.fp0))
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, source)
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, f32(rt.fp0))
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, source)
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, f32(rt.fp0))
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, source)
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, f32(rt.fp0))
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, source)
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, rt.fp0)
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, source)
    rt.r0 = u64(i64(RES))
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, rt.fp0)
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i32_TruncSat_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, source)
    set_stack_i32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, rt.fp0)
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, source)
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, rt.fp0)
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u32_TruncSat_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, source)
    set_stack_u32(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, f32(rt.fp0))
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, source)
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, f32(rt.fp0))
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, source)
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f32_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, f32(rt.fp0))
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, source)
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f32_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, f32(rt.fp0))
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    let dest = slot_index(rt)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, source)
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, rt.fp0)
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, source)
    rt.r0 = u64(RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, rt.fp0)
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_i64_TruncSat_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, source)
    set_stack_i64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f64_r_r(var rt : M3Runtime) : m3ret_t {
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, rt.fp0)
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, source)
    rt.r0 = RES
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f64_s_r(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, rt.fp0)
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


def public op_u64_TruncSat_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    let dest = slot_index(rt)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, source)
    set_stack_u64(rt, dest, RES)
    return nextOpDirect(rt)
}


// C: d_m3TypeModifyOp (i64 Extend from i32 / u32, f32 Demote from f64, f64
// Promote from f32: `REG_TO = (TO) ((FROM) REG_FROM)`, the _s form from
// `slot (FROM)`) and d_m3TypeConvertOp (f32 / f64 Convert from i32 / u32 /
// i64 / u64: the same cast into the register, the _s_r / _s_s forms into
// `slot (TO)`). Eden: daslang's numeric casts, measured on 0.6.3 and 0.6.4
// to be C's (u64 -> f32 / f64 correctly rounded above the top bit as well,
// i64 -> f32 ties to even, f64 -> f32 keeps a NaN's high payload bits and
// overflows to inf like the hardware conversion); the register stores
// follow the part-2 conventions, an f32 widened into rt.fp0.


def public op_i64_Extend_i32_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(i32(u32(rt.r0))))   // C: _r0 = (i64) ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_i64_Extend_i32_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i32(rt)
    rt.r0 = u64(i64(from))
    return nextOpDirect(rt)
}


def public op_i64_Extend_u32_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(u32(rt.r0))   // C: _r0 = (i64) ((u32) _r0)
    return nextOpDirect(rt)
}


def public op_i64_Extend_u32_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u32(rt)
    rt.r0 = u64(from)
    return nextOpDirect(rt)
}


def public op_f32_Demote_f64_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(f32(rt.fp0))   // C: _fp0 = (f32) ((f64) _fp0)
    return nextOpDirect(rt)
}


def public op_f32_Demote_f64_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_f64(rt)
    rt.fp0 = f64(f32(from))
    return nextOpDirect(rt)
}


def public op_f64_Promote_f32_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(f32(rt.fp0))   // C: _fp0 = (f64) ((f32) _fp0)
    return nextOpDirect(rt)
}


def public op_f64_Promote_f32_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_f32(rt)
    rt.fp0 = f64(from)
    return nextOpDirect(rt)
}


def public op_f32_Convert_i32_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(f32(i32(u32(rt.r0))))   // C: _fp0 = (f32) ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_f32_Convert_i32_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f32(rt, f32(i32(u32(rt.r0))))   // C: slot (f32) = (f32) ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_f32_Convert_i32_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i32(rt)
    rt.fp0 = f64(f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_i32_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i32(rt)
    set_slot_f32(rt, f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_u32_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(f32(u32(rt.r0)))   // C: _fp0 = (f32) ((u32) _r0)
    return nextOpDirect(rt)
}


def public op_f32_Convert_u32_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f32(rt, f32(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_f32_Convert_u32_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u32(rt)
    rt.fp0 = f64(f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_u32_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u32(rt)
    set_slot_f32(rt, f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_i64_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(f32(i64(rt.r0)))   // C: _fp0 = (f32) ((i64) _r0)
    return nextOpDirect(rt)
}


def public op_f32_Convert_i64_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f32(rt, f32(i64(rt.r0)))
    return nextOpDirect(rt)
}


def public op_f32_Convert_i64_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i64(rt)
    rt.fp0 = f64(f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_i64_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i64(rt)
    set_slot_f32(rt, f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_u64_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(f32(rt.r0))   // C: _fp0 = (f32) ((u64) _r0)
    return nextOpDirect(rt)
}


def public op_f32_Convert_u64_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f32(rt, f32(rt.r0))
    return nextOpDirect(rt)
}


def public op_f32_Convert_u64_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u64(rt)
    rt.fp0 = f64(f32(from))
    return nextOpDirect(rt)
}


def public op_f32_Convert_u64_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u64(rt)
    set_slot_f32(rt, f32(from))
    return nextOpDirect(rt)
}


def public op_f64_Convert_i32_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(i32(u32(rt.r0)))   // C: _fp0 = (f64) ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_f64_Convert_i32_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f64(rt, f64(i32(u32(rt.r0))))   // C: slot (f64) = (f64) ((i32) _r0)
    return nextOpDirect(rt)
}


def public op_f64_Convert_i32_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i32(rt)
    rt.fp0 = f64(from)
    return nextOpDirect(rt)
}


def public op_f64_Convert_i32_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i32(rt)
    set_slot_f64(rt, f64(from))
    return nextOpDirect(rt)
}


def public op_f64_Convert_u32_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(u32(rt.r0))   // C: _fp0 = (f64) ((u32) _r0)
    return nextOpDirect(rt)
}


def public op_f64_Convert_u32_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f64(rt, f64(u32(rt.r0)))
    return nextOpDirect(rt)
}


def public op_f64_Convert_u32_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u32(rt)
    rt.fp0 = f64(from)
    return nextOpDirect(rt)
}


def public op_f64_Convert_u32_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u32(rt)
    set_slot_f64(rt, f64(from))
    return nextOpDirect(rt)
}


def public op_f64_Convert_i64_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(i64(rt.r0))   // C: _fp0 = (f64) ((i64) _r0)
    return nextOpDirect(rt)
}


def public op_f64_Convert_i64_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f64(rt, f64(i64(rt.r0)))
    return nextOpDirect(rt)
}


def public op_f64_Convert_i64_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i64(rt)
    rt.fp0 = f64(from)
    return nextOpDirect(rt)
}


def public op_f64_Convert_i64_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_i64(rt)
    set_slot_f64(rt, f64(from))
    return nextOpDirect(rt)
}


def public op_f64_Convert_u64_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(rt.r0)   // C: _fp0 = (f64) ((u64) _r0)
    return nextOpDirect(rt)
}


def public op_f64_Convert_u64_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f64(rt, f64(rt.r0))
    return nextOpDirect(rt)
}


def public op_f64_Convert_u64_r_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u64(rt)
    rt.fp0 = f64(from)
    return nextOpDirect(rt)
}


def public op_f64_Convert_u64_s_s(var rt : M3Runtime) : m3ret_t {
    let from = slot_u64(rt)
    set_slot_f64(rt, f64(from))
    return nextOpDirect(rt)
}


// C: d_m3ReinterpretOp (i32 <- f32, i64 <- f64 into _r0; f32 <- i32, f64 <-
// i64 into _fp0) through a union of the two types (`u.c = (FROM) SRC;
// REG = u.t`, the _s forms through `slot (FROM)` / `slot (TO)`). Eden: the
// bit casts of daslib/math_bits (float_bits_to_int / int_bits_to_float,
// double_bits_to_uint64 / uint64_bits_to_double and their signed forms),
// bit-exact, a NaN payload kept; an i32 pattern is sign-extended into rt.r0
// as C's i64 register takes the union's i32 member, an f32 pattern widened
// into rt.fp0 (C: the f64 register holds the f32).


def public op_i32_Reinterpret_f32_r_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = u64(i64(float_bits_to_int(f32(rt.fp0))))   // C: u.c = (f32) _fp0; _r0 = u.t
    return nextOpDirect(rt)
}


def public op_i32_Reinterpret_f32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    rt.r0 = u64(i64(float_bits_to_int(source)))
    return nextOpDirect(rt)
}


def public op_i32_Reinterpret_f32_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_i32(rt, float_bits_to_int(f32(rt.fp0)))   // C: slot (i32) = u.t
    return nextOpDirect(rt)
}


def public op_i32_Reinterpret_f32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f32(rt)
    set_slot_i32(rt, float_bits_to_int(source))
    return nextOpDirect(rt)
}


def public op_i64_Reinterpret_f64_r_r(var rt : M3Runtime) : m3ret_t {
    rt.r0 = double_bits_to_uint64(rt.fp0)   // C: u.c = (f64) _fp0; _r0 = u.t
    return nextOpDirect(rt)
}


def public op_i64_Reinterpret_f64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    rt.r0 = double_bits_to_uint64(source)
    return nextOpDirect(rt)
}


def public op_i64_Reinterpret_f64_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_i64(rt, double_bits_to_int64(rt.fp0))   // C: slot (i64) = u.t
    return nextOpDirect(rt)
}


def public op_i64_Reinterpret_f64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_f64(rt)
    set_slot_i64(rt, double_bits_to_int64(source))
    return nextOpDirect(rt)
}


def public op_f32_Reinterpret_i32_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = f64(int_bits_to_float(i32(u32(rt.r0))))   // C: u.c = (i32) _r0; _fp0 = u.t
    return nextOpDirect(rt)
}


def public op_f32_Reinterpret_i32_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_i32(rt)
    rt.fp0 = f64(int_bits_to_float(source))
    return nextOpDirect(rt)
}


def public op_f32_Reinterpret_i32_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f32(rt, int_bits_to_float(i32(u32(rt.r0))))   // C: slot (f32) = u.t
    return nextOpDirect(rt)
}


def public op_f32_Reinterpret_i32_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_i32(rt)
    set_slot_f32(rt, int_bits_to_float(source))
    return nextOpDirect(rt)
}


def public op_f64_Reinterpret_i64_r_r(var rt : M3Runtime) : m3ret_t {
    rt.fp0 = uint64_bits_to_double(rt.r0)   // C: u.c = (i64) _r0; _fp0 = u.t
    return nextOpDirect(rt)
}


def public op_f64_Reinterpret_i64_r_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_i64(rt)
    rt.fp0 = int64_bits_to_double(source)
    return nextOpDirect(rt)
}


def public op_f64_Reinterpret_i64_s_r(var rt : M3Runtime) : m3ret_t {
    set_slot_f64(rt, uint64_bits_to_double(rt.r0))   // C: slot (f64) = u.t
    return nextOpDirect(rt)
}


def public op_f64_Reinterpret_i64_s_s(var rt : M3Runtime) : m3ret_t {
    let source = slot_i64(rt)
    set_slot_f64(rt, int64_bits_to_double(source))
    return nextOpDirect(rt)
}


def public op_GetGlobal_s32(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)   // C: u32 * global = immediate (u32 *); Eden: the handle into rt.globals
    let value = u32(rt.globals[global].valueBits)   // the low four bytes of the union (m3_types)
    set_slot_u32(rt, value)
    return nextOpDirect(rt)
}


def public op_GetGlobal_s64(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)
    let value = rt.globals[global].valueBits
    set_slot_u64(rt, value)
    return nextOpDirect(rt)
}


def public op_SetGlobal_i32(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)
    M3Global_SetI32Value(rt.globals[global], i32(u32(rt.r0)))   // C: * global = (u32) _r0
    return nextOpDirect(rt)
}


def public op_SetGlobal_i64(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)
    M3Global_SetI64Value(rt.globals[global], i64(rt.r0))   // C: * global = (u64) _r0
    return nextOpDirect(rt)
}


def public op_Call(var rt : M3Runtime) : m3ret_t {
    let callPC = immediate_pc(rt)
    let stackOffset = immediate_i32(rt)
    // C: IM3Memory memory = m3MemInfo (_mem) — Eden: absent, rt.mem cannot move
    let sp = rt.sp + stackOffset
    let r = Call(rt, callPC, sp, 0l, 0.0lf)
    // C: _mem = memory->mallocated — Eden: absent
    if (r == M3_RETURN) {   // C: if (not r)
        return nextOpDirect(rt)
    }
    // C: pushBacktraceFrame () — d_m3RecordBacktraces == false, compiled out
    return forwardTrap(r)
}


def public op_CallIndirect(var rt : M3Runtime) : m3ret_t {
    let tableIndex = slot_u32(rt)
    let _module = immediate_handle(rt)   // C: IM3Module module = immediate (IM3Module)
    let _type = immediate_handle(rt)     // C: IM3FuncType type = immediate (IM3FuncType)
    let stackOffset = immediate_i32(rt)
    // C: IM3Memory memory = m3MemInfo (_mem) — Eden: absent
    let sp = rt.sp + stackOffset
    var r : M3Result = m3Err_none
    if (tableIndex < rt.modules[_module].table0Size) {
        let _function = rt.modules[_module].table0[int(tableIndex)]
        if (_function != -1) {   // C: if (function)
            if (_type == rt.functions[_function].funcTypeIdx) {   // Eden: interned handles compare (DESIGN 4.1)
                if (rt.functions[_function].compiled == -1) {   // C: if (not function->compiled)
                    r = CompileFunction(rt, _function)
                }
                if (m3ResultIsOk(r)) {
                    // C: Call (function->compiled, ...) - read after the lazy compile, not before.
                    let callResult = Call(rt, rt.functions[_function].compiled, sp, 0l, 0.0lf)
                    // C: _mem = memory->mallocated — Eden: absent
                    if (callResult == M3_RETURN) {   // C: if (not r)
                        return nextOpDirect(rt)
                    }
                    // C: pushBacktraceFrame () — compiled out
                    return forwardTrap(callResult)
                }
            } else {
                r = m3Err_trapIndirectCallTypeMismatch
            }
        } else {
            r = m3Err_trapTableElementIsNull
        }
    } else {
        r = m3Err_trapTableIndexOutOfRange
    }
    if (m3ResultIsError(r)) {
        return newTrap(rt, r)
    }
    return forwardTrap(rt, r)
}


def public op_CallRawFunction(var rt : M3Runtime) : m3ret_t {
    var ctx = M3ImportContext()
    let call = immediate_handle(rt)          // C: M3RawCall call = (M3RawCall) (* _pc++); Eden: handle into rt.rawCalls
    ctx.functionIdx = immediate_handle(rt)   // C: ctx.function = immediate (IM3Function)
    ctx.userdata = immediate_handle(rt)      // C: ctx.userdata = immediate (void *); Eden: the int token
    let sp = rt.sp                           // C: u64* const sp = ((u64*)_sp)
    // C: IM3Memory memory = m3MemInfo (_mem); IM3Runtime runtime = m3MemRuntime (_mem) — Eden: rt itself
    // m3_Call uses runtime->stack to set-up initial exported function stack.
    // Reconfigure the stack to enable recursive invocations of m3_Call.
    // I.e. exported/table function can be called from an impoted function.
    // Eden: the frame base m3_Call uses is rt.originStack (see the header)
    let stack_backup = rt.originStack
    rt.originStack = sp
    let rawCall = rt.rawCalls[call]
    let possible_trap = invoke(rawCall, rt, sp)   // C: call (runtime, &ctx, sp, m3MemData (_mem)); Eden: (rt, sp), DESIGN 4.5
    rt.originStack = stack_backup
    // C: if (possible_trap) { _mem = memory->mallocated; pushBacktraceFrame (); } — Eden: both absent
    return forwardTrap(rt, possible_trap)
}


def public op_MemSize(var rt : M3Runtime) : m3ret_t {
    // C: IM3Memory memory = m3MemInfo (_mem) — Eden: rt.memory
    rt.r0 = u64(rt.memory.numPages)
    return nextOpDirect(rt)
}


def public op_MemGrow(var rt : M3Runtime) : m3ret_t {
    // C: IM3Runtime runtime = m3MemRuntime (_mem); IM3Memory memory = & runtime->memory — Eden: rt, rt.memory
    let numPagesToGrow = i32(u32(rt.r0))
    if (numPagesToGrow >= 0) {
        rt.r0 = u64(rt.memory.numPages)
        if (numPagesToGrow != 0) {
            let requiredPages = rt.memory.numPages + u32(numPagesToGrow)
            let r = ResizeMemory(rt, requiredPages)
            if (m3ResultIsError(r)) {
                rt.r0 = u64(-1l)
            }
            // C: _mem = memory->mallocated — Eden: absent, ResizeMemory resized rt.mem in place
        }
    } else {
        rt.r0 = u64(-1l)
    }
    return nextOpDirect(rt)
}


def public op_MemCopy(var rt : M3Runtime) : m3ret_t {
    let size = u32(rt.r0)
    let source = u64(slot_u32(rt))
    let destination = u64(slot_u32(rt))
    if (destination + u64(size) <= u64(mem_size(rt))) {
        if (source + u64(size) <= u64(mem_size(rt))) {
            // C: memmove (dst, src, size) — Eden: byte by byte on rt.mem; the
            // regions may overlap, so a destination above the source copies
            // from the end, as memmove does
            let dst = int(destination)
            let src = int(source)
            let n = int(size)
            if (dst <= src) {
                for (i in range(n)) {
                    rt.mem[dst + i] = rt.mem[src + i]
                }
            } else {
                for (i in range(n)) {
                    let j = n - 1 - i
                    rt.mem[dst + j] = rt.mem[src + j]
                }
            }
            return nextOpDirect(rt)
        }
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)   // C: d_outOfBoundsMemOp
}


def public op_MemFill(var rt : M3Runtime) : m3ret_t {
    let size = u32(rt.r0)
    let byte = slot_u32(rt)
    let destination = u64(slot_u32(rt))
    if (destination + u64(size) <= u64(mem_size(rt))) {
        // C: memset (mem8, (u8) byte, size) — Eden: byte by byte on rt.mem
        let dst = int(destination)
        for (i in range(int(size))) {
            rt.mem[dst + i] = u8(byte)
        }
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)   // C: d_outOfBoundsMemOp
}


// it's a debate: should the compilation be trigger be the caller or callee page.
// it's a much easier to put it in the caller pager. if it's in the callee, either the entire page
// has be left dangling or it's just a stub that jumps to a newly acquired page.  In Gestalt, I opted
// for the stub approach. Stubbing makes it easier to dynamically free the compilation. You can also
// do both.
def public op_Compile(var rt : M3Runtime) : m3ret_t {
    // C: rewrite_op (op_Call) — * (_pc - 1) = op_Call, the operation word of
    // the op_Compile that is running; Eden: the word of the name, in place
    rt.code[rt.pc - 1] = m3_OpWord("op_Call")
    let _function = immediate_handle(rt)   // C: IM3Function function = immediate (IM3Function)
    var result : M3Result = m3Err_none
    if (rt.functions[_function].compiled == -1) {   // check to see if function was compiled since this operation was emitted.
        result = CompileFunction(rt, _function)
    }
    if (m3ResultIsOk(result)) {
        // patch up compiled pc and call rewritten op_Call
        rt.pc = rt.pc - 1
        rt.code[rt.pc] = u64(rt.functions[_function].compiled)   // C: * ((void**) --_pc) = (void*) (function->compiled)
        rt.pc = rt.pc - 1
        return nextOpDirect(rt)
    }
    return newTrap(rt, result)
}


def public op_Entry(var rt : M3Runtime) : m3ret_t {
    d_m3ClearRegisters(rt)
    let _function = immediate_handle(rt)   // C: IM3Function function = immediate (IM3Function)
    // C: IM3Memory memory = m3MemInfo (_mem) — Eden: absent
    let stackEnd = rt.sp + int(rt.functions[_function].maxStackSlots)
    if (d_m3SkipStackCheck || stackEnd < length(rt.stack)) {   // C: (_sp + maxStackSlots) < _mem->maxStack
        // DEBUG-only hit counter omitted when DEBUG is not part of the Das module configuration.
        // C: u8 * stack = (u8 *) ((m3slot_t *) _sp + function->numRetAndArgSlots)
        var stack = rt.sp + int(rt.functions[_function].numRetAndArgSlots)
        // C: memset (stack, 0x0, function->numLocalBytes) — Eden: one word per slot
        let numLocalSlots = int(u32(rt.functions[_function].numLocalBytes) / u32(typeinfo sizeof(type<m3slot_t>)))
        for (i in range(numLocalSlots)) {
            rt.stack[stack + i] = 0ul
        }
        stack = stack + numLocalSlots   // C: stack += function->numLocalBytes
        if (length(rt.functions[_function].constants) > 0) {   // C: if (function->constants)
            // C: memcpy (stack, function->constants, function->numConstantBytes) — Eden: the constant words
            let numConstants = length(rt.functions[_function].constants)
            for (i in range(numConstants)) {
                rt.stack[stack + i] = rt.functions[_function].constants[i]
            }
        }
        let r = nextOpImpl(rt)
        // C: if (r) { _mem = memory->mallocated; fillBacktraceFrame (); } — Eden:
        // the reload is absent and d_m3RecordBacktraces == false compiles the
        // backtrace out
        return forwardTrap(r)
    }
    return newTrap(rt, m3Err_trapStackOverflow)
}


def public op_Loop(var rt : M3Runtime) : m3ret_t {
    // regs are unused coming into a loop anyway
    // this reduces code size & stack usage
    // C: d_m3ClearRegisters, once; Eden: repeated per iteration below, since
    // C passes the cleared copies to every iteration and the fields are shared
    var r : m3ret_t = M3_NEXT
    // C: IM3Memory memory = m3MemInfo (_mem) — Eden: absent
    let loopPC = rt.pc   // Eden: C's by-value _pc, the loop's body start; also the id op_ContinueLoop returns
    while (true) {
        rt.pc = loopPC
        d_m3ClearRegisters(rt)
        r = nextOpImpl(rt)
        // linear memory pointer needs refreshed here because the block it's looping over
        // can potentially invoke the grow operation.
        // C: _mem = memory->mallocated — Eden: absent
        if (r != loopPC) {   // C: while (r == _pc)
            break
        }
    }
    return forwardTrap(r)
}


def public op_Branch(var rt : M3Runtime) : m3ret_t {
    // C: jumpOp (* _pc) — the word at _pc, not advanced; Eden: the read
    // advances rt.pc, which jumpOpDirect overwrites with the target anyway
    let branch = immediate_pc(rt)
    return jumpOpDirect(rt, branch)
}


def public op_If_r(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let elsePC = immediate_pc(rt)
    if (condition != 0) {
        return nextOpDirect(rt)
    }
    return jumpOpDirect(rt, elsePC)
}


def public op_If_s(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let elsePC = immediate_pc(rt)
    if (condition != 0) {
        return nextOpDirect(rt)
    }
    return jumpOpDirect(rt, elsePC)
}


def public op_BranchTable(var rt : M3Runtime) : m3ret_t {
    var branchIndex = slot_u32(rt)           // branch index is always in a slot
    let numTargets = immediate_u32(rt)
    let branches = rt.pc                     // C: pc_t * branches = (pc_t *) _pc; Eden: the index of the first target word
    if (branchIndex > numTargets) {
        branchIndex = numTargets             // the default index
    }
    let target : pc_t = int(rt.code[branches + int(branchIndex)])   // C: branches [branchIndex]
    return jumpOpDirect(rt, target)
}


def public op_SetRegister_i32(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    rt.r0 = u64(i64(value))   // C: _r0 = slot (i32), sign-extended into m3reg_t
    return nextOpDirect(rt)
}


def public op_SetSlot_i32(var rt : M3Runtime) : m3ret_t {
    set_slot_i32(rt, i32(u32(rt.r0)))   // C: slot (i32) = (i32) _r0
    return nextOpDirect(rt)
}


def public op_PreserveSetSlot_i32(var rt : M3Runtime) : m3ret_t {
    let stack = slot_index(rt)
    let preserve = slot_index(rt)
    set_stack_i32(rt, preserve, stack_i32(rt, stack))   // C: * preserve = * stack
    set_stack_i32(rt, stack, i32(u32(rt.r0)))           // C: * stack = (i32) _r0
    return nextOpDirect(rt)
}


def public op_SetRegister_i64(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    rt.r0 = u64(value)
    return nextOpDirect(rt)
}


def public op_SetSlot_i64(var rt : M3Runtime) : m3ret_t {
    set_slot_i64(rt, i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_PreserveSetSlot_i64(var rt : M3Runtime) : m3ret_t {
    let stack = slot_index(rt)
    let preserve = slot_index(rt)
    set_stack_i64(rt, preserve, stack_i64(rt, stack))
    set_stack_i64(rt, stack, i64(rt.r0))
    return nextOpDirect(rt)
}


def public op_SetRegister_f32(var rt : M3Runtime) : m3ret_t {
    let value = slot_f32(rt)
    rt.fp0 = f64(value)
    return nextOpDirect(rt)
}


def public op_SetSlot_f32(var rt : M3Runtime) : m3ret_t {
    set_slot_f32(rt, f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_PreserveSetSlot_f32(var rt : M3Runtime) : m3ret_t {
    let stack = slot_index(rt)
    let preserve = slot_index(rt)
    set_stack_f32(rt, preserve, stack_f32(rt, stack))
    set_stack_f32(rt, stack, f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_SetRegister_f64(var rt : M3Runtime) : m3ret_t {
    let value = slot_f64(rt)
    rt.fp0 = value
    return nextOpDirect(rt)
}


def public op_SetSlot_f64(var rt : M3Runtime) : m3ret_t {
    set_slot_f64(rt, rt.fp0)
    return nextOpDirect(rt)
}


def public op_PreserveSetSlot_f64(var rt : M3Runtime) : m3ret_t {
    let stack = slot_index(rt)
    let preserve = slot_index(rt)
    set_stack_f64(rt, preserve, stack_f64(rt, stack))
    set_stack_f64(rt, stack, rt.fp0)
    return nextOpDirect(rt)
}


def public op_CopySlot_32(var rt : M3Runtime) : m3ret_t {
    let dst = slot_index(rt)
    let src = slot_index(rt)
    set_stack_u32(rt, dst, stack_u32(rt, src))   // C: * dst = * src
    return nextOpDirect(rt)
}


def public op_PreserveCopySlot_32(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    let src = slot_index(rt)
    let preserve = slot_index(rt)
    set_stack_u32(rt, preserve, stack_u32(rt, dest))   // C: * preserve = * dest
    set_stack_u32(rt, dest, stack_u32(rt, src))        // C: * dest = * src
    return nextOpDirect(rt)
}


def public op_CopySlot_64(var rt : M3Runtime) : m3ret_t {
    let dst = slot_index(rt)
    let src = slot_index(rt)
    set_stack_u64(rt, dst, stack_u64(rt, src))
    return nextOpDirect(rt)
}


def public op_PreserveCopySlot_64(var rt : M3Runtime) : m3ret_t {
    let dest = slot_index(rt)
    let src = slot_index(rt)
    let preserve = slot_index(rt)
    set_stack_u64(rt, preserve, stack_u64(rt, dest))
    set_stack_u64(rt, dest, stack_u64(rt, src))
    return nextOpDirect(rt)
}


// compiled out under the active configuration: d_m3EnableOpTracing == false (op_DumpStack)


def public op_Select_i32_rss(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    if (condition != 0) {
        rt.r0 = u64(i64(operand1))
    } else {
        rt.r0 = u64(i64(operand2))
    }
    return nextOpDirect(rt)
}


def public op_Select_i32_srs(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand1 = slot_i32(rt)
    if (condition != 0) {
        rt.r0 = u64(i64(operand1))
    } else {
        rt.r0 = u64(i64(i32(u32(rt.r0))))   // C: _r0 = (i32) _r0
    }
    return nextOpDirect(rt)
}


def public op_Select_i32_ssr(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_i32(rt)
    if (condition != 0) {
        rt.r0 = u64(i64(i32(u32(rt.r0))))
    } else {
        rt.r0 = u64(i64(operand2))
    }
    return nextOpDirect(rt)
}


def public op_Select_i32_sss(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_i32(rt)
    let operand1 = slot_i32(rt)
    if (condition != 0) {
        rt.r0 = u64(i64(operand1))
    } else {
        rt.r0 = u64(i64(operand2))
    }
    return nextOpDirect(rt)
}


def public op_Select_i64_rss(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    if (condition != 0) {
        rt.r0 = u64(operand1)
    } else {
        rt.r0 = u64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_i64_srs(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand1 = slot_i64(rt)
    if (condition != 0) {
        rt.r0 = u64(operand1)
    } else {
        rt.r0 = rt.r0
    }
    return nextOpDirect(rt)
}


def public op_Select_i64_ssr(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_i64(rt)
    if (condition != 0) {
        rt.r0 = rt.r0
    } else {
        rt.r0 = u64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_i64_sss(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_i64(rt)
    let operand1 = slot_i64(rt)
    if (condition != 0) {
        rt.r0 = u64(operand1)
    } else {
        rt.r0 = u64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_f32_sss(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    if (condition != 0) {
        rt.fp0 = f64(operand1)
    } else {
        rt.fp0 = f64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_f32_srs(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand1 = slot_f32(rt)
    if (condition != 0) {
        rt.fp0 = f64(operand1)
    } else {
        rt.fp0 = f64(f32(rt.fp0))
    }
    return nextOpDirect(rt)
}


def public op_Select_f32_ssr(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_f32(rt)
    if (condition != 0) {
        rt.fp0 = f64(f32(rt.fp0))
    } else {
        rt.fp0 = f64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_f32_rss(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand2 = slot_f32(rt)
    let operand1 = slot_f32(rt)
    if (condition != 0) {
        rt.fp0 = f64(operand1)
    } else {
        rt.fp0 = f64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_f32_rrs(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand1 = slot_f32(rt)
    if (condition != 0) {
        rt.fp0 = f64(operand1)
    } else {
        rt.fp0 = f64(f32(rt.fp0))
    }
    return nextOpDirect(rt)
}


def public op_Select_f32_rsr(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand2 = slot_f32(rt)
    if (condition != 0) {
        rt.fp0 = f64(f32(rt.fp0))
    } else {
        rt.fp0 = f64(operand2)
    }
    return nextOpDirect(rt)
}


def public op_Select_f64_sss(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    if (condition != 0) {
        rt.fp0 = operand1
    } else {
        rt.fp0 = operand2
    }
    return nextOpDirect(rt)
}


def public op_Select_f64_srs(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand1 = slot_f64(rt)
    if (condition != 0) {
        rt.fp0 = operand1
    } else {
        rt.fp0 = rt.fp0
    }
    return nextOpDirect(rt)
}


def public op_Select_f64_ssr(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let operand2 = slot_f64(rt)
    if (condition != 0) {
        rt.fp0 = rt.fp0
    } else {
        rt.fp0 = operand2
    }
    return nextOpDirect(rt)
}


def public op_Select_f64_rss(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand2 = slot_f64(rt)
    let operand1 = slot_f64(rt)
    if (condition != 0) {
        rt.fp0 = operand1
    } else {
        rt.fp0 = operand2
    }
    return nextOpDirect(rt)
}


def public op_Select_f64_rrs(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand1 = slot_f64(rt)
    if (condition != 0) {
        rt.fp0 = operand1
    } else {
        rt.fp0 = rt.fp0
    }
    return nextOpDirect(rt)
}


def public op_Select_f64_rsr(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let operand2 = slot_f64(rt)
    if (condition != 0) {
        rt.fp0 = rt.fp0
    } else {
        rt.fp0 = operand2
    }
    return nextOpDirect(rt)
}


def public op_Return(var rt : M3Runtime) : m3ret_t {
    if (d_m3LogNativeStack) {   // C: an empty macro unless d_m3LogNativeStack
        m3StackCheck()
    }
    return retOp(rt)   // C: return m3Err_none
}


def public op_BranchIf_r(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let branch = immediate_pc(rt)
    if (condition != 0) {
        return jumpOpDirect(rt, branch)
    }
    return nextOpDirect(rt)
}


def public op_BranchIf_s(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let branch = immediate_pc(rt)
    if (condition != 0) {
        return jumpOpDirect(rt, branch)
    }
    return nextOpDirect(rt)
}


def public op_BranchIfPrologue_r(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let branch = immediate_pc(rt)
    if (condition != 0) {
        // this is the "prologue" that ends with
        // a plain branch to the actual target
        return nextOpDirect(rt)
    }
    return jumpOpDirect(rt, branch)   // jump over the prologue
}


def public op_BranchIfPrologue_s(var rt : M3Runtime) : m3ret_t {
    let condition = slot_i32(rt)
    let branch = immediate_pc(rt)
    if (condition != 0) {
        return nextOpDirect(rt)
    }
    return jumpOpDirect(rt, branch)
}


def public op_ContinueLoop(var rt : M3Runtime) : m3ret_t {
    if (d_m3LogNativeStack) {   // C: an empty macro unless d_m3LogNativeStack
        m3StackCheck()
    }
    // TODO: this is where execution can "escape" the M3 code and callback to the client / fiber switch
    // OR it can go in the Loop operation. I think it's best to do here. adding code to the loop operation
    // has the potential to increase its native-stack usage. (don't forget ContinueLoopIf too.)
    let loopId = immediate_pc(rt)   // C: void * loopId = immediate (void *); Eden: the loop's pc (DESIGN 4.4)
    return loopId
}


def public op_ContinueLoopIf(var rt : M3Runtime) : m3ret_t {
    let condition = i32(u32(rt.r0))
    let loopId = immediate_pc(rt)
    if (condition != 0) {
        return loopId
    }
    return nextOpDirect(rt)
}


def public op_Const32(var rt : M3Runtime) : m3ret_t {
    let value = immediate_u32(rt)   // C: u32 value = * (u32 *)_pc++
    set_slot_u32(rt, value)
    return nextOpDirect(rt)
}


def public op_Const64(var rt : M3Runtime) : m3ret_t {
    let value = immediate_u64(rt)   // C: u64 value = * (u64 *)_pc; _pc += (M3_SIZEOF_PTR == 4) ? 2 : 1 — Eden: one word
    set_slot_u64(rt, value)
    return nextOpDirect(rt)
}


def public op_Unsupported(var rt : M3Runtime) : m3ret_t {
    return newTrap(rt, "unsupported instruction executed")
}


def public op_Unreachable(var rt : M3Runtime) : m3ret_t {
    if (d_m3LogNativeStack) {   // C: an empty macro unless d_m3LogNativeStack
        m3StackCheck()
    }
    return newTrap(rt, m3Err_trapUnreachable)
}


def public op_End(var rt : M3Runtime) : m3ret_t {
    if (d_m3LogNativeStack) {   // C: an empty macro unless d_m3LogNativeStack
        m3StackCheck()
    }
    return retOp(rt)   // C: return m3Err_none
}


def public op_SetGlobal_s32(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)   // C: u32 * global = immediate (u32 *)
    let value = slot_u32(rt)
    M3Global_SetI32Value(rt.globals[global], i32(value))   // C: * global = slot (u32), the low four bytes
    return nextOpDirect(rt)
}


def public op_SetGlobal_s64(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)
    let value = slot_u64(rt)
    M3Global_SetI64Value(rt.globals[global], i64(value))
    return nextOpDirect(rt)
}


def public op_SetGlobal_f32(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)
    M3Global_SetF32Value(rt.globals[global], f32(rt.fp0))
    return nextOpDirect(rt)
}


def public op_SetGlobal_f64(var rt : M3Runtime) : m3ret_t {
    let global = immediate_handle(rt)
    M3Global_SetF64Value(rt.globals[global], rt.fp0)
    return nextOpDirect(rt)
}


/* The load and store operations below. C writes the access through memcpy of
   a constant size (m3_exec.h, d_m3Load/d_m3Store) and says why at the macro:
   "memcpy here is to support non-aligned access on some platforms". Eden: the
   access is the little-endian assembly of the bytes by load_T / store_T of
   m3_exec_defs (DESIGN.md section 4.2), which needs no alignment; the bounds
   check `address + sizeof (TYPE) <= _mem->length` is C's, against mem_size(rt),
   with C's trap string. The register writes keep C's conversions: an i32
   result is sign-extended into the i64 register (m3reg_t), a u8/u16/u32 source
   zero-extended, a float result widened to the f64 register. */
def public op_f32_Load_f32_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= u64(mem_size(rt))) {
        let value = load_f32(rt, int(operand))
        rt.fp0 = f64(value)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f32_Load_f32_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= u64(mem_size(rt))) {
        let value = load_f32(rt, int(operand))
        rt.fp0 = f64(value)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f64_Load_f64_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= u64(mem_size(rt))) {
        let value = load_f64(rt, int(operand))
        rt.fp0 = value
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f64_Load_f64_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= u64(mem_size(rt))) {
        let value = load_f64(rt, int(operand))
        rt.fp0 = value
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_i8_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= u64(mem_size(rt))) {
        let value = load_s8(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_i8_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= u64(mem_size(rt))) {
        let value = load_s8(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_u8_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let value = load_u8(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_u8_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let value = load_u8(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_i16_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let value = load_s16(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_i16_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let value = load_s16(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_u16_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= u64(mem_size(rt))) {
        let value = load_u16(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_u16_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= u64(mem_size(rt))) {
        let value = load_u16(rt, int(operand))
        rt.r0 = u64(i64(i32(value)))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_i32_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let value = load_i32(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Load_i32_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let value = load_i32(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i8_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= u64(mem_size(rt))) {
        let value = load_s8(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i8_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= u64(mem_size(rt))) {
        let value = load_s8(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_u8_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let value = load_u8(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_u8_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let value = load_u8(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i16_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let value = load_s16(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i16_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let value = load_s16(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_u16_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= u64(mem_size(rt))) {
        let value = load_u16(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_u16_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= u64(mem_size(rt))) {
        let value = load_u16(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i32_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let value = load_i32(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i32_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let value = load_i32(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_u32_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u32>)) <= u64(mem_size(rt))) {
        let value = load_u32(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_u32_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u32>)) <= u64(mem_size(rt))) {
        let value = load_u32(rt, int(operand))
        rt.r0 = u64(i64(value))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i64_r(var rt : M3Runtime) : m3ret_t {
    let offset = immediate_u32(rt)
    var operand = u64(u32(rt.r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= u64(mem_size(rt))) {
        let value = load_i64(rt, int(operand))
        rt.r0 = u64(value)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Load_i64_s(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= u64(mem_size(rt))) {
        let value = load_i64(rt, int(operand))
        rt.r0 = u64(value)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f32_Store_f32_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= u64(mem_size(rt))) {
        let val = f32(rt.fp0)
        store_f32(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f32_Store_f32_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_f32(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= u64(mem_size(rt))) {
        let val = value
        store_f32(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f32_Store_f32_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_f32(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= u64(mem_size(rt))) {
        let val = value
        store_f32(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f32_Store_f32_rr(var rt : M3Runtime) : m3ret_t {
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= u64(mem_size(rt))) {
        let val = f32(rt.fp0)
        store_f32(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f64_Store_f64_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= u64(mem_size(rt))) {
        let val = rt.fp0
        store_f64(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f64_Store_f64_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_f64(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= u64(mem_size(rt))) {
        let val = value
        store_f64(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f64_Store_f64_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_f64(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= u64(mem_size(rt))) {
        let val = value
        store_f64(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_f64_Store_f64_rr(var rt : M3Runtime) : m3ret_t {
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= u64(mem_size(rt))) {
        let val = rt.fp0
        store_f64(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_u8_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let val = u8(i32(u32(rt.r0)))
        store_u8(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_u8_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let val = u8(value)
        store_u8(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_u8_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let val = u8(value)
        store_u8(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_i16_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let val = i16(i32(u32(rt.r0)))
        store_u16(rt, int(operand), u16(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_i16_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let val = i16(value)
        store_u16(rt, int(operand), u16(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_i16_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let val = i16(value)
        store_u16(rt, int(operand), u16(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_i32_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let val = i32(u32(rt.r0))
        store_u32(rt, int(operand), u32(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_i32_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let val = value
        store_u32(rt, int(operand), u32(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i32_Store_i32_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i32(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let val = value
        store_u32(rt, int(operand), u32(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_u8_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let val = u8(rt.r0)
        store_u8(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_u8_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let val = u8(value)
        store_u8(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_u8_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= u64(mem_size(rt))) {
        let val = u8(value)
        store_u8(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i16_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let val = i16(i64(rt.r0))
        store_u16(rt, int(operand), u16(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i16_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let val = i16(value)
        store_u16(rt, int(operand), u16(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i16_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= u64(mem_size(rt))) {
        let val = i16(value)
        store_u16(rt, int(operand), u16(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i32_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let val = i32(u32(rt.r0))
        store_u32(rt, int(operand), u32(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i32_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let val = i32(value)
        store_u32(rt, int(operand), u32(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i32_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= u64(mem_size(rt))) {
        let val = i32(value)
        store_u32(rt, int(operand), u32(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i64_rs(var rt : M3Runtime) : m3ret_t {
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= u64(mem_size(rt))) {
        let val = rt.r0
        store_u64(rt, int(operand), val)
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i64_sr(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(u32(rt.r0))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= u64(mem_size(rt))) {
        let val = value
        store_u64(rt, int(operand), u64(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


def public op_i64_Store_i64_ss(var rt : M3Runtime) : m3ret_t {
    let value = slot_i64(rt)
    var operand = u64(slot_u32(rt))
    let offset = immediate_u32(rt)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= u64(mem_size(rt))) {
        let val = value
        store_u64(rt, int(operand), u64(val))
        return nextOpDirect(rt)
    }
    return newTrap(rt, m3Err_trapOutOfBoundsMemoryAccess)
}


// debugOp (d_m3EnableOpTracing) and profileOp (d_m3EnableOpProfiling) are
// compiled out under the active configuration.


// ============================================================================
// The op table (DESIGN.md section 4.4)
// ============================================================================


// Eden: registers every operation by name, one line per operation, in the
// order of the upstream file (op_NoOp first, then the families in file
// order); the index is the registration order, and only consistency between
// this table and the compiler's name lookups matters. Idempotent: a second
// call rebuilds the same table. The three parts of the port register in
// file order: op_NoOp, the part-2 families, the part-3 conversions, then
// the part-1 operations from op_GetGlobal_s32 on.
def public m3_build_op_table() {
    clear(g_ops)
    clear(g_opIndex)
    m3_register_op("op_NoOp", @@op_NoOp)
    // op_i32_Equal_rs ... op_u64_Popcnt_s (the compare, arithmetic, bit and
    // float families, upstream lines 621 - 2282)
    m3_register_op("op_i32_Equal_rs", @@op_i32_Equal_rs)
    m3_register_op("op_i32_Equal_ss", @@op_i32_Equal_ss)
    m3_register_op("op_i32_NotEqual_rs", @@op_i32_NotEqual_rs)
    m3_register_op("op_i32_NotEqual_ss", @@op_i32_NotEqual_ss)
    m3_register_op("op_i32_LessThan_sr", @@op_i32_LessThan_sr)
    m3_register_op("op_i32_LessThan_rs", @@op_i32_LessThan_rs)
    m3_register_op("op_i32_LessThan_ss", @@op_i32_LessThan_ss)
    m3_register_op("op_i32_GreaterThan_sr", @@op_i32_GreaterThan_sr)
    m3_register_op("op_i32_GreaterThan_rs", @@op_i32_GreaterThan_rs)
    m3_register_op("op_i32_GreaterThan_ss", @@op_i32_GreaterThan_ss)
    m3_register_op("op_i32_LessThanOrEqual_sr", @@op_i32_LessThanOrEqual_sr)
    m3_register_op("op_i32_LessThanOrEqual_rs", @@op_i32_LessThanOrEqual_rs)
    m3_register_op("op_i32_LessThanOrEqual_ss", @@op_i32_LessThanOrEqual_ss)
    m3_register_op("op_i32_GreaterThanOrEqual_sr", @@op_i32_GreaterThanOrEqual_sr)
    m3_register_op("op_i32_GreaterThanOrEqual_rs", @@op_i32_GreaterThanOrEqual_rs)
    m3_register_op("op_i32_GreaterThanOrEqual_ss", @@op_i32_GreaterThanOrEqual_ss)
    m3_register_op("op_i64_Equal_rs", @@op_i64_Equal_rs)
    m3_register_op("op_i64_Equal_ss", @@op_i64_Equal_ss)
    m3_register_op("op_i64_NotEqual_rs", @@op_i64_NotEqual_rs)
    m3_register_op("op_i64_NotEqual_ss", @@op_i64_NotEqual_ss)
    m3_register_op("op_i64_LessThan_sr", @@op_i64_LessThan_sr)
    m3_register_op("op_i64_LessThan_rs", @@op_i64_LessThan_rs)
    m3_register_op("op_i64_LessThan_ss", @@op_i64_LessThan_ss)
    m3_register_op("op_i64_GreaterThan_sr", @@op_i64_GreaterThan_sr)
    m3_register_op("op_i64_GreaterThan_rs", @@op_i64_GreaterThan_rs)
    m3_register_op("op_i64_GreaterThan_ss", @@op_i64_GreaterThan_ss)
    m3_register_op("op_i64_LessThanOrEqual_sr", @@op_i64_LessThanOrEqual_sr)
    m3_register_op("op_i64_LessThanOrEqual_rs", @@op_i64_LessThanOrEqual_rs)
    m3_register_op("op_i64_LessThanOrEqual_ss", @@op_i64_LessThanOrEqual_ss)
    m3_register_op("op_i64_GreaterThanOrEqual_sr", @@op_i64_GreaterThanOrEqual_sr)
    m3_register_op("op_i64_GreaterThanOrEqual_rs", @@op_i64_GreaterThanOrEqual_rs)
    m3_register_op("op_i64_GreaterThanOrEqual_ss", @@op_i64_GreaterThanOrEqual_ss)
    m3_register_op("op_u32_LessThan_sr", @@op_u32_LessThan_sr)
    m3_register_op("op_u32_LessThan_rs", @@op_u32_LessThan_rs)
    m3_register_op("op_u32_LessThan_ss", @@op_u32_LessThan_ss)
    m3_register_op("op_u32_GreaterThan_sr", @@op_u32_GreaterThan_sr)
    m3_register_op("op_u32_GreaterThan_rs", @@op_u32_GreaterThan_rs)
    m3_register_op("op_u32_GreaterThan_ss", @@op_u32_GreaterThan_ss)
    m3_register_op("op_u32_LessThanOrEqual_sr", @@op_u32_LessThanOrEqual_sr)
    m3_register_op("op_u32_LessThanOrEqual_rs", @@op_u32_LessThanOrEqual_rs)
    m3_register_op("op_u32_LessThanOrEqual_ss", @@op_u32_LessThanOrEqual_ss)
    m3_register_op("op_u32_GreaterThanOrEqual_sr", @@op_u32_GreaterThanOrEqual_sr)
    m3_register_op("op_u32_GreaterThanOrEqual_rs", @@op_u32_GreaterThanOrEqual_rs)
    m3_register_op("op_u32_GreaterThanOrEqual_ss", @@op_u32_GreaterThanOrEqual_ss)
    m3_register_op("op_u64_LessThan_sr", @@op_u64_LessThan_sr)
    m3_register_op("op_u64_LessThan_rs", @@op_u64_LessThan_rs)
    m3_register_op("op_u64_LessThan_ss", @@op_u64_LessThan_ss)
    m3_register_op("op_u64_GreaterThan_sr", @@op_u64_GreaterThan_sr)
    m3_register_op("op_u64_GreaterThan_rs", @@op_u64_GreaterThan_rs)
    m3_register_op("op_u64_GreaterThan_ss", @@op_u64_GreaterThan_ss)
    m3_register_op("op_u64_LessThanOrEqual_sr", @@op_u64_LessThanOrEqual_sr)
    m3_register_op("op_u64_LessThanOrEqual_rs", @@op_u64_LessThanOrEqual_rs)
    m3_register_op("op_u64_LessThanOrEqual_ss", @@op_u64_LessThanOrEqual_ss)
    m3_register_op("op_u64_GreaterThanOrEqual_sr", @@op_u64_GreaterThanOrEqual_sr)
    m3_register_op("op_u64_GreaterThanOrEqual_rs", @@op_u64_GreaterThanOrEqual_rs)
    m3_register_op("op_u64_GreaterThanOrEqual_ss", @@op_u64_GreaterThanOrEqual_ss)
    m3_register_op("op_f32_Equal_rs", @@op_f32_Equal_rs)
    m3_register_op("op_f32_Equal_ss", @@op_f32_Equal_ss)
    m3_register_op("op_f32_NotEqual_rs", @@op_f32_NotEqual_rs)
    m3_register_op("op_f32_NotEqual_ss", @@op_f32_NotEqual_ss)
    m3_register_op("op_f32_LessThan_sr", @@op_f32_LessThan_sr)
    m3_register_op("op_f32_LessThan_rs", @@op_f32_LessThan_rs)
    m3_register_op("op_f32_LessThan_ss", @@op_f32_LessThan_ss)
    m3_register_op("op_f32_GreaterThan_sr", @@op_f32_GreaterThan_sr)
    m3_register_op("op_f32_GreaterThan_rs", @@op_f32_GreaterThan_rs)
    m3_register_op("op_f32_GreaterThan_ss", @@op_f32_GreaterThan_ss)
    m3_register_op("op_f32_LessThanOrEqual_sr", @@op_f32_LessThanOrEqual_sr)
    m3_register_op("op_f32_LessThanOrEqual_rs", @@op_f32_LessThanOrEqual_rs)
    m3_register_op("op_f32_LessThanOrEqual_ss", @@op_f32_LessThanOrEqual_ss)
    m3_register_op("op_f32_GreaterThanOrEqual_sr", @@op_f32_GreaterThanOrEqual_sr)
    m3_register_op("op_f32_GreaterThanOrEqual_rs", @@op_f32_GreaterThanOrEqual_rs)
    m3_register_op("op_f32_GreaterThanOrEqual_ss", @@op_f32_GreaterThanOrEqual_ss)
    m3_register_op("op_f64_Equal_rs", @@op_f64_Equal_rs)
    m3_register_op("op_f64_Equal_ss", @@op_f64_Equal_ss)
    m3_register_op("op_f64_NotEqual_rs", @@op_f64_NotEqual_rs)
    m3_register_op("op_f64_NotEqual_ss", @@op_f64_NotEqual_ss)
    m3_register_op("op_f64_LessThan_sr", @@op_f64_LessThan_sr)
    m3_register_op("op_f64_LessThan_rs", @@op_f64_LessThan_rs)
    m3_register_op("op_f64_LessThan_ss", @@op_f64_LessThan_ss)
    m3_register_op("op_f64_GreaterThan_sr", @@op_f64_GreaterThan_sr)
    m3_register_op("op_f64_GreaterThan_rs", @@op_f64_GreaterThan_rs)
    m3_register_op("op_f64_GreaterThan_ss", @@op_f64_GreaterThan_ss)
    m3_register_op("op_f64_LessThanOrEqual_sr", @@op_f64_LessThanOrEqual_sr)
    m3_register_op("op_f64_LessThanOrEqual_rs", @@op_f64_LessThanOrEqual_rs)
    m3_register_op("op_f64_LessThanOrEqual_ss", @@op_f64_LessThanOrEqual_ss)
    m3_register_op("op_f64_GreaterThanOrEqual_sr", @@op_f64_GreaterThanOrEqual_sr)
    m3_register_op("op_f64_GreaterThanOrEqual_rs", @@op_f64_GreaterThanOrEqual_rs)
    m3_register_op("op_f64_GreaterThanOrEqual_ss", @@op_f64_GreaterThanOrEqual_ss)
    m3_register_op("op_i32_Add_rs", @@op_i32_Add_rs)
    m3_register_op("op_i32_Add_ss", @@op_i32_Add_ss)
    m3_register_op("op_i64_Add_rs", @@op_i64_Add_rs)
    m3_register_op("op_i64_Add_ss", @@op_i64_Add_ss)
    m3_register_op("op_i32_Multiply_rs", @@op_i32_Multiply_rs)
    m3_register_op("op_i32_Multiply_ss", @@op_i32_Multiply_ss)
    m3_register_op("op_i64_Multiply_rs", @@op_i64_Multiply_rs)
    m3_register_op("op_i64_Multiply_ss", @@op_i64_Multiply_ss)
    m3_register_op("op_i32_Subtract_sr", @@op_i32_Subtract_sr)
    m3_register_op("op_i32_Subtract_rs", @@op_i32_Subtract_rs)
    m3_register_op("op_i32_Subtract_ss", @@op_i32_Subtract_ss)
    m3_register_op("op_i64_Subtract_sr", @@op_i64_Subtract_sr)
    m3_register_op("op_i64_Subtract_rs", @@op_i64_Subtract_rs)
    m3_register_op("op_i64_Subtract_ss", @@op_i64_Subtract_ss)
    m3_register_op("op_u32_ShiftLeft_sr", @@op_u32_ShiftLeft_sr)
    m3_register_op("op_u32_ShiftLeft_rs", @@op_u32_ShiftLeft_rs)
    m3_register_op("op_u32_ShiftLeft_ss", @@op_u32_ShiftLeft_ss)
    m3_register_op("op_u64_ShiftLeft_sr", @@op_u64_ShiftLeft_sr)
    m3_register_op("op_u64_ShiftLeft_rs", @@op_u64_ShiftLeft_rs)
    m3_register_op("op_u64_ShiftLeft_ss", @@op_u64_ShiftLeft_ss)
    m3_register_op("op_i32_ShiftRight_sr", @@op_i32_ShiftRight_sr)
    m3_register_op("op_i32_ShiftRight_rs", @@op_i32_ShiftRight_rs)
    m3_register_op("op_i32_ShiftRight_ss", @@op_i32_ShiftRight_ss)
    m3_register_op("op_i64_ShiftRight_sr", @@op_i64_ShiftRight_sr)
    m3_register_op("op_i64_ShiftRight_rs", @@op_i64_ShiftRight_rs)
    m3_register_op("op_i64_ShiftRight_ss", @@op_i64_ShiftRight_ss)
    m3_register_op("op_u32_ShiftRight_sr", @@op_u32_ShiftRight_sr)
    m3_register_op("op_u32_ShiftRight_rs", @@op_u32_ShiftRight_rs)
    m3_register_op("op_u32_ShiftRight_ss", @@op_u32_ShiftRight_ss)
    m3_register_op("op_u64_ShiftRight_sr", @@op_u64_ShiftRight_sr)
    m3_register_op("op_u64_ShiftRight_rs", @@op_u64_ShiftRight_rs)
    m3_register_op("op_u64_ShiftRight_ss", @@op_u64_ShiftRight_ss)
    m3_register_op("op_u32_And_rs", @@op_u32_And_rs)
    m3_register_op("op_u32_And_ss", @@op_u32_And_ss)
    m3_register_op("op_u32_Or_rs", @@op_u32_Or_rs)
    m3_register_op("op_u32_Or_ss", @@op_u32_Or_ss)
    m3_register_op("op_u32_Xor_rs", @@op_u32_Xor_rs)
    m3_register_op("op_u32_Xor_ss", @@op_u32_Xor_ss)
    m3_register_op("op_u64_And_rs", @@op_u64_And_rs)
    m3_register_op("op_u64_And_ss", @@op_u64_And_ss)
    m3_register_op("op_u64_Or_rs", @@op_u64_Or_rs)
    m3_register_op("op_u64_Or_ss", @@op_u64_Or_ss)
    m3_register_op("op_u64_Xor_rs", @@op_u64_Xor_rs)
    m3_register_op("op_u64_Xor_ss", @@op_u64_Xor_ss)
    m3_register_op("op_f32_Add_rs", @@op_f32_Add_rs)
    m3_register_op("op_f32_Add_ss", @@op_f32_Add_ss)
    m3_register_op("op_f32_Multiply_rs", @@op_f32_Multiply_rs)
    m3_register_op("op_f32_Multiply_ss", @@op_f32_Multiply_ss)
    m3_register_op("op_f32_Subtract_sr", @@op_f32_Subtract_sr)
    m3_register_op("op_f32_Subtract_rs", @@op_f32_Subtract_rs)
    m3_register_op("op_f32_Subtract_ss", @@op_f32_Subtract_ss)
    m3_register_op("op_f32_Divide_sr", @@op_f32_Divide_sr)
    m3_register_op("op_f32_Divide_rs", @@op_f32_Divide_rs)
    m3_register_op("op_f32_Divide_ss", @@op_f32_Divide_ss)
    m3_register_op("op_f64_Add_rs", @@op_f64_Add_rs)
    m3_register_op("op_f64_Add_ss", @@op_f64_Add_ss)
    m3_register_op("op_f64_Multiply_rs", @@op_f64_Multiply_rs)
    m3_register_op("op_f64_Multiply_ss", @@op_f64_Multiply_ss)
    m3_register_op("op_f64_Subtract_sr", @@op_f64_Subtract_sr)
    m3_register_op("op_f64_Subtract_rs", @@op_f64_Subtract_rs)
    m3_register_op("op_f64_Subtract_ss", @@op_f64_Subtract_ss)
    m3_register_op("op_f64_Divide_sr", @@op_f64_Divide_sr)
    m3_register_op("op_f64_Divide_rs", @@op_f64_Divide_rs)
    m3_register_op("op_f64_Divide_ss", @@op_f64_Divide_ss)
    m3_register_op("op_u32_Rotl_sr", @@op_u32_Rotl_sr)
    m3_register_op("op_u32_Rotl_rs", @@op_u32_Rotl_rs)
    m3_register_op("op_u32_Rotl_ss", @@op_u32_Rotl_ss)
    m3_register_op("op_u32_Rotr_sr", @@op_u32_Rotr_sr)
    m3_register_op("op_u32_Rotr_rs", @@op_u32_Rotr_rs)
    m3_register_op("op_u32_Rotr_ss", @@op_u32_Rotr_ss)
    m3_register_op("op_u64_Rotl_sr", @@op_u64_Rotl_sr)
    m3_register_op("op_u64_Rotl_rs", @@op_u64_Rotl_rs)
    m3_register_op("op_u64_Rotl_ss", @@op_u64_Rotl_ss)
    m3_register_op("op_u64_Rotr_sr", @@op_u64_Rotr_sr)
    m3_register_op("op_u64_Rotr_rs", @@op_u64_Rotr_rs)
    m3_register_op("op_u64_Rotr_ss", @@op_u64_Rotr_ss)
    m3_register_op("op_u32_Divide_sr", @@op_u32_Divide_sr)
    m3_register_op("op_u32_Divide_rs", @@op_u32_Divide_rs)
    m3_register_op("op_u32_Divide_ss", @@op_u32_Divide_ss)
    m3_register_op("op_u32_Remainder_sr", @@op_u32_Remainder_sr)
    m3_register_op("op_u32_Remainder_rs", @@op_u32_Remainder_rs)
    m3_register_op("op_u32_Remainder_ss", @@op_u32_Remainder_ss)
    m3_register_op("op_i32_Divide_sr", @@op_i32_Divide_sr)
    m3_register_op("op_i32_Divide_rs", @@op_i32_Divide_rs)
    m3_register_op("op_i32_Divide_ss", @@op_i32_Divide_ss)
    m3_register_op("op_i32_Remainder_sr", @@op_i32_Remainder_sr)
    m3_register_op("op_i32_Remainder_rs", @@op_i32_Remainder_rs)
    m3_register_op("op_i32_Remainder_ss", @@op_i32_Remainder_ss)
    m3_register_op("op_u64_Divide_sr", @@op_u64_Divide_sr)
    m3_register_op("op_u64_Divide_rs", @@op_u64_Divide_rs)
    m3_register_op("op_u64_Divide_ss", @@op_u64_Divide_ss)
    m3_register_op("op_u64_Remainder_sr", @@op_u64_Remainder_sr)
    m3_register_op("op_u64_Remainder_rs", @@op_u64_Remainder_rs)
    m3_register_op("op_u64_Remainder_ss", @@op_u64_Remainder_ss)
    m3_register_op("op_i64_Divide_sr", @@op_i64_Divide_sr)
    m3_register_op("op_i64_Divide_rs", @@op_i64_Divide_rs)
    m3_register_op("op_i64_Divide_ss", @@op_i64_Divide_ss)
    m3_register_op("op_i64_Remainder_sr", @@op_i64_Remainder_sr)
    m3_register_op("op_i64_Remainder_rs", @@op_i64_Remainder_rs)
    m3_register_op("op_i64_Remainder_ss", @@op_i64_Remainder_ss)
    m3_register_op("op_f32_Min_sr", @@op_f32_Min_sr)
    m3_register_op("op_f32_Min_rs", @@op_f32_Min_rs)
    m3_register_op("op_f32_Min_ss", @@op_f32_Min_ss)
    m3_register_op("op_f32_Max_sr", @@op_f32_Max_sr)
    m3_register_op("op_f32_Max_rs", @@op_f32_Max_rs)
    m3_register_op("op_f32_Max_ss", @@op_f32_Max_ss)
    m3_register_op("op_f32_CopySign_sr", @@op_f32_CopySign_sr)
    m3_register_op("op_f32_CopySign_rs", @@op_f32_CopySign_rs)
    m3_register_op("op_f32_CopySign_ss", @@op_f32_CopySign_ss)
    m3_register_op("op_f64_Min_sr", @@op_f64_Min_sr)
    m3_register_op("op_f64_Min_rs", @@op_f64_Min_rs)
    m3_register_op("op_f64_Min_ss", @@op_f64_Min_ss)
    m3_register_op("op_f64_Max_sr", @@op_f64_Max_sr)
    m3_register_op("op_f64_Max_rs", @@op_f64_Max_rs)
    m3_register_op("op_f64_Max_ss", @@op_f64_Max_ss)
    m3_register_op("op_f64_CopySign_sr", @@op_f64_CopySign_sr)
    m3_register_op("op_f64_CopySign_rs", @@op_f64_CopySign_rs)
    m3_register_op("op_f64_CopySign_ss", @@op_f64_CopySign_ss)
    m3_register_op("op_f32_Abs_r", @@op_f32_Abs_r)
    m3_register_op("op_f32_Abs_s", @@op_f32_Abs_s)
    m3_register_op("op_f32_Ceil_r", @@op_f32_Ceil_r)
    m3_register_op("op_f32_Ceil_s", @@op_f32_Ceil_s)
    m3_register_op("op_f32_Floor_r", @@op_f32_Floor_r)
    m3_register_op("op_f32_Floor_s", @@op_f32_Floor_s)
    m3_register_op("op_f32_Trunc_r", @@op_f32_Trunc_r)
    m3_register_op("op_f32_Trunc_s", @@op_f32_Trunc_s)
    m3_register_op("op_f32_Sqrt_r", @@op_f32_Sqrt_r)
    m3_register_op("op_f32_Sqrt_s", @@op_f32_Sqrt_s)
    m3_register_op("op_f32_Nearest_r", @@op_f32_Nearest_r)
    m3_register_op("op_f32_Nearest_s", @@op_f32_Nearest_s)
    m3_register_op("op_f32_Negate_r", @@op_f32_Negate_r)
    m3_register_op("op_f32_Negate_s", @@op_f32_Negate_s)
    m3_register_op("op_f64_Abs_r", @@op_f64_Abs_r)
    m3_register_op("op_f64_Abs_s", @@op_f64_Abs_s)
    m3_register_op("op_f64_Ceil_r", @@op_f64_Ceil_r)
    m3_register_op("op_f64_Ceil_s", @@op_f64_Ceil_s)
    m3_register_op("op_f64_Floor_r", @@op_f64_Floor_r)
    m3_register_op("op_f64_Floor_s", @@op_f64_Floor_s)
    m3_register_op("op_f64_Trunc_r", @@op_f64_Trunc_r)
    m3_register_op("op_f64_Trunc_s", @@op_f64_Trunc_s)
    m3_register_op("op_f64_Sqrt_r", @@op_f64_Sqrt_r)
    m3_register_op("op_f64_Sqrt_s", @@op_f64_Sqrt_s)
    m3_register_op("op_f64_Nearest_r", @@op_f64_Nearest_r)
    m3_register_op("op_f64_Nearest_s", @@op_f64_Nearest_s)
    m3_register_op("op_f64_Negate_r", @@op_f64_Negate_r)
    m3_register_op("op_f64_Negate_s", @@op_f64_Negate_s)
    m3_register_op("op_i32_EqualToZero_r", @@op_i32_EqualToZero_r)
    m3_register_op("op_i32_EqualToZero_s", @@op_i32_EqualToZero_s)
    m3_register_op("op_i64_EqualToZero_r", @@op_i64_EqualToZero_r)
    m3_register_op("op_i64_EqualToZero_s", @@op_i64_EqualToZero_s)
    m3_register_op("op_u32_Clz_r", @@op_u32_Clz_r)
    m3_register_op("op_u32_Clz_s", @@op_u32_Clz_s)
    m3_register_op("op_u32_Ctz_r", @@op_u32_Ctz_r)
    m3_register_op("op_u32_Ctz_s", @@op_u32_Ctz_s)
    m3_register_op("op_u32_Popcnt_r", @@op_u32_Popcnt_r)
    m3_register_op("op_u32_Popcnt_s", @@op_u32_Popcnt_s)
    m3_register_op("op_u64_Clz_r", @@op_u64_Clz_r)
    m3_register_op("op_u64_Clz_s", @@op_u64_Clz_s)
    m3_register_op("op_u64_Ctz_r", @@op_u64_Ctz_r)
    m3_register_op("op_u64_Ctz_s", @@op_u64_Ctz_s)
    m3_register_op("op_u64_Popcnt_r", @@op_u64_Popcnt_r)
    m3_register_op("op_u64_Popcnt_s", @@op_u64_Popcnt_s)
    // op_i32_Wrap_i64_r ... op_f64_Reinterpret_i64_s_s (the conversion
    // families, upstream lines 2284 - 3220)
    m3_register_op("op_i32_Wrap_i64_r", @@op_i32_Wrap_i64_r)
    m3_register_op("op_i32_Wrap_i64_s", @@op_i32_Wrap_i64_s)
    m3_register_op("op_i32_Extend8_s_r", @@op_i32_Extend8_s_r)
    m3_register_op("op_i32_Extend8_s_s", @@op_i32_Extend8_s_s)
    m3_register_op("op_i32_Extend16_s_r", @@op_i32_Extend16_s_r)
    m3_register_op("op_i32_Extend16_s_s", @@op_i32_Extend16_s_s)
    m3_register_op("op_i64_Extend8_s_r", @@op_i64_Extend8_s_r)
    m3_register_op("op_i64_Extend8_s_s", @@op_i64_Extend8_s_s)
    m3_register_op("op_i64_Extend16_s_r", @@op_i64_Extend16_s_r)
    m3_register_op("op_i64_Extend16_s_s", @@op_i64_Extend16_s_s)
    m3_register_op("op_i64_Extend32_s_r", @@op_i64_Extend32_s_r)
    m3_register_op("op_i64_Extend32_s_s", @@op_i64_Extend32_s_s)
    m3_register_op("op_i32_Trunc_f32_r_r", @@op_i32_Trunc_f32_r_r)
    m3_register_op("op_i32_Trunc_f32_r_s", @@op_i32_Trunc_f32_r_s)
    m3_register_op("op_i32_Trunc_f32_s_r", @@op_i32_Trunc_f32_s_r)
    m3_register_op("op_i32_Trunc_f32_s_s", @@op_i32_Trunc_f32_s_s)
    m3_register_op("op_u32_Trunc_f32_r_r", @@op_u32_Trunc_f32_r_r)
    m3_register_op("op_u32_Trunc_f32_r_s", @@op_u32_Trunc_f32_r_s)
    m3_register_op("op_u32_Trunc_f32_s_r", @@op_u32_Trunc_f32_s_r)
    m3_register_op("op_u32_Trunc_f32_s_s", @@op_u32_Trunc_f32_s_s)
    m3_register_op("op_i32_Trunc_f64_r_r", @@op_i32_Trunc_f64_r_r)
    m3_register_op("op_i32_Trunc_f64_r_s", @@op_i32_Trunc_f64_r_s)
    m3_register_op("op_i32_Trunc_f64_s_r", @@op_i32_Trunc_f64_s_r)
    m3_register_op("op_i32_Trunc_f64_s_s", @@op_i32_Trunc_f64_s_s)
    m3_register_op("op_u32_Trunc_f64_r_r", @@op_u32_Trunc_f64_r_r)
    m3_register_op("op_u32_Trunc_f64_r_s", @@op_u32_Trunc_f64_r_s)
    m3_register_op("op_u32_Trunc_f64_s_r", @@op_u32_Trunc_f64_s_r)
    m3_register_op("op_u32_Trunc_f64_s_s", @@op_u32_Trunc_f64_s_s)
    m3_register_op("op_i64_Trunc_f32_r_r", @@op_i64_Trunc_f32_r_r)
    m3_register_op("op_i64_Trunc_f32_r_s", @@op_i64_Trunc_f32_r_s)
    m3_register_op("op_i64_Trunc_f32_s_r", @@op_i64_Trunc_f32_s_r)
    m3_register_op("op_i64_Trunc_f32_s_s", @@op_i64_Trunc_f32_s_s)
    m3_register_op("op_u64_Trunc_f32_r_r", @@op_u64_Trunc_f32_r_r)
    m3_register_op("op_u64_Trunc_f32_r_s", @@op_u64_Trunc_f32_r_s)
    m3_register_op("op_u64_Trunc_f32_s_r", @@op_u64_Trunc_f32_s_r)
    m3_register_op("op_u64_Trunc_f32_s_s", @@op_u64_Trunc_f32_s_s)
    m3_register_op("op_i64_Trunc_f64_r_r", @@op_i64_Trunc_f64_r_r)
    m3_register_op("op_i64_Trunc_f64_r_s", @@op_i64_Trunc_f64_r_s)
    m3_register_op("op_i64_Trunc_f64_s_r", @@op_i64_Trunc_f64_s_r)
    m3_register_op("op_i64_Trunc_f64_s_s", @@op_i64_Trunc_f64_s_s)
    m3_register_op("op_u64_Trunc_f64_r_r", @@op_u64_Trunc_f64_r_r)
    m3_register_op("op_u64_Trunc_f64_r_s", @@op_u64_Trunc_f64_r_s)
    m3_register_op("op_u64_Trunc_f64_s_r", @@op_u64_Trunc_f64_s_r)
    m3_register_op("op_u64_Trunc_f64_s_s", @@op_u64_Trunc_f64_s_s)
    m3_register_op("op_i32_TruncSat_f32_r_r", @@op_i32_TruncSat_f32_r_r)
    m3_register_op("op_i32_TruncSat_f32_r_s", @@op_i32_TruncSat_f32_r_s)
    m3_register_op("op_i32_TruncSat_f32_s_r", @@op_i32_TruncSat_f32_s_r)
    m3_register_op("op_i32_TruncSat_f32_s_s", @@op_i32_TruncSat_f32_s_s)
    m3_register_op("op_u32_TruncSat_f32_r_r", @@op_u32_TruncSat_f32_r_r)
    m3_register_op("op_u32_TruncSat_f32_r_s", @@op_u32_TruncSat_f32_r_s)
    m3_register_op("op_u32_TruncSat_f32_s_r", @@op_u32_TruncSat_f32_s_r)
    m3_register_op("op_u32_TruncSat_f32_s_s", @@op_u32_TruncSat_f32_s_s)
    m3_register_op("op_i32_TruncSat_f64_r_r", @@op_i32_TruncSat_f64_r_r)
    m3_register_op("op_i32_TruncSat_f64_r_s", @@op_i32_TruncSat_f64_r_s)
    m3_register_op("op_i32_TruncSat_f64_s_r", @@op_i32_TruncSat_f64_s_r)
    m3_register_op("op_i32_TruncSat_f64_s_s", @@op_i32_TruncSat_f64_s_s)
    m3_register_op("op_u32_TruncSat_f64_r_r", @@op_u32_TruncSat_f64_r_r)
    m3_register_op("op_u32_TruncSat_f64_r_s", @@op_u32_TruncSat_f64_r_s)
    m3_register_op("op_u32_TruncSat_f64_s_r", @@op_u32_TruncSat_f64_s_r)
    m3_register_op("op_u32_TruncSat_f64_s_s", @@op_u32_TruncSat_f64_s_s)
    m3_register_op("op_i64_TruncSat_f32_r_r", @@op_i64_TruncSat_f32_r_r)
    m3_register_op("op_i64_TruncSat_f32_r_s", @@op_i64_TruncSat_f32_r_s)
    m3_register_op("op_i64_TruncSat_f32_s_r", @@op_i64_TruncSat_f32_s_r)
    m3_register_op("op_i64_TruncSat_f32_s_s", @@op_i64_TruncSat_f32_s_s)
    m3_register_op("op_u64_TruncSat_f32_r_r", @@op_u64_TruncSat_f32_r_r)
    m3_register_op("op_u64_TruncSat_f32_r_s", @@op_u64_TruncSat_f32_r_s)
    m3_register_op("op_u64_TruncSat_f32_s_r", @@op_u64_TruncSat_f32_s_r)
    m3_register_op("op_u64_TruncSat_f32_s_s", @@op_u64_TruncSat_f32_s_s)
    m3_register_op("op_i64_TruncSat_f64_r_r", @@op_i64_TruncSat_f64_r_r)
    m3_register_op("op_i64_TruncSat_f64_r_s", @@op_i64_TruncSat_f64_r_s)
    m3_register_op("op_i64_TruncSat_f64_s_r", @@op_i64_TruncSat_f64_s_r)
    m3_register_op("op_i64_TruncSat_f64_s_s", @@op_i64_TruncSat_f64_s_s)
    m3_register_op("op_u64_TruncSat_f64_r_r", @@op_u64_TruncSat_f64_r_r)
    m3_register_op("op_u64_TruncSat_f64_r_s", @@op_u64_TruncSat_f64_r_s)
    m3_register_op("op_u64_TruncSat_f64_s_r", @@op_u64_TruncSat_f64_s_r)
    m3_register_op("op_u64_TruncSat_f64_s_s", @@op_u64_TruncSat_f64_s_s)
    m3_register_op("op_i64_Extend_i32_r", @@op_i64_Extend_i32_r)
    m3_register_op("op_i64_Extend_i32_s", @@op_i64_Extend_i32_s)
    m3_register_op("op_i64_Extend_u32_r", @@op_i64_Extend_u32_r)
    m3_register_op("op_i64_Extend_u32_s", @@op_i64_Extend_u32_s)
    m3_register_op("op_f32_Demote_f64_r", @@op_f32_Demote_f64_r)
    m3_register_op("op_f32_Demote_f64_s", @@op_f32_Demote_f64_s)
    m3_register_op("op_f64_Promote_f32_r", @@op_f64_Promote_f32_r)
    m3_register_op("op_f64_Promote_f32_s", @@op_f64_Promote_f32_s)
    m3_register_op("op_f32_Convert_i32_r_r", @@op_f32_Convert_i32_r_r)
    m3_register_op("op_f32_Convert_i32_s_r", @@op_f32_Convert_i32_s_r)
    m3_register_op("op_f32_Convert_i32_r_s", @@op_f32_Convert_i32_r_s)
    m3_register_op("op_f32_Convert_i32_s_s", @@op_f32_Convert_i32_s_s)
    m3_register_op("op_f32_Convert_u32_r_r", @@op_f32_Convert_u32_r_r)
    m3_register_op("op_f32_Convert_u32_s_r", @@op_f32_Convert_u32_s_r)
    m3_register_op("op_f32_Convert_u32_r_s", @@op_f32_Convert_u32_r_s)
    m3_register_op("op_f32_Convert_u32_s_s", @@op_f32_Convert_u32_s_s)
    m3_register_op("op_f32_Convert_i64_r_r", @@op_f32_Convert_i64_r_r)
    m3_register_op("op_f32_Convert_i64_s_r", @@op_f32_Convert_i64_s_r)
    m3_register_op("op_f32_Convert_i64_r_s", @@op_f32_Convert_i64_r_s)
    m3_register_op("op_f32_Convert_i64_s_s", @@op_f32_Convert_i64_s_s)
    m3_register_op("op_f32_Convert_u64_r_r", @@op_f32_Convert_u64_r_r)
    m3_register_op("op_f32_Convert_u64_s_r", @@op_f32_Convert_u64_s_r)
    m3_register_op("op_f32_Convert_u64_r_s", @@op_f32_Convert_u64_r_s)
    m3_register_op("op_f32_Convert_u64_s_s", @@op_f32_Convert_u64_s_s)
    m3_register_op("op_f64_Convert_i32_r_r", @@op_f64_Convert_i32_r_r)
    m3_register_op("op_f64_Convert_i32_s_r", @@op_f64_Convert_i32_s_r)
    m3_register_op("op_f64_Convert_i32_r_s", @@op_f64_Convert_i32_r_s)
    m3_register_op("op_f64_Convert_i32_s_s", @@op_f64_Convert_i32_s_s)
    m3_register_op("op_f64_Convert_u32_r_r", @@op_f64_Convert_u32_r_r)
    m3_register_op("op_f64_Convert_u32_s_r", @@op_f64_Convert_u32_s_r)
    m3_register_op("op_f64_Convert_u32_r_s", @@op_f64_Convert_u32_r_s)
    m3_register_op("op_f64_Convert_u32_s_s", @@op_f64_Convert_u32_s_s)
    m3_register_op("op_f64_Convert_i64_r_r", @@op_f64_Convert_i64_r_r)
    m3_register_op("op_f64_Convert_i64_s_r", @@op_f64_Convert_i64_s_r)
    m3_register_op("op_f64_Convert_i64_r_s", @@op_f64_Convert_i64_r_s)
    m3_register_op("op_f64_Convert_i64_s_s", @@op_f64_Convert_i64_s_s)
    m3_register_op("op_f64_Convert_u64_r_r", @@op_f64_Convert_u64_r_r)
    m3_register_op("op_f64_Convert_u64_s_r", @@op_f64_Convert_u64_s_r)
    m3_register_op("op_f64_Convert_u64_r_s", @@op_f64_Convert_u64_r_s)
    m3_register_op("op_f64_Convert_u64_s_s", @@op_f64_Convert_u64_s_s)
    m3_register_op("op_i32_Reinterpret_f32_r_r", @@op_i32_Reinterpret_f32_r_r)
    m3_register_op("op_i32_Reinterpret_f32_r_s", @@op_i32_Reinterpret_f32_r_s)
    m3_register_op("op_i32_Reinterpret_f32_s_r", @@op_i32_Reinterpret_f32_s_r)
    m3_register_op("op_i32_Reinterpret_f32_s_s", @@op_i32_Reinterpret_f32_s_s)
    m3_register_op("op_i64_Reinterpret_f64_r_r", @@op_i64_Reinterpret_f64_r_r)
    m3_register_op("op_i64_Reinterpret_f64_r_s", @@op_i64_Reinterpret_f64_r_s)
    m3_register_op("op_i64_Reinterpret_f64_s_r", @@op_i64_Reinterpret_f64_s_r)
    m3_register_op("op_i64_Reinterpret_f64_s_s", @@op_i64_Reinterpret_f64_s_s)
    m3_register_op("op_f32_Reinterpret_i32_r_r", @@op_f32_Reinterpret_i32_r_r)
    m3_register_op("op_f32_Reinterpret_i32_r_s", @@op_f32_Reinterpret_i32_r_s)
    m3_register_op("op_f32_Reinterpret_i32_s_r", @@op_f32_Reinterpret_i32_s_r)
    m3_register_op("op_f32_Reinterpret_i32_s_s", @@op_f32_Reinterpret_i32_s_s)
    m3_register_op("op_f64_Reinterpret_i64_r_r", @@op_f64_Reinterpret_i64_r_r)
    m3_register_op("op_f64_Reinterpret_i64_r_s", @@op_f64_Reinterpret_i64_r_s)
    m3_register_op("op_f64_Reinterpret_i64_s_r", @@op_f64_Reinterpret_i64_s_r)
    m3_register_op("op_f64_Reinterpret_i64_s_s", @@op_f64_Reinterpret_i64_s_s)
    m3_register_op("op_GetGlobal_s32", @@op_GetGlobal_s32)
    m3_register_op("op_GetGlobal_s64", @@op_GetGlobal_s64)
    m3_register_op("op_SetGlobal_i32", @@op_SetGlobal_i32)
    m3_register_op("op_SetGlobal_i64", @@op_SetGlobal_i64)
    m3_register_op("op_Call", @@op_Call)
    m3_register_op("op_CallIndirect", @@op_CallIndirect)
    m3_register_op("op_CallRawFunction", @@op_CallRawFunction)
    m3_register_op("op_MemSize", @@op_MemSize)
    m3_register_op("op_MemGrow", @@op_MemGrow)
    m3_register_op("op_MemCopy", @@op_MemCopy)
    m3_register_op("op_MemFill", @@op_MemFill)
    m3_register_op("op_Compile", @@op_Compile)
    m3_register_op("op_Entry", @@op_Entry)
    m3_register_op("op_Loop", @@op_Loop)
    m3_register_op("op_Branch", @@op_Branch)
    m3_register_op("op_If_r", @@op_If_r)
    m3_register_op("op_If_s", @@op_If_s)
    m3_register_op("op_BranchTable", @@op_BranchTable)
    m3_register_op("op_SetRegister_i32", @@op_SetRegister_i32)
    m3_register_op("op_SetSlot_i32", @@op_SetSlot_i32)
    m3_register_op("op_PreserveSetSlot_i32", @@op_PreserveSetSlot_i32)
    m3_register_op("op_SetRegister_i64", @@op_SetRegister_i64)
    m3_register_op("op_SetSlot_i64", @@op_SetSlot_i64)
    m3_register_op("op_PreserveSetSlot_i64", @@op_PreserveSetSlot_i64)
    m3_register_op("op_SetRegister_f32", @@op_SetRegister_f32)
    m3_register_op("op_SetSlot_f32", @@op_SetSlot_f32)
    m3_register_op("op_PreserveSetSlot_f32", @@op_PreserveSetSlot_f32)
    m3_register_op("op_SetRegister_f64", @@op_SetRegister_f64)
    m3_register_op("op_SetSlot_f64", @@op_SetSlot_f64)
    m3_register_op("op_PreserveSetSlot_f64", @@op_PreserveSetSlot_f64)
    m3_register_op("op_CopySlot_32", @@op_CopySlot_32)
    m3_register_op("op_PreserveCopySlot_32", @@op_PreserveCopySlot_32)
    m3_register_op("op_CopySlot_64", @@op_CopySlot_64)
    m3_register_op("op_PreserveCopySlot_64", @@op_PreserveCopySlot_64)
    m3_register_op("op_Select_i32_rss", @@op_Select_i32_rss)
    m3_register_op("op_Select_i32_srs", @@op_Select_i32_srs)
    m3_register_op("op_Select_i32_ssr", @@op_Select_i32_ssr)
    m3_register_op("op_Select_i32_sss", @@op_Select_i32_sss)
    m3_register_op("op_Select_i64_rss", @@op_Select_i64_rss)
    m3_register_op("op_Select_i64_srs", @@op_Select_i64_srs)
    m3_register_op("op_Select_i64_ssr", @@op_Select_i64_ssr)
    m3_register_op("op_Select_i64_sss", @@op_Select_i64_sss)
    m3_register_op("op_Select_f32_sss", @@op_Select_f32_sss)
    m3_register_op("op_Select_f32_srs", @@op_Select_f32_srs)
    m3_register_op("op_Select_f32_ssr", @@op_Select_f32_ssr)
    m3_register_op("op_Select_f32_rss", @@op_Select_f32_rss)
    m3_register_op("op_Select_f32_rrs", @@op_Select_f32_rrs)
    m3_register_op("op_Select_f32_rsr", @@op_Select_f32_rsr)
    m3_register_op("op_Select_f64_sss", @@op_Select_f64_sss)
    m3_register_op("op_Select_f64_srs", @@op_Select_f64_srs)
    m3_register_op("op_Select_f64_ssr", @@op_Select_f64_ssr)
    m3_register_op("op_Select_f64_rss", @@op_Select_f64_rss)
    m3_register_op("op_Select_f64_rrs", @@op_Select_f64_rrs)
    m3_register_op("op_Select_f64_rsr", @@op_Select_f64_rsr)
    m3_register_op("op_Return", @@op_Return)
    m3_register_op("op_BranchIf_r", @@op_BranchIf_r)
    m3_register_op("op_BranchIf_s", @@op_BranchIf_s)
    m3_register_op("op_BranchIfPrologue_r", @@op_BranchIfPrologue_r)
    m3_register_op("op_BranchIfPrologue_s", @@op_BranchIfPrologue_s)
    m3_register_op("op_ContinueLoop", @@op_ContinueLoop)
    m3_register_op("op_ContinueLoopIf", @@op_ContinueLoopIf)
    m3_register_op("op_Const32", @@op_Const32)
    m3_register_op("op_Const64", @@op_Const64)
    m3_register_op("op_Unsupported", @@op_Unsupported)
    m3_register_op("op_Unreachable", @@op_Unreachable)
    m3_register_op("op_End", @@op_End)
    m3_register_op("op_SetGlobal_s32", @@op_SetGlobal_s32)
    m3_register_op("op_SetGlobal_s64", @@op_SetGlobal_s64)
    m3_register_op("op_SetGlobal_f32", @@op_SetGlobal_f32)
    m3_register_op("op_SetGlobal_f64", @@op_SetGlobal_f64)
    m3_register_op("op_f32_Load_f32_r", @@op_f32_Load_f32_r)
    m3_register_op("op_f32_Load_f32_s", @@op_f32_Load_f32_s)
    m3_register_op("op_f64_Load_f64_r", @@op_f64_Load_f64_r)
    m3_register_op("op_f64_Load_f64_s", @@op_f64_Load_f64_s)
    m3_register_op("op_i32_Load_i8_r", @@op_i32_Load_i8_r)
    m3_register_op("op_i32_Load_i8_s", @@op_i32_Load_i8_s)
    m3_register_op("op_i32_Load_u8_r", @@op_i32_Load_u8_r)
    m3_register_op("op_i32_Load_u8_s", @@op_i32_Load_u8_s)
    m3_register_op("op_i32_Load_i16_r", @@op_i32_Load_i16_r)
    m3_register_op("op_i32_Load_i16_s", @@op_i32_Load_i16_s)
    m3_register_op("op_i32_Load_u16_r", @@op_i32_Load_u16_r)
    m3_register_op("op_i32_Load_u16_s", @@op_i32_Load_u16_s)
    m3_register_op("op_i32_Load_i32_r", @@op_i32_Load_i32_r)
    m3_register_op("op_i32_Load_i32_s", @@op_i32_Load_i32_s)
    m3_register_op("op_i64_Load_i8_r", @@op_i64_Load_i8_r)
    m3_register_op("op_i64_Load_i8_s", @@op_i64_Load_i8_s)
    m3_register_op("op_i64_Load_u8_r", @@op_i64_Load_u8_r)
    m3_register_op("op_i64_Load_u8_s", @@op_i64_Load_u8_s)
    m3_register_op("op_i64_Load_i16_r", @@op_i64_Load_i16_r)
    m3_register_op("op_i64_Load_i16_s", @@op_i64_Load_i16_s)
    m3_register_op("op_i64_Load_u16_r", @@op_i64_Load_u16_r)
    m3_register_op("op_i64_Load_u16_s", @@op_i64_Load_u16_s)
    m3_register_op("op_i64_Load_i32_r", @@op_i64_Load_i32_r)
    m3_register_op("op_i64_Load_i32_s", @@op_i64_Load_i32_s)
    m3_register_op("op_i64_Load_u32_r", @@op_i64_Load_u32_r)
    m3_register_op("op_i64_Load_u32_s", @@op_i64_Load_u32_s)
    m3_register_op("op_i64_Load_i64_r", @@op_i64_Load_i64_r)
    m3_register_op("op_i64_Load_i64_s", @@op_i64_Load_i64_s)
    m3_register_op("op_f32_Store_f32_rs", @@op_f32_Store_f32_rs)
    m3_register_op("op_f32_Store_f32_sr", @@op_f32_Store_f32_sr)
    m3_register_op("op_f32_Store_f32_ss", @@op_f32_Store_f32_ss)
    m3_register_op("op_f32_Store_f32_rr", @@op_f32_Store_f32_rr)
    m3_register_op("op_f64_Store_f64_rs", @@op_f64_Store_f64_rs)
    m3_register_op("op_f64_Store_f64_sr", @@op_f64_Store_f64_sr)
    m3_register_op("op_f64_Store_f64_ss", @@op_f64_Store_f64_ss)
    m3_register_op("op_f64_Store_f64_rr", @@op_f64_Store_f64_rr)
    m3_register_op("op_i32_Store_u8_rs", @@op_i32_Store_u8_rs)
    m3_register_op("op_i32_Store_u8_sr", @@op_i32_Store_u8_sr)
    m3_register_op("op_i32_Store_u8_ss", @@op_i32_Store_u8_ss)
    m3_register_op("op_i32_Store_i16_rs", @@op_i32_Store_i16_rs)
    m3_register_op("op_i32_Store_i16_sr", @@op_i32_Store_i16_sr)
    m3_register_op("op_i32_Store_i16_ss", @@op_i32_Store_i16_ss)
    m3_register_op("op_i32_Store_i32_rs", @@op_i32_Store_i32_rs)
    m3_register_op("op_i32_Store_i32_sr", @@op_i32_Store_i32_sr)
    m3_register_op("op_i32_Store_i32_ss", @@op_i32_Store_i32_ss)
    m3_register_op("op_i64_Store_u8_rs", @@op_i64_Store_u8_rs)
    m3_register_op("op_i64_Store_u8_sr", @@op_i64_Store_u8_sr)
    m3_register_op("op_i64_Store_u8_ss", @@op_i64_Store_u8_ss)
    m3_register_op("op_i64_Store_i16_rs", @@op_i64_Store_i16_rs)
    m3_register_op("op_i64_Store_i16_sr", @@op_i64_Store_i16_sr)
    m3_register_op("op_i64_Store_i16_ss", @@op_i64_Store_i16_ss)
    m3_register_op("op_i64_Store_i32_rs", @@op_i64_Store_i32_rs)
    m3_register_op("op_i64_Store_i32_sr", @@op_i64_Store_i32_sr)
    m3_register_op("op_i64_Store_i32_ss", @@op_i64_Store_i32_ss)
    m3_register_op("op_i64_Store_i64_rs", @@op_i64_Store_i64_rs)
    m3_register_op("op_i64_Store_i64_sr", @@op_i64_Store_i64_sr)
    m3_register_op("op_i64_Store_i64_ss", @@op_i64_Store_i64_ss)
}
