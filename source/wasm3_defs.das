options gen2
options indenting = 4

module wasm3_defs shared public


/*
    wasm3_defs.h -> wasm3_defs.das

    Pure gen2 Daslang port.

    This module owns all platform/compiler/endianness decisions used by the
    wasm3 port. It does not depend on C interop, WASI, m3_core.das, or a
    parallel type/error system.
*/


// ============================================================================
// Stringification / token concatenation
// ============================================================================


/*
    C preprocessor block omitted:

        M3_STR__
        M3_STR
        M3_CONCAT__
        M3_CONCAT

    These macros operate on C preprocessing tokens, not runtime values.
    Daslang has no textual C preprocessor stage, and reproducing token
    stringification/concatenation as runtime functions would have different
    semantics and no independent use in this module.
*/


// ============================================================================
// Compiler information
// ============================================================================


/*
    C compiler-detection block omitted:

        M3_COMPILER_CLANG
        M3_COMPILER_GCC
        M3_COMPILER_ICC
        M3_COMPILER_MSVC

    In the C source those flags describe the C/C++ compiler processing the
    header. This file is pure Daslang, so exposing a set of runtime booleans
    pretending to be C preprocessor symbols would be misleading.

    M3_COMPILER_VER is retained as the public informational value. It reports
    the Daslang compiler version rather than an implementation detail of an
    optional native backend used later for AOT/JIT.
*/

let public M3_COMPILER_VER = "Daslang {get_das_version()}"


/*
    C feature-query macro block omitted:

        M3_COMPILER_HAS_FEATURE(x)
        M3_COMPILER_HAS_BUILTIN(x)
        M3_COMPILER_HAS_ATTRIBUTE(x)

    __has_feature / __has_builtin / __has_attribute query a C-family frontend
    during preprocessing. They have no standalone runtime meaning in Daslang.
    Daslang language features and builtins are resolved directly by the
    Daslang compiler.
*/


// ============================================================================
// Endianness
// ============================================================================


/*
    The C preprocessor endianness-detection branches are replaced by one
    representation probe.

    This avoids hard-coding architecture tables and detects the byte order of
    the actual Daslang target representation.

    Only this implementation-level probe is unsafe. No C interop is involved.
*/

def private m3_detect_little_endian() : bool {
    var probe : uint16 = uint16(0x0102)

    unsafe {
        let first_byte = *addr<uint8?>(probe)
        return first_byte == uint8(0x02)
    }
}


let public M3_LITTLE_ENDIAN = m3_detect_little_endian()
let public M3_BIG_ENDIAN = !M3_LITTLE_ENDIAN


// ============================================================================
// Architecture
// ============================================================================


/*
    C architecture-preprocessor block omitted.

    The original header maps compiler-specific predefined macros such as
    __x86_64__, __aarch64__, __riscv, _M_X64, etc. to M3_ARCH.

    gen2 Daslang provides get_architecture_name(), so the platform decision is
    centralized here without reproducing the host C preprocessor.

    Typical values include:
        "x86_64"
        "x86"
        "arm64"
        "arm"
        "wasm32"
        "unknown"
*/

let public M3_ARCH = get_architecture_name()


// ============================================================================
// Byte swapping
// ============================================================================


/*
    C compiler-specific byte-swap selection omitted:

        _byteswap_*
        __builtin_bswap*
        __bswap_*

    Selecting a native C intrinsic is a backend optimization decision and has
    no independent semantic equivalent in pure Daslang.

    The three public functions below intentionally remain separate, matching
    wasm3_defs.h. Their results reproduce the fallback Wasm3 bit formulas.
*/


def public m3_bswap16(x : uint16) : uint16 {
    let v = uint(x)

    return uint16(
          ((v >> 8u) & 0x00ffu)
        | ((v & 0x00ffu) << 8u)
    )
}


def public m3_bswap32(x : uint) : uint {
    return (
          ((x & 0xff000000u) >> 24u)
        | ((x & 0x00ff0000u) >> 8u)
        | ((x & 0x0000ff00u) << 8u)
        | ((x & 0x000000ffu) << 24u)
    )
}


def public m3_bswap64(x : uint64) : uint64 {
    return (
          ((x & 0xff00000000000000ul) >> 56ul)
        | ((x & 0x00ff000000000000ul) >> 40ul)
        | ((x & 0x0000ff0000000000ul) >> 24ul)
        | ((x & 0x000000ff00000000ul) >> 8ul)
        | ((x & 0x00000000ff000000ul) << 8ul)
        | ((x & 0x0000000000ff0000ul) << 24ul)
        | ((x & 0x000000000000ff00ul) << 40ul)
        | ((x & 0x00000000000000fful) << 56ul)
    )
}


// ============================================================================
// Bit operations
// ============================================================================


/*
    C:

        #define m3_isBitSet(val, pos) ((val & (1 << pos)) != 0)

    A function is preferable in Daslang:
      - each argument is evaluated exactly once;
      - there is no textual macro expansion;
      - the value type is preserved through the named generic T.
*/

def public m3_isBitSet(val : auto(T); pos : auto(P)) : bool {
    return (val & (T(1) << T(pos))) != T(0)
}


// ============================================================================
// Branch prediction hints
// ============================================================================


/*
    C compiler-selection block omitted:

        __builtin_expect(!!(x), 0)
        __builtin_expect(!!(x), 1)

    There is no portable gen2 expression-level branch prediction intrinsic
    equivalent to this C macro contract.

    The semantic requirement is therefore preserved exactly:
      - x is evaluated once;
      - its bool value is returned unchanged;
      - LIKELY/UNLIKELY introduce no observable behavior.
*/

def public M3_UNLIKELY(x : bool) : bool {
    return x
}


def public M3_LIKELY(x : bool) : bool {
    return x
}
