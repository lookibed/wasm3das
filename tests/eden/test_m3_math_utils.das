options gen2
options indenting = 4

module test_m3_math_utils shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_math_utils
require daslib/math_bits

/*
    test_m3_math_utils.das: Eden counterpart of
    .upstream/tests/integration/test_m3_math_utils.das.

    Tests:
        rotl32
        rotr32
        rotl64
        rotr64

    Проверяются:

        - zero
        - single low bit
        - highest bit
        - all bits
        - alternating 1010...
        - alternating 0101...
        - arbitrary asymmetric pattern

    Кроме фиксированных expected values используется независимая
    reference implementation, которая вращает значение по одному биту.

    Every upstream [test] has a counterpart below with the same values in
    the same order. The fail-fast expect_u32 / expect_u64 helpers of the
    upstream file (panic on the first mismatch) become recording checks of
    eden_test, so one failing value never hides the others.

    Eden: the bit views of the float results (bits_f32 / bits_f64) and the
    construction of a float from its bits (as_f32 / as_f64) come from
    daslib/math_bits (float_bits_to_uint / double_bits_to_uint64 /
    uint_bits_to_float / uint64_bits_to_double) instead of a reinterpret.
    One test is added for the helpers the upstream suite never calls
    (test_conversions_and_minmax: the trapping and saturating float-to-int
    conversions at their range constants, the wasm min/max rules, signed and
    unsigned div/rem, the bit-count helpers); it has no upstream counterpart.
*/


/*
    Assertions
*/

def private expect_u32(
                       var t : TestRun;
                       name : string;
                       actual : u32;
                       expected : u32
                       ) {
    equal(t, actual, expected, name)
}


def private expect_u64(
                       var t : TestRun;
                       name : string;
                       actual : u64;
                       expected : u64
                       ) {
    equal(t, actual, expected, name)
}


/*
    Независимые reference implementations.

    Намеренно НЕ повторяют формулу:

        (n << c) | (n >> (...))

    Вместо этого делают rotation по одному биту.
*/


def private reference_rotl32(n : u32; c : uint) : u32 {
    var result = n

    let count = int(c & 31u)

    for (_i in range(count)) {
        let carry = (result >> 31u) & 1u

        result <<= 1u
        result |= carry
    }

    return result
}


def private reference_rotr32(n : u32; c : uint) : u32 {
    var result = n

    let count = int(c & 31u)

    for (_i in range(count)) {
        let carry = result & 1u

        result >>= 1u
        result |= carry << 31u
    }

    return result
}


def private reference_rotl64(n : u64; c : uint) : u64 {
    var result = n

    let count = int(c & 63u)

    for (_i in range(count)) {
        let carry = (result >> 63ul) & 1ul

        result <<= 1ul
        result |= carry
    }

    return result
}


def private reference_rotr64(n : u64; c : uint) : u64 {
    var result = n

    let count = int(c & 63u)

    for (_i in range(count)) {
        let carry = result & 1ul

        result >>= 1ul
        result |= carry << 63ul
    }

    return result
}


/*
    ------------------------------------------------------------
    Explicit expected values
    ------------------------------------------------------------

    Эти проверки нужны отдельно от reference implementation.
*/


def test_expected_32(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038

    /*
        zero
    */

    expect_u32(t, "rotl32 zero c=7", rotl32(0u, 7u), 0u)
    expect_u32(t, "rotr32 zero c=7", rotr32(0u, 7u), 0u)


    /*
        single low bit
    */

    expect_u32(t, "rotl32 bit0 c=1", rotl32(0x00000001u, 1u), 0x00000002u)
    expect_u32(t, "rotr32 bit0 c=1", rotr32(0x00000001u, 1u), 0x80000000u)
    expect_u32(t, "rotl32 bit0 c=7", rotl32(0x00000001u, 7u), 0x00000080u)
    expect_u32(t, "rotr32 bit0 c=7", rotr32(0x00000001u, 7u), 0x02000000u)


    /*
        highest bit
    */

    expect_u32(t, "rotl32 msb c=1", rotl32(0x80000000u, 1u), 0x00000001u)
    expect_u32(t, "rotr32 msb c=1", rotr32(0x80000000u, 1u), 0x40000000u)
    expect_u32(t, "rotl32 msb c=7", rotl32(0x80000000u, 7u), 0x00000040u)
    expect_u32(t, "rotr32 msb c=7", rotr32(0x80000000u, 7u), 0x01000000u)


    /*
        all bits
    */

    expect_u32(t, "rotl32 all c=7", rotl32(0xFFFFFFFFu, 7u), 0xFFFFFFFFu)
    expect_u32(t, "rotr32 all c=7", rotr32(0xFFFFFFFFu, 7u), 0xFFFFFFFFu)


    /*
        alternating 1010...
    */

    expect_u32(t, "rotl32 AAAAAAAA c=1", rotl32(0xAAAAAAAAu, 1u), 0x55555555u)
    expect_u32(t, "rotr32 AAAAAAAA c=1", rotr32(0xAAAAAAAAu, 1u), 0x55555555u)


    /*
        alternating 0101...
    */

    expect_u32(t, "rotl32 55555555 c=1", rotl32(0x55555555u, 1u), 0xAAAAAAAAu)
    expect_u32(t, "rotr32 55555555 c=1", rotr32(0x55555555u, 1u), 0xAAAAAAAAu)


    /*
        arbitrary asymmetric pattern
    */

    expect_u32(t, "rotl32 12345678 c=1", rotl32(0x12345678u, 1u), 0x2468ACF0u)
    expect_u32(t, "rotr32 12345678 c=1", rotr32(0x12345678u, 1u), 0x091A2B3Cu)
    expect_u32(t, "rotl32 12345678 c=7", rotl32(0x12345678u, 7u), 0x1A2B3C09u)
    expect_u32(t, "rotr32 12345678 c=7", rotr32(0x12345678u, 7u), 0xF02468ACu)
    expect_u32(t, "rotl32 12345678 c=15", rotl32(0x12345678u, 15u), 0x2B3C091Au)
    expect_u32(t, "rotr32 12345678 c=15", rotr32(0x12345678u, 15u), 0xACF02468u)
    expect_u32(t, "rotl32 12345678 c=16", rotl32(0x12345678u, 16u), 0x56781234u)
    expect_u32(t, "rotr32 12345678 c=16", rotr32(0x12345678u, 16u), 0x56781234u)
    expect_u32(t, "rotl32 12345678 c=31", rotl32(0x12345678u, 31u), 0x091A2B3Cu)
    expect_u32(t, "rotr32 12345678 c=31", rotr32(0x12345678u, 31u), 0x2468ACF0u)

    /*
        255 % 32 == 31
    */

    expect_u32(t, "rotl32 12345678 c=255", rotl32(0x12345678u, 255u), 0x091A2B3Cu)
    expect_u32(t, "rotr32 12345678 c=255", rotr32(0x12345678u, 255u), 0x2468ACF0u)
}


def test_expected_64(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038

    /*
        zero
    */

    expect_u64(t, "rotl64 zero c=7", rotl64(0ul, 7u), 0ul)
    expect_u64(t, "rotr64 zero c=7", rotr64(0ul, 7u), 0ul)


    /*
        single low bit
    */

    expect_u64(t, "rotl64 bit0 c=1", rotl64(0x0000000000000001ul, 1u), 0x0000000000000002ul)
    expect_u64(t, "rotr64 bit0 c=1", rotr64(0x0000000000000001ul, 1u), 0x8000000000000000ul)
    expect_u64(t, "rotl64 bit0 c=7", rotl64(0x0000000000000001ul, 7u), 0x0000000000000080ul)
    expect_u64(t, "rotr64 bit0 c=7", rotr64(0x0000000000000001ul, 7u), 0x0200000000000000ul)


    /*
        highest bit
    */

    expect_u64(t, "rotl64 msb c=1", rotl64(0x8000000000000000ul, 1u), 0x0000000000000001ul)
    expect_u64(t, "rotr64 msb c=1", rotr64(0x8000000000000000ul, 1u), 0x4000000000000000ul)
    expect_u64(t, "rotl64 msb c=7", rotl64(0x8000000000000000ul, 7u), 0x0000000000000040ul)
    expect_u64(t, "rotr64 msb c=7", rotr64(0x8000000000000000ul, 7u), 0x0100000000000000ul)


    /*
        all bits
    */

    expect_u64(t, "rotl64 all c=7", rotl64(0xFFFFFFFFFFFFFFFFul, 7u), 0xFFFFFFFFFFFFFFFFul)
    expect_u64(t, "rotr64 all c=7", rotr64(0xFFFFFFFFFFFFFFFFul, 7u), 0xFFFFFFFFFFFFFFFFul)


    /*
        alternating 1010...
    */

    expect_u64(t, "rotl64 AAAAAAAAAAAAAAAA c=1", rotl64(0xAAAAAAAAAAAAAAAAul, 1u), 0x5555555555555555ul)
    expect_u64(t, "rotr64 AAAAAAAAAAAAAAAA c=1", rotr64(0xAAAAAAAAAAAAAAAAul, 1u), 0x5555555555555555ul)


    /*
        alternating 0101...
    */

    expect_u64(t, "rotl64 5555555555555555 c=1", rotl64(0x5555555555555555ul, 1u), 0xAAAAAAAAAAAAAAAAul)
    expect_u64(t, "rotr64 5555555555555555 c=1", rotr64(0x5555555555555555ul, 1u), 0xAAAAAAAAAAAAAAAAul)


    /*
        arbitrary asymmetric pattern
    */

    expect_u64(t, "rotl64 0123456789ABCDEF c=1", rotl64(0x0123456789ABCDEFul, 1u), 0x02468ACF13579BDEul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=1", rotr64(0x0123456789ABCDEFul, 1u), 0x8091A2B3C4D5E6F7ul)
    expect_u64(t, "rotl64 0123456789ABCDEF c=7", rotl64(0x0123456789ABCDEFul, 7u), 0x91A2B3C4D5E6F780ul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=7", rotr64(0x0123456789ABCDEFul, 7u), 0xDE02468ACF13579Bul)
    expect_u64(t, "rotl64 0123456789ABCDEF c=31", rotl64(0x0123456789ABCDEFul, 31u), 0xC4D5E6F78091A2B3ul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=31", rotr64(0x0123456789ABCDEFul, 31u), 0x13579BDE02468ACFul)
    expect_u64(t, "rotl64 0123456789ABCDEF c=32", rotl64(0x0123456789ABCDEFul, 32u), 0x89ABCDEF01234567ul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=32", rotr64(0x0123456789ABCDEFul, 32u), 0x89ABCDEF01234567ul)
    expect_u64(t, "rotl64 0123456789ABCDEF c=33", rotl64(0x0123456789ABCDEFul, 33u), 0x13579BDE02468ACFul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=33", rotr64(0x0123456789ABCDEFul, 33u), 0xC4D5E6F78091A2B3ul)
    expect_u64(t, "rotl64 0123456789ABCDEF c=63", rotl64(0x0123456789ABCDEFul, 63u), 0x8091A2B3C4D5E6F7ul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=63", rotr64(0x0123456789ABCDEFul, 63u), 0x02468ACF13579BDEul)

    /*
        255 % 64 == 63
    */

    expect_u64(t, "rotl64 0123456789ABCDEF c=255", rotl64(0x0123456789ABCDEFul, 255u), 0x8091A2B3C4D5E6F7ul)
    expect_u64(t, "rotr64 0123456789ABCDEF c=255", rotr64(0x0123456789ABCDEFul, 255u), 0x02468ACF13579BDEul)
}


/*
    ------------------------------------------------------------
    Full 32-bit test matrix
    ------------------------------------------------------------
*/


def test_rotations_32(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038

    /*
        Значения:

            zero
            single low bit
            highest bit
            all bits
            alternating 1010
            alternating 0101
            arbitrary asymmetric
    */

    let values = fixed_array(
        0x00000000u,
        0x00000001u,
        0x80000000u,
        0xFFFFFFFFu,
        0xAAAAAAAAu,
        0x55555555u,
        0x12345678u
    )

    let counts = fixed_array(
        0u,
        1u,
        7u,
        15u,
        16u,
        31u,
        32u,
        33u,
        63u,
        64u,
        255u
    )


    for (value in values) {

        /*
            Rotation by zero is identity.
        */

        expect_u32(t, "rotl32 identity c=0 value={value}", rotl32(value, 0u), value)
        expect_u32(t, "rotr32 identity c=0 value={value}", rotr32(value, 0u), value)


        for (c in counts) {

            let left = rotl32(value, c)
            let right = rotr32(value, c)

            /*
                Compare against independent reference.
            */

            expect_u32(t, "rotl32 reference value={value} c={c}", left, reference_rotl32(value, c))
            expect_u32(t, "rotr32 reference value={value} c={c}", right, reference_rotr32(value, c))


            /*
                rotl -> rotr must restore original.
            */

            expect_u32(t, "rotl32->rotr32 value={value} c={c}", rotr32(left, c), value)


            /*
                rotr -> rotl must restore original.
            */

            expect_u32(t, "rotr32->rotl32 value={value} c={c}", rotl32(right, c), value)


            /*
                Counter is periodic modulo 32.
            */

            expect_u32(t, "rotl32 periodic +32 value={value} c={c}", rotl32(value, c + 32u), left)
            expect_u32(t, "rotr32 periodic +32 value={value} c={c}", rotr32(value, c + 32u), right)


            /*
                Also explicitly compare against c & 31.
            */

            expect_u32(t, "rotl32 modulo-32 value={value} c={c}", left, rotl32(value, c & 31u))
            expect_u32(t, "rotr32 modulo-32 value={value} c={c}", right, rotr32(value, c & 31u))
        }
    }


    /*
        All bits set must be invariant for every requested counter.
    */

    for (c in counts) {
        expect_u32(t, "rotl32 all-bits invariant c={c}", rotl32(0xFFFFFFFFu, c), 0xFFFFFFFFu)
        expect_u32(t, "rotr32 all-bits invariant c={c}", rotr32(0xFFFFFFFFu, c), 0xFFFFFFFFu)
    }
}


/*
    ------------------------------------------------------------
    Full 64-bit test matrix
    ------------------------------------------------------------
*/


def test_rotations_64(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038

    let values = fixed_array(
        0x0000000000000000ul,
        0x0000000000000001ul,
        0x8000000000000000ul,
        0xFFFFFFFFFFFFFFFFul,
        0xAAAAAAAAAAAAAAAAul,
        0x5555555555555555ul,
        0x0123456789ABCDEFul
    )

    let counts = fixed_array(
        0u,
        1u,
        7u,
        31u,
        32u,
        33u,
        63u,
        64u,
        65u,
        127u,
        128u,
        255u
    )


    for (value in values) {

        /*
            Rotation by zero is identity.
        */

        expect_u64(t, "rotl64 identity c=0 value={value}", rotl64(value, 0u), value)
        expect_u64(t, "rotr64 identity c=0 value={value}", rotr64(value, 0u), value)


        for (c in counts) {

            let left = rotl64(value, c)
            let right = rotr64(value, c)


            /*
                Independent reference.
            */

            expect_u64(t, "rotl64 reference value={value} c={c}", left, reference_rotl64(value, c))
            expect_u64(t, "rotr64 reference value={value} c={c}", right, reference_rotr64(value, c))


            /*
                rotl -> rotr restores original.
            */

            expect_u64(t, "rotl64->rotr64 value={value} c={c}", rotr64(left, c), value)


            /*
                rotr -> rotl restores original.
            */

            expect_u64(t, "rotr64->rotl64 value={value} c={c}", rotl64(right, c), value)


            /*
                Counter is periodic modulo 64.
            */

            expect_u64(t, "rotl64 periodic +64 value={value} c={c}", rotl64(value, c + 64u), left)
            expect_u64(t, "rotr64 periodic +64 value={value} c={c}", rotr64(value, c + 64u), right)


            /*
                Explicit c & 63 check.
            */

            expect_u64(t, "rotl64 modulo-64 value={value} c={c}", left, rotl64(value, c & 63u))
            expect_u64(t, "rotr64 modulo-64 value={value} c={c}", right, rotr64(value, c & 63u))
        }
    }


    /*
        All bits set must be invariant for every requested counter.
    */

    for (c in counts) {
        expect_u64(t, "rotl64 all-bits invariant c={c}", rotl64(0xFFFFFFFFFFFFFFFFul, c), 0xFFFFFFFFFFFFFFFFul)
        expect_u64(t, "rotr64 all-bits invariant c={c}", rotr64(0xFFFFFFFFFFFFFFFFul, c), 0xFFFFFFFFFFFFFFFFul)
    }
}


/*
    ------------------------------------------------------------
    Cross-properties
    ------------------------------------------------------------
*/


def test_cross_properties_32(var t : TestRun; fx : FixtureSource) {
    let values = fixed_array(
        0x00000000u,
        0x00000001u,
        0x80000000u,
        0xFFFFFFFFu,
        0xAAAAAAAAu,
        0x55555555u,
        0x12345678u
    )

    let counts = fixed_array(
        0u,
        1u,
        7u,
        15u,
        16u,
        31u,
        32u,
        33u,
        63u,
        64u,
        255u
    )

    for (value in values) {
        for (c in counts) {

            /*
                rotl(x, c) == rotr(x, 32 - c)
                after reducing c modulo 32.
            */

            let normalized = c & 31u
            let opposite = (32u - normalized) & 31u

            expect_u32(t, "rotl32 == opposite rotr32 value={value} c={c}", rotl32(value, c), rotr32(value, opposite))
            expect_u32(t, "rotr32 == opposite rotl32 value={value} c={c}", rotr32(value, c), rotl32(value, opposite))
        }
    }
}


def test_cross_properties_64(var t : TestRun; fx : FixtureSource) {
    let values = fixed_array(
        0x0000000000000000ul,
        0x0000000000000001ul,
        0x8000000000000000ul,
        0xFFFFFFFFFFFFFFFFul,
        0xAAAAAAAAAAAAAAAAul,
        0x5555555555555555ul,
        0x0123456789ABCDEFul
    )

    let counts = fixed_array(
        0u,
        1u,
        7u,
        31u,
        32u,
        33u,
        63u,
        64u,
        65u,
        127u,
        128u,
        255u
    )

    for (value in values) {
        for (c in counts) {

            let normalized = c & 63u
            let opposite = (64u - normalized) & 63u

            expect_u64(t, "rotl64 == opposite rotr64 value={value} c={c}", rotl64(value, c), rotr64(value, opposite))
            expect_u64(t, "rotr64 == opposite rotl64 value={value} c={c}", rotr64(value, c), rotl64(value, opposite))
        }
    }
}


/*
    ------------------------------------------------------------
    libm functions named by m3_exec.h
    ------------------------------------------------------------

    fabsf/fabs/floorf/ceilf/rintf/rint are the functions the
    d_m3UnaryOp_f rows of C m3_exec.h call. They are compared here against
    the C library results for the cases the daslang `math` module gets wrong:
    signed zero, infinities, NaN, FLT_MAX and the half-way values, where
    libm rint rounds to even and math::round rounds away from zero.
*/


def private bits_f32(value : f32) : u32 {
    return float_bits_to_uint(value)   // Eden: math_bits view (upstream: reinterpret<u32>)
}


def private bits_f64(value : f64) : u64 {
    return double_bits_to_uint64(value)   // Eden: math_bits view (upstream: reinterpret<u64>)
}


def private as_f32(bits : u32) : f32 {
    return uint_bits_to_float(bits)   // Eden: math_bits cast (upstream: reinterpret<f32>)
}


def private as_f64(bits : u64) : f64 {
    return uint64_bits_to_double(bits)   // Eden: math_bits cast (upstream: reinterpret<f64>)
}


def test_fabs(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038
    expect_u32(t, "fabsf(-0.0)", bits_f32(fabsf(as_f32(0x80000000u))), 0x00000000u)
    expect_u32(t, "fabsf(+0.0)", bits_f32(fabsf(as_f32(0x00000000u))), 0x00000000u)
    expect_u32(t, "fabsf(-1.5)", bits_f32(fabsf(as_f32(0xbfc00000u))), 0x3fc00000u)
    expect_u32(t, "fabsf(-inf)", bits_f32(fabsf(as_f32(0xff800000u))), 0x7f800000u)
    expect_u32(t, "fabsf(-nan)", bits_f32(fabsf(as_f32(0xffc00000u))), 0x7fc00000u)

    expect_u64(t, "fabs(-0.0)", bits_f64(fabs(as_f64(0x8000000000000000ul))), 0x0000000000000000ul)
    expect_u64(t, "fabs(-1.5)", bits_f64(fabs(as_f64(0xbff8000000000000ul))), 0x3ff8000000000000ul)
    expect_u64(t, "fabs(-inf)", bits_f64(fabs(as_f64(0xfff0000000000000ul))), 0x7ff0000000000000ul)
}


def test_floorf(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038
    expect_u32(t, "floorf(+0.0)", bits_f32(floorf(as_f32(0x00000000u))), 0x00000000u)
    expect_u32(t, "floorf(-0.0)", bits_f32(floorf(as_f32(0x80000000u))), 0x80000000u)
    expect_u32(t, "floorf(0.5)", bits_f32(floorf(as_f32(0x3f000000u))), 0x00000000u)
    expect_u32(t, "floorf(1.5)", bits_f32(floorf(as_f32(0x3fc00000u))), 0x3f800000u)
    expect_u32(t, "floorf(-0.5)", bits_f32(floorf(as_f32(0xbf000000u))), 0xbf800000u)
    expect_u32(t, "floorf(-1.5)", bits_f32(floorf(as_f32(0xbfc00000u))), 0xc0000000u)
    expect_u32(t, "floorf(2.0)", bits_f32(floorf(as_f32(0x40000000u))), 0x40000000u)
    expect_u32(t, "floorf(FLT_MAX)", bits_f32(floorf(as_f32(0x7f7fffffu))), 0x7f7fffffu)
    expect_u32(t, "floorf(-FLT_MAX)", bits_f32(floorf(as_f32(0xff7fffffu))), 0xff7fffffu)
    expect_u32(t, "floorf(inf)", bits_f32(floorf(as_f32(0x7f800000u))), 0x7f800000u)
    expect_u32(t, "floorf(-inf)", bits_f32(floorf(as_f32(0xff800000u))), 0xff800000u)
    expect_u32(t, "floorf(nan)", bits_f32(floorf(as_f32(0x7fc00000u))), 0x7fc00000u)
}


def test_ceilf(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038
    expect_u32(t, "ceilf(+0.0)", bits_f32(ceilf(as_f32(0x00000000u))), 0x00000000u)
    expect_u32(t, "ceilf(-0.0)", bits_f32(ceilf(as_f32(0x80000000u))), 0x80000000u)
    expect_u32(t, "ceilf(0.5)", bits_f32(ceilf(as_f32(0x3f000000u))), 0x3f800000u)
    expect_u32(t, "ceilf(1.5)", bits_f32(ceilf(as_f32(0x3fc00000u))), 0x40000000u)
    // -0.5 rounds up to negative zero, not to +0.0.
    expect_u32(t, "ceilf(-0.5)", bits_f32(ceilf(as_f32(0xbf000000u))), 0x80000000u)
    expect_u32(t, "ceilf(-1.5)", bits_f32(ceilf(as_f32(0xbfc00000u))), 0xbf800000u)
    expect_u32(t, "ceilf(FLT_MAX)", bits_f32(ceilf(as_f32(0x7f7fffffu))), 0x7f7fffffu)
    expect_u32(t, "ceilf(inf)", bits_f32(ceilf(as_f32(0x7f800000u))), 0x7f800000u)
    expect_u32(t, "ceilf(-inf)", bits_f32(ceilf(as_f32(0xff800000u))), 0xff800000u)
    expect_u32(t, "ceilf(nan)", bits_f32(ceilf(as_f32(0x7fc00000u))), 0x7fc00000u)
}


def test_rintf(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038
    // Halves round to even, unlike math::round which rounds away from zero.
    expect_u32(t, "rintf(0.5)", bits_f32(rintf(as_f32(0x3f000000u))), 0x00000000u)
    expect_u32(t, "rintf(1.5)", bits_f32(rintf(as_f32(0x3fc00000u))), 0x40000000u)
    expect_u32(t, "rintf(2.5)", bits_f32(rintf(as_f32(0x40200000u))), 0x40000000u)
    expect_u32(t, "rintf(4.5)", bits_f32(rintf(as_f32(0x40900000u))), 0x40800000u)
    expect_u32(t, "rintf(-0.5)", bits_f32(rintf(as_f32(0xbf000000u))), 0x80000000u)
    expect_u32(t, "rintf(-1.5)", bits_f32(rintf(as_f32(0xbfc00000u))), 0xc0000000u)
    expect_u32(t, "rintf(-2.5)", bits_f32(rintf(as_f32(0xc0200000u))), 0xc0000000u)
    // The smallest denormal rounds to a zero of its own sign.
    expect_u32(t, "rintf(min denormal)", bits_f32(rintf(as_f32(0x00000001u))), 0x00000000u)
    expect_u32(t, "rintf(-min denormal)", bits_f32(rintf(as_f32(0x80000001u))), 0x80000000u)
    expect_u32(t, "rintf(-0.0)", bits_f32(rintf(as_f32(0x80000000u))), 0x80000000u)
    expect_u32(t, "rintf(FLT_MAX)", bits_f32(rintf(as_f32(0x7f7fffffu))), 0x7f7fffffu)
    expect_u32(t, "rintf(inf)", bits_f32(rintf(as_f32(0x7f800000u))), 0x7f800000u)
    expect_u32(t, "rintf(nan)", bits_f32(rintf(as_f32(0x7fc00000u))), 0x7fc00000u)
}


def test_rint(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038
    expect_u64(t, "rint(0.5)", bits_f64(rint(as_f64(0x3fe0000000000000ul))), 0x0000000000000000ul)
    expect_u64(t, "rint(1.5)", bits_f64(rint(as_f64(0x3ff8000000000000ul))), 0x4000000000000000ul)
    expect_u64(t, "rint(2.5)", bits_f64(rint(as_f64(0x4004000000000000ul))), 0x4000000000000000ul)
    expect_u64(t, "rint(-0.5)", bits_f64(rint(as_f64(0xbfe0000000000000ul))), 0x8000000000000000ul)
    expect_u64(t, "rint(-1.5)", bits_f64(rint(as_f64(0xbff8000000000000ul))), 0xc000000000000000ul)
    expect_u64(t, "rint(-2.5)", bits_f64(rint(as_f64(0xc004000000000000ul))), 0xc000000000000000ul)
    expect_u64(t, "rint(min denormal)", bits_f64(rint(as_f64(0x0000000000000001ul))), 0x0000000000000000ul)
    expect_u64(t, "rint(min normal)", bits_f64(rint(as_f64(0x0010000000000000ul))), 0x0000000000000000ul)
    expect_u64(t, "rint(-0.0)", bits_f64(rint(as_f64(0x8000000000000000ul))), 0x8000000000000000ul)
    expect_u64(t, "rint(inf)", bits_f64(rint(as_f64(0x7ff0000000000000ul))), 0x7ff0000000000000ul)
    expect_u64(t, "rint(nan)", bits_f64(rint(as_f64(0x7ff8000000000000ul))), 0x7ff8000000000000ul)
    // a signalling NaN comes back quieted with its payload and sign (glibc,
    // the C wasm3's libm; f64.wast nan:arithmetic)
    expect_u64(t, "rint(snan)", bits_f64(rint(as_f64(0x7ff4000000000000ul))), 0x7ffc000000000000ul)
    expect_u64(t, "rint(-snan)", bits_f64(rint(as_f64(0xfff4000000000000ul))), 0xfffc000000000000ul)
}


// Eden: the f64 floor / ceil / trunc of m3_math_utils over the `math`
// module: a signalling NaN comes back quieted (payload and sign kept) as
// glibc returns it, the other values as libm
def test_f64_rounding_nan(var t : TestRun; fx : FixtureSource) { // nolint:STYLE038
    expect_u64(t, "floor64(snan)", bits_f64(floor64(as_f64(0x7ff4000000000000ul))), 0x7ffc000000000000ul)
    expect_u64(t, "floor64(-snan)", bits_f64(floor64(as_f64(0xfff4000000000000ul))), 0xfffc000000000000ul)
    expect_u64(t, "ceil64(snan)", bits_f64(ceil64(as_f64(0x7ff4000000000000ul))), 0x7ffc000000000000ul)
    expect_u64(t, "trunc64(-snan)", bits_f64(trunc64(as_f64(0xfff4000000000000ul))), 0xfffc000000000000ul)
    expect_u64(t, "floor64(qnan)", bits_f64(floor64(as_f64(0x7ff8000000000000ul))), 0x7ff8000000000000ul)
    expect_u64(t, "floor64(-1.5)", bits_f64(floor64(as_f64(0xbff8000000000000ul))), 0xc000000000000000ul)
    expect_u64(t, "ceil64(-0.5)", bits_f64(ceil64(as_f64(0xbfe0000000000000ul))), 0x8000000000000000ul)
    expect_u64(t, "trunc64(2.75)", bits_f64(trunc64(as_f64(0x4006000000000000ul))), 0x4000000000000000ul)
}


/*
    ------------------------------------------------------------
    Conversions, min/max, div/rem, bit counts (Eden only)
    ------------------------------------------------------------

    No upstream counterpart. The OP_* helpers, min/max and the builtin_*
    wrappers are only exercised upstream through m3_exec; here they are
    checked directly at the range constants of C m3_math_utils.h so the
    sandbox build of the generic functions is verified before m3_exec
    lands: the NaN trap, both overflow edges, the largest in-range values,
    the saturating results at NaN / -inf / +inf, the wasm min/max rules
    for NaN and signed zero, INT_MIN / -1 and division by zero.
*/


def private check_trunc_i32_f32(var t : TestRun) {
    var r : i32 = 7
    is_err(t, OP_I32_TRUNC_F32(r, as_f32(0x7fc00000u)), m3Err_trapIntegerConversion, "i32.trunc_f32 nan traps conversion")
    is_err(t, OP_I32_TRUNC_F32(r, as_f32(0x7f800000u)), m3Err_trapIntegerOverflow, "i32.trunc_f32 +inf traps overflow")
    is_err(t, OP_I32_TRUNC_F32(r, as_f32(0xff800000u)), m3Err_trapIntegerOverflow, "i32.trunc_f32 -inf traps overflow")
    is_err(t, OP_I32_TRUNC_F32(r, 2147483648.0f), m3Err_trapIntegerOverflow, "i32.trunc_f32 2^31 traps overflow")
    is_err(t, OP_I32_TRUNC_F32(r, -2147483904.0f), m3Err_trapIntegerOverflow, "i32.trunc_f32 RMIN traps overflow")
    equal(t, r, 7, "i32.trunc_f32 RES untouched by a trap")

    is_ok(t, OP_I32_TRUNC_F32(r, 2147483520.0f), "i32.trunc_f32 largest in-range float")
    equal(t, r, 2147483520, "i32.trunc_f32 largest in-range value")
    is_ok(t, OP_I32_TRUNC_F32(r, -2147483648.0f), "i32.trunc_f32 -2^31 is in range")
    equal(t, r, -2147483647 - 1, "i32.trunc_f32 -2^31 value")
    is_ok(t, OP_I32_TRUNC_F32(r, -1.5f), "i32.trunc_f32 -1.5")
    equal(t, r, -1, "i32.trunc_f32 -1.5 truncates toward zero")
    is_ok(t, OP_I32_TRUNC_F32(r, as_f32(0x80000000u)), "i32.trunc_f32 -0.0")
    equal(t, r, 0, "i32.trunc_f32 -0.0 is 0")
}


def private check_trunc_u32(var t : TestRun) {
    var r : u32 = 7u
    is_err(t, OP_U32_TRUNC_F32(r, -1.0f), m3Err_trapIntegerOverflow, "u32.trunc_f32 -1.0 traps overflow")
    is_err(t, OP_U32_TRUNC_F32(r, 4294967296.0f), m3Err_trapIntegerOverflow, "u32.trunc_f32 2^32 traps overflow")
    is_ok(t, OP_U32_TRUNC_F32(r, -0.5f), "u32.trunc_f32 -0.5 is in range")
    equal(t, r, 0u, "u32.trunc_f32 -0.5 is 0")
    is_ok(t, OP_U32_TRUNC_F32(r, 4294967040.0f), "u32.trunc_f32 largest in-range float")
    equal(t, r, 4294967040u, "u32.trunc_f32 largest in-range value")

    is_err(t, OP_U32_TRUNC_F64(r, as_f64(0x7ff8000000000000ul)), m3Err_trapIntegerConversion, "u32.trunc_f64 nan traps conversion")
    is_err(t, OP_U32_TRUNC_F64(r, -1.0lf), m3Err_trapIntegerOverflow, "u32.trunc_f64 -1.0 traps overflow")
    is_err(t, OP_U32_TRUNC_F64(r, 4294967296.0lf), m3Err_trapIntegerOverflow, "u32.trunc_f64 2^32 traps overflow")
    is_ok(t, OP_U32_TRUNC_F64(r, 4294967295.9lf), "u32.trunc_f64 just below 2^32")
    equal(t, r, 0xFFFFFFFFu, "u32.trunc_f64 just below 2^32 is UINT32_MAX")
    is_ok(t, OP_U32_TRUNC_F64(r, -0.9lf), "u32.trunc_f64 -0.9 is in range")
    equal(t, r, 0u, "u32.trunc_f64 -0.9 is 0")
}


def private check_trunc_i64_f64(var t : TestRun) {
    var r : i64 = 7l
    is_err(t, OP_I64_TRUNC_F64(r, as_f64(0xfff8000000000000ul)), m3Err_trapIntegerConversion, "i64.trunc_f64 -nan traps conversion")
    is_err(t, OP_I64_TRUNC_F64(r, 9223372036854775808.0lf), m3Err_trapIntegerOverflow, "i64.trunc_f64 2^63 traps overflow")
    is_err(t, OP_I64_TRUNC_F64(r, -9223372036854777856.0lf), m3Err_trapIntegerOverflow, "i64.trunc_f64 RMIN traps overflow")
    is_ok(t, OP_I64_TRUNC_F64(r, -9223372036854775808.0lf), "i64.trunc_f64 -2^63 is in range")
    equal(t, r, -9223372036854775807l - 1l, "i64.trunc_f64 -2^63 value")
    is_ok(t, OP_I64_TRUNC_F64(r, 9223372036854774784.0lf), "i64.trunc_f64 largest in-range double")
    equal(t, r, 9223372036854774784l, "i64.trunc_f64 largest in-range value")

    var i32r : i32 = 0
    is_err(t, OP_I32_TRUNC_F64(i32r, -2147483649.0lf), m3Err_trapIntegerOverflow, "i32.trunc_f64 RMIN traps overflow")
    is_ok(t, OP_I32_TRUNC_F64(i32r, -2147483648.9lf), "i32.trunc_f64 just above RMIN")
    equal(t, i32r, -2147483647 - 1, "i32.trunc_f64 just above RMIN truncates to INT32_MIN")
    is_ok(t, OP_I32_TRUNC_F64(i32r, 2147483647.9lf), "i32.trunc_f64 just below 2^31")
    equal(t, i32r, 2147483647, "i32.trunc_f64 just below 2^31 is INT32_MAX")
}


def private check_trunc_64_f32_and_u64(var t : TestRun) {
    var r : i64 = 0l
    is_err(t, OP_I64_TRUNC_F32(r, 9223372036854775808.0f), m3Err_trapIntegerOverflow, "i64.trunc_f32 2^63 traps overflow")
    is_err(t, OP_I64_TRUNC_F32(r, -9223373136366403584.0f), m3Err_trapIntegerOverflow, "i64.trunc_f32 RMIN traps overflow")
    is_ok(t, OP_I64_TRUNC_F32(r, -9223372036854775808.0f), "i64.trunc_f32 -2^63 is in range")
    equal(t, r, -9223372036854775807l - 1l, "i64.trunc_f32 -2^63 value")
    is_ok(t, OP_I64_TRUNC_F32(r, 9223371487098961920.0f), "i64.trunc_f32 largest in-range float")
    equal(t, r, 9223371487098961920l, "i64.trunc_f32 largest in-range value")

    var u : u64 = 0ul
    is_err(t, OP_U64_TRUNC_F32(u, -1.0f), m3Err_trapIntegerOverflow, "u64.trunc_f32 -1.0 traps overflow")
    is_err(t, OP_U64_TRUNC_F32(u, 18446744073709551616.0f), m3Err_trapIntegerOverflow, "u64.trunc_f32 2^64 traps overflow")
    is_ok(t, OP_U64_TRUNC_F32(u, 18446742974197923840.0f), "u64.trunc_f32 largest in-range float")
    equal(t, u, 18446742974197923840ul, "u64.trunc_f32 largest in-range value")

    is_err(t, OP_U64_TRUNC_F64(u, as_f64(0x7ff8000000000000ul)), m3Err_trapIntegerConversion, "u64.trunc_f64 nan traps conversion")
    is_err(t, OP_U64_TRUNC_F64(u, 18446744073709551616.0lf), m3Err_trapIntegerOverflow, "u64.trunc_f64 2^64 traps overflow")
    is_ok(t, OP_U64_TRUNC_F64(u, 18446744073709549568.0lf), "u64.trunc_f64 largest in-range double")
    equal(t, u, 18446744073709549568ul, "u64.trunc_f64 largest in-range value")
    is_ok(t, OP_U64_TRUNC_F64(u, -0.9lf), "u64.trunc_f64 -0.9 is in range")
    equal(t, u, 0ul, "u64.trunc_f64 -0.9 is 0")
}


def private check_trunc_sat(var t : TestRun) {
    var i : i32 = 7
    OP_I32_TRUNC_SAT_F32(i, as_f32(0x7fc00000u))
    equal(t, i, 0, "i32.trunc_sat_f32 nan is 0")
    OP_I32_TRUNC_SAT_F32(i, as_f32(0xff800000u))
    equal(t, i, -2147483647 - 1, "i32.trunc_sat_f32 -inf is INT32_MIN")
    OP_I32_TRUNC_SAT_F32(i, as_f32(0x7f800000u))
    equal(t, i, 2147483647, "i32.trunc_sat_f32 +inf is INT32_MAX")
    OP_I32_TRUNC_SAT_F32(i, 2147483648.0f)
    equal(t, i, 2147483647, "i32.trunc_sat_f32 2^31 saturates")
    OP_I32_TRUNC_SAT_F32(i, -2147483904.0f)
    equal(t, i, -2147483647 - 1, "i32.trunc_sat_f32 RMIN saturates")
    OP_I32_TRUNC_SAT_F32(i, -2147483648.0f)
    equal(t, i, -2147483647 - 1, "i32.trunc_sat_f32 -2^31 converts")
    OP_I32_TRUNC_SAT_F32(i, 1.9f)
    equal(t, i, 1, "i32.trunc_sat_f32 1.9 truncates")

    var u : u32 = 7u
    OP_U32_TRUNC_SAT_F32(u, as_f32(0xffc00000u))
    equal(t, u, 0u, "u32.trunc_sat_f32 -nan is 0")
    OP_U32_TRUNC_SAT_F32(u, -1.0f)
    equal(t, u, 0u, "u32.trunc_sat_f32 -1.0 saturates to 0")
    OP_U32_TRUNC_SAT_F32(u, 4294967296.0f)
    equal(t, u, 0xFFFFFFFFu, "u32.trunc_sat_f32 2^32 saturates to UINT32_MAX")
    OP_U32_TRUNC_SAT_F64(u, -0.5lf)
    equal(t, u, 0u, "u32.trunc_sat_f64 -0.5 is 0")
    OP_U32_TRUNC_SAT_F64(u, 4294967295.0lf)
    equal(t, u, 0xFFFFFFFFu, "u32.trunc_sat_f64 2^32-1 converts")
    OP_I32_TRUNC_SAT_F64(i, -2147483649.0lf)
    equal(t, i, -2147483647 - 1, "i32.trunc_sat_f64 RMIN saturates")
    OP_I32_TRUNC_SAT_F64(i, 2147483648.0lf)
    equal(t, i, 2147483647, "i32.trunc_sat_f64 2^31 saturates")

    var l : i64 = 7l
    OP_I64_TRUNC_SAT_F32(l, as_f32(0x7fc00000u))
    equal(t, l, 0l, "i64.trunc_sat_f32 nan is 0")
    OP_I64_TRUNC_SAT_F32(l, -9223373136366403584.0f)
    equal(t, l, -9223372036854775807l - 1l, "i64.trunc_sat_f32 RMIN saturates")
    OP_I64_TRUNC_SAT_F32(l, 9223372036854775808.0f)
    equal(t, l, 9223372036854775807l, "i64.trunc_sat_f32 2^63 saturates")
    OP_I64_TRUNC_SAT_F64(l, as_f64(0xfff0000000000000ul))
    equal(t, l, -9223372036854775807l - 1l, "i64.trunc_sat_f64 -inf saturates")
    OP_I64_TRUNC_SAT_F64(l, 9223372036854775808.0lf)
    equal(t, l, 9223372036854775807l, "i64.trunc_sat_f64 2^63 saturates")
    OP_I64_TRUNC_SAT_F64(l, -3.7lf)
    equal(t, l, -3l, "i64.trunc_sat_f64 -3.7 truncates")

    var ul : u64 = 7ul
    OP_U64_TRUNC_SAT_F32(ul, as_f32(0x7fc00000u))
    equal(t, ul, 0ul, "u64.trunc_sat_f32 nan is 0")
    OP_U64_TRUNC_SAT_F32(ul, -1.0f)
    equal(t, ul, 0ul, "u64.trunc_sat_f32 -1.0 saturates to 0")
    OP_U64_TRUNC_SAT_F32(ul, 18446744073709551616.0f)
    equal(t, ul, 0xFFFFFFFFFFFFFFFFul, "u64.trunc_sat_f32 2^64 saturates to UINT64_MAX")
    OP_U64_TRUNC_SAT_F64(ul, 18446744073709551616.0lf)
    equal(t, ul, 0xFFFFFFFFFFFFFFFFul, "u64.trunc_sat_f64 2^64 saturates to UINT64_MAX")
    OP_U64_TRUNC_SAT_F64(ul, 18446744073709549568.0lf)
    equal(t, ul, 18446744073709549568ul, "u64.trunc_sat_f64 largest in-range double converts")
}


def private check_min_max(var t : TestRun) {
    let negZero = as_f32(0x80000000u)
    let posZero = as_f32(0x00000000u)
    let nan = as_f32(0x7fc00000u)
    let negNanPayload = as_f32(0xffc12345u)

    expect_u32(t, "min_f32(-0, +0) is -0", bits_f32(min_f32(negZero, posZero)), 0x80000000u)
    expect_u32(t, "min_f32(+0, -0) is -0", bits_f32(min_f32(posZero, negZero)), 0x80000000u)
    expect_u32(t, "max_f32(-0, +0) is +0", bits_f32(max_f32(negZero, posZero)), 0x00000000u)
    expect_u32(t, "max_f32(+0, -0) is +0", bits_f32(max_f32(posZero, negZero)), 0x00000000u)
    check(t, isnan(min_f32(nan, 1.0f)), "min_f32(nan, 1) is nan")
    check(t, isnan(min_f32(1.0f, nan)), "min_f32(1, nan) is nan")
    check(t, isnan(max_f32(negNanPayload, -1.0f)), "max_f32(-nan payload, -1) is nan")
    check(t, isnan(max_f32(1.0f, nan)), "max_f32(1, nan) is nan")
    equal(t, min_f32(-1.5f, 2.0f), -1.5f, "min_f32(-1.5, 2) is -1.5")
    equal(t, max_f32(-1.5f, 2.0f), 2.0f, "max_f32(-1.5, 2) is 2")
    expect_u32(t, "min_f32(-inf, inf) is -inf", bits_f32(min_f32(as_f32(0xff800000u), as_f32(0x7f800000u))), 0xff800000u)
    expect_u32(t, "max_f32(-inf, inf) is +inf", bits_f32(max_f32(as_f32(0xff800000u), as_f32(0x7f800000u))), 0x7f800000u)

    let negZero64 = as_f64(0x8000000000000000ul)
    let posZero64 = as_f64(0x0000000000000000ul)
    let nan64 = as_f64(0x7ff8000000000000ul)

    expect_u64(t, "min_f64(-0, +0) is -0", bits_f64(min_f64(negZero64, posZero64)), 0x8000000000000000ul)
    expect_u64(t, "min_f64(+0, -0) is -0", bits_f64(min_f64(posZero64, negZero64)), 0x8000000000000000ul)
    expect_u64(t, "max_f64(-0, +0) is +0", bits_f64(max_f64(negZero64, posZero64)), 0x0000000000000000ul)
    expect_u64(t, "max_f64(+0, -0) is +0", bits_f64(max_f64(posZero64, negZero64)), 0x0000000000000000ul)
    check(t, isnan(min_f64(nan64, 1.0lf)), "min_f64(nan, 1) is nan")
    check(t, isnan(max_f64(1.0lf, nan64)), "max_f64(1, nan) is nan")
    equal(t, min_f64(-1.5lf, 2.0lf), -1.5lf, "min_f64(-1.5, 2) is -1.5")
    equal(t, max_f64(-1.5lf, 2.0lf), 2.0lf, "max_f64(-1.5, 2) is 2")

    // signbit / isnan on the special patterns
    check(t, signbit(negZero), "signbit(-0.0f)")
    check(t, !signbit(posZero), "!signbit(+0.0f)")
    check(t, signbit(negNanPayload), "signbit(-nan) reads the sign of a NaN")
    check(t, signbit(negZero64), "signbit(-0.0)")
    check(t, !signbit(1.0lf), "!signbit(1.0)")
    check(t, isnan(negNanPayload), "isnan(-nan with payload)")
    check(t, !isnan(as_f32(0x7f800000u)), "!isnan(+inf)")
    check(t, isnan(as_f64(0xfff0000000000001ul)), "isnan(signalling nan, f64)")
    check(t, !isnan(as_f64(0xfff0000000000000ul)), "!isnan(-inf, f64)")
}


def private check_div_rem(var t : TestRun) {
    var r : i32 = 7
    is_err(t, OP_DIV_S(r, 1, 0, -2147483647 - 1), m3Err_trapDivisionByZero, "i32.div_s by zero traps")
    is_err(t, OP_DIV_S(r, -2147483647 - 1, -1, -2147483647 - 1), m3Err_trapIntegerOverflow, "i32.div_s INT_MIN / -1 traps overflow")
    equal(t, r, 7, "i32.div_s RES untouched by a trap")
    is_ok(t, OP_DIV_S(r, -7, 2, -2147483647 - 1), "i32.div_s -7 / 2")
    equal(t, r, -3, "i32.div_s -7 / 2 truncates toward zero")
    is_err(t, OP_REM_S(r, 1, 0, -2147483647 - 1), m3Err_trapDivisionByZero, "i32.rem_s by zero traps")
    is_ok(t, OP_REM_S(r, -2147483647 - 1, -1, -2147483647 - 1), "i32.rem_s INT_MIN % -1 does not trap")
    equal(t, r, 0, "i32.rem_s INT_MIN % -1 is 0")
    is_ok(t, OP_REM_S(r, -7, 2, -2147483647 - 1), "i32.rem_s -7 % 2")
    equal(t, r, -1, "i32.rem_s -7 % 2 keeps the sign of the dividend")

    var u : u32 = 7u
    is_err(t, OP_DIV_U(u, 1u, 0u), m3Err_trapDivisionByZero, "i32.div_u by zero traps")
    is_ok(t, OP_DIV_U(u, 0xFFFFFFFFu, 2u), "i32.div_u UINT32_MAX / 2")
    equal(t, u, 0x7FFFFFFFu, "i32.div_u UINT32_MAX / 2 is unsigned")
    is_err(t, OP_REM_U(u, 1u, 0u), m3Err_trapDivisionByZero, "i32.rem_u by zero traps")
    is_ok(t, OP_REM_U(u, 0xFFFFFFFFu, 10u), "i32.rem_u UINT32_MAX % 10")
    equal(t, u, 5u, "i32.rem_u UINT32_MAX % 10 is 5")

    var l : i64 = 0l
    is_err(t, OP_DIV_S(l, -9223372036854775807l - 1l, -1l, -9223372036854775807l - 1l), m3Err_trapIntegerOverflow, "i64.div_s INT64_MIN / -1 traps overflow")
    is_ok(t, OP_REM_S(l, -9223372036854775807l - 1l, -1l, -9223372036854775807l - 1l), "i64.rem_s INT64_MIN % -1 does not trap")
    equal(t, l, 0l, "i64.rem_s INT64_MIN % -1 is 0")

    var ul : u64 = 0ul
    is_ok(t, OP_DIV_U(ul, 0xFFFFFFFFFFFFFFFFul, 2ul), "i64.div_u UINT64_MAX / 2")
    equal(t, ul, 0x7FFFFFFFFFFFFFFFul, "i64.div_u UINT64_MAX / 2 is unsigned")
}


def private check_bit_counts(var t : TestRun) {
    equal(t, builtin_popcount(0u), 0, "popcount(0)")
    equal(t, builtin_popcount(0xFFFFFFFFu), 32, "popcount(all 32)")
    equal(t, builtin_popcount(0x12345678u), 13, "popcount(0x12345678)")
    equal(t, builtin_ctz(1u), 0, "ctz(1)")
    equal(t, builtin_ctz(0x80000000u), 31, "ctz(msb)")
    equal(t, builtin_clz(1u), 31, "clz(1)")
    equal(t, builtin_clz(0x80000000u), 0, "clz(msb)")
    equal(t, builtin_popcountll(0ul), 0, "popcountll(0)")
    equal(t, builtin_popcountll(0xFFFFFFFFFFFFFFFFul), 64, "popcountll(all 64)")
    equal(t, builtin_ctzll(0x8000000000000000ul), 63, "ctzll(msb)")
    equal(t, builtin_ctzll(0x0000000100000000ul), 32, "ctzll(bit 32)")
    equal(t, builtin_clzll(1ul), 63, "clzll(1)")
    equal(t, builtin_clzll(0x0000000100000000ul), 31, "clzll(bit 32)")
    equal(t, M3_MAX(-3, 5), 5, "M3_MAX")
    equal(t, M3_MIN(-3, 5), -3, "M3_MIN")
}


def test_conversions_and_minmax(var t : TestRun; fx : FixtureSource) {
    check_trunc_i32_f32(t)
    check_trunc_u32(t)
    check_trunc_i64_f64(t)
    check_trunc_64_f32_and_u64(t)
    check_trunc_sat(t)
    check_min_max(t)
    check_div_rem(t)
    check_bit_counts(t)
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_math_utils(var t : TestRun; fx : FixtureSource) {

    /*
        Сначала explicit constants:
        если implementation и reference одновременно имеют одинаковую
        логическую ошибку, эти тесты всё равно её поймают.
    */

    begin_test(t, "test_expected_32")
    test_expected_32(t, fx)
    begin_test(t, "test_expected_64")
    test_expected_64(t, fx)

    /*
        Затем полная матрица.
    */

    begin_test(t, "test_rotations_32")
    test_rotations_32(t, fx)
    begin_test(t, "test_rotations_64")
    test_rotations_64(t, fx)

    /*
        Дополнительная связь между left/right rotations.
    */

    begin_test(t, "test_cross_properties_32")
    test_cross_properties_32(t, fx)
    begin_test(t, "test_cross_properties_64")
    test_cross_properties_64(t, fx)

    /*
        Наконец libm-функции из d_m3UnaryOp_f.
    */

    begin_test(t, "test_fabs")
    test_fabs(t, fx)
    begin_test(t, "test_floorf")
    test_floorf(t, fx)
    begin_test(t, "test_ceilf")
    test_ceilf(t, fx)
    begin_test(t, "test_rintf")
    test_rintf(t, fx)
    begin_test(t, "test_rint")
    test_rint(t, fx)
    begin_test(t, "test_f64_rounding_nan")
    test_f64_rounding_nan(t, fx)

    /*
        Eden only: the helpers m3_exec will call.
    */

    begin_test(t, "test_conversions_and_minmax")
    test_conversions_and_minmax(t, fx)
}
