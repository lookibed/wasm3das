options gen2
options indenting = 4

module test_m3_api_wasi_fd shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_api_wasi_fd
require modules/wasm3das/source/m3_bind
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core
require strings
require math

/*
    test_m3_api_wasi_fd.das: the Eden tests of source/m3_api_wasi_fd.das
    (the fd half of m3_api_wasi.c), ported from
    .upstream/tests/integration/test_m3_api_wasi_fd.das.

    Every function under test is an M3RawCall, so the tests drive it the way
    op_CallRawFunction does: a runtime with 64 KiB of linear memory (upstream:
    the one page of a loaded `(module (memory 1))`; here rt.mem is sized by
    hand, m3_GetMemorySize is its length), the result cell at BASE of
    rt.stack and the arguments in the cells after it (two slot words per
    cell, DESIGN 4.5), and an M3ImportContext whose userdata is the token of
    a WASI context (m3_NewWasiContext). Arguments and results that live in
    linear memory are written and read with the m3Api* helpers.

    The upstream tests that open real files (path_open, fd_read, fd_write)
    run over a fake file system: a test backend (M3WasiFsBackend) of lambdas
    over an in-memory list of files, installed with m3_SetWasiFsBackend; its
    standard streams delegate to the default backend. "wasm3c/test/wasi/
    simple/0.txt" is seeded with "Hello world", the body of the fixture the
    C WASI driver's "Simple WASI test" cats; test_simple_txt_fixture checks
    that fixture itself through the FixtureSource. The other tests run over
    the default backend (rt.stdinBuffer / stdoutBuffer / stderrBuffer, no
    files).

    Changed assertion: path_open with dirfd 1 is ENOTDIR (C: openat on the
    stdout descriptor, which is not a directory); upstream checked its own
    EBADF. A dirfd past the preopen table is still EBADF.

    Eden tests (no upstream counterpart):
      - test_stdout_iovecs_nul: three iovecs with NUL bytes land byte-exact
        in rt.stdoutBuffer; fd 2 in rt.stderrBuffer.
      - test_stdin_read: fd_read consumes rt.stdinBuffer (NUL included),
        stops after the short iovec, then reads 0 at the end.
      - test_bad_fd: every fd call on a descriptor that is not open, a write
        to stdin, and a token that names no context.
      - test_iovec_out_of_bounds: the iovec array, a buffer and the count
        out of bounds trap with m3Err_trapOutOfBoundsMemoryAccess before
        any byte moves; an empty iovec is skipped (non-HAS_IOVEC branch).
      - test_path_open_default: the default backend has no files (NOENT,
        with O_CREAT too), a standard stream is not a directory (NOTDIR),
        "." opens, stdin does not seek (SPIPE).
      - test_linked_fd_write: fd_write linked with m3_LinkRawFunctionEx and
        the context token into a hand-built module and called through
        m3_Call; its trap leaves m3_Call.
*/


let private BASE = 16   // the result cell of every direct call, in rt.stack

let private SIMPLE_TXT = "wasm3c/test/wasi/simple/0.txt"
let private SIMPLE_TXT_BODY = "Hello world"
let private SCRATCH_TXT = "tmp/test_m3_api_wasi_fd.out"

// Linear-memory offsets the tests use; any spot inside the single page will
// do, they only have to stay apart.
let private OFF_PATH = 0x100u
let private OFF_OUT = 0x200u
let private OFF_IOVS = 0x300u
let private OFF_BUF0 = 0x400u
let private OFF_BUF1 = 0x500u
let private OFF_BUF2 = 0x580u
let private OFF_COUNT = 0x600u


// ============================================================================
// The fake file system (the test backend)
// ============================================================================


struct FakeFile {
    path : string = ""
    data : array<u8>
}


let private FH_FREE = 0
let private FH_DIR = 1
let private FH_FILE = 2


struct FakeHandle {
    kind : int = 0
    file : int = -1
    pos : int = 0
    flags : int = 0
}


var private g_fake_files : array<FakeFile>
var private g_fake_handles : array<FakeHandle>   // index = backend handle; 0..2 are the default stdio


def private fake_reset() {
    clear(g_fake_files)
    clear(g_fake_handles)
    for (i in range(3)) {
        push(g_fake_handles, FakeHandle())
    }
}


def private fake_seed(path : string; text : string) {
    var file = FakeFile(path = path)
    for (i in range(length(text))) {
        push(file.data, u8(character_at(text, i)))
    }
    emplace(g_fake_files, file)
}


def private fake_find(path : string) : int {
    for (file, i in g_fake_files, count()) {
        if (file.path == path) {
            return i
        }
    }
    return -1
}


def private fake_is_open(handle : int) : bool {
    return handle >= 3 && handle < length(g_fake_handles) && g_fake_handles[handle].kind != FH_FREE
}


def private fake_new_handle(kind : int; file : int; flags : int) : int {
    for (i in range(3, length(g_fake_handles))) {
        if (g_fake_handles[i].kind == FH_FREE) {
            g_fake_handles[i] = FakeHandle(kind = kind, file = file, flags = flags)
            return i
        }
    }
    push(g_fake_handles, FakeHandle(kind = kind, file = file, flags = flags))
    return length(g_fake_handles) - 1
}


def private fake_open(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int {
    if (path == "." && (dirHandle == AT_FDCWD || (fake_is_open(dirHandle) && g_fake_handles[dirHandle].kind == FH_DIR))) {
        return fake_new_handle(FH_DIR, -1, flags)
    }
    if (dirHandle != AT_FDCWD) {
        if (dirHandle >= 0 && dirHandle <= 2) {
            return -ENOTDIR
        }
        if (!fake_is_open(dirHandle)) {
            return -EBADF
        }
        if (g_fake_handles[dirHandle].kind != FH_DIR) {
            return -ENOTDIR
        }
    }
    var idx = fake_find(path)
    if (idx == -1) {
        if ((flags & O_CREAT) == 0) {
            return -ENOENT
        }
        emplace(g_fake_files, FakeFile(path = path))
        idx = length(g_fake_files) - 1
    } elif ((flags & O_CREAT) != 0 && (flags & O_EXCL) != 0) {
        return -EEXIST
    }
    if ((flags & O_TRUNC) != 0 && (flags & O_ACCMODE) != O_RDONLY) {
        clear(g_fake_files[idx].data)
    }
    return fake_new_handle(FH_FILE, idx, flags)
}


def private fake_read(var rt : M3Runtime; handle : int; var buf : array<u8>; len : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_read(rt, handle, buf, len)
    }
    if (!fake_is_open(handle)) {
        return -EBADF
    }
    if (g_fake_handles[handle].kind == FH_DIR) {
        return -EISDIR
    }
    if ((g_fake_handles[handle].flags & O_ACCMODE) == O_WRONLY) {
        return -EBADF
    }
    let file = g_fake_handles[handle].file
    let pos = g_fake_handles[handle].pos
    let n = max(0, min(len, length(g_fake_files[file].data) - pos))
    resize(buf, n)
    for (i in range(n)) {
        buf[i] = g_fake_files[file].data[pos + i]
    }
    g_fake_handles[handle].pos = pos + n
    return n
}


def private fake_write(var rt : M3Runtime; handle : int; bytes : array<u8>) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_write(rt, handle, bytes)
    }
    if (!fake_is_open(handle) || g_fake_handles[handle].kind == FH_DIR) {
        return -EBADF
    }
    if ((g_fake_handles[handle].flags & O_ACCMODE) == O_RDONLY) {
        return -EBADF
    }
    let file = g_fake_handles[handle].file
    if ((g_fake_handles[handle].flags & O_APPEND) != 0) {
        g_fake_handles[handle].pos = length(g_fake_files[file].data)
    }
    var pos = g_fake_handles[handle].pos
    for (b in bytes) {
        if (pos < length(g_fake_files[file].data)) {
            g_fake_files[file].data[pos] = b
        } else {
            push(g_fake_files[file].data, b)
        }
        pos++
    }
    g_fake_handles[handle].pos = pos
    return length(bytes)
}


def private fake_lseek(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_lseek(rt, handle, offset, whence)
    }
    if (!fake_is_open(handle)) {
        return i64(-EBADF)
    }
    if (g_fake_handles[handle].kind == FH_DIR) {
        return 0l
    }
    var origin = 0l
    if (whence == SEEK_CUR) {
        origin = i64(g_fake_handles[handle].pos)
    } elif (whence == SEEK_END) {
        origin = i64(length(g_fake_files[g_fake_handles[handle].file].data))
    } elif (whence != SEEK_SET) {
        return i64(-EINVAL)
    }
    let target = origin + offset
    if (target < 0l) {
        return i64(-EINVAL)
    }
    g_fake_handles[handle].pos = int(target)
    return target
}


def private fake_close(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_close(rt, handle)
    }
    if (!fake_is_open(handle)) {
        return -EBADF
    }
    g_fake_handles[handle] = FakeHandle()
    return 0
}


def private fake_fdatasync(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_fdatasync(rt, handle)
    }
    if (!fake_is_open(handle)) {
        return -EBADF
    }
    return g_fake_handles[handle].kind == FH_DIR ? -EINVAL : 0
}


def private fake_fcntl_getfl(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_fcntl_getfl(rt, handle)
    }
    if (!fake_is_open(handle)) {
        return -EBADF
    }
    if (g_fake_handles[handle].kind == FH_DIR) {
        return O_RDONLY | O_DIRECTORY
    }
    return g_fake_handles[handle].flags & ~(O_CREAT | O_EXCL | O_TRUNC)
}


def private fake_fstat_mode(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_fstat_mode(rt, handle)
    }
    if (!fake_is_open(handle)) {
        return -EBADF
    }
    return g_fake_handles[handle].kind == FH_DIR ? S_IFDIR : S_IFREG
}


def private fake_backend() : M3WasiFsBackend {
    var b = M3WasiFsBackend()
    b.open <- @(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int {
        return fake_open(rt, dirHandle, path, flags, mode)
    }
    b.read <- @(var rt : M3Runtime; handle : int; var buf : array<u8>; len : int) : int {
        return fake_read(rt, handle, buf, len)
    }
    b.write <- @(var rt : M3Runtime; handle : int; bytes : array<u8>) : int {
        return fake_write(rt, handle, bytes)
    }
    b.lseek <- @(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
        return fake_lseek(rt, handle, offset, whence)
    }
    b.close <- @(var rt : M3Runtime; handle : int) : int {
        return fake_close(rt, handle)
    }
    b.fdatasync <- @(var rt : M3Runtime; handle : int) : int {
        return fake_fdatasync(rt, handle)
    }
    b.fcntl_getfl <- @(var rt : M3Runtime; handle : int) : int {
        return fake_fcntl_getfl(rt, handle)
    }
    b.fstat_mode <- @(var rt : M3Runtime; handle : int) : int {
        return fake_fstat_mode(rt, handle)
    }
    return <- b
}


// ============================================================================
// Fixture: a runtime with one page of memory and a WASI context
// ============================================================================


def private new_runtime() : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    resize(rt.mem, 65536)
    return <- rt
}


// a new context over the default backend, or over a fresh fake file system
// holding SIMPLE_TXT; the preopens are opened as m3_LinkWASI does
def private new_wasi(var rt : M3Runtime; fake : bool) : int {
    let token = m3_NewWasiContext()
    if (fake) {
        fake_reset()
        fake_seed(SIMPLE_TXT, SIMPLE_TXT_BODY)
        var b <- fake_backend()
        m3_SetWasiFsBackend(token, b)
    }
    wasi_fd_open_preopens(rt, token)
    return token
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


// a call that must not trap; returns the WASI errno C's m3ApiReturn stored
def private call_ok(var t : TestRun; var rt : M3Runtime; fn : M3RawCall; token : int; args : array<u64>; what : string) : u32 {
    is_ok(t, call_raw(rt, fn, token, args), "{what} must not trap")
    return stack_u32(rt, BASE)
}


def private call_prestat_get(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; buf : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_prestat_get, token, [u64(fd), u64(buf)], "fd_prestat_get")
}


def private call_prestat_dir_name(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; path : u32; path_len : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_prestat_dir_name, token, [u64(fd), u64(path), u64(path_len)], "fd_prestat_dir_name")
}


def private call_fdstat_get(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; fdstat : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_fdstat_get, token, [u64(fd), u64(fdstat)], "fd_fdstat_get")
}


def private call_fdstat_set_flags(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; flags : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_fdstat_set_flags, token, [u64(fd), u64(flags)], "fd_fdstat_set_flags")
}


def private path_open_args(dirfd : u32; path : u32; path_len : u32; oflags : u32; fs_rights_base : u64; fs_flags : u32; fd_out : u32) : array<u64> {
    // dirflags and fs_rights_inheriting are 0
    return <- [u64(dirfd), 0ul, u64(path), u64(path_len), u64(oflags), fs_rights_base, 0ul, u64(fs_flags), u64(fd_out)]
}


def private call_path_open(var t : TestRun; var rt : M3Runtime; token : int; dirfd : u32; path : u32; path_len : u32; oflags : u32; fs_rights_base : u64; fs_flags : u32; fd_out : u32) : u32 {
    let args <- path_open_args(dirfd, path, path_len, oflags, fs_rights_base, fs_flags, fd_out)
    return call_ok(t, rt, @@m3_wasi_generic_path_open, token, args, "path_open")
}


def private call_fd_read(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; iovs : u32; iovs_len : u32; nread : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_read, token, [u64(fd), u64(iovs), u64(iovs_len), u64(nread)], "fd_read")
}


def private call_fd_write(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; iovs : u32; iovs_len : u32; nwritten : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_write, token, [u64(fd), u64(iovs), u64(iovs_len), u64(nwritten)], "fd_write")
}


def private call_preview1_fd_seek(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; offset : i64; whence : u32; out : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_snapshot_preview1_fd_seek, token, [u64(fd), u64(offset), u64(whence), u64(out)], "fd_seek")
}


def private call_unstable_fd_seek(var t : TestRun; var rt : M3Runtime; token : int; fd : u32; offset : i64; whence : u32; out : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_unstable_fd_seek, token, [u64(fd), u64(offset), u64(whence), u64(out)], "fd_seek")
}


def private call_fd_close(var t : TestRun; var rt : M3Runtime; token : int; fd : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_close, token, [u64(fd)], "fd_close")
}


def private call_fd_datasync(var t : TestRun; var rt : M3Runtime; token : int; fd : u32) : u32 {
    return call_ok(t, rt, @@m3_wasi_generic_fd_datasync, token, [u64(fd)], "fd_datasync")
}


def private mem_write32(var rt : M3Runtime; off : u32; value : u32) {
    m3ApiWriteMem32(rt, int(off), value)
}


def private mem_read32(rt : M3Runtime; off : u32) : u32 {
    return m3ApiReadMem32(rt, int(off))
}


def private mem_read64(rt : M3Runtime; off : u32) : u64 {
    return m3ApiReadMem64(rt, int(off))
}


def private mem_read8(rt : M3Runtime; off : u32) : u8 {
    return m3ApiReadMem8(rt, int(off))
}


def private mem_write_string(var rt : M3Runtime; off : u32; text : string) : u32 {
    m3ApiWriteString(rt, int(off), text)
    return u32(length(text))
}


def private mem_read_string(rt : M3Runtime; off : u32; count : u32) : string {
    return m3ApiReadString(rt, int(off), int(count))
}


// One iovec is {u32 buf; u32 buf_len}, matching C's wasi_iovec_t.
def private mem_write_iovec(var rt : M3Runtime; off : u32; index : u32; buf : u32; buf_len : u32) {
    mem_write32(rt, off + index * WASI_IOVEC_SIZE + WASI_IOVEC_OFF_BUF, buf)
    mem_write32(rt, off + index * WASI_IOVEC_SIZE + WASI_IOVEC_OFF_BUF_LEN, buf_len)
}


// Opens SIMPLE_TXT read-only through preopen `dirfd` and returns the new fd,
// or 0xFFFFFFFF when path_open failed.
def private open_simple_txt(var t : TestRun; var rt : M3Runtime; token : int; dirfd : u32) : u32 {
    let path_len = mem_write_string(rt, OFF_PATH, SIMPLE_TXT)
    let errno = call_path_open(t, rt, token, dirfd, OFF_PATH, path_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT)
    if (errno != u32(WASI_ERRNO_SUCCESS)) {
        return 0xFFFFFFFFu
    }
    return mem_read32(rt, OFF_OUT)
}


def private bytes_of(text : string) : array<u8> {
    var out : array<u8>
    for (i in range(length(text))) {
        push(out, u8(character_at(text, i)))
    }
    return <- out
}


def private same_bytes(a : array<u8>; b : array<u8>) : bool {
    if (length(a) != length(b)) {
        return false
    }
    for (x, y in a, b) {
        if (x != y) {
            return false
        }
    }
    return true
}


// ============================================================================
// Tests ported from upstream
// ============================================================================


// C errno_to_wasi is a plain table; the port must agree with it entry by
// entry, including the __WASI_ERRNO_INVAL default for anything unlisted.
def test_errno_to_wasi(var t : TestRun; fx : FixtureSource) {
    equal(t, errno_to_wasi(2), WASI_ERRNO_NOENT, "ENOENT")
    equal(t, errno_to_wasi(9), WASI_ERRNO_BADF, "EBADF")
    equal(t, errno_to_wasi(17), WASI_ERRNO_EXIST, "EEXIST")
    equal(t, errno_to_wasi(20), WASI_ERRNO_NOTDIR, "ENOTDIR")
    equal(t, errno_to_wasi(22), WASI_ERRNO_INVAL, "EINVAL")
    equal(t, errno_to_wasi(34), WASI_ERRNO_RANGE, "ERANGE")
    equal(t, errno_to_wasi(4242), WASI_ERRNO_INVAL, "unlisted errno defaults to INVAL")
}


// C: fd_prestat_get answers only for 3 <= fd < PREOPEN_CNT, and reports the
// preopen type plus strlen(path)+1.
def test_fd_prestat(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    check(t, m3_IsWasiContext(token), "the context exists")
    equal(t, int(m3_GetMemorySize(rt)), 65536, "runtime has linear memory")

    equal(t, call_prestat_get(t, rt, token, 3u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_prestat_get(3)")
    equal(t, mem_read32(rt, OFF_OUT), u32(WASI_PREOPENTYPE_DIR), "preopen 3 is a directory")
    equal(t, mem_read32(rt, OFF_OUT + 4u), 2u, "preopen 3 name length is strlen(\"/\") + 1")

    equal(t, call_prestat_get(t, rt, token, 4u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_prestat_get(4)")
    equal(t, mem_read32(rt, OFF_OUT + 4u), 3u, "preopen 4 name length is strlen(\"./\") + 1")

    // C rejects the standard streams and anything past the table.
    equal(t, call_prestat_get(t, rt, token, 2u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_prestat_get(2) is BADF")
    equal(t, call_prestat_get(t, rt, token, 5u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_prestat_get(5) is BADF")

    equal(t, call_prestat_dir_name(t, rt, token, 3u, OFF_PATH, 2u), u32(WASI_ERRNO_SUCCESS), "fd_prestat_dir_name(3)")
    equal_str(t, mem_read_string(rt, OFF_PATH, 1u), "/", "preopen 3 is named \"/\"")
    equal(t, mem_read8(rt, OFF_PATH + 1u), 0u8, "the copied name keeps its NUL terminator")

    equal(t, call_prestat_dir_name(t, rt, token, 4u, OFF_PATH, 3u), u32(WASI_ERRNO_SUCCESS), "fd_prestat_dir_name(4)")
    equal_str(t, mem_read_string(rt, OFF_PATH, 2u), "./", "preopen 4 is named \"./\"")

    equal(t, call_prestat_dir_name(t, rt, token, 9u, OFF_PATH, 2u), u32(WASI_ERRNO_BADF), "fd_prestat_dir_name(9) is BADF")

    m3_FreeRuntime(rt)
}


// C fills __wasi_fdstat_t from fstat/fcntl and clears FD_SEEK|FD_TELL for
// descriptors 0..2 so they look like a TTY.
def test_fd_fdstat_get(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    let all_rights = 0xFFFFFFFFFFFFFFFFul
    let tty_rights = all_rights & ~(WASI_RIGHTS_FD_SEEK | WASI_RIGHTS_FD_TELL)

    for (fd in urange(3u)) {
        equal(t, call_fdstat_get(t, rt, token, fd, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get of a standard stream")
        equal(t, mem_read8(rt, OFF_OUT), WASI_FILETYPE_CHARACTER_DEVICE, "standard streams are character devices")
        equal(t, mem_read64(rt, OFF_OUT + 8u), tty_rights, "standard streams have no FD_SEEK/FD_TELL")
        equal(t, mem_read64(rt, OFF_OUT + 16u), all_rights, "fs_rights_inheriting is all rights")
    }

    equal(t, preopen[3].fd, 3, "m3_LinkWASI's loop opened preopen 3 as descriptor 3")
    equal(t, call_fdstat_get(t, rt, token, 3u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get(3)")
    equal(t, mem_read8(rt, OFF_OUT), WASI_FILETYPE_DIRECTORY, "a preopen is a directory")
    equal(t, mem_read64(rt, OFF_OUT + 8u), all_rights, "a preopen keeps FD_SEEK/FD_TELL")

    // C reaches this through fcntl(fd, F_GETFL) failing with EBADF.
    equal(t, call_fdstat_get(t, rt, token, 99u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_fdstat_get of an unknown fd is BADF")

    // C's fd_fdstat_set_flags is a "// TODO" that always succeeds.
    equal(t, call_fdstat_set_flags(t, rt, token, 1u, 1u), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_set_flags always succeeds")
    equal(t, call_fdstat_set_flags(t, rt, token, 99u, 0u), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_set_flags ignores a bad fd too")

    m3_FreeRuntime(rt)
}


// path_open resolves against the preopen, and a file opened through it
// reports REGULAR_FILE (over the fake file system).
def test_path_open(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, true)

    let fd = open_simple_txt(t, rt, token, 3u)
    check(t, fd != 0xFFFFFFFFu, "path_open of 0.txt through preopen 3")
    check(t, fd >= u32(PREOPEN_CNT), "a new fd comes after the preopens")

    equal(t, call_fdstat_get(t, rt, token, fd, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get of the opened file")
    equal(t, mem_read8(rt, OFF_OUT), WASI_FILETYPE_REGULAR_FILE, "an opened file is a regular file")

    equal(t, call_fd_close(t, rt, token, fd), u32(WASI_ERRNO_SUCCESS), "fd_close")
    // C's close() on an already closed descriptor returns -1, and the C
    // function passes that straight through instead of an errno.
    equal(t, call_fd_close(t, rt, token, fd), 0xFFFFFFFFu, "closing twice returns close()'s -1")

    // The other preopen names the same directory, so it opens the same file.
    let fd2 = open_simple_txt(t, rt, token, 4u)
    check(t, fd2 != 0xFFFFFFFFu, "path_open of 0.txt through preopen 4")
    equal(t, call_fd_close(t, rt, token, fd2), u32(WASI_ERRNO_SUCCESS), "fd_close")

    // C: openat() fails with ENOENT, which errno_to_wasi maps to NOENT.
    let missing_len = mem_write_string(rt, OFF_PATH, "wasm3c/test/wasi/simple/no-such-file.txt")
    equal(t, call_path_open(t, rt, token, 3u, OFF_PATH, missing_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_NOENT), "path_open of a missing file is NOENT")

    // C checks the 512-byte host_path buffer before touching the filesystem.
    equal(t, call_path_open(t, rt, token, 3u, OFF_PATH, 512u, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_INVAL), "path_len >= 512 is INVAL")

    // Eden: C's openat(preopen[1].fd = 1, ...) is ENOTDIR (upstream: its own
    // EBADF); a dirfd past the table is EBADF (C reads past it).
    let simple_len = mem_write_string(rt, OFF_PATH, SIMPLE_TXT)
    equal(t, call_path_open(t, rt, token, 1u, OFF_PATH, simple_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_NOTDIR), "path_open with a standard stream as dirfd is NOTDIR")
    equal(t, call_path_open(t, rt, token, 9u, OFF_PATH, simple_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_BADF), "path_open with a dirfd past the preopen table is BADF")

    m3_FreeRuntime(rt)
}


// fd_read fills the iovecs in order and stops after a short read, which is
// the non-HAS_IOVEC branch of the C function.
def test_fd_read(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, true)
    let fd = open_simple_txt(t, rt, token, 3u)
    check(t, fd != 0xFFFFFFFFu, "path_open of 0.txt")
    if (fd == 0xFFFFFFFFu) {
        m3_FreeRuntime(rt)
        return
    }

    // "Hello world" split over two iovecs: 5 bytes, then the remaining 6.
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 5u)
    mem_write_iovec(rt, OFF_IOVS, 1u, OFF_BUF1, 6u)
    equal(t, mem_read32(rt, OFF_IOVS + WASI_IOVEC_OFF_BUF_LEN), 5u, "the iovec array is where fd_read looks")
    equal(t, call_fd_read(t, rt, token, fd, OFF_IOVS, 2u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read of two iovecs")
    equal(t, mem_read32(rt, OFF_COUNT), 11u, "nread is the whole file")
    equal_str(t, mem_read_string(rt, OFF_BUF0, 5u), "Hello", "first iovec")
    equal_str(t, mem_read_string(rt, OFF_BUF1, 6u), " world", "second iovec")

    // At end of file the loop reads nothing and still succeeds.
    equal(t, call_fd_read(t, rt, token, fd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read at EOF")
    equal(t, mem_read32(rt, OFF_COUNT), 0u, "nread is 0 at EOF")

    // snapshot_preview1 whence: 0 = SET, 1 = CUR, 2 = END.
    equal(t, call_preview1_fd_seek(t, rt, token, fd, 6l, 0u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_seek SET 6")
    equal(t, mem_read64(rt, OFF_OUT), 6ul, "the new offset is written back as u64")
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 5u)
    equal(t, call_fd_read(t, rt, token, fd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read after seek")
    equal(t, mem_read32(rt, OFF_COUNT), 5u, "nread after seek")
    equal_str(t, mem_read_string(rt, OFF_BUF0, 5u), "world", "the tail of the file")

    // wasi_unstable numbers whence differently: 0 = CUR, 1 = END, 2 = SET.
    equal(t, call_unstable_fd_seek(t, rt, token, fd, 0l, 1u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "unstable fd_seek END 0")
    equal(t, mem_read64(rt, OFF_OUT), 11ul, "END lands on the file size")
    equal(t, call_unstable_fd_seek(t, rt, token, fd, 0l, 2u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "unstable fd_seek SET 0")
    equal(t, mem_read64(rt, OFF_OUT), 0ul, "SET 0 rewinds")
    equal(t, call_preview1_fd_seek(t, rt, token, fd, 0l, 7u, OFF_OUT), u32(WASI_ERRNO_INVAL), "an unknown whence is INVAL")

    // C: read() on an unknown descriptor fails with EBADF.
    equal(t, call_fd_read(t, rt, token, 99u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_read of an unknown fd is BADF")
    equal(t, call_preview1_fd_seek(t, rt, token, 99u, 0l, 0u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_seek of an unknown fd is BADF")

    equal(t, call_fd_close(t, rt, token, fd), u32(WASI_ERRNO_SUCCESS), "fd_close")
    equal(t, call_fd_read(t, rt, token, fd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_read after close is BADF")

    m3_FreeRuntime(rt)
}


// fd_write is the same loop in the other direction; the round trip proves
// path_open's create/truncate flags and fd_datasync (fake file system).
def test_fd_write(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, true)

    let path_len = mem_write_string(rt, OFF_PATH, SCRATCH_TXT)
    let oflags = u32(WASI_OFLAGS_CREAT) | u32(WASI_OFLAGS_TRUNC)
    let rights = WASI_RIGHTS_FD_READ | WASI_RIGHTS_FD_WRITE
    equal(t, call_path_open(t, rt, token, 3u, OFF_PATH, path_len, oflags, rights, 0u, OFF_OUT),
          u32(WASI_ERRNO_SUCCESS), "path_open with CREAT|TRUNC")
    let fd = mem_read32(rt, OFF_OUT)

    let head = mem_write_string(rt, OFF_BUF0, "Hello")
    let tail = mem_write_string(rt, OFF_BUF1, " world")
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, head)
    mem_write_iovec(rt, OFF_IOVS, 1u, OFF_BUF1, tail)
    equal(t, call_fd_write(t, rt, token, fd, OFF_IOVS, 2u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_write of two iovecs")
    equal(t, mem_read32(rt, OFF_COUNT), 11u, "nwritten is the sum of both iovecs")

    // C's fd_datasync is fdatasync(fd).
    equal(t, call_fd_datasync(t, rt, token, fd), u32(WASI_ERRNO_SUCCESS), "fd_datasync")
    equal(t, call_fd_close(t, rt, token, fd), u32(WASI_ERRNO_SUCCESS), "fd_close")

    // Read it back through a second path_open, so the bytes really landed.
    let reopen_len = mem_write_string(rt, OFF_PATH, SCRATCH_TXT)
    equal(t, call_path_open(t, rt, token, 3u, OFF_PATH, reopen_len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_SUCCESS), "path_open of the file just written")
    let rfd = mem_read32(rt, OFF_OUT)
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 11u)
    equal(t, call_fd_read(t, rt, token, rfd, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read of the round trip")
    equal(t, mem_read32(rt, OFF_COUNT), 11u, "the whole file came back")
    equal_str(t, mem_read_string(rt, OFF_BUF0, 11u), SIMPLE_TXT_BODY, "the round trip preserves the bytes")
    equal(t, call_fd_close(t, rt, token, rfd), u32(WASI_ERRNO_SUCCESS), "fd_close")
    let idx = fake_find(SCRATCH_TXT)
    check(t, idx != -1 && same_bytes(g_fake_files[idx].data, bytes_of(SIMPLE_TXT_BODY)), "the fake file system holds the bytes")

    // C: write() on an unknown descriptor fails with EBADF, but only once it
    // reaches a non-empty iovec.
    equal(t, call_fd_write(t, rt, token, 99u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_write of an unknown fd is BADF")
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 0u)
    equal(t, call_fd_write(t, rt, token, 99u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "only empty iovecs never reach write()")
    equal(t, mem_read32(rt, OFF_COUNT), 0u, "nwritten is 0")

    // A directory is fdatasync's -1 case here.
    equal(t, call_fd_datasync(t, rt, token, 3u), 0xFFFFFFFFu, "fd_datasync of a directory returns -1")

    m3_FreeRuntime(rt)
}


// The file the fake file system stands for must be the one the C WASI
// driver expects (read through the FixtureSource, not a file API).
def test_simple_txt_fixture(var t : TestRun; fx : FixtureSource) {
    let bytes <- load_fixture(fx, "wasi/simple/0.txt")
    equal(t, length(bytes), length(SIMPLE_TXT_BODY), "0.txt holds exactly \"Hello world\"")
    check(t, same_bytes(bytes, bytes_of(SIMPLE_TXT_BODY)), "0.txt is the body the fake file system seeds")
}


// ============================================================================
// Eden tests
// ============================================================================


def test_stdout_iovecs_nul(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    let part0 <- [0x61u8, 0x00u8, 0x62u8]       // "a\0b"
    let part1 <- [0x00u8]                       // "\0"
    let part2 <- [0xffu8, 0x63u8, 0x0au8]       // "\xffc\n"
    m3ApiWriteBytes(rt, int(OFF_BUF0), part0)
    m3ApiWriteBytes(rt, int(OFF_BUF1), part1)
    m3ApiWriteBytes(rt, int(OFF_BUF2), part2)
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 3u)
    mem_write_iovec(rt, OFF_IOVS, 1u, OFF_BUF1, 1u)
    mem_write_iovec(rt, OFF_IOVS, 2u, OFF_BUF2, 3u)
    equal(t, call_fd_write(t, rt, token, 1u, OFF_IOVS, 3u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_write(1) of three iovecs")
    equal(t, mem_read32(rt, OFF_COUNT), 7u, "nwritten counts every byte, NULs included")
    let want <- [0x61u8, 0x00u8, 0x62u8, 0x00u8, 0xffu8, 0x63u8, 0x0au8]
    check(t, same_bytes(rt.stdoutBuffer, want), "rt.stdoutBuffer holds the bytes exactly")
    equal(t, length(rt.stderrBuffer), 0, "stderr is untouched")

    equal(t, call_fd_write(t, rt, token, 2u, OFF_IOVS, 2u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_write(2)")
    equal(t, mem_read32(rt, OFF_COUNT), 4u, "nwritten of fd 2")
    let wantErr <- [0x61u8, 0x00u8, 0x62u8, 0x00u8]
    check(t, same_bytes(rt.stderrBuffer, wantErr), "rt.stderrBuffer holds the bytes exactly")
    equal(t, length(rt.stdoutBuffer), 7, "stdout is untouched by fd 2")
    m3_FreeRuntime(rt)
}


def test_stdin_read(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    rt.stdinBuffer <- [0x68u8, 0x69u8, 0x00u8, 0x21u8, 0x0au8]   // "hi\0!\n"
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 3u)
    mem_write_iovec(rt, OFF_IOVS, 1u, OFF_BUF1, 4u)
    mem_write_iovec(rt, OFF_IOVS, 2u, OFF_BUF2, 4u)
    equal(t, call_fd_read(t, rt, token, 0u, OFF_IOVS, 3u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read(0) of three iovecs")
    equal(t, mem_read32(rt, OFF_COUNT), 5u, "nread is what stdin held")
    let got0 <- m3ApiReadBytes(rt, int(OFF_BUF0), 3)
    let got1 <- m3ApiReadBytes(rt, int(OFF_BUF1), 2)
    let want0 <- [0x68u8, 0x69u8, 0x00u8]
    let want1 <- [0x21u8, 0x0au8]
    check(t, same_bytes(got0, want0), "the first iovec is full, NUL included")
    check(t, same_bytes(got1, want1), "the second iovec got the short rest")
    equal(t, mem_read8(rt, OFF_BUF2), 0u8, "the loop stopped after the short read")
    equal(t, length(rt.stdinBuffer), 0, "the read consumed rt.stdinBuffer")
    equal(t, call_fd_read(t, rt, token, 0u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "fd_read(0) at the end")
    equal(t, mem_read32(rt, OFF_COUNT), 0u, "nread is 0 at the end of stdin")
    m3_FreeRuntime(rt)
}


def test_bad_fd(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    mem_write_string(rt, OFF_BUF0, "x")
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 1u)
    equal(t, call_fd_write(t, rt, token, 42u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_write(42)")
    equal(t, call_fd_read(t, rt, token, 42u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_read(42)")
    equal(t, call_preview1_fd_seek(t, rt, token, 42u, 0l, 0u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_seek(42)")
    equal(t, call_fdstat_get(t, rt, token, 42u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_fdstat_get(42)")
    equal(t, call_fd_close(t, rt, token, 42u), 0xFFFFFFFFu, "fd_close(42) is close()'s -1")
    equal(t, call_fd_datasync(t, rt, token, 42u), 0xFFFFFFFFu, "fd_datasync(42) is fdatasync()'s -1")
    equal(t, call_fd_write(t, rt, token, 0u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "stdin is not writable")
    equal(t, call_fd_read(t, rt, token, 1u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "stdout is not readable")
    equal(t, length(rt.stdoutBuffer), 0, "nothing reached stdout")

    // a token that names no context has no descriptors
    equal(t, call_fd_write(t, rt, -1, 1u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_write without a context")
    equal(t, call_fdstat_get(t, rt, 1000000, 1u, OFF_OUT), u32(WASI_ERRNO_BADF), "fd_fdstat_get without a context")
    equal(t, call_prestat_get(t, rt, -1, 3u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_prestat_get reads only the preopen table")

    // a closed standard stream stays closed
    equal(t, call_fd_close(t, rt, token, 1u), u32(WASI_ERRNO_SUCCESS), "fd_close(1)")
    equal(t, call_fd_write(t, rt, token, 1u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_BADF), "fd_write(1) after close")
    m3_FreeRuntime(rt)
}


def test_iovec_out_of_bounds(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    let oob = m3Err_trapOutOfBoundsMemoryAccess
    mem_write_string(rt, OFF_BUF0, "abc")

    // the iovec array itself: 2 iovecs need 16 bytes, 8 are left
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_write, token, [1ul, 65528ul, 2ul, u64(OFF_COUNT)]), oob, "fd_write: iovec array past the end")
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_read, token, [0ul, 65528ul, 2ul, u64(OFF_COUNT)]), oob, "fd_read: iovec array past the end")

    // the count
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 3u)
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_write, token, [1ul, u64(OFF_IOVS), 1ul, 65533ul]), oob, "fd_write: nwritten past the end")

    // a buffer: the first iovec is in bounds, the second is not; C checks
    // each buffer just before its write, so the first write happened
    mem_write_iovec(rt, OFF_IOVS, 1u, 65530u, 10u)
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_write, token, [1ul, u64(OFF_IOVS), 2ul, u64(OFF_COUNT)]), oob, "fd_write: buffer past the end")
    equal(t, length(rt.stdoutBuffer), 3, "the in-bounds iovec before it was written (non-HAS_IOVEC order)")
    mem_write_iovec(rt, OFF_IOVS, 0u, 0xfffffff0u, 4u)
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_write, token, [1ul, u64(OFF_IOVS), 1ul, u64(OFF_COUNT)]), oob, "fd_write: buffer at 0xfffffff0")
    rt.stdinBuffer <- [1u8, 2u8]
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_read, token, [0ul, u64(OFF_IOVS), 1ul, u64(OFF_COUNT)]), oob, "fd_read: buffer at 0xfffffff0")
    equal(t, length(rt.stdinBuffer), 2, "the trap came before the read")

    // an empty iovec is skipped before its check (C: `if (len == 0) continue`)
    mem_write_iovec(rt, OFF_IOVS, 0u, 0xfffffff0u, 0u)
    equal(t, call_fd_write(t, rt, token, 1u, OFF_IOVS, 1u, OFF_COUNT), u32(WASI_ERRNO_SUCCESS), "an empty iovec out of bounds is skipped")
    equal(t, mem_read32(rt, OFF_COUNT), 0u, "nwritten is 0")

    // the other checked pointers
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_prestat_get, token, [3ul, 65532ul]), oob, "fd_prestat_get: buf past the end")
    is_err(t, call_raw(rt, @@m3_wasi_generic_fd_fdstat_get, token, [1ul, 65520ul]), oob, "fd_fdstat_get: fdstat past the end")
    is_err(t, call_raw(rt, @@m3_wasi_snapshot_preview1_fd_seek, token, [3ul, 0ul, 0ul, 65530ul]), oob, "fd_seek: result past the end")
    let bad_path <- path_open_args(3u, 65530u, 10u, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT)
    is_err(t, call_raw(rt, @@m3_wasi_generic_path_open, token, bad_path), oob, "path_open: path past the end")
    m3_FreeRuntime(rt)
}


def test_path_open_default(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let token = new_wasi(rt, false)
    let len = mem_write_string(rt, OFF_PATH, "missing.txt")
    equal(t, call_path_open(t, rt, token, 3u, OFF_PATH, len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_NOENT), "the default backend has no files: NOENT")
    let rw = WASI_RIGHTS_FD_READ | WASI_RIGHTS_FD_WRITE
    equal(t, call_path_open(t, rt, token, 4u, OFF_PATH, len, u32(WASI_OFLAGS_CREAT), rw, 0u, OFF_OUT),
          u32(WASI_ERRNO_NOENT), "nothing can be created: NOENT with O_CREAT too")
    equal(t, call_path_open(t, rt, token, 0u, OFF_PATH, len, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_NOTDIR), "stdin is not a directory")

    let dot = mem_write_string(rt, OFF_PATH, ".")
    equal(t, call_path_open(t, rt, token, 3u, OFF_PATH, dot, 0u, WASI_RIGHTS_FD_READ, 0u, OFF_OUT),
          u32(WASI_ERRNO_SUCCESS), "\".\" opens")
    equal(t, mem_read32(rt, OFF_OUT), 5u, "as the lowest free descriptor")
    equal(t, call_fdstat_get(t, rt, token, 5u, OFF_OUT), u32(WASI_ERRNO_SUCCESS), "fd_fdstat_get(5)")
    equal(t, mem_read8(rt, OFF_OUT), WASI_FILETYPE_DIRECTORY, "it is a directory")

    equal(t, call_preview1_fd_seek(t, rt, token, 0u, 0l, 1u, OFF_OUT), u32(WASI_ERRNO_SPIPE), "stdin does not seek")
    m3_FreeRuntime(rt)
}


// ============================================================================
// fd_write linked into a module (ctx.userdata is the context token)
// ============================================================================


def private leb(var out : array<u8>; value : uint) {
    var v = value
    while (true) {
        let b = v & 0x7fu
        v = v >> 7u
        if (v == 0u) {
            push(out, u8(b))
            break
        }
        push(out, u8(b | 0x80u))
    }
}


def private name(var out : array<u8>; text : string) {
    leb(out, uint(length(text)))
    for (i in range(length(text))) {
        push(out, u8(character_at(text, i)))
    }
}


def private section(var out : array<u8>; id : int; content : array<u8>) {
    push(out, u8(id))
    leb(out, uint(length(content)))
    for (b in content) {
        push(out, b)
    }
}


/*
    (module
      (import "wasi_snapshot_preview1" "fd_write" (func $w (param i32 i32 i32 i32) (result i32)))
      (memory 1)
      (func (export "run") (param i32 i32 i32 i32) (result i32)
        (call $w (local.get 0) (local.get 1) (local.get 2) (local.get 3))))
*/
def private fd_write_module() : array<u8> {
    var out : array<u8>
    for (b in [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8]) {
        push(out, b)
    }
    var types : array<u8>
    leb(types, 1u)
    push(types, 0x60u8)
    leb(types, 4u)
    for (k in range(4)) {
        push(types, 0x7fu8)
    }
    leb(types, 1u)
    push(types, 0x7fu8)
    section(out, 1, types)

    var imports : array<u8>
    leb(imports, 1u)
    name(imports, "wasi_snapshot_preview1")
    name(imports, "fd_write")
    push(imports, 0x00u8)
    leb(imports, 0u)
    section(out, 2, imports)

    var funcs : array<u8>
    leb(funcs, 1u)
    leb(funcs, 0u)
    section(out, 3, funcs)

    var mems : array<u8>
    leb(mems, 1u)
    push(mems, 0x00u8)
    leb(mems, 1u)
    section(out, 5, mems)

    var exports : array<u8>
    leb(exports, 1u)
    name(exports, "run")
    push(exports, 0x00u8)
    leb(exports, 1u)
    section(out, 7, exports)

    var body : array<u8>
    leb(body, 0u)
    for (i in range(4)) {
        push(body, 0x20u8)
        leb(body, uint(i))
    }
    push(body, 0x10u8)
    leb(body, 0u)
    push(body, 0x0bu8)
    var code : array<u8>
    leb(code, 1u)
    leb(code, uint(length(body)))
    for (b in body) {
        push(code, b)
    }
    section(out, 10, code)
    return <- out
}


def test_linked_fd_write(var t : TestRun; fx : FixtureSource) {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    let bytes <- fd_write_module()
    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "the hand-built module parses")
    if (parsed._0 != m3Err_none) {
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LoadModule(rt, parsed._1), "m3_LoadModule")
    let token = m3_NewWasiContext()
    wasi_fd_open_preopens(rt, token)
    is_ok(t, m3_LinkRawFunctionEx(rt, parsed._1, "wasi_snapshot_preview1", "fd_write", "i(i*i*)", @@m3_wasi_generic_fd_write, token),
          "link fd_write with the context token")
    var run : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, run, "run"), "m3_FindFunction run")
    if (run == -1) {
        m3_FreeRuntime(rt)
        return
    }

    let text <- [0x6fu8, 0x6bu8, 0x00u8, 0x0au8]   // "ok\0\n"
    m3ApiWriteBytes(rt, int(OFF_BUF0), text)
    mem_write_iovec(rt, OFF_IOVS, 0u, OFF_BUF0, 4u)
    is_ok(t, m3_Call(rt, run, [1ul, u64(OFF_IOVS), 1ul, u64(OFF_COUNT)]), "m3_Call run(1, iovs, 1, count)")
    var out : array<u64>
    is_ok(t, m3_GetResults(rt, run, 1u, out), "m3_GetResults")
    if (length(out) == 1) {
        equal(t, u32(out[0] & 0xfffffffful), u32(WASI_ERRNO_SUCCESS), "fd_write returned SUCCESS to wasm")
    }
    equal(t, mem_read32(rt, OFF_COUNT), 4u, "nwritten through the linked call")
    check(t, same_bytes(rt.stdoutBuffer, text), "the linked call wrote rt.stdoutBuffer byte for byte")

    is_err(t, m3_Call(rt, run, [1ul, 65532ul, 1ul, u64(OFF_COUNT)]), m3Err_trapOutOfBoundsMemoryAccess,
           "an out-of-bounds iovec array traps out of m3_Call")
    m3_FreeRuntime(rt)
}


def public run_tests_m3_api_wasi_fd(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_errno_to_wasi")
    test_errno_to_wasi(t, fx)
    begin_test(t, "test_fd_prestat")
    test_fd_prestat(t, fx)
    begin_test(t, "test_fd_fdstat_get")
    test_fd_fdstat_get(t, fx)
    begin_test(t, "test_path_open")
    test_path_open(t, fx)
    begin_test(t, "test_fd_read")
    test_fd_read(t, fx)
    begin_test(t, "test_fd_write")
    test_fd_write(t, fx)
    begin_test(t, "test_simple_txt_fixture")
    test_simple_txt_fixture(t, fx)
    begin_test(t, "test_stdout_iovecs_nul")
    test_stdout_iovecs_nul(t, fx)
    begin_test(t, "test_stdin_read")
    test_stdin_read(t, fx)
    begin_test(t, "test_bad_fd")
    test_bad_fd(t, fx)
    begin_test(t, "test_iovec_out_of_bounds")
    test_iovec_out_of_bounds(t, fx)
    begin_test(t, "test_path_open_default")
    test_path_open_default(t, fx)
    begin_test(t, "test_linked_fd_write")
    test_linked_fd_write(t, fx)
}
