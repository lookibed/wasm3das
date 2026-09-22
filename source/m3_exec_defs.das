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

    The C form restored (docs/execution-design.md, section 6). The five
    interpreter registers are passed BY VALUE and every operation ends with
    `return nextOpImpl(...)`, the direct call of the next operation that C
    spells `M3_MUSTTAIL return nextOpImpl()`. Daslang still has no
    M3_MUSTTAIL, so the daslang interpreter tier nests one frame per executed
    operation and is slower and deeper than the trampoline it replaces
    (measured 1.3-1.6x on fib 30); the gain is in the AOT/ctx tier, where the
    emitted C++ `return operation(...)` is a tail call gcc turns into a
    sibling-call jump, exactly as in C wasm3.

    nextOpImpl, jumpOpImpl, nextOpDirect, jumpOpDirect and RunCode - C's
    M3_MUSTTAIL threading - live in m3_exec.das, not here, because under the
    LLVM JIT an infer pass replaces the indirect call through the code-page
    word with a generated tree of DIRECT calls to the op_* functions, and only
    m3_exec.das sees them all. The C form is the source form and what every
    other tier compiles; see the "Operation dispatch" section of m3_exec.das.
    What stays in this file is the ABI itself - IM3Operation - which the
    compile tables of m3_compile.das keep in C's shape (c_setSetOps, the
    M3OP(...) rows, c_opNull and IsNoOp all hold IM3Operation VALUES).
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


// nextOpImpl, jumpOpImpl, nextOpDirect and jumpOpDirect - C's
// #define nextOpImpl() ((IM3Operation)(* _pc))(_pc + 1, d_m3OpArgs) and its
// three companions - live in m3_exec.das, next to the operations. See the
// "Operation dispatch" section there and the paragraph above.


// ============================================================================
// RunCode
// ============================================================================


// C: d_m3RetSig RunCode (d_m3OpSig) { nextOpDirect(); } - also in m3_exec.das,
// because it is nextOpDirect and nothing else.
