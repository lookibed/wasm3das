options gen2
options indenting = 4

module m3_api_wasi_fd shared public

require modules/wasm3das/source/m3_api_defs public   // Eden: project-root-relative path (upstream: ./m3_api_defs.das)
require modules/wasm3das/source/wasi_core public     // Eden: project-root-relative path (upstream: ./wasi_core.das)
require strings                                      // Eden: character_at for the preopen name copy (upstream: daslib/strings)
require math


/*
    Conservative Gen2 port of the file-descriptor half of m3_api_wasi.c:
    the Preopen table, errno_to_wasi, the fd_* raw functions and path_open.

    The core half of the same C file (args_*, environ_*, clock_*,
    random_get, proc_exit, m3_GetWasiContext and m3_LinkWASI) lives in
    m3_api_wasi.das and requires this module by the C names below.

    C-macro adaptations, applied once here (see m3_api_defs.das):
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list; the
      port spells that list out.
    - m3ApiReturn(VALUE) is m3ApiReturn_u32(raw_return, VALUE) followed by
      `return m3Err_none`; m3ApiCheckMem returns the trap result to the caller.
    - C's `buf + N` pointer arithmetic inside linear memory is an offset sum.

    Conditional compilation: the port targets the POSIX (Linux) branch of the
    C file (`!_WIN32`, `!APE`, and HAS_IOVEC, which m3_api_wasi.c defines
    for __linux__). fd_read and fd_write take the HAS_IOVEC branch:
    copy_iov_to_host checks every iovec (the empty ones too) before any
    I/O, then one readv / writev moves the bytes, and its result is the
    answer (a partial count is SUCCESS, only a failed call is an errno).

    Eden: the upstream port took the non-HAS_IOVEC loop (one read/write per
    iovec, skipping empty ones, stopping after a short transfer), which is
    not what the Linux build of C does (empty iovecs are checked, 0 iovecs
    on a bad fd is BADF, more than IOV_MAX iovecs is INVAL, a later
    out-of-bounds buffer traps before the earlier ones move, an error after
    a partial transfer is not reported); the HAS_IOVEC branch is ported
    instead, with readv / writev as backend calls (see THE BACKEND).

    Eden: deviations from the upstream port (.upstream/source/m3_api_wasi_fd.das)
    and from C, for the EdenSpark sandbox (docs/eden-port/DESIGN.md 4.5, 4.7,
    4.7b-wasi, 4.7c). The sandbox has no file system and no fio, so the
    upstream descriptor layer over fio FILE handles is replaced by a
    descriptor table over a pluggable backend:

      - THE BACKEND. C calls the host OS (open/openat, readv, writev, lseek,
        close, fdatasync, fcntl F_GETFL, fstat). Those eight calls are the
        lambdas of `struct M3WasiFsBackend`, one per C call, POSIX-shaped:
        each takes the runtime (for the in-memory stdio of DESIGN 4.7) and a
        backend handle and returns what the POSIX call returns on success
        (a handle, a byte count, an offset, the flags, st_mode, 0) or the
        NEGATED <errno.h> value on failure (the Linux numbering below, which
        is public for that reason). The fd layer maps the errno with C's
        errno_to_wasi. Bytes cross the interface as array<u8> (DESIGN 4.7c):
        an iovec is one array<u8>; readv gets them sized to the iovec
        lengths, fills them in order and returns the count, which fd_read
        scatters back into linear memory (only the first `count` bytes, as
        readv writes them). A backend follows Linux readv/writev: EBADF for
        a handle that is not open (even with 0 iovecs), then EINVAL for more
        than IOV_MAX iovecs, then EBADF for a handle not open for that
        direction, and a partial transfer returns its count.
        open receives the open(2) flags and mode C computes from the WASI
        oflags / fdflags / rights, so a backend sees exactly what openat
        would have seen; dirHandle is a backend handle, AT_FDCWD for C's
        plain open(), or -1 when the WASI descriptor is not open (openat on
        a bad dirfd). Backend handles 0, 1, 2 are the standard streams.
      - THE DEFAULT BACKEND (the editor's): a backend lambda that is null
        falls back to the wasi_default_* functions of this module, so
        M3WasiFsBackend() is the in-memory backend of DESIGN 4.7b-wasi:
        handle 0 reads (and consumes) rt.stdinBuffer, handles 1 and 2 append
        to rt.stdoutBuffer / rt.stderrBuffer (character devices, 0 read-only
        and 1, 2 write-only; lseek is ESPIPE and fdatasync EINVAL, as on a
        terminal or a pipe), and
        "." is an empty directory, so the two preopens open and every path
        under them is ENOENT (with O_CREAT as well: there is nowhere to
        create a file). Every open of "." is a new directory handle (from
        WASI_DEFAULT_DIR_HANDLE up) with its own offset, as every open(2) is
        a new open file description; it behaves as a directory of Linux's
        in-memory file system (tmpfs, dcache_dir_lseek; measured on Linux
        6.6): open with O_CREAT|O_EXCL is EEXIST, with O_CREAT, O_TRUNC or
        write access EISDIR; lseek SEEK_SET / SEEK_CUR move the offset,
        SEEK_END, another whence or a negative result is EINVAL; readv of
        0 bytes is 0, of more EISDIR; fdatasync is 0. Because the default
        needs no lambda, the editor never stores a function value in a
        global, and a hot reload that carries the globals over (DESIGN 1)
        keeps it usable.
        .local/app installs a fio backend with m3_SetWasiFsBackend.
      - THE CONTEXT. C's m3_wasi_context_t (m3_api_wasi.h) moves here, one
        layer down, because it now holds the descriptor table and the
        backend next to C's exit_code / argc / argv; m3_api_wasi uses this
        declaration. C keeps one static context and lets the OS own the
        descriptors; the port keeps contexts in `m3_wasi_contexts`, and the
        int TOKEN of a context (its index, from m3_NewWasiContext) is what
        m3_LinkWASI passes as the userdata of every WASI import, so each raw
        function reaches its context as `ctx.userdata` (M3ImportContext of
        DESIGN 4.5). C links the fd functions with m3_LinkRawFunction (no
        userdata); m3_api_wasi links them with m3_LinkRawFunctionEx and the
        token instead. A raw function whose token names no context has no
        descriptors: every fd operation is EBADF (the prestat functions
        read only the preopen table, as in C, and still answer).
      - THE DESCRIPTOR TABLE. In C the WASI fd is the host fd. Here
        `m3_wasi_context_t.fds` maps a WASI fd (the index) to a backend
        handle (-1 = closed). A new context has 0, 1, 2 open on handles
        0, 1, 2, as a process starts; an open takes the lowest closed slot,
        which is the descriptor openat() returns; close always releases the
        slot, as close(2) does even when it reports an error. The private
        wasi_host_* functions are the POSIX calls over this table.
      - the preopen loop of m3_LinkWASI is wasi_fd_open_preopens(rt, token),
        a literal port of that loop (open(real_path, O_RDONLY) into
        preopen[i].fd, -1 on failure); it needs the context, so m3_LinkWASI
        creates the context first (C creates it after the loop). The
        upstream idempotence guard is gone: every call opens new
        descriptors, as C's loop does.
      - path_open: `host_fd = openat(preopen[dirfd].fd, ...)` keeps C's
        shape, so a dirfd whose preopen is a standard stream is ENOTDIR
        (from the backend, as openat reports it; upstream answered EBADF);
        C reads past the preopen table for dirfd >= PREOPEN_CNT, the port
        answers EBADF there (as upstream). The path is read as a C string
        (m3ApiReadString: it ends at the first NUL, as C's openat reads it).
      - the narrow arguments are read as C's m3ApiGetArg reads them:
        __wasi_oflags_t and __wasi_fdflags_t are uint16_t, so oflags,
        fs_flags and the ignored flags of fd_fdstat_set_flags go through
        m3ApiGetArg_u16 (upstream: u32).
      - fd_fdstat_get follows C: fcntl(F_GETFL) first (its errno is the
        result when it fails), then fstat's st_mode for fs_filetype and the
        fcntl flags for fs_flags (upstream derived both from its table
        kind). C ignores fstat's result; a failing backend fstat gives
        mode 0 (C reads an uninitialized struct).
      - fd_close / fd_datasync keep C's quirk: a failure returns the -1 of
        close()/fdatasync() itself (0xFFFFFFFF), not errno_to_wasi(errno).
      - fd_write no longer flushes the standard streams (upstream: fio
        FILE buffering); the buffers are the streams.
      - C's `struct iovec iovs[iovs_len]` (a VLA of host pointers) is an
        array<iovec> whose iov_base is a linear-memory offset; the bytes
        move through one array<u8> per iovec (THE BACKEND), and fd_read
        writes back at most the iovecs' total even if a backend claims
        more; `options never_inline` is dropped (untested in the editor,
        DESIGN 1).
*/


// The <errno.h> values errno_to_wasi switches on, in C order. Linux/glibc
// asm-generic numbering, the platform this port targets.
// Eden: public, a backend returns them negated (see the header)
let public EPERM = 1
let public ENOENT = 2
let public ESRCH = 3
let public EINTR = 4
let public EIO = 5
let public ENXIO = 6
let public E2BIG = 7
let public ENOEXEC = 8
let public EBADF = 9
let public ECHILD = 10
let public EAGAIN = 11
let public ENOMEM = 12
let public EACCES = 13
let public EFAULT = 14
let public EBUSY = 16
let public EEXIST = 17
let public EXDEV = 18
let public ENODEV = 19
let public ENOTDIR = 20
let public EISDIR = 21
let public EINVAL = 22
let public ENFILE = 23
let public EMFILE = 24
let public ENOTTY = 25
let public ETXTBSY = 26
let public EFBIG = 27
let public ENOSPC = 28
let public ESPIPE = 29
let public EROFS = 30
let public EMLINK = 31
let public EPIPE = 32
let public EDOM = 33
let public ERANGE = 34


// Eden: the <fcntl.h>, <unistd.h> and <sys/stat.h> values C passes to and
// reads from the host calls (Linux x86-64), the vocabulary of the backend
let public O_RDONLY = 0
let public O_WRONLY = 1
let public O_RDWR = 2
let public O_ACCMODE = 3
let public O_CREAT = 64
let public O_EXCL = 128
let public O_TRUNC = 512
let public O_APPEND = 1024
let public O_NONBLOCK = 2048
let public O_DSYNC = 4096
let public O_DIRECTORY = 65536
let public O_SYNC = 1052672
let public AT_FDCWD = -100
let public IOV_MAX = 1024     // <limits.h>, the kernel's UIO_MAXIOV: readv/writev beyond it are EINVAL

let public SEEK_SET = 0
let public SEEK_CUR = 1
let public SEEK_END = 2

let public S_IFMT = 61440     // 0170000
let public S_IFBLK = 24576    // 0060000
let public S_IFCHR = 8192     // 0020000
let public S_IFDIR = 16384    // 0040000
let public S_IFREG = 32768    // 0100000
let public S_IFLNK = 40960    // 0120000


// C <sys/stat.h>: #define S_ISBLK(m) (((m) & S_IFMT) == S_IFBLK), and so on
def private S_ISBLK(m : int) : bool {
    return (m & S_IFMT) == S_IFBLK
}


def private S_ISCHR(m : int) : bool {
    return (m & S_IFMT) == S_IFCHR
}


def private S_ISDIR(m : int) : bool {
    return (m & S_IFMT) == S_IFDIR
}


def private S_ISREG(m : int) : bool {
    return (m & S_IFMT) == S_IFREG
}


def private S_ISLNK(m : int) : bool {
    return (m & S_IFMT) == S_IFLNK
}


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
    The -1 entries are filled in by m3_LinkWASI, here through
    wasi_fd_open_preopens(). As in C the table is global; `fd` is a WASI
    descriptor of the context the last m3_LinkWASI opened it in. */
var public preopen = [
    Preopen(fd = 0, path = "<stdin>", real_path = ""),
    Preopen(fd = 1, path = "<stdout>", real_path = ""),
    Preopen(fd = 2, path = "<stderr>", real_path = ""),
    Preopen(fd = -1, path = "/", real_path = "."),
    Preopen(fd = -1, path = "./", real_path = ".")
]


// ============================================================================
// Eden: the file-system backend and the WASI context (see the header)
// ============================================================================


// Eden: one lambda per host call of C; each returns the POSIX success value
// or the negated errno. A null lambda falls back to the wasi_default_*
// function of the same call (see the header).
struct public M3WasiFsBackend {
    // C: openat(dirfd, path, flags, mode) / open(path, flags): a new handle
    open : lambda<(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int>
    // C: readv(fd, iov, iovcnt): the byte count; `bufs` holds one array per
    // iovec, sized to its length, and the bytes fill them in order
    readv : lambda<(var rt : M3Runtime; handle : int; var bufs : array<array<u8>>) : int>
    // C: writev(fd, iov, iovcnt): the byte count written, taken from `bufs`
    // (one array per iovec) in order
    writev : lambda<(var rt : M3Runtime; handle : int; bufs : array<array<u8>>) : int>
    // C: lseek(fd, offset, whence): the new offset
    lseek : lambda<(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64>
    // C: close(fd): 0
    close : lambda<(var rt : M3Runtime; handle : int) : int>
    // C: fdatasync(fd): 0
    fdatasync : lambda<(var rt : M3Runtime; handle : int) : int>
    // C: fcntl(fd, F_GETFL): the O_* status and access flags
    fcntl_getfl : lambda<(var rt : M3Runtime; handle : int) : int>
    // C: fstat(fd, &st), st.st_mode
    fstat_mode : lambda<(var rt : M3Runtime; handle : int) : int>
}


/*  C m3_api_wasi.h:

        typedef struct m3_wasi_context_t
        {
            i32                     exit_code;
            u32                     argc;
            ccstr_t *               argv;
        } m3_wasi_context_t;

    argv is an array<string> the embedder fills (as upstream). Eden: moved
    here from m3_api_wasi and extended with the descriptor table and the
    backend (see the header). */
struct public m3_wasi_context_t {
    exit_code : i32 = 0
    argc : u32 = 0u
    argv : array<string>
    fds : array<int>                            // Eden: WASI fd -> backend handle, -1 = closed
    backend : M3WasiFsBackend = M3WasiFsBackend()   // Eden: null lambdas = the default backend
}


// Eden: the contexts; a context's token (ctx.userdata of the WASI imports)
// is its index. C: the one `static m3_wasi_context_t* wasi_context` of
// m3_api_wasi.c, which m3_api_wasi keeps as a token.
var public m3_wasi_contexts : array<m3_wasi_context_t>


// Eden: a new context: C's zeroed m3_wasi_context_t, descriptors 0, 1, 2
// open on the backend's standard streams, the default backend. Returns
// its token.
def public m3_NewWasiContext() : int {
    var c = m3_wasi_context_t()
    push(c.fds, 0)
    push(c.fds, 1)
    push(c.fds, 2)
    emplace(m3_wasi_contexts, c)
    return length(m3_wasi_contexts) - 1
}


// Eden: whether `token` names a context
def public m3_IsWasiContext(token : int) : bool {
    return token >= 0 && token < length(m3_wasi_contexts)
}


// Eden: installs `backend` in the context `token` (a null lambda keeps the
// default for its call); false when the token names no context
def public m3_SetWasiFsBackend(token : int; var backend : M3WasiFsBackend) : bool {
    if (!m3_IsWasiContext(token)) {
        return false
    }
    m3_wasi_contexts[token].backend <- backend
    return true
}


// Eden: the backend handle behind a WASI descriptor, -1 when it is not open
// (or the token names no context)
def private wasi_fd_handle(token : int; fd : u32) : int {
    if (!m3_IsWasiContext(token)) {
        return -1
    }
    if (fd >= u32(length(m3_wasi_contexts[token].fds))) {
        return -1
    }
    return m3_wasi_contexts[token].fds[int(fd)]
}


// Eden: the lowest closed descriptor gets `handle`, which is the descriptor
// open()/openat() return
def private wasi_fd_alloc(token : int; handle : int) : int {
    for (i in range(length(m3_wasi_contexts[token].fds))) {
        if (m3_wasi_contexts[token].fds[i] == -1) {
            m3_wasi_contexts[token].fds[i] = handle
            return i
        }
    }
    push(m3_wasi_contexts[token].fds, handle)
    return length(m3_wasi_contexts[token].fds) - 1
}


// ============================================================================
// Eden: the default backend (DESIGN 4.7b-wasi): in-memory stdio, no files
// ============================================================================


// Eden: the first directory handle of the default backend; every open of
// "." takes the lowest closed one from here up
let public WASI_DEFAULT_DIR_HANDLE = 3


// Eden: the default backend's open directories: entry k is the handle
// WASI_DEFAULT_DIR_HANDLE + k and holds that open file description's offset
// (f_pos), -1 when the handle is closed. A global like m3_wasi_contexts:
// backend handles belong to the backend (the OS in C), not to a context.
var private wasi_default_dir_pos : array<i64>


// Eden: whether `handle` is an open directory of the default backend
def private wasi_default_is_dir(handle : int) : bool {
    let k = handle - WASI_DEFAULT_DIR_HANDLE
    return k >= 0 && k < length(wasi_default_dir_pos) && wasi_default_dir_pos[k] >= 0l
}


// Eden: whether `handle` is open in the default backend (a standard stream
// or a directory)
def private wasi_default_is_open(handle : int) : bool {
    return (handle >= 0 && handle <= 2) || wasi_default_is_dir(handle)
}


// Eden: a new directory handle at offset 0, the lowest closed one
def private wasi_default_new_dir() : int {
    for (k in range(length(wasi_default_dir_pos))) {
        if (wasi_default_dir_pos[k] < 0l) {
            wasi_default_dir_pos[k] = 0l
            return WASI_DEFAULT_DIR_HANDLE + k
        }
    }
    push(wasi_default_dir_pos, 0l)
    return WASI_DEFAULT_DIR_HANDLE + length(wasi_default_dir_pos) - 1
}


def public wasi_default_open(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int {
    if (dirHandle == AT_FDCWD || wasi_default_is_dir(dirHandle)) {
        if (path == "." || path == "./") {
            // Linux do_open, then may_open, on an existing directory
            if ((flags & O_CREAT) != 0) {
                if ((flags & O_EXCL) != 0) {
                    return -EEXIST
                }
                return -EISDIR
            }
            if ((flags & O_ACCMODE) != O_RDONLY || (flags & O_TRUNC) != 0) {
                return -EISDIR   // write access (O_TRUNC asks for it too)
            }
            return wasi_default_new_dir()
        }
        return -ENOENT   // the directory is empty and nothing can be created in it
    }
    if (length(path) > 0 && character_at(path, 0) == '/') {
        return -ENOENT   // an absolute path ignores dirHandle, as openat does
    }
    if (dirHandle >= 0 && dirHandle <= 2) {
        return -ENOTDIR
    }
    return -EBADF
}


// Linux readv: EBADF for a closed handle, EINVAL past IOV_MAX, then EBADF
// for a handle not open for reading
def public wasi_default_readv(var rt : M3Runtime; handle : int; var bufs : array<array<u8>>) : int {
    if (!wasi_default_is_open(handle)) {
        return -EBADF
    }
    if (length(bufs) > IOV_MAX) {
        return -EINVAL
    }
    var total = 0
    for (b in bufs) {
        total += length(b)
    }
    if (handle == 0) {
        // stdin reads as a pipe: a read takes (and removes) what is
        // buffered, filling the iovecs in order
        let n = min(total, length(rt.stdinBuffer))
        var k = 0
        for (b in bufs) {
            let take = min(length(b), n - k)
            for (i in range(take)) {
                b[i] = rt.stdinBuffer[k + i]
            }
            k += take
        }
        erase(rt.stdinBuffer, 0, n)
        return n
    } elif (wasi_default_is_dir(handle)) {
        return total == 0 ? 0 : -EISDIR   // a read of 0 bytes never reaches the directory
    }
    return -EBADF   // stdout and stderr are write-only
}


// Linux writev: EBADF for a closed handle, EINVAL past IOV_MAX, then EBADF
// for a handle not open for writing
def public wasi_default_writev(var rt : M3Runtime; handle : int; bufs : array<array<u8>>) : int {
    if (!wasi_default_is_open(handle)) {
        return -EBADF
    }
    if (length(bufs) > IOV_MAX) {
        return -EINVAL
    }
    if (handle == 1 || handle == 2) {
        var n = 0
        for (b in bufs) {
            for (x in b) {
                if (handle == 1) {
                    push(rt.stdoutBuffer, x)
                } else {
                    push(rt.stderrBuffer, x)
                }
            }
            n += length(b)
        }
        return n
    }
    return -EBADF   // stdin and the directories are read-only
}


// the standard streams do not seek (ESPIPE); a directory seeks as Linux's
// dcache_dir_lseek (tmpfs): SET and CUR only, never below 0
def public wasi_default_lseek(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
    if (handle >= 0 && handle <= 2) {
        return i64(-ESPIPE)
    } elif (wasi_default_is_dir(handle)) {
        let k = handle - WASI_DEFAULT_DIR_HANDLE
        var target = 0l
        if (whence == SEEK_SET) {
            target = offset
        } elif (whence == SEEK_CUR) {
            target = wasi_default_dir_pos[k] + offset
        } else {
            return i64(-EINVAL)   // SEEK_END and anything else
        }
        if (target < 0l) {
            return i64(-EINVAL)
        }
        wasi_default_dir_pos[k] = target
        return target
    }
    return i64(-EBADF)
}


def public wasi_default_close(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return 0
    } elif (wasi_default_is_dir(handle)) {
        wasi_default_dir_pos[handle - WASI_DEFAULT_DIR_HANDLE] = -1l
        return 0
    }
    return -EBADF
}


// Linux fdatasync: EINVAL on a pipe or character device (no fsync), 0 on a
// directory
def public wasi_default_fdatasync(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return -EINVAL
    } elif (wasi_default_is_dir(handle)) {
        return 0
    }
    return -EBADF
}


def public wasi_default_fcntl_getfl(var rt : M3Runtime; handle : int) : int {
    if (handle == 0) {
        return O_RDONLY
    } elif (handle == 1 || handle == 2) {
        return O_WRONLY
    } elif (wasi_default_is_dir(handle)) {
        return O_RDONLY | O_DIRECTORY
    }
    return -EBADF
}


def public wasi_default_fstat_mode(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return S_IFCHR
    } elif (wasi_default_is_dir(handle)) {
        return S_IFDIR
    }
    return -EBADF
}


// ============================================================================
// Eden: the host calls of C over the descriptor table (see the header).
// Each returns the POSIX success value or the negated errno.
// ============================================================================


// C: openat(dirfd, path, flags, mode); dirfd is a WASI descriptor or AT_FDCWD
def private wasi_host_openat(var rt : M3Runtime; token : int; dirfd : int; path : string; flags : int; mode : int) : int {
    if (!m3_IsWasiContext(token)) {
        return -EBADF
    }
    var dirHandle = -1
    if (dirfd == AT_FDCWD) {
        dirHandle = AT_FDCWD
    } elif (dirfd >= 0) {
        dirHandle = wasi_fd_handle(token, u32(dirfd))
    }
    var handle = 0
    if (m3_wasi_contexts[token].backend.open != null) {
        handle = invoke(m3_wasi_contexts[token].backend.open, rt, dirHandle, path, flags, mode)
    } else {
        handle = wasi_default_open(rt, dirHandle, path, flags, mode)
    }
    if (handle < 0) {
        return handle
    }
    return wasi_fd_alloc(token, handle)
}


// C: readv(fd, iovs, iovs_len)
def private wasi_host_readv(var rt : M3Runtime; token : int; fd : u32; var bufs : array<array<u8>>) : int {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return -EBADF
    }
    if (m3_wasi_contexts[token].backend.readv != null) {
        return invoke(m3_wasi_contexts[token].backend.readv, rt, handle, bufs)
    }
    return wasi_default_readv(rt, handle, bufs)
}


// C: writev(fd, iovs, iovs_len)
def private wasi_host_writev(var rt : M3Runtime; token : int; fd : u32; bufs : array<array<u8>>) : int {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return -EBADF
    }
    if (m3_wasi_contexts[token].backend.writev != null) {
        return invoke(m3_wasi_contexts[token].backend.writev, rt, handle, bufs)
    }
    return wasi_default_writev(rt, handle, bufs)
}


// C: lseek(fd, offset, whence)
def private wasi_host_lseek(var rt : M3Runtime; token : int; fd : u32; offset : i64; whence : int) : i64 {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return i64(-EBADF)
    }
    if (m3_wasi_contexts[token].backend.lseek != null) {
        return invoke(m3_wasi_contexts[token].backend.lseek, rt, handle, offset, whence)
    }
    return wasi_default_lseek(rt, handle, offset, whence)
}


// C: close(fd); the descriptor is released whatever the backend reports
def private wasi_host_close(var rt : M3Runtime; token : int; fd : u32) : int {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return -EBADF
    }
    m3_wasi_contexts[token].fds[int(fd)] = -1
    if (m3_wasi_contexts[token].backend.close != null) {
        return invoke(m3_wasi_contexts[token].backend.close, rt, handle)
    }
    return wasi_default_close(rt, handle)
}


// C: fdatasync(fd)
def private wasi_host_fdatasync(var rt : M3Runtime; token : int; fd : u32) : int {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return -EBADF
    }
    if (m3_wasi_contexts[token].backend.fdatasync != null) {
        return invoke(m3_wasi_contexts[token].backend.fdatasync, rt, handle)
    }
    return wasi_default_fdatasync(rt, handle)
}


// C: fcntl(fd, F_GETFL)
def private wasi_host_fcntl_getfl(var rt : M3Runtime; token : int; fd : u32) : int {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return -EBADF
    }
    if (m3_wasi_contexts[token].backend.fcntl_getfl != null) {
        return invoke(m3_wasi_contexts[token].backend.fcntl_getfl, rt, handle)
    }
    return wasi_default_fcntl_getfl(rt, handle)
}


// C: fstat(fd, &st), st.st_mode
def private wasi_host_fstat_mode(var rt : M3Runtime; token : int; fd : u32) : int {
    let handle = wasi_fd_handle(token, fd)
    if (handle == -1) {
        return -EBADF
    }
    if (m3_wasi_contexts[token].backend.fstat_mode != null) {
        return invoke(m3_wasi_contexts[token].backend.fstat_mode, rt, handle)
    }
    return wasi_default_fstat_mode(rt, handle)
}


// ============================================================================
// errno_to_wasi
// ============================================================================


// C writes this as a switch; daslang has no switch over integers, so the
// APE_CASE_RET chain becomes an if/else chain in the same order.
def public errno_to_wasi(errnum : int) : wasi_errno_t {
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
// The preopen loop m3_LinkWASI calls
// ============================================================================


/*  C, in m3_LinkWASI:

        // Preopen dirs
        for (int i = 3; i < PREOPEN_CNT; i++) {
            preopen[i].fd = open(preopen[i].real_path, O_RDONLY);
        }

    Eden: the loop over the context `token` (see the header); open() is
    openat(AT_FDCWD, ...), and a failure stores open()'s -1. */
def public wasi_fd_open_preopens(var rt : M3Runtime; token : int) {
    for (i in 3..PREOPEN_CNT) {
        let fd = wasi_host_openat(rt, token, AT_FDCWD, preopen[i].real_path, O_RDONLY, 0)
        preopen[i].fd = fd >= 0 ? fd : -1
    }
}


// ============================================================================
// copy_iov_to_host (HAS_IOVEC)
// ============================================================================


// C <sys/uio.h>: struct iovec { void* iov_base; size_t iov_len; };
// Eden: iov_base is the offset into rt.mem that m3ApiOffsetToPtr gives
struct private iovec {
    iov_base : int
    iov_len : u64
}


/*  C (#if defined(HAS_IOVEC)):

        static inline
        const void* copy_iov_to_host(IM3Runtime runtime, void* _mem, struct iovec* host_iov, wasi_iovec_t* wasi_iov, int32_t iovs_len)

    Eden: host_iov is the caller's array of iovs_len entries (C's VLA),
    wasi_iov the offset of the wasi_iovec_t array in linear memory; _mem is
    rt.mem. m3ApiCheckMem returns its trap to the caller (see above). */
def private copy_iov_to_host(rt : M3Runtime; var host_iov : array<iovec>; wasi_iov : int; iovs_len : int) : M3Result {
    // Convert wasi memory offsets to host addresses
    for (i in range(iovs_len)) {
        let iov = wasi_iov + i * int(WASI_IOVEC_SIZE)
        host_iov[i].iov_base = m3ApiOffsetToPtr(m3ApiReadMem32(rt, iov + int(WASI_IOVEC_OFF_BUF)))
        host_iov[i].iov_len = u64(m3ApiReadMem32(rt, iov + int(WASI_IOVEC_OFF_BUF_LEN)))
        let check = m3ApiCheckMem(rt, host_iov[i].iov_base, host_iov[i].iov_len)
        if (check != m3Err_none) { return check }
    }
    return m3ApiSuccess()
}


// ============================================================================
// WASI API implementation (file descriptors)
// ============================================================================


def public m3_wasi_generic_fd_prestat_dir_name(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let path = m3ApiGetArgMem(rt, f)             // m3ApiGetArgMem (char *, path)
    let path_len = m3ApiGetArg_u32(rt, f)        // m3ApiGetArg (__wasi_size_t, path_len)

    let check = m3ApiCheckMem(rt, path, u64(path_len))
    if (check != m3Err_none) { return check }

    if (fd < 3u || fd >= u32(PREOPEN_CNT)) {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_BADF))
        return m3Err_none
    }
    let name = preopen[int(fd)].path
    let slen = u64(length(name)) + 1ul   // C: strlen(preopen[fd].path) + 1
    // C: memcpy(path, preopen[fd].path, M3_MIN(slen, path_len)); the byte
    // at index strlen is the NUL terminator the copy includes
    let count = int(min(slen, u64(path_len)))
    var bytes : array<u8>
    resize(bytes, count)
    for (i in range(count)) {
        bytes[i] = i < length(name) ? u8(character_at(name, i)) : 0u8
    }
    m3ApiWriteBytes(rt, path, bytes)
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_prestat_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let buf = m3ApiGetArgMem(rt, f)              // m3ApiGetArgMem (uint8_t *, buf)

    let check = m3ApiCheckMem(rt, buf, 8ul)
    if (check != m3Err_none) { return check }

    if (fd < 3u || fd >= u32(PREOPEN_CNT)) {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_BADF))
        return m3Err_none
    }

    // C writes the one-byte prestat tag with a 32-bit store, so the three
    // padding bytes before the name length are zeroed; keep that.
    m3ApiWriteMem32(rt, buf + 0, u32(WASI_PREOPENTYPE_DIR))
    m3ApiWriteMem32(rt, buf + 4, u32(length(preopen[int(fd)].path)) + 1u)
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_fdstat_get(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let fdstat = m3ApiGetArgMem(rt, f)           // m3ApiGetArgMem (__wasi_fdstat_t *, fdstat)

    // C: m3ApiCheckMem(fdstat, sizeof(__wasi_fdstat_t)). The field offsets
    // used below are the ones wasi_core.h asserts.
    let check = m3ApiCheckMem(rt, fdstat, u64(WASI_FDSTAT_SIZE))
    if (check != m3Err_none) { return check }

    let fl = wasi_host_fcntl_getfl(rt, ctx.userdata, fd)   // C: int fl = fcntl(fd, F_GETFL)
    if (fl < 0) {
        m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(-fl)))
        return m3Err_none
    }

    let st_mode = wasi_host_fstat_mode(rt, ctx.userdata, fd)   // C: fstat(fd, &fd_stat)
    let mode = st_mode >= 0 ? st_mode : 0                     // C: int mode = fd_stat.st_mode
    var fs_filetype = 0u
    fs_filetype |= S_ISBLK(mode) ? uint(WASI_FILETYPE_BLOCK_DEVICE) : 0u
    fs_filetype |= S_ISCHR(mode) ? uint(WASI_FILETYPE_CHARACTER_DEVICE) : 0u
    fs_filetype |= S_ISDIR(mode) ? uint(WASI_FILETYPE_DIRECTORY) : 0u
    fs_filetype |= S_ISREG(mode) ? uint(WASI_FILETYPE_REGULAR_FILE) : 0u
    //(S_ISSOCK(mode)  ? __WASI_FILETYPE_SOCKET_STREAM    : 0) |
    fs_filetype |= S_ISLNK(mode) ? uint(WASI_FILETYPE_SYMBOLIC_LINK) : 0u
    m3ApiWriteMem8(rt, fdstat + int(WASI_FDSTAT_OFF_FS_FILETYPE), u8(fs_filetype))

    var fs_flags = 0u
    fs_flags |= (fl & O_APPEND) != 0 ? uint(WASI_FDFLAGS_APPEND) : 0u
    fs_flags |= (fl & O_DSYNC) != 0 ? uint(WASI_FDFLAGS_DSYNC) : 0u
    fs_flags |= (fl & O_NONBLOCK) != 0 ? uint(WASI_FDFLAGS_NONBLOCK) : 0u
    //((fl & O_RSYNC)     ? __WASI_FDFLAGS_RSYNC     : 0) |
    fs_flags |= (fl & O_SYNC) != 0 ? uint(WASI_FDFLAGS_SYNC) : 0u
    m3ApiWriteMem16(rt, fdstat + int(WASI_FDSTAT_OFF_FS_FLAGS), u16(fs_flags))

    var fs_rights_base = 0xFFFFFFFFFFFFFFFFul // all rights

    // Make descriptors 0,1,2 look like a TTY
    if (fd <= 2u) {
        fs_rights_base &= ~(WASI_RIGHTS_FD_SEEK | WASI_RIGHTS_FD_TELL)
    }
    m3ApiWriteMem64(rt, fdstat + int(WASI_FDSTAT_OFF_FS_RIGHTS_BASE), fs_rights_base)

    m3ApiWriteMem64(rt, fdstat + int(WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING), 0xFFFFFFFFFFFFFFFFul) // all rights
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_fdstat_set_flags(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    // C reads both arguments and does nothing with them ("// TODO").
    m3ApiGetArg_u32(rt, f)                       // m3ApiGetArg (__wasi_fd_t, fd)
    m3ApiGetArg_u16(rt, f)                       // m3ApiGetArg (__wasi_fdflags_t, flags)

    // TODO

    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


// The two fd_seek flavours differ only in the whence encoding: wasi_unstable
// numbered it CUR/END/SET, wasi_snapshot_preview1 SET/CUR/END.
def public m3_wasi_unstable_fd_seek(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let offset = m3ApiGetArg_i64(rt, f)          // m3ApiGetArg (__wasi_filedelta_t, offset)
    let wasi_whence = m3ApiGetArg_u32(rt, f)     // m3ApiGetArg (uint32_t, wasi_whence)
    let result = m3ApiGetArgMem(rt, f)           // m3ApiGetArgMem (__wasi_filesize_t *, result)

    let check = m3ApiCheckMem(rt, result, 8ul) // sizeof(__wasi_filesize_t)
    if (check != m3Err_none) { return check }

    var whence = 0
    if (wasi_whence == 0u) { whence = SEEK_CUR }
    elif (wasi_whence == 1u) { whence = SEEK_END }
    elif (wasi_whence == 2u) { whence = SEEK_SET }
    else {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    return wasi_fd_seek_common(rt, ctx, raw_return, fd, offset, whence, result)
}


def public m3_wasi_snapshot_preview1_fd_seek(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let offset = m3ApiGetArg_i64(rt, f)          // m3ApiGetArg (__wasi_filedelta_t, offset)
    let wasi_whence = m3ApiGetArg_u32(rt, f)     // m3ApiGetArg (uint32_t, wasi_whence)
    let result = m3ApiGetArgMem(rt, f)           // m3ApiGetArgMem (__wasi_filesize_t *, result)

    let check = m3ApiCheckMem(rt, result, 8ul) // sizeof(__wasi_filesize_t)
    if (check != m3Err_none) { return check }

    var whence = 0
    if (wasi_whence == 0u) { whence = SEEK_SET }
    elif (wasi_whence == 1u) { whence = SEEK_CUR }
    elif (wasi_whence == 2u) { whence = SEEK_END }
    else {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    return wasi_fd_seek_common(rt, ctx, raw_return, fd, offset, whence, result)
}


/*  The tail both fd_seek flavours share (upstream). C is, in each:

        ret = lseek(fd, offset, whence);
        if (ret < 0) { m3ApiReturn(errno_to_wasi(errno)); }
        m3ApiWriteMem64(result, ret);
        m3ApiReturn(__WASI_ERRNO_SUCCESS);

    Eden: lseek is the backend call (see the header), so the upstream
    fseek/ftell pair and its EINVAL guess are gone. */
def private wasi_fd_seek_common(var rt : M3Runtime; ctx : M3ImportContext; raw_return : int; fd : u32; offset : i64; whence : int; result : int) : M3Result {
    let ret = wasi_host_lseek(rt, ctx.userdata, fd, offset, whence)
    if (ret < 0l) {
        m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(int(-ret))))
        return m3Err_none
    }
    m3ApiWriteMem64(rt, result, u64(ret))
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_path_open(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let dirfd = m3ApiGetArg_u32(rt, f)           // m3ApiGetArg (__wasi_fd_t, dirfd)
    m3ApiGetArg_u32(rt, f)                       // m3ApiGetArg (__wasi_lookupflags_t, dirflags): never used
    let path = m3ApiGetArgMem(rt, f)             // m3ApiGetArgMem (const char *, path)
    let path_len = m3ApiGetArg_u32(rt, f)        // m3ApiGetArg (__wasi_size_t, path_len)
    let oflags = m3ApiGetArg_u16(rt, f)          // m3ApiGetArg (__wasi_oflags_t, oflags)
    let fs_rights_base = m3ApiGetArg_u64(rt, f)  // m3ApiGetArg (__wasi_rights_t, fs_rights_base)
    m3ApiGetArg_u64(rt, f)                       // m3ApiGetArg (__wasi_rights_t, fs_rights_inheriting): never used
    let fs_flags = m3ApiGetArg_u16(rt, f)        // m3ApiGetArg (__wasi_fdflags_t, fs_flags)
    let fd = m3ApiGetArgMem(rt, f)               // m3ApiGetArgMem (__wasi_fd_t *, fd)

    var check = m3ApiCheckMem(rt, path, u64(path_len))
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, fd, 4ul) // sizeof(__wasi_fd_t)
    if (check != m3Err_none) { return check }

    if (path_len >= 512u) {
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_INVAL))
        return m3Err_none
    }

    // copy path so we can ensure it is NULL terminated
    // Eden: a C string, it ends at the first NUL as openat reads it
    let host_path = m3ApiReadString(rt, path, int(path_len))

    // translate o_flags and fs_flags into flags and mode
    let o = uint(oflags)
    let fsf = uint(fs_flags)
    var flags = 0
    flags |= (o & uint(WASI_OFLAGS_CREAT)) != 0u ? O_CREAT : 0
    //((oflags & __WASI_OFLAGS_DIRECTORY)         ? O_DIRECTORY : 0) |
    flags |= (o & uint(WASI_OFLAGS_EXCL)) != 0u ? O_EXCL : 0
    flags |= (o & uint(WASI_OFLAGS_TRUNC)) != 0u ? O_TRUNC : 0
    flags |= (fsf & uint(WASI_FDFLAGS_APPEND)) != 0u ? O_APPEND : 0
    flags |= (fsf & uint(WASI_FDFLAGS_DSYNC)) != 0u ? O_DSYNC : 0
    flags |= (fsf & uint(WASI_FDFLAGS_NONBLOCK)) != 0u ? O_NONBLOCK : 0
    //((fs_flags & __WASI_FDFLAGS_RSYNC)      ? O_RSYNC     : 0) |
    flags |= (fsf & uint(WASI_FDFLAGS_SYNC)) != 0u ? O_SYNC : 0
    let canRead = (fs_rights_base & WASI_RIGHTS_FD_READ) != 0ul
    let canWrite = (fs_rights_base & WASI_RIGHTS_FD_WRITE) != 0ul
    if (canRead && canWrite) {
        flags |= O_RDWR
    } elif (canWrite) {
        flags |= O_WRONLY
    } elif (canRead) {
        flags |= O_RDONLY // no-op because O_RDONLY is 0
    }
    let mode = 420 // C: 0644
    // C: int host_fd = openat (preopen[dirfd].fd, host_path, flags, mode);
    // Eden: C reads past the table for dirfd >= PREOPEN_CNT; that is EBADF
    var host_fd = -EBADF
    if (dirfd < u32(PREOPEN_CNT)) {
        host_fd = wasi_host_openat(rt, ctx.userdata, preopen[int(dirfd)].fd, host_path, flags, mode)
    }

    if (host_fd < 0) {
        m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(-host_fd)))
        return m3Err_none
    } else {
        m3ApiWriteMem32(rt, fd, u32(host_fd))
        m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
        return m3Err_none
    }
}


def public m3_wasi_generic_fd_read(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let wasi_iovs = m3ApiGetArgMem(rt, f)        // m3ApiGetArgMem (wasi_iovec_t *, wasi_iovs)
    let iovs_len = m3ApiGetArg_u32(rt, f)        // m3ApiGetArg (__wasi_size_t, iovs_len)
    let nread = m3ApiGetArgMem(rt, f)            // m3ApiGetArgMem (__wasi_size_t *, nread)

    var check = m3ApiCheckMem(rt, wasi_iovs, u64(iovs_len) * u64(WASI_IOVEC_SIZE))
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, nread, 4ul) // sizeof(__wasi_size_t)
    if (check != m3Err_none) { return check }

    // (HAS_IOVEC) C: struct iovec iovs[iovs_len];
    var iovs : array<iovec>
    resize(iovs, int(iovs_len))
    let mem_check = copy_iov_to_host(rt, iovs, wasi_iovs, int(iovs_len))
    if (mem_check != m3Err_none) {
        return mem_check
    }

    // Eden: one array per iovec, sized to it, for the backend to fill
    var bufs : array<array<u8>>
    resize(bufs, int(iovs_len))
    for (iov, b in iovs, bufs) {
        resize(b, int(iov.iov_len))
    }
    var ret = wasi_host_readv(rt, ctx.userdata, fd, bufs)   // C: ssize_t ret = readv(fd, iovs, iovs_len)
    if (ret < 0) {
        m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(-ret)))
        return m3Err_none
    }
    // Eden: the first `ret` bytes land in the iovecs in order, as readv
    // writes them, never past the checked buffers
    var left = ret
    for (iov, b in iovs, bufs) {
        let take = min(left, min(int(iov.iov_len), length(b)))
        resize(b, take)
        m3ApiWriteBytes(rt, iov.iov_base, b)
        left -= take
    }
    ret -= left
    m3ApiWriteMem32(rt, nread, u32(ret))
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_write(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)
    let wasi_iovs = m3ApiGetArgMem(rt, f)        // m3ApiGetArgMem (wasi_iovec_t *, wasi_iovs)
    let iovs_len = m3ApiGetArg_u32(rt, f)        // m3ApiGetArg (__wasi_size_t, iovs_len)
    let nwritten = m3ApiGetArgMem(rt, f)         // m3ApiGetArgMem (__wasi_size_t *, nwritten)

    var check = m3ApiCheckMem(rt, wasi_iovs, u64(iovs_len) * u64(WASI_IOVEC_SIZE))
    if (check != m3Err_none) { return check }
    check = m3ApiCheckMem(rt, nwritten, 4ul) // sizeof(__wasi_size_t)
    if (check != m3Err_none) { return check }

    // (HAS_IOVEC) C: struct iovec iovs[iovs_len];
    var iovs : array<iovec>
    resize(iovs, int(iovs_len))
    let mem_check = copy_iov_to_host(rt, iovs, wasi_iovs, int(iovs_len))
    if (mem_check != m3Err_none) {
        return mem_check
    }

    // Eden: the bytes of each iovec, in order, for the backend
    var bufs : array<array<u8>>
    for (iov in iovs) {
        var bytes <- m3ApiReadBytes(rt, iov.iov_base, int(iov.iov_len))
        emplace(bufs, bytes)
    }
    let ret = wasi_host_writev(rt, ctx.userdata, fd, bufs)   // C: ssize_t ret = writev(fd, iovs, iovs_len)
    if (ret < 0) {
        m3ApiReturn_u32(rt, raw_return, u32(errno_to_wasi(-ret)))
        return m3Err_none
    }
    m3ApiWriteMem32(rt, nwritten, u32(ret))
    m3ApiReturn_u32(rt, raw_return, u32(WASI_ERRNO_SUCCESS))
    return m3Err_none
}


def public m3_wasi_generic_fd_close(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)

    // C: int ret = close(fd); close() returns -1 on failure
    let ret = wasi_host_close(rt, ctx.userdata, fd) < 0 ? -1 : 0
    // C: m3ApiReturn(ret == 0 ? __WASI_ERRNO_SUCCESS : ret): the raw -1
    m3ApiReturn_u32(rt, raw_return, ret == 0 ? u32(WASI_ERRNO_SUCCESS) : u32(ret))
    return m3Err_none
}


def public m3_wasi_generic_fd_datasync(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)          // m3ApiReturnType (uint32_t)
    let fd = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (__wasi_fd_t, fd)

    // C (Linux): int ret = fdatasync(fd); -1 on failure
    let ret = wasi_host_fdatasync(rt, ctx.userdata, fd) < 0 ? -1 : 0
    // The same C quirk as fd_close: the raw -1, not errno_to_wasi(errno).
    m3ApiReturn_u32(rt, raw_return, ret == 0 ? u32(WASI_ERRNO_SUCCESS) : u32(ret))
    return m3Err_none
}
