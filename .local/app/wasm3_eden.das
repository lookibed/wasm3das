options gen2
options indenting = 4
// C M3_MUSTTAIL is replaced by the RunLoop dispatcher of m3_exec_defs (DESIGN
// 4.4): ops return to the loop, and only a wasm call nests Daslang frames.
// `options stack` counts only in the program root, which for the command
// line tool is this file. The size lets the wasm stack limit checked by
// op_Entry be reached before the Daslang context stack, so an unbounded wasm
// recursion ends as `[trap] stack overflow` (the spec suite's
// assert_exhaustion cases), not as a Daslang stack overflow.
options stack = 67_108_864

// Gen2 port of wasm3c/platforms/app/main.c onto the Eden API, from the
// pointer-based port .upstream/app/wasm3.das (which passed the spec suite).
//
// Scope, as upstream: everything wasm3c/test/run-spec-test.py drives through
// `--repl` (:init, :version, :exit, :load, :load-hex, :invoke, :get-global,
// :set-global, :compile, :dump) and the non-REPL `wasm3 <file> [args...]`
// path of wasm3c/test/run-wasi-test.py, including the LINK_WASI branch of
// repl_call. Gas metering, the tracer and backtraces are out of scope, as
// upstream.
//
// Lives under .local/ (hidden from the editor): it reads files and stdio with
// daslib/fio, which the sandbox allows only here (DESIGN 2).
//
// Eden: deviations from the upstream port and from C
//   - the runtime and the environment are values (m3_NewRuntime returns the
//     runtime; C's `runtime != NULL` is `haveRuntime`), modules and
//     functions are int handles (-1 = NULL), every API call takes the
//     runtime first.
//   - m3_ParseModule copies the binary into the runtime (m3_parse), so C's
//     `wasm_bins[MAX_MODULES]` ownership of the buffers is gone: the local
//     buffer is dropped after the parse.
//   - C's `runtime->modules` (the list head) is Runtime_FirstModule(rt);
//     :get-global, :set-global and :compile with no module loaded answer
//     m3Err_globalLookupFailed / "no modules loaded" where C dereferences
//     NULL.
//   - STDIO. The library layers write the guest's stdout / stderr into
//     rt.stdoutBuffer / rt.stderrBuffer (DESIGN 4.7); flush_stdio writes
//     them to the real streams as soon as a call returns (before the
//     result lines, which is C's order) and before every WASI fd 1/2 write,
//     so program output streams and keeps its order.
//   - WASI FILES. install_fio_backend installs an M3WasiFsBackend over fio
//     (DESIGN 4.7b-wasi) in the WASI context the first m3_LinkWASI creates:
//     paths resolve relative to the cwd (the preopened '.'), fd 0 reads the
//     real stdin. m3_LinkWASI already opened the preopens with the default
//     backend, so they are closed and reopened through the new backend
//     (C's open(".") at link time; the numbers stay 3 and 4).
//   - exit codes: C's `exit(wasi_ctx->exit_code)` from inside repl_call is
//     recorded and returned from main (daslang uses main's int as the
//     process exit code), skipping the _onfatal epilogue as exit() does.

require daslib/fio
require daslib/strings_boost
require math
require strings
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_module
require modules/wasm3das/source/m3_api_libc
require modules/wasm3das/source/m3_api_wasi
require modules/wasm3das/source/m3_api_wasi_fd


// C: #define MAX_MODULES 16 (Eden: only the counter remains, see the header)
let MAX_MODULES = 16

// C wasm3.h: #define M3_VERSION "0.5.2"
let M3_VERSION = "0.5.2"


var env = M3Environment()
var runtime = M3Runtime()
var haveRuntime = false          // Eden: C's `runtime != NULL`
var argEdenFuseOps = false       // Eden: --eden-fuse-ops, the optional operation fusion (M3Runtime.edenFuseOps)
var wasm_bins_qty = 0

// C repl_call leaves the process through exit(wasi_ctx->exit_code); the
// request travels to main() in these two variables (see the header)
var exit_requested = false
var exit_code = 0


// ============================================================================
// Small C library helpers that Daslang does not provide verbatim
// ============================================================================


def private out_write(text : string) {
    fprint(fstdout(), text)
    fflush(fstdout())
}


def private err_write(text : string) {
    fprint(fstderr(), text)
    fflush(fstderr())
}


// Eden: the guest's buffered stdout / stderr to the real streams (see the header)
def private flush_stdio(var rt : M3Runtime) {
    if (length(rt.stdoutBuffer) > 0) {
        fwrite(fstdout(), rt.stdoutBuffer)
        clear(rt.stdoutBuffer)
    }
    if (length(rt.stderrBuffer) > 0) {
        fwrite(fstderr(), rt.stderrBuffer)
        clear(rt.stderrBuffer)
    }
    fflush(fstdout())
    fflush(fstderr())
}


// A C `const char*` walked by index: the bytes of a string, copied once.
def private str_bytes(text : string) : array<u8> {
    var bytes : array<u8>
    peek_data(text) $(data) {
        bytes := data
    }
    return <- bytes
}


// C fgets(cmd_buff, 2048, stdin). Daslang fgets returns at most 16383
// characters per call, so a line is assembled until the newline arrives.
// Returns "" only at end of file, which is C's `!fgets(...)`.
def private read_line() : string {
    var chunks : array<string>
    while (true) {
        let chunk = fgets(fstdin())
        if (empty(chunk)) {
            break
        }
        push(chunks, chunk)
        if (ends_with(chunk, "\n")) {
            break
        }
    }
    return join(chunks, "")
}


// C strtoul/strtoull with base 10. Wraps like the C unsigned conversion; a
// leading '-' negates, as strtoul does.
def private strtoull_10(text : string) : u64 {
    let s <- str_bytes(text)
    let n = length(s)
    var i = 0
    while (i < n) {
        let c = int(s[i])
        if (c != 32 && (c < 9 || c > 13)) {
            break
        }
        i++
    }
    var negative = false
    if (i < n) {
        let c = int(s[i])
        if (c == 45) {
            negative = true
            i++
        } elif (c == 43) {
            i++
        }
    }
    var value = 0ul
    while (i < n) {
        let c = int(s[i])
        if (!is_number(c)) {
            break
        }
        value = value * 10ul + u64(c - 48)
        i++
    }
    return negative ? 0ul - value : value
}


// C printf "%" PRIu32 / "%" PRIu64: Daslang renders u32 / u64 in hexadecimal
// in string interpolation, so the unsigned decimal form is built here.
def private utoa(i_value : u64) : string {
    if (i_value == 0ul) {
        return "0"
    }
    var digits : array<int>
    var value = i_value
    while (value != 0ul) {
        push(digits, int(value % 10ul))
        value /= 10ul
    }
    let count = length(digits)
    return build_string() $(var w) {
        for (i in 0 .. count) {
            write_char(w, 48 + digits[count - 1 - i])
        }
    }
}


// C isxdigit + strtol(hex, NULL, 16) on a two character buffer.
def private hex_value(c : int) : int {
    if (is_number(c)) {
        return c - 48
    }
    if (c >= 97 && c <= 102) {
        return c - 87
    }
    if (c >= 65 && c <= 70) {
        return c - 55
    }
    return -1
}


// ============================================================================
// Eden: the WASI file-system backend over fio (DESIGN 4.7b-wasi)
// ============================================================================


// One backend handle past the standard streams: handle = 3 + index.
struct FioHandle {
    f : FILE const? = null
    isOpen : bool = false
    isDir : bool = false
    path : string = ""
    flags : int = 0
    dirPos : i64 = 0l
}


let FIO_FIRST_HANDLE = 3

var fio_handles : array<FioHandle>
var backendToken = -1           // the WASI context the backend is installed in


def private fio_index(handle : int) : int {
    let k = handle - FIO_FIRST_HANDLE
    if (k >= 0 && k < length(fio_handles) && fio_handles[k].isOpen) {
        return k
    }
    return -1
}


def private fio_new_handle(f : FILE const?; isDir : bool; path : string; flags : int) : int {
    var k = -1
    for (i in range(length(fio_handles))) {
        if (!fio_handles[i].isOpen) {
            k = i
            break
        }
    }
    if (k == -1) {
        push(fio_handles, FioHandle())
        k = length(fio_handles) - 1
    }
    fio_handles[k].f = f
    fio_handles[k].isOpen = true
    fio_handles[k].isDir = isDir
    fio_handles[k].path = path
    fio_handles[k].flags = flags
    fio_handles[k].dirPos = 0l
    return FIO_FIRST_HANDLE + k
}


// C openat(dirfd, path, flags, mode): the path resolves against the
// directory handle (AT_FDCWD = the cwd; an absolute path ignores it)
def private fio_open(dirHandle : int; path : string; flags : int) : int {
    var fullPath = path
    if (!(length(path) > 0 && character_at(path, 0) == '/')) {
        if (dirHandle == AT_FDCWD) {
            fullPath = path
        } elif (dirHandle >= 0 && dirHandle <= 2) {
            return -ENOTDIR
        } else {
            let dk = fio_index(dirHandle)
            if (dk == -1) {
                return -EBADF
            }
            if (!fio_handles[dk].isDir) {
                return -ENOTDIR
            }
            fullPath = "{fio_handles[dk].path}/{path}"
        }
    }
    var st : FStat
    let exists = stat(fullPath, st)
    let acc = flags & O_ACCMODE
    if (exists && st.is_dir) {
        // Linux do_open / may_open on an existing directory
        if ((flags & O_CREAT) != 0) {
            return (flags & O_EXCL) != 0 ? -EEXIST : -EISDIR
        }
        if (acc != O_RDONLY || (flags & O_TRUNC) != 0) {
            return -EISDIR
        }
        return fio_new_handle(null, true, fullPath, flags)
    }
    if ((flags & O_DIRECTORY) != 0) {
        return exists ? -ENOTDIR : -ENOENT
    }
    if (exists && (flags & O_CREAT) != 0 && (flags & O_EXCL) != 0) {
        return -EEXIST
    }
    if (!exists && (flags & O_CREAT) == 0) {
        return -ENOENT
    }
    let append = (flags & O_APPEND) != 0
    var mode = "rb"
    if (acc == O_RDONLY) {
        if (!exists) {
            // O_CREAT|O_RDONLY: create the empty file, then open it for reading
            let c = fopen(fullPath, "wb")
            if (c == null) {
                return -ENOENT
            }
            fclose(c)
        }
        mode = "rb"
    } elif (!exists || (flags & O_TRUNC) != 0) {
        if (append) {
            mode = acc == O_WRONLY ? "ab" : "a+b"
        } else {
            mode = acc == O_WRONLY ? "wb" : "w+b"
        }
    } else {
        if (append) {
            mode = acc == O_WRONLY ? "ab" : "a+b"
        } else {
            mode = "r+b"
        }
    }
    let f = fopen(fullPath, mode)
    if (f == null) {
        return exists ? -EACCES : -ENOENT
    }
    return fio_new_handle(f, false, fullPath, flags)
}


// C readv: fills the iovecs in order, a short read ends the call
def private fio_readv(handle : int; var bufs : array<array<u8>>) : int {
    var f : FILE const? = null
    if (handle == 0) {
        f = fstdin()
    } elif (handle == 1 || handle == 2) {
        return -EBADF
    } else {
        let k = fio_index(handle)
        if (k == -1) {
            return -EBADF
        }
        if (length(bufs) > IOV_MAX) {
            return -EINVAL
        }
        if (fio_handles[k].isDir) {
            var total = 0
            for (b in bufs) {
                total += length(b)
            }
            return total == 0 ? 0 : -EISDIR
        }
        if ((fio_handles[k].flags & O_ACCMODE) == O_WRONLY) {
            return -EBADF
        }
        f = fio_handles[k].f
    }
    if (length(bufs) > IOV_MAX) {
        return -EINVAL
    }
    var n = 0
    for (b in bufs) {
        let want = length(b)
        if (want == 0) {
            continue
        }
        let got = fread(f, b)
        if (got > 0) {
            n += got
        }
        if (got < want) {
            break
        }
    }
    return n
}


// C writev: the iovecs in order; fd 1 / 2 first flush what the guest
// buffered through libc, so the output keeps its order
def private fio_writev(var rt : M3Runtime; handle : int; bufs : array<array<u8>>) : int {
    var f : FILE const? = null
    if (handle == 1 || handle == 2) {
        flush_stdio(rt)
        f = handle == 1 ? fstdout() : fstderr()
    } elif (handle == 0) {
        return -EBADF
    } else {
        let k = fio_index(handle)
        if (k == -1) {
            return -EBADF
        }
        if (fio_handles[k].isDir || (fio_handles[k].flags & O_ACCMODE) == O_RDONLY) {
            return length(bufs) > IOV_MAX ? -EINVAL : -EBADF
        }
        f = fio_handles[k].f
    }
    if (length(bufs) > IOV_MAX) {
        return -EINVAL
    }
    var n = 0
    for (b in bufs) {
        if (length(b) == 0) {
            continue
        }
        let put = fwrite(f, b)
        if (put > 0) {
            n += put
        }
        if (put < length(b)) {
            break
        }
    }
    return n
}


def private fio_lseek(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_lseek(rt, handle, offset, whence)
    }
    let k = fio_index(handle)
    if (k == -1) {
        return i64(-EBADF)
    }
    if (fio_handles[k].isDir) {
        var target = 0l
        if (whence == SEEK_SET) {
            target = offset
        } elif (whence == SEEK_CUR) {
            target = fio_handles[k].dirPos + offset
        } else {
            return i64(-EINVAL)
        }
        if (target < 0l) {
            return i64(-EINVAL)
        }
        fio_handles[k].dirPos = target
        return target
    }
    if (whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) {
        return i64(-EINVAL)
    }
    let f = fio_handles[k].f
    if (whence == SEEK_CUR && offset + ftell(f) < 0l) {
        return i64(-EINVAL)
    }
    if (fseek(f, offset, whence) != 0l) {
        return i64(-EINVAL)
    }
    return ftell(f)
}


def private fio_close(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_close(rt, handle)
    }
    let k = fio_index(handle)
    if (k == -1) {
        return -EBADF
    }
    if (fio_handles[k].f != null) {
        fclose(fio_handles[k].f)
    }
    fio_handles[k] = FioHandle()
    return 0
}


def private fio_fdatasync(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_fdatasync(rt, handle)
    }
    let k = fio_index(handle)
    if (k == -1) {
        return -EBADF
    }
    if (fio_handles[k].f != null) {
        fflush(fio_handles[k].f)
    }
    return 0
}


def private fio_fcntl_getfl(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_fcntl_getfl(rt, handle)
    }
    let k = fio_index(handle)
    if (k == -1) {
        return -EBADF
    }
    if (fio_handles[k].isDir) {
        return O_RDONLY | O_DIRECTORY
    }
    return fio_handles[k].flags & (O_ACCMODE | O_APPEND | O_NONBLOCK | O_DSYNC | O_SYNC)
}


def private fio_fstat_mode(var rt : M3Runtime; handle : int) : int {
    if (handle >= 0 && handle <= 2) {
        return wasi_default_fstat_mode(rt, handle)
    }
    let k = fio_index(handle)
    if (k == -1) {
        return -EBADF
    }
    return fio_handles[k].isDir ? S_IFDIR : S_IFREG
}


// Eden: installs the fio backend in the WASI context and reopens the
// preopens through it (see the header). Once per context.
def private install_fio_backend() {
    let token = m3_GetWasiContext()
    if (!m3_IsWasiContext(token) || token == backendToken) {
        return
    }
    for (i in 3..PREOPEN_CNT) {
        let fd = preopen[i].fd
        if (fd >= 0 && fd < length(m3_wasi_contexts[token].fds)) {
            let h = m3_wasi_contexts[token].fds[fd]
            if (h >= 0) {
                wasi_default_close(runtime, h)
            }
            m3_wasi_contexts[token].fds[fd] = -1
        }
        preopen[i].fd = -1
    }
    var backend = M3WasiFsBackend()
    backend.open <- @(var rt : M3Runtime; dirHandle : int; path : string; flags : int; mode : int) : int {
        return fio_open(dirHandle, path, flags)
    }
    backend.readv <- @(var rt : M3Runtime; handle : int; var bufs : array<array<u8>>) : int {
        return fio_readv(handle, bufs)
    }
    backend.writev <- @(var rt : M3Runtime; handle : int; bufs : array<array<u8>>) : int {
        return fio_writev(rt, handle, bufs)
    }
    backend.lseek <- @(var rt : M3Runtime; handle : int; offset : i64; whence : int) : i64 {
        return fio_lseek(rt, handle, offset, whence)
    }
    backend.close <- @(var rt : M3Runtime; handle : int) : int {
        return fio_close(rt, handle)
    }
    backend.fdatasync <- @(var rt : M3Runtime; handle : int) : int {
        return fio_fdatasync(rt, handle)
    }
    backend.fcntl_getfl <- @(var rt : M3Runtime; handle : int) : int {
        return fio_fcntl_getfl(rt, handle)
    }
    backend.fstat_mode <- @(var rt : M3Runtime; handle : int) : int {
        return fio_fstat_mode(rt, handle)
    }
    m3_SetWasiFsBackend(token, backend)
    backendToken = token
    wasi_fd_open_preopens(runtime, token)
}


// ============================================================================
// main.c
// ============================================================================


/*
    C link_all calls m3_LinkSpecTest, m3_LinkLibC and, when built with WASI,
    m3_LinkWASI (the tracer and gas blocks are not part of this build).
    Eden: then installs the fio backend in the WASI context (see the header).
*/
def link_all(_module : IM3Module) : M3Result {
    if (_module == -1) {
        return m3Err_moduleNotLinked
    }
    var res = m3_LinkSpecTest(runtime, _module)
    if (res != m3Err_none) {
        return res
    }

    res = m3_LinkLibC(runtime, _module)
    if (res != m3Err_none) {
        return res
    }

    res = m3_LinkWASI(runtime, _module)
    if (res != m3Err_none) {
        return res
    }

    install_fio_backend()   // Eden: see the header

    return res
}


def modname_from_fn(fn : string) : string {
    let sep <- str_bytes("/\\:*?")
    let s <- str_bytes(fn)
    // C advances `fn` past the last occurrence of each separator in turn
    var start = 0
    for (si in 0 .. length(sep)) {
        let c = sep[si]
        var off = -1
        for (i in start .. length(s)) {
            if (s[i] == c) {
                off = i
            }
        }
        if (off >= 0) {
            start = off + 1
        }
    }
    return start == 0 ? fn : slice(fn, start)
}


def repl_load(fn : string) : M3Result {
    var result : M3Result = m3Err_none
    var _module : IM3Module = -1

    var wasm : array<u8>
    var fsize : u32 = 0u

    let f = fopen(fn, "rb")
    if (f == null) {
        return "cannot open file"
    }
    fseek(f, 0l, seek_end)
    fsize = u32(ftell(f))
    fseek(f, 0l, seek_set)

    if (fsize < 8u) {
        fclose(f)
        return "file is too small"
    } elif (fsize > 256u * 1024u * 1024u) {
        fclose(f)
        return "file is too big"
    }

    resize(wasm, int(fsize))
    if (fread(f, wasm) != int(fsize)) {
        fclose(f)
        return "cannot read file"
    }
    fclose(f)

    let parsed = m3_ParseModule(runtime, wasm)
    result = parsed._0
    _module = parsed._1
    if (result != m3Err_none) {
        // C on_error: m3_FreeModule(module) then free(wasm)
        m3_FreeModule(runtime, _module)
        return result
    }

    result = m3_LoadModule(runtime, _module)
    if (result != m3Err_none) {
        m3_FreeModule(runtime, _module)
        return result
    }

    m3_SetModuleName(runtime, _module, modname_from_fn(fn))

    result = link_all(_module)
    if (result != m3Err_none) {
        m3_FreeModule(runtime, _module)
        return result
    }

    // C: if (wasm_bins_qty < MAX_MODULES) wasm_bins[wasm_bins_qty++] = wasm;
    // Eden: the runtime keeps its own copy (see the header)
    if (wasm_bins_qty < MAX_MODULES) {
        wasm_bins_qty++
    }

    return result
}


def repl_load_hex(fsize : u32) : M3Result {
    var result : M3Result = m3Err_none

    if (fsize < 8u) {
        return "file is too small"
    } elif (fsize > 10u * 1024u * 1024u) {
        return "file too big"
    }

    var wasm : array<u8>
    resize(wasm, int(fsize))

    {   // Load hex data from stdin
        var wasm_idx = 0
        var hi = -1
        var sawEol = false
        while (!sawEol) {
            // C reads stdin one character at a time until fsize bytes are
            // decoded, then consumes the newline with fgets; the line is
            // consumed in fgets-sized chunks here (as upstream), non-hex
            // characters are skipped the same way
            let chunk = fgets(fstdin())
            if (empty(chunk)) {
                return "cannot read EOL"
            }
            let s <- str_bytes(chunk)
            let n = length(s)
            for (k in 0 .. n) {
                let d = hex_value(int(s[k]))
                if (d < 0) {
                    continue
                }
                if (hi < 0) {
                    hi = d
                } else {
                    if (wasm_idx < int(fsize)) {
                        wasm[wasm_idx] = u8(hi * 16 + d)
                        wasm_idx++
                    }
                    hi = -1
                }
            }
            if (s[n - 1] == u8(10)) {
                sawEol = true
            }
        }
        if (wasm_idx != int(fsize)) {
            return "cannot read file"
        }
    }

    let parsed = m3_ParseModule(runtime, wasm)
    result = parsed._0
    let _module = parsed._1
    if (result != m3Err_none) {
        return result
    }

    result = m3_LoadModule(runtime, _module)
    if (result != m3Err_none) {
        return result
    }

    result = link_all(_module)

    return result
}


// C print_backtrace walks m3_GetBacktrace; d_m3RecordBacktraces is off, so
// the info is empty (C: NULL) and nothing is printed.
def print_backtrace() {
    let info <- m3_GetBacktrace(runtime)
    if (length(info.frames) == 0) {
        return
    }
    err_write("==== wasm backtrace:\n")
}


// C passes `argv + start`; the tail is copied.
def private argv_tail(argv : array<string>; start : int) : array<string> {
    var result : array<string>
    for (i in start .. length(argv)) {
        push(result, argv[i])
    }
    return <- result
}


def repl_call(name : string; argc : int; argv : array<string>) : M3Result {
    var func : IM3Function = -1
    var result = m3_FindFunction(runtime, func, name)
    if (result != m3Err_none) {
        return result
    }

    if (argc != 0 && (name == "main" || name == "_main")) {
        return "passing arguments to libc main() not implemented"
    }

    if (name == "_start") {
        // C: #if defined(LINK_WASI)
        var wasi_argv <- argv_tail(argv, 0)

        // Strip wasm file path
        if (argc > 0) {
            wasi_argv[0] = modname_from_fn(wasi_argv[0])
        }

        let wasi_ctx = m3_GetWasiContext()   // Eden: the context token
        if (m3_IsWasiContext(wasi_ctx)) {
            m3_wasi_contexts[wasi_ctx].argc = u32(argc)
            m3_wasi_contexts[wasi_ctx].argv := wasi_argv
        }

        // C: m3_CallArgv(func, 0, NULL)
        var no_argv : array<string>
        result = m3_CallArgv(runtime, func, no_argv)
        flush_stdio(runtime)   // Eden: see the header

        if (result == m3Err_trapExit) {
            // C: exit(wasi_ctx->exit_code) (see the header)
            exit_requested = true
            exit_code = m3_IsWasiContext(wasi_ctx) ? m3_wasi_contexts[wasi_ctx].exit_code : 0
        }

        return result
    }

    let arg_count = int(m3_GetArgCount(runtime, func))
    let ret_count = int(m3_GetRetCount(runtime, func))
    if (argc < arg_count) {
        return "not enough arguments"
    } elif (argc > arg_count) {
        return "too many arguments"
    }

    result = m3_CallArgv(runtime, func, argv)
    flush_stdio(runtime)   // Eden: see the header
    if (result != m3Err_none) {
        return result
    }

    var valbuff : array<u64>
    result = m3_GetResults(runtime, func, u32(ret_count), valbuff)
    if (result != m3Err_none) {
        return result
    }

    if (ret_count <= 0) {
        err_write("Result: <Empty Stack>\n")
    }
    for (i in 0 .. ret_count) {
        let _type = m3_GetRetType(runtime, func, u32(i))
        if (_type == M3ValueType.c_m3Type_i32) {
            err_write("Result: {m3_bits_to_i32(valbuff[i])}\n")
        } elif (_type == M3ValueType.c_m3Type_i64) {
            err_write("Result: {m3_bits_to_i64(valbuff[i])}\n")
        } elif (_type == M3ValueType.c_m3Type_f32) {
            // C uses PRIf32 ("%f"); Daslang prints the shortest round-trip form (as upstream)
            err_write("Result: {m3_bits_to_f32(valbuff[i])}\n")
        } elif (_type == M3ValueType.c_m3Type_f64) {
            err_write("Result: {m3_bits_to_f64(valbuff[i])}\n")
        } else {
            return "unknown return type"
        }
    }

    return result
}


// :invoke is used by spec tests, so it treats floats as raw data
def repl_invoke(name : string; argc : int; argv : array<string>) : M3Result {
    var func : IM3Function = -1
    var result = m3_FindFunction(runtime, func, name)
    if (result != m3Err_none) {
        return result
    }

    let arg_count = int(m3_GetArgCount(runtime, func))
    let ret_count = int(m3_GetRetCount(runtime, func))

    if (argc > 128) {
        return "arguments limit reached"
    } elif (argc < arg_count) {
        return "not enough arguments"
    } elif (argc > arg_count) {
        return "too many arguments"
    }

    // C: static uint64_t valbuff[128]; Eden: the argument bits (m3_Call)
    var valbuff : array<u64>
    for (i in 0 .. argc) {
        let _type = m3_GetArgType(runtime, func, u32(i))
        if (_type == M3ValueType.c_m3Type_i32 || _type == M3ValueType.c_m3Type_f32) {
            // C: *(u32*)(s) = strtoul(argv[i], NULL, 10)
            push(valbuff, u64(u32(strtoull_10(argv[i]))))
        } elif (_type == M3ValueType.c_m3Type_i64 || _type == M3ValueType.c_m3Type_f64) {
            // C: *(u64*)(s) = strtoull(argv[i], NULL, 10)
            push(valbuff, strtoull_10(argv[i]))
        } else {
            return "unknown argument type"
        }
    }

    result = m3_Call(runtime, func, valbuff)
    flush_stdio(runtime)   // Eden: see the header
    if (result != m3Err_none) {
        return result
    }

    // reuse valbuff for return values
    clear(valbuff)
    result = m3_GetResults(runtime, func, u32(ret_count), valbuff)
    if (result != m3Err_none) {
        return result
    }

    // formatted first so that "unknown return type" leaves no partial line (as upstream)
    var values : array<string>
    for (i in 0 .. ret_count) {
        let _type = m3_GetRetType(runtime, func, u32(i))
        if (_type == M3ValueType.c_m3Type_i32) {
            push(values, "{utoa(valbuff[i] & 0xFFFFFFFFul)}:i32")
        } elif (_type == M3ValueType.c_m3Type_f32) {
            push(values, "{utoa(valbuff[i] & 0xFFFFFFFFul)}:f32")
        } elif (_type == M3ValueType.c_m3Type_i64) {
            push(values, "{utoa(valbuff[i])}:i64")
        } elif (_type == M3ValueType.c_m3Type_f64) {
            push(values, "{utoa(valbuff[i])}:f64")
        } else {
            return "unknown return type"
        }
    }
    if (ret_count <= 0) {
        err_write("Result: <Empty Stack>\n")
    } else {
        err_write("Result: {join(values, ", ")}\n")
    }

    return result
}


def repl_global_get(name : string) : M3Result {
    // C: m3_FindGlobal(runtime->modules, name); Eden: the list head (see the header)
    let first = Runtime_FirstModule(runtime)
    let g = first != -1 ? m3_FindGlobal(runtime, first, name) : -1

    var tagged = M3TaggedValue()
    let err = m3_GetGlobal(runtime, g, tagged)
    if (err != m3Err_none) {
        return err
    }

    if (tagged._type == M3ValueType.c_m3Type_i32) {
        err_write("{utoa(u64(u32(tagged_get_i32(tagged))))}:i32\n")
    } elif (tagged._type == M3ValueType.c_m3Type_i64) {
        err_write("{utoa(u64(tagged_get_i64(tagged)))}:i64\n")
    } elif (tagged._type == M3ValueType.c_m3Type_f32) {
        // C uses PRIf32/PRIf64 ("%f"); Daslang prints the shortest round-trip form (as upstream)
        err_write("{tagged_get_f32(tagged)}:f32\n")
    } elif (tagged._type == M3ValueType.c_m3Type_f64) {
        err_write("{tagged_get_f64(tagged)}:f64\n")
    } else {
        return m3Err_invalidTypeId
    }
    return m3Err_none
}


def repl_global_set(name : string; value : string) : M3Result {
    let first = Runtime_FirstModule(runtime)
    let g = first != -1 ? m3_FindGlobal(runtime, first, name) : -1

    var tagged = M3TaggedValue()
    tagged._type = m3_GetGlobalType(runtime, g)

    if (tagged._type == M3ValueType.c_m3Type_i32) {
        tagged_set_i32(tagged, i32(u32(strtoull_10(value))))
    } elif (tagged._type == M3ValueType.c_m3Type_i64) {
        tagged_set_i64(tagged, i64(strtoull_10(value)))
    } elif (tagged._type == M3ValueType.c_m3Type_f32) {
        tagged_set_f32(tagged, float(to_double(value)))
    } elif (tagged._type == M3ValueType.c_m3Type_f64) {
        tagged_set_f64(tagged, to_double(value))
    } else {
        return m3Err_invalidTypeId
    }

    return m3_SetGlobal(runtime, g, tagged)
}


def repl_compile() : M3Result {
    let first = Runtime_FirstModule(runtime)
    if (first == -1) {
        return "no modules loaded"   // Eden: C dereferences NULL (see the header)
    }
    return m3_CompileModule(runtime, first)
}


def repl_dump() : M3Result {
    var len = 0u
    let mem = m3_GetMemory(runtime, len, 0u)
    if (mem != -1) {
        let f = fopen("wasm3_dump.bin", "wb")
        if (f == null) {
            return "cannot open file"
        }
        if (fwrite(f, runtime.mem) != int(len)) {
            fclose(f)
            return "cannot write file"
        }
        fclose(f)
    }
    return m3Err_none
}


def repl_free() {
    if (haveRuntime) {
        m3_FreeRuntime(runtime)
        haveRuntime = false
    }
    wasm_bins_qty = 0
}


def repl_init(stack : u32) : M3Result {
    repl_free()
    runtime <- m3_NewRuntime(env, stack, -1)
    runtime.edenFuseOps = argEdenFuseOps
    haveRuntime = true
    // C: if (runtime == NULL) return "m3_NewRuntime failed"; Eden: a value, cannot fail
    return m3Err_none
}


/*
    C main.c names this static helper `unescape`; spelled unescape_argv
    because the strings module exports its own `unescape` (as upstream).
*/
def private unescape_argv(buff : string) : string {
    let s <- str_bytes(buff)
    let n = length(s)
    return build_string() $(var w) {
        var i = 0
        while (i < n) {
            let c = int(s[i])
            if (c == 92 && i + 1 < n) {       // '\\'
                let e = int(s[i + 1])
                if (e == 48) {                // '0'
                    write_char(w, 0)
                } elif (e == 98) {            // 'b'
                    write_char(w, 8)
                } elif (e == 110) {           // 'n'
                    write_char(w, 10)
                } elif (e == 114) {           // 'r'
                    write_char(w, 13)
                } elif (e == 116) {           // 't'
                    write_char(w, 9)
                } elif (e == 120 && i + 3 < n) {   // 'x'
                    let hi = hex_value(int(s[i + 2]))
                    let lo = hex_value(int(s[i + 3]))
                    write_char(w, max(hi, 0) * 16 + max(lo, 0))
                    i += 2
                } else {
                    // Otherwise just pass the letter. Also handles '\\'
                    write_char(w, e)
                }
                i += 2
            } else {
                write_char(w, c)
                i++
            }
        }
    }
}


// C split_argv: words separated by space, \n, \r, \t
def private split_argv(str : string) : array<string> {
    var result : array<string>
    for (word in split_by_chars(str, " \n\r\t")) {
        if (!empty(word)) {
            push(result, word)
        }
    }
    return <- result
}


/*
    The option words still accepted *after* the file operand (the rescan
    deviation of upstream, see main_run). Only the long spellings: a wasm
    program's own `-f` argument must not be swallowed.
*/
def private is_post_file_option(arg : string) : bool {
    for (opt in fixed_array("--help", "--wasm3-help", "--version", "--repl", "--dump-on-trap", "--compile", "--stack-size", "--gas-limit", "--dir", "--func")) {
        if (arg == opt) {
            return true
        }
    }
    return false
}


def print_version() {
    let wasm3_env = get_env_variable("WASM3")
    let wasm3_arch = get_env_variable("WASM3_ARCH")

    let self_hosting = (!empty(wasm3_arch) || !empty(wasm3_env)) ? " self-hosting" : ""
    let arch = !empty(wasm3_arch) ? wasm3_arch : M3_ARCH
    out_write("Wasm3 v{M3_VERSION}{self_hosting} on {arch}\n")

    // C: "Build: " __DATE__ " " __TIME__ ", " M3_COMPILER_VER
    out_write("Build: Daslang Eden port, {M3_COMPILER_VER}\n")
}


def print_usage() {
    out_write("Usage:\n")
    out_write("  wasm3 [options] <file> [args...]\n")
    out_write("  wasm3 --repl [file]\n")
    out_write("Options:\n")
    out_write("  --func <function>     function to run       default: _start\n")
    out_write("  --stack-size <size>   stack size in bytes   default: 64KB\n")
    out_write("  --compile             disable lazy compilation\n")
    out_write("  --dump-on-trap        dump wasm memory\n")
    out_write("  --gas-limit           set gas limit\n")
    out_write("  --eden-fuse-ops       optional operation fusion (Eden; off = C's operations)\n")
}


// The process arguments as C main() sees them: argv[0] is the program name,
// the rest is everything after `--`.
def private process_argv() : array<string> {
    var result : array<string>
    push(result, "wasm3")
    var seen = false
    for (a in get_command_line_arguments()) {
        if (seen) {
            push(result, a)
        } elif (a == "--") {
            seen = true
        }
    }
    return <- result
}


/*
    C main() up to the `_onfatal` label. -1 is the C `goto _onfatal`; any
    other value is one of C main()'s early `return N` statements.
*/
def private main_run(var result : M3Result&) : int {
    var argRepl = false
    var argDumpOnTrap = false
    var argCompile = false
    var argFile = ""
    var haveFile = false
    var argFunc = "_start"
    var argStackSize = 64u * 1024u

    let i_argv <- process_argv()
    var i_pos = 0
    var i_argc = length(i_argv)

    // ARGV_SHIFT(): skip executable name
    i_argc--
    i_pos++

    var scanning = true
    while (scanning) {
        while (i_argc > 0) {
            let arg = i_argv[i_pos]
            // C: `if (arg[0] != '-') break`; the second half is upstream's
            // rescan deviation (only known option words after the file)
            let notOption = first_character(arg) != 45
            if (notOption || (haveFile && !is_post_file_option(arg))) {
                break
            }

            i_argc--
            i_pos++
            // --wasm3-help is the alias scripts/eden/wasm3 substitutes for
            // --help and -h, which the daslang CLI consumes
            if (arg == "--help" || arg == "-h" || arg == "--wasm3-help") {
                print_usage()
                return 0
            } elif (arg == "--version") {
                print_version()
                return 0
            } elif (arg == "--repl") {
                argRepl = true
            } elif (arg == "--dump-on-trap") {
                argDumpOnTrap = true
            } elif (arg == "--eden-fuse-ops") {
                argEdenFuseOps = true
            } elif (arg == "--compile") {
                argCompile = true
            } elif (arg == "--stack-size") {
                var tmp = "65536"
                if (i_argc > 0) {
                    tmp = i_argv[i_pos]
                    i_argc--
                    i_pos++
                }
                argStackSize = u32(strtoull_10(tmp))
            } elif (arg == "--gas-limit") {
                // gas metering is not ported; the value is consumed and ignored
                if (i_argc > 0) {
                    i_argc--
                    i_pos++
                }
            } elif (arg == "--dir") {
                if (i_argc > 0) {
                    i_argc--
                    i_pos++
                }
            } elif (arg == "--func" || arg == "-f") {
                if (i_argc > 0) {
                    argFunc = i_argv[i_pos]
                    i_argc--
                    i_pos++
                }
            }
        }

        if (haveFile || i_argc <= 0) {
            break
        }

        if ((argRepl && i_argc > 1) || (!argRepl && i_argc < 1)) {
            print_usage()
            return 1
        }

        // ARGV_SET(argFile)
        argFile = i_argv[i_pos]
        haveFile = true
        i_argc--
        i_pos++

        // upstream deviation: rescan the option words main.c knows after the file
        scanning = i_argc > 0 && is_post_file_option(i_argv[i_pos])
    }

    if (!haveFile) {
        if ((argRepl && i_argc > 1) || (!argRepl && i_argc < 1)) {
            print_usage()
            return 1
        }
    }

    result = repl_init(argStackSize)
    if (result != m3Err_none) {
        err_write("Error: [Fatal] repl_init: {result}\n")
        return -1
    }

    if (haveFile) {
        result = repl_load(argFile)
        if (result != m3Err_none) {
            err_write("Error: [Fatal] repl_load: {result}\n")
            return -1
        }

        if (argCompile) {
            repl_compile()
        }

        if (!argRepl) {
            if (argFunc == "_start") {
                // C: repl_call(argFunc, i_argc+1, i_argv-1): the wasm file name is argv[0]
                result = repl_call(argFunc, i_argc + 1, argv_tail(i_argv, i_pos - 1))
            } else {
                result = repl_call(argFunc, i_argc, argv_tail(i_argv, i_pos))
            }

            // C: repl_call already left the process through exit()
            if (exit_requested) {
                return -1
            }

            if (result != m3Err_none) {
                if (argDumpOnTrap) {
                    repl_dump()
                }
                print_backtrace()
                return -1
            }
        }
    }

    while (argRepl) {
        out_write("wasm3> ")
        let cmd_buff = read_line()
        if (empty(cmd_buff)) {
            return 0
        }
        let argv <- split_argv(cmd_buff)
        let argc = length(argv)
        if (argc <= 0) {
            continue
        }
        result = m3Err_none
        if (argv[0] == ":init") {
            result = repl_init(argStackSize)
        } elif (argv[0] == ":version") {
            print_version()
        } elif (argv[0] == ":exit") {
            repl_free()
            return 0
        } elif (argv[0] == ":load") {               // :load <filename>
            result = argc > 1 ? repl_load(argv[1]) : "not enough arguments"
        } elif (argv[0] == ":load-hex") {           // :load-hex <size>\n <hex-encoded-binary>
            result = argc > 1 ? repl_load_hex(u32(strtoull_10(argv[1]))) : "not enough arguments"
        } elif (argv[0] == ":get-global") {
            result = argc > 1 ? repl_global_get(argv[1]) : "not enough arguments"
        } elif (argv[0] == ":set-global") {
            result = argc > 2 ? repl_global_set(argv[1], argv[2]) : "not enough arguments"
        } elif (argv[0] == ":dump") {
            result = repl_dump()
        } elif (argv[0] == ":compile") {
            result = repl_compile()
        } elif (argv[0] == ":invoke") {
            result = argc > 1 ? repl_invoke(unescape_argv(argv[1]), argc - 2, argv_tail(argv, 2)) : "not enough arguments"
        } elif (first_character(argv[0]) == 58) {   // ':'
            result = "no such command"
        } else {
            result = repl_call(unescape_argv(argv[0]), argc - 1, argv_tail(argv, 1))
            if (exit_requested) {
                return -1
            }
            if (result != m3Err_none) {
                print_backtrace()
            }
        }

        if (result == m3Err_trapExit) {
            // C: TODO fprintf(stderr, M3_ARCH "-wasi: exit(%d)\n", runtime->exit_code)
            pass
        } elif (result != m3Err_none) {
            var info = M3ErrorInfo()
            m3_GetErrorInfo(runtime, info)
            err_write("Error: {result} ({info.message})\n")
        }
    }

    // left only by one of the returns above; with argRepl false control
    // falls through to _onfatal
    return -1
}


[export]
def main : int {
    var result : M3Result = m3Err_none
    env <- m3_NewEnvironment()
    haveRuntime = false

    let early = main_run(result)

    // C: exit(wasi_ctx->exit_code) inside repl_call skips the epilogue
    if (exit_requested) {
        flush_stdio(runtime)
        return exit_code
    }

    if (early >= 0) {
        fflush(fstdout())
        fflush(fstderr())
        return early
    }

    // C: _onfatal:
    if (result != m3Err_none) {
        var text = "Error: {result}"
        if (haveRuntime) {
            var info = M3ErrorInfo()
            m3_GetErrorInfo(runtime, info)
            if (!empty(info.message)) {
                text += " ({info.message})"
            }
        }
        err_write("{text}\n")
    }

    // C: m3_FreeRuntime(runtime); m3_FreeEnvironment(env)
    repl_free()
    m3_FreeEnvironment(env)

    fflush(fstdout())
    fflush(fstderr())
    return result != m3Err_none ? 1 : 0
}
