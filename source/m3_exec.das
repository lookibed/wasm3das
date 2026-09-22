options gen2
options indenting = 4
// The shape of the operation dispatch the LLVM JIT tier gets: "chain" (the
// measured default, docs/native-build.md section 6, E9), "tree", "noinline"
// or "chain_noinline". It has no effect in any other tier. See the "Operation
// dispatch" section below and dispatch_shape in m3_exec_expand.das.
options _m3_dispatch = "chain"

module m3_exec shared public

require math
require ./m3_core.das
require ./m3_types.das public
require ./m3_math_utils.das public
require ./m3_exec_defs.das public
// Compile-time only, and deliberately not re-exported: the pass that expands the
// operand readers below at their use sites, the way the C preprocessor expands
// immediate()/slot()/slot_ptr(). See m3_exec_expand.das.
require ./m3_exec_expand.das

// Conservative Gen2 port of m3_exec.h.
// The threaded-interpreter ABI, op_* names, register/slot forms, trap propagation,
// memory checks, and immediate layout are intentionally kept close to wasm3.
//
// The C form, documented in m3_exec_defs.das and docs/execution-design.md
// (section 6): every operation takes the five interpreter registers (_pc,
// _sp, _mem, _r0, _fp0) BY VALUE and `return nextOpDirect (...)` /
// `return jumpOpDirect (...)` calls the next operation directly, which is
// what C's M3_MUSTTAIL return of nextOpImpl()/jumpOpImpl(PC) does. Daslang
// has no M3_MUSTTAIL, so the daslang interpreter tier nests one frame per
// executed operation; the AOT/ctx tier emits `return operation(...)`, which
// gcc turns into a sibling-call jump. The LLVM JIT tier needs one more thing -
// a DIRECT call, because it never tail-calls through a function value - and
// gets it from the generated dispatch described under "Operation dispatch"
// below.

let INT32_MIN : i32 = -2147483647 - 1
let INT64_MIN : i64 = -9223372036854775807l - 1l








// C spells the three as macros (d_m3RecordBacktraces == false makes them
// empty / a plain passthrough); [inline] keeps them free at the use site, as
// in C, instead of one call node per trap check.
[inline]
def pushBacktraceFrame(_pc : pc_t; _mem : M3MemoryHeader?) {
    // d_m3RecordBacktraces == false: the C body calls PushBacktraceFrame and
    // is compiled out. The backtrace layer is not ported yet.
}

[inline]
def newTrap(_pc : pc_t; _mem : M3MemoryHeader?; err : M3Result) : M3Result {
    pushBacktraceFrame(_pc, _mem)
    return err
}

[inline]
def forwardTrap(err : M3Result) : M3Result {
    return err
}

// C m3ret_t is `const void *`: an operation returns NULL, an error string, or
// (op_ContinueLoop/op_ContinueLoopIf) the pc of the loop to continue. The
// port keeps M3Result for the first two and reinterprets the loop pc into the
// same M3Result; only op_Loop consumes it, comparing pointers. Nothing else
// may compare such a value by content.



/*
    C m3_exec.h calls CompileFunction (m3_compile.c) for lazy compilation on
    the op_Entry/op_Call paths. The C header cycle between m3_exec.h and
    m3_compile.h cannot be expressed in an acyclic Daslang module graph, so
    the compiler implementation is registered in this hook; m3_env.das wires
    it when the full module set loads.
*/

var public CompileFunctionHook : function<(var io_function : IM3Function) : M3Result>

var public ResizeMemoryHook : function<(var io_runtime : IM3Runtime; i_numPages : u32) : M3Result>

// C: M3Result ResizeMemory (IM3Runtime io_runtime, u32 i_numPages) — m3_env.c,
// registered by m3_env.das (see CompileFunctionHook note). Private: m3_env.das
// defines the real ResizeMemory and must not see this bridge as a second candidate.
// `io_runtime` and `io_function` are `var`: both bridges hand the pointer to a
// hook that writes through it (ResizeMemory rewrites runtime->memory,
// CompileFunction fills function->compiled), and the daslang JIT gives a
// non-`var` pointer parameter the LLVM `readonly` attribute (upstream #3991),
// which folds the caller's read of that memory from `--jit-opt-level=1` up.
def private ResizeMemory(var io_runtime : IM3Runtime; i_numPages : u32) : M3Result {
    if (ResizeMemoryHook == null) {
        return "memory resize hook is not wired"
    }
    return ResizeMemoryHook(io_runtime, i_numPages)
}

def private CompileFunction(var io_function : IM3Function) : M3Result {
    if (CompileFunctionHook == null) {
        return "lazy compilation hook is not wired"
    }
    return CompileFunctionHook(io_function)
}


// ============================================================================
// C string.h in op_MemCopy / op_MemFill / op_Entry
// ============================================================================


// C's `memmove`, `memset` and `memcpy` need no replacement: `memmove`,
// `memset8` and `memcpy` are the daslang builtins with the same contract, and
// op_MemCopy, op_MemFill and op_Entry call them directly the way C calls libc.

// ============================================================================
// libm replacements (C copysignf/copysign)
//
// fabsf/fabs/floorf/ceilf/rintf/rint live in m3_math_utils.das next to the
// other libm-shaped helpers; see the comment there for why the `math` module
// cannot be used for them.
// ============================================================================


def copysign_f32(a : f32; b : f32) : f32 {
    unsafe {
        let abits = reinterpret<u32>(a)
        let bbits = reinterpret<u32>(b)
        return reinterpret<f32>((abits & 0x7fffffffu) | (bbits & 0x80000000u))
    }
}

def copysign_f64(a : f64; b : f64) : f64 {
    unsafe {
        let abits = reinterpret<u64>(a)
        let bbits = reinterpret<u64>(b)
        return reinterpret<f64>((abits & 0x7ffffffffffffffful) | (bbits & 0x8000000000000000ul))
    }
}

/*
    Operand readers. C spells them as preprocessor macros in m3_exec_defs.h, so
    an operation body carries their expansion, not a call:

        #define immediate(TYPE)     * ((TYPE *) _pc++)
        #define slot_ptr(TYPE)      (TYPE *)   (_sp + immediate (i32))
        #define slot(TYPE)          * (TYPE *) (_sp + immediate (i32))

    The port keeps them as functions so the 509 operation bodies keep the C
    spelling, but each one is [inline] and *flat*: slot_T does not call
    slot_ptr_T, which does not call immediate_i32. Each is the C macro written
    out once, exactly as the C preprocessor writes it out at the use site.

    Why flat and why by reference: the daslang interpreter evaluates one node
    per statement, per call and per inline splice, and an [inline] argument
    passed by value is copied into a temporary of its own. Measured on a
    synthetic code page run through RunLoop (op_i32_Add_ss, min of five runs,
    tmp/opbench.das):

        nested, plain calls (the previous spelling)   274 ns/op
        nested, [inline]                              272 ns/op
        flat [inline], _sp by value                   219 ns/op
        flat [inline], _sp by reference               190 ns/op
        the same expansion written out by hand        144 ns/op

    so the nesting, not the call, was the cost. The remaining 46 ns is the
    result temporary daslang gives every inline splice; removing it would mean
    writing the expansion into all 509 bodies, which is not worth the fidelity.
*/

[inline]
def bool_reg(value : bool) : m3reg_t {
    // C: _r0 = (operand1 == operand2) - the bool-to-m3reg_t conversion.
    return value ? 1l : 0l
}

[inline]
def immediate_i32(var _pc : pc_t&) : i32 {
    unsafe {
        let value = reinterpret<i32 const?>(_pc)[0]
        _pc += 1
        return value
    }
}

[inline]
def immediate_u32(var _pc : pc_t&) : u32 {
    unsafe {
        let value = reinterpret<u32 const?>(_pc)[0]
        _pc += 1
        return value
    }
}

[inline]
def immediate_pc(var _pc : pc_t&) : pc_t {
    unsafe {
        var value = reinterpret<pc_t>(_pc[0])
        _pc += 1
        return value
    }
}

[inline]
def immediate_code(var _pc : pc_t&) : code_t {
    unsafe {
        let value = _pc[0]
        _pc += 1
        return value
    }
}

[inline]
def immediate_function(var _pc : pc_t&) : IM3Function {
    unsafe {
        var value = reinterpret<IM3Function>(_pc[0])
        _pc += 1
        return value
    }
}

[inline]
def immediate_module(var _pc : pc_t&) : IM3Module {
    unsafe {
        var value = reinterpret<IM3Module>(_pc[0])
        _pc += 1
        return value
    }
}

[inline]
def immediate_functype(var _pc : pc_t&) : IM3FuncType {
    unsafe {
        var value = reinterpret<IM3FuncType>(_pc[0])
        _pc += 1
        return value
    }
}

[inline]
def immediate_rawcall(var _pc : pc_t&) : M3RawCall {
    unsafe {
        let value = reinterpret<M3RawCall>(_pc[0])
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_i8(var _pc : pc_t&; _sp : m3stack_t&) : i8? {
    unsafe {
        var ptr = reinterpret<i8?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_i8(var _pc : pc_t&; _sp : m3stack_t&) : i8 {
    unsafe {
        let value = reinterpret<i8?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_u8(var _pc : pc_t&; _sp : m3stack_t&) : u8? {
    unsafe {
        var ptr = reinterpret<u8?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_u8(var _pc : pc_t&; _sp : m3stack_t&) : u8 {
    unsafe {
        let value = reinterpret<u8?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_i16(var _pc : pc_t&; _sp : m3stack_t&) : i16? {
    unsafe {
        var ptr = reinterpret<i16?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_i16(var _pc : pc_t&; _sp : m3stack_t&) : i16 {
    unsafe {
        let value = reinterpret<i16?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_u16(var _pc : pc_t&; _sp : m3stack_t&) : u16? {
    unsafe {
        var ptr = reinterpret<u16?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_u16(var _pc : pc_t&; _sp : m3stack_t&) : u16 {
    unsafe {
        let value = reinterpret<u16?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_i32(var _pc : pc_t&; _sp : m3stack_t&) : i32? {
    unsafe {
        var ptr = reinterpret<i32?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_i32(var _pc : pc_t&; _sp : m3stack_t&) : i32 {
    unsafe {
        let value = reinterpret<i32?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_u32(var _pc : pc_t&; _sp : m3stack_t&) : u32? {
    unsafe {
        var ptr = reinterpret<u32?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_u32(var _pc : pc_t&; _sp : m3stack_t&) : u32 {
    unsafe {
        let value = reinterpret<u32?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_i64(var _pc : pc_t&; _sp : m3stack_t&) : i64? {
    unsafe {
        var ptr = reinterpret<i64?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_i64(var _pc : pc_t&; _sp : m3stack_t&) : i64 {
    unsafe {
        let value = reinterpret<i64?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_u64(var _pc : pc_t&; _sp : m3stack_t&) : u64? {
    unsafe {
        var ptr = reinterpret<u64?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_u64(var _pc : pc_t&; _sp : m3stack_t&) : u64 {
    unsafe {
        let value = reinterpret<u64?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_f32(var _pc : pc_t&; _sp : m3stack_t&) : f32? {
    unsafe {
        var ptr = reinterpret<f32?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_f32(var _pc : pc_t&; _sp : m3stack_t&) : f32 {
    unsafe {
        let value = reinterpret<f32?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

[inline]
def slot_ptr_f64(var _pc : pc_t&; _sp : m3stack_t&) : f64? {
    unsafe {
        var ptr = reinterpret<f64?>(_sp + reinterpret<i32 const?>(_pc)[0])
        _pc += 1
        return ptr
    }
}

[inline]
def slot_f64(var _pc : pc_t&; _sp : m3stack_t&) : f64 {
    unsafe {
        let value = reinterpret<f64?>(_sp + reinterpret<i32 const?>(_pc)[0])[0]
        _pc += 1
        return value
    }
}

// ============================================================================
// Operation dispatch
// ============================================================================


/*
    C stores the IM3Operation function pointer itself in the code page and
    reaches the operation through an indirect call:

        EmitWord (page, op)                       // the function pointer
        ((IM3Operation)(* _pc))(_pc + 1, ...)     // the indirect call back

    That is the source form below - m3_OpWord is the cast C's EmitWord macro
    does, nextOpImpl the cast and call its macro does - and it is what the
    daslang interpreter, the AOT tier and the standalone-context tier compile,
    unchanged.

    Under the LLVM JIT (`-jit`, `-exe`) it cannot stay that way. daslang emits
    a call through a function value as a generic-wrapper invoke with an
    argument buffer on the stack, which is never a tail call, so a wasm loop
    nests one native frame per executed operation. A DIRECT call in return
    position is a tail call for LLVM exactly as it is for gcc. So when
    `prog.policies.jit_enabled` is set, and only then, the infer pass in
    m3_exec_expand.das rewrites the placeholder bodies below:

        m3_OpWord(op)   -> the operation's INDEX, so a code-page word is an
                           index in 0..m3_OpCount()-1 over the op_* functions
                           of this module sorted by name;
        nextOpImpl,
        jumpOpImpl      -> `return m3_DispatchOp (...)`;
        m3_DispatchOp   -> the generated dispatch over that index, whose leaves
                           are DIRECT calls `return op_<name>(...)`;
        m3_OpAt,
        m3_OpCount      -> the same tree over the function VALUES, and the
                           number of operations, for the reverse map.

    Nothing else changes: the compile tables of m3_compile.das keep C's
    IM3Operation values (c_setSetOps, the M3OP(...) rows, c_opNull, IsNoOp),
    every operation still ends with `return nextOpDirect (...)`, and the
    numbering never leaves this module - m3_OpIndex is the reverse map the
    emitters reach through m3_OpWord, m3_OpAt the forward one it is built from.

    This is also why nextOpImpl, jumpOpImpl, nextOpDirect, jumpOpDirect and
    RunCode live here and not in m3_exec_defs.das: only here is every op_*
    visible for a direct call.
*/

/* C stores NULL in absent operation-table slots; m3_compile.das holds the
   explicit sentinel c_opNull = @@op_NoOp instead, because Daslang function
   values are non-nullable. The operation itself lives here, with the other
   operations: C's Compile_Select emits its NULL operation unguarded when the
   stack is polymorphic, so the sentinel does reach a code page and needs a
   dispatch index like every other op_*. It is never meant to execute. */
[unused_argument(_pc, _sp, _mem, _r0, _fp0)]
def public op_NoOp(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return m3Err_noCompiler
}

/* The code-page word of an operation. C: EmitWord (page, op) stores the
   IM3Operation value itself, which the reinterpret below spells; through u64
   because the AOT backend lowers a function-to-pointer reinterpret to the
   value's address (see EmitWord in m3_code.das). Every emission site of an
   operation word goes through this one function, so the JIT pass has a single
   body to rewrite into `return m3_OpIndex(op)`. */
def public m3_OpWord(op : IM3Operation) : u64 {
    return unsafe(reinterpret<u64>(op))
}

/* The operation word of `_pc` read as a dispatch index, with `_pc` advanced
   past it - the `(* _pc)` and the `_pc + 1` of C's nextOpImpl macro, in the
   one shape the generated dispatch needs. [inline], like the operand readers
   above, so the splice lands in m3_DispatchOp itself. Unused unless the JIT
   pass generates the dispatch. */
[inline]
def public m3_WordIndex(var _pc : pc_t&) : int {
    unsafe {
        let idx = int(reinterpret<u64>(_pc[0]))
        _pc += 1
        return idx
    }
}

/* Placeholder. Under the JIT the pass replaces this body with the generated
   dispatch: `let idx = m3_WordIndex(_pc)` followed by a linear equality chain
   - or, with `options _m3_dispatch = "tree"` / `"noinline"` at the top of this
   file, a balanced `if (idx < mid)` tree - whose leaves are DIRECT calls
   `return op_<name>(_pc, _sp, _mem, _r0, _fp0)`. A plain function, not
   [inline]: every operation tail-calls into it through nextOpImpl and it
   tail-calls the operation, so the backend sees one chain of sibling calls;
   an [inline] splice would copy the whole dispatch into each of the 500 tail
   positions. */
[unused_argument(_pc, _sp, _mem, _r0, _fp0)]
def public m3_DispatchOp(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return m3Err_none
}

/* Placeholder. Under the JIT the pass replaces this body with the same tree,
   its leaves returning the function VALUE `@@op_<name>`. It has no C
   counterpart: it exists only so m3_OpIndex can build the reverse map. */
[unused_argument(idx)]
def public m3_OpAt(idx : int) : IM3Operation {
    return @@op_NoOp
}

/* Placeholder. Under the JIT the pass replaces this body with the number of
   op_* functions of this module. */
def public m3_OpCount() : int {
    return 0
}

// The reverse of m3_OpAt, and the only thing the emitters need: the compile
// tables keep C's IM3Operation VALUES, so m3_OpWord turns the value it is
// handed into the index the code-page word carries.
var private g_opIndex : table<u64; int>

def public m3_OpIndex(op : IM3Operation) : u64 {
    // Filled lazily, deliberately not from an [init]: a required module's
    // [init] does not run in the standalone context on the pinned daslang.
    if (empty(g_opIndex)) {
        for (i in range(m3_OpCount())) {
            g_opIndex[unsafe(reinterpret<u64>(m3_OpAt(i)))] = i
        }
    }
    let idx = g_opIndex ?[unsafe(reinterpret<u64>(op))] ?? -1
    d_m3Assert(idx >= 0, "m3_OpIndex: not an m3_exec operation")
    return u64(idx)
}


// C: #define nextOpImpl() ((IM3Operation)(* _pc))(_pc + 1, d_m3OpArgs)
def public nextOpImpl(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe {
        let operation = reinterpret<IM3Operation>(_pc[0])
        return operation(_pc + 1, _sp, _mem, _r0, _fp0)
    }
}

// C: #define jumpOpImpl(PC) ((IM3Operation)(* PC))( PC + 1, d_m3OpArgs)
def public jumpOpImpl(var pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe {
        let operation = reinterpret<IM3Operation>(pc[0])
        return operation(pc + 1, _sp, _mem, _r0, _fp0)
    }
}

// C: #define nextOpDirect() M3_MUSTTAIL return nextOpImpl()
[inline]
def public nextOpDirect(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
}

// C: #define jumpOpDirect(PC) M3_MUSTTAIL return jumpOpImpl((pc_t)(PC))
[inline]
def public jumpOpDirect(var PC : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return jumpOpImpl(PC, _sp, _mem, _r0, _fp0)
}


// C: d_m3RetSig RunCode (d_m3OpSig) { nextOpDirect(); }
def public RunCode(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
}


// C: static inline m3ret_t Call (d_m3OpSig) — takes the operation signature by
// value and its callers (op_Call, op_CallIndirect) pass a fresh stack pointer
// and cleared registers. C ends it with nextOpDirect(), a MUSTTAIL return of
// nextOpImpl(): Call's result is the completed result of the callee's operation
// chain, so the trampoline form is nextOpImpl, one nested RunLoop per wasm call.
// Deliberately not [inline]: its five parameters are by value, so an inline
// splice turns one call node into five argument-copy nodes plus the result
// temporary. Measured on fib 28 that is a loss (4.04 s against 3.91 s).
// C tests the M3Result against NULL, one pointer comparison. The port's
// M3Result is a string and m3Err_none is "" (m3_core.das), so `r ==
// m3Err_none` is a CONTENT comparison: both backends emit a call - strcmp in
// the -ctx emission, jit_str_cmp in the LLVM JIT - on the return path of every
// wasm call, every host call and every trapping arithmetic operation. This
// module tests the result with m3ResultIsOk/m3ResultIsError (m3_core.das):
// `empty`'s contract, spelled as the pointer test C's comparison is.
def Call(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let possible_trap = m3_Yield()
    if (m3ResultIsError(possible_trap)) { return possible_trap }
    return nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand == i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand != i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand < i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand > i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand <= i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand >= i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand == _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand != _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand < _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand > _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand <= _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand >= _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand < u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand > u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand <= u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand >= u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand < u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand > u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand <= u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand >= u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand == f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand != f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand < f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand > f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand <= f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand >= f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand == _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand != _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand < _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand > _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand <= _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand >= _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

// C m3_math_utils.h spells these as preprocessor macros, so they cost nothing
// at the use site; [inline] is the same thing for the daslang interpreter,
// which would otherwise evaluate a call node per arithmetic operation.
[inline]
def OP_ADD_32(a, b : i32) : i32 { unsafe { return reinterpret<i32>(reinterpret<u32>(a) + reinterpret<u32>(b)) } }
[inline]
def OP_ADD_64(a, b : i64) : i64 { unsafe { return reinterpret<i64>(reinterpret<u64>(a) + reinterpret<u64>(b)) } }
[inline]
def OP_SUB_32(a, b : i32) : i32 { unsafe { return reinterpret<i32>(reinterpret<u32>(a) - reinterpret<u32>(b)) } }
[inline]
def OP_SUB_64(a, b : i64) : i64 { unsafe { return reinterpret<i64>(reinterpret<u64>(a) - reinterpret<u64>(b)) } }
[inline]
def OP_MUL_32(a, b : i32) : i32 { unsafe { return reinterpret<i32>(reinterpret<u32>(a) * reinterpret<u32>(b)) } }
[inline]
def OP_MUL_64(a, b : i64) : i64 { unsafe { return reinterpret<i64>(reinterpret<u64>(a) * reinterpret<u64>(b)) } }

[inline]
def OP_SHL_32(x, n : u32) : u32 { return x << (n % 32u) }
[inline]
def OP_SHL_64(x, n : u64) : u64 { return x << (n % 64ul) }
[inline]
def OP_SHR_32(x, n : u32) : u32 { return x >> (n % 32u) }
[inline]
def OP_SHR_64(x, n : u64) : u64 { return x >> (n % 64ul) }

// C: "clz(0), ctz(0) results are undefined for rest platforms, fix it" - the
// portable branch of the OP_CLZ_*/OP_CTZ_* macros. The Daslang builtins share
// the hardware quirk (clz(0u) is 31 here), so the guard is mandatory.
[inline]
def OP_CLZ_32(x : u32) : u32 { return x == 0u ? 32u : clz(x) }
[inline]
def OP_CTZ_32(x : u32) : u32 { return x == 0u ? 32u : ctz(x) }
[inline]
def OP_CLZ_64(x : u64) : u64 { return x == 0ul ? 64ul : clz(x) }
[inline]
def OP_CTZ_64(x : u64) : u64 { return x == 0ul ? 64ul : ctz(x) }

def public op_i32_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_ADD_32(operand, i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_ADD_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_ADD_64(operand, _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = OP_ADD_64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_MUL_32(operand, i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_MUL_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_MUL_64(operand, _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = OP_MUL_64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_SUB_32(i32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_SUB_32(operand, i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_SUB_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_SUB_64(_r0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_SUB_64(operand, _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = OP_SUB_64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftLeft_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftLeft_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftLeft_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftLeft_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_64(u64(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftLeft_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_64(operand, u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftLeft_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_64(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(i32(_r0) >> i32(u32(operand) % 32u))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(operand >> i32(u32(i32(_r0)) % 32u))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(operand1 >> i32(u32(operand2) % 32u))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = (_r0 >> i64(u64(operand) % 64ul))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = (operand >> i64(u64(_r0) % 64ul))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = (operand1 >> i64(u64(operand2) % 64ul))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_64(u64(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_64(operand, u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_64(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_And_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand & u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_And_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand1 & operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Or_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand | u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Or_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand1 | operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Xor_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand ^ u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Xor_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand1 ^ operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_And_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand & u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_And_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand1 & operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Or_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand | u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Or_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand1 | operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Xor_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand ^ u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Xor_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand1 ^ operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand + f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 + operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand * f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 * operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(f32(_fp0) - operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand - f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 - operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(f32(_fp0) / operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand / f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 / operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand + _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 + operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand * _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 * operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (_fp0 - operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand - _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 - operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (_fp0 / operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand / _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 / operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotl_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotl32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotl_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotl32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotl_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotl32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotr_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotr32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotr_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotr32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotr_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotr32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotl_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotl64(u64(_r0), u32(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotl_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotl64(operand, u32(u64(_r0) % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotl_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotl64(operand1, u32(operand2 % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotr_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotr64(u64(_r0), u32(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotr_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotr64(operand, u32(u64(_r0) % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotr_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotr64(operand1, u32(operand2 % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_DIV_U(RES, u32(_r0), operand)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_DIV_U(RES, operand, u32(_r0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_DIV_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_REM_U(RES, u32(_r0), operand)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_REM_U(RES, operand, u32(_r0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_REM_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_DIV_S(RES, i32(_r0), operand, INT32_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_DIV_S(RES, operand, i32(_r0), INT32_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_DIV_S(RES, operand1, operand2, INT32_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_REM_S(RES, i32(_r0), operand, INT32_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_REM_S(RES, operand, i32(_r0), INT32_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_REM_S(RES, operand1, operand2, INT32_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_DIV_U(RES, u64(_r0), operand)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_DIV_U(RES, operand, u64(_r0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_DIV_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_REM_U(RES, u64(_r0), operand)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_REM_U(RES, operand, u64(_r0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_REM_U(RES, operand1, operand2)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_DIV_S(RES, _r0, operand, INT64_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_DIV_S(RES, operand, _r0, INT64_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_DIV_S(RES, operand1, operand2, INT64_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_REM_S(RES, _r0, operand, INT64_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_REM_S(RES, operand, _r0, INT64_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_REM_S(RES, operand1, operand2, INT64_MIN)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Min_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(min_f32(f32(_fp0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Min_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(min_f32(operand, f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Min_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(min_f32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Max_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(max_f32(f32(_fp0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Max_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(max_f32(operand, f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Max_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(max_f32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_CopySign_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(copysign_f32(f32(_fp0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_CopySign_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(copysign_f32(operand, f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_CopySign_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(copysign_f32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Min_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = min_f64(_fp0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Min_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = min_f64(operand, _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Min_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = min_f64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Max_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = max_f64(_fp0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Max_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = max_f64(operand, _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Max_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = max_f64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_CopySign_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = copysign_f64(_fp0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_CopySign_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = copysign_f64(operand, _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_CopySign_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = copysign_f64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Abs_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(fabsf(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Abs_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(fabsf(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Ceil_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(ceilf(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Ceil_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(ceilf(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Floor_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(floorf(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Floor_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(floorf(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Trunc_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::trunc(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Trunc_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::trunc(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Sqrt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::sqrt(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Sqrt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::sqrt(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Nearest_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(rintf(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Nearest_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(rintf(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Negate_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(-(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Negate_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(-(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Abs_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = fabs(_fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Abs_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = fabs(operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Ceil_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::ceil(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Ceil_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::ceil(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Floor_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::floor(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Floor_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::floor(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Trunc_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::trunc(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Trunc_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::trunc(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Sqrt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::sqrt(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Sqrt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::sqrt(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Nearest_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = rint(_fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Nearest_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = rint(operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Negate_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (-(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Negate_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (-(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_EqualToZero_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = bool_reg(i32(_r0) == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_EqualToZero_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_EqualToZero_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = bool_reg(_r0 == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_EqualToZero_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Clz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(OP_CLZ_32(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Clz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_CLZ_32(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Ctz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(OP_CTZ_32(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Ctz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_CTZ_32(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Popcnt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(popcnt(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Popcnt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(popcnt(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Clz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(OP_CLZ_64(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Clz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_CLZ_64(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Ctz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(OP_CTZ_64(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Ctz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_CTZ_64(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Popcnt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(popcnt(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Popcnt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(popcnt(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Wrap_i64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(u32(u64(_r0) & 0xfffffffful))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Wrap_i64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = m3reg_t(u32(u64(operand) & 0xfffffffful))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend8_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(i32(i8(i32(_r0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend8_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(i32(i8(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend16_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(i32(i16(i32(_r0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend16_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(i32(i16(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend8_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i8(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend8_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = i64(i8(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend16_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i16(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend16_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = i64(i16(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = i64(i32(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, f32(_fp0))
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, _fp0)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, source)
    if (m3ResultIsError(result)) { return result }
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, _fp0)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, _fp0)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, _fp0)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, _fp0)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, source)
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, _fp0)
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, source)
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, _fp0)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, _fp0)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, _fp0)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, source)
    unsafe(dest[0]) = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_i32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_i32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(slot_i32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_u32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_u32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(slot_u32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Demote_f64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Demote_f64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(slot_f64(_pc, _sp)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Promote_f32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Promote_f32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(slot_f32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe(dest[0]) = f32(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe(dest[0]) = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(unsafe(reinterpret<i32>(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    _r0 = m3reg_t(unsafe(reinterpret<i32>(source)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i32>(f32(_fp0))) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i32>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = unsafe(reinterpret<i64>(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    _r0 = unsafe(reinterpret<i64>(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i64>(_fp0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i64>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(unsafe(reinterpret<f32>(i32(_r0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    _fp0 = f64(unsafe(reinterpret<f32>(source)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f32>(i32(_r0))) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f32>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = unsafe(reinterpret<f64>(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    _fp0 = unsafe(reinterpret<f64>(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f64>(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f64>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_GetGlobal_s32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u32?>(immediate_code(_pc)))
    unsafe { slot_ptr_u32(_pc, _sp)[0] = global[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_GetGlobal_s64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u64?>(immediate_code(_pc)))
    unsafe { slot_ptr_u64(_pc, _sp)[0] = global[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u32?>(immediate_code(_pc)))
    unsafe(global[0]) = u32(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u64?>(immediate_code(_pc)))
    unsafe(global[0]) = u64(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Call(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var callPC = immediate_pc(_pc)
    let stackOffset = immediate_i32(_pc)
    let memory = m3MemInfo(_mem)
    var sp = unsafe(_sp + stackOffset)
    let r = Call(callPC, sp, _mem, 0l, 0.0lf)
    _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
    if (m3ResultIsOk(r)) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    pushBacktraceFrame(_pc, _mem)
    return forwardTrap(r)
}

def public op_CallIndirect(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let tableIndex = slot_u32(_pc, _sp)
    var _module = immediate_module(_pc)
    let _type = immediate_functype(_pc)
    let stackOffset = immediate_i32(_pc)
    let memory = m3MemInfo(_mem)
    var sp = unsafe(_sp + stackOffset)
    var r : M3Result = m3Err_none
    if (tableIndex < _module.table0Size) {
        var _function = unsafe(_module.table0[tableIndex])
        if (_function != null) {
            if (_type == _function.funcType) {
                if (_function.compiled == null) { r = CompileFunction(_function) }
                if (m3ResultIsOk(r)) {
                    // C: Call (function->compiled, ...) - read after the lazy compile, not before.
                    r = Call(unsafe(reinterpret<pc_t>(_function.compiled)), sp, _mem, 0l, 0.0lf)
                    _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
                    if (m3ResultIsOk(r)) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
                    pushBacktraceFrame(_pc, _mem)
                    return forwardTrap(r)
                }
            } else { r = m3Err_trapIndirectCallTypeMismatch }
        } else { r = m3Err_trapTableElementIsNull }
    } else { r = m3Err_trapTableIndexOutOfRange }
    if (m3ResultIsError(r)) { return newTrap(_pc, _mem, r) }
    return forwardTrap(r)
}

def public op_CallRawFunction(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var ctx : M3ImportContext
    let call = immediate_rawcall(_pc)
    ctx._function = immediate_function(_pc)
    ctx.userdata = immediate_code(_pc)
    // `sp` is `var`: M3RawCall takes `_sp` and `_mem` as `var` (see the
    // typedef in m3_types.das, upstream #3991).
    var sp = unsafe(reinterpret<u64?>(_sp))
    let memory = m3MemInfo(_mem)
    var runtime = m3MemRuntime(_mem)
    let stack_backup = runtime.stack
    runtime.stack = sp
    let possible_trap = call(runtime, unsafe(addr(ctx)), sp, m3MemData(_mem))
    runtime.stack = stack_backup
    if (m3ResultIsError(possible_trap)) { _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated)); pushBacktraceFrame(_pc, _mem) }
    return forwardTrap(possible_trap)
}

def public op_MemSize(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let memory = m3MemInfo(_mem)
    _r0 = m3reg_t(memory.numPages)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_MemGrow(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var runtime = m3MemRuntime(_mem)
    let memory = unsafe(addr(runtime.memory))
    let numPagesToGrow = i32(_r0)
    if (numPagesToGrow >= 0) {
        _r0 = m3reg_t(memory.numPages)
        if (numPagesToGrow != 0) {
            let requiredPages = memory.numPages + u32(numPagesToGrow)
            let r = ResizeMemory(runtime, requiredPages)
            if (m3ResultIsError(r)) { _r0 = -1l }
            _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
        }
    } else { _r0 = -1l }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_MemCopy(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let size = u32(_r0)
    let source = u64(slot_u32(_pc, _sp))
    let destination = u64(slot_u32(_pc, _sp))
    if (destination + u64(size) <= _mem.length) {
        if (source + u64(size) <= _mem.length) {
            let dst = unsafe(m3MemData(_mem) + int64(destination))
            let src = unsafe(m3MemData(_mem) + int64(source))
            unsafe(memmove(dst, src, size))
            return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
        }
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_MemFill(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let size = u32(_r0)
    let byte = slot_u32(_pc, _sp)
    let destination = u64(slot_u32(_pc, _sp))
    if (destination + u64(size) <= _mem.length) {
        unsafe { memset8(m3MemData(_mem) + int64(destination), u8(byte), int(size)) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_Compile(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe {
        var rewrite = (_pc - 1)
        // C: * (_pc - 1) = op_Call — the operation word of the op_Compile that
        // is running, so it goes through m3_OpWord like every other emission
        // of an operation word.
        rewrite[0] = unsafe(reinterpret<code_t>(m3_OpWord(@@op_Call)))
    }
    var _function = immediate_function(_pc)
    var result : M3Result = m3Err_none
    if (_function.compiled == null) { result = CompileFunction(_function) }
    if (m3ResultIsOk(result)) {
        _pc = unsafe(_pc - 1)
        unsafe { _pc[0] = reinterpret<code_t>(_function.compiled) }
        _pc = unsafe(_pc - 1)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, result)
}

def public op_Entry(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = 0l
    _fp0 = 0.0lf
    let _function = immediate_function(_pc)
    let memory = m3MemInfo(_mem)
    let stackEnd = unsafe(_sp + int(_function.maxStackSlots))
if (d_m3SkipStackCheck || intptr(stackEnd) < intptr(_mem.maxStack)) {
        // DEBUG-only hit counter omitted when DEBUG is not part of the Das module configuration.
        var stack = unsafe(reinterpret<u8?>(unsafe(_sp + int(_function.numRetAndArgSlots))))
        // C: memset (stack, 0x0, function->numLocalBytes)
        unsafe(memset8(stack, 0u8, int(_function.numLocalBytes)))
        stack = unsafe(stack + int(_function.numLocalBytes))
        if (_function.constants != null) { unsafe(memcpy(stack, _function.constants, int(_function.numConstantBytes))) }
        let r = nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
        if (m3ResultIsError(r)) {
            _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
            // d_m3RecordBacktraces == false: the C FillBacktraceFunctionInfo call is compiled out.
        }
        return forwardTrap(r)
    }
    return newTrap(_pc, _mem, m3Err_trapStackOverflow)
}

def public op_Loop(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = 0l
    _fp0 = 0.0lf
    var r : M3Result
    let memory = m3MemInfo(_mem)
    while (true) {
        r = nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
        _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
        // C: while (r == _pc). m3ret_t is a void*, so a loop id returned by
        // op_ContinueLoop is the loop's pc itself; compare the pointers, not
        // the string contents an M3Result would otherwise be compared by.
        if (unsafe(reinterpret<void?>(r)) != unsafe(reinterpret<void?>(_pc))) { break }
    }
    return forwardTrap(r)
}

def public op_Branch(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe {
        var branch = reinterpret<pc_t>(_pc[0])
        return jumpOpDirect(branch, _sp, _mem, _r0, _fp0)
    }
}

def public op_If_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    var elsePC = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(elsePC, _sp, _mem, _r0, _fp0)
}

def public op_If_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    var elsePC = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(elsePC, _sp, _mem, _r0, _fp0)
}

def public op_BranchTable(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var branchIndex = slot_u32(_pc, _sp)
    let numTargets = immediate_u32(_pc)
    var branches = unsafe(reinterpret<pc_t?>(_pc))
    if (branchIndex > numTargets) { branchIndex = numTargets }
    var target : pc_t = unsafe(branches[int(branchIndex)])
    return jumpOpDirect(target, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(slot_i32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe(slot_ptr_i32(_pc, _sp)[0]) = i32(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_i32(_pc, _sp)
    var preserve = slot_ptr_i32(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe(stack[0]) = i32(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = slot_i64(_pc, _sp)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe(slot_ptr_i64(_pc, _sp)[0]) = _r0
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_i64(_pc, _sp)
    var preserve = slot_ptr_i64(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe(stack[0]) = _r0
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(slot_f32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe(slot_ptr_f32(_pc, _sp)[0]) = f32(_fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_f32(_pc, _sp)
    var preserve = slot_ptr_f32(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe(stack[0]) = f32(_fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = slot_f64(_pc, _sp)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe(slot_ptr_f64(_pc, _sp)[0]) = _fp0
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_f64(_pc, _sp)
    var preserve = slot_ptr_f64(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe(stack[0]) = _fp0
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_CopySlot_32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dst = slot_ptr_u32(_pc, _sp)
    var src = slot_ptr_u32(_pc, _sp)
    unsafe { dst[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveCopySlot_32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var src = slot_ptr_u32(_pc, _sp)
    var preserve = slot_ptr_u32(_pc, _sp)
    unsafe { preserve[0] = dest[0] }
    unsafe { dest[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_CopySlot_64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dst = slot_ptr_u64(_pc, _sp)
    var src = slot_ptr_u64(_pc, _sp)
    unsafe { dst[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveCopySlot_64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var src = slot_ptr_u64(_pc, _sp)
    var preserve = slot_ptr_u64(_pc, _sp)
    unsafe { preserve[0] = dest[0] }
    unsafe { dest[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

// compiled out under the active configuration: d_m3EnableOpTracing == false (op_DumpStack)

def public op_Select_i32_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(operand1) } else { _r0 = m3reg_t(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(operand1) } else { _r0 = m3reg_t(i32(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(i32(_r0)) } else { _r0 = m3reg_t(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(operand1) } else { _r0 = m3reg_t(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = operand1 } else { _r0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = operand1 } else { _r0 = _r0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = _r0 } else { _r0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = operand1 } else { _r0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(f32(_fp0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(f32(_fp0)) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_rrs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(f32(_fp0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_rsr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(f32(_fp0)) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = _fp0 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_rrs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_rsr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = _fp0 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Return(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    if (d_m3LogNativeStack) { m3StackCheck() }   // C: an empty macro unless d_m3LogNativeStack
    return m3Err_none
}

def public op_BranchIf_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return jumpOpDirect(branch, _sp, _mem, _r0, _fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_BranchIf_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return jumpOpDirect(branch, _sp, _mem, _r0, _fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_BranchIfPrologue_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(branch, _sp, _mem, _r0, _fp0)
}

def public op_BranchIfPrologue_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(branch, _sp, _mem, _r0, _fp0)
}

def public op_ContinueLoop(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    if (d_m3LogNativeStack) { m3StackCheck() }   // C: an empty macro unless d_m3LogNativeStack
    let loopId = immediate_code(_pc)
    return unsafe(reinterpret<M3Result>(loopId))
}

def public op_ContinueLoopIf(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let loopId = immediate_code(_pc)
    if (condition != 0) { return unsafe(reinterpret<M3Result>(loopId)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Const32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let p = unsafe(reinterpret<u32 const?>(_pc))
    let value = unsafe(p[0])
    _pc = unsafe(_pc + 1)
    unsafe(slot_ptr_u32(_pc, _sp)[0]) = value
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Const64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var value : u64
    unsafe {
        let p = reinterpret<u64 const?>(_pc)
        value = p[0]
        if (M3_SIZEOF_PTR == 4) { _pc += 2 } else { _pc++ }
    }
    unsafe(slot_ptr_u64(_pc, _sp)[0]) = value
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Unsupported(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return newTrap(_pc, _mem, "unsupported instruction executed")
}

def public op_Unreachable(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    if (d_m3LogNativeStack) { m3StackCheck() }   // C: an empty macro unless d_m3LogNativeStack
    return newTrap(_pc, _mem, m3Err_trapUnreachable)
}

def public op_End(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    if (d_m3LogNativeStack) { m3StackCheck() }   // C: an empty macro unless d_m3LogNativeStack
    return m3Err_none
}

def public op_SetGlobal_s32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u32?>(immediate_code(_pc)))
    unsafe(global[0]) = slot_u32(_pc, _sp)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_s64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u64?>(immediate_code(_pc)))
    unsafe(global[0]) = slot_u64(_pc, _sp)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<f32?>(immediate_code(_pc)))
    unsafe(global[0]) = f32(_fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<f64?>(immediate_code(_pc)))
    unsafe(global[0]) = _fp0
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

/* The load and store operations below. C writes the access through memcpy of
   a constant size (m3_exec.h, d_m3Load/d_m3Store) and says why at the macro:
   "memcpy here is to support non-aligned access on some platforms". On the
   platforms this port builds for, a scalar load or store of the same size is
   exactly what that memcpy compiles to, and it is the one spelling both
   backends lower to one instruction: gcc folds the constant-size memcpy of the
   -ctx emission itself, but the LLVM JIT keeps daslang's memcpy as a call
   through the runtime's function pointer, which needs a frame, spills the five
   interpreter registers around it and turns the operation's tail jump into a
   call plus a return - a native frame per executed load (docs/native-build.md,
   section 6, E10). So the deviation from C's spelling is the constant-size
   memcpy written as the typed access it means. The two variable-size copies of
   this module, op_MemCopy and op_Entry's constants, stay memcpy, as in C. */
def public op_f32_Load_f32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var value : f32
        unsafe { value = reinterpret<f32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _fp0 = f64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Load_f32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var value : f32
        unsafe { value = reinterpret<f32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _fp0 = f64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Load_f64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var value : f64
        unsafe { value = reinterpret<f64 const?>(m3MemData(_mem) + int64(operand))[0] }
        _fp0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Load_f64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var value : f64
        unsafe { value = reinterpret<f64 const?>(m3MemData(_mem) + int64(operand))[0] }
        _fp0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { value = reinterpret<i8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { value = reinterpret<i8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { value = reinterpret<u8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { value = reinterpret<u8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { value = reinterpret<i16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { value = reinterpret<i16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { value = reinterpret<u16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { value = reinterpret<u16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { value = reinterpret<i32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { value = reinterpret<i32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = m3reg_t(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { value = reinterpret<i8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { value = reinterpret<i8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { value = reinterpret<u8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { value = reinterpret<u8 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { value = reinterpret<i16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { value = reinterpret<i16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { value = reinterpret<u16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { value = reinterpret<u16 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { value = reinterpret<i32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { value = reinterpret<i32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u32>)) <= _mem.length) {
        var value : u32
        unsafe { value = reinterpret<u32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u32>)) <= _mem.length) {
        var value : u32
        unsafe { value = reinterpret<u32 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var value : i64
        unsafe { value = reinterpret<i64 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var value : i64
        unsafe { value = reinterpret<i64 const?>(m3MemData(_mem) + int64(operand))[0] }
        _r0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        let val = f32(_fp0)
        unsafe { reinterpret<f32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<f32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<f32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_rr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        let val = f32(_fp0)
        unsafe { reinterpret<f32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        let val = _fp0
        unsafe { reinterpret<f64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<f64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<f64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_rr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        let val = _fp0
        unsafe { reinterpret<f64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_u8_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        let val = u8(i32(_r0))
        unsafe { reinterpret<u8?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_u8_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        let val = u8(value)
        unsafe { reinterpret<u8?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_u8_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        let val = u8(value)
        unsafe { reinterpret<u8?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i16_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        let val = i16(i32(_r0))
        unsafe { reinterpret<i16?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i16_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        let val = i16(value)
        unsafe { reinterpret<i16?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i16_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        let val = i16(value)
        unsafe { reinterpret<i16?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i32_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        let val = i32(_r0)
        unsafe { reinterpret<i32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i32_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<i32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i32_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<i32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_u8_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        let val = u8(_r0)
        unsafe { reinterpret<u8?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_u8_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        let val = u8(value)
        unsafe { reinterpret<u8?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_u8_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        let val = u8(value)
        unsafe { reinterpret<u8?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i16_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        let val = i16(_r0)
        unsafe { reinterpret<i16?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i16_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        let val = i16(value)
        unsafe { reinterpret<i16?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i16_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        let val = i16(value)
        unsafe { reinterpret<i16?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i32_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        let val = i32(_r0)
        unsafe { reinterpret<i32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i32_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        let val = i32(value)
        unsafe { reinterpret<i32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i32_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        let val = i32(value)
        unsafe { reinterpret<i32?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i64_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        let val = _r0
        unsafe { reinterpret<i64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i64_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<i64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i64_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        let val = value
        unsafe { reinterpret<i64?>(m3MemData(_mem) + int64(operand))[0] = val }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

// debugOp (d_m3EnableOpTracing) and profileOp (d_m3EnableOpProfiling) are
// compiled out under the active configuration.
// configuration, together with its C definition in m3_exec_defs.h.