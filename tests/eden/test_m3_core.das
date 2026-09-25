options gen2
options indenting = 4

module test_m3_core shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_core
require modules/wasm3das/source/m3_config   // d_m3LogNativeStack for the stack-diagnostics check
require daslib/math_bits

/*
    test_m3_core.das: Eden counterpart of
    .upstream/tests/integration/test_m3_core.das.

    Every upstream [test] has a counterpart below with the same checks in the
    same order; the fail-fast check / check_result helpers of the upstream
    file become the recording checks of eden_test (check / equal / equal_str),
    so one failing value never hides the others.

    Eden: the upstream cursors are pointers built with addr(buf[0]) and
    advanced by the readers; here a cursor is the byte array plus an index
    (source/m3_core.das, DESIGN.md section 4.4), so init_cursor yields the
    start index 0 and the end index length(buf), a cursor offset is the
    index itself, and the two "cursor beyond the declared end" cases set the
    index past the end directly (end = 0, cursor = 1). The bit views of the
    float results come from daslib/math_bits (float_bits_to_uint /
    double_bits_to_uint64) instead of a reinterpret. One test is added for
    the Eden shape of the allocation helpers and the stack diagnostics
    (test_array_allocation_helpers); it has no upstream counterpart.
*/


def private check_result(var t : TestRun; actual : M3Result; expected : M3Result; message : string) {
    equal_str(t, actual, expected, message)
}


def private init_cursor(
                        var t : TestRun;
                        buf : array<u8>;
                        var cursor : int&;
                        var end : int&
                        ) {
    check(t, !empty(buf), "test buffer must not be empty")

    // Eden: start is index 0 (the upstream `start = addr(buf[0])`)
    cursor = 0
    end = length(buf)
}


def private f32_bits(value : f32) : u32 {
    return float_bits_to_uint(value)
}


def private f64_bits(value : f64) : u64 {
    return double_bits_to_uint64(value)
}


def private check_uleb(
                       var t : TestRun;
                       buf : array<u8>;
                       max_bits : u32;
                       expected_value : u64;
                       expected_result : M3Result;
                       expected_pos : int;
                       case_name : string
                       ) {
    var cursor = 0
    var end = 0
    init_cursor(t, buf, cursor, end)

    var value : u64 = 0ul
    let result = ReadLebUnsigned(buf, value, max_bits, cursor, end)

    check_result(t, result, expected_result, "{case_name} result")
    equal(t, value, expected_value, "{case_name} value")
    equal(t, cursor, expected_pos, "{case_name} position")
}


def private check_sleb(
                       var t : TestRun;
                       buf : array<u8>;
                       max_bits : u32;
                       expected_value : i64;
                       expected_result : M3Result;
                       expected_pos : int;
                       case_name : string
                       ) {
    var cursor = 0
    var end = 0
    init_cursor(t, buf, cursor, end)

    var value : i64 = 0l
    let result = ReadLebSigned(buf, value, max_bits, cursor, end)

    check_result(t, result, expected_result, "{case_name} result")
    equal(t, value, expected_value, "{case_name} value")
    equal(t, cursor, expected_pos, "{case_name} position")
}


def private check_normalize(
                            var t : TestRun;
                            input : i8;
                            expected_type : u8;
                            expected_result : M3Result;
                            case_name : string
                            ) {
    var output : u8 = 0u8
    let result = NormalizeType(output, input)

    check_result(t, result, expected_result, "NormalizeType {case_name} result")
    equal(t, u32(output), u32(expected_type), "NormalizeType {case_name} output")
}


// ============================================================================
// Fixed-width reads
// ============================================================================


def test_fixed_width_little_endian_reads(var t : TestRun; fx : FixtureSource) {
    {
        var buf <- [0xabu8]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : u8 = 0u8
        let result = Read_u8(buf, value, cursor, end)
        check_result(t, result, m3Err_none, "Read_u8")
        equal(t, u32(value), 0xabu, "Read_u8 value")
        equal(t, cursor, 1, "Read_u8 position")
    }

    {
        var buf <- [u8(0x78), u8(0x56), u8(0x34), u8(0x12)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : u32 = 0u
        let result = Read_u32(buf, value, cursor, end)
        check_result(t, result, m3Err_none, "Read_u32")
        equal(t, value, 0x12345678u, "Read_u32 little-endian value")
        equal(t, cursor, 4, "Read_u32 position")
    }

    {
        var buf <- [
            u8(0xef), u8(0xcd), u8(0xab), u8(0x89),
            u8(0x67), u8(0x45), u8(0x23), u8(0x01)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : u64 = 0ul
        let result = Read_u64(buf, value, cursor, end)
        check_result(t, result, m3Err_none, "Read_u64")
        equal(t, value, 0x0123456789abcdeful, "Read_u64 little-endian value")
        equal(t, cursor, 8, "Read_u64 position")
    }
}


// ============================================================================
// Float reads
// ============================================================================


def private check_f32_special_reads(var t : TestRun) {
    {
        var buf <- [u8(0x00), u8(0x00), u8(0x00), u8(0x80)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f32 = 0.0
        check_result(t, Read_f32(buf, value, cursor, end), m3Err_none, "Read_f32 -0")
        equal(t, f32_bits(value), 0x80000000u, "Read_f32 must preserve -0 bits")
        equal(t, cursor, 4, "Read_f32 -0 position")
    }

    {
        var buf <- [u8(0x00), u8(0x00), u8(0x80), u8(0x7f)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f32 = 0.0
        check_result(t, Read_f32(buf, value, cursor, end), m3Err_none, "Read_f32 +inf")
        equal(t, f32_bits(value), 0x7f800000u, "Read_f32 must preserve +inf bits")
    }

    {
        var buf <- [u8(0x00), u8(0x00), u8(0x80), u8(0xff)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f32 = 0.0
        check_result(t, Read_f32(buf, value, cursor, end), m3Err_none, "Read_f32 -inf")
        equal(t, f32_bits(value), 0xff800000u, "Read_f32 must preserve -inf bits")
    }

    {
        var buf <- [u8(0x45), u8(0x23), u8(0xc1), u8(0x7f)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f32 = 0.0
        check_result(t, Read_f32(buf, value, cursor, end), m3Err_none, "Read_f32 NaN")
        equal(t, f32_bits(value), 0x7fc12345u, "Read_f32 must preserve NaN payload bits")
    }
}


def private check_f64_special_reads(var t : TestRun) {
    {
        var buf <- [
            u8(0x00), u8(0x00), u8(0x00), u8(0x00),
            u8(0x00), u8(0x00), u8(0x00), u8(0x80)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f64 = 0.0lf
        check_result(t, Read_f64(buf, value, cursor, end), m3Err_none, "Read_f64 -0")
        equal(t, f64_bits(value), 0x8000000000000000ul, "Read_f64 must preserve -0 bits")
        equal(t, cursor, 8, "Read_f64 -0 position")
    }

    {
        var buf <- [
            u8(0x00), u8(0x00), u8(0x00), u8(0x00),
            u8(0x00), u8(0x00), u8(0xf0), u8(0x7f)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f64 = 0.0lf
        check_result(t, Read_f64(buf, value, cursor, end), m3Err_none, "Read_f64 +inf")
        equal(t, f64_bits(value), 0x7ff0000000000000ul, "Read_f64 must preserve +inf bits")
    }

    {
        var buf <- [
            u8(0x00), u8(0x00), u8(0x00), u8(0x00),
            u8(0x00), u8(0x00), u8(0xf0), u8(0xff)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f64 = 0.0lf
        check_result(t, Read_f64(buf, value, cursor, end), m3Err_none, "Read_f64 -inf")
        equal(t, f64_bits(value), 0xfff0000000000000ul, "Read_f64 must preserve -inf bits")
    }

    {
        var buf <- [
            u8(0xbc), u8(0x9a), u8(0x78), u8(0x56),
            u8(0x34), u8(0x12), u8(0xf8), u8(0x7f)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : f64 = 0.0lf
        check_result(t, Read_f64(buf, value, cursor, end), m3Err_none, "Read_f64 NaN")
        equal(t, f64_bits(value), 0x7ff8123456789abcul, "Read_f64 must preserve NaN payload bits")
    }
}


def test_float_reads_preserve_ieee_bits(var t : TestRun; fx : FixtureSource) {
    check_f32_special_reads(t)
    check_f64_special_reads(t)
}


// ============================================================================
// LEB128
// ============================================================================


def test_unsigned_leb_values(var t : TestRun; fx : FixtureSource) {
    {
        var buf <- [u8(0x00)]
        check_uleb(t, buf, 64u, 0ul, m3Err_none, 1, "uleb 0")
    }
    {
        var buf <- [u8(0x01)]
        check_uleb(t, buf, 64u, 1ul, m3Err_none, 1, "uleb 1")
    }
    {
        var buf <- [u8(0x7f)]
        check_uleb(t, buf, 64u, 127ul, m3Err_none, 1, "uleb 127")
    }
    {
        var buf <- [u8(0x80), u8(0x01)]
        check_uleb(t, buf, 64u, 128ul, m3Err_none, 2, "uleb 128")
    }
    {
        var buf <- [u8(0xe5), u8(0x8e), u8(0x26)]
        check_uleb(t, buf, 64u, 624485ul, m3Err_none, 3, "uleb 624485")
    }
    {
        var buf <- [u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x0f)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : u32 = 0u
        check_result(t, ReadLEB_u32(buf, value, cursor, end), m3Err_none, "uleb max u32")
        equal(t, value, 0xffffffffu, "uleb max u32 value")
        equal(t, cursor, 5, "uleb max u32 position")
    }
    {
        var buf <- [
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0xff),
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x01)
        ]
        check_uleb(t, buf, 64u, 0xfffffffffffffffful, m3Err_none, 10, "uleb max u64")
    }
}


def private check_signed_leb_scalar_values(var t : TestRun) {
    {
        var buf <- [u8(0x00)]
        check_sleb(t, buf, 64u, 0l, m3Err_none, 1, "sleb 0")
    }
    {
        var buf <- [u8(0x01)]
        check_sleb(t, buf, 64u, 1l, m3Err_none, 1, "sleb 1")
    }
    {
        var buf <- [u8(0x7f)]
        check_sleb(t, buf, 64u, -1l, m3Err_none, 1, "sleb -1")
    }
    {
        var buf <- [u8(0x3f)]
        check_sleb(t, buf, 64u, 63l, m3Err_none, 1, "sleb 63")
    }
    {
        var buf <- [u8(0xc0), u8(0x00)]
        check_sleb(t, buf, 64u, 64l, m3Err_none, 2, "sleb 64")
    }
    {
        var buf <- [u8(0x40)]
        check_sleb(t, buf, 64u, -64l, m3Err_none, 1, "sleb -64")
    }
    {
        var buf <- [u8(0xbf), u8(0x7f)]
        check_sleb(t, buf, 64u, -65l, m3Err_none, 2, "sleb -65")
    }
    {
        var buf <- [u8(0x9b), u8(0xf1), u8(0x59)]
        check_sleb(t, buf, 64u, -624485l, m3Err_none, 3, "sleb -624485")
    }
}


def private check_signed_leb_boundaries(var t : TestRun) {
    {
        var buf <- [u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x78)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : i32 = 0
        check_result(t, ReadLEB_i32(buf, value, cursor, end), m3Err_none, "sleb min i32")
        equal(t, value, (-2147483647 - 1), "sleb min i32 value")
        equal(t, cursor, 5, "sleb min i32 position")
    }
    {
        var buf <- [u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x07)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : i32 = 0
        check_result(t, ReadLEB_i32(buf, value, cursor, end), m3Err_none, "sleb max i32")
        equal(t, value, 2147483647, "sleb max i32 value")
        equal(t, cursor, 5, "sleb max i32 position")
    }
    {
        var buf <- [
            u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x80),
            u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x7f)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : i64 = 0l
        check_result(t, ReadLEB_i64(buf, value, cursor, end), m3Err_none, "sleb min i64")
        equal(t, value, (-9223372036854775807l - 1l), "sleb min i64 value")
        equal(t, cursor, 10, "sleb min i64 position")
    }
    {
        var buf <- [
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0xff),
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x00)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : i64 = 0l
        check_result(t, ReadLEB_i64(buf, value, cursor, end), m3Err_none, "sleb max i64")
        equal(t, value, 9223372036854775807l, "sleb max i64 value")
        equal(t, cursor, 10, "sleb max i64 position")
    }
}


def test_signed_leb_values(var t : TestRun; fx : FixtureSource) {
    check_signed_leb_scalar_values(t)
    check_signed_leb_boundaries(t)
}


// ============================================================================
// Errors and positions
// ============================================================================


def test_read_errors_and_positions(var t : TestRun; fx : FixtureSource) {
    // Fixed-width underrun must not consume any bytes.
    {
        var buf <- [u8(0x11), u8(0x22), u8(0x33)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var value : u32 = 0xfeedbeefu
        check_result(t, Read_u32(buf, value, cursor, end), m3Err_wasmUnderrun, "Read_u32 truncated")
        equal(t, value, 0xfeedbeefu, "Read_u32 truncated must leave output unchanged")
        equal(t, cursor, 0, "Read_u32 truncated must not advance")
    }

    // Cursor beyond the declared end is the explicit overrun path in the port.
    {
        var buf <- [u8(0x11), u8(0x22)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        // Eden: the upstream `end = start; cursor = start + 1` as indices
        end = 0
        cursor = 1

        var value : u8 = 0x5au8
        check_result(t, Read_u8(buf, value, cursor, end), m3Err_wasmOverrun, "Read_u8 overrun")
        equal(t, u32(value), 0x5au, "Read_u8 overrun must leave output unchanged")
        equal(t, cursor, 1, "Read_u8 overrun must not change cursor")
    }

    // Truncated LEB consumes the bytes it inspected, exactly like the C loop.
    {
        var buf <- [u8(0x80)]
        check_uleb(t, buf, 32u, 0ul, m3Err_wasmUnderrun, 1, "uleb truncated")
    }

    // A LEB longer than the allowed seven-bit width stops as soon as max bits are reached.
    {
        var buf <- [u8(0x80), u8(0x00)]
        check_uleb(t, buf, 7u, 0ul, m3Err_lebOverflow, 1, "uleb too long for u7")
    }

    // 32-bit overflow path: five continuation bytes consume five bytes and return lebOverflow.
    {
        var buf <- [u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x00)]
        check_uleb(t, buf, 32u, 0ul, m3Err_lebOverflow, 5, "uleb32 overflow")
    }

    // Signed overflow uses the same cursor rule.
    {
        var buf <- [u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x00)]
        check_sleb(t, buf, 32u, 0l, m3Err_lebOverflow, 5, "sleb32 overflow")
    }

    // LEB cursor already beyond end reports overrun without consuming further bytes.
    {
        var buf <- [u8(0x00), u8(0x00)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        // Eden: the upstream `end = start; cursor = start + 1` as indices
        end = 0
        cursor = 1

        var value : u64 = 123ul
        check_result(t, ReadLebUnsigned(buf, value, 32u, cursor, end), m3Err_wasmOverrun, "uleb overrun")
        equal(t, value, 0ul, "uleb overrun output follows parser zero initialization")
        equal(t, cursor, 1, "uleb overrun must not change cursor")
    }
}


// ============================================================================
// UTF-8
// ============================================================================


def test_utf8_reads_and_positions(var t : TestRun; fx : FixtureSource) {
    // Empty string.
    {
        var buf <- [u8(0x00)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var text = "sentinel"
        check_result(t, Read_utf8(buf, text, cursor, end), m3Err_none, "utf8 empty")
        equal_str(t, text, "", "utf8 empty value")
        equal(t, cursor, 1, "utf8 empty position")
    }

    // ASCII.
    {
        var buf <- [u8(0x05), u8('h'), u8('e'), u8('l'), u8('l'), u8('o')]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var text : string
        check_result(t, Read_utf8(buf, text, cursor, end), m3Err_none, "utf8 ascii")
        equal_str(t, text, "hello", "utf8 ascii value")
        equal(t, cursor, 6, "utf8 ascii position")
    }

    // UTF-8 bytes for "Привет".
    {
        var buf <- [
            u8(0x0c),
            u8(0xd0), u8(0x9f), u8(0xd1), u8(0x80),
            u8(0xd0), u8(0xb8), u8(0xd0), u8(0xb2),
            u8(0xd0), u8(0xb5), u8(0xd1), u8(0x82)
        ]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var text : string
        check_result(t, Read_utf8(buf, text, cursor, end), m3Err_none, "utf8 multibyte")
        equal_str(t, text, "Привет", "utf8 multibyte value")
        equal(t, cursor, 13, "utf8 multibyte position")
    }

    // Declared 3 bytes, only 2 available. Length byte is consumed; payload is not.
    {
        var buf <- [u8(0x03), u8(0xe2), u8(0x82)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var text = "sentinel"
        check_result(t, Read_utf8(buf, text, cursor, end), m3Err_wasmUnderrun, "utf8 truncated")
        equal_str(t, text, "", "utf8 truncated clears output")
        equal(t, cursor, 1, "utf8 truncated position after length")
    }

    // d_m3MaxSaneUtf8Length + 1 == 10001, ULEB = 0x91 0x4e.
    {
        var buf <- [u8(0x91), u8(0x4e)]
        var cursor = 0
        var end = 0
        init_cursor(t, buf, cursor, end)

        var text = "sentinel"
        check_result(t, Read_utf8(buf, text, cursor, end), m3Err_missingUTF8, "utf8 excessive length")
        equal_str(t, text, "", "utf8 excessive length clears output")
        equal(t, cursor, 2, "utf8 excessive length consumes only length LEB")
    }
}


// ============================================================================
// NormalizeType
// ============================================================================


def test_normalize_type(var t : TestRun; fx : FixtureSource) {
    check_normalize(t, i8(-1), u8(M3ValueType.c_m3Type_i32), m3Err_none, "i32")
    check_normalize(t, i8(-2), u8(M3ValueType.c_m3Type_i64), m3Err_none, "i64")
    check_normalize(t, i8(-3), u8(M3ValueType.c_m3Type_f32), m3Err_none, "f32")
    check_normalize(t, i8(-4), u8(M3ValueType.c_m3Type_f64), m3Err_none, "f64")
    check_normalize(t, i8(-5), u8(M3ValueType.c_m3Type_v128), m3Err_none, "v128")
    check_normalize(t, i8(-64), u8(M3ValueType.c_m3Type_none), m3Err_none, "none")

    check_normalize(t, i8(0), u8(0), m3Err_invalidTypeId, "invalid zero")
    check_normalize(t, i8(-6), u8(6), m3Err_invalidTypeId, "invalid -6")
    check_normalize(t, i8(1), u8(0xff), m3Err_invalidTypeId, "invalid +1")
}


// ============================================================================
// Eden: the array allocation helpers and the stack diagnostics
// ============================================================================


// a struct with a handle field, to show that the "zero fill" of an
// allocation is the element default (a null handle is -1, DESIGN.md 4.1)
struct private HandleSlot {
    handle : int = -1
    count : u32 = 0u
}


def test_array_allocation_helpers(var t : TestRun; fx : FixtureSource) {
    // m3_Malloc_Impl: a fresh block of i_size default elements
    var slots : array<HandleSlot>
    m3_Malloc_Impl(slots, 3)
    equal(t, length(slots), 3, "m3_Malloc_Impl length")
    equal(t, slots[2].handle, -1, "m3_Malloc_Impl element default is a null handle")
    equal(t, slots[2].count, 0u, "m3_Malloc_Impl element default is zero")

    // a second allocation into the same array replaces the block
    slots[0].handle = 7
    m3_Malloc_Impl(slots, 2)
    equal(t, length(slots), 2, "m3_Malloc_Impl replaces the block")
    equal(t, slots[0].handle, -1, "m3_Malloc_Impl does not keep old elements")

    // m3_Realloc_Impl: same size is a no-op, growth keeps the head and
    // zero-fills the tail, shrinking keeps the head
    slots[1].handle = 5
    m3_Realloc_Impl(slots, 2, 2)
    equal(t, length(slots), 2, "m3_Realloc_Impl same size keeps the length")
    equal(t, slots[1].handle, 5, "m3_Realloc_Impl same size keeps the elements")
    m3_Realloc_Impl(slots, 5, 2)
    equal(t, length(slots), 5, "m3_Realloc_Impl grows")
    equal(t, slots[1].handle, 5, "m3_Realloc_Impl growth keeps the head")
    equal(t, slots[4].handle, -1, "m3_Realloc_Impl growth zero-fills the tail")
    m3_Realloc_Impl(slots, 1, 5)
    equal(t, length(slots), 1, "m3_Realloc_Impl shrinks")
    equal(t, slots[0].handle, -1, "m3_Realloc_Impl shrinking keeps the head")

    // m3_Free_Impl: the empty array is the null pointer
    m3_Free_Impl(slots)
    equal(t, length(slots), 0, "m3_Free_Impl empties the block")

    // scalar element types, as m3_env uses for the linear memory
    var mem : array<u8>
    m3_Malloc_Impl(mem, 4)
    equal(t, length(mem), 4, "m3_Malloc_Impl u8 length")
    equal(t, u32(mem[3]), 0u, "m3_Malloc_Impl u8 zero fill")
    mem[3] = u8(0x2a)
    m3_Realloc_Impl(mem, 8, 4)
    equal(t, length(mem), 8, "m3_Realloc_Impl u8 grows")
    equal(t, u32(mem[3]), 0x2au, "m3_Realloc_Impl u8 keeps the head")
    equal(t, u32(mem[7]), 0u, "m3_Realloc_Impl u8 zero-fills the tail")

    // m3_CopyMem: a new block holding the first i_size elements
    var words <- [u64(1), u64(2), u64(3)]
    var copied <- m3_CopyMem(words, 2)
    equal(t, length(copied), 2, "m3_CopyMem length")
    equal(t, copied[1], 2ul, "m3_CopyMem copies the elements")
    copied[0] = 9ul
    equal(t, words[0], 1ul, "m3_CopyMem is a separate block")
    var none <- m3_CopyMem(words, 0)
    equal(t, length(none), 0, "m3_CopyMem of zero elements is empty")

    // the stack diagnostics are the C `#else` branch (d_m3LogNativeStack off)
    check(t, !d_m3LogNativeStack, "d_m3LogNativeStack is off")
    m3StackCheckInit()
    m3StackCheck()
    equal(t, m3StackGetMax(), 0, "m3StackGetMax is 0 when d_m3LogNativeStack is off")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_core(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_fixed_width_little_endian_reads")
    test_fixed_width_little_endian_reads(t, fx)
    begin_test(t, "test_float_reads_preserve_ieee_bits")
    test_float_reads_preserve_ieee_bits(t, fx)
    begin_test(t, "test_unsigned_leb_values")
    test_unsigned_leb_values(t, fx)
    begin_test(t, "test_signed_leb_values")
    test_signed_leb_values(t, fx)
    begin_test(t, "test_read_errors_and_positions")
    test_read_errors_and_positions(t, fx)
    begin_test(t, "test_utf8_reads_and_positions")
    test_utf8_reads_and_positions(t, fx)
    begin_test(t, "test_normalize_type")
    test_normalize_type(t, fx)
    begin_test(t, "test_array_allocation_helpers")
    test_array_allocation_helpers(t, fx)
}
