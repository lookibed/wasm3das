options gen2
options indenting = 4

require dastest/testing_boost
require ../../source/m3_core.das


def private fail(message : string) {
    panic("test_m3_core: {message}")
}


def private check(condition : bool; message : string) {
    if (!condition) {
        fail(message)
    }
}


def private check_result(actual : M3Result; expected : M3Result; message : string) {
    if (actual != expected) {
        fail("{message}: expected result '{expected}', got '{actual}'")
    }
}


def private cursor_offset(start : bytes_t; cursor : bytes_t) : int {
    unsafe {
        return int(intptr(cursor) - intptr(start))
    }
}


def private init_cursor(
                        var buf : array<u8>;
                        var start : bytes_t&;
                        var cursor : bytes_t&;
                        var end : cbytes_t&
                        ) {
    check(!empty(buf), "test buffer must not be empty")

    unsafe {
        start = addr(buf[0])
        cursor = start
        end = start
        end += length(buf)
    }
}


def private f32_bits(value : f32) : u32 {
    unsafe {
        return reinterpret<u32>(value)
    }
}


def private f64_bits(value : f64) : u64 {
    unsafe {
        return reinterpret<u64>(value)
    }
}


def private check_uleb(
                       var buf : array<u8>;
                       max_bits : u32;
                       expected_value : u64;
                       expected_result : M3Result;
                       expected_pos : int;
                       case_name : string
                       ) {
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_cursor(buf, start, cursor, end)

    var value : u64 = 0ul
    let result = ReadLebUnsigned(value, max_bits, cursor, end)

    check_result(result, expected_result, "{case_name} result")
    check(value == expected_value, "{case_name} value: expected {expected_value}, got {value}")
    check(cursor_offset(start, cursor) == expected_pos,
        "{case_name} position: expected {expected_pos}, got {cursor_offset(start, cursor)}")
}


def private check_sleb(
                       var buf : array<u8>;
                       max_bits : u32;
                       expected_value : i64;
                       expected_result : M3Result;
                       expected_pos : int;
                       case_name : string
                       ) {
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_cursor(buf, start, cursor, end)

    var value : i64 = 0l
    let result = ReadLebSigned(value, max_bits, cursor, end)

    check_result(result, expected_result, "{case_name} result")
    check(value == expected_value, "{case_name} value: expected {expected_value}, got {value}")
    check(cursor_offset(start, cursor) == expected_pos,
        "{case_name} position: expected {expected_pos}, got {cursor_offset(start, cursor)}")
}


def private check_normalize(
                            input : i8;
                            expected_type : u8;
                            expected_result : M3Result;
                            case_name : string
                            ) {
    var output : u8 = 0u8
    let result = NormalizeType(output, input)

    check_result(result, expected_result, "NormalizeType {case_name} result")
    check(u32(output) == u32(expected_type),
        "NormalizeType {case_name} output: expected {u32(expected_type)}, got {u32(output)}")
}


[test]
def test_fixed_width_little_endian_reads() {
    {
        var buf <- [0xabu8]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : u8 = 0u8
        let result = Read_u8(value, cursor, end)
        check_result(result, m3Err_none, "Read_u8")
        check(u32(value) == 0xabu, "Read_u8 value")
        check(cursor_offset(start, cursor) == 1, "Read_u8 position")
    }

    {
        var buf <- [u8(0x78), u8(0x56), u8(0x34), u8(0x12)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : u32 = 0u
        let result = Read_u32(value, cursor, end)
        check_result(result, m3Err_none, "Read_u32")
        check(value == 0x12345678u, "Read_u32 little-endian value")
        check(cursor_offset(start, cursor) == 4, "Read_u32 position")
    }

    {
        var buf <- [
            u8(0xef), u8(0xcd), u8(0xab), u8(0x89),
            u8(0x67), u8(0x45), u8(0x23), u8(0x01)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : u64 = 0ul
        let result = Read_u64(value, cursor, end)
        check_result(result, m3Err_none, "Read_u64")
        check(value == 0x0123456789abcdeful, "Read_u64 little-endian value")
        check(cursor_offset(start, cursor) == 8, "Read_u64 position")
    }
}


def private check_f32_special_reads() {
    {
        var buf <- [u8(0x00), u8(0x00), u8(0x00), u8(0x80)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f32 = 0.0
        check_result(Read_f32(value, cursor, end), m3Err_none, "Read_f32 -0")
        check(f32_bits(value) == 0x80000000u, "Read_f32 must preserve -0 bits")
        check(cursor_offset(start, cursor) == 4, "Read_f32 -0 position")
    }

    {
        var buf <- [u8(0x00), u8(0x00), u8(0x80), u8(0x7f)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f32 = 0.0
        check_result(Read_f32(value, cursor, end), m3Err_none, "Read_f32 +inf")
        check(f32_bits(value) == 0x7f800000u, "Read_f32 must preserve +inf bits")
    }

    {
        var buf <- [u8(0x00), u8(0x00), u8(0x80), u8(0xff)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f32 = 0.0
        check_result(Read_f32(value, cursor, end), m3Err_none, "Read_f32 -inf")
        check(f32_bits(value) == 0xff800000u, "Read_f32 must preserve -inf bits")
    }

    {
        var buf <- [u8(0x45), u8(0x23), u8(0xc1), u8(0x7f)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f32 = 0.0
        check_result(Read_f32(value, cursor, end), m3Err_none, "Read_f32 NaN")
        check(f32_bits(value) == 0x7fc12345u, "Read_f32 must preserve NaN payload bits")
    }
}


def private check_f64_special_reads() {
    {
        var buf <- [
            u8(0x00), u8(0x00), u8(0x00), u8(0x00),
            u8(0x00), u8(0x00), u8(0x00), u8(0x80)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f64 = 0.0lf
        check_result(Read_f64(value, cursor, end), m3Err_none, "Read_f64 -0")
        check(f64_bits(value) == 0x8000000000000000ul, "Read_f64 must preserve -0 bits")
        check(cursor_offset(start, cursor) == 8, "Read_f64 -0 position")
    }

    {
        var buf <- [
            u8(0x00), u8(0x00), u8(0x00), u8(0x00),
            u8(0x00), u8(0x00), u8(0xf0), u8(0x7f)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f64 = 0.0lf
        check_result(Read_f64(value, cursor, end), m3Err_none, "Read_f64 +inf")
        check(f64_bits(value) == 0x7ff0000000000000ul, "Read_f64 must preserve +inf bits")
    }

    {
        var buf <- [
            u8(0x00), u8(0x00), u8(0x00), u8(0x00),
            u8(0x00), u8(0x00), u8(0xf0), u8(0xff)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f64 = 0.0lf
        check_result(Read_f64(value, cursor, end), m3Err_none, "Read_f64 -inf")
        check(f64_bits(value) == 0xfff0000000000000ul, "Read_f64 must preserve -inf bits")
    }

    {
        var buf <- [
            u8(0xbc), u8(0x9a), u8(0x78), u8(0x56),
            u8(0x34), u8(0x12), u8(0xf8), u8(0x7f)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : f64 = 0.0lf
        check_result(Read_f64(value, cursor, end), m3Err_none, "Read_f64 NaN")
        check(f64_bits(value) == 0x7ff8123456789abcul, "Read_f64 must preserve NaN payload bits")
    }
}


[test]
def test_float_reads_preserve_ieee_bits() {
    check_f32_special_reads()
    check_f64_special_reads()
}

[test]
def test_unsigned_leb_values() {
    {
        var buf <- [u8(0x00)]
        check_uleb(buf, 64u, 0ul, m3Err_none, 1, "uleb 0")
    }
    {
        var buf <- [u8(0x01)]
        check_uleb(buf, 64u, 1ul, m3Err_none, 1, "uleb 1")
    }
    {
        var buf <- [u8(0x7f)]
        check_uleb(buf, 64u, 127ul, m3Err_none, 1, "uleb 127")
    }
    {
        var buf <- [u8(0x80), u8(0x01)]
        check_uleb(buf, 64u, 128ul, m3Err_none, 2, "uleb 128")
    }
    {
        var buf <- [u8(0xe5), u8(0x8e), u8(0x26)]
        check_uleb(buf, 64u, 624485ul, m3Err_none, 3, "uleb 624485")
    }
    {
        var buf <- [u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x0f)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : u32 = 0u
        check_result(ReadLEB_u32(value, cursor, end), m3Err_none, "uleb max u32")
        check(value == 0xffffffffu, "uleb max u32 value")
        check(cursor_offset(start, cursor) == 5, "uleb max u32 position")
    }
    {
        var buf <- [
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0xff),
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x01)
        ]
        check_uleb(buf, 64u, 0xfffffffffffffffful, m3Err_none, 10, "uleb max u64")
    }
}


def private check_signed_leb_scalar_values() {
    {
        var buf <- [u8(0x00)]
        check_sleb(buf, 64u, 0l, m3Err_none, 1, "sleb 0")
    }
    {
        var buf <- [u8(0x01)]
        check_sleb(buf, 64u, 1l, m3Err_none, 1, "sleb 1")
    }
    {
        var buf <- [u8(0x7f)]
        check_sleb(buf, 64u, -1l, m3Err_none, 1, "sleb -1")
    }
    {
        var buf <- [u8(0x3f)]
        check_sleb(buf, 64u, 63l, m3Err_none, 1, "sleb 63")
    }
    {
        var buf <- [u8(0xc0), u8(0x00)]
        check_sleb(buf, 64u, 64l, m3Err_none, 2, "sleb 64")
    }
    {
        var buf <- [u8(0x40)]
        check_sleb(buf, 64u, -64l, m3Err_none, 1, "sleb -64")
    }
    {
        var buf <- [u8(0xbf), u8(0x7f)]
        check_sleb(buf, 64u, -65l, m3Err_none, 2, "sleb -65")
    }
    {
        var buf <- [u8(0x9b), u8(0xf1), u8(0x59)]
        check_sleb(buf, 64u, -624485l, m3Err_none, 3, "sleb -624485")
    }
}


def private check_signed_leb_boundaries() {
    {
        var buf <- [u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x78)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : i32 = 0
        check_result(ReadLEB_i32(value, cursor, end), m3Err_none, "sleb min i32")
        check(value == (-2147483647 - 1), "sleb min i32 value")
        check(cursor_offset(start, cursor) == 5, "sleb min i32 position")
    }
    {
        var buf <- [u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x07)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : i32 = 0
        check_result(ReadLEB_i32(value, cursor, end), m3Err_none, "sleb max i32")
        check(value == 2147483647, "sleb max i32 value")
        check(cursor_offset(start, cursor) == 5, "sleb max i32 position")
    }
    {
        var buf <- [
            u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x80),
            u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x7f)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : i64 = 0l
        check_result(ReadLEB_i64(value, cursor, end), m3Err_none, "sleb min i64")
        check(value == (-9223372036854775807l - 1l), "sleb min i64 value")
        check(cursor_offset(start, cursor) == 10, "sleb min i64 position")
    }
    {
        var buf <- [
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0xff),
            u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x00)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : i64 = 0l
        check_result(ReadLEB_i64(value, cursor, end), m3Err_none, "sleb max i64")
        check(value == 9223372036854775807l, "sleb max i64 value")
        check(cursor_offset(start, cursor) == 10, "sleb max i64 position")
    }
}


[test]
def test_signed_leb_values() {
    check_signed_leb_scalar_values()
    check_signed_leb_boundaries()
}

[test]
def test_read_errors_and_positions() {
    // Fixed-width underrun must not consume any bytes.
    {
        var buf <- [u8(0x11), u8(0x22), u8(0x33)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var value : u32 = 0xfeedbeefu
        check_result(Read_u32(value, cursor, end), m3Err_wasmUnderrun, "Read_u32 truncated")
        check(value == 0xfeedbeefu, "Read_u32 truncated must leave output unchanged")
        check(cursor_offset(start, cursor) == 0, "Read_u32 truncated must not advance")
    }

    // Cursor beyond the declared end is the explicit overrun path in the port.
    {
        var buf <- [u8(0x11), u8(0x22)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        unsafe {
            end = start
            cursor = start
            cursor += 1
        }

        var value : u8 = 0x5au8
        check_result(Read_u8(value, cursor, end), m3Err_wasmOverrun, "Read_u8 overrun")
        check(u32(value) == 0x5au, "Read_u8 overrun must leave output unchanged")
        check(cursor_offset(start, cursor) == 1, "Read_u8 overrun must not change cursor")
    }

    // Truncated LEB consumes the bytes it inspected, exactly like the C loop.
    {
        var buf <- [u8(0x80)]
        check_uleb(buf, 32u, 0ul, m3Err_wasmUnderrun, 1, "uleb truncated")
    }

    // A LEB longer than the allowed seven-bit width stops as soon as max bits are reached.
    {
        var buf <- [u8(0x80), u8(0x00)]
        check_uleb(buf, 7u, 0ul, m3Err_lebOverflow, 1, "uleb too long for u7")
    }

    // 32-bit overflow path: five continuation bytes consume five bytes and return lebOverflow.
    {
        var buf <- [u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x00)]
        check_uleb(buf, 32u, 0ul, m3Err_lebOverflow, 5, "uleb32 overflow")
    }

    // Signed overflow uses the same cursor rule.
    {
        var buf <- [u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x00)]
        check_sleb(buf, 32u, 0l, m3Err_lebOverflow, 5, "sleb32 overflow")
    }

    // LEB cursor already beyond end reports overrun without consuming further bytes.
    {
        var buf <- [u8(0x00), u8(0x00)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        unsafe {
            end = start
            cursor = start
            cursor += 1
        }

        var value : u64 = 123ul
        check_result(ReadLebUnsigned(value, 32u, cursor, end), m3Err_wasmOverrun, "uleb overrun")
        check(value == 0ul, "uleb overrun output follows parser zero initialization")
        check(cursor_offset(start, cursor) == 1, "uleb overrun must not change cursor")
    }
}


[test]
def test_utf8_reads_and_positions() {
    // Empty string.
    {
        var buf <- [u8(0x00)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var text = "sentinel"
        check_result(Read_utf8(text, cursor, end), m3Err_none, "utf8 empty")
        check(text == "", "utf8 empty value")
        check(cursor_offset(start, cursor) == 1, "utf8 empty position")
    }

    // ASCII.
    {
        var buf <- [u8(0x05), u8('h'), u8('e'), u8('l'), u8('l'), u8('o')]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var text : string
        check_result(Read_utf8(text, cursor, end), m3Err_none, "utf8 ascii")
        check(text == "hello", "utf8 ascii value")
        check(cursor_offset(start, cursor) == 6, "utf8 ascii position")
    }

    // UTF-8 bytes for "Привет".
    {
        var buf <- [
            u8(0x0c),
            u8(0xd0), u8(0x9f), u8(0xd1), u8(0x80),
            u8(0xd0), u8(0xb8), u8(0xd0), u8(0xb2),
            u8(0xd0), u8(0xb5), u8(0xd1), u8(0x82)
        ]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var text : string
        check_result(Read_utf8(text, cursor, end), m3Err_none, "utf8 multibyte")
        check(text == "Привет", "utf8 multibyte value")
        check(cursor_offset(start, cursor) == 13, "utf8 multibyte position")
    }

    // Declared 3 bytes, only 2 available. Length byte is consumed; payload is not.
    {
        var buf <- [u8(0x03), u8(0xe2), u8(0x82)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var text = "sentinel"
        check_result(Read_utf8(text, cursor, end), m3Err_wasmUnderrun, "utf8 truncated")
        check(text == "", "utf8 truncated clears output")
        check(cursor_offset(start, cursor) == 1, "utf8 truncated position after length")
    }

    // d_m3MaxSaneUtf8Length + 1 == 10001, ULEB = 0x91 0x4e.
    {
        var buf <- [u8(0x91), u8(0x4e)]
        var start : bytes_t
        var cursor : bytes_t
        var end : cbytes_t
        init_cursor(buf, start, cursor, end)

        var text = "sentinel"
        check_result(Read_utf8(text, cursor, end), m3Err_missingUTF8, "utf8 excessive length")
        check(text == "", "utf8 excessive length clears output")
        check(cursor_offset(start, cursor) == 2, "utf8 excessive length consumes only length LEB")
    }
}


[test]
def test_normalize_type() {
    check_normalize(i8(-1), u8(M3ValueType.c_m3Type_i32), m3Err_none, "i32")
    check_normalize(i8(-2), u8(M3ValueType.c_m3Type_i64), m3Err_none, "i64")
    check_normalize(i8(-3), u8(M3ValueType.c_m3Type_f32), m3Err_none, "f32")
    check_normalize(i8(-4), u8(M3ValueType.c_m3Type_f64), m3Err_none, "f64")
    check_normalize(i8(-5), u8(M3ValueType.c_m3Type_v128), m3Err_none, "v128")
    check_normalize(i8(-64), u8(M3ValueType.c_m3Type_none), m3Err_none, "none")

    check_normalize(i8(0), u8(0), m3Err_invalidTypeId, "invalid zero")
    check_normalize(i8(-6), u8(6), m3Err_invalidTypeId, "invalid -6")
    check_normalize(i8(1), u8(0xff), m3Err_invalidTypeId, "invalid +1")
}


[export]
def main() {
    test_fixed_width_little_endian_reads()
    test_float_reads_preserve_ieee_bits()
    test_unsigned_leb_values()
    test_signed_leb_values()
    test_read_errors_and_positions()
    test_utf8_reads_and_positions()
    test_normalize_type()

    print("test_m3_core: all tests passed\n")
}
