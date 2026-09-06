options gen2
options indenting = 4

module wasi_core shared public

require ./m3_core.das public


/*
    Conservative Gen2 port of the subset of wasm3c/source/extra/wasi_core.h
    that m3_api_wasi.c uses.

    wasi_core.h is the auto-generated WASI `snapshot_preview1` ABI header
    (from typenames.witx / wasi_snapshot_preview1.witx). It declares far more
    than wasm3 touches: subscriptions, events, signals, socket flags, dirents
    and the function prototypes of the whole API. Only the typedefs, the
    constant groups and the structures that m3_api_wasi.c actually reads or
    writes are ported here, in the order of the C header. The rest is
    deliberately absent; adding a group later means copying its C block, not
    inventing names.

    Deviations from the C header, all forced and all local to this file:

    1. NAMES: C `__WASI_X` is spelled `WASI_X` and C `__wasi_x_t` is spelled
       `wasi_x_t`. The Daslang compiler rejects identifiers starting with a
       double underscore (error 20116, "names starting with __ are reserved"),
       so the leading `__` is dropped and the rest of every C name is kept
       exactly. This is the only renaming in the file.

    2. CONSTANTS: C `#define __WASI_X (UINTn_C(v))` becomes
       `let public WASI_X : uN`. Daslang has no preprocessor; an immutable
       module `let` is the closest equivalent and keeps the C width visible in
       the declaration. The widths are the ones the C header asserts: errno is
       uint16_t, rights is uint64_t, clockid and lookupflags are uint32_t,
       fdflags and oflags are uint16_t, filetype, whence and preopentype are
       uint8_t. Daslang has literal suffixes for u32 (`0u`), u8 (`0u8`) and
       u64 (`0ul`) but none for u16, so the 16-bit groups are written
       `uint16(v)`; the value and the declared type are unchanged.

    3. LAYOUTS: the structures below are ABI layouts inside *wasm linear
       memory*, not host objects. Host functions never dereference a Daslang
       value of these types: they compute a byte offset into `_mem` and use
       m3ApiReadMem* / m3ApiWriteMem*, exactly as the C macros do. The Daslang
       structs are therefore accompanied by explicit `_SIZE` and `_OFF_*`
       constants, taken from the `_Static_assert(sizeof/offsetof ...)` lines of
       the C header, and those constants - not the Daslang struct layout - are
       what the port computes with. The structs are kept so the C field names
       stay in the tree and so tests can compare the Daslang layout with the
       ABI one.

    The scalar aliases u8/u16/u32/u64/i64 come from m3_core.das, which is the
    port's spelling of the stdint types wasi_core.h includes.

    errno_to_wasi() is NOT here. It lives in m3_api_wasi.c (not in the header)
    and maps host `errno` values, so in the port it belongs to the module that
    owns the host descriptor layer, m3_api_wasi_fd.das.
*/


// ============================================================================
// Scalar typedefs (wasi_core.h)
// ============================================================================


// C: typedef uint32_t __wasi_size_t; // fixme for wasm64
typedef public wasi_size_t = u32

// C: typedef uint64_t __wasi_filesize_t;
typedef public wasi_filesize_t = u64

// C: typedef uint64_t __wasi_timestamp_t;
typedef public wasi_timestamp_t = u64

// C: typedef uint32_t __wasi_clockid_t;
typedef public wasi_clockid_t = u32

// C: typedef uint16_t __wasi_errno_t;
typedef public wasi_errno_t = u16

// C: typedef uint64_t __wasi_rights_t;
typedef public wasi_rights_t = u64

// C: typedef uint32_t __wasi_fd_t;
typedef public wasi_fd_t = u32

// C: typedef int64_t __wasi_filedelta_t;
typedef public wasi_filedelta_t = i64

// C: typedef uint8_t __wasi_whence_t;
typedef public wasi_whence_t = u8

// C: typedef uint64_t __wasi_inode_t;
typedef public wasi_inode_t = u64

// C: typedef uint8_t __wasi_filetype_t;
typedef public wasi_filetype_t = u8

// C: typedef uint16_t __wasi_fdflags_t;
typedef public wasi_fdflags_t = u16

// C: typedef uint64_t __wasi_device_t;
typedef public wasi_device_t = u64

// C: typedef uint32_t __wasi_lookupflags_t;
typedef public wasi_lookupflags_t = u32

// C: typedef uint16_t __wasi_oflags_t;
typedef public wasi_oflags_t = u16

// C: typedef uint64_t __wasi_linkcount_t;
typedef public wasi_linkcount_t = u64

// C: typedef uint8_t __wasi_preopentype_t;
typedef public wasi_preopentype_t = u8


// ============================================================================
// wasi_clockid_t values (C __WASI_CLOCKID_*)
// ============================================================================


let public WASI_CLOCKID_REALTIME : wasi_clockid_t = 0u
let public WASI_CLOCKID_MONOTONIC : wasi_clockid_t = 1u
let public WASI_CLOCKID_PROCESS_CPUTIME_ID : wasi_clockid_t = 2u
let public WASI_CLOCKID_THREAD_CPUTIME_ID : wasi_clockid_t = 3u


// ============================================================================
// wasi_errno_t values (C __WASI_ERRNO_*)
//
// All 77 codes of the C header, in its order. Only a handful appear in
// m3_api_wasi.c, but errno_to_wasi() in the descriptor module needs most of
// the POSIX ones and the set is the ABI, so it is ported whole.
// ============================================================================


let public WASI_ERRNO_SUCCESS : wasi_errno_t = uint16(0)
let public WASI_ERRNO_2BIG : wasi_errno_t = uint16(1)
let public WASI_ERRNO_ACCES : wasi_errno_t = uint16(2)
let public WASI_ERRNO_ADDRINUSE : wasi_errno_t = uint16(3)
let public WASI_ERRNO_ADDRNOTAVAIL : wasi_errno_t = uint16(4)
let public WASI_ERRNO_AFNOSUPPORT : wasi_errno_t = uint16(5)
let public WASI_ERRNO_AGAIN : wasi_errno_t = uint16(6)
let public WASI_ERRNO_ALREADY : wasi_errno_t = uint16(7)
let public WASI_ERRNO_BADF : wasi_errno_t = uint16(8)
let public WASI_ERRNO_BADMSG : wasi_errno_t = uint16(9)
let public WASI_ERRNO_BUSY : wasi_errno_t = uint16(10)
let public WASI_ERRNO_CANCELED : wasi_errno_t = uint16(11)
let public WASI_ERRNO_CHILD : wasi_errno_t = uint16(12)
let public WASI_ERRNO_CONNABORTED : wasi_errno_t = uint16(13)
let public WASI_ERRNO_CONNREFUSED : wasi_errno_t = uint16(14)
let public WASI_ERRNO_CONNRESET : wasi_errno_t = uint16(15)
let public WASI_ERRNO_DEADLK : wasi_errno_t = uint16(16)
let public WASI_ERRNO_DESTADDRREQ : wasi_errno_t = uint16(17)
let public WASI_ERRNO_DOM : wasi_errno_t = uint16(18)
let public WASI_ERRNO_DQUOT : wasi_errno_t = uint16(19)
let public WASI_ERRNO_EXIST : wasi_errno_t = uint16(20)
let public WASI_ERRNO_FAULT : wasi_errno_t = uint16(21)
let public WASI_ERRNO_FBIG : wasi_errno_t = uint16(22)
let public WASI_ERRNO_HOSTUNREACH : wasi_errno_t = uint16(23)
let public WASI_ERRNO_IDRM : wasi_errno_t = uint16(24)
let public WASI_ERRNO_ILSEQ : wasi_errno_t = uint16(25)
let public WASI_ERRNO_INPROGRESS : wasi_errno_t = uint16(26)
let public WASI_ERRNO_INTR : wasi_errno_t = uint16(27)
let public WASI_ERRNO_INVAL : wasi_errno_t = uint16(28)
let public WASI_ERRNO_IO : wasi_errno_t = uint16(29)
let public WASI_ERRNO_ISCONN : wasi_errno_t = uint16(30)
let public WASI_ERRNO_ISDIR : wasi_errno_t = uint16(31)
let public WASI_ERRNO_LOOP : wasi_errno_t = uint16(32)
let public WASI_ERRNO_MFILE : wasi_errno_t = uint16(33)
let public WASI_ERRNO_MLINK : wasi_errno_t = uint16(34)
let public WASI_ERRNO_MSGSIZE : wasi_errno_t = uint16(35)
let public WASI_ERRNO_MULTIHOP : wasi_errno_t = uint16(36)
let public WASI_ERRNO_NAMETOOLONG : wasi_errno_t = uint16(37)
let public WASI_ERRNO_NETDOWN : wasi_errno_t = uint16(38)
let public WASI_ERRNO_NETRESET : wasi_errno_t = uint16(39)
let public WASI_ERRNO_NETUNREACH : wasi_errno_t = uint16(40)
let public WASI_ERRNO_NFILE : wasi_errno_t = uint16(41)
let public WASI_ERRNO_NOBUFS : wasi_errno_t = uint16(42)
let public WASI_ERRNO_NODEV : wasi_errno_t = uint16(43)
let public WASI_ERRNO_NOENT : wasi_errno_t = uint16(44)
let public WASI_ERRNO_NOEXEC : wasi_errno_t = uint16(45)
let public WASI_ERRNO_NOLCK : wasi_errno_t = uint16(46)
let public WASI_ERRNO_NOLINK : wasi_errno_t = uint16(47)
let public WASI_ERRNO_NOMEM : wasi_errno_t = uint16(48)
let public WASI_ERRNO_NOMSG : wasi_errno_t = uint16(49)
let public WASI_ERRNO_NOPROTOOPT : wasi_errno_t = uint16(50)
let public WASI_ERRNO_NOSPC : wasi_errno_t = uint16(51)
let public WASI_ERRNO_NOSYS : wasi_errno_t = uint16(52)
let public WASI_ERRNO_NOTCONN : wasi_errno_t = uint16(53)
let public WASI_ERRNO_NOTDIR : wasi_errno_t = uint16(54)
let public WASI_ERRNO_NOTEMPTY : wasi_errno_t = uint16(55)
let public WASI_ERRNO_NOTRECOVERABLE : wasi_errno_t = uint16(56)
let public WASI_ERRNO_NOTSOCK : wasi_errno_t = uint16(57)
let public WASI_ERRNO_NOTSUP : wasi_errno_t = uint16(58)
let public WASI_ERRNO_NOTTY : wasi_errno_t = uint16(59)
let public WASI_ERRNO_NXIO : wasi_errno_t = uint16(60)
let public WASI_ERRNO_OVERFLOW : wasi_errno_t = uint16(61)
let public WASI_ERRNO_OWNERDEAD : wasi_errno_t = uint16(62)
let public WASI_ERRNO_PERM : wasi_errno_t = uint16(63)
let public WASI_ERRNO_PIPE : wasi_errno_t = uint16(64)
let public WASI_ERRNO_PROTO : wasi_errno_t = uint16(65)
let public WASI_ERRNO_PROTONOSUPPORT : wasi_errno_t = uint16(66)
let public WASI_ERRNO_PROTOTYPE : wasi_errno_t = uint16(67)
let public WASI_ERRNO_RANGE : wasi_errno_t = uint16(68)
let public WASI_ERRNO_ROFS : wasi_errno_t = uint16(69)
let public WASI_ERRNO_SPIPE : wasi_errno_t = uint16(70)
let public WASI_ERRNO_SRCH : wasi_errno_t = uint16(71)
let public WASI_ERRNO_STALE : wasi_errno_t = uint16(72)
let public WASI_ERRNO_TIMEDOUT : wasi_errno_t = uint16(73)
let public WASI_ERRNO_TXTBSY : wasi_errno_t = uint16(74)
let public WASI_ERRNO_XDEV : wasi_errno_t = uint16(75)
let public WASI_ERRNO_NOTCAPABLE : wasi_errno_t = uint16(76)


// ============================================================================
// wasi_rights_t values (C __WASI_RIGHTS_*, 64-bit bit flags)
// ============================================================================


let public WASI_RIGHTS_FD_DATASYNC : wasi_rights_t = 1ul
let public WASI_RIGHTS_FD_READ : wasi_rights_t = 2ul
let public WASI_RIGHTS_FD_SEEK : wasi_rights_t = 4ul
let public WASI_RIGHTS_FD_FDSTAT_SET_FLAGS : wasi_rights_t = 8ul
let public WASI_RIGHTS_FD_SYNC : wasi_rights_t = 16ul
let public WASI_RIGHTS_FD_TELL : wasi_rights_t = 32ul
let public WASI_RIGHTS_FD_WRITE : wasi_rights_t = 64ul
let public WASI_RIGHTS_FD_ADVISE : wasi_rights_t = 128ul
let public WASI_RIGHTS_FD_ALLOCATE : wasi_rights_t = 256ul
let public WASI_RIGHTS_PATH_CREATE_DIRECTORY : wasi_rights_t = 512ul
let public WASI_RIGHTS_PATH_CREATE_FILE : wasi_rights_t = 1024ul
let public WASI_RIGHTS_PATH_LINK_SOURCE : wasi_rights_t = 2048ul
let public WASI_RIGHTS_PATH_LINK_TARGET : wasi_rights_t = 4096ul
let public WASI_RIGHTS_PATH_OPEN : wasi_rights_t = 8192ul
let public WASI_RIGHTS_FD_READDIR : wasi_rights_t = 16384ul
let public WASI_RIGHTS_PATH_READLINK : wasi_rights_t = 32768ul
let public WASI_RIGHTS_PATH_RENAME_SOURCE : wasi_rights_t = 65536ul
let public WASI_RIGHTS_PATH_RENAME_TARGET : wasi_rights_t = 131072ul
let public WASI_RIGHTS_PATH_FILESTAT_GET : wasi_rights_t = 262144ul
let public WASI_RIGHTS_PATH_FILESTAT_SET_SIZE : wasi_rights_t = 524288ul
let public WASI_RIGHTS_PATH_FILESTAT_SET_TIMES : wasi_rights_t = 1048576ul
let public WASI_RIGHTS_FD_FILESTAT_GET : wasi_rights_t = 2097152ul
let public WASI_RIGHTS_FD_FILESTAT_SET_SIZE : wasi_rights_t = 4194304ul
let public WASI_RIGHTS_FD_FILESTAT_SET_TIMES : wasi_rights_t = 8388608ul
let public WASI_RIGHTS_PATH_SYMLINK : wasi_rights_t = 16777216ul
let public WASI_RIGHTS_PATH_REMOVE_DIRECTORY : wasi_rights_t = 33554432ul
let public WASI_RIGHTS_PATH_UNLINK_FILE : wasi_rights_t = 67108864ul
let public WASI_RIGHTS_POLL_FD_READWRITE : wasi_rights_t = 134217728ul
let public WASI_RIGHTS_SOCK_SHUTDOWN : wasi_rights_t = 268435456ul


// ============================================================================
// wasi_iovec_t / wasi_ciovec_t
//
// In the C header `buf` is a host `uint8_t*`; inside wasm linear memory the
// same field is a 32-bit wasm offset, which is why m3_api_wasi.c declares its
// own guest-side alias
//
//     typedef struct wasi_iovec_t { __wasi_size_t buf; __wasi_size_t buf_len; }
//
// Dropping the leading `__` makes the header's `__wasi_iovec_t` and that
// alias the same Daslang name. That is correct rather than lossy: the port
// only ever needs the guest view, which is what both of them describe here,
// and the C file's own struct is byte-identical to the header one under the
// 32-bit wasm ABI. The host-pointer spelling of the C header field is
// recorded in the comment.
// ============================================================================


let public WASI_IOVEC_SIZE : u32 = 8u
let public WASI_IOVEC_OFF_BUF : u32 = 0u
let public WASI_IOVEC_OFF_BUF_LEN : u32 = 4u


struct public wasi_iovec_t {
    buf : wasi_size_t           // C header: uint8_t * buf, offset 0
    buf_len : wasi_size_t       // C header: __wasi_size_t buf_len, offset 4
}


struct public wasi_ciovec_t {
    buf : wasi_size_t           // C header: const uint8_t * buf, offset 0
    buf_len : wasi_size_t       // C header: __wasi_size_t buf_len, offset 4
}


// ============================================================================
// wasi_whence_t values (C __WASI_WHENCE_*)
// ============================================================================


let public WASI_WHENCE_SET : wasi_whence_t = 0u8
let public WASI_WHENCE_CUR : wasi_whence_t = 1u8
let public WASI_WHENCE_END : wasi_whence_t = 2u8


// ============================================================================
// wasi_filetype_t values (C __WASI_FILETYPE_*)
// ============================================================================


let public WASI_FILETYPE_UNKNOWN : wasi_filetype_t = 0u8
let public WASI_FILETYPE_BLOCK_DEVICE : wasi_filetype_t = 1u8
let public WASI_FILETYPE_CHARACTER_DEVICE : wasi_filetype_t = 2u8
let public WASI_FILETYPE_DIRECTORY : wasi_filetype_t = 3u8
let public WASI_FILETYPE_REGULAR_FILE : wasi_filetype_t = 4u8
let public WASI_FILETYPE_SOCKET_DGRAM : wasi_filetype_t = 5u8
let public WASI_FILETYPE_SOCKET_STREAM : wasi_filetype_t = 6u8
let public WASI_FILETYPE_SYMBOLIC_LINK : wasi_filetype_t = 7u8


// ============================================================================
// wasi_fdflags_t values (C __WASI_FDFLAGS_*)
// ============================================================================


let public WASI_FDFLAGS_APPEND : wasi_fdflags_t = uint16(1)
let public WASI_FDFLAGS_DSYNC : wasi_fdflags_t = uint16(2)
let public WASI_FDFLAGS_NONBLOCK : wasi_fdflags_t = uint16(4)
let public WASI_FDFLAGS_RSYNC : wasi_fdflags_t = uint16(8)
let public WASI_FDFLAGS_SYNC : wasi_fdflags_t = uint16(16)


// ============================================================================
// wasi_fdstat_t
//
// C asserts: sizeof == 24, alignof == 8, offsetof fs_filetype == 0,
// fs_flags == 2, fs_rights_base == 8, fs_rights_inheriting == 16.
// The two holes (byte 1, bytes 4..7) are part of the ABI and are written by
// nobody; a guest that zeroes the buffer sees zeroes there.
// ============================================================================


let public WASI_FDSTAT_SIZE : u32 = 24u
let public WASI_FDSTAT_OFF_FS_FILETYPE : u32 = 0u
let public WASI_FDSTAT_OFF_FS_FLAGS : u32 = 2u
let public WASI_FDSTAT_OFF_FS_RIGHTS_BASE : u32 = 8u
let public WASI_FDSTAT_OFF_FS_RIGHTS_INHERITING : u32 = 16u


struct public wasi_fdstat_t {
    fs_filetype : wasi_filetype_t          // offset 0
    pad0 : u8                              // ABI hole at offset 1
    fs_flags : wasi_fdflags_t              // offset 2
    pad1 : u32                             // ABI hole at offsets 4..7
    fs_rights_base : wasi_rights_t         // offset 8
    fs_rights_inheriting : wasi_rights_t   // offset 16
}


// ============================================================================
// wasi_lookupflags_t values (C __WASI_LOOKUPFLAGS_*)
// ============================================================================


let public WASI_LOOKUPFLAGS_SYMLINK_FOLLOW : wasi_lookupflags_t = 1u


// ============================================================================
// wasi_oflags_t values (C __WASI_OFLAGS_*)
// ============================================================================


let public WASI_OFLAGS_CREAT : wasi_oflags_t = uint16(1)
let public WASI_OFLAGS_DIRECTORY : wasi_oflags_t = uint16(2)
let public WASI_OFLAGS_EXCL : wasi_oflags_t = uint16(4)
let public WASI_OFLAGS_TRUNC : wasi_oflags_t = uint16(8)


// ============================================================================
// wasi_filestat_t
//
// C asserts: sizeof == 64, alignof == 8, offsets dev 0, ino 8, filetype 16,
// nlink 24, size 32, atim 40, mtim 48, ctim 56.
// ============================================================================


let public WASI_FILESTAT_SIZE : u32 = 64u
let public WASI_FILESTAT_OFF_DEV : u32 = 0u
let public WASI_FILESTAT_OFF_INO : u32 = 8u
let public WASI_FILESTAT_OFF_FILETYPE : u32 = 16u
let public WASI_FILESTAT_OFF_NLINK : u32 = 24u
let public WASI_FILESTAT_OFF_SIZE : u32 = 32u
let public WASI_FILESTAT_OFF_ATIM : u32 = 40u
let public WASI_FILESTAT_OFF_MTIM : u32 = 48u
let public WASI_FILESTAT_OFF_CTIM : u32 = 56u


struct public wasi_filestat_t {
    dev : wasi_device_t                    // offset 0
    ino : wasi_inode_t                     // offset 8
    filetype : wasi_filetype_t             // offset 16
    pad0 : u8                              // ABI hole at offset 17
    pad1 : u16                             // ABI hole at offsets 18..19
    pad2 : u32                             // ABI hole at offsets 20..23
    nlink : wasi_linkcount_t               // offset 24
    size : wasi_filesize_t                 // offset 32
    atim : wasi_timestamp_t                // offset 40
    mtim : wasi_timestamp_t                // offset 48
    ctim : wasi_timestamp_t                // offset 56
}


// ============================================================================
// wasi_preopentype_t values and wasi_prestat_t
//
// C asserts: sizeof(__wasi_prestat_t) == 8, alignof == 4, pr_type at 0,
// u at 4; sizeof(__wasi_prestat_dir_t) == 4 with pr_name_len at 0.
//
// m3_wasi_generic_fd_prestat_get does not use these names: it writes two
// raw 32-bit words, `buf+0 = __WASI_PREOPENTYPE_DIR` and
// `buf+4 = strlen(path)+1`, which is the same layout with pr_type widened to
// its 4-byte slot. The port keeps the C code's spelling and the ABI names
// side by side.
// ============================================================================


let public WASI_PREOPENTYPE_DIR : wasi_preopentype_t = 0u8

let public WASI_PRESTAT_SIZE : u32 = 8u
let public WASI_PRESTAT_OFF_PR_TYPE : u32 = 0u
let public WASI_PRESTAT_OFF_U : u32 = 4u
let public WASI_PRESTAT_DIR_OFF_PR_NAME_LEN : u32 = 0u


struct public wasi_prestat_dir_t {
    pr_name_len : wasi_size_t              // offset 0
}


/*
    C: typedef union __wasi_prestat_u_t { __wasi_prestat_dir_t dir; }

    Daslang has no C union type. The union has exactly one member in this
    revision of the ABI, so the port spells it as a struct with that member;
    the size (4) and alignment (4) are identical.
*/
struct public wasi_prestat_u_t {
    dir : wasi_prestat_dir_t
}


struct public wasi_prestat_t {
    pr_type : wasi_preopentype_t           // offset 0
    pad0 : u8                              // ABI hole at offset 1
    pad1 : u16                             // ABI hole at offsets 2..3
    u : wasi_prestat_u_t                   // offset 4
}
