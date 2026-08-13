options gen2
options indenting = 4

require ../source/wasm3_defs.das


// ============================================================================
// Fail-fast assertions
// ============================================================================


def expect_true(name : string; value : bool) {
    if (!value) {
        panic("{name}: expected true")
    }
}


def expect_false(name : string; value : bool) {
    if (value) {
        panic("{name}: expected false")
    }
}


def expect_u16(name : string; actual : uint16; expected : uint16) {
    if (actual != expected) {
        panic("{name}: expected {expected}, got {actual}")
    }
}


def expect_u32(name : string; actual : uint; expected : uint) {
    if (actual != expected) {
        panic("{name}: expected {expected}, got {actual}")
    }
}


def expect_u64(name : string; actual : uint64; expected : uint64) {
    if (actual != expected) {
        panic("{name}: expected {expected}, got {actual}")
    }
}


// ============================================================================
// m3_bswap16
// ============================================================================


def test_m3_bswap16() {
    expect_u16("m3_bswap16 zero",
        m3_bswap16(uint16(0x0000)),
        uint16(0x0000))

    expect_u16("m3_bswap16 all bits",
        m3_bswap16(uint16(0xffff)),
        uint16(0xffff))

    expect_u16("m3_bswap16 0x1234",
        m3_bswap16(uint16(0x1234)),
        uint16(0x3412))

    // Single-byte values in each byte position.
    expect_u16("m3_bswap16 low byte",
        m3_bswap16(uint16(0x00ff)),
        uint16(0xff00))

    expect_u16("m3_bswap16 high byte",
        m3_bswap16(uint16(0xff00)),
        uint16(0x00ff))

    expect_u16("m3_bswap16 single low byte 0xA5",
        m3_bswap16(uint16(0x00a5)),
        uint16(0xa500))

    expect_u16("m3_bswap16 single high byte 0x5A",
        m3_bswap16(uint16(0x5a00)),
        uint16(0x005a))

    expect_u16("m3_bswap16 low bit",
        m3_bswap16(uint16(0x0001)),
        uint16(0x0100))

    expect_u16("m3_bswap16 bit 8",
        m3_bswap16(uint16(0x0100)),
        uint16(0x0001))

    let values = fixed_array(
        uint16(0x0000),
        uint16(0xffff),
        uint16(0x1234),
        uint16(0x00ff),
        uint16(0xff00),
        uint16(0x00a5),
        uint16(0x5a00),
        uint16(0x0001),
        uint16(0x0100),
        uint16(0x8001),
        uint16(0x5aa5)
    )

    for (value in values) {
        expect_u16("m3_bswap16 double value={value}",
            m3_bswap16(m3_bswap16(value)),
            value)
    }
}


// ============================================================================
// m3_bswap32
// ============================================================================


def test_m3_bswap32() {
    expect_u32("m3_bswap32 zero",
        m3_bswap32(0x00000000u),
        0x00000000u)

    expect_u32("m3_bswap32 all bits",
        m3_bswap32(0xffffffffu),
        0xffffffffu)

    expect_u32("m3_bswap32 0x12345678",
        m3_bswap32(0x12345678u),
        0x78563412u)

    expect_u32("m3_bswap32 0x01020304",
        m3_bswap32(0x01020304u),
        0x04030201u)

    expect_u32("m3_bswap32 high bit",
        m3_bswap32(0x80000000u),
        0x00000080u)

    expect_u32("m3_bswap32 low bit",
        m3_bswap32(0x00000001u),
        0x01000000u)

    let values = fixed_array(
        0x00000000u,
        0xffffffffu,
        0x12345678u,
        0x01020304u,
        0x80000000u,
        0x00000001u,
        0xa55ac33cu,
        0xdeadbeefu
    )

    for (value in values) {
        expect_u32("m3_bswap32 double value={value}",
            m3_bswap32(m3_bswap32(value)),
            value)
    }
}


// ============================================================================
// m3_bswap64
// ============================================================================


def test_m3_bswap64() {
    expect_u64("m3_bswap64 zero",
        m3_bswap64(0x0000000000000000ul),
        0x0000000000000000ul)

    expect_u64("m3_bswap64 all bits",
        m3_bswap64(0xfffffffffffffffful),
        0xfffffffffffffffful)

    expect_u64("m3_bswap64 0x0123456789ABCDEF",
        m3_bswap64(0x0123456789abcdeful),
        0xefcdab8967452301ul)

    expect_u64("m3_bswap64 0x0102030405060708",
        m3_bswap64(0x0102030405060708ul),
        0x0807060504030201ul)

    expect_u64("m3_bswap64 high bit",
        m3_bswap64(0x8000000000000000ul),
        0x0000000000000080ul)

    expect_u64("m3_bswap64 low bit",
        m3_bswap64(0x0000000000000001ul),
        0x0100000000000000ul)

    let values = fixed_array(
        0x0000000000000000ul,
        0xfffffffffffffffful,
        0x0123456789abcdeful,
        0x0102030405060708ul,
        0x8000000000000000ul,
        0x0000000000000001ul,
        0xa55ac33c96695aa5ul,
        0xdeadbeef01234567ul
    )

    for (value in values) {
        expect_u64("m3_bswap64 double value={value}",
            m3_bswap64(m3_bswap64(value)),
            value)
    }
}


// ============================================================================
// m3_isBitSet — explicit examples
// ============================================================================


def test_m3_isBitSet_examples() {
    // Low bit set / clear.
    expect_true("m3_isBitSet u32 low set",
        m3_isBitSet(0x00000001u, 0u))

    expect_false("m3_isBitSet u32 low clear",
        m3_isBitSet(0x00000002u, 0u))

    // High bit set / clear, 32 bit.
    expect_true("m3_isBitSet u32 high set",
        m3_isBitSet(0x80000000u, 31u))

    expect_false("m3_isBitSet u32 high clear",
        m3_isBitSet(0x7fffffffu, 31u))

    // High bit set / clear, 64 bit.
    expect_true("m3_isBitSet u64 high set",
        m3_isBitSet(0x8000000000000000ul, 63ul))

    expect_false("m3_isBitSet u64 high clear",
        m3_isBitSet(0x7ffffffffffffffful, 63ul))

    // Alternating patterns, 32 bit.
    for (i in range(32)) {
        let pos = uint(i)

        let a_actual = m3_isBitSet(0xaaaaaaaau, pos)
        let a_expected = (i & 1) == 1
        if (a_actual != a_expected) {
            panic("m3_isBitSet 0xAAAAAAAA pos={i}: expected {a_expected}, got {a_actual}")
        }

        let five_actual = m3_isBitSet(0x55555555u, pos)
        let five_expected = (i & 1) == 0
        if (five_actual != five_expected) {
            panic("m3_isBitSet 0x55555555 pos={i}: expected {five_expected}, got {five_actual}")
        }
    }

    // Alternating patterns, 64 bit.
    for (i in range(64)) {
        let pos = uint64(i)

        let a_actual = m3_isBitSet(0xaaaaaaaaaaaaaaaaul, pos)
        let a_expected = (i & 1) == 1
        if (a_actual != a_expected) {
            panic("m3_isBitSet 64-bit A pattern pos={i}: expected {a_expected}, got {a_actual}")
        }

        let five_actual = m3_isBitSet(0x5555555555555555ul, pos)
        let five_expected = (i & 1) == 0
        if (five_actual != five_expected) {
            panic("m3_isBitSet 64-bit 5 pattern pos={i}: expected {five_expected}, got {five_actual}")
        }
    }
}


// ============================================================================
// m3_isBitSet — full-width one-hot sweep
// ============================================================================


def test_m3_isBitSet_full_width_32() {
    for (set_pos in range(32)) {
        let value = 1u << uint(set_pos)

        for (check_pos in range(32)) {
            let actual = m3_isBitSet(value, uint(check_pos))
            let expected = set_pos == check_pos

            if (actual != expected) {
                panic("m3_isBitSet u32 one-hot set={set_pos} check={check_pos}: expected {expected}, got {actual}")
            }
        }
    }
}


def test_m3_isBitSet_full_width_64() {
    for (set_pos in range(64)) {
        let value = 1ul << uint64(set_pos)

        for (check_pos in range(64)) {
            let actual = m3_isBitSet(value, uint64(check_pos))
            let expected = set_pos == check_pos

            if (actual != expected) {
                panic("m3_isBitSet u64 one-hot set={set_pos} check={check_pos}: expected {expected}, got {actual}")
            }
        }
    }
}


// ============================================================================
// M3_LIKELY / M3_UNLIKELY
// ============================================================================


def counted_bool(var evaluations : int&; value : bool) : bool {
    evaluations++
    return value
}


def test_likely_unlikely() {
    expect_true("M3_LIKELY true", M3_LIKELY(true))
    expect_false("M3_LIKELY false", M3_LIKELY(false))

    expect_true("M3_UNLIKELY true", M3_UNLIKELY(true))
    expect_false("M3_UNLIKELY false", M3_UNLIKELY(false))

    // Also verify that each argument expression is evaluated exactly once.
    var likely_count = 0
    let likely_value = M3_LIKELY(counted_bool(likely_count, true))
    expect_true("M3_LIKELY counted value", likely_value)
    if (likely_count != 1) {
        panic("M3_LIKELY evaluated argument {likely_count} times, expected 1")
    }

    var unlikely_count = 0
    let unlikely_value = M3_UNLIKELY(counted_bool(unlikely_count, false))
    expect_false("M3_UNLIKELY counted value", unlikely_value)
    if (unlikely_count != 1) {
        panic("M3_UNLIKELY evaluated argument {unlikely_count} times, expected 1")
    }
}


// ============================================================================
// Compiler / architecture information
// ============================================================================


def test_platform_information() {
    if (M3_COMPILER_VER == "") {
        panic("M3_COMPILER_VER must not be empty")
    }

    if (M3_ARCH == "") {
        panic("M3_ARCH must not be empty")
    }
}


// ============================================================================
// Endianness
// ============================================================================


def observe_little_endian() : bool {
    var probe : uint16 = uint16(0x0102)

    unsafe {
        let bytes = addr<uint8?>(probe)
        let b0 = *bytes
        let b1 = *(bytes + 1)

        if (b0 == uint8(0x02) && b1 == uint8(0x01)) {
            return true
        }

        if (b0 == uint8(0x01) && b1 == uint8(0x02)) {
            return false
        }

        panic("unexpected uint16 byte representation: first={b0}, second={b1}")
    }

    return false
}


def test_endianness() {
    let actual_little = observe_little_endian()

    if (M3_LITTLE_ENDIAN != actual_little) {
        panic("M3_LITTLE_ENDIAN mismatch: expected {actual_little}, got {M3_LITTLE_ENDIAN}")
    }

    let actual_big = !actual_little
    if (M3_BIG_ENDIAN != actual_big) {
        panic("M3_BIG_ENDIAN mismatch: expected {actual_big}, got {M3_BIG_ENDIAN}")
    }

    if (M3_LITTLE_ENDIAN == M3_BIG_ENDIAN) {
        panic("exactly one of M3_LITTLE_ENDIAN and M3_BIG_ENDIAN must be true")
    }
}


// ============================================================================
// Main
// ============================================================================


[export]
def main {
    test_m3_bswap16()
    test_m3_bswap32()
    test_m3_bswap64()

    test_m3_isBitSet_examples()
    test_m3_isBitSet_full_width_32()
    test_m3_isBitSet_full_width_64()

    test_likely_unlikely()
    test_platform_information()
    test_endianness()

    print("test_wasm3_defs: all tests passed\n")
}
