options gen2
options indenting = 4
// Host functions run once per import call, not per wasm operation:
// automatic inlining costs startup only.
options never_inline = true

module m3_api_wasi shared public

// C includes m3_env.h and m3_exception.h; m3_LinkRawFunction/Ex are declared
// in wasm3.h, which the port spells as m3_bind.das (the same require list
// m3_api_libc.das uses for the same reason).
require ./m3_api_defs.das public
require ./m3_bind.das public
require ./wasi_core.das public
require ./m3_api_wasi_fd.das public
require daslib/random


/*
    Conservative Gen2 port of the core half of m3_api_wasi.c, together with
    the m3_api_wasi.h declarations (the port has no separate header files, so
    the context struct and the two public prototypes live here, as in
    m3_api_libc.das).

    Split of the C file across two Daslang modules:

    | C                                              | port |
    |---|---|
    | m3_wasi_context_t, wasi_context                | this file |
    | convert_clockid, convert_timespec              | this file |
    | args_get, args_sizes_get                       | this file |
    | environ_get, environ_sizes_get                 | this file |
    | random_get, clock_res_get, clock_time_get      | this file |
    | proc_exit                                      | this file |
    | SuppressLookupFailure, m3_GetWasiContext       | this file |
    | m3_LinkWASI                                    | this file |
    | PREOPEN_CNT, struct Preopen, preopen[]         | m3_api_wasi_fd.das |
    | errno_to_wasi                                  | m3_api_wasi_fd.das |
    | copy_iov_to_host                               | m3_api_wasi_fd.das |
    | fd_*, path_open, both fd_seek variants         | m3_api_wasi_fd.das |

    The C names are unchanged on both sides; the only reason for the split is
    that the descriptor half needs a host file-descriptor layer that the core
    half does not. `wasi_iovec_t` moved one step further, into wasi_core.das,
    so that the descriptor module can name it without depending on this one.

    Conditional compilation: the port targets the POSIX branch of the C file
    (`!_WIN32`, `!APE`, `HAS_IOVEC`). The _WIN32 and APE branches are not
    represented, exactly as elsewhere in this port.

    C-macro adaptations, as in m3_api_libc.das:
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list
      (runtime, _ctx, _sp, _mem); the port spells that list out and keeps its
      own `sp` cursor, per the header comment of m3_api_defs.das.
    - m3ApiSuccess() is `return m3Err_none`, m3ApiTrap(V) is `return V`.
    - `_ (EXPR)` (m3_exception.h) is `result = EXPR; if (result != m3Err_none)
      { return result }`; the C function's only `_catch:` label is its
      `return result`.
*/


// ============================================================================
// m3_api_wasi.h: m3_wasi_context_t
// ============================================================================


/*
    C m3_api_wasi.h:

        typedef struct m3_wasi_context_t
        {
            i32                     exit_code;
            u32                     argc;
            ccstr_t *               argv;
        } m3_wasi_context_t;

    DEVIATION: C's `ccstr_t * argv` is a bare pointer to an argv vector the
    embedder owns (wasm3's main.c points it at the real `argv`). The port
    stores a Daslang `array<string>` instead, so the embedder fills it with
    `push` and the strings stay alive with the context. `argc` is kept as a
    separate field, as in C, and is what every function below iterates over;
    the array's own `length` is not used as the argument count, so the C
    control flow is unchanged.
*/
struct public m3_wasi_context_t {
    exit_code : i32
    argc : u32
    argv : array<string>
}


/*
    C: static m3_wasi_context_t* wasi_context;

    A module-level pointer, allocated once in m3_LinkWASI and, exactly as in
    C, never freed: the C `static` outlives every module and runtime and the
    embedder keeps reading `exit_code` after m3_FreeRuntime. The allocation is
    the host pair from m3_core.das (docs/memory-ownership.md), which zeroes,
    so the `argv` array field starts in the valid empty state without a
    constructor.
*/
var private wasi_context : m3_wasi_context_t?


/*
    C: typedef struct wasi_iovec_t { __wasi_size_t buf; __wasi_size_t buf_len; }

    Ported in wasi_core.das next to the ABI iovec it duplicates; see the
    comment there.
*/


/*
    C: #define PREOPEN_CNT 5, struct Preopen, Preopen preopen[PREOPEN_CNT]

    Ported in m3_api_wasi_fd.das: fd_prestat_get, fd_prestat_dir_name and
    path_open are the only readers, and m3_LinkWASI's `open()` loop over the
    table is reached here through wasi_fd_open_preopens().
*/


/*
    C: static __wasi_errno_t errno_to_wasi(int errnum)

    Ported in m3_api_wasi_fd.das: it maps host `errno` values, which only the
    descriptor half produces.
*/


// ============================================================================
// <time.h> substitutes
//
// C calls POSIX clock_gettime/clock_getres and names the clocks with the
// CLOCK_* macros of <time.h>. Daslang binds neither, so the three pieces are
// re-implemented here over the daslang builtins, keeping the C names, the C
// signatures and the C call shape so that convert_clockid, clock_res_get and
// clock_time_get port literally.
//
// The CLOCK_* values are the Linux <time.h> ones (0..3), which is also the
// order wasi_core.h happens to give the WASI clock ids; convert_clockid still
// spells out C's switch rather than relying on that coincidence.
// ============================================================================


let private CLOCK_REALTIME : i32 = 0
let private CLOCK_MONOTONIC : i32 = 1
let private CLOCK_PROCESS_CPUTIME_ID : i32 = 2
let private CLOCK_THREAD_CPUTIME_ID : i32 = 3


// C: struct timespec { time_t tv_sec; long tv_nsec; }
struct public timespec {
    tv_sec : i64
    tv_nsec : i64
}


/*
    Anchor for the realtime clock.

    DEVIATION: C's clock_gettime(CLOCK_REALTIME) returns nanoseconds since the
    epoch. Daslang's wall clock, get_clock(), has one-second resolution, and
    its nanosecond clock, ref_time_ticks(), is monotonic with an undefined
    epoch. The port anchors the monotonic clock to the wall clock once and
    derives every later realtime value as anchor + elapsed. Two consequences,
    both accepted:

    - the absolute epoch can be off by up to one second, the resolution of
      get_clock at the moment of the anchor;
    - the difference between two realtime readings is exact to the
      nanosecond, which is what the WASI test programs actually measure
      (wasm3c/test/wasi/simple/test.c times fib(20) with two CLOCK_REALTIME
      readings and prints the delta in ms).

    The anchor is taken lazily on first use rather than in an [init] function
    because a dastest file that declares its own module does not run the
    [init] functions of the shared modules it requires.
*/
let private NSEC_PER_SEC : i64 = 1000000000l

var private wasi_clock_anchored : bool = false
var private wasi_clock_base_nsec : i64 = 0l
var private wasi_clock_base_ticks : i64 = 0l


def private anchor_wasi_clock() {
    if (!wasi_clock_anchored) {
        wasi_clock_base_nsec = int64(get_clock()) * NSEC_PER_SEC
        wasi_clock_base_ticks = ref_time_ticks()
        wasi_clock_anchored = true
    }
}


// C: int clock_gettime(int clk_id, struct timespec *spec)
def private clock_gettime(clk_id : i32; var spec : timespec&) : i32 {
    anchor_wasi_clock()

    var nsec : i64 = 0l

    if (clk_id == CLOCK_REALTIME) {
        nsec = wasi_clock_base_nsec + (ref_time_ticks() - wasi_clock_base_ticks)
    } elif (clk_id == CLOCK_MONOTONIC) {
        // ref_time_ticks() is monotonic nanoseconds, which is exactly what
        // CLOCK_MONOTONIC promises (its epoch is undefined in both).
        nsec = ref_time_ticks()
    } elif (clk_id == CLOCK_PROCESS_CPUTIME_ID || clk_id == CLOCK_THREAD_CPUTIME_ID) {
        // DEVIATION: daslang exposes no CPU-time clock. Wall time elapsed
        // since the anchor is the closest available reading and keeps the
        // clock monotonic and non-negative, which is what a guest measuring
        // CPU time needs in order not to misbehave.
        nsec = ref_time_ticks() - wasi_clock_base_ticks
    } else {
        return -1
    }

    spec.tv_sec = nsec / NSEC_PER_SEC
    spec.tv_nsec = nsec % NSEC_PER_SEC
    return 0
}


// C: int clock_getres(int clk_id, struct timespec *spec)
//
// DEVIATION: daslang exposes no resolution query. The port therefore behaves
// like the C file's own Windows shim, which is `return -1; // Defaults to
// 1000000`: m3_wasi_generic_clock_res_get then reports 1 ms, an answer the C
// code already produces on one of its supported platforms.
def private clock_getres(clk_id : i32; var spec : timespec&) : i32 {
    return -1
}


// C: static inline int convert_clockid(__wasi_clockid_t in)
// `in` is a daslang keyword; the parameter keeps the C name with the
// established leading-underscore spelling.
def private convert_clockid(_in : wasi_clockid_t) : i32 {
    if (_in == WASI_CLOCKID_MONOTONIC) { return CLOCK_MONOTONIC }
    if (_in == WASI_CLOCKID_PROCESS_CPUTIME_ID) { return CLOCK_PROCESS_CPUTIME_ID }
    if (_in == WASI_CLOCKID_REALTIME) { return CLOCK_REALTIME }
    if (_in == WASI_CLOCKID_THREAD_CPUTIME_ID) { return CLOCK_THREAD_CPUTIME_ID }
    return -1
}


let private UINT64_MAX : u64 = 0xfffffffffffffffful


// C: static inline __wasi_timestamp_t convert_timespec(const struct timespec *ts)
def private convert_timespec(ts : timespec) : wasi_timestamp_t {
    if (ts.tv_sec < 0l) {
        return 0ul
    }
    if (u64(ts.tv_sec) >= UINT64_MAX / u64(NSEC_PER_SEC)) {
        return UINT64_MAX
    }
    return u64(ts.tv_sec) * u64(NSEC_PER_SEC) + u64(ts.tv_nsec)
}


/*
    C: static inline const void* copy_iov_to_host(...)

    Ported in m3_api_wasi_fd.das next to its only two callers, fd_read and
    fd_write.
*/


// ============================================================================
// WASI API implementation
// ============================================================================


// C: m3ApiRawFunction(m3_wasi_generic_args_get)
def public m3_wasi_generic_args_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    // The M3RawCall parameters arrive const; `_sp` is C's mutable cursor and
    // m3ApiCheckMem takes the runtime by mutable value, so both are re-typed
    // once here, as in every raw function of this port.
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    var argv : u32?                                          // m3ApiGetArgMem (uint32_t *, argv)
    var argv_buf : u8?                                       // m3ApiGetArgMem (char *, argv_buf)
    unsafe {
        argv = reinterpret<u32?>(m3ApiGetArgMem(sp, _mem))
        argv_buf = reinterpret<u8?>(m3ApiGetArgMem(sp, _mem))
    }

    var context : m3_wasi_context_t?
    unsafe {
        context = reinterpret<m3_wasi_context_t?>(_ctx.userdata)
    }

    if (context == null) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var check : M3Result = m3ApiCheckMem(rt, _mem, unsafe(reinterpret<void?>(argv)), u64(context.argc) * 4ul)
    if (check != m3Err_none) { return check }

    for (i in 0u..context.argc) {
        // C: m3ApiWriteMem32(&argv[i], m3ApiPtrToOffset(argv_buf));
        // m3ApiOffsetToPtr is `(uint8_t*)base + offset`; with `argv` as the
        // base and a byte offset it is C's `&argv[i]`.
        m3ApiWriteMem32(
            m3ApiOffsetToPtr(unsafe(reinterpret<void?>(argv)), i * 4u),
            m3ApiPtrToOffset(_mem, unsafe(reinterpret<void?>(argv_buf)))
        )

        let len = length(context.argv[i])                    // C: size_t len = strlen (context->argv[i]);

        check = m3ApiCheckMem(rt, _mem, unsafe(reinterpret<void?>(argv_buf)), u64(len))
        if (check != m3Err_none) { return check }

        unsafe {
            memcpy(reinterpret<void?>(argv_buf), reinterpret<void?>(context.argv[i]), len)
            argv_buf = argv_buf + len
            // C: * argv_buf++ = 0;
            argv_buf[0] = 0u8
            argv_buf = argv_buf + 1
        }
    }

    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// C: m3ApiRawFunction(m3_wasi_generic_args_sizes_get)
def public m3_wasi_generic_args_sizes_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    let argc = m3ApiGetArgMem(sp, _mem)                      // m3ApiGetArgMem (__wasi_size_t *, argc)
    let argv_buf_size = m3ApiGetArgMem(sp, _mem)             // m3ApiGetArgMem (__wasi_size_t *, argv_buf_size)

    var check : M3Result = m3ApiCheckMem(rt, _mem, argc, 4ul)
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, _mem, argv_buf_size, 4ul)
    if (check != m3Err_none) { return check }

    var context : m3_wasi_context_t?
    unsafe {
        context = reinterpret<m3_wasi_context_t?>(_ctx.userdata)
    }

    if (context == null) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var buf_len : wasi_size_t = 0u
    for (i in 0u..context.argc) {
        buf_len += u32(length(context.argv[i])) + 1u
    }

    m3ApiWriteMem32(argc, context.argc)
    m3ApiWriteMem32(argv_buf_size, buf_len)

    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// C: m3ApiRawFunction(m3_wasi_generic_environ_get)
// The C body is a bare `// TODO` followed by the success return; the two
// memory arguments are consumed and never used, which is why nothing is
// written into the guest buffers.
def public m3_wasi_generic_environ_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    m3ApiGetArgMem(sp, _mem)                                 // m3ApiGetArgMem (uint32_t *, env)
    m3ApiGetArgMem(sp, _mem)                                 // m3ApiGetArgMem (char *, env_buf)

    // TODO
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// C: m3ApiRawFunction(m3_wasi_generic_environ_sizes_get)
def public m3_wasi_generic_environ_sizes_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    let env_count = m3ApiGetArgMem(sp, _mem)                 // m3ApiGetArgMem (__wasi_size_t *, env_count)
    let env_buf_size = m3ApiGetArgMem(sp, _mem)              // m3ApiGetArgMem (__wasi_size_t *, env_buf_size)

    var check : M3Result = m3ApiCheckMem(rt, _mem, env_count, 4ul)
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, _mem, env_buf_size, 4ul)
    if (check != m3Err_none) { return check }

    // TODO
    m3ApiWriteMem32(env_count, 0u)
    m3ApiWriteMem32(env_buf_size, 0u)

    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


/*
    C, in this order and all ported in m3_api_wasi_fd.das:

        m3_wasi_generic_fd_prestat_dir_name
        m3_wasi_generic_fd_prestat_get
        m3_wasi_generic_fd_fdstat_get
        m3_wasi_generic_fd_fdstat_set_flags
        m3_wasi_unstable_fd_seek
        m3_wasi_snapshot_preview1_fd_seek
        m3_wasi_generic_path_open
        m3_wasi_generic_fd_read
        m3_wasi_generic_fd_write
        m3_wasi_generic_fd_close
        m3_wasi_generic_fd_datasync
*/


/*
    Random source for m3_wasi_generic_random_get.

    DEVIATION: C fills the buffer from the OS entropy pool (getrandom on
    Linux/FreeBSD, getentropy on the BSD-ish platforms, RtlGenRandom on
    Windows) and loops because those calls can return short or fail with
    EINTR/EAGAIN. Daslang has no binding for any of them; daslib/random's LCG
    is what is available. It is a pseudo-random generator seeded once from
    the monotonic clock, so the bytes are not cryptographic quality. Nothing
    in wasm3's WASI test set needs them to be (test.c seeds rand() with
    getentropy and prints a sum), but an embedder that does must replace this
    function.

    The generator never fails and never returns short, so C's retry loop
    collapses to a single pass; the loop's shape is recorded in the comment
    at the call site.

    The seed is taken lazily, for the reason given at anchor_wasi_clock().
*/
var private wasi_random_seeded : bool = false
var private wasi_random_state : int4


def private seed_wasi_random() {
    if (!wasi_random_seeded) {
        wasi_random_state = random_seed(int(ref_time_ticks()))
        wasi_random_seeded = true
    }
}


// C: m3ApiRawFunction(m3_wasi_generic_random_get)
def public m3_wasi_generic_random_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    let buf = m3ApiGetArgMem(sp, _mem)                       // m3ApiGetArgMem (uint8_t *, buf)
    let buf_len = m3ApiGetArg_u32(sp)                        // m3ApiGetArg (__wasi_size_t, buf_len)

    let check : M3Result = m3ApiCheckMem(rt, _mem, buf, u64(buf_len))
    if (check != m3Err_none) { return check }

    seed_wasi_random()

    // C: while (1) { retlen = getrandom(buf, buf_len, 0); ... } - retry on
    // EINTR/EAGAIN, advance buf/buf_len on a short read, return SUCCESS when
    // retlen == buf_len. The generator below always fills the whole buffer.
    for (i in 0u..buf_len) {
        m3ApiWriteMem8(m3ApiOffsetToPtr(buf, i), u8(uint(random_int(wasi_random_state)) & 0xffu))
    }

    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// C: m3ApiRawFunction(m3_wasi_generic_clock_res_get)
def public m3_wasi_generic_clock_res_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    let wasi_clk_id = m3ApiGetArg_u32(sp)                    // m3ApiGetArg (__wasi_clockid_t, wasi_clk_id)
    let resolution = m3ApiGetArgMem(sp, _mem)                // m3ApiGetArgMem (__wasi_timestamp_t *, resolution)

    let check : M3Result = m3ApiCheckMem(rt, _mem, resolution, 8ul)
    if (check != m3Err_none) { return check }

    let clk = convert_clockid(wasi_clk_id)
    if (clk < 0) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var tp : timespec
    if (clock_getres(clk, tp) != 0) {
        m3ApiWriteMem64(resolution, 1000000ul)
    } else {
        m3ApiWriteMem64(resolution, convert_timespec(tp))
    }

    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// C: m3ApiRawFunction(m3_wasi_generic_clock_time_get)
def public m3_wasi_generic_clock_time_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                     // m3ApiReturnType (uint32_t)
    let wasi_clk_id = m3ApiGetArg_u32(sp)                    // m3ApiGetArg (__wasi_clockid_t, wasi_clk_id)
    m3ApiGetArg_u64(sp)                                      // m3ApiGetArg (__wasi_timestamp_t, precision)
    let _time = m3ApiGetArgMem(sp, _mem)                     // m3ApiGetArgMem (__wasi_timestamp_t *, time); C name `time`

    let check : M3Result = m3ApiCheckMem(rt, _mem, _time, 8ul)
    if (check != m3Err_none) { return check }

    let clk = convert_clockid(wasi_clk_id)
    if (clk < 0) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var tp : timespec
    if (clock_gettime(clk, tp) != 0) {
        // C: m3ApiReturn(errno_to_wasi(errno)); the port's clock_gettime has
        // no errno, and its only failure is an unknown clock id, which the
        // convert_clockid check above has already excluded.
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(0)))
        return m3Err_none
    }

    m3ApiWriteMem64(_time, convert_timespec(tp))
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// C: m3ApiRawFunction(m3_wasi_generic_proc_exit)
// No m3ApiReturnType: the C signature is "v(i)", so the first slot is the
// argument, not a return value.
def public m3_wasi_generic_proc_exit(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let code = m3ApiGetArg_u32(sp)                           // m3ApiGetArg (uint32_t, code)

    var context : m3_wasi_context_t?
    unsafe {
        context = reinterpret<m3_wasi_context_t?>(_ctx.userdata)
    }

    if (context != null) {
        context.exit_code = i32(code)
    }

    return m3Err_trapExit                                    // m3ApiTrap (m3Err_trapExit)
}


// ============================================================================
// Linking
// ============================================================================


// C: static M3Result SuppressLookupFailure(M3Result i_result)
def private SuppressLookupFailure(i_result : M3Result) : M3Result {
    if (i_result == m3Err_functionLookupFailed) {
        return m3Err_none
    } else {
        return i_result
    }
}


// C: m3_wasi_context_t* m3_GetWasiContext()
def public m3_GetWasiContext() : m3_wasi_context_t? {
    return wasi_context
}


// C parameter `module` renamed to `_module`: `module` is a daslang keyword.
def public m3_LinkWASI(var _module : IM3Module) : M3Result {
    /*
        C _WIN32 branch sets the three standard handles to O_BINARY; the port
        targets the POSIX branch:

            // Preopen dirs
            for (int i = 3; i < PREOPEN_CNT; i++) {
                preopen[i].fd = open(preopen[i].real_path, O_RDONLY);
            }

        The table and the host `open` live in the descriptor module, so the
        loop is reached through its hook. Descriptors 3 and 4 therefore get
        their numbers here, at link time, exactly as in C.
    */
    wasi_fd_open_preopens()

    if (wasi_context == null) {
        unsafe {
            wasi_context = reinterpret<m3_wasi_context_t?>(m3_Malloc_Impl(u64(typeinfo sizeof(type<m3_wasi_context_t>))))
        }
        wasi_context.exit_code = 0
        wasi_context.argc = 0u
        // C: wasi_context->argv = 0. The port's argv is a Daslang array and
        // m3_Malloc_Impl zeroes, which is that array's valid empty state.
    }

    let namespaces = ["wasi_unstable", "wasi_snapshot_preview1"]

    // Some functions are incompatible between WASI versions
    //
    // C declares `M3Result result = m3Err_none;` at the top of the function;
    // the initialiser is dead there too, because the first `_ (...)`
    // overwrites it before any read, so the first link becomes the
    // declaration here, as in m3_api_libc.das.
    var result : M3Result = SuppressLookupFailure(m3_LinkRawFunction(_module, "wasi_unstable", "fd_seek", "i(iIi*)", @@m3_wasi_unstable_fd_seek))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, "wasi_snapshot_preview1", "fd_seek", "i(iIi*)", @@m3_wasi_snapshot_preview1_fd_seek))
    if (result != m3Err_none) { return result }
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_unstable",          "fd_filestat_get",   "i(i*)",     &m3_wasi_unstable_fd_filestat_get)));
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_snapshot_preview1", "fd_filestat_get",   "i(i*)",     &m3_wasi_snapshot_preview1_fd_filestat_get)));
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_unstable",          "path_filestat_get", "i(ii*i*)",  &m3_wasi_unstable_path_filestat_get)));
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_snapshot_preview1", "path_filestat_get", "i(ii*i*)",  &m3_wasi_snapshot_preview1_path_filestat_get)));

    for (wasi in namespaces) {
        let ctx = unsafe(reinterpret<void const?>(wasi_context))

        result = SuppressLookupFailure(m3_LinkRawFunctionEx(_module, wasi, "args_get", "i(**)", @@m3_wasi_generic_args_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(_module, wasi, "args_sizes_get", "i(**)", @@m3_wasi_generic_args_sizes_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "clock_res_get", "i(i*)", @@m3_wasi_generic_clock_res_get))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "clock_time_get", "i(iI*)", @@m3_wasi_generic_clock_time_get))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "environ_get", "i(**)", @@m3_wasi_generic_environ_get))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "environ_sizes_get", "i(**)", @@m3_wasi_generic_environ_sizes_get))
        if (result != m3Err_none) { return result }

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_advise",            "i(iIIi)", )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_allocate",          "i(iII)",  )));
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_close", "i(i)", @@m3_wasi_generic_fd_close))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_datasync", "i(i)", @@m3_wasi_generic_fd_datasync))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_fdstat_get", "i(i*)", @@m3_wasi_generic_fd_fdstat_get))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_fdstat_set_flags", "i(ii)", @@m3_wasi_generic_fd_fdstat_set_flags))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_fdstat_set_rights", "i(iII)",  )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_filestat_set_size", "i(iI)",   )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_filestat_set_times","i(iIIi)", )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_pread",             "i(i*iI*)",)));
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_prestat_get", "i(i*)", @@m3_wasi_generic_fd_prestat_get))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_prestat_dir_name", "i(i*i)", @@m3_wasi_generic_fd_prestat_dir_name))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_pwrite",            "i(i*iI*)",)));
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_read", "i(i*i*)", @@m3_wasi_generic_fd_read))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_readdir",           "i(i*iI*)",)));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_renumber",          "i(ii)",   )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_sync",              "i(i)",    )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_tell",              "i(i*)",   )));
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "fd_write", "i(i*i*)", @@m3_wasi_generic_fd_write))
        if (result != m3Err_none) { return result }

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_create_directory",    "i(i*i)",       )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_filestat_set_times",  "i(ii*iIIi)",   )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_link",                "i(ii*ii*i)",   )));
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "path_open", "i(ii*iiIIi*)", @@m3_wasi_generic_path_open))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_readlink",            "i(i*i*i*)",    )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_remove_directory",    "i(i*i)",       )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_rename",              "i(i*ii*i)",    )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_symlink",             "i(*ii*i)",     )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_unlink_file",         "i(i*i)",       )));

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "poll_oneoff",          "i(**i*)", &m3_wasi_generic_poll_oneoff)));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(_module, wasi, "proc_exit", "v(i)", @@m3_wasi_generic_proc_exit, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "proc_raise",           "i(i)",    )));
        result = SuppressLookupFailure(m3_LinkRawFunction(_module, wasi, "random_get", "i(*i)", @@m3_wasi_generic_random_get))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sched_yield",          "i()",     )));

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sock_recv",            "i(i*ii**)",        )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sock_send",            "i(i*ii*)",         )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sock_shutdown",        "i(ii)",            )));
    }

    return result                                            // C: _catch: return result;
}
