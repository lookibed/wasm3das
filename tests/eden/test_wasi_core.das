options gen2
options indenting = 4

module test_wasi_core shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/wasi_core

/*
    test_wasi_core.das: Eden counterpart of
    .upstream/tests/integration/test_wasi_core.das (C
    wasm3c/source/extra/wasi_core.h).

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

    All ten upstream [test]s are ported with the same values and messages;
    `t |> equal(a, b, msg)` becomes `equal(t, a, b, msg)`.
    Eden: the struct values `typeinfo offsetof` needs are initialized
    (`wasi_iovec_t()` instead of `var _iov : wasi_iovec_t`, DESIGN section 6:
    the sandbox refuses an uninitialized struct variable).
*/


// ============================================================================
// Scalar widths (wasi_core.h _Static_assert(sizeof(...)) lines)
// ============================================================================


def test_typedef_widths(var t : TestRun; fx : FixtureSource) {
    equal(t, typeinfo sizeof(type<wasi_size_t>), 4, "__wasi_size_t is uint32_t")
    equal(t, typeinfo sizeof(type<wasi_filesize_t>), 8, "__wasi_filesize_t is uint64_t")
    equal(t, typeinfo sizeof(type<wasi_timestamp_t>), 8, "__wasi_timestamp_t is uint64_t")
    equal(t, typeinfo sizeof(type<wasi_clockid_t>), 4, "__wasi_clockid_t is uint32_t")
    equal(t, typeinfo sizeof(type<wasi_errno_t>), 2, "__wasi_errno_t is uint16_t")
    equal(t, typeinfo sizeof(type<wasi_rights_t>), 8, "__wasi_rights_t is uint64_t")
    equal(t, typeinfo sizeof(type<wasi_fd_t>), 4, "__wasi_fd_t is uint32_t")
    equal(t, typeinfo sizeof(type<wasi_filedelta_t>), 8, "__wasi_filedelta_t is int64_t")
    equal(t, typeinfo sizeof(type<wasi_whence_t>), 1, "__wasi_whence_t is uint8_t")
    equal(t, typeinfo sizeof(type<wasi_inode_t>), 8, "__wasi_inode_t is uint64_t")
    equal(t, typeinfo sizeof(type<wasi_filetype_t>), 1, "__wasi_filetype_t is uint8_t")
    equal(t, typeinfo sizeof(type<wasi_fdflags_t>), 2, "__wasi_fdflags_t is uint16_t")
    equal(t, typeinfo sizeof(type<wasi_device_t>), 8, "__wasi_device_t is uint64_t")
    equal(t, typeinfo sizeof(type<wasi_lookupflags_t>), 4, "__wasi_lookupflags_t is uint32_t")
    equal(t, typeinfo sizeof(type<wasi_oflags_t>), 2, "__wasi_oflags_t is uint16_t")
    equal(t, typeinfo sizeof(type<wasi_linkcount_t>), 8, "__wasi_linkcount_t is uint64_t")
    equal(t, typeinfo sizeof(type<wasi_preopentype_t>), 1, "__wasi_preopentype_t is uint8_t")
}


// ============================================================================
// Constant groups
// ============================================================================


def test_clockid_values(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_CLOCKID_REALTIME, 0u, "__WASI_CLOCKID_REALTIME")
    equal(t, WASI_CLOCKID_MONOTONIC, 1u, "__WASI_CLOCKID_MONOTONIC")
    equal(t, WASI_CLOCKID_PROCESS_CPUTIME_ID, 2u, "__WASI_CLOCKID_PROCESS_CPUTIME_ID")
    equal(t, WASI_CLOCKID_THREAD_CPUTIME_ID, 3u, "__WASI_CLOCKID_THREAD_CPUTIME_ID")
}


// The full errno list is 77 codes, 0..76, in alphabetical order after
// SUCCESS. The ends, the codes m3_api_wasi.c returns by name and the codes
// errno_to_wasi maps are checked here.
def test_errno_values(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_ERRNO_SUCCESS, uint16(0), "__WASI_ERRNO_SUCCESS")
    equal(t, WASI_ERRNO_2BIG, uint16(1), "__WASI_ERRNO_2BIG")
    equal(t, WASI_ERRNO_ACCES, uint16(2), "__WASI_ERRNO_ACCES")
    equal(t, WASI_ERRNO_AGAIN, uint16(6), "__WASI_ERRNO_AGAIN")
    equal(t, WASI_ERRNO_BADF, uint16(8), "__WASI_ERRNO_BADF")
    equal(t, WASI_ERRNO_BUSY, uint16(10), "__WASI_ERRNO_BUSY")
    equal(t, WASI_ERRNO_EXIST, uint16(20), "__WASI_ERRNO_EXIST")
    equal(t, WASI_ERRNO_INTR, uint16(27), "__WASI_ERRNO_INTR")
    equal(t, WASI_ERRNO_INVAL, uint16(28), "__WASI_ERRNO_INVAL")
    equal(t, WASI_ERRNO_IO, uint16(29), "__WASI_ERRNO_IO")
    equal(t, WASI_ERRNO_ISDIR, uint16(31), "__WASI_ERRNO_ISDIR")
    equal(t, WASI_ERRNO_MFILE, uint16(33), "__WASI_ERRNO_MFILE")
    equal(t, WASI_ERRNO_NOENT, uint16(44), "__WASI_ERRNO_NOENT")
    equal(t, WASI_ERRNO_NOMEM, uint16(48), "__WASI_ERRNO_NOMEM")
    equal(t, WASI_ERRNO_NOSPC, uint16(51), "__WASI_ERRNO_NOSPC")
    equal(t, WASI_ERRNO_NOSYS, uint16(52), "__WASI_ERRNO_NOSYS")
    equal(t, WASI_ERRNO_NOTDIR, uint16(54), "__WASI_ERRNO_NOTDIR")
    equal(t, WASI_ERRNO_NOTTY, uint16(59), "__WASI_ERRNO_NOTTY")
    equal(t, WASI_ERRNO_PERM, uint16(63), "__WASI_ERRNO_PERM")
    equal(t, WASI_ERRNO_PIPE, uint16(64), "__WASI_ERRNO_PIPE")
    equal(t, WASI_ERRNO_RANGE, uint16(68), "__WASI_ERRNO_RANGE")
    equal(t, WASI_ERRNO_ROFS, uint16(69), "__WASI_ERRNO_ROFS")
    equal(t, WASI_ERRNO_SPIPE, uint16(70), "__WASI_ERRNO_SPIPE")
    equal(t, WASI_ERRNO_SRCH, uint16(71), "__WASI_ERRNO_SRCH")
    equal(t, WASI_ERRNO_TXTBSY, uint16(74), "__WASI_ERRNO_TXTBSY")
    equal(t, WASI_ERRNO_XDEV, uint16(75), "__WASI_ERRNO_XDEV")
    equal(t, WASI_ERRNO_NOTCAPABLE, uint16(76), "__WASI_ERRNO_NOTCAPABLE is the last code")
}


def test_rights_values(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_RIGHTS_FD_DATASYNC, 1ul, "__WASI_RIGHTS_FD_DATASYNC")
    equal(t, WASI_RIGHTS_FD_READ, 2ul, "__WASI_RIGHTS_FD_READ")
    equal(t, WASI_RIGHTS_FD_SEEK, 4ul, "__WASI_RIGHTS_FD_SEEK")
    equal(t, WASI_RIGHTS_FD_FDSTAT_SET_FLAGS, 8ul, "__WASI_RIGHTS_FD_FDSTAT_SET_FLAGS")
    equal(t, WASI_RIGHTS_FD_TELL, 32ul, "__WASI_RIGHTS_FD_TELL")
    equal(t, WASI_RIGHTS_FD_WRITE, 64ul, "__WASI_RIGHTS_FD_WRITE")
    equal(t, WASI_RIGHTS_PATH_OPEN, 8192ul, "__WASI_RIGHTS_PATH_OPEN")
    equal(t, WASI_RIGHTS_SOCK_SHUTDOWN, 268435456ul, "__WASI_RIGHTS_SOCK_SHUTDOWN is the last right")

    // Every right is a distinct single bit, 1 << 0 .. 1 << 28.
    equal(t, WASI_RIGHTS_SOCK_SHUTDOWN, 1ul << 28u, "the rights are bit flags")

    // m3_wasi_generic_fd_fdstat_get clears exactly these two for fd 0,1,2.
    let tty_mask = WASI_RIGHTS_FD_SEEK | WASI_RIGHTS_FD_TELL
    equal(t, tty_mask, 36ul, "FD_SEEK | FD_TELL")
}


def test_whence_and_filetype_values(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_WHENCE_SET, 0u8, "__WASI_WHENCE_SET")
    equal(t, WASI_WHENCE_CUR, 1u8, "__WASI_WHENCE_CUR")
    equal(t, WASI_WHENCE_END, 2u8, "__WASI_WHENCE_END")

    equal(t, WASI_FILETYPE_UNKNOWN, 0u8, "__WASI_FILETYPE_UNKNOWN")
    equal(t, WASI_FILETYPE_BLOCK_DEVICE, 1u8, "__WASI_FILETYPE_BLOCK_DEVICE")
    equal(t, WASI_FILETYPE_CHARACTER_DEVICE, 2u8, "__WASI_FILETYPE_CHARACTER_DEVICE")
    equal(t, WASI_FILETYPE_DIRECTORY, 3u8, "__WASI_FILETYPE_DIRECTORY")
    equal(t, WASI_FILETYPE_REGULAR_FILE, 4u8, "__WASI_FILETYPE_REGULAR_FILE")
    equal(t, WASI_FILETYPE_SOCKET_DGRAM, 5u8, "__WASI_FILETYPE_SOCKET_DGRAM")
    equal(t, WASI_FILETYPE_SOCKET_STREAM, 6u8, "__WASI_FILETYPE_SOCKET_STREAM")
    equal(t, WASI_FILETYPE_SYMBOLIC_LINK, 7u8, "__WASI_FILETYPE_SYMBOLIC_LINK")
}


def test_fdflags_oflags_lookupflags_preopentype(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_FDFLAGS_APPEND, uint16(1), "__WASI_FDFLAGS_APPEND")
    equal(t, WASI_FDFLAGS_DSYNC, uint16(2), "__WASI_FDFLAGS_DSYNC")
    equal(t, WASI_FDFLAGS_NONBLOCK, uint16(4), "__WASI_FDFLAGS_NONBLOCK")
    equal(t, WASI_FDFLAGS_RSYNC, uint16(8), "__WASI_FDFLAGS_RSYNC")
    equal(t, WASI_FDFLAGS_SYNC, uint16(16), "__WASI_FDFLAGS_SYNC")

    equal(t, WASI_OFLAGS_CREAT, uint16(1), "__WASI_OFLAGS_CREAT")
    equal(t, WASI_OFLAGS_DIRECTORY, uint16(2), "__WASI_OFLAGS_DIRECTORY")
    equal(t, WASI_OFLAGS_EXCL, uint16(4), "__WASI_OFLAGS_EXCL")
    equal(t, WASI_OFLAGS_TRUNC, uint16(8), "__WASI_OFLAGS_TRUNC")

    equal(t, WASI_LOOKUPFLAGS_SYMLINK_FOLLOW, 1u, "__WASI_LOOKUPFLAGS_SYMLINK_FOLLOW")

    equal(t, WASI_PREOPENTYPE_DIR, 0u8, "__WASI_PREOPENTYPE_DIR")
}


// ============================================================================
// ABI layouts
// ============================================================================


// C: sizeof == 8, buf at 0, buf_len at 4 (the commented-out asserts of the
// header; m3_api_wasi.c relies on them for its own wasi_iovec_t).
def test_iovec_layout(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_IOVEC_SIZE, 8u, "sizeof(__wasi_iovec_t)")
    equal(t, WASI_IOVEC_OFF_BUF, 0u, "offsetof(__wasi_iovec_t, buf)")
    equal(t, WASI_IOVEC_OFF_BUF_LEN, 4u, "offsetof(__wasi_iovec_t, buf_len)")

    // `typeinfo offsetof` needs a value of the type; the underscore prefix
    // marks it as intentionally never read (LINT002).
    let _iov = wasi_iovec_t()   // Eden: initialized, DESIGN section 6
    equal(t, typeinfo sizeof(type<wasi_iovec_t>), 8, "wasi_iovec_t lays out to 8 bytes")
    equal(t, typeinfo offsetof < buf > (_iov), 0, "wasi_iovec_t.buf")
    equal(t, typeinfo offsetof < buf_len > (_iov), 4, "wasi_iovec_t.buf_len")

    let _ciov = wasi_ciovec_t()   // Eden: initialized, DESIGN section 6
    equal(t, typeinfo sizeof(type<wasi_ciovec_t>), 8, "wasi_ciovec_t lays out to 8 bytes")
    equal(t, typeinfo offsetof < buf > (_ciov), 0, "wasi_ciovec_t.buf")
    equal(t, typeinfo offsetof < buf_len > (_ciov), 4, "wasi_ciovec_t.buf_len")
}


// C: _Static_assert(sizeof(__wasi_fdstat_t) == 24), offsets 0, 2, 8, 16.
def test_fdstat_layout(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_FDSTAT_SIZE, 24u, "sizeof(__wasi_fdstat_t)")
    equal(t, WASI_FDSTAT_OFF_FS_FILETYPE, 0u, "offsetof fs_filetype")
    equal(t, WASI_FDSTAT_OFF_FS_FLAGS, 2u, "offsetof fs_flags")
    equal(t, WASI_FDSTAT_OFF_FS_RIGHTS_BASE, 8u, "offsetof fs_rights_base")
    equal(t, WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING, 16u, "offsetof fs_rights_inheriting")

    let _fdstat = wasi_fdstat_t()   // Eden: initialized, DESIGN section 6
    equal(t, typeinfo sizeof(type<wasi_fdstat_t>), int(WASI_FDSTAT_SIZE), "wasi_fdstat_t size")
    equal(t, typeinfo offsetof < fs_filetype > (_fdstat), int(WASI_FDSTAT_OFF_FS_FILETYPE), "wasi_fdstat_t.fs_filetype")
    equal(t, typeinfo offsetof < fs_flags > (_fdstat), int(WASI_FDSTAT_OFF_FS_FLAGS), "wasi_fdstat_t.fs_flags")
    equal(t, typeinfo offsetof < fs_rights_base > (_fdstat), int(WASI_FDSTAT_OFF_FS_RIGHTS_BASE), "wasi_fdstat_t.fs_rights_base")
    equal(t, typeinfo offsetof < fs_rights_inheriting > (_fdstat), int(WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING), "wasi_fdstat_t.fs_rights_inheriting")
}


// C: _Static_assert(sizeof(__wasi_filestat_t) == 64), offsets 0, 8, 16, 24,
// 32, 40, 48, 56.
def test_filestat_layout(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_FILESTAT_SIZE, 64u, "sizeof(__wasi_filestat_t)")
    equal(t, WASI_FILESTAT_OFF_DEV, 0u, "offsetof dev")
    equal(t, WASI_FILESTAT_OFF_INO, 8u, "offsetof ino")
    equal(t, WASI_FILESTAT_OFF_FILETYPE, 16u, "offsetof filetype")
    equal(t, WASI_FILESTAT_OFF_NLINK, 24u, "offsetof nlink")
    equal(t, WASI_FILESTAT_OFF_SIZE, 32u, "offsetof size")
    equal(t, WASI_FILESTAT_OFF_ATIM, 40u, "offsetof atim")
    equal(t, WASI_FILESTAT_OFF_MTIM, 48u, "offsetof mtim")
    equal(t, WASI_FILESTAT_OFF_CTIM, 56u, "offsetof ctim")

    let _fs = wasi_filestat_t()   // Eden: initialized, DESIGN section 6
    equal(t, typeinfo sizeof(type<wasi_filestat_t>), int(WASI_FILESTAT_SIZE), "wasi_filestat_t size")
    equal(t, typeinfo offsetof < dev > (_fs), int(WASI_FILESTAT_OFF_DEV), "wasi_filestat_t.dev")
    equal(t, typeinfo offsetof < ino > (_fs), int(WASI_FILESTAT_OFF_INO), "wasi_filestat_t.ino")
    equal(t, typeinfo offsetof < filetype > (_fs), int(WASI_FILESTAT_OFF_FILETYPE), "wasi_filestat_t.filetype")
    equal(t, typeinfo offsetof < nlink > (_fs), int(WASI_FILESTAT_OFF_NLINK), "wasi_filestat_t.nlink")
    equal(t, typeinfo offsetof < size > (_fs), int(WASI_FILESTAT_OFF_SIZE), "wasi_filestat_t.size")
    equal(t, typeinfo offsetof < atim > (_fs), int(WASI_FILESTAT_OFF_ATIM), "wasi_filestat_t.atim")
    equal(t, typeinfo offsetof < mtim > (_fs), int(WASI_FILESTAT_OFF_MTIM), "wasi_filestat_t.mtim")
    equal(t, typeinfo offsetof < ctim > (_fs), int(WASI_FILESTAT_OFF_CTIM), "wasi_filestat_t.ctim")
}


// C: _Static_assert(sizeof(__wasi_prestat_t) == 8), pr_type at 0, u at 4;
// sizeof(__wasi_prestat_dir_t) == 4 with pr_name_len at 0. This is the layout
// m3_wasi_generic_fd_prestat_get writes as two raw 32-bit words.
def test_prestat_layout(var t : TestRun; fx : FixtureSource) {
    equal(t, WASI_PRESTAT_SIZE, 8u, "sizeof(__wasi_prestat_t)")
    equal(t, WASI_PRESTAT_OFF_PR_TYPE, 0u, "offsetof pr_type")
    equal(t, WASI_PRESTAT_OFF_U, 4u, "offsetof u")
    equal(t, WASI_PRESTAT_DIR_OFF_PR_NAME_LEN, 0u, "offsetof pr_name_len")

    let _pre = wasi_prestat_t()   // Eden: initialized, DESIGN section 6
    equal(t, typeinfo sizeof(type<wasi_prestat_t>), int(WASI_PRESTAT_SIZE), "wasi_prestat_t size")
    equal(t, typeinfo offsetof < pr_type > (_pre), int(WASI_PRESTAT_OFF_PR_TYPE), "wasi_prestat_t.pr_type")
    equal(t, typeinfo offsetof < u > (_pre), int(WASI_PRESTAT_OFF_U), "wasi_prestat_t.u")

    let _dir = wasi_prestat_dir_t()   // Eden: initialized, DESIGN section 6
    equal(t, typeinfo sizeof(type<wasi_prestat_dir_t>), 4, "wasi_prestat_dir_t size")
    equal(t, typeinfo offsetof < pr_name_len > (_dir), 0, "wasi_prestat_dir_t.pr_name_len")
}


def public run_tests_wasi_core(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_typedef_widths")
    test_typedef_widths(t, fx)
    begin_test(t, "test_clockid_values")
    test_clockid_values(t, fx)
    begin_test(t, "test_errno_values")
    test_errno_values(t, fx)
    begin_test(t, "test_rights_values")
    test_rights_values(t, fx)
    begin_test(t, "test_whence_and_filetype_values")
    test_whence_and_filetype_values(t, fx)
    begin_test(t, "test_fdflags_oflags_lookupflags_preopentype")
    test_fdflags_oflags_lookupflags_preopentype(t, fx)
    begin_test(t, "test_iovec_layout")
    test_iovec_layout(t, fx)
    begin_test(t, "test_fdstat_layout")
    test_fdstat_layout(t, fx)
    begin_test(t, "test_filestat_layout")
    test_filestat_layout(t, fx)
    begin_test(t, "test_prestat_layout")
    test_prestat_layout(t, fx)
}
