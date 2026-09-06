options gen2
options indenting = 4

// No `module` declaration, like tests/test_m3_api_libc.das: under dastest a
// test file that names its module does not run the [init] functions of
// required shared modules.

require dastest/testing_boost
require ../source/wasi_core.das


/*
    Component test for wasi_core.das (C wasm3c/source/extra/wasi_core.h).

    The file is a pure ABI declaration, so the test compares it with the C
    header rather than exercising behaviour:

    - every constant group is spot-checked against the `#define` values of
      wasi_core.h, including the first, the last and the ones m3_api_wasi.c
      actually names;
    - the declared widths match the `_Static_assert(sizeof(...))` lines;
    - the `_SIZE`/`_OFF_*` constants match the
      `_Static_assert(offsetof(...))` lines, and the Daslang structs that
      carry the C field names lay out to the same offsets, so a port that
      writes through either spelling writes the same bytes.
*/


// ============================================================================
// Scalar widths (wasi_core.h _Static_assert(sizeof(...)) lines)
// ============================================================================


[test]
def test_typedef_widths(t : T?) {
    t |> equal(typeinfo sizeof(type<wasi_size_t>), 4, "__wasi_size_t is uint32_t")
    t |> equal(typeinfo sizeof(type<wasi_filesize_t>), 8, "__wasi_filesize_t is uint64_t")
    t |> equal(typeinfo sizeof(type<wasi_timestamp_t>), 8, "__wasi_timestamp_t is uint64_t")
    t |> equal(typeinfo sizeof(type<wasi_clockid_t>), 4, "__wasi_clockid_t is uint32_t")
    t |> equal(typeinfo sizeof(type<wasi_errno_t>), 2, "__wasi_errno_t is uint16_t")
    t |> equal(typeinfo sizeof(type<wasi_rights_t>), 8, "__wasi_rights_t is uint64_t")
    t |> equal(typeinfo sizeof(type<wasi_fd_t>), 4, "__wasi_fd_t is uint32_t")
    t |> equal(typeinfo sizeof(type<wasi_filedelta_t>), 8, "__wasi_filedelta_t is int64_t")
    t |> equal(typeinfo sizeof(type<wasi_whence_t>), 1, "__wasi_whence_t is uint8_t")
    t |> equal(typeinfo sizeof(type<wasi_inode_t>), 8, "__wasi_inode_t is uint64_t")
    t |> equal(typeinfo sizeof(type<wasi_filetype_t>), 1, "__wasi_filetype_t is uint8_t")
    t |> equal(typeinfo sizeof(type<wasi_fdflags_t>), 2, "__wasi_fdflags_t is uint16_t")
    t |> equal(typeinfo sizeof(type<wasi_device_t>), 8, "__wasi_device_t is uint64_t")
    t |> equal(typeinfo sizeof(type<wasi_lookupflags_t>), 4, "__wasi_lookupflags_t is uint32_t")
    t |> equal(typeinfo sizeof(type<wasi_oflags_t>), 2, "__wasi_oflags_t is uint16_t")
    t |> equal(typeinfo sizeof(type<wasi_linkcount_t>), 8, "__wasi_linkcount_t is uint64_t")
    t |> equal(typeinfo sizeof(type<wasi_preopentype_t>), 1, "__wasi_preopentype_t is uint8_t")
}


// ============================================================================
// Constant groups
// ============================================================================


[test]
def test_clockid_values(t : T?) {
    t |> equal(WASI_CLOCKID_REALTIME, 0u, "__WASI_CLOCKID_REALTIME")
    t |> equal(WASI_CLOCKID_MONOTONIC, 1u, "__WASI_CLOCKID_MONOTONIC")
    t |> equal(WASI_CLOCKID_PROCESS_CPUTIME_ID, 2u, "__WASI_CLOCKID_PROCESS_CPUTIME_ID")
    t |> equal(WASI_CLOCKID_THREAD_CPUTIME_ID, 3u, "__WASI_CLOCKID_THREAD_CPUTIME_ID")
}


// The full errno list is 77 codes, 0..76, in alphabetical order after
// SUCCESS. The ends, the codes m3_api_wasi.c returns by name and the codes
// errno_to_wasi maps are checked here.
[test]
def test_errno_values(t : T?) {
    t |> equal(WASI_ERRNO_SUCCESS, uint16(0), "__WASI_ERRNO_SUCCESS")
    t |> equal(WASI_ERRNO_2BIG, uint16(1), "__WASI_ERRNO_2BIG")
    t |> equal(WASI_ERRNO_ACCES, uint16(2), "__WASI_ERRNO_ACCES")
    t |> equal(WASI_ERRNO_AGAIN, uint16(6), "__WASI_ERRNO_AGAIN")
    t |> equal(WASI_ERRNO_BADF, uint16(8), "__WASI_ERRNO_BADF")
    t |> equal(WASI_ERRNO_BUSY, uint16(10), "__WASI_ERRNO_BUSY")
    t |> equal(WASI_ERRNO_EXIST, uint16(20), "__WASI_ERRNO_EXIST")
    t |> equal(WASI_ERRNO_INTR, uint16(27), "__WASI_ERRNO_INTR")
    t |> equal(WASI_ERRNO_INVAL, uint16(28), "__WASI_ERRNO_INVAL")
    t |> equal(WASI_ERRNO_IO, uint16(29), "__WASI_ERRNO_IO")
    t |> equal(WASI_ERRNO_ISDIR, uint16(31), "__WASI_ERRNO_ISDIR")
    t |> equal(WASI_ERRNO_MFILE, uint16(33), "__WASI_ERRNO_MFILE")
    t |> equal(WASI_ERRNO_NOENT, uint16(44), "__WASI_ERRNO_NOENT")
    t |> equal(WASI_ERRNO_NOMEM, uint16(48), "__WASI_ERRNO_NOMEM")
    t |> equal(WASI_ERRNO_NOSPC, uint16(51), "__WASI_ERRNO_NOSPC")
    t |> equal(WASI_ERRNO_NOSYS, uint16(52), "__WASI_ERRNO_NOSYS")
    t |> equal(WASI_ERRNO_NOTDIR, uint16(54), "__WASI_ERRNO_NOTDIR")
    t |> equal(WASI_ERRNO_NOTTY, uint16(59), "__WASI_ERRNO_NOTTY")
    t |> equal(WASI_ERRNO_PERM, uint16(63), "__WASI_ERRNO_PERM")
    t |> equal(WASI_ERRNO_PIPE, uint16(64), "__WASI_ERRNO_PIPE")
    t |> equal(WASI_ERRNO_RANGE, uint16(68), "__WASI_ERRNO_RANGE")
    t |> equal(WASI_ERRNO_ROFS, uint16(69), "__WASI_ERRNO_ROFS")
    t |> equal(WASI_ERRNO_SPIPE, uint16(70), "__WASI_ERRNO_SPIPE")
    t |> equal(WASI_ERRNO_SRCH, uint16(71), "__WASI_ERRNO_SRCH")
    t |> equal(WASI_ERRNO_TXTBSY, uint16(74), "__WASI_ERRNO_TXTBSY")
    t |> equal(WASI_ERRNO_XDEV, uint16(75), "__WASI_ERRNO_XDEV")
    t |> equal(WASI_ERRNO_NOTCAPABLE, uint16(76), "__WASI_ERRNO_NOTCAPABLE is the last code")
}


[test]
def test_rights_values(t : T?) {
    t |> equal(WASI_RIGHTS_FD_DATASYNC, 1ul, "__WASI_RIGHTS_FD_DATASYNC")
    t |> equal(WASI_RIGHTS_FD_READ, 2ul, "__WASI_RIGHTS_FD_READ")
    t |> equal(WASI_RIGHTS_FD_SEEK, 4ul, "__WASI_RIGHTS_FD_SEEK")
    t |> equal(WASI_RIGHTS_FD_FDSTAT_SET_FLAGS, 8ul, "__WASI_RIGHTS_FD_FDSTAT_SET_FLAGS")
    t |> equal(WASI_RIGHTS_FD_TELL, 32ul, "__WASI_RIGHTS_FD_TELL")
    t |> equal(WASI_RIGHTS_FD_WRITE, 64ul, "__WASI_RIGHTS_FD_WRITE")
    t |> equal(WASI_RIGHTS_PATH_OPEN, 8192ul, "__WASI_RIGHTS_PATH_OPEN")
    t |> equal(WASI_RIGHTS_SOCK_SHUTDOWN, 268435456ul, "__WASI_RIGHTS_SOCK_SHUTDOWN is the last right")

    // Every right is a distinct single bit, 1 << 0 .. 1 << 28.
    t |> equal(WASI_RIGHTS_SOCK_SHUTDOWN, 1ul << 28u, "the rights are bit flags")

    // m3_wasi_generic_fd_fdstat_get clears exactly these two for fd 0,1,2.
    let tty_mask = WASI_RIGHTS_FD_SEEK | WASI_RIGHTS_FD_TELL
    t |> equal(tty_mask, 36ul, "FD_SEEK | FD_TELL")
}


[test]
def test_whence_and_filetype_values(t : T?) {
    t |> equal(WASI_WHENCE_SET, 0u8, "__WASI_WHENCE_SET")
    t |> equal(WASI_WHENCE_CUR, 1u8, "__WASI_WHENCE_CUR")
    t |> equal(WASI_WHENCE_END, 2u8, "__WASI_WHENCE_END")

    t |> equal(WASI_FILETYPE_UNKNOWN, 0u8, "__WASI_FILETYPE_UNKNOWN")
    t |> equal(WASI_FILETYPE_BLOCK_DEVICE, 1u8, "__WASI_FILETYPE_BLOCK_DEVICE")
    t |> equal(WASI_FILETYPE_CHARACTER_DEVICE, 2u8, "__WASI_FILETYPE_CHARACTER_DEVICE")
    t |> equal(WASI_FILETYPE_DIRECTORY, 3u8, "__WASI_FILETYPE_DIRECTORY")
    t |> equal(WASI_FILETYPE_REGULAR_FILE, 4u8, "__WASI_FILETYPE_REGULAR_FILE")
    t |> equal(WASI_FILETYPE_SOCKET_DGRAM, 5u8, "__WASI_FILETYPE_SOCKET_DGRAM")
    t |> equal(WASI_FILETYPE_SOCKET_STREAM, 6u8, "__WASI_FILETYPE_SOCKET_STREAM")
    t |> equal(WASI_FILETYPE_SYMBOLIC_LINK, 7u8, "__WASI_FILETYPE_SYMBOLIC_LINK")
}


[test]
def test_fdflags_oflags_lookupflags_preopentype(t : T?) {
    t |> equal(WASI_FDFLAGS_APPEND, uint16(1), "__WASI_FDFLAGS_APPEND")
    t |> equal(WASI_FDFLAGS_DSYNC, uint16(2), "__WASI_FDFLAGS_DSYNC")
    t |> equal(WASI_FDFLAGS_NONBLOCK, uint16(4), "__WASI_FDFLAGS_NONBLOCK")
    t |> equal(WASI_FDFLAGS_RSYNC, uint16(8), "__WASI_FDFLAGS_RSYNC")
    t |> equal(WASI_FDFLAGS_SYNC, uint16(16), "__WASI_FDFLAGS_SYNC")

    t |> equal(WASI_OFLAGS_CREAT, uint16(1), "__WASI_OFLAGS_CREAT")
    t |> equal(WASI_OFLAGS_DIRECTORY, uint16(2), "__WASI_OFLAGS_DIRECTORY")
    t |> equal(WASI_OFLAGS_EXCL, uint16(4), "__WASI_OFLAGS_EXCL")
    t |> equal(WASI_OFLAGS_TRUNC, uint16(8), "__WASI_OFLAGS_TRUNC")

    t |> equal(WASI_LOOKUPFLAGS_SYMLINK_FOLLOW, 1u, "__WASI_LOOKUPFLAGS_SYMLINK_FOLLOW")

    t |> equal(WASI_PREOPENTYPE_DIR, 0u8, "__WASI_PREOPENTYPE_DIR")
}


// ============================================================================
// ABI layouts
// ============================================================================


// C: sizeof == 8, buf at 0, buf_len at 4 (the commented-out asserts of the
// header; m3_api_wasi.c relies on them for its own wasi_iovec_t).
[test]
def test_iovec_layout(t : T?) {
    t |> equal(WASI_IOVEC_SIZE, 8u, "sizeof(__wasi_iovec_t)")
    t |> equal(WASI_IOVEC_OFF_BUF, 0u, "offsetof(__wasi_iovec_t, buf)")
    t |> equal(WASI_IOVEC_OFF_BUF_LEN, 4u, "offsetof(__wasi_iovec_t, buf_len)")

    // `typeinfo offsetof` needs a value of the type; the underscore prefix
    // marks it as intentionally never read (LINT002).
    var _iov : wasi_iovec_t
    t |> equal(typeinfo sizeof(type<wasi_iovec_t>), 8, "wasi_iovec_t lays out to 8 bytes")
    t |> equal(typeinfo offsetof < buf > (_iov), 0, "wasi_iovec_t.buf")
    t |> equal(typeinfo offsetof < buf_len > (_iov), 4, "wasi_iovec_t.buf_len")

    var _ciov : wasi_ciovec_t
    t |> equal(typeinfo sizeof(type<wasi_ciovec_t>), 8, "wasi_ciovec_t lays out to 8 bytes")
    t |> equal(typeinfo offsetof < buf > (_ciov), 0, "wasi_ciovec_t.buf")
    t |> equal(typeinfo offsetof < buf_len > (_ciov), 4, "wasi_ciovec_t.buf_len")
}


// C: _Static_assert(sizeof(__wasi_fdstat_t) == 24), offsets 0, 2, 8, 16.
[test]
def test_fdstat_layout(t : T?) {
    t |> equal(WASI_FDSTAT_SIZE, 24u, "sizeof(__wasi_fdstat_t)")
    t |> equal(WASI_FDSTAT_OFF_FS_FILETYPE, 0u, "offsetof fs_filetype")
    t |> equal(WASI_FDSTAT_OFF_FS_FLAGS, 2u, "offsetof fs_flags")
    t |> equal(WASI_FDSTAT_OFF_FS_RIGHTS_BASE, 8u, "offsetof fs_rights_base")
    t |> equal(WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING, 16u, "offsetof fs_rights_inheriting")

    var _fdstat : wasi_fdstat_t
    t |> equal(typeinfo sizeof(type<wasi_fdstat_t>), int(WASI_FDSTAT_SIZE), "wasi_fdstat_t size")
    t |> equal(typeinfo offsetof < fs_filetype > (_fdstat), int(WASI_FDSTAT_OFF_FS_FILETYPE), "wasi_fdstat_t.fs_filetype")
    t |> equal(typeinfo offsetof < fs_flags > (_fdstat), int(WASI_FDSTAT_OFF_FS_FLAGS), "wasi_fdstat_t.fs_flags")
    t |> equal(typeinfo offsetof < fs_rights_base > (_fdstat), int(WASI_FDSTAT_OFF_FS_RIGHTS_BASE), "wasi_fdstat_t.fs_rights_base")
    t |> equal(typeinfo offsetof < fs_rights_inheriting > (_fdstat), int(WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING), "wasi_fdstat_t.fs_rights_inheriting")
}


// C: _Static_assert(sizeof(__wasi_filestat_t) == 64), offsets 0, 8, 16, 24,
// 32, 40, 48, 56.
[test]
def test_filestat_layout(t : T?) {
    t |> equal(WASI_FILESTAT_SIZE, 64u, "sizeof(__wasi_filestat_t)")
    t |> equal(WASI_FILESTAT_OFF_DEV, 0u, "offsetof dev")
    t |> equal(WASI_FILESTAT_OFF_INO, 8u, "offsetof ino")
    t |> equal(WASI_FILESTAT_OFF_FILETYPE, 16u, "offsetof filetype")
    t |> equal(WASI_FILESTAT_OFF_NLINK, 24u, "offsetof nlink")
    t |> equal(WASI_FILESTAT_OFF_SIZE, 32u, "offsetof size")
    t |> equal(WASI_FILESTAT_OFF_ATIM, 40u, "offsetof atim")
    t |> equal(WASI_FILESTAT_OFF_MTIM, 48u, "offsetof mtim")
    t |> equal(WASI_FILESTAT_OFF_CTIM, 56u, "offsetof ctim")

    var _fs : wasi_filestat_t
    t |> equal(typeinfo sizeof(type<wasi_filestat_t>), int(WASI_FILESTAT_SIZE), "wasi_filestat_t size")
    t |> equal(typeinfo offsetof < dev > (_fs), int(WASI_FILESTAT_OFF_DEV), "wasi_filestat_t.dev")
    t |> equal(typeinfo offsetof < ino > (_fs), int(WASI_FILESTAT_OFF_INO), "wasi_filestat_t.ino")
    t |> equal(typeinfo offsetof < filetype > (_fs), int(WASI_FILESTAT_OFF_FILETYPE), "wasi_filestat_t.filetype")
    t |> equal(typeinfo offsetof < nlink > (_fs), int(WASI_FILESTAT_OFF_NLINK), "wasi_filestat_t.nlink")
    t |> equal(typeinfo offsetof < size > (_fs), int(WASI_FILESTAT_OFF_SIZE), "wasi_filestat_t.size")
    t |> equal(typeinfo offsetof < atim > (_fs), int(WASI_FILESTAT_OFF_ATIM), "wasi_filestat_t.atim")
    t |> equal(typeinfo offsetof < mtim > (_fs), int(WASI_FILESTAT_OFF_MTIM), "wasi_filestat_t.mtim")
    t |> equal(typeinfo offsetof < ctim > (_fs), int(WASI_FILESTAT_OFF_CTIM), "wasi_filestat_t.ctim")
}


// C: _Static_assert(sizeof(__wasi_prestat_t) == 8), pr_type at 0, u at 4;
// sizeof(__wasi_prestat_dir_t) == 4 with pr_name_len at 0. This is the layout
// m3_wasi_generic_fd_prestat_get writes as two raw 32-bit words.
[test]
def test_prestat_layout(t : T?) {
    t |> equal(WASI_PRESTAT_SIZE, 8u, "sizeof(__wasi_prestat_t)")
    t |> equal(WASI_PRESTAT_OFF_PR_TYPE, 0u, "offsetof pr_type")
    t |> equal(WASI_PRESTAT_OFF_U, 4u, "offsetof u")
    t |> equal(WASI_PRESTAT_DIR_OFF_PR_NAME_LEN, 0u, "offsetof pr_name_len")

    var _pre : wasi_prestat_t
    t |> equal(typeinfo sizeof(type<wasi_prestat_t>), int(WASI_PRESTAT_SIZE), "wasi_prestat_t size")
    t |> equal(typeinfo offsetof < pr_type > (_pre), int(WASI_PRESTAT_OFF_PR_TYPE), "wasi_prestat_t.pr_type")
    t |> equal(typeinfo offsetof < u > (_pre), int(WASI_PRESTAT_OFF_U), "wasi_prestat_t.u")

    var _dir : wasi_prestat_dir_t
    t |> equal(typeinfo sizeof(type<wasi_prestat_dir_t>), 4, "wasi_prestat_dir_t size")
    t |> equal(typeinfo offsetof < pr_name_len > (_dir), 0, "wasi_prestat_dir_t.pr_name_len")
}
