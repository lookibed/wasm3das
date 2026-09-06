options gen2
options indenting = 4
// No wasm is executed here — the raw functions are called directly — but the
// fixture parses and loads a module, so the regression's stack budget is kept.
options stack = 4_194_304

// No `module` declaration, like tests/test_m3_env.das: under dastest a test
// file that names its module does not run the [init] functions of required
// shared modules.

require dastest/testing_boost
require daslib/fio
require daslib/strings
require ../source/m3_api_wasi_fd.das
require ../source/m3_parse.das


/*
    Component test for m3_api_wasi_fd.das (the fd half of m3_api_wasi.c).

    Every function under test is an M3RawCall, so the test drives it the way
    the executor does: a runtime that owns linear memory, a `_sp` array whose
    slot 0 is the return value and whose following slots are the arguments,
    and `_mem` pointing at the base of that linear memory. Arguments and
    results that live in linear memory are written and read with the same
    m3Api* helpers the port uses.

    The fixture module is assembled here rather than read from disk so the
    test runs in CI:

        (module (memory 1))

    one 64 KiB page, section 5 only, which is all fd_read/fd_write need.

    File fixtures come from wasm3c/test, relative to the repository root,
    which is dastest's working directory. wasm3c/test/wasi/simple/0.txt is
    the file the C WASI driver's "Simple WASI test" cats; it holds exactly
    "Hello world" with no trailing newline.
*/
let MEMORY_WASM = [
    0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
    // memory: one section-5 entry, flags 0 (no maximum), minimum 1 page
    0x05u8, 0x03u8, 0x01u8, 0x00u8, 0x01u8
]


let SIMPLE_TXT = "wasm3c/test/wasi/simple/0.txt"
let SIMPLE_TXT_BODY = "Hello world"
let SCRATCH_TXT = "tmp/test_m3_api_wasi_fd.out"


// Linear-memory offsets the tests use; any spot inside the single page will
// do, they only have to stay apart.
let OFF_PATH = 0x100u
let OFF_OUT = 0x200u
let OFF_IOVS = 0x300u
let OFF_BUF0 = 0x400u
let OFF_BUF1 = 0x500u
let OFF_COUNT = 0x600u


struct WasiFdFixture {
    env : IM3Environment
    runtime : IM3Runtime
    _module : IM3Module
    mem : void?
}


def private module_bytes() : array<u8> {
    var bytes : array<u8>
    bytes |> push_from(MEMORY_WASM)
    return <- bytes
}


// The module bytes must outlive the module: m3_ParseModule stores wasm
// pointers into the caller's buffer.
def private new_fixture(var bytes : array<u8>) : WasiFdFixture {
    var env = m3_NewEnvironment()
    var fx = WasiFdFixture(env = env, runtime = m3_NewRuntime(env, 64u * 1024u, null))
    if (m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes))) != m3Err_none) {
        fx._module = null
        return fx
    }
    if (m3_LoadModule(fx.runtime, fx._module) != m3Err_none) {
        fx._module = null
        return fx
    }
    var size = 0u
    let mem = m3_GetMemory(fx.runtime, size, 0u)
    unsafe {
        fx.mem = reinterpret<void?>(mem)
    }
    return fx
}


def private free_fixture(var fx : WasiFdFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


// ============================================================================
// Stack-slot and linear-memory helpers
// ============================================================================


def private new_sp() : array<u64> {
    var sp : array<u64>
    sp |> resize(16)
    return <- sp
}


def private sp_ptr(var sp : array<u64>) : u64? {
    return unsafe(addr(sp[0]))
}


// C m3ApiReturn writes sizeof(uint32_t) bytes into the slot, so only the low
// half of slot 0 carries the WASI errno.
def private sp_result(sp : array<u64>) : u32 {
    return u32(sp[0] & 0xFFFFFFFFul)
}


// [sideeffects]: the body only writes through a raw pointer, which daslang
// does not count as an observable effect, so without the annotation the call
// is optimised away.
[sideeffects]
def private mem_write32(mem : void?; off : u32; value : u32) {
    m3ApiWriteMem32(m3ApiOffsetToPtr(mem, off), value)
}


def private mem_read32(mem : void?; off : u32) : u32 {
    return m3ApiReadMem32(m3ApiOffsetToPtr(mem, off))
}


def private mem_read64(mem : void?; off : u32) : u64 {
    return m3ApiReadMem64(m3ApiOffsetToPtr(mem, off))
}


def private mem_read8(mem : void?; off : u32) : u8 {
    return m3ApiReadMem8(m3ApiOffsetToPtr(mem, off))
}


def private mem_write_string(mem : void?; off : u32; text : string) : u32 {
    var written = 0u
    peek_data(text) $(data : array<uint8>#) {
        for (i in 0..length(data)) {
            m3ApiWriteMem8(m3ApiOffsetToPtr(mem, off + u32(i)), data[i])
        }
        written = u32(length(data))
    }
    return written
}


def private mem_read_string(mem : void?; off : u32; count : u32) : string {
    var data : array<u8>
    data |> resize(int(count))
    for (i in 0..int(count)) {
        data[i] = mem_read8(mem, off + u32(i))
    }
    return string(data)
}


// One iovec is {u32 buf; u32 buf_len}, matching C's wasi_iovec_t.
[sideeffects]
def private mem_write_iovec(mem : void?; off : u32; index : u32; buf : u32; buf_len : u32) {
    mem_write32(mem, off + index * WASI_IOVEC_SIZE + WASI_IOVEC_OFF_BUF, buf)
    mem_write32(mem, off + index * WASI_IOVEC_SIZE + WASI_IOVEC_OFF_BUF_LEN, buf_len)
}


// ============================================================================
// Raw-call drivers, one per signature under test
// ============================================================================


def private call_prestat_get(var fx : WasiFdFixture; fd : u32; buf : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    sp[2] = u64(buf)
    let result = m3_wasi_generic_fd_prestat_get(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_prestat_get must not trap")
    return sp_result(sp)
}


def private call_prestat_dir_name(var fx : WasiFdFixture; fd : u32; path : u32; path_len : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    sp[2] = u64(path)
    sp[3] = u64(path_len)
    let result = m3_wasi_generic_fd_prestat_dir_name(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_prestat_dir_name must not trap")
    return sp_result(sp)
}


def private call_fdstat_get(var fx : WasiFdFixture; fd : u32; fdstat : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    sp[2] = u64(fdstat)
    let result = m3_wasi_generic_fd_fdstat_get(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_fdstat_get must not trap")
    return sp_result(sp)
}


def private call_fdstat_set_flags(var fx : WasiFdFixture; fd : u32; flags : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    sp[2] = u64(flags)
    let result = m3_wasi_generic_fd_fdstat_set_flags(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_fdstat_set_flags must not trap")
    return sp_result(sp)
}


def private call_path_open(var fx : WasiFdFixture;
                           dirfd : u32;
                           path : u32;
                           path_len : u32;
                           oflags : u32;
                           fs_rights_base : u64;
                           fs_flags : u32;
                           fd_out : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(dirfd)
    sp[2] = 0ul // dirflags
    sp[3] = u64(path)
    sp[4] = u64(path_len)
    sp[5] = u64(oflags)
    sp[6] = fs_rights_base
    sp[7] = 0ul // fs_rights_inheriting
    sp[8] = u64(fs_flags)
    sp[9] = u64(fd_out)
    let result = m3_wasi_generic_path_open(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "path_open must not trap")
    return sp_result(sp)
}


def private call_fd_read(var fx : WasiFdFixture; fd : u32; iovs : u32; iovs_len : u32; nread : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    sp[2] = u64(iovs)
    sp[3] = u64(iovs_len)
    sp[4] = u64(nread)
    let result = m3_wasi_generic_fd_read(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_read must not trap")
    return sp_result(sp)
}


def private call_fd_write(var fx : WasiFdFixture; fd : u32; iovs : u32; iovs_len : u32; nwritten : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    sp[2] = u64(iovs)
    sp[3] = u64(iovs_len)
    sp[4] = u64(nwritten)
    let result = m3_wasi_generic_fd_write(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_write must not trap")
    return sp_result(sp)
}


def private call_preview1_fd_seek(var fx : WasiFdFixture; fd : u32; offset : i64; whence : u32; out : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    unsafe {
        addr<i64?>(sp[2])[0] = offset
    }
    sp[3] = u64(whence)
    sp[4] = u64(out)
    let result = m3_wasi_snapshot_preview1_fd_seek(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_seek must not trap")
    return sp_result(sp)
}


def private call_unstable_fd_seek(var fx : WasiFdFixture; fd : u32; offset : i64; whence : u32; out : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    unsafe {
        addr<i64?>(sp[2])[0] = offset
    }
    sp[3] = u64(whence)
    sp[4] = u64(out)
    let result = m3_wasi_unstable_fd_seek(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_seek must not trap")
    return sp_result(sp)
}


def private call_fd_close(var fx : WasiFdFixture; fd : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    let result = m3_wasi_generic_fd_close(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_close must not trap")
    return sp_result(sp)
}


def private call_fd_datasync(var fx : WasiFdFixture; fd : u32) : u32 {
    var sp <- new_sp()
    sp[1] = u64(fd)
    let result = m3_wasi_generic_fd_datasync(fx.runtime, null, sp_ptr(sp), fx.mem)
    assert(result == m3Err_none, "fd_datasync must not trap")
    return sp_result(sp)
}


// Opens SIMPLE_TXT read-only through the "/" preopen and returns the new fd,
// or 0xFFFFFFFF when path_open failed.
def private open_simple_txt(var fx : WasiFdFixture; dirfd : u32) : u32 {
    let path_len = mem_write_string(fx.mem, OFF_PATH, SIMPLE_TXT)
    let errno = call_path_open(fx, dirfd, OFF_PATH, path_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT)
    if (errno != u32(WASI_ERRNO_SUCCESS)) {
        return 0xFFFFFFFFu
    }
    return mem_read32(fx.mem, OFF_OUT)
}


// ============================================================================
// Tests
// ============================================================================


// C errno_to_wasi is a plain table; the port must agree with it entry by
// entry, including the __WASI_ERRNO_INVAL default for anything unlisted.
[test]
def test_errno_to_wasi(t : T?) {
    t |> equal(errno_to_wasi(2), WASI_ERRNO_NOENT, "ENOENT")
    t |> equal(errno_to_wasi(9), WASI_ERRNO_BADF, "EBADF")
    t |> equal(errno_to_wasi(17), WASI_ERRNO_EXIST, "EEXIST")
    t |> equal(errno_to_wasi(20), WASI_ERRNO_NOTDIR, "ENOTDIR")
    t |> equal(errno_to_wasi(22), WASI_ERRNO_INVAL, "EINVAL")
    t |> equal(errno_to_wasi(34), WASI_ERRNO_RANGE, "ERANGE")
    t |> equal(errno_to_wasi(4242), WASI_ERRNO_INVAL, "unlisted errno defaults to INVAL")
}


// C: fd_prestat_get answers only for 3 <= fd < PREOPEN_CNT, and reports the
// preopen type plus strlen(path)+1.
[test]
def test_fd_prestat(t : T?) {
    wasi_fd_open_preopens()
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    t |> success(fx._module != null, "memory fixture parses and loads")
    t |> success(fx.mem != null, "runtime has linear memory")
    if (fx.mem == null) {
        free_fixture(fx)
        return
    }

    t |> equal(call_prestat_get(fx, 3u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_prestat_get(3)")
    t |> equal(mem_read32(fx.mem, OFF_OUT), u32(WASI_PREOPENTYPE_DIR), "preopen 3 is a directory")
    t |> equal(mem_read32(fx.mem, OFF_OUT + 4u), 2u, "preopen 3 name length is strlen(\"/\") + 1")

    t |> equal(call_prestat_get(fx, 4u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_prestat_get(4)")
    t |> equal(mem_read32(fx.mem, OFF_OUT + 4u), 3u, "preopen 4 name length is strlen(\"./\") + 1")

    // C rejects the standard streams and anything past the table.
    t |> equal(call_prestat_get(fx, 2u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_prestat_get(2) is BADF")
    t |> equal(call_prestat_get(fx, 5u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_prestat_get(5) is BADF")

    t |> equal(call_prestat_dir_name(fx, 3u, OFF_PATH, 2u), u32(WASI_ERRNO_SUCCESS), "fd_prestat_dir_name(3)")
    t |> equal(mem_read_string(fx.mem, OFF_PATH, 1u), "/", "preopen 3 is named \"/\"")
    t |> equal(mem_read8(fx.mem, OFF_PATH + 1u), 0u8, "the copied name keeps its NUL terminator")

    t |> equal(call_prestat_dir_name(fx, 4u, OFF_PATH, 3u), u32(WASI_ERRNO_SUCCESS), "fd_prestat_dir_name(4)")
    t |> equal(mem_read_string(fx.mem, OFF_PATH, 2u), "./", "preopen 4 is named \"./\"")

    t |> equal(call_prestat_dir_name(fx, 9u, OFF_PATH, 2u), u32(WASI_ERRNO_BADF), "fd_prestat_dir_name(9) is BADF")

    free_fixture(fx)
}


// C fills __wasi_fdstat_t from fstat/fcntl and clears FD_SEEK|FD_TELL for
// descriptors 0..2 so they look like a TTY.
[test]
def test_fd_fdstat_get(t : T?) {
    wasi_fd_open_preopens()
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    if (fx.mem == null) {
        free_fixture(fx)
        return
    }
    let all_rights = 0xFFFFFFFFFFFFFFFFul
    let tty_rights = all_rights & ~(WASI_RIGHTS_FD_SEEK | WASI_RIGHTS_FD_TELL)

    for (fd in 0u..3u) {
        t |> equal(call_fdstat_get(fx, fd, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get of a standard stream")
        t |> equal(mem_read8(fx.mem, OFF_OUT), WASI_FILETYPE_CHARACTER_DEVICE, "standard streams are character devices")
        t |> equal(mem_read64(fx.mem, OFF_OUT + 8u), tty_rights, "standard streams have no FD_SEEK/FD_TELL")
        t |> equal(mem_read64(fx.mem, OFF_OUT + 16u), all_rights, "fs_rights_inheriting is all rights")
    }

    t |> equal(call_fdstat_get(fx, 3u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get(3)")
    t |> equal(mem_read8(fx.mem, OFF_OUT), WASI_FILETYPE_DIRECTORY, "a preopen is a directory")
    t |> equal(mem_read64(fx.mem, OFF_OUT + 8u), all_rights, "a preopen keeps FD_SEEK/FD_TELL")

    // C reaches this through fcntl(fd, F_GETFL) failing with EBADF.
    t |> equal(call_fdstat_get(fx, 99u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_fdstat_get of an unknown fd is BADF")

    // C's fd_fdstat_set_flags is a "// TODO" that always succeeds.
    t |> equal(call_fdstat_set_flags(fx, 1u, 1u), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_set_flags always succeeds")
    t |> equal(call_fdstat_set_flags(fx, 99u, 0u), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_set_flags ignores a bad fd too")

    free_fixture(fx)
}


// path_open resolves against the preopen's real path, and a file opened
// through it reports REGULAR_FILE.
[test]
def test_path_open(t : T?) {
    wasi_fd_open_preopens()
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    if (fx.mem == null) {
        free_fixture(fx)
        return
    }

    let fd = open_simple_txt(fx, 3u)
    t |> success(fd != 0xFFFFFFFFu, "path_open of 0.txt through preopen 3")
    t |> success(fd >= u32(PREOPEN_CNT), "a new fd comes after the preopens")

    t |> equal(call_fdstat_get(fx, fd, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get of the opened file")
    t |> equal(mem_read8(fx.mem, OFF_OUT), WASI_FILETYPE_REGULAR_FILE, "an opened file is a regular file")

    t |> equal(call_fd_close(fx, fd), u32(WASI_ERRNO_SUCCESS), "fd_close")
    // C's close() on an already closed descriptor returns -1, and the C
    // function passes that straight through instead of an errno.
    t |> equal(call_fd_close(fx, fd), 0xFFFFFFFFu, "closing twice returns close()'s -1")

    // The other preopen names the same directory, so it opens the same file.
    let fd2 = open_simple_txt(fx, 4u)
    t |> success(fd2 != 0xFFFFFFFFu, "path_open of 0.txt through preopen 4")
    t |> equal(call_fd_close(fx, fd2), u32(WASI_ERRNO_SUCCESS), "fd_close")

    // C: openat() fails with ENOENT, which errno_to_wasi maps to NOENT.
    let missing_len = mem_write_string(fx.mem, OFF_PATH, "wasm3c/test/wasi/simple/no-such-file.txt")
    t |> equal(call_path_open(fx, 3u, OFF_PATH, missing_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
               u32(WASI_ERRNO_NOENT), "path_open of a missing file is NOENT")

    // C checks the 512-byte host_path buffer before touching the filesystem.
    t |> equal(call_path_open(fx, 3u, OFF_PATH, 512u, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
               u32(WASI_ERRNO_INVAL), "path_len >= 512 is INVAL")

    // C indexes preopen[dirfd] without a bounds check; the port rejects an
    // invalid dirfd instead of reading past the table.
    let simple_len = mem_write_string(fx.mem, OFF_PATH, SIMPLE_TXT)
    t |> equal(call_path_open(fx, 1u, OFF_PATH, simple_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
               u32(WASI_ERRNO_BADF), "path_open with a non-directory dirfd is BADF")

    free_fixture(fx)
}


// fd_read fills the iovecs in order and stops after a short read, which is
// the non-HAS_IOVEC branch of the C function.
[test]
def test_fd_read(t : T?) {
    wasi_fd_open_preopens()
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    if (fx.mem == null) {
        free_fixture(fx)
        return
    }
    let fd = open_simple_txt(fx, 3u)
    t |> success(fd != 0xFFFFFFFFu, "path_open of 0.txt")
    if (fd == 0xFFFFFFFFu) {
        free_fixture(fx)
        return
    }

    // "Hello world" split over two iovecs: 5 bytes, then the remaining 6.
    mem_write_iovec(fx.mem, OFF_IOVS, 0u, OFF_BUF0, 5u)
    mem_write_iovec(fx.mem, OFF_IOVS, 1u, OFF_BUF1, 6u)
    t |> equal(mem_read32(fx.mem, OFF_IOVS + WASI_IOVEC_OFF_BUF_LEN), 5u, "the iovec array is where fd_read looks")
    t |> equal(call_fd_read(fx, fd, OFF_IOVS, 2u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read of two iovecs")
    t |> equal(mem_read32(fx.mem, OFF_COUNT), 11u, "nread is the whole file")
    t |> equal(mem_read_string(fx.mem, OFF_BUF0, 5u), "Hello", "first iovec")
    t |> equal(mem_read_string(fx.mem, OFF_BUF1, 6u), " world", "second iovec")

    // At end of file the loop reads nothing and still succeeds.
    t |> equal(call_fd_read(fx, fd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read at EOF")
    t |> equal(mem_read32(fx.mem, OFF_COUNT), 0u, "nread is 0 at EOF")

    // snapshot_preview1 whence: 0 = SET, 1 = CUR, 2 = END.
    t |> equal(call_preview1_fd_seek(fx, fd, 6l, 0u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_seek SET 6")
    t |> equal(mem_read64(fx.mem, OFF_OUT), 6ul, "the new offset is written back as u64")
    mem_write_iovec(fx.mem, OFF_IOVS, 0u, OFF_BUF0, 5u)
    t |> equal(call_fd_read(fx, fd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read after seek")
    t |> equal(mem_read32(fx.mem, OFF_COUNT), 5u, "nread after seek")
    t |> equal(mem_read_string(fx.mem, OFF_BUF0, 5u), "world", "the tail of the file")

    // wasi_unstable numbers whence differently: 0 = CUR, 1 = END, 2 = SET.
    t |> equal(call_unstable_fd_seek(fx, fd, 0l, 1u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "unstable fd_seek END 0")
    t |> equal(mem_read64(fx.mem, OFF_OUT), 11ul, "END lands on the file size")
    t |> equal(call_unstable_fd_seek(fx, fd, 0l, 2u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "unstable fd_seek SET 0")
    t |> equal(mem_read64(fx.mem, OFF_OUT), 0ul, "SET 0 rewinds")
    t |> equal(call_preview1_fd_seek(fx, fd, 0l, 7u, OFF_OUT), u32(WASI_ERRNO_INVAL), "an unknown whence is INVAL")

    // C: read() on an unknown descriptor fails with EBADF.
    t |> equal(call_fd_read(fx, 99u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_read of an unknown fd is BADF")
    t |> equal(call_preview1_fd_seek(fx, 99u, 0l, 0u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_seek of an unknown fd is BADF")

    t |> equal(call_fd_close(fx, fd), u32(WASI_ERRNO_SUCCESS), "fd_close")
    t |> equal(call_fd_read(fx, fd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_read after close is BADF")

    free_fixture(fx)
}


// fd_write is the same loop in the other direction; the round trip proves
// path_open's create/truncate mode and fd_datasync's flush.
[test]
def test_fd_write(t : T?) {
    wasi_fd_open_preopens()
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    if (fx.mem == null) {
        free_fixture(fx)
        return
    }

    let path_len = mem_write_string(fx.mem, OFF_PATH, SCRATCH_TXT)
    let oflags = u32(WASI_OFLAGS_CREAT) | u32(WASI_OFLAGS_TRUNC)
    let rights = WASI_RIGHTS_FD_READ | WASI_RIGHTS_FD_WRITE
    t |> equal(call_path_open(fx, 3u, OFF_PATH, path_len, oflags, rights, 0u, OFF_OUT),
               u32(WASI_ERRNO_SUCCESS), "path_open with CREAT|TRUNC")
    let fd = mem_read32(fx.mem, OFF_OUT)

    let head = mem_write_string(fx.mem, OFF_BUF0, "Hello")
    let tail = mem_write_string(fx.mem, OFF_BUF1, " world")
    mem_write_iovec(fx.mem, OFF_IOVS, 0u, OFF_BUF0, head)
    mem_write_iovec(fx.mem, OFF_IOVS, 1u, OFF_BUF1, tail)
    t |> equal(call_fd_write(fx, fd, OFF_IOVS, 2u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_write of two iovecs")
    t |> equal(mem_read32(fx.mem, OFF_COUNT), 11u, "nwritten is the sum of both iovecs")

    // C's fd_datasync is fdatasync(fd); the port flushes.
    t |> equal(call_fd_datasync(fx, fd), u32(WASI_ERRNO_SUCCESS), "fd_datasync")
    t |> equal(call_fd_close(fx, fd), u32(WASI_ERRNO_SUCCESS), "fd_close")

    // Read it back through a second path_open, so the bytes really landed.
    let reopen_len = mem_write_string(fx.mem, OFF_PATH, SCRATCH_TXT)
    t |> equal(call_path_open(fx, 3u, OFF_PATH, reopen_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
               u32(WASI_ERRNO_SUCCESS), "path_open of the file just written")
    let rfd = mem_read32(fx.mem, OFF_OUT)
    mem_write_iovec(fx.mem, OFF_IOVS, 0u, OFF_BUF0, 11u)
    t |> equal(call_fd_read(fx, rfd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read of the round trip")
    t |> equal(mem_read32(fx.mem, OFF_COUNT), 11u, "the whole file came back")
    t |> equal(mem_read_string(fx.mem, OFF_BUF0, 11u), SIMPLE_TXT_BODY, "the round trip preserves the bytes")
    t |> equal(call_fd_close(fx, rfd), u32(WASI_ERRNO_SUCCESS), "fd_close")

    // C: write() on an unknown descriptor fails with EBADF, but only once it
    // reaches a non-empty iovec.
    t |> equal(call_fd_write(fx, 99u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_write of an unknown fd is BADF")
    mem_write_iovec(fx.mem, OFF_IOVS, 0u, OFF_BUF0, 0u)
    t |> equal(call_fd_write(fx, 99u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "only empty iovecs never reach write()")
    t |> equal(mem_read32(fx.mem, OFF_COUNT), 0u, "nwritten is 0")

    // A handle-less descriptor is fdatasync's -1 case.
    t |> equal(call_fd_datasync(fx, 3u), 0xFFFFFFFFu, "fd_datasync of a directory returns -1")

    free_fixture(fx)
}


// The file the fixture reads must be the one the C WASI driver expects.
[test]
def test_simple_txt_fixture(t : T?) {
    var st : FStat
    t |> success(stat(SIMPLE_TXT, st), "wasm3c/test/wasi/simple/0.txt exists")
    t |> equal(int(st.size), length(SIMPLE_TXT_BODY), "0.txt holds exactly \"Hello world\"")
}
