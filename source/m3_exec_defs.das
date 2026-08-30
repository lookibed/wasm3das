options gen2
options indenting = 4

module m3_exec_defs shared public

require ./m3_core.das public
require ./m3_types.das public


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

    C nextOpImpl()/jumpOpImpl() expand through ((IM3Operation)(*_pc))(_pc + 1, ...)
    and become the plain calls below; C nextOpDirect()/jumpOpDirect() add the
    M3_MUSTTAIL marker, which has no Daslang equivalent and is documented at
    the call sites instead.
*/


// ============================================================================
// Memory accessors
// ============================================================================


/* C: #define m3MemData(mem) (u8*)(((M3MemoryHeader*)(mem))+1) */
def public m3MemData(var _mem : M3MemoryHeader?) : u8? {
    unsafe {
        return reinterpret<u8?>(_mem + 1)
    }
}

/* C: #define m3MemRuntime(mem) (((M3MemoryHeader*)(mem))->runtime) */
def public m3MemRuntime(var _mem : M3MemoryHeader?) : IM3Runtime {
    return _mem.runtime
}

/* C: #define m3MemInfo(mem) (&(((M3MemoryHeader*)(mem))->runtime->memory)) */
def public m3MemInfo(var _mem : M3MemoryHeader?) : IM3Memory {
    unsafe {
        return addr(_mem.runtime.memory)
    }
}


// ============================================================================
// Operation ABI
// ============================================================================


/* C: typedef m3ret_t (vectorcall * IM3Operation) (d_m3OpSig); */
typedef public IM3Operation = function<(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result>


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
def public nextOpDirect(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
}

// C: #define jumpOpDirect(PC) M3_MUSTTAIL return jumpOpImpl((pc_t)(PC))
def public jumpOpDirect(var pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return jumpOpImpl(pc, _sp, _mem, _r0, _fp0)
}


// ============================================================================
// RunCode
// ============================================================================


// C: d_m3RetSig RunCode (d_m3OpSig) { nextOpDirect(); }
def public RunCode(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}
