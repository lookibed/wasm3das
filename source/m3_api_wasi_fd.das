options gen2
options indenting = 4
// Host functions run once per import call, not per wasm operation:
// automatic inlining costs startup only.
options never_inline = true

module m3_api_wasi_fd shared public

require ./m3_api_defs.das public
require ./wasi_core.das public
require daslib/fio
require daslib/strings
require math


/*
    Conservative Gen2 port of the file-descriptor half of m3_api_wasi.c:
    the Preopen table, errno_to_wasi, the fd_* raw functions and path_open.

    The core half of the same C file (the context, args_*, environ_*,
    clock_*, random_get, proc_exit, m3_GetWasiContext and m3_LinkWASI) lives
    in m3_api_wasi.das and requires this module by the C names below.

    C-macro adaptations, applied once here (see m3_api_defs.das):
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list
      (runtime, _ctx, _sp, _mem); the port spells that list out.
    - the C macros advance `_sp` in place; M3RawCall declares `_sp` const, so
      every function starts from a mutable copy `sp` of it.
    - m3ApiReturn(VALUE) is m3ApiReturn_u32(raw_return, VALUE) followed by
      `return m3Err_none`; m3ApiCheckMem returns the trap result to the caller.
    - C's `buf + N` pointer arithmetic inside linear memory is spelled
      m3ApiOffsetToPtr(buf, N), which is exactly base + offset.

    THE DESCRIPTOR LAYER — the one structural deviation from C.

    C works on raw POSIX descriptors: the WASI fd *is* the host fd, produced
    by open()/openat() and consumed by read/write/lseek/close. Daslang has no
    open()/read()/write(); the only file API is `fio`, whose handle is an
    opaque `file` (a C FILE*). The port therefore keeps a descriptor table in
    this module, `wasi_fds`, and the WASI fd is the table index:

        0, 1, 2   the standard streams, fstdin()/fstdout()/fstderr()
        3, 4      the preopened directories of the C `preopen` table,
                  which carry a real path and no host handle
        5...      files opened by path_open, in the lowest free slot, which
                  is what openat() would have returned

    Consequences, each also noted at its site:
    - C's `preopen[i].fd = open(preopen[i].real_path, O_RDONLY)` loop in
      m3_LinkWASI has no equivalent, because a directory needs no host
      handle here. wasi_fd_open_preopens() takes its place and m3_LinkWASI
      calls it there.
    - path_open resolves the path against preopen[dirfd].real_path instead
      of passing preopen[dirfd].fd to openat().
    - there is no errno. errno_to_wasi is ported in full and called with the
      errno the failing C call would have set; where fio loses the
      distinction the choice is documented at the call site.
    - fio_core::fseek returns 0/-1 like fseek(3), not the new offset like
      lseek(2), so fd_seek reads the offset back with ftell.
*/


// The <errno.h> values errno_to_wasi switches on, in C order. Linux/glibc
// asm-generic numbering, the platform this port targets.
let private EPERM = 1
let private ENOENT = 2
let private ESRCH = 3
let private EINTR = 4
let private EIO = 5
let private ENXIO = 6
let private E2BIG = 7
let private ENOEXEC = 8
let private EBADF = 9
let private ECHILD = 10
let private EAGAIN = 11
let private ENOMEM = 12
let private EACCES = 13
let private EFAULT = 14
let private EBUSY = 16
let private EEXIST = 17
let private EXDEV = 18
let private ENODEV = 19
let private ENOTDIR = 20
let private EISDIR = 21
let private EINVAL = 22
let private ENFILE = 23
let private EMFILE = 24
let private ENOTTY = 25
let private ETXTBSY = 26
let private EFBIG = 27
let private ENOSPC = 28
let private ESPIPE = 29
let private EROFS = 30
let private EMLINK = 31
let private EPIPE = 32
let private EDOM = 33
let private ERANGE = 34


// ============================================================================
// Preopen table
// ============================================================================


// C: #define PREOPEN_CNT 5
let public PREOPEN_CNT = 5


// C: typedef struct Preopen { int fd; const char* path; const char* real_path; } Preopen;
struct public Preopen {
    fd : int
    path : string
    real_path : string
}


/*  C:
        Preopen preopen[PREOPEN_CNT] = {
            {  0, "<stdin>" , "" },
            {  1, "<stdout>", "" },
            {  2, "<stderr>", "" },
            { -1, "/"       , "." },
            { -1, "./"      , "." },
        };
    The -1 entries are filled in by m3_LinkWASI; here by
    wasi_fd_open_preopens(). */
var public preopen = [
    Preopen(fd = 0, path = "<stdin>", real_path = ""),
    Preopen(fd = 1, path = "<stdout>", real_path = ""),
    Preopen(fd = 2, path = "<stderr>", real_path = ""),
    Preopen(fd = -1, path = "/", real_path = "."),
    Preopen(fd = -1, path = "./", real_path = ".")
]


// ============================================================================
// The descriptor table (no C counterpart; see the file comment)
// ============================================================================


enum WasiFdKind {
    wasi_fd_free
    wasi_fd_stdin
    wasi_fd_stdout
    wasi_fd_stderr
    wasi_fd_directory
    wasi_fd_file
}


struct WasiFdEntry {
    kind : WasiFdKind
    // The host stream. Null for a free slot and for a preopened directory,
    // which C represents with a descriptor from open(path, O_RDONLY) that it
    // only ever passes to openat().
    f : file
    // The host path: real_path for a directory, the opened path for a file.
    path : string
}


var private wasi_fds : array<WasiFdEntry>


def private wasi_fd_alloc(kind : WasiFdKind; f : file; path : string) : int {
    // C gets the descriptor from openat(), which returns the lowest unused
    // host descriptor. Here the WASI fd is the table index, so the lowest
    // free slot at or above PREOPEN_CNT plays exactly that role.
    for (i in PREOPEN_CNT..length(wasi_fds)) {
        if (wasi_fds[i].kind == WasiFdKind.wasi_fd_free) {
            wasi_fds[i].kind = kind
            wasi_fds[i].f = f
            wasi_fds[i].path = path
            return i
        }
    }
    wasi_fds |> push(WasiFdEntry(kind = kind, f = f, path = path))
    return length(wasi_fds) - 1
}


def private wasi_fd_kind(fd : u32) : WasiFdKind {
    if (fd >= u32(length(wasi_fds))) {
        return WasiFdKind.wasi_fd_free
    }
    return wasi_fds[int(fd)].kind
}


/*  m3ApiCheckMem takes its runtime by mutable reference, because the
    m3_GetMemorySize it calls does; the M3RawCall signature hands `runtime`
    over as a const variable, so every call site would need its own mutable
    copy. This adapter makes that copy once. The C macro reads
    m3ApiCheckMem(addr, len) at every site below, and the fix belongs in
    m3_api_defs.das/m3_env.das, where neither function mutates the runtime
    (C: `uint32_t m3_GetMemorySize (IM3Runtime i_runtime)`). */
def private wasi_check_mem(runtime : IM3Runtime; _mem : void?; _addr : void?; len : u64) : M3Result {
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    return m3ApiCheckMem(rt, _mem, _addr, len)
}


// The host stream behind a WASI fd, or null when there is none: a free slot,
// an out-of-range index, or a preopened directory. Every C call that takes a
// raw fd (read, write, lseek, fdatasync) fails with EBADF in those cases.
def private wasi_fd_handle(fd : u32) : file {
    if (wasi_fd_kind(fd) == WasiFdKind.wasi_fd_free) {
        return null
    }
    return wasi_fds[int(fd)].f
}


// ============================================================================
// errno_to_wasi
// ============================================================================


// C writes this as a switch; daslang has no switch over integers, so the
// APE_CASE_RET chain becomes an if/else chain in the same order.
def public errno_to_wasi(errnum : int) : uint16 {
    if (errnum == EPERM) { return WASI_ERRNO_PERM }
    elif (errnum == ENOENT) { return WASI_ERRNO_NOENT }
    elif (errnum == ESRCH) { return WASI_ERRNO_SRCH }
    elif (errnum == EINTR) { return WASI_ERRNO_INTR }
    elif (errnum == EIO) { return WASI_ERRNO_IO }
    elif (errnum == ENXIO) { return WASI_ERRNO_NXIO }
    elif (errnum == E2BIG) { return WASI_ERRNO_2BIG }
    elif (errnum == ENOEXEC) { return WASI_ERRNO_NOEXEC }
    elif (errnum == EBADF) { return WASI_ERRNO_BADF }
    elif (errnum == ECHILD) { return WASI_ERRNO_CHILD }
    elif (errnum == EAGAIN) { return WASI_ERRNO_AGAIN }
    elif (errnum == ENOMEM) { return WASI_ERRNO_NOMEM }
    elif (errnum == EACCES) { return WASI_ERRNO_ACCES }
    elif (errnum == EFAULT) { return WASI_ERRNO_FAULT }
    elif (errnum == EBUSY) { return WASI_ERRNO_BUSY }
    elif (errnum == EEXIST) { return WASI_ERRNO_EXIST }
    elif (errnum == EXDEV) { return WASI_ERRNO_XDEV }
    elif (errnum == ENODEV) { return WASI_ERRNO_NODEV }
    elif (errnum == ENOTDIR) { return WASI_ERRNO_NOTDIR }
    elif (errnum == EISDIR) { return WASI_ERRNO_ISDIR }
    elif (errnum == EINVAL) { return WASI_ERRNO_INVAL }
    elif (errnum == ENFILE) { return WASI_ERRNO_NFILE }
    elif (errnum == EMFILE) { return WASI_ERRNO_MFILE }
    elif (errnum == ENOTTY) { return WASI_ERRNO_NOTTY }
    elif (errnum == ETXTBSY) { return WASI_ERRNO_TXTBSY }
    elif (errnum == EFBIG) { return WASI_ERRNO_FBIG }
    elif (errnum == ENOSPC) { return WASI_ERRNO_NOSPC }
    elif (errnum == ESPIPE) { return WASI_ERRNO_SPIPE }
    elif (errnum == EROFS) { return WASI_ERRNO_ROFS }
    elif (errnum == EMLINK) { return WASI_ERRNO_MLINK }
    elif (errnum == EPIPE) { return WASI_ERRNO_PIPE }
    elif (errnum == EDOM) { return WASI_ERRNO_DOM }
    elif (errnum == ERANGE) { return WASI_ERRNO_RANGE }
    return WASI_ERRNO_INVAL
}


// ============================================================================
// The preopen hook m3_LinkWASI calls in place of C's open() loop
// ============================================================================


/*  C, in m3_LinkWASI:

        // Preopen dirs
        for (int i = 3; i < PREOPEN_CNT; i++) {
            preopen[i].fd = open(preopen[i].real_path, O_RDONLY);
        }

    The port has no open() and needs no handle for a directory, so this fills
    the descriptor table instead: slots 0..2 are the standard streams and
    slots 3..PREOPEN_CNT-1 the preopened directories, each carrying the C
    real_path that path_open resolves against. preopen[i].fd is set to i,
    the value openat() would be given.

    C re-runs its loop on every m3_LinkWASI call and leaks the previous
    descriptors; this is idempotent instead, so linking a second module does
    not invalidate fds the first one opened. */
def public wasi_fd_open_preopens() {
    if (length(wasi_fds) >= PREOPEN_CNT) {
        return
    }
    wasi_fds |> clear()
    wasi_fds |> reserve(PREOPEN_CNT)

    wasi_fds |> push(WasiFdEntry(kind = WasiFdKind.wasi_fd_stdin, f = fstdin(), path = preopen[0].path))
    wasi_fds |> push(WasiFdEntry(kind = WasiFdKind.wasi_fd_stdout, f = fstdout(), path = preopen[1].path))
    wasi_fds |> push(WasiFdEntry(kind = WasiFdKind.wasi_fd_stderr, f = fstderr(), path = preopen[2].path))

    for (i in 3..PREOPEN_CNT) {
        wasi_fds |> push(WasiFdEntry(kind = WasiFdKind.wasi_fd_directory, f = null, path = preopen[i].real_path))
        preopen[i].fd = i
    }
}


// ============================================================================
// WASI API implementation (file descriptors)
// ============================================================================


def public m3_wasi_generic_fd_prestat_dir_name(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let path = m3ApiGetArgMem(sp, _mem)
    let path_len = m3ApiGetArg_u32(sp)

    let check : M3Result = wasi_check_mem(runtime, _mem, path, u64(path_len))
    if (check != m3Err_none) { return check }

    if (fd < 3u || fd >= u32(PREOPEN_CNT)) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_BADF))
        return m3Err_none
    }
    let name = preopen[int(fd)].path
    let slen = long_length(name) + 1l // C: strlen(preopen[fd].path) + 1
    // C: memcpy(path, preopen[fd].path, M3_MIN(slen, path_len)). The port
    // copies the same byte count one byte at a time, over the string's own
    // byte data; the byte at index long_length(name) is the NUL terminator
    // that strlen()+1 accounts for and that peek_data does not carry.
    let count = min(slen, int64(path_len))
    peek_data(name) $(data : array<uint8>#) {
        for (i in 0l..count) {
            let b = i < long_length(data) ? data[int(i)] : uint8(0)
            m3ApiWriteMem8(m3ApiOffsetToPtr(path, u32(i)), b)
        }
    }
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_prestat_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let buf = m3ApiGetArgMem(sp, _mem)

    let check : M3Result = wasi_check_mem(runtime, _mem, buf, u64(WASI_PRESTAT_SIZE))
    if (check != m3Err_none) { return check }

    if (fd < 3u || fd >= u32(PREOPEN_CNT)) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_BADF))
        return m3Err_none
    }

    // C writes the one-byte prestat tag with a 32-bit store, so the three
    // padding bytes before the name length are zeroed; keep that.
    m3ApiWriteMem32(m3ApiOffsetToPtr(buf, WASI_PRESTAT_OFF_PR_TYPE), u32(WASI_PREOPENTYPE_DIR))
    m3ApiWriteMem32(m3ApiOffsetToPtr(buf, WASI_PRESTAT_OFF_U + WASI_PRESTAT_DIR_OFF_PR_NAME_LEN),
                    u32(length(preopen[int(fd)].path)) + 1u)
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_fdstat_get(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let fdstat = m3ApiGetArgMem(sp, _mem)

    // C: m3ApiCheckMem(fdstat, sizeof(__wasi_fdstat_t)). The field offsets
    // used below are the ones wasi_core.h asserts.
    let check : M3Result = wasi_check_mem(runtime, _mem, fdstat, u64(WASI_FDSTAT_SIZE))
    if (check != m3Err_none) { return check }

    // C calls fcntl(fd, F_GETFL) and returns errno_to_wasi(errno) when it
    // fails, which for an unknown descriptor is EBADF.
    let kind = wasi_fd_kind(fd)
    if (kind == WasiFdKind.wasi_fd_free) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EBADF)))
        return m3Err_none
    }

    // C derives fs_filetype from fstat's st_mode. The descriptor table knows
    // the kind directly: the standard streams stand in for S_ISCHR, the
    // preopens for S_ISDIR and everything path_open produced for S_ISREG.
    var fs_filetype = WASI_FILETYPE_REGULAR_FILE
    if (kind == WasiFdKind.wasi_fd_directory) {
        fs_filetype = WASI_FILETYPE_DIRECTORY
    } elif (kind != WasiFdKind.wasi_fd_file) {
        fs_filetype = WASI_FILETYPE_CHARACTER_DEVICE
    }
    m3ApiWriteMem8(m3ApiOffsetToPtr(fdstat, WASI_FDSTAT_OFF_FS_FILETYPE), fs_filetype)

    // C maps the fcntl status flags (O_APPEND, O_DSYNC, O_NONBLOCK, O_SYNC)
    // into fs_flags. fio exposes no such query, so the port reports none;
    // wasi-libc only reads this field to detect O_APPEND, which the port
    // never reports set because it never leaves a stream in append mode
    // without the guest having asked for it in path_open.
    m3ApiWriteMem16(m3ApiOffsetToPtr(fdstat, WASI_FDSTAT_OFF_FS_FLAGS), uint16(0))

    var fs_rights_base = 0xFFFFFFFFFFFFFFFFul // all rights
    // C: make descriptors 0,1,2 look like a TTY
    if (fd <= 2u) {
        fs_rights_base &= ~(WASI_RIGHTS_FD_SEEK | WASI_RIGHTS_FD_TELL)
    }
    m3ApiWriteMem64(m3ApiOffsetToPtr(fdstat, WASI_FDSTAT_OFF_FS_RIGHTS_BASE), fs_rights_base)
    m3ApiWriteMem64(m3ApiOffsetToPtr(fdstat, WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING), 0xFFFFFFFFFFFFFFFFul) // all rights
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_fdstat_set_flags(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    // C reads both arguments and does nothing with them ("// TODO"); the
    // reads still have to happen, because they are what advances _sp.
    m3ApiGetArg_u32(sp) // __wasi_fd_t fd
    m3ApiGetArg_u32(sp) // __wasi_fdflags_t flags

    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// The two fd_seek flavours differ only in the whence encoding: wasi_unstable
// numbered it CUR/END/SET, wasi_snapshot_preview1 SET/CUR/END.
def public m3_wasi_unstable_fd_seek(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let offset = m3ApiGetArg_i64(sp)
    let wasi_whence = m3ApiGetArg_u32(sp)
    let result = m3ApiGetArgMem(sp, _mem)

    let check : M3Result = wasi_check_mem(runtime, _mem, result, 8ul) // sizeof(__wasi_filesize_t)
    if (check != m3Err_none) { return check }

    var whence = 0
    if (wasi_whence == 0u) { whence = seek_cur }
    elif (wasi_whence == 1u) { whence = seek_end }
    elif (wasi_whence == 2u) { whence = seek_set }
    else {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    return wasi_fd_seek_common(raw_return, fd, offset, whence, result)
}


def public m3_wasi_snapshot_preview1_fd_seek(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let offset = m3ApiGetArg_i64(sp)
    let wasi_whence = m3ApiGetArg_u32(sp)
    let result = m3ApiGetArgMem(sp, _mem)

    let check : M3Result = wasi_check_mem(runtime, _mem, result, 8ul) // sizeof(__wasi_filesize_t)
    if (check != m3Err_none) { return check }

    var whence = 0
    if (wasi_whence == 0u) { whence = seek_set }
    elif (wasi_whence == 1u) { whence = seek_cur }
    elif (wasi_whence == 2u) { whence = seek_end }
    else {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    return wasi_fd_seek_common(raw_return, fd, offset, whence, result)
}


/*  The tail both fd_seek flavours share. C is one statement:

        ret = lseek(fd, offset, whence);
        if (ret < 0) { m3ApiReturn(errno_to_wasi(errno)); }
        m3ApiWriteMem64(result, ret);

    fio_core::fseek is fseek(3): it returns 0 or -1, not the new offset, so
    the offset is read back with ftell. fseek(3) also discards errno; a
    handle that is open can only fail here on a negative resulting offset
    (EINVAL) or on a pipe (ESPIPE), and EINVAL is the one the guest can
    provoke, so that is what the port reports. */
def private wasi_fd_seek_common(raw_return : u64?; fd : u32; offset : i64; whence : int; result : void?) : M3Result {
    let f = wasi_fd_handle(fd)
    if (f == null) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EBADF)))
        return m3Err_none
    }
    if (fseek(f, offset, whence) != 0l) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EINVAL)))
        return m3Err_none
    }
    let ret = ftell(f)
    if (ret < 0l) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EINVAL)))
        return m3Err_none
    }
    m3ApiWriteMem64(result, u64(ret))
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_path_open(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let dirfd = m3ApiGetArg_u32(sp)
    // C reads dirflags (__WASI_LOOKUPFLAGS_SYMLINK_FOLLOW) and never uses it.
    m3ApiGetArg_u32(sp) // __wasi_lookupflags_t dirflags
    let path = m3ApiGetArgMem(sp, _mem)
    let path_len = m3ApiGetArg_u32(sp)
    let oflags = m3ApiGetArg_u32(sp)
    let fs_rights_base = m3ApiGetArg_u64(sp)
    // C reads fs_rights_inheriting and never uses it.
    m3ApiGetArg_u64(sp) // __wasi_rights_t fs_rights_inheriting
    let fs_flags = m3ApiGetArg_u32(sp)
    let fd = m3ApiGetArgMem(sp, _mem)

    var check : M3Result = wasi_check_mem(runtime, _mem, path, u64(path_len))
    if (check != m3Err_none) { return check }
    check = wasi_check_mem(runtime, _mem, fd, 4ul) // sizeof(__wasi_fd_t)
    if (check != m3Err_none) { return check }

    if (path_len >= 512u) {
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    // C copies the path into a stack buffer and appends the NUL terminator
    // openat() needs; string(array<u8>) carries its own length, so the
    // terminator is implicit here.
    var path_bytes : array<u8>
    path_bytes |> resize(int(path_len))
    if (path_len != 0u) {
        unsafe {
            memcpy(addr<void?>(path_bytes[0]), path, path_len)
        }
    }
    let host_path = string(path_bytes)

    // C: openat(preopen[dirfd].fd, host_path, flags, mode). C does not range
    // check dirfd and reads past the preopen array for an invalid one; the
    // port checks, because the equivalent daslang read would trap.
    if (dirfd >= u32(PREOPEN_CNT) || wasi_fd_kind(dirfd) != WasiFdKind.wasi_fd_directory) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EBADF)))
        return m3Err_none
    }
    let real_path = preopen[int(dirfd)].real_path
    let full_path = real_path == "" ? host_path : "{real_path}/{host_path}"

    // C translates oflags/fs_flags/fs_rights_base into open(2) flags. fio has
    // only fopen(3) modes, so the same decision produces a mode string; every
    // arm below is the mode with the open(2) semantics of the C flag set.
    // O_DSYNC, O_NONBLOCK and O_SYNC have no fopen equivalent and are
    // dropped; they only affect flushing behaviour the port does not promise.
    let creat = (oflags & u32(WASI_OFLAGS_CREAT)) != 0u
    let excl = (oflags & u32(WASI_OFLAGS_EXCL)) != 0u
    let trunc = (oflags & u32(WASI_OFLAGS_TRUNC)) != 0u
    let want_dir = (oflags & u32(WASI_OFLAGS_DIRECTORY)) != 0u
    let append = (fs_flags & u32(WASI_FDFLAGS_APPEND)) != 0u
    let rd = (fs_rights_base & WASI_RIGHTS_FD_READ) != 0ul
    let wr = (fs_rights_base & WASI_RIGHTS_FD_WRITE) != 0ul

    var st : FStat
    let exists = stat(full_path, st)
    let is_dir = exists && st.is_dir

    // A directory: fopen(3) on Linux succeeds for a directory but every read
    // then fails with EISDIR, so a directory becomes a handle-less table
    // entry, like the preopens.
    if (want_dir || is_dir) {
        if (!is_dir) {
            m3ApiReturn_u32(raw_return, u32(errno_to_wasi(exists ? ENOTDIR : ENOENT)))
            return m3Err_none
        }
        let dir_fd = wasi_fd_alloc(WasiFdKind.wasi_fd_directory, null, full_path)
        m3ApiWriteMem32(fd, u32(dir_fd))
        m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
        return m3Err_none
    }

    // O_EXCL and the missing-file case, which fopen(3) cannot distinguish
    // after the fact because it reports no errno.
    if (creat && excl && exists) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EEXIST)))
        return m3Err_none
    }
    if (!creat && !exists) {
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(ENOENT)))
        return m3Err_none
    }

    var mode = "rb" // O_RDONLY
    if (wr) {
        if (append) {
            mode = rd ? "a+b" : "ab" // O_APPEND
        } elif (trunc) {
            mode = rd ? "w+b" : "wb" // O_TRUNC
        } elif (creat && !exists) {
            mode = rd ? "w+b" : "wb" // O_CREAT on a file that is not there
        } else {
            // O_WRONLY/O_RDWR on an existing file, no truncation. fopen has
            // no write-only mode that keeps the contents; "r+b" is the one
            // with open(2)'s semantics, and the extra read capability is
            // invisible to a guest whose rights do not include FD_READ.
            mode = "r+b"
        }
    }

    let f = fopen(full_path, mode)
    if (f == null) {
        // C: m3ApiReturn(errno_to_wasi(errno)). fopen(3) reports no errno
        // here; the file existed or was creatable a moment ago, so what is
        // left is a permission or path problem, reported as C would report
        // the common one.
        m3ApiReturn_u32(raw_return, u32(errno_to_wasi(ENOENT)))
        return m3Err_none
    }
    let host_fd = wasi_fd_alloc(WasiFdKind.wasi_fd_file, f, full_path)
    m3ApiWriteMem32(fd, u32(host_fd))
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


/*  fd_read and fd_write below are the non-HAS_IOVEC branch of the C
    functions: one read/write per iovec, stopping after a short transfer.
    Daslang has no readv/writev, and wasm3 already ships this branch for the
    platforms without <sys/uio.h>, so the port selects an existing C path
    rather than inventing one. The observable difference is on a pipe, where
    readv returns whatever is available in one syscall; fread(3) blocks until
    the buffer is full or the stream ends. */
def public m3_wasi_generic_fd_read(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let wasi_iovs = m3ApiGetArgMem(sp, _mem)
    let iovs_len = m3ApiGetArg_u32(sp)
    let nread = m3ApiGetArgMem(sp, _mem)

    // C: m3ApiCheckMem(wasi_iovs, iovs_len * sizeof(wasi_iovec_t)).
    var check : M3Result = wasi_check_mem(runtime, _mem, wasi_iovs, u64(iovs_len) * u64(WASI_IOVEC_SIZE))
    if (check != m3Err_none) { return check }
    check = wasi_check_mem(runtime, _mem, nread, 4ul) // sizeof(__wasi_size_t)
    if (check != m3Err_none) { return check }

    var res = 0
    for (i in urange(iovs_len)) {
        let iov = m3ApiOffsetToPtr(wasi_iovs, i * WASI_IOVEC_SIZE)
        let buf_addr = m3ApiOffsetToPtr(_mem, m3ApiReadMem32(m3ApiOffsetToPtr(iov, WASI_IOVEC_OFF_BUF)))
        let len = m3ApiReadMem32(m3ApiOffsetToPtr(iov, WASI_IOVEC_OFF_BUF_LEN))
        if (len == 0u) { continue }
        check = wasi_check_mem(runtime, _mem, buf_addr, u64(len))
        if (check != m3Err_none) { return check }
        // C: read(fd, addr, len). The lookup is inside the loop because C
        // only reaches read() for a non-empty iovec, so a bad fd with only
        // empty iovecs succeeds there too.
        let f = wasi_fd_handle(fd)
        if (f == null) {
            m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EBADF)))
            return m3Err_none
        }
        var ret = 0
        unsafe {
            ret = _builtin_read(f, reinterpret<u8?>(buf_addr), int(len))
        }
        if (ret < 0) {
            m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EIO)))
            return m3Err_none
        }
        res += ret
        if (u32(ret) < len) { break }
    }
    m3ApiWriteMem32(nread, u32(res))
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_write(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)
    let wasi_iovs = m3ApiGetArgMem(sp, _mem)
    let iovs_len = m3ApiGetArg_u32(sp)
    let nwritten = m3ApiGetArgMem(sp, _mem)

    var check : M3Result = wasi_check_mem(runtime, _mem, wasi_iovs, u64(iovs_len) * u64(WASI_IOVEC_SIZE))
    if (check != m3Err_none) { return check }
    check = wasi_check_mem(runtime, _mem, nwritten, 4ul) // sizeof(__wasi_size_t)
    if (check != m3Err_none) { return check }

    var res = 0
    for (i in urange(iovs_len)) {
        let iov = m3ApiOffsetToPtr(wasi_iovs, i * WASI_IOVEC_SIZE)
        let buf_addr = m3ApiOffsetToPtr(_mem, m3ApiReadMem32(m3ApiOffsetToPtr(iov, WASI_IOVEC_OFF_BUF)))
        let len = m3ApiReadMem32(m3ApiOffsetToPtr(iov, WASI_IOVEC_OFF_BUF_LEN))
        if (len == 0u) { continue }
        check = wasi_check_mem(runtime, _mem, buf_addr, u64(len))
        if (check != m3Err_none) { return check }
        let f = wasi_fd_handle(fd)
        if (f == null) {
            m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EBADF)))
            return m3Err_none
        }
        var ret = 0
        unsafe {
            ret = _builtin_write(f, reinterpret<u8?>(buf_addr), int(len))
        }
        if (ret < 0) {
            m3ApiReturn_u32(raw_return, u32(errno_to_wasi(EIO)))
            return m3Err_none
        }
        res += ret
        if (u32(ret) < len) { break }
    }

    // C writes with write(2), which is unbuffered, so a guest's stdout and
    // stderr interleave in the order it produced them. fio writes through
    // FILE*, so the standard streams are flushed here to keep that order.
    let kind = wasi_fd_kind(fd)
    if (kind == WasiFdKind.wasi_fd_stdout || kind == WasiFdKind.wasi_fd_stderr) {
        fflush(wasi_fd_handle(fd))
    }

    m3ApiWriteMem32(nwritten, u32(res))
    m3ApiReturn_u32(raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_close(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)

    // C: int ret = close(fd). Releasing the table slot is what stands in for
    // it; the standard streams are only detached, never fclose'd, because
    // the host process still needs them and the port cannot reopen one.
    var ret = -1
    let kind = wasi_fd_kind(fd)
    if (kind != WasiFdKind.wasi_fd_free) {
        if (kind == WasiFdKind.wasi_fd_file) {
            fclose(wasi_fds[int(fd)].f)
        }
        wasi_fds[int(fd)].kind = WasiFdKind.wasi_fd_free
        wasi_fds[int(fd)].f = null
        wasi_fds[int(fd)].path = ""
        ret = 0
    }

    // C: m3ApiReturn(ret == 0 ? __WASI_ERRNO_SUCCESS : ret). On failure it
    // returns close()'s -1 as the errno value, not errno_to_wasi(errno);
    // the quirk is kept, so a bad fd yields 0xFFFFFFFF as it does in C.
    m3ApiReturn_u32(raw_return, ret == 0 ? u32(WASI_ERRNO_SUCCESS) : u32(ret))
    return m3Err_none
}


def public m3_wasi_generic_fd_datasync(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)
    let fd = m3ApiGetArg_u32(sp)

    // C on Linux: int ret = fdatasync(fd). fflush is the fio equivalent for
    // a FILE*; a handle-less descriptor (a preopened directory, a free slot)
    // is the -1 case, as fdatasync would be for a bad fd. stdin is excluded
    // as well: fdatasync(0) fails with EBADF because the descriptor is not
    // open for writing, and fflush on an input stream would instead discard
    // buffered input that a guest reading stdin still needs.
    var ret = -1
    let f = wasi_fd_handle(fd)
    if (f != null && wasi_fd_kind(fd) != WasiFdKind.wasi_fd_stdin) {
        fflush(f)
        ret = 0
    }

    // The same C quirk as fd_close: the raw -1, not errno_to_wasi(errno).
    m3ApiReturn_u32(raw_return, ret == 0 ? u32(WASI_ERRNO_SUCCESS) : u32(ret))
    return m3Err_none
}
