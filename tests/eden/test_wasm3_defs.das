options gen2
options indenting = 4

module test_wasm3_defs shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/wasm3_defs

/*
    test_wasm3_defs.das: Eden counterpart of
    .upstream/tests/integration/test_wasm3_defs.das.

    Every upstream [test] has a counterpart below with the same checks; the
    fail-fast expect_* helpers of the upstream file become the recording
    checks of eden_test (equal / check), so one failing value never hides
    the others.

    Eden: test_endianness cannot observe the host representation (the
    upstream probe reads a uint16 through its address, which the sandbox
    forbids); it checks the constant contract of wasm3_defs instead:
    M3_LITTLE_ENDIAN is true (wasm is little-endian by definition) and
    exactly one of the two flags is set.
*/


// ============================================================================
// m3_bswap16
// ============================================================================


def test_m3_bswap16(var t : TestRun; fx : FixtureSource) {
    equal(t, m3_bswap16(uint16(0x0000)), uint16(0x0000), "m3_bswap16 zero")

    equal(t, m3_bswap16(uint16(0xffff)), uint16(0xffff), "m3_bswap16 all bits")

    equal(t, m3_bswap16(uint16(0x1234)), uint16(0x3412), "m3_bswap16 0x1234")

    // Single-byte values in each byte position.
    equal(t, m3_bswap16(uint16(0x00ff)), uint16(0xff00), "m3_bswap16 low byte")

    equal(t, m3_bswap16(uint16(0xff00)), uint16(0x00ff), "m3_bswap16 high byte")

    equal(t, m3_bswap16(uint16(0x00a5)), uint16(0xa500), "m3_bswap16 single low byte 0xA5")

    equal(t, m3_bswap16(uint16(0x5a00)), uint16(0x005a), "m3_bswap16 single high byte 0x5A")

    equal(t, m3_bswap16(uint16(0x0001)), uint16(0x0100), "m3_bswap16 low bit")

    equal(t, m3_bswap16(uint16(0x0100)), uint16(0x0001), "m3_bswap16 bit 8")

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
        equal(t, m3_bswap16(m3_bswap16(value)), value, "m3_bswap16 double value={value}")
    }
}


// ============================================================================
// m3_bswap32
// ============================================================================


def test_m3_bswap32(var t : TestRun; fx : FixtureSource) {
    equal(t, m3_bswap32(0x00000000u), 0x00000000u, "m3_bswap32 zero")

    equal(t, m3_bswap32(0xffffffffu), 0xffffffffu, "m3_bswap32 all bits")

    equal(t, m3_bswap32(0x12345678u), 0x78563412u, "m3_bswap32 0x12345678")

    equal(t, m3_bswap32(0x01020304u), 0x04030201u, "m3_bswap32 0x01020304")

    equal(t, m3_bswap32(0x80000000u), 0x00000080u, "m3_bswap32 high bit")

    equal(t, m3_bswap32(0x00000001u), 0x01000000u, "m3_bswap32 low bit")

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
        equal(t, m3_bswap32(m3_bswap32(value)), value, "m3_bswap32 double value={value}")
    }
}


// ============================================================================
// m3_bswap64
// ============================================================================


def test_m3_bswap64(var t : TestRun; fx : FixtureSource) {
    equal(t, m3_bswap64(0x0000000000000000ul), 0x0000000000000000ul, "m3_bswap64 zero")

    equal(t, m3_bswap64(0xfffffffffffffffful), 0xfffffffffffffffful, "m3_bswap64 all bits")

    equal(t, m3_bswap64(0x0123456789abcdeful), 0xefcdab8967452301ul, "m3_bswap64 0x0123456789ABCDEF")

    equal(t, m3_bswap64(0x0102030405060708ul), 0x0807060504030201ul, "m3_bswap64 0x0102030405060708")

    equal(t, m3_bswap64(0x8000000000000000ul), 0x0000000000000080ul, "m3_bswap64 high bit")

    equal(t, m3_bswap64(0x0000000000000001ul), 0x0100000000000000ul, "m3_bswap64 low bit")

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
        equal(t, m3_bswap64(m3_bswap64(value)), value, "m3_bswap64 double value={value}")
    }
}


// ============================================================================
// m3_isBitSet — explicit examples
// ============================================================================


def test_m3_isBitSet_examples(var t : TestRun; fx : FixtureSource) {
    // Low bit set / clear.
    check(t, m3_isBitSet(0x00000001u, 0u), "m3_isBitSet u32 low set")

    check(t, !m3_isBitSet(0x00000002u, 0u), "m3_isBitSet u32 low clear")

    // High bit set / clear, 32 bit.
    check(t, m3_isBitSet(0x80000000u, 31u), "m3_isBitSet u32 high set")

    check(t, !m3_isBitSet(0x7fffffffu, 31u), "m3_isBitSet u32 high clear")

    // High bit set / clear, 64 bit.
    check(t, m3_isBitSet(0x8000000000000000ul, 63ul), "m3_isBitSet u64 high set")

    check(t, !m3_isBitSet(0x7ffffffffffffffful, 63ul), "m3_isBitSet u64 high clear")

    // Alternating patterns, 32 bit.
    for (i in range(32)) {
        let pos = uint(i)

        let a_actual = m3_isBitSet(0xaaaaaaaau, pos)
        let a_expected = (i & 1) == 1
        equal(t, a_actual, a_expected, "m3_isBitSet 0xAAAAAAAA pos={i}")

        let five_actual = m3_isBitSet(0x55555555u, pos)
        let five_expected = (i & 1) == 0
        equal(t, five_actual, five_expected, "m3_isBitSet 0x55555555 pos={i}")
    }

    // Alternating patterns, 64 bit.
    for (i in range(64)) {
        let pos = uint64(i)

        let a_actual = m3_isBitSet(0xaaaaaaaaaaaaaaaaul, pos)
        let a_expected = (i & 1) == 1
        equal(t, a_actual, a_expected, "m3_isBitSet 64-bit A pattern pos={i}")

        let five_actual = m3_isBitSet(0x5555555555555555ul, pos)
        let five_expected = (i & 1) == 0
        equal(t, five_actual, five_expected, "m3_isBitSet 64-bit 5 pattern pos={i}")
    }
}


// ============================================================================
// m3_isBitSet — full-width one-hot sweep
// ============================================================================


def test_m3_isBitSet_full_width_32(var t : TestRun; fx : FixtureSource) {
    for (set_pos in range(32)) {
        let value = 1u << uint(set_pos)

        for (check_pos in range(32)) {
            let actual = m3_isBitSet(value, uint(check_pos))
            let expected = set_pos == check_pos

            equal(t, actual, expected, "m3_isBitSet u32 one-hot set={set_pos} check={check_pos}")
        }
    }
}


def test_m3_isBitSet_full_width_64(var t : TestRun; fx : FixtureSource) {
    for (set_pos in range(64)) {
        let value = 1ul << uint64(set_pos)

        for (check_pos in range(64)) {
            let actual = m3_isBitSet(value, uint64(check_pos))
            let expected = set_pos == check_pos

            equal(t, actual, expected, "m3_isBitSet u64 one-hot set={set_pos} check={check_pos}")
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


def test_likely_unlikely(var t : TestRun; fx : FixtureSource) {
    check(t, M3_LIKELY(true), "M3_LIKELY true")
    check(t, !M3_LIKELY(false), "M3_LIKELY false")

    check(t, M3_UNLIKELY(true), "M3_UNLIKELY true")
    check(t, !M3_UNLIKELY(false), "M3_UNLIKELY false")

    // Also verify that each argument expression is evaluated exactly once.
    var likely_count = 0
    let likely_value = M3_LIKELY(counted_bool(likely_count, true))
    check(t, likely_value, "M3_LIKELY counted value")
    equal(t, likely_count, 1, "M3_LIKELY evaluates its argument once")

    var unlikely_count = 0
    let unlikely_value = M3_UNLIKELY(counted_bool(unlikely_count, false))
    check(t, !unlikely_value, "M3_UNLIKELY counted value")
    equal(t, unlikely_count, 1, "M3_UNLIKELY evaluates its argument once")
}


// ============================================================================
// Compiler / architecture information
// ============================================================================


def test_platform_information(var t : TestRun; fx : FixtureSource) {
    check(t, M3_COMPILER_VER != "", "M3_COMPILER_VER must not be empty")

    check(t, M3_ARCH != "", "M3_ARCH must not be empty")
}


// ============================================================================
// Endianness
// ============================================================================


def test_endianness(var t : TestRun; fx : FixtureSource) {
    // Eden: the upstream observe_little_endian() reads the bytes of a uint16
    // through an unsafe address; the sandbox forbids that, and wasm3_defs
    // fixes the byte order to little-endian (wasm is little-endian by
    // definition, see the module header). The expected value is therefore
    // the contract itself rather than an observation of the host.
    let actual_little = true

    equal(t, M3_LITTLE_ENDIAN, actual_little, "M3_LITTLE_ENDIAN mismatch")

    let actual_big = !actual_little
    equal(t, M3_BIG_ENDIAN, actual_big, "M3_BIG_ENDIAN mismatch")

    check(t, M3_LITTLE_ENDIAN != M3_BIG_ENDIAN, "exactly one of M3_LITTLE_ENDIAN and M3_BIG_ENDIAN must be true")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_wasm3_defs(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_m3_bswap16")
    test_m3_bswap16(t, fx)
    begin_test(t, "test_m3_bswap32")
    test_m3_bswap32(t, fx)
    begin_test(t, "test_m3_bswap64")
    test_m3_bswap64(t, fx)

    begin_test(t, "test_m3_isBitSet_examples")
    test_m3_isBitSet_examples(t, fx)
    begin_test(t, "test_m3_isBitSet_full_width_32")
    test_m3_isBitSet_full_width_32(t, fx)
    begin_test(t, "test_m3_isBitSet_full_width_64")
    test_m3_isBitSet_full_width_64(t, fx)

    begin_test(t, "test_likely_unlikely")
    test_likely_unlikely(t, fx)
    begin_test(t, "test_platform_information")
    test_platform_information(t, fx)
    begin_test(t, "test_endianness")
    test_endianness(t, fx)
}
