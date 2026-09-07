options gen2
options indenting = 4
// The WASI host functions are called directly as M3RawCall values, so no
// interpreter frames are nested here; the stack is raised for the parser
// instead. wasi/simple/test.wasm is a real 50 KB clang output whose data
// segments make m3_ParseModule recurse into Parse_InitExpr far deeper than
// the default 16 KiB context stack allows. options stack counts only in the
// program root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/integration/test_m3_api_libc.das: under dastest a
// test file that names its module does not run the [init] functions of
// required shared modules.

require dastest/testing_boost
require daslib/fio
require ../../source/m3_api_wasi.das
require ../../source/m3_parse.das


/*
    Component test for the core half of m3_api_wasi.das (C m3_api_wasi.c).

    Two fixtures:

    1. A hand-assembled module whose only section is a one-page memory. It
       gives m3_LoadModule something to allocate, so the raw functions get a
       real `_mem` base and m3ApiCheckMem has a real memory size to bound
       against. The raw functions are then called directly with a `_sp` slot
       array and an M3ImportContext, which is exactly the ABI
       m3ApiRawFunction expands to.

    2. wasm3c/test/wasi/simple/test.wasm, the module the C driver
       (wasm3c/test/run-wasi-test.py) runs first. It imports 13
       wasi_snapshot_preview1 functions, all of them in C m3_LinkWASI's list,
       so a correct m3_LinkWASI must leave none of them unresolved.
*/


let TEST_WASM_PATH = "wasm3c/test/wasi/simple/test.wasm"


// The 13 imports of wasi/simple/test.wasm, in the order of its import
// section. Every one is linked by C m3_LinkWASI.
let TEST_WASM_IMPORTS = [
    "proc_exit", "clock_time_get", "fd_read", "fd_close",
    "fd_prestat_get", "fd_prestat_dir_name", "fd_fdstat_get", "path_open",
    "args_sizes_get", "args_get", "random_get", "fd_seek", "fd_write"
]


/*
    (module (memory 1))

    Sections in the order m3_ParseModule enforces: 5 memory only.
    Section 5, size 3: one memory, limits flag 0 (min only), min 1 page.
*/
let MEMORY_WASM = [
    0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
    0x05u8, 0x03u8, 0x01u8, 0x00u8, 0x01u8
]


let PAGE_SIZE = 65536u


struct WasiFixture {
    env : IM3Environment
    runtime : IM3Runtime
    _module : IM3Module
    mem : u8?
    memSize : u32
}


def private read_file(path : string) : array<u8> {
    var bytes : array<u8>
    fopen(path, "rb") $(f) {
        if (f != null) {
            let st = fstat(f)
            bytes |> resize(int64(st.size))
            fread(f, bytes)
        }
    }
    return <- bytes
}


// The module bytes must outlive the module: m3_ParseModule stores wasm
// pointers into the caller's buffer.
def private new_fixture(var bytes : array<u8>) : WasiFixture {
    var fx : WasiFixture
    fx.env = m3_NewEnvironment()
    if (fx.env == null) { return fx }
    fx.runtime = m3_NewRuntime(fx.env, 64u * 1024u, null)
    if (fx.runtime == null) { return fx }
    if (m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes))) != m3Err_none) {
        fx._module = null
        return fx
    }
    if (m3_LoadModule(fx.runtime, fx._module) != m3Err_none) {
        fx._module = null
        return fx
    }
    fx.mem = m3_GetMemory(fx.runtime, fx.memSize, 0u)
    return fx
}


def private free_fixture(var fx : WasiFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


// ============================================================================
// Linear-memory helpers (host side of the guest addresses used below)
// ============================================================================


def private mem_u8(fx : WasiFixture; off : u32) : u8 {
    unsafe {
        return (fx.mem + int(off))[0]
    }
}


// `var fx` rather than a const parameter: the fixture is copied by value, so
// its `mem` pointer keeps write access to linear memory.
def private mem_set_u8(var fx : WasiFixture; off : u32; value : u8) {
    unsafe {
        (fx.mem + int(off))[0] = value
    }
}


def private mem_u32(fx : WasiFixture; off : u32) : u32 {
    unsafe {
        return reinterpret<u32?>(fx.mem + int(off))[0]
    }
}


def private mem_u64(fx : WasiFixture; off : u32) : u64 {
    unsafe {
        return reinterpret<u64?>(fx.mem + int(off))[0]
    }
}


def private mem_base(fx : WasiFixture) : void? {
    unsafe {
        return reinterpret<void?>(fx.mem)
    }
}


// ============================================================================
// Raw-call helper: the M3RawCall ABI m3ApiRawFunction expands to
// ============================================================================


/*
    A wasm3 raw function receives `_sp` pointing at the return slot, followed
    by one 64-bit slot per argument, and `_mem` pointing at the base of linear
    memory. The helpers below build that stack in an array the caller owns and
    hand out its address; `slots[0]` is the return value after the call.
*/
def private new_slots(count : int) : array<u64> {
    var slots : array<u64>
    slots |> resize(count)
    return <- slots
}


def private sp_of(var slots : array<u64>) : u64? {
    unsafe {
        return addr(slots[0])
    }
}


// ============================================================================
// m3_LinkWASI over the real WASI test module
// ============================================================================


def private import_compiled(var fx : WasiFixture; field : string) : bool {
    for (i in 0u..fx._module.numFuncImports) {
        var f : IM3Function
        unsafe { f = addr(fx._module.functions[i]) }
        if (f.import.fieldUtf8 == field) {
            return f.compiled != null
        }
    }
    return false
}


// C m3_LinkWASI links both wasi_unstable and wasi_snapshot_preview1 and wraps
// every lookup in SuppressLookupFailure, so a module importing only a subset
// still links cleanly and every name it does import must end up bound.
[test]
def test_link_wasi_resolves_every_test_wasm_import(t : T?) {
    var bytes <- read_file(TEST_WASM_PATH)
    t |> success(!empty(bytes), "wasi/simple/test.wasm is readable")
    if (empty(bytes)) { return }

    var fx = new_fixture(bytes)
    t |> success(fx._module != null, "test.wasm parses and loads")
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    t |> equal(fx._module.numFuncImports, 13u, "test.wasm has 13 function imports")
    t |> equal(m3_LinkWASI(fx._module), m3Err_none, "m3_LinkWASI")

    for (name in TEST_WASM_IMPORTS) {
        t |> success(import_compiled(fx, name), "wasi_snapshot_preview1.{name} is linked")
    }

    free_fixture(fx)
}


// C: m3_LinkWASI allocates the static context on its first call and never
// frees it, so every later call returns the same pointer.
[test]
def test_link_wasi_allocates_the_context_once(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_fixture(bytes)
    t |> success(fx._module != null, "memory fixture parses and loads")
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    t |> equal(m3_LinkWASI(fx._module), m3Err_none, "m3_LinkWASI on a module with no imports")

    var ctx = m3_GetWasiContext()
    t |> success(ctx != null, "m3_GetWasiContext after m3_LinkWASI")

    t |> equal(m3_LinkWASI(fx._module), m3Err_none, "m3_LinkWASI again")
    t |> success(m3_GetWasiContext() == ctx, "the context pointer is stable")

    free_fixture(fx)
}


// ============================================================================
// The raw functions, called directly on a one-page linear memory
// ============================================================================


// Builds the memory fixture and makes sure the WASI context exists, since
// only m3_LinkWASI allocates it (as in C).
def private new_wasi_fixture(t : T?; var bytes : array<u8>) : WasiFixture {
    var fx = new_fixture(bytes)
    if (fx._module == null) { return fx }
    t |> equal(m3_LinkWASI(fx._module), m3Err_none, "m3_LinkWASI")
    t |> equal(fx.memSize, PAGE_SIZE, "one page of linear memory")
    return fx
}


def private import_context(ctx : m3_wasi_context_t?) : M3ImportContext {
    var ictx : M3ImportContext
    unsafe {
        ictx.userdata = reinterpret<void?>(ctx)
    }
    return ictx
}


[test]
def test_args_sizes_get_and_args_get(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_wasi_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ctx = m3_GetWasiContext()
    ctx.argc = 2u
    ctx.argv <- ["cat", "./wasi/simple/0.txt"]
    t |> equal(length(ctx.argv[0]), 3, "argv[0] length")
    t |> equal(length(ctx.argv[1]), 19, "argv[1] length")

    var ictx = import_context(ctx)

    // args_sizes_get: i(**) - two out pointers, at guest offsets 16 and 32.
    var slots <- new_slots(3)
    slots[1] = 16ul
    slots[2] = 32ul
    var result = m3_wasi_generic_args_sizes_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots), mem_base(fx))
    t |> equal(result, m3Err_none, "args_sizes_get returns no trap")
    t |> equal(u32(slots[0]), u32(WASI_ERRNO_SUCCESS), "args_sizes_get -> ERRNO_SUCCESS")
    t |> equal(mem_u32(fx, 16u), 2u, "args_sizes_get writes argc")
    // C: buf_len += strlen(argv[i]) + 1 for every argument.
    t |> equal(mem_u32(fx, 32u), 24u, "args_sizes_get writes argv_buf_size (3+1 + 19+1)")

    // args_get: i(**) - the offset array at 100, the string buffer at 200.
    var slots2 <- new_slots(3)
    slots2[1] = 100ul
    slots2[2] = 200ul
    result = m3_wasi_generic_args_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots2), mem_base(fx))
    t |> equal(result, m3Err_none, "args_get returns no trap")
    t |> equal(u32(slots2[0]), u32(WASI_ERRNO_SUCCESS), "args_get -> ERRNO_SUCCESS")

    t |> equal(mem_u32(fx, 100u), 200u, "argv[0] points at the buffer start")
    t |> equal(mem_u32(fx, 104u), 204u, "argv[1] points past \"cat\\0\"")

    t |> equal(mem_u8(fx, 200u), 0x63u8, "argv_buf 'c'")
    t |> equal(mem_u8(fx, 201u), 0x61u8, "argv_buf 'a'")
    t |> equal(mem_u8(fx, 202u), 0x74u8, "argv_buf 't'")
    t |> equal(mem_u8(fx, 203u), 0u8, "argv_buf NUL after argv[0]")
    t |> equal(mem_u8(fx, 204u), 0x2eu8, "argv_buf '.'")
    t |> equal(mem_u8(fx, 205u), 0x2fu8, "argv_buf '/'")
    t |> equal(mem_u8(fx, 222u), 0x74u8, "argv_buf last character of argv[1]")
    t |> equal(mem_u8(fx, 223u), 0u8, "argv_buf NUL after argv[1]")

    // C: `if (context == NULL) { m3ApiReturn(__WASI_ERRNO_INVAL); }`.
    var no_ctx = import_context(null)
    var slots3 <- new_slots(3)
    slots3[1] = 16ul
    slots3[2] = 32ul
    result = m3_wasi_generic_args_sizes_get(fx.runtime, unsafe(addr(no_ctx)), sp_of(slots3), mem_base(fx))
    t |> equal(result, m3Err_none, "args_sizes_get without a context returns no trap")
    t |> equal(u32(slots3[0]), u32(WASI_ERRNO_INVAL), "args_sizes_get without a context -> ERRNO_INVAL")

    // C m3ApiCheckMem traps instead of returning an errno when the guest
    // pointer leaves linear memory.
    var slots4 <- new_slots(3)
    slots4[1] = u64(fx.memSize)
    slots4[2] = 32ul
    result = m3_wasi_generic_args_sizes_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots4), mem_base(fx))
    t |> equal(result, m3Err_trapOutOfBoundsMemoryAccess, "args_sizes_get traps past the end of memory")

    ctx.argc = 0u
    ctx.argv |> clear()
    free_fixture(fx)
}


// C leaves both environ functions as `// TODO`: environ_get writes nothing
// and environ_sizes_get reports zero variables and a zero-length buffer.
[test]
def test_environ_get_and_environ_sizes_get(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_wasi_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ictx = import_context(m3_GetWasiContext())

    mem_set_u8(fx, 48u, 0xaau8)
    mem_set_u8(fx, 64u, 0xaau8)

    var slots <- new_slots(3)
    slots[1] = 48ul
    slots[2] = 64ul
    var result = m3_wasi_generic_environ_sizes_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots), mem_base(fx))
    t |> equal(result, m3Err_none, "environ_sizes_get returns no trap")
    t |> equal(u32(slots[0]), u32(WASI_ERRNO_SUCCESS), "environ_sizes_get -> ERRNO_SUCCESS")
    t |> equal(mem_u32(fx, 48u), 0u, "environ_sizes_get writes 0 variables")
    t |> equal(mem_u32(fx, 64u), 0u, "environ_sizes_get writes a 0-byte buffer size")

    // environ_get consumes its two memory arguments and writes nothing.
    mem_set_u8(fx, 300u, 0xaau8)
    var slots2 <- new_slots(3)
    slots2[1] = 300ul
    slots2[2] = 400ul
    result = m3_wasi_generic_environ_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots2), mem_base(fx))
    t |> equal(result, m3Err_none, "environ_get returns no trap")
    t |> equal(u32(slots2[0]), u32(WASI_ERRNO_SUCCESS), "environ_get -> ERRNO_SUCCESS")
    t |> equal(mem_u8(fx, 300u), 0xaau8, "environ_get writes nothing (C TODO)")

    free_fixture(fx)
}


[test]
def test_clock_time_get(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_wasi_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ictx = import_context(m3_GetWasiContext())

    // clock_time_get: i(iI*) - clock id, precision, out pointer.
    var slots <- new_slots(4)
    slots[1] = u64(WASI_CLOCKID_REALTIME)
    slots[2] = 0ul
    slots[3] = 512ul
    var result = m3_wasi_generic_clock_time_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots), mem_base(fx))
    t |> equal(result, m3Err_none, "clock_time_get returns no trap")
    t |> equal(u32(slots[0]), u32(WASI_ERRNO_SUCCESS), "clock_time_get(REALTIME) -> ERRNO_SUCCESS")

    let first = mem_u64(fx, 512u)
    // A realtime clock in nanoseconds since the epoch: seconds must be past
    // 2020-09-13 (1600000000), which is what distinguishes it from the
    // monotonic clock.
    t |> success(first / 1000000000ul > 1600000000ul, "REALTIME is a wall clock in nanoseconds")

    var slots2 <- new_slots(4)
    slots2[1] = u64(WASI_CLOCKID_REALTIME)
    slots2[2] = 0ul
    slots2[3] = 520ul
    result = m3_wasi_generic_clock_time_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots2), mem_base(fx))
    t |> equal(u32(slots2[0]), u32(WASI_ERRNO_SUCCESS), "clock_time_get(REALTIME) again")
    t |> success(mem_u64(fx, 520u) >= first, "REALTIME does not go backwards")

    var slots3 <- new_slots(4)
    slots3[1] = u64(WASI_CLOCKID_MONOTONIC)
    slots3[2] = 0ul
    slots3[3] = 528ul
    result = m3_wasi_generic_clock_time_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots3), mem_base(fx))
    t |> equal(u32(slots3[0]), u32(WASI_ERRNO_SUCCESS), "clock_time_get(MONOTONIC) -> ERRNO_SUCCESS")
    t |> success(mem_u64(fx, 528u) > 0ul, "MONOTONIC is non-zero")

    // C: `int clk = convert_clockid(...); if (clk < 0) m3ApiReturn(INVAL);`
    mem_set_u8(fx, 536u, 0xaau8)
    var slots4 <- new_slots(4)
    slots4[1] = 99ul
    slots4[2] = 0ul
    slots4[3] = 536ul
    result = m3_wasi_generic_clock_time_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots4), mem_base(fx))
    t |> equal(result, m3Err_none, "clock_time_get with an unknown clock returns no trap")
    t |> equal(u32(slots4[0]), u32(WASI_ERRNO_INVAL), "clock_time_get(99) -> ERRNO_INVAL")
    t |> equal(mem_u8(fx, 536u), 0xaau8, "clock_time_get(99) writes nothing")

    free_fixture(fx)
}


// C: when clock_getres fails the resolution defaults to 1000000 ns. The
// port's clock_getres always reports failure (daslang has no resolution
// query), so every clock reports the 1 ms default.
[test]
def test_clock_res_get(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_wasi_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ictx = import_context(m3_GetWasiContext())

    var slots <- new_slots(3)
    slots[1] = u64(WASI_CLOCKID_REALTIME)
    slots[2] = 512ul
    var result = m3_wasi_generic_clock_res_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots), mem_base(fx))
    t |> equal(result, m3Err_none, "clock_res_get returns no trap")
    t |> equal(u32(slots[0]), u32(WASI_ERRNO_SUCCESS), "clock_res_get -> ERRNO_SUCCESS")
    t |> equal(mem_u64(fx, 512u), 1000000ul, "clock_res_get -> the 1 ms default")

    var slots2 <- new_slots(3)
    slots2[1] = 99ul
    slots2[2] = 512ul
    result = m3_wasi_generic_clock_res_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots2), mem_base(fx))
    t |> equal(u32(slots2[0]), u32(WASI_ERRNO_INVAL), "clock_res_get(99) -> ERRNO_INVAL")

    free_fixture(fx)
}


[test]
def test_random_get(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_wasi_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ictx = import_context(m3_GetWasiContext())

    // Fill the target range and one byte on each side with a marker, so the
    // test sees both that the buffer was written and that nothing outside it
    // was.
    for (off in 399u..465u) {
        mem_set_u8(fx, off, 0xaau8)
    }

    // random_get: i(*i) - buffer pointer, length.
    var slots <- new_slots(3)
    slots[1] = 400ul
    slots[2] = 64ul
    var result = m3_wasi_generic_random_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots), mem_base(fx))
    t |> equal(result, m3Err_none, "random_get returns no trap")
    t |> equal(u32(slots[0]), u32(WASI_ERRNO_SUCCESS), "random_get -> ERRNO_SUCCESS")

    var changed = 0
    for (off in 400u..464u) {
        if (mem_u8(fx, off) != 0xaau8) {
            changed++
        }
    }
    // 64 bytes that all happen to equal the marker has probability 256^-64.
    t |> success(changed > 0, "random_get fills the buffer")
    t |> equal(mem_u8(fx, 399u), 0xaau8, "random_get does not write before the buffer")
    t |> equal(mem_u8(fx, 464u), 0xaau8, "random_get does not write past the buffer")

    // C m3ApiCheckMem(buf, buf_len) traps when the range leaves memory.
    var slots2 <- new_slots(3)
    slots2[1] = u64(fx.memSize - 4u)
    slots2[2] = 64ul
    result = m3_wasi_generic_random_get(fx.runtime, unsafe(addr(ictx)), sp_of(slots2), mem_base(fx))
    t |> equal(result, m3Err_trapOutOfBoundsMemoryAccess, "random_get traps past the end of memory")

    free_fixture(fx)
}


// C: proc_exit stores the code in the context and traps with m3Err_trapExit;
// it has no return slot, its signature being "v(i)".
[test]
def test_proc_exit(t : T?) {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    var fx = new_wasi_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ctx = m3_GetWasiContext()
    ctx.exit_code = 0
    var ictx = import_context(ctx)

    var slots <- new_slots(1)
    slots[0] = 42ul
    let result = m3_wasi_generic_proc_exit(fx.runtime, unsafe(addr(ictx)), sp_of(slots), mem_base(fx))
    t |> equal(result, m3Err_trapExit, "proc_exit traps with m3Err_trapExit")
    t |> equal(ctx.exit_code, 42, "proc_exit stores the code in the context")

    // C tolerates a missing context: `if (context) { context->exit_code = code; }`.
    var no_ctx = import_context(null)
    var slots2 <- new_slots(1)
    slots2[0] = 7ul
    let result2 = m3_wasi_generic_proc_exit(fx.runtime, unsafe(addr(no_ctx)), sp_of(slots2), mem_base(fx))
    t |> equal(result2, m3Err_trapExit, "proc_exit without a context still traps")
    t |> equal(ctx.exit_code, 42, "proc_exit without a context leaves the context alone")

    ctx.exit_code = 0
    free_fixture(fx)
}
