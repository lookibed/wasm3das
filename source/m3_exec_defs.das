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

    Trampoline deviation (notes/exec_trampoline_design.md). Daslang has no
    M3_MUSTTAIL, so the C shape "every op tail-jumps to the next op" would nest
    one Daslang frame per executed operation. Instead the operation returns to
    a dispatch loop:

        C d_m3OpSig       ->  the same five inputs, taken BY REFERENCE, so the
                              operation updates the dispatcher's state in place
                              exactly where C would have passed the updated
                              values on to the next operation
        C nextOpImpl()    ->  RunLoop: run the code at _pc to completion and
        C jumpOpImpl(PC)      return its result, which is what the C macro means
                              once every operation below it tail-jumps
        C nextOpDirect()  ->  return m3Ret_nextOp, the sentinel that tells the
        C jumpOpDirect(PC)    dispatching RunLoop to execute the word at _pc

    The three places where C makes a real (non-tail) call - Call() from op_Call
    and op_CallIndirect, op_Entry and op_Loop - keep calling nextOpImpl, so a
    nested wasm call still nests a bounded number of Daslang frames per wasm
    frame instead of per executed operation.

    Direct-dispatch deviation. C stores the IM3Operation function pointer itself
    in the code page and reaches it through an indirect call. The port stores an
    operation INDEX instead - a plain int in 0..m3_OpCount()-1 over the op_*
    functions of m3_exec sorted by name - and RunLoop turns it back into the
    operation with m3_DispatchOp, a generated balanced `if (idx < mid)` tree
    whose leaves are DIRECT calls to op_<name>. The reason is inlining: no C++
    compiler and no LLVM pass can inline through an indirect call, so in the
    native tiers (ctx, exe, jit) every wasm operation paid a call/return and
    moved the five interpreter registers through memory. With the tree spliced
    into RunLoop ([inline] on m3_DispatchOp) the backends see ordinary direct
    calls and can inline the operation bodies into the dispatcher.

    Consequently RunLoop, nextOpImpl, jumpOpImpl and RunCode live in m3_exec.das,
    not here: only there is every op_* visible for a direct call. What stays in
    this file is the ABI itself - IM3Operation, the m3Ret_nextOp sentinel and the
    two [inline] tail-position helpers - because the 509 operation bodies and the
    compile tables of m3_compile.das keep the C form: `IM3Operation` VALUES live
    in c_setSetOps, the M3OP(...) rows, c_opNull and IsNoOp exactly as in C, and
    only the code-page word is an index. m3_OpIndex (m3_exec.das) is the reverse
    map the emitters use, m3_OpAt the forward one it is built from.

    Measured, 2026-09-21, and the premise does not hold on this toolchain, so
    this is an experiment on record rather than a win. The daslang AOT does not
    lower a named daslang call to a C++ call at all: every call site becomes
    `das_invoke_function(..., Func(__context__->fnByMangledName(<hash>)), ...)`,
    a Context lookup plus the same indirect invoke the code-page word already
    was. The generated tree therefore costs the ctx tier nine comparisons and a
    mangled-name lookup ON TOP of the indirect call it was meant to remove:
    fib 35 went from 2.38 s to 2.92 s (median of seven, alternating runs). In
    the plain interpreter the cost is the tree itself - nine evaluated nodes per
    operation against one indirect-call node - and fib 30 went from 2.54 s to
    4.66 s. Making this pay would need the AOT to emit a real C++ call for a
    statically known callee, which is a daslang backend change, not a port one.
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
typedef public IM3Operation = function<(var _pc : pc_t&; var _sp : m3stack_t&; var _mem : M3MemoryHeader?&; var _r0 : m3reg_t&; var _fp0 : f64&) : M3Result>


/*
    The dispatcher sentinel. An operation returns it instead of tail-jumping;
    RunLoop recognises it by pointer, never by content, exactly like the loop
    ids op_ContinueLoop returns. It can not collide with m3Err_none, with a
    trap string or with a code page address.

    `var`, not `let`: a `let` string global is constant-folded, and a backend
    that materialises its own copy of the literal (the daslang JIT does) then
    fails the pointer-identity test. A `var` keeps one address everywhere.
*/
var public m3Ret_nextOp : M3Result = "m3: dispatch the operation at _pc"


// RunLoop, nextOpImpl and jumpOpImpl - the trampoline that stands in for C's
// M3_MUSTTAIL threading - live in m3_exec.das, next to the operations they
// dispatch directly. See the direct-dispatch paragraph above.

// C: #define nextOpDirect() M3_MUSTTAIL return nextOpImpl()
// The operation has already written _pc/_sp/_mem/_r0/_fp0 back through its
// reference parameters, so the tail jump is a return to the dispatching loop.
[inline, unused_argument(_pc, _sp, _mem, _r0, _fp0)]
def public nextOpDirect(var _pc : pc_t&; var _sp : m3stack_t&; var _mem : M3MemoryHeader?&; var _r0 : m3reg_t&; var _fp0 : f64&) : M3Result {
    return m3Ret_nextOp
}

// C: #define jumpOpDirect(PC) M3_MUSTTAIL return jumpOpImpl((pc_t)(PC))
// _sp/_mem/_r0/_fp0 are already the dispatcher's own state, so only the branch
// target has to be handed over.
[inline]
def public jumpOpDirect(var _pc : pc_t&; var PC : pc_t) : M3Result {
    _pc = PC
    return m3Ret_nextOp
}


// ============================================================================
// RunCode
// ============================================================================


// C: d_m3RetSig RunCode (d_m3OpSig) { nextOpDirect(); } - in m3_exec.das, with
// RunLoop and the generated dispatch tree it needs.
