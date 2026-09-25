options gen2
options indenting = 4

module test_m3_api_wasi shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_api_wasi
require modules/wasm3das/source/m3_api_wasi_fd
require modules/wasm3das/source/m3_bind
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core
require strings
require daslib/strings_boost

/*
    test_m3_api_wasi.das: the Eden tests of source/m3_api_wasi.das (the core
    half of m3_api_wasi.c: args, environ, clocks, random, proc_exit,
    m3_LinkWASI), ported from .upstream/tests/integration/test_m3_api_wasi.das.

    Two fixtures, as upstream:

    1. A hand-assembled module whose only section is a one-page memory,
       parsed and loaded into a runtime, so the raw functions see a real
       64 KiB rt.mem and m3ApiCheckMem a real memory size. The raw functions
       are then called as op_CallRawFunction calls them: the result cell at
       BASE of rt.stack and the arguments in the cells after it (two slot
       words per cell, DESIGN 4.5), and an M3ImportContext whose userdata is
       the WASI context token m3_LinkWASI created (m3_GetWasiContext).
       Upstream: a `_sp` slot array and a pointer context; C's NULL context
       is the token -1.

    2. wasm3c/test/wasi/simple/test.wasm (through the FixtureSource), the
       module the C WASI driver (wasm3c/test/run-wasi-test.py) runs first.
       It imports 13 wasi_snapshot_preview1 functions, all of them in C
       m3_LinkWASI's list, so a correct m3_LinkWASI must leave none of them
       unresolved.

    Changed assertions: none. The context is a token instead of a pointer
    (test_link_wasi_allocates_the_context_once compares tokens), and
    test_clock_res_get keeps upstream's 1 ms default (the port's
    clock_getres fails, as upstream's; see the source header).

    Eden tests (no upstream counterpart):
      - test_wasi_simple_end_to_end: the milestone. test.wasm is parsed,
        loaded and linked with m3_LinkWASI; argv is what
        platforms/app/main.c passes for the driver's "Simple WASI test"
        (`wasm3 ./wasi/simple/test.wasm cat ./wasi/simple/0.txt`, argv[0]
        stripped to the module name: "test.wasm", "cat",
        "./wasi/simple/0.txt"); _start runs through m3_CallArgv with no
        arguments, as repl_call does. rt.stdoutBuffer must match the
        driver's expect_pattern (strings_boost glob_match; `*` is its only wildcard) and, byte for
        byte, every line that does not depend on the clock or the random
        source; those lines are checked for their shape (the "Now:" second
        is a wall clock, "x + y = z" adds up, fib(20) = 6765 [.. ms]).
        0.txt is served by a one-file test backend over the fixture's
        bytes (the default backend has no files); the default backend is
        restored afterwards. The run ends with C's exit protocol: either
        m3Err_trapExit with exit_code 0 or a plain return.
      - test_clock_monotonic: every WASI clock id reads without going
        backwards over repeated reads, REALTIME is nanoseconds past 2020,
        MONOTONIC counts from the anchor plus a 1 s base, the CPU-time clocks are small, id 4 (past
        the WASI ids) is INVAL, clock_res_get is the 1 ms default for all
        four ids.
      - test_random_get_fills: a 0-byte request succeeds and writes
        nothing, a 4 KiB request writes every byte with many distinct
        values, two requests differ.
      - test_args_layout: argc 0 (sizes 0/0, args_get writes nothing), an
        empty argument and a non-ASCII (UTF-8) one: the offsets and the
        NUL-terminated bytes in linear memory, args_get's out-of-bounds
        traps (the offset array, the string buffer).
      - test_proc_exit_linked: proc_exit imported by a hand-built module,
        once from wasi_snapshot_preview1 and once from wasi_unstable,
        linked by m3_LinkWASI and called through m3_Call: m3_Call returns
        m3Err_trapExit and the context's exit_code is the argument (a
        negative code as the i32 C stores).
*/


let private BASE = 16            // the result cell of every direct call, in rt.stack
let private PAGE_SIZE = 65536u
let private TEST_WASM = "wasi/simple/test.wasm"
let private SIMPLE_TXT = "wasi/simple/0.txt"


// ============================================================================
// Fixtures
// ============================================================================


/*
    (module (memory 1))

    Sections in the order m3_ParseModule enforces: 5 memory only.
    Section 5, size 3: one memory, limits flag 0 (min only), min 1 page.
*/
def private memory_wasm() : array<u8> {
    return <- [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
               0x05u8, 0x03u8, 0x01u8, 0x00u8, 0x01u8]
}


def private new_runtime(stackBytes : u32) : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, stackBytes, -1)
    return <- rt
}


// parses and loads `bytes`; the module handle, or -1
def private load_module(var t : TestRun; var rt : M3Runtime; bytes : array<u8>; what : string) : IM3Module {
    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "{what} parses")
    if (parsed._0 != m3Err_none) {
        return -1
    }
    let loaded = m3_LoadModule(rt, parsed._1)
    is_ok(t, loaded, "{what} loads")
    if (loaded != m3Err_none) {
        return -1
    }
    return parsed._1
}


// Builds the memory fixture and makes sure the WASI context exists, since
// only m3_LinkWASI creates it (as in C). The WASI token, or -1.
def private new_wasi_fixture(var t : TestRun; var rt : M3Runtime) : int {
    let bytes <- memory_wasm()
    let m = load_module(t, rt, bytes, "the memory fixture")
    if (m == -1) {
        return -1
    }
    is_ok(t, m3_LinkWASI(rt, m), "m3_LinkWASI")
    equal(t, m3_GetMemorySize(rt), PAGE_SIZE, "one page of linear memory")
    return m3_GetWasiContext()
}


// ============================================================================
// Raw-call drivers and linear-memory helpers
// ============================================================================


// calls `fn` with the result cell at BASE and `args` in the cells after it
def private call_raw(var rt : M3Runtime; fn : M3RawCall; token : int; args : array<u64>) : M3Result {
    set_stack_u64(rt, BASE, 0xdeaddeaddeaddeadul)
    for (a, k in args, count()) {
        set_stack_u64(rt, BASE + 2 * (1 + k), a)
    }
    return invoke(fn, rt, M3ImportContext(userdata = token), BASE)
}


// calls a void `fn` ("v(...)"): the arguments start at BASE
def private call_raw_void(var rt : M3Runtime; fn : M3RawCall; token : int; args : array<u64>) : M3Result {
    for (a, k in args, count()) {
        set_stack_u64(rt, BASE + 2 * k, a)
    }
    return invoke(fn, rt, M3ImportContext(userdata = token), BASE)
}


// the WASI errno C's m3ApiReturn stored
def private ret_errno(rt : M3Runtime) : u32 {
    return stack_u32(rt, BASE)
}


def private mem_u8(rt : M3Runtime; off : u32) : u8 {
    return m3ApiReadMem8(rt, int(off))
}


def private mem_set_u8(var rt : M3Runtime; off : u32; value : u8) {
    m3ApiWriteMem8(rt, int(off), value)
}


def private mem_u32(rt : M3Runtime; off : u32) : u32 {
    return m3ApiReadMem32(rt, int(off))
}


def private mem_u64(rt : M3Runtime; off : u32) : u64 {
    return m3ApiReadMem64(rt, int(off))
}


// sets the context's argv (C: wasi_ctx->argc = argc; wasi_ctx->argv = argv)
def private set_args(token : int; var args : array<string>) {
    m3_wasi_contexts[token].argc = u32(length(args))
    m3_wasi_contexts[token].argv <- args
}


def private clear_args(token : int) {
    if (m3_IsWasiContext(token)) {
        m3_wasi_contexts[token].argc = 0u
        clear(m3_wasi_contexts[token].argv)
    }
}


// ============================================================================
// m3_LinkWASI over the real WASI test module
// ============================================================================


def private import_compiled(rt : M3Runtime; m : IM3Module; field : string) : bool {
    for (i in range(int(rt.modules[m].numFuncImports))) {
        let fi = rt.modules[m].functions[i]
        if (rt.functions[fi].import.fieldUtf8 == field) {
            return rt.functions[fi].compiled != -1
        }
    }
    return false
}


// C m3_LinkWASI links both wasi_unstable and wasi_snapshot_preview1 and wraps
// every lookup in SuppressLookupFailure, so a module importing only a subset
// still links cleanly and every name it does import must end up bound.
def test_link_wasi_resolves_every_test_wasm_import(var t : TestRun; fx : FixtureSource) {
    let bytes <- load_fixture(fx, TEST_WASM)
    check(t, !empty(bytes), "wasi/simple/test.wasm is readable")
    if (empty(bytes)) {
        return
    }

    var rt <- new_runtime(64u * 1024u)
    let m = load_module(t, rt, bytes, "test.wasm")
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    equal(t, rt.modules[m].numFuncImports, 13u, "test.wasm has 13 function imports")
    is_ok(t, m3_LinkWASI(rt, m), "m3_LinkWASI")

    // The 13 imports of wasi/simple/test.wasm, in the order of its import
    // section. Every one is linked by C m3_LinkWASI.
    let names <- ["proc_exit", "clock_time_get", "fd_read", "fd_close",
                  "fd_prestat_get", "fd_prestat_dir_name", "fd_fdstat_get", "path_open",
                  "args_sizes_get", "args_get", "random_get", "fd_seek", "fd_write"]
    for (name in names) {
        check(t, import_compiled(rt, m, name), "wasi_snapshot_preview1.{name} is linked")
    }

    m3_FreeRuntime(rt)
}


// C: m3_LinkWASI allocates the static context on its first call and never
// frees it, so every later call returns the same pointer.
// Eden: the same token
def test_link_wasi_allocates_the_context_once(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let bytes <- memory_wasm()
    let m = load_module(t, rt, bytes, "the memory fixture")
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    is_ok(t, m3_LinkWASI(rt, m), "m3_LinkWASI on a module with no imports")

    let ctx = m3_GetWasiContext()
    check(t, ctx != -1 && m3_IsWasiContext(ctx), "m3_GetWasiContext after m3_LinkWASI")

    is_ok(t, m3_LinkWASI(rt, m), "m3_LinkWASI again")
    equal(t, m3_GetWasiContext(), ctx, "the context token is stable")

    m3_FreeRuntime(rt)
}


// ============================================================================
// The raw functions, called directly on a one-page linear memory
// ============================================================================


def test_args_sizes_get_and_args_get(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    var args <- ["cat", "./wasi/simple/0.txt"]
    set_args(ctx, args)
    equal(t, length(m3_wasi_contexts[ctx].argv[0]), 3, "argv[0] length")
    equal(t, length(m3_wasi_contexts[ctx].argv[1]), 19, "argv[1] length")

    // args_sizes_get: i(**) - two out pointers, at guest offsets 16 and 32.
    var result = call_raw(rt, @@m3_wasi_generic_args_sizes_get, ctx, [16ul, 32ul])
    is_ok(t, result, "args_sizes_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "args_sizes_get -> ERRNO_SUCCESS")
    equal(t, mem_u32(rt, 16u), 2u, "args_sizes_get writes argc")
    // C: buf_len += strlen(argv[i]) + 1 for every argument.
    equal(t, mem_u32(rt, 32u), 24u, "args_sizes_get writes argv_buf_size (3+1 + 19+1)")

    // args_get: i(**) - the offset array at 100, the string buffer at 200.
    result = call_raw(rt, @@m3_wasi_generic_args_get, ctx, [100ul, 200ul])
    is_ok(t, result, "args_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "args_get -> ERRNO_SUCCESS")

    equal(t, mem_u32(rt, 100u), 200u, "argv[0] points at the buffer start")
    equal(t, mem_u32(rt, 104u), 204u, "argv[1] points past \"cat\\0\"")

    equal(t, mem_u8(rt, 200u), 0x63u8, "argv_buf 'c'")
    equal(t, mem_u8(rt, 201u), 0x61u8, "argv_buf 'a'")
    equal(t, mem_u8(rt, 202u), 0x74u8, "argv_buf 't'")
    equal(t, mem_u8(rt, 203u), 0u8, "argv_buf NUL after argv[0]")
    equal(t, mem_u8(rt, 204u), 0x2eu8, "argv_buf '.'")
    equal(t, mem_u8(rt, 205u), 0x2fu8, "argv_buf '/'")
    equal(t, mem_u8(rt, 222u), 0x74u8, "argv_buf last character of argv[1]")
    equal(t, mem_u8(rt, 223u), 0u8, "argv_buf NUL after argv[1]")

    // C: `if (context == NULL) { m3ApiReturn(__WASI_ERRNO_INVAL); }`.
    result = call_raw(rt, @@m3_wasi_generic_args_sizes_get, -1, [16ul, 32ul])
    is_ok(t, result, "args_sizes_get without a context returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_INVAL), "args_sizes_get without a context -> ERRNO_INVAL")

    // C m3ApiCheckMem traps instead of returning an errno when the guest
    // pointer leaves linear memory.
    result = call_raw(rt, @@m3_wasi_generic_args_sizes_get, ctx, [u64(m3_GetMemorySize(rt)), 32ul])
    is_err(t, result, m3Err_trapOutOfBoundsMemoryAccess, "args_sizes_get traps past the end of memory")

    clear_args(ctx)
    m3_FreeRuntime(rt)
}


// C leaves both environ functions as `// TODO`: environ_get writes nothing
// and environ_sizes_get reports zero variables and a zero-length buffer.
def test_environ_get_and_environ_sizes_get(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    mem_set_u8(rt, 48u, 0xaau8)
    mem_set_u8(rt, 64u, 0xaau8)

    var result = call_raw(rt, @@m3_wasi_generic_environ_sizes_get, ctx, [48ul, 64ul])
    is_ok(t, result, "environ_sizes_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "environ_sizes_get -> ERRNO_SUCCESS")
    equal(t, mem_u32(rt, 48u), 0u, "environ_sizes_get writes 0 variables")
    equal(t, mem_u32(rt, 64u), 0u, "environ_sizes_get writes a 0-byte buffer size")

    // environ_get consumes its two memory arguments and writes nothing.
    mem_set_u8(rt, 300u, 0xaau8)
    result = call_raw(rt, @@m3_wasi_generic_environ_get, ctx, [300ul, 400ul])
    is_ok(t, result, "environ_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "environ_get -> ERRNO_SUCCESS")
    equal(t, mem_u8(rt, 300u), 0xaau8, "environ_get writes nothing (C TODO)")

    m3_FreeRuntime(rt)
}


def test_clock_time_get(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    // clock_time_get: i(iI*) - clock id, precision, out pointer.
    var result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [u64(WASI_CLOCKID_REALTIME), 0ul, 512ul])
    is_ok(t, result, "clock_time_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "clock_time_get(REALTIME) -> ERRNO_SUCCESS")

    let first = mem_u64(rt, 512u)
    // A realtime clock in nanoseconds since the epoch: seconds must be past
    // 2020-09-13 (1600000000), which is what distinguishes it from the
    // monotonic clock.
    check(t, first / 1000000000ul > 1600000000ul, "REALTIME is a wall clock in nanoseconds")

    result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [u64(WASI_CLOCKID_REALTIME), 0ul, 520ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "clock_time_get(REALTIME) again")
    check(t, mem_u64(rt, 520u) >= first, "REALTIME does not go backwards")

    result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [u64(WASI_CLOCKID_MONOTONIC), 0ul, 528ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "clock_time_get(MONOTONIC) -> ERRNO_SUCCESS")
    check(t, mem_u64(rt, 528u) > 0ul, "MONOTONIC is non-zero")

    // C: `int clk = convert_clockid(...); if (clk < 0) m3ApiReturn(INVAL);`
    mem_set_u8(rt, 536u, 0xaau8)
    result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [99ul, 0ul, 536ul])
    is_ok(t, result, "clock_time_get with an unknown clock returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_INVAL), "clock_time_get(99) -> ERRNO_INVAL")
    equal(t, mem_u8(rt, 536u), 0xaau8, "clock_time_get(99) writes nothing")

    m3_FreeRuntime(rt)
}


// C: when clock_getres fails the resolution defaults to 1000000 ns. The
// port's clock_getres always reports failure (daslang has no resolution
// query), so every clock reports the 1 ms default.
def test_clock_res_get(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    var result = call_raw(rt, @@m3_wasi_generic_clock_res_get, ctx, [u64(WASI_CLOCKID_REALTIME), 512ul])
    is_ok(t, result, "clock_res_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "clock_res_get -> ERRNO_SUCCESS")
    equal(t, mem_u64(rt, 512u), 1000000ul, "clock_res_get -> the 1 ms default")

    result = call_raw(rt, @@m3_wasi_generic_clock_res_get, ctx, [99ul, 512ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_INVAL), "clock_res_get(99) -> ERRNO_INVAL")

    m3_FreeRuntime(rt)
}


def test_random_get(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    // Fill the target range and one byte on each side with a marker, so the
    // test sees both that the buffer was written and that nothing outside it
    // was.
    for (off in urange(399u, 465u)) {
        mem_set_u8(rt, off, 0xaau8)
    }

    // random_get: i(*i) - buffer pointer, length.
    var result = call_raw(rt, @@m3_wasi_generic_random_get, ctx, [400ul, 64ul])
    is_ok(t, result, "random_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "random_get -> ERRNO_SUCCESS")

    var changed = 0
    for (off in urange(400u, 464u)) {
        if (mem_u8(rt, off) != 0xaau8) {
            changed++
        }
    }
    // 64 bytes that all happen to equal the marker has probability 256^-64.
    check(t, changed > 0, "random_get fills the buffer")
    equal(t, mem_u8(rt, 399u), 0xaau8, "random_get does not write before the buffer")
    equal(t, mem_u8(rt, 464u), 0xaau8, "random_get does not write past the buffer")

    // C m3ApiCheckMem(buf, buf_len) traps when the range leaves memory.
    result = call_raw(rt, @@m3_wasi_generic_random_get, ctx, [u64(m3_GetMemorySize(rt) - 4u), 64ul])
    is_err(t, result, m3Err_trapOutOfBoundsMemoryAccess, "random_get traps past the end of memory")

    m3_FreeRuntime(rt)
}


// C: proc_exit stores the code in the context and traps with m3Err_trapExit;
// it has no return slot, its signature being "v(i)".
def test_proc_exit(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    m3_wasi_contexts[ctx].exit_code = 0

    let result = call_raw_void(rt, @@m3_wasi_generic_proc_exit, ctx, [42ul])
    is_err(t, result, m3Err_trapExit, "proc_exit traps with m3Err_trapExit")
    equal(t, m3_wasi_contexts[ctx].exit_code, 42, "proc_exit stores the code in the context")

    // C tolerates a missing context: `if (context) { context->exit_code = code; }`.
    let result2 = call_raw_void(rt, @@m3_wasi_generic_proc_exit, -1, [7ul])
    is_err(t, result2, m3Err_trapExit, "proc_exit without a context still traps")
    equal(t, m3_wasi_contexts[ctx].exit_code, 42, "proc_exit without a context leaves the context alone")

    m3_wasi_contexts[ctx].exit_code = 0
    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden tests
// ============================================================================


// A one-file backend for the end-to-end run: "wasi/simple/0.txt" (under
// either preopen, with or without a leading "./" or "/") opens read-only on
// SIMPLE_HANDLE over the fixture's bytes; everything else is the default
// backend (the standard streams and the "." preopens).
let private SIMPLE_HANDLE = 100000

var private g_simple_body : array<u8>
var private g_simple_pos : int = -1   // -1 = closed


def private simple_rel(path : string) : string {
    var p = path
    while (true) {
        if (starts_with(p, "./")) {
            p = slice(p, 2)
        } elif (starts_with(p, "/")) {
            p = slice(p, 1)
        } else {
            break
        }
    }
    return p
}


def private simple_open(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int {
    if (simple_rel(path) == SIMPLE_TXT) {
        if ((flags & O_ACCMODE) != O_RDONLY || (flags & O_CREAT) != 0) {
            return -EACCES
        }
        if (g_simple_pos != -1) {
            return -EMFILE   // one open at a time is all the test needs
        }
        g_simple_pos = 0
        return SIMPLE_HANDLE
    }
    return wasi_default_open(rt, dirHandle, path, flags, mode)
}


def private simple_readv(var rt : M3Runtime; handle : int; var bufs : array<array<u8>>) : int {
    if (handle != SIMPLE_HANDLE) {
        return wasi_default_readv(rt, handle, bufs)
    }
    if (g_simple_pos == -1) {
        return -EBADF
    }
    var n = 0
    for (b in bufs) {
        for (i in range(length(b))) {
            if (g_simple_pos >= length(g_simple_body)) {
                return n
            }
            b[i] = g_simple_body[g_simple_pos]
            g_simple_pos++
            n++
        }
    }
    return n
}


def private simple_lseek(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
    if (handle != SIMPLE_HANDLE) {
        return wasi_default_lseek(rt, handle, offset, whence)
    }
    var origin = 0l
    if (whence == SEEK_CUR) {
        origin = i64(g_simple_pos)
    } elif (whence == SEEK_END) {
        origin = i64(length(g_simple_body))
    } elif (whence != SEEK_SET) {
        return i64(-EINVAL)
    }
    let target = origin + offset
    if (target < 0l) {
        return i64(-EINVAL)
    }
    g_simple_pos = int(target)
    return target
}


def private simple_backend() : M3WasiFsBackend {
    var b = M3WasiFsBackend()
    b.open <- @(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int {
        return simple_open(rt, dirHandle, path, flags, mode)
    }
    b.readv <- @(var rt : M3Runtime; handle : int; var bufs : array<array<u8>>) : int {
        return simple_readv(rt, handle, bufs)
    }
    b.writev <- @(var rt : M3Runtime; handle : int; bufs : array<array<u8>>) : int {
        if (handle == SIMPLE_HANDLE) {
            return -EBADF
        }
        return wasi_default_writev(rt, handle, bufs)
    }
    b.lseek <- @(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
        return simple_lseek(rt, handle, offset, whence)
    }
    b.close <- @(var rt : M3Runtime; handle : int) : int {
        if (handle == SIMPLE_HANDLE) {
            g_simple_pos = -1
            return 0
        }
        return wasi_default_close(rt, handle)
    }
    b.fdatasync <- @(var rt : M3Runtime; handle : int) : int {
        if (handle == SIMPLE_HANDLE) {
            return 0
        }
        return wasi_default_fdatasync(rt, handle)
    }
    b.fcntl_getfl <- @(var rt : M3Runtime; handle : int) : int {
        if (handle == SIMPLE_HANDLE) {
            return O_RDONLY
        }
        return wasi_default_fcntl_getfl(rt, handle)
    }
    b.fstat_mode <- @(var rt : M3Runtime; handle : int) : int {
        if (handle == SIMPLE_HANDLE) {
            return S_IFREG
        }
        return wasi_default_fstat_mode(rt, handle)
    }
    return <- b
}


def private is_decimal(s : string) : bool {
    if (empty(s)) {
        return false
    }
    for (i in range(length(s))) {
        let c = character_at(s, i)
        if (c < '0' || c > '9') {
            return false
        }
    }
    return true
}


def test_wasi_simple_end_to_end(var t : TestRun; fx : FixtureSource) {
    let bytes <- load_fixture(fx, TEST_WASM)
    check(t, !empty(bytes), "wasi/simple/test.wasm is readable")
    var body <- load_fixture(fx, SIMPLE_TXT)
    check(t, !empty(body), "wasi/simple/0.txt is readable")
    if (empty(bytes) || empty(body)) {
        return
    }

    var rt <- new_runtime(64u * 1024u)
    let m = load_module(t, rt, bytes, "test.wasm")
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LinkWASI(rt, m), "m3_LinkWASI")
    let ctx = m3_GetWasiContext()
    if (!m3_IsWasiContext(ctx)) {
        m3_FreeRuntime(rt)
        return
    }

    // the one-file backend (the preopens m3_LinkWASI opened are default
    // directory handles, which it passes on)
    g_simple_body <- body
    g_simple_pos = -1
    var backend <- simple_backend()
    m3_SetWasiFsBackend(ctx, backend)

    // platforms/app/main.c: argv[0] is the module file name
    // (modname_from_fn), then the driver's args
    var args <- ["test.wasm", "cat", "./wasi/simple/0.txt"]
    set_args(ctx, args)
    m3_wasi_contexts[ctx].exit_code = -1

    var start : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, start, "_start"), "m3_FindFunction _start")
    if (start != -1) {
        var noArgs : array<string>
        let result = m3_CallArgv(rt, start, noArgs)   // C repl_call: m3_CallArgv(func, 0, NULL)
        check(t, result == m3Err_none || result == m3Err_trapExit, "_start returns or exits (result \"{result}\")")
        if (result == m3Err_trapExit) {
            equal(t, m3_wasi_contexts[ctx].exit_code, 0, "proc_exit(0): the exit code the driver sees")
        }
    }

    let text = string(rt.stdoutBuffer)
    equal(t, length(text), length(rt.stdoutBuffer), "stdout has no NUL byte")
    equal(t, length(rt.stderrBuffer), 0, "nothing on stderr")

    // run-wasi-test.py, commands_fast[0] "Simple WASI test"; its only
    // wildcard is `*`, where strings_boost's glob_match is Python's fnmatch
    let pattern = "Hello world*Constructor OK*Args: *; cat; ./wasi/simple/0.txt;*fib(20) = 6765* ms*48 65 6c 6c 6f 20 77 6f 72 6c 64*=== done ===*"
    check(t, glob_match(pattern, text), "stdout matches the driver's expect_pattern:\n{text}")

    // the exact bytes of every deterministic line (test.c main)
    let head = "Hello world\nConstructor OK\nHello printf!\nArgs: test.wasm; cat; ./wasi/simple/0.txt; \n"
    let tail = "48 65 6c 6c 6f 20 77 6f 72 6c 64 \n=== done ===\n"
    check(t, starts_with(text, head), "stdout starts with the exact bytes of test_write, test_constructor, test_printf, test_args")
    check(t, ends_with(text, tail), "stdout ends with the exact bytes of test_cat and \"=== done ===\"")

    let lines <- split(text, "\n")
    equal(t, length(lines), 10, "nine lines and the empty piece after the last newline")
    if (length(lines) == 10) {
        // test_gettime: "Now: %lld sec, %ld ns"
        let now <- split(lines[4], " ")
        let nowOk = length(now) == 5 && now[0] == "Now:" && now[2] == "sec," && now[4] == "ns"
        check(t, nowOk, "test_gettime line shape: \"{lines[4]}\"")
        if (nowOk) {
            check(t, is_decimal(now[1]) && to_int64(now[1]) > 1600000000l, "REALTIME seconds are a wall clock")
            check(t, is_decimal(now[3]) && to_int64(now[3]) < 1000000000l, "tv_nsec is below one second")
        }
        // test_random: "%d + %d = %d", both in 0..10
        let sum <- split(lines[5], " ")
        let sumOk = length(sum) == 5 && sum[1] == "+" && sum[3] == "=" && is_decimal(sum[0]) && is_decimal(sum[2]) && is_decimal(sum[4])
        check(t, sumOk, "test_random line shape: \"{lines[5]}\"")
        if (sumOk) {
            let x = to_int(sum[0])
            let y = to_int(sum[2])
            check(t, x <= 10 && y <= 10 && x + y == to_int(sum[4]), "rand_range(0, 10) twice and their sum")
        }
        // test_perf_fib: "fib(%d) = %d [%.3f ms]"
        check(t, starts_with(lines[6], "fib(20) = 6765 [") && ends_with(lines[6], " ms]"), "test_perf_fib line: \"{lines[6]}\"")
    }

    // back to the default backend and an empty argv for the next user of
    // the shared context
    var none = M3WasiFsBackend()
    m3_SetWasiFsBackend(ctx, none)
    clear_args(ctx)
    m3_wasi_contexts[ctx].exit_code = 0
    clear(g_simple_body)
    m3_FreeRuntime(rt)
}


def test_clock_monotonic(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    let ids <- [WASI_CLOCKID_REALTIME, WASI_CLOCKID_MONOTONIC, WASI_CLOCKID_PROCESS_CPUTIME_ID, WASI_CLOCKID_THREAD_CPUTIME_ID]
    for (id in ids) {
        var prev = 0ul
        var ok = true
        for (k in range(50)) {
            let result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [u64(id), 1ul, 1024ul])
            if (result != m3Err_none || ret_errno(rt) != u32(WASI_ERRNO_SUCCESS)) {
                ok = false
                break
            }
            let now = mem_u64(rt, 1024u)
            if (now < prev) {
                ok = false
                break
            }
            prev = now
        }
        check(t, ok, "clock {id}: 50 reads succeed and never go backwards")
        if (id == WASI_CLOCKID_REALTIME) {
            check(t, prev > 1600000000ul * 1000000000ul, "clock {id} is nanoseconds past 2020")
        } elif (id == WASI_CLOCKID_MONOTONIC) {
            // Eden: counts from the anchor plus a 1 s base, like an uptime (Linux: since boot)
            check(t, prev >= 1000000000ul, "clock {id} starts at the 1 s base")
            check(t, prev < 1600000000ul * 1000000000ul, "clock {id} is not epoch time")
        } else {
            check(t, prev < 1600000000ul * 1000000000ul, "clock {id} is the time elapsed since the anchor")
        }

        let res = call_raw(rt, @@m3_wasi_generic_clock_res_get, ctx, [u64(id), 1040ul])
        is_ok(t, res, "clock_res_get({id}) returns no trap")
        equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "clock_res_get({id}) -> ERRNO_SUCCESS")
        equal(t, mem_u64(rt, 1040u), 1000000ul, "clock_res_get({id}) -> the 1 ms default")
    }

    // the first id past the WASI clocks (C: convert_clockid default: -1)
    var result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [4ul, 0ul, 1024ul])
    is_ok(t, result, "clock_time_get(4) returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_INVAL), "clock_time_get(4) -> ERRNO_INVAL")
    result = call_raw(rt, @@m3_wasi_generic_clock_res_get, ctx, [4ul, 1040ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_INVAL), "clock_res_get(4) -> ERRNO_INVAL")

    // m3ApiCheckMem before the clock id: 8 bytes must fit
    result = call_raw(rt, @@m3_wasi_generic_clock_time_get, ctx, [u64(WASI_CLOCKID_MONOTONIC), 0ul, u64(m3_GetMemorySize(rt) - 4u)])
    is_err(t, result, m3Err_trapOutOfBoundsMemoryAccess, "clock_time_get traps when the timestamp leaves memory")
    result = call_raw(rt, @@m3_wasi_generic_clock_res_get, ctx, [99ul, u64(m3_GetMemorySize(rt) - 4u)])
    is_err(t, result, m3Err_trapOutOfBoundsMemoryAccess, "clock_res_get checks memory before the clock id")

    m3_FreeRuntime(rt)
}


def test_random_get_fills(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    // 0 bytes: getrandom returns 0 == buf_len, SUCCESS, nothing written
    mem_set_u8(rt, 2048u, 0xaau8)
    var result = call_raw(rt, @@m3_wasi_generic_random_get, ctx, [2048ul, 0ul])
    is_ok(t, result, "random_get of 0 bytes returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "random_get of 0 bytes -> ERRNO_SUCCESS")
    equal(t, mem_u8(rt, 2048u), 0xaau8, "random_get of 0 bytes writes nothing")

    // 4 KiB, twice
    result = call_raw(rt, @@m3_wasi_generic_random_get, ctx, [8192ul, 4096ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "random_get of 4 KiB -> ERRNO_SUCCESS")
    result = call_raw(rt, @@m3_wasi_generic_random_get, ctx, [16384ul, 4096ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "random_get of 4 KiB again")

    var seen : array<bool>
    resize(seen, 256)
    var distinct = 0
    var same = 0
    for (i in range(4096)) {
        let a = mem_u8(rt, 8192u + u32(i))
        if (!seen[int(a)]) {
            seen[int(a)] = true
            distinct++
        }
        if (a == mem_u8(rt, 16384u + u32(i))) {
            same++
        }
    }
    check(t, distinct > 200, "4 KiB of random bytes take many distinct values ({distinct})")
    check(t, same < 4096, "two random_get calls give different bytes")

    // the end of the range may be the end of memory exactly
    result = call_raw(rt, @@m3_wasi_generic_random_get, ctx, [u64(m3_GetMemorySize(rt) - 16u), 16ul])
    is_ok(t, result, "random_get up to the last byte of memory returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "random_get up to the last byte -> ERRNO_SUCCESS")

    m3_FreeRuntime(rt)
}


def test_args_layout(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    let ctx = new_wasi_fixture(t, rt)
    if (ctx == -1) {
        m3_FreeRuntime(rt)
        return
    }

    // argc 0: sizes 0 / 0, args_get writes nothing
    clear_args(ctx)
    var result = call_raw(rt, @@m3_wasi_generic_args_sizes_get, ctx, [16ul, 32ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "args_sizes_get with argc 0 -> ERRNO_SUCCESS")
    equal(t, mem_u32(rt, 16u), 0u, "argc 0")
    equal(t, mem_u32(rt, 32u), 0u, "argv_buf_size 0")
    mem_set_u8(rt, 100u, 0xaau8)
    mem_set_u8(rt, 200u, 0xaau8)
    result = call_raw(rt, @@m3_wasi_generic_args_get, ctx, [100ul, 200ul])
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "args_get with argc 0 -> ERRNO_SUCCESS")
    equal(t, mem_u8(rt, 100u), 0xaau8, "args_get with argc 0 writes no offset")
    equal(t, mem_u8(rt, 200u), 0xaau8, "args_get with argc 0 writes no byte")

    // "a", "" and "é!" (UTF-8: 0xc3 0xa9, then '!'): C's strlen counts bytes
    var args <- ["a", "", "é!"]
    set_args(ctx, args)
    result = call_raw(rt, @@m3_wasi_generic_args_sizes_get, ctx, [16ul, 32ul])
    equal(t, mem_u32(rt, 16u), 3u, "argc 3")
    equal(t, mem_u32(rt, 32u), 7u, "argv_buf_size (1+1 + 0+1 + 3+1)")

    result = call_raw(rt, @@m3_wasi_generic_args_get, ctx, [300ul, 400ul])
    is_ok(t, result, "args_get returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_SUCCESS), "args_get -> ERRNO_SUCCESS")
    equal(t, mem_u32(rt, 300u), 400u, "argv[0] at the buffer start")
    equal(t, mem_u32(rt, 304u), 402u, "argv[1] after \"a\\0\"")
    equal(t, mem_u32(rt, 308u), 403u, "argv[2] after the empty argument's NUL")
    let want <- [0x61u8, 0u8, 0u8, 0xc3u8, 0xa9u8, 0x21u8, 0u8]
    var same = true
    for (b, i in want, count()) {
        if (mem_u8(rt, 400u + u32(i)) != b) {
            same = false
        }
    }
    check(t, same, "argv_buf holds the NUL-terminated bytes back to back")

    // m3ApiCheckMem(argv, argc * 4) traps before anything is written
    result = call_raw(rt, @@m3_wasi_generic_args_get, ctx, [u64(m3_GetMemorySize(rt) - 8u), 400ul])
    is_err(t, result, m3Err_trapOutOfBoundsMemoryAccess, "args_get traps when the offset array leaves memory")
    // m3ApiCheckMem(argv_buf, len) per argument: "é!" does not fit
    result = call_raw(rt, @@m3_wasi_generic_args_get, ctx, [300ul, u64(m3_GetMemorySize(rt) - 4u)])
    is_err(t, result, m3Err_trapOutOfBoundsMemoryAccess, "args_get traps when an argument leaves memory")

    // no context
    result = call_raw(rt, @@m3_wasi_generic_args_get, -1, [300ul, 400ul])
    is_ok(t, result, "args_get without a context returns no trap")
    equal(t, ret_errno(rt), u32(WASI_ERRNO_INVAL), "args_get without a context -> ERRNO_INVAL")

    clear_args(ctx)
    m3_FreeRuntime(rt)
}


/*
    (module
      (import "<ns>" "proc_exit" (func (param i32)))
      (func (export "run") (param i32) local.get 0 call 0))
*/
def private proc_exit_module(ns : string) : array<u8> {
    var out <- [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
                0x01u8, 0x05u8, 0x01u8, 0x60u8, 0x01u8, 0x7fu8, 0x00u8]      // type 0: (i32) -> ()
    let n = length(ns)
    push(out, 0x02u8)                                                        // import section
    push(out, u8(n + 14))
    push(out, 0x01u8)
    push(out, u8(n))
    for (i in range(n)) {
        push(out, u8(character_at(ns, i)))
    }
    push(out, 0x09u8)
    let field = "proc_exit"
    for (i in range(length(field))) {
        push(out, u8(character_at(field, i)))
    }
    push(out, 0x00u8)                                                        // func, type 0
    push(out, 0x00u8)
    let rest <- [0x03u8, 0x02u8, 0x01u8, 0x00u8,                             // function section: type 0
                 0x07u8, 0x07u8, 0x01u8, 0x03u8, 0x72u8, 0x75u8, 0x6eu8, 0x00u8, 0x01u8,   // export "run" = func 1
                 0x0au8, 0x08u8, 0x01u8, 0x06u8, 0x00u8, 0x20u8, 0x00u8, 0x10u8, 0x00u8, 0x0bu8]   // local.get 0; call 0
    for (b in rest) {
        push(out, b)
    }
    return <- out
}


def private run_proc_exit(var t : TestRun; ns : string; code : u64; want : i32) {
    var rt <- new_runtime(64u * 1024u)
    let bytes <- proc_exit_module(ns)
    let m = load_module(t, rt, bytes, "{ns} proc_exit module")
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LinkWASI(rt, m), "m3_LinkWASI ({ns})")
    let ctx = m3_GetWasiContext()
    check(t, import_compiled(rt, m, "proc_exit"), "{ns}.proc_exit is linked")
    var run : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, run, "run"), "m3_FindFunction run")
    if (run == -1 || !m3_IsWasiContext(ctx)) {
        m3_FreeRuntime(rt)
        return
    }
    m3_wasi_contexts[ctx].exit_code = 12345
    is_err(t, m3_Call(rt, run, [code]), m3Err_trapExit, "{ns}: run({code}) leaves m3_Call with m3Err_trapExit")
    equal(t, m3_wasi_contexts[ctx].exit_code, want, "{ns}: the exit code is in the context")
    m3_wasi_contexts[ctx].exit_code = 0
    m3_FreeRuntime(rt)
}


def test_proc_exit_linked(var t : TestRun; fx : FixtureSource) {
    run_proc_exit(t, "wasi_snapshot_preview1", 3ul, 3)
    run_proc_exit(t, "wasi_unstable", 0xfffffffful, -1)
}


def public run_tests_m3_api_wasi(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_link_wasi_resolves_every_test_wasm_import")
    test_link_wasi_resolves_every_test_wasm_import(t, fx)
    begin_test(t, "test_link_wasi_allocates_the_context_once")
    test_link_wasi_allocates_the_context_once(t, fx)
    begin_test(t, "test_args_sizes_get_and_args_get")
    test_args_sizes_get_and_args_get(t, fx)
    begin_test(t, "test_environ_get_and_environ_sizes_get")
    test_environ_get_and_environ_sizes_get(t, fx)
    begin_test(t, "test_clock_time_get")
    test_clock_time_get(t, fx)
    begin_test(t, "test_clock_res_get")
    test_clock_res_get(t, fx)
    begin_test(t, "test_random_get")
    test_random_get(t, fx)
    begin_test(t, "test_proc_exit")
    test_proc_exit(t, fx)
    begin_test(t, "test_wasi_simple_end_to_end")
    test_wasi_simple_end_to_end(t, fx)
    begin_test(t, "test_clock_monotonic")
    test_clock_monotonic(t, fx)
    begin_test(t, "test_random_get_fills")
    test_random_get_fills(t, fx)
    begin_test(t, "test_args_layout")
    test_args_layout(t, fx)
    begin_test(t, "test_proc_exit_linked")
    test_proc_exit_linked(t, fx)
}
