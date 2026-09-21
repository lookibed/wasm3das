options gen2
options indenting = 4

module m3_exec_defs shared public

require ./m3_core.das public
require ./m3_types.das


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

<<<<<<< HEAD
    The C form restored (docs/execution-design.md, section 6). The five
    interpreter registers are passed BY VALUE and every operation ends with
    `return nextOpImpl(...)`, the direct call of the next operation that C
    spells `M3_MUSTTAIL return nextOpImpl()`. Daslang still has no
    M3_MUSTTAIL, so the daslang interpreter tier nests one frame per executed
    operation and is slower and deeper than the trampoline it replaces
    (measured 1.3-1.6x on fib 30); the gain is in the AOT/ctx tier, where the
    emitted C++ `return operation(...)` is a tail call gcc turns into a
    sibling-call jump, exactly as in C wasm3.

    Direct-dispatch experiment (branch perf/jit-dispatch-tree). C stores the
    IM3Operation function pointer itself in the code page and reaches it
    through an indirect call. This branch stores an operation INDEX instead -
    a plain int in 0..m3_OpCount()-1 over the op_* functions of m3_exec sorted
    by name - and nextOpImpl turns it back into the operation with
    m3_DispatchOp, a generated balanced `if (idx < mid)` tree whose leaves are
    DIRECT calls to op_<name>. The reason is the daslang JIT: it never emits a
    tail call for a call through a function value, so on the C form every
    executed operation nests an LLVM frame until the wasm function returns
    (measured 209 ns per operation in a micro-model against 4 ns for the call
    itself), whereas a direct call in return position with the same signature
    is a sibling-call jump for LLVM as it is for gcc.

    Consequently nextOpImpl, jumpOpImpl, nextOpDirect, jumpOpDirect and RunCode
    live in m3_exec.das, not here: only there is every op_* visible for a
    direct call. What stays in this file is the ABI itself - IM3Operation -
    because the operation bodies and the compile tables of m3_compile.das keep
    the C form: `IM3Operation` VALUES live in c_setSetOps, the M3OP(...) rows,
    c_opNull and IsNoOp exactly as in C, and only the code-page word is an
    index. m3_OpIndex (m3_exec.das) is the reverse map the emitters use,
    m3_OpAt the forward one it is built from.
*/


// ============================================================================
// Memory accessors
// ============================================================================


// These three are preprocessor macros in C, so they cost nothing at the use
// site. [inline] is their equivalent for the daslang interpreter, which would
// otherwise evaluate a call node per memory access; every load and store
// operation reaches memory through m3MemData.

// `_mem` is taken by reference: an [inline] argument passed by value is copied
// into a temporary of its own, and every load and store operation expands
// m3MemData.

/* C: #define m3MemData(mem) (u8*)(((M3MemoryHeader*)(mem))+1) */
[inline]
def public m3MemData(_mem : M3MemoryHeader?&) : u8? {
    unsafe {
        return reinterpret<u8?>(_mem + 1)
    }
}

/* C: #define m3MemRuntime(mem) (((M3MemoryHeader*)(mem))->runtime) */
[inline]
def public m3MemRuntime(var _mem : M3MemoryHeader?&) : IM3Runtime {
    return _mem.runtime
}

/* C: #define m3MemInfo(mem) (&(((M3MemoryHeader*)(mem))->runtime->memory)) */
[inline]
def public m3MemInfo(var _mem : M3MemoryHeader?&) : IM3Memory {
    unsafe {
        return addr(_mem.runtime.memory)
    }
}


// ============================================================================
// Operation ABI
// ============================================================================


/* C: typedef m3ret_t (vectorcall * IM3Operation) (d_m3OpSig); */
typedef public IM3Operation = function<(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result>


// nextOpImpl, jumpOpImpl, nextOpDirect, jumpOpDirect and RunCode - C's
// M3_MUSTTAIL threading - live in m3_exec.das, next to the operations the
// generated dispatch tree calls directly. See the direct-dispatch paragraph
// above.
