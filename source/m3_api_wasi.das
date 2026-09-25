options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (host functions run once
// per import call, so inlining costs startup only) is dropped, as in m3_bind
// and m3_api_libc: the option is untested in the editor (DESIGN.md section 1).

module m3_api_wasi shared public

// C includes m3_env.h and m3_exception.h; m3_LinkRawFunction/Ex are declared
// in wasm3.h, which the port spells as m3_bind.das (the same require list
// m3_api_libc.das uses for the same reason).
require modules/wasm3das/source/m3_api_defs public      // Eden: project-root-relative path (upstream: ./m3_api_defs.das)
require modules/wasm3das/source/m3_bind public          // Eden: project-root-relative path (upstream: ./m3_bind.das)
require modules/wasm3das/source/wasi_core public        // Eden: project-root-relative path (upstream: ./wasi_core.das)
require modules/wasm3das/source/m3_api_wasi_fd public   // Eden: project-root-relative path (upstream: ./m3_api_wasi_fd.das)
require daslib/random
require strings                                         // Eden: length of an argv string (0.6.3 binds it in strings)


/*
    Conservative Gen2 port of the core half of m3_api_wasi.c, together with
    the m3_api_wasi.h declarations (the port has no separate header files, so
    the two public prototypes live here, as in m3_api_libc.das).

    Split of the C file across two Daslang modules:

    | C                                              | port |
    |---|---|
    | m3_wasi_context_t                              | m3_api_wasi_fd.das (Eden) |
    | wasi_context                                   | this file |
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

    Conditional compilation: the port targets the POSIX (Linux) branch of the
    C file (`!_WIN32`, `!APE`, `HAS_IOVEC`, `__linux__`). The _WIN32 and APE
    branches are not represented, exactly as elsewhere in this port. C links
    no sched_yield and no poll_oneoff (both are commented out in
    m3_LinkWASI), so neither exists here.

    C-macro adaptations, as in m3_api_libc.das:
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list; the
      port spells that list out and keeps its own cursor, per the header
      comment of m3_api_defs.das.
    - m3ApiSuccess() is `return m3Err_none`, m3ApiTrap(V) is `return V`.
    - `_ (EXPR)` (m3_exception.h) is `result = EXPR; if (result != m3Err_none)
      { return result }`; the C function's only `_catch:` label is its
      `return result`.

    Eden: deviations from the upstream port (.upstream/source/m3_api_wasi.das)
    and from C, for the EdenSpark sandbox (docs/eden-port/DESIGN.md 1, 4.5,
    4.7, 4.7b-wasi, 4.7c):
      - the requires are Eden-project-root relative (DESIGN section 6);
        `options never_inline` is dropped.
      - every raw function is an M3RawCall
        `(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result`
        (C: `runtime, _ctx, _sp, _mem`) and opens with
        `var f = m3ApiFrame(sp)`; `raw_return` is a cell index and a guest
        pointer is its offset into rt.mem (m3_api_defs). The upstream
        reinterpret lines are gone.
      - THE CONTEXT. C's m3_wasi_context_t is declared in m3_api_wasi_fd
        (it holds the descriptor table and the file-system backend next to
        C's exit_code / argc / argv) and lives in its global
        `m3_wasi_contexts`. C's `static m3_wasi_context_t* wasi_context` is
        the int token of that context here (-1 = C's NULL), and
        `(m3_wasi_context_t*)(_ctx->userdata)` is `ctx.userdata`, the token
        m3_LinkWASI links every import with; C's `context == NULL` test is
        `!m3_IsWasiContext(token)`. A token is an int, so a hot reload that
        carries the globals over (DESIGN 1) keeps the context usable; the
        default backend holds no function value.
      - m3_GetWasiContext() returns the token (C: the pointer). The host
        sets `m3_wasi_contexts[token].argc` / `.argv` (C: `wasi_ctx->argc
        = argc; wasi_ctx->argv = argv;` in platforms/app/main.c) and reads
        `.exit_code` after m3_Call returns m3Err_trapExit.
      - m3_LinkWASI takes the runtime first (m3_bind's m3_LinkRawFunction
        does, as m3_LinkLibC). It creates the context BEFORE the preopen
        loop, because the loop (wasi_fd_open_preopens of m3_api_wasi_fd)
        opens descriptors in that context; C runs the loop first. The
        context test is `!m3_IsWasiContext(wasi_context)` (C:
        `!wasi_context`), which also re-creates a context whose token no
        longer names one.
      - m3_LinkWASI links EVERY WASI import with m3_LinkRawFunctionEx and
        the token (DESIGN 4.7b-wasi): the fd functions, which C links with
        m3_LinkRawFunction (no userdata) because the OS owns its
        descriptors, reach the context's descriptor table through it. The
        clock, environ and random functions ignore it, as in C.
      - args_get copies the argument bytes with m3ApiWriteString (C:
        memcpy) and the NUL with m3ApiWriteMem8 (C: `*argv_buf++ = 0`).
        C checks `len` bytes, not `len + 1`: the NUL one byte past the end
        of the linear memory is written past it in C and is an array
        range panic here, which m3_Call's recover turns into an M3Result
        (m3_env). C iterates `argc`, not the argv length; an argc larger
        than the argv array reads past it in C and panics here likewise.
      - THE CLOCKS. C calls the host clock_gettime / clock_getres with the
        Linux CLOCK_* ids. The sandbox has neither; the port keeps both
        functions under their C names and signatures (private), with C's
        clock ids and C's failure (-1 and errno EINVAL for an id Linux does
        not know; convert_clockid already answers INVAL for an unknown WASI
        id, as in C). Their time source is the builtin pair the editor
        accepts (m3_api_libc uses it too): `get_clock()` (the wall clock,
        one-second resolution) and `ref_time_ticks()` / `get_time_nsec(ref)`
        (a monotonic nanosecond clock; only differences through
        get_time_nsec are used, never the absolute tick value). The clocks
        are anchored once, on first use: the wall-clock second and the tick
        value at that moment. Then
          REALTIME  = anchor seconds (in ns) + ns elapsed since the anchor:
                      nanoseconds since the epoch, off by less than one
                      second in absolute value (the resolution of get_clock
                      at the anchor), exact in every difference, never
                      stepping backwards;
          MONOTONIC = the same value: a monotonic clock whose epoch is the
                      anchor's wall-clock second (Linux: the boot; neither
                      POSIX nor WASI fixes it);
          PROCESS_CPUTIME_ID, THREAD_CPUTIME_ID = ns elapsed since the
                      anchor: the sandbox has no CPU-time clock, and the
                      elapsed wall time keeps the clock monotonic and
                      non-negative (upstream's choice).
        The anchor is taken lazily, on the first clock read: the sandbox
        has no module initializer annotation (DESIGN, porter rules).
      - clock_getres always fails (upstream's choice, the C file's own
        Windows shim `return -1; // Defaults to 1000000`), so
        clock_res_get reports C's 1 ms default for every known clock.
      - random_get keeps C's Linux loop (getrandom, retry on EINTR/EAGAIN,
        advance on a short read). getrandom is a private function under its
        C name that fills the range from daslib/random's LCG
        (`random_int`, seeded once from the monotonic tick value): NOT a
        cryptographically secure generator. The sandbox has no OS entropy
        source; wasm3's WASI tests only seed rand() with the bytes, and an
        embedder that needs real entropy must replace getrandom. It never
        fails and never returns short, so the loop ends on its first pass.
      - C's `errno` is the private global `errno`, set by the two host
        substitutes that can fail (clock_gettime).
    Everything else (names, C order, control flow, checks and their order,
    the trap strings) is the C of m3_api_wasi.c.
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

    Eden: declared in m3_api_wasi_fd.das (see the header): `argv` is an
    array<string> the embedder fills, `argc` stays a separate field, as in
    C, and is what every function below iterates over.
*/


/*
    C: static m3_wasi_context_t* wasi_context;

    Allocated once in m3_LinkWASI and, exactly as in C, never freed: the C
    `static` outlives every module and runtime and the embedder keeps
    reading `exit_code` after m3_FreeRuntime.
    Eden: the token of the context in m3_wasi_contexts, -1 = NULL.
*/
var private wasi_context : int = -1


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

    Ported in m3_api_wasi_fd.das: it maps host `errno` values, which the
    descriptor half produces; this half uses it for clock_time_get and
    random_get.
*/


// ============================================================================
// <time.h> and <errno.h> substitutes
//
// C calls POSIX clock_gettime/clock_getres and names the clocks with the
// CLOCK_* macros of <time.h>. Daslang binds neither, so the pieces are
// re-implemented here over the daslang builtins, keeping the C names, the C
// signatures and the C call shape so that convert_clockid, clock_res_get and
// clock_time_get port literally (see the header).
//
// The CLOCK_* values are the Linux <time.h> ones (0..3), which is also the
// order wasi_core.h happens to give the WASI clock ids; convert_clockid still
// spells out C's switch rather than relying on that coincidence.
// ============================================================================


let private CLOCK_REALTIME : i32 = 0
let private CLOCK_MONOTONIC : i32 = 1
let private CLOCK_PROCESS_CPUTIME_ID : i32 = 2
let private CLOCK_THREAD_CPUTIME_ID : i32 = 3


// Eden: C's `errno` (see the header)
var private errno : int = 0


// C: struct timespec { time_t tv_sec; long tv_nsec; }
struct public timespec {
    tv_sec : i64 = 0l
    tv_nsec : i64 = 0l
}


// Eden: the clock anchor (see the header); globals the editor carries over
// a hot reload
let private NSEC_PER_SEC : i64 = 1000000000l

var private wasi_clock_anchored : bool = false
var private wasi_clock_base_nsec : i64 = 0l
var private wasi_clock_base_ticks : i64 = 0l


// Eden: takes the anchor once (see the header)
def private anchor_wasi_clock() {
    if (!wasi_clock_anchored) {
        wasi_clock_base_nsec = int64(get_clock()) * NSEC_PER_SEC
        wasi_clock_base_ticks = ref_time_ticks()
        wasi_clock_anchored = true
    }
}


// C: int clock_gettime(int clk_id, struct timespec *spec)
// Eden: the substitute of the header; -1 and errno EINVAL for an unknown id,
// as Linux
def private clock_gettime(clk_id : i32; var spec : timespec&) : i32 {
    anchor_wasi_clock()

    let elapsed = get_time_nsec(wasi_clock_base_ticks)
    var nsec : i64 = 0l

    if (clk_id == CLOCK_REALTIME || clk_id == CLOCK_MONOTONIC) {
        nsec = wasi_clock_base_nsec + elapsed
    } elif (clk_id == CLOCK_PROCESS_CPUTIME_ID || clk_id == CLOCK_THREAD_CPUTIME_ID) {
        nsec = elapsed
    } else {
        errno = EINVAL
        return -1
    }

    spec.tv_sec = nsec / NSEC_PER_SEC
    spec.tv_nsec = nsec % NSEC_PER_SEC
    return 0
}


// C: int clock_getres(int clk_id, struct timespec *spec)
// Eden: always fails, as the C file's Windows shim (see the header)
def private clock_getres(clk_id : i32; var spec : timespec&) : i32 {
    return -1 // Defaults to 1000000
}


// C: static inline int convert_clockid(__wasi_clockid_t in)
// `in` is a daslang keyword; the parameter keeps the C name with the
// established leading-underscore spelling. C's switch is an if chain.
def private convert_clockid(_in : wasi_clockid_t) : i32 {
    if (_in == WASI_CLOCKID_MONOTONIC) { return CLOCK_MONOTONIC }
    if (_in == WASI_CLOCKID_PROCESS_CPUTIME_ID) { return CLOCK_PROCESS_CPUTIME_ID }
    if (_in == WASI_CLOCKID_REALTIME) { return CLOCK_REALTIME }
    if (_in == WASI_CLOCKID_THREAD_CPUTIME_ID) { return CLOCK_THREAD_CPUTIME_ID }
    return -1
}


// C: UINT64_MAX (<stdint.h>)
let private UINT64_MAX : u64 = 0xfffffffffffffffful


// C: static inline __wasi_timestamp_t convert_timespec(const struct timespec *ts)
def private convert_timespec(ts : timespec) : wasi_timestamp_t {
    if (ts.tv_sec < 0l) {
        return 0ul
    }
    if (u64(ts.tv_sec) >= UINT64_MAX / 1000000000ul) {
        return UINT64_MAX
    }
    return u64(ts.tv_sec) * 1000000000ul + u64(ts.tv_nsec)
}


/*
    C: static inline const void* copy_iov_to_host(...)

    Ported in m3_api_wasi_fd.das next to its only two callers, fd_read and
    fd_write.
*/


// ============================================================================
// WASI API implementation
// ============================================================================


def public m3_wasi_generic_args_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    let argv = m3ApiGetArgMem(rt, f)                         // m3ApiGetArgMem (uint32_t *, argv)
    var argv_buf = m3ApiGetArgMem(rt, f)                     // m3ApiGetArgMem (char *, argv_buf)

    let context = ctx.userdata                               // C: (m3_wasi_context_t*)(_ctx->userdata); Eden: the token

    if (!m3_IsWasiContext(context)) {                        // C: context == NULL
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    let argc = m3_wasi_contexts[context].argc
    var check = m3ApiCheckMem(rt, argv, u64(argc) * 4ul)    // C: context->argc * sizeof(uint32_t)
    if (check != m3Err_none) { return check }

    for (i in urange(argc)) {
        // C: m3ApiWriteMem32(&argv[i], m3ApiPtrToOffset(argv_buf));
        m3ApiWriteMem32(rt, argv + int(i) * 4, m3ApiPtrToOffset(argv_buf))

        let arg = m3_wasi_contexts[context].argv[int(i)]
        let len = length(arg)                                // C: size_t len = strlen (context->argv[i]);

        check = m3ApiCheckMem(rt, argv_buf, u64(len))
        if (check != m3Err_none) { return check }
        m3ApiWriteString(rt, argv_buf, arg)                  // C: memcpy (argv_buf, context->argv[i], len);
        argv_buf += len
        m3ApiWriteMem8(rt, argv_buf, 0u8)                    // C: * argv_buf++ = 0;
        argv_buf += 1
    }

    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_args_sizes_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    let argc = m3ApiGetArgMem(rt, f)                         // m3ApiGetArgMem (__wasi_size_t *, argc)
    let argv_buf_size = m3ApiGetArgMem(rt, f)                // m3ApiGetArgMem (__wasi_size_t *, argv_buf_size)

    var check = m3ApiCheckMem(rt, argc, 4ul)                 // sizeof(__wasi_size_t)
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, argv_buf_size, 4ul)
    if (check != m3Err_none) { return check }

    let context = ctx.userdata                               // C: (m3_wasi_context_t*)(_ctx->userdata); Eden: the token

    if (!m3_IsWasiContext(context)) {                        // C: context == NULL
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var buf_len : wasi_size_t = 0u
    for (i in urange(m3_wasi_contexts[context].argc)) {
        buf_len += u32(length(m3_wasi_contexts[context].argv[int(i)])) + 1u   // C: strlen (context->argv[i]) + 1
    }

    m3ApiWriteMem32(rt, argc, m3_wasi_contexts[context].argc)
    m3ApiWriteMem32(rt, argv_buf_size, buf_len)

    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// The C body is a bare `// TODO` followed by the success return; the two
// memory arguments are consumed and never used, which is why nothing is
// written into the guest buffers.
def public m3_wasi_generic_environ_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    m3ApiGetArgMem(rt, f)                                    // m3ApiGetArgMem (uint32_t *, env)
    m3ApiGetArgMem(rt, f)                                    // m3ApiGetArgMem (char *, env_buf)

    // TODO
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_environ_sizes_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    let env_count = m3ApiGetArgMem(rt, f)                    // m3ApiGetArgMem (__wasi_size_t *, env_count)
    let env_buf_size = m3ApiGetArgMem(rt, f)                 // m3ApiGetArgMem (__wasi_size_t *, env_buf_size)

    var check = m3ApiCheckMem(rt, env_count, 4ul)            // sizeof(__wasi_size_t)
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, env_buf_size, 4ul)
    if (check != m3Err_none) { return check }

    // TODO
    m3ApiWriteMem32(rt, env_count, 0u)
    m3ApiWriteMem32(rt, env_buf_size, 0u)

    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
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


// Eden: the generator state of getrandom, seeded once (see the header)
var private wasi_random_seeded : bool = false
var private wasi_random_state : int4 = int4(0)


// C: ssize_t getrandom(void *buf, size_t buflen, unsigned int flags) (<sys/random.h>)
// Eden: the substitute of the header, over rt.mem[buf .. buf + buflen) (the
// caller checked the range): daslib/random, not a CSPRNG; never short
def private getrandom(var rt : M3Runtime; buf : int; buflen : u32; flags : u32) : i64 {
    if (!wasi_random_seeded) {
        wasi_random_state = random_seed(int(ref_time_ticks()))
        wasi_random_seeded = true
    }
    for (i in range(int(buflen))) {
        let r = random_int(wasi_random_state)
        m3ApiWriteMem8(rt, buf + i, u8(uint(r) & 0xffu))
    }
    return i64(buflen)
}


def public m3_wasi_generic_random_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    var buf = m3ApiGetArgMem(rt, f)                          // m3ApiGetArgMem (uint8_t *, buf)
    var buf_len = m3ApiGetArg_u32(rt, f)                     // m3ApiGetArg (__wasi_size_t, buf_len)

    let check = m3ApiCheckMem(rt, buf, u64(buf_len))
    if (check != m3Err_none) { return check }

    while (true) {
        var retlen : i64 = 0l                                // C: ssize_t retlen = 0;

        // C: #elif defined(__FreeBSD__) || defined(__linux__)
        retlen = getrandom(rt, buf, buf_len, 0u)

        if (retlen < 0l) {
            if (errno == EINTR || errno == EAGAIN) {
                continue
            }
            m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(errno)))
            return m3Err_none
        } elif (retlen == i64(buf_len)) {
            m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
            return m3Err_none
        } else {
            buf += int(retlen)
            buf_len -= u32(retlen)
        }
    }
    return m3Err_none                                        // Eden: unreachable (C's loop has no exit); daslang needs a return
}


def public m3_wasi_generic_clock_res_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    let wasi_clk_id = m3ApiGetArg_u32(rt, f)                 // m3ApiGetArg (__wasi_clockid_t, wasi_clk_id)
    let resolution = m3ApiGetArgMem(rt, f)                   // m3ApiGetArgMem (__wasi_timestamp_t *, resolution)

    let check = m3ApiCheckMem(rt, resolution, 8ul)           // sizeof(__wasi_timestamp_t)
    if (check != m3Err_none) { return check }

    let clk = convert_clockid(wasi_clk_id)
    if (clk < 0) {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var tp = timespec()
    if (clock_getres(clk, tp) != 0) {
        m3ApiWriteMem64(rt, resolution, 1000000ul)
    } else {
        m3ApiWriteMem64(rt, resolution, convert_timespec(tp))
    }

    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_clock_time_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                      // m3ApiReturnType (uint32_t)
    let wasi_clk_id = m3ApiGetArg_u32(rt, f)                 // m3ApiGetArg (__wasi_clockid_t, wasi_clk_id)
    m3ApiGetArg_u64(rt, f)                                   // m3ApiGetArg (__wasi_timestamp_t, precision)
    let _time = m3ApiGetArgMem(rt, f)                        // m3ApiGetArgMem (__wasi_timestamp_t *, time); C name `time`

    let check = m3ApiCheckMem(rt, _time, 8ul)                // sizeof(__wasi_timestamp_t)
    if (check != m3Err_none) { return check }

    let clk = convert_clockid(wasi_clk_id)
    if (clk < 0) {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    var tp = timespec()
    if (clock_gettime(clk, tp) != 0) {
        m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(errno)))
        return m3Err_none
    }

    m3ApiWriteMem64(rt, _time, convert_timespec(tp))
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// No m3ApiReturnType: the C signature is "v(i)", so the first cell is the
// argument, not a return value.
def public m3_wasi_generic_proc_exit(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let code = m3ApiGetArg_u32(rt, f)                        // m3ApiGetArg (uint32_t, code)

    let context = ctx.userdata                               // C: (m3_wasi_context_t*)(_ctx->userdata); Eden: the token

    if (m3_IsWasiContext(context)) {                         // C: if (context)
        m3_wasi_contexts[context].exit_code = i32(code)
    }

    return m3ApiTrap(m3Err_trapExit)
}


// ============================================================================
// Linking
// ============================================================================


def private SuppressLookupFailure(i_result : M3Result) : M3Result {
    if (i_result == m3Err_functionLookupFailed) {
        return m3Err_none
    } else {
        return i_result
    }
}


// C: m3_wasi_context_t* m3_GetWasiContext()
// Eden: the token of the context in m3_wasi_contexts, -1 before the first
// m3_LinkWASI (C: NULL)
def public m3_GetWasiContext() : int {
    return wasi_context
}


// C parameter `module` renamed to `_module`: `module` is a daslang keyword.
// Eden: the runtime first (see the header)
def public m3_LinkWASI(var rt : M3Runtime; _module : IM3Module) : M3Result {
    // Eden: the context is created before the preopen loop, which opens its
    // descriptors in it (see the header); C: `if (!wasi_context)` after the loop
    if (!m3_IsWasiContext(wasi_context)) {
        wasi_context = m3_NewWasiContext()                   // C: malloc; exit_code = 0; argc = 0; argv = 0
    }

    /*
        C _WIN32 branch sets the three standard handles to O_BINARY; the port
        targets the POSIX branch:

            // Preopen dirs
            for (int i = 3; i < PREOPEN_CNT; i++) {
                preopen[i].fd = open(preopen[i].real_path, O_RDONLY);
            }

        The table and the host `open` live in the descriptor module, so the
        loop is reached through wasi_fd_open_preopens. Descriptors 3 and 4
        therefore get their numbers here, at link time, exactly as in C.
    */
    wasi_fd_open_preopens(rt, wasi_context)

    let namespaces = fixed_array("wasi_unstable", "wasi_snapshot_preview1")

    // Some functions are incompatible between WASI versions
    //
    // C declares `M3Result result = m3Err_none;` at the top of the function;
    // the initialiser is dead there too, because the first `_ (...)`
    // overwrites it before any read, so the first link becomes the
    // declaration here, as in m3_api_libc.das.
    // Eden: every link passes the context token (see the header)
    var result : M3Result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, "wasi_unstable", "fd_seek", "i(iIi*)", @@m3_wasi_unstable_fd_seek, wasi_context))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, "wasi_snapshot_preview1", "fd_seek", "i(iIi*)", @@m3_wasi_snapshot_preview1_fd_seek, wasi_context))
    if (result != m3Err_none) { return result }
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_unstable",          "fd_filestat_get",   "i(i*)",     &m3_wasi_unstable_fd_filestat_get)));
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_snapshot_preview1", "fd_filestat_get",   "i(i*)",     &m3_wasi_snapshot_preview1_fd_filestat_get)));
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_unstable",          "path_filestat_get", "i(ii*i*)",  &m3_wasi_unstable_path_filestat_get)));
    //_ (SuppressLookupFailure (m3_LinkRawFunction (module, "wasi_snapshot_preview1", "path_filestat_get", "i(ii*i*)",  &m3_wasi_snapshot_preview1_path_filestat_get)));

    for (wasi in namespaces) {
        let ctx = wasi_context

        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "args_get", "i(**)", @@m3_wasi_generic_args_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "args_sizes_get", "i(**)", @@m3_wasi_generic_args_sizes_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "clock_res_get", "i(i*)", @@m3_wasi_generic_clock_res_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "clock_time_get", "i(iI*)", @@m3_wasi_generic_clock_time_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "environ_get", "i(**)", @@m3_wasi_generic_environ_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "environ_sizes_get", "i(**)", @@m3_wasi_generic_environ_sizes_get, ctx))
        if (result != m3Err_none) { return result }

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_advise",            "i(iIIi)", )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_allocate",          "i(iII)",  )));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_close", "i(i)", @@m3_wasi_generic_fd_close, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_datasync", "i(i)", @@m3_wasi_generic_fd_datasync, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_fdstat_get", "i(i*)", @@m3_wasi_generic_fd_fdstat_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_fdstat_set_flags", "i(ii)", @@m3_wasi_generic_fd_fdstat_set_flags, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_fdstat_set_rights", "i(iII)",  )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_filestat_set_size", "i(iI)",   )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_filestat_set_times","i(iIIi)", )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_pread",             "i(i*iI*)",)));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_prestat_get", "i(i*)", @@m3_wasi_generic_fd_prestat_get, ctx))
        if (result != m3Err_none) { return result }
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_prestat_dir_name", "i(i*i)", @@m3_wasi_generic_fd_prestat_dir_name, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_pwrite",            "i(i*iI*)",)));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_read", "i(i*i*)", @@m3_wasi_generic_fd_read, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_readdir",           "i(i*iI*)",)));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_renumber",          "i(ii)",   )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_sync",              "i(i)",    )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "fd_tell",              "i(i*)",   )));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "fd_write", "i(i*i*)", @@m3_wasi_generic_fd_write, ctx))
        if (result != m3Err_none) { return result }

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_create_directory",    "i(i*i)",       )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_filestat_set_times",  "i(ii*iIIi)",   )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_link",                "i(ii*ii*i)",   )));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "path_open", "i(ii*iiIIi*)", @@m3_wasi_generic_path_open, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_readlink",            "i(i*i*i*)",    )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_remove_directory",    "i(i*i)",       )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_rename",              "i(i*ii*i)",    )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_symlink",             "i(*ii*i)",     )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "path_unlink_file",         "i(i*i)",       )));

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "poll_oneoff",          "i(**i*)", &m3_wasi_generic_poll_oneoff)));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "proc_exit", "v(i)", @@m3_wasi_generic_proc_exit, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "proc_raise",           "i(i)",    )));
        result = SuppressLookupFailure(m3_LinkRawFunctionEx(rt, _module, wasi, "random_get", "i(*i)", @@m3_wasi_generic_random_get, ctx))
        if (result != m3Err_none) { return result }
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sched_yield",          "i()",     )));

        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sock_recv",            "i(i*ii**)",        )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sock_send",            "i(i*ii*)",         )));
        //_     (SuppressLookupFailure (m3_LinkRawFunction (module, wasi, "sock_shutdown",        "i(ii)",            )));
    }

    return result                                            // C: _catch: return result;
}
