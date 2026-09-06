options gen2
options indenting = 4

require dastest/testing_boost
require ../source/m3_math_utils.das


/*
    test_m3_math_utils.das

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

    При первом несовпадении вызывается panic.
*/


/*
    Assertions
*/

def expect_u32(
               name : string;
               actual : u32;
               expected : u32
               ) {
    if (actual != expected) {
        panic(
            "{name}: expected {expected}, got {actual}"
        )
    }
}


def expect_u64(
               name : string;
               actual : u64;
               expected : u64
               ) {
    if (actual != expected) {
        panic(
            "{name}: expected {expected}, got {actual}"
        )
    }
}


/*
    Независимые reference implementations.

    Намеренно НЕ повторяют формулу:

        (n << c) | (n >> (...))

    Вместо этого делают rotation по одному биту.
*/


def reference_rotl32(n : u32; c : uint) : u32 {
    var result = n

    let count = int(c & 31u)

    for (_i in range(count)) {
        let carry = (result >> 31u) & 1u

        result <<= 1u
        result |= carry
    }

    return result
}


def reference_rotr32(n : u32; c : uint) : u32 {
    var result = n

    let count = int(c & 31u)

    for (_i in range(count)) {
        let carry = result & 1u

        result >>= 1u
        result |= carry << 31u
    }

    return result
}


def reference_rotl64(n : u64; c : uint) : u64 {
    var result = n

    let count = int(c & 63u)

    for (_i in range(count)) {
        let carry = (result >> 63ul) & 1ul

        result <<= 1ul
        result |= carry
    }

    return result
}


def reference_rotr64(n : u64; c : uint) : u64 {
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


[test]
def test_expected_32() { // nolint:STYLE038

    /*
        zero
    */

    expect_u32(
        "rotl32 zero c=7",
        rotl32(0u, 7u),
        0u
    )

    expect_u32(
        "rotr32 zero c=7",
        rotr32(0u, 7u),
        0u
    )


    /*
        single low bit
    */

    expect_u32(
        "rotl32 bit0 c=1",
        rotl32(0x00000001u, 1u),
        0x00000002u
    )

    expect_u32(
        "rotr32 bit0 c=1",
        rotr32(0x00000001u, 1u),
        0x80000000u
    )

    expect_u32(
        "rotl32 bit0 c=7",
        rotl32(0x00000001u, 7u),
        0x00000080u
    )

    expect_u32(
        "rotr32 bit0 c=7",
        rotr32(0x00000001u, 7u),
        0x02000000u
    )


    /*
        highest bit
    */

    expect_u32(
        "rotl32 msb c=1",
        rotl32(0x80000000u, 1u),
        0x00000001u
    )

    expect_u32(
        "rotr32 msb c=1",
        rotr32(0x80000000u, 1u),
        0x40000000u
    )

    expect_u32(
        "rotl32 msb c=7",
        rotl32(0x80000000u, 7u),
        0x00000040u
    )

    expect_u32(
        "rotr32 msb c=7",
        rotr32(0x80000000u, 7u),
        0x01000000u
    )


    /*
        all bits
    */

    expect_u32(
        "rotl32 all c=7",
        rotl32(0xFFFFFFFFu, 7u),
        0xFFFFFFFFu
    )

    expect_u32(
        "rotr32 all c=7",
        rotr32(0xFFFFFFFFu, 7u),
        0xFFFFFFFFu
    )


    /*
        alternating 1010...
    */

    expect_u32(
        "rotl32 AAAAAAAA c=1",
        rotl32(0xAAAAAAAAu, 1u),
        0x55555555u
    )

    expect_u32(
        "rotr32 AAAAAAAA c=1",
        rotr32(0xAAAAAAAAu, 1u),
        0x55555555u
    )


    /*
        alternating 0101...
    */

    expect_u32(
        "rotl32 55555555 c=1",
        rotl32(0x55555555u, 1u),
        0xAAAAAAAAu
    )

    expect_u32(
        "rotr32 55555555 c=1",
        rotr32(0x55555555u, 1u),
        0xAAAAAAAAu
    )


    /*
        arbitrary asymmetric pattern
    */

    expect_u32(
        "rotl32 12345678 c=1",
        rotl32(0x12345678u, 1u),
        0x2468ACF0u
    )

    expect_u32(
        "rotr32 12345678 c=1",
        rotr32(0x12345678u, 1u),
        0x091A2B3Cu
    )

    expect_u32(
        "rotl32 12345678 c=7",
        rotl32(0x12345678u, 7u),
        0x1A2B3C09u
    )

    expect_u32(
        "rotr32 12345678 c=7",
        rotr32(0x12345678u, 7u),
        0xF02468ACu
    )

    expect_u32(
        "rotl32 12345678 c=15",
        rotl32(0x12345678u, 15u),
        0x2B3C091Au
    )

    expect_u32(
        "rotr32 12345678 c=15",
        rotr32(0x12345678u, 15u),
        0xACF02468u
    )

    expect_u32(
        "rotl32 12345678 c=16",
        rotl32(0x12345678u, 16u),
        0x56781234u
    )

    expect_u32(
        "rotr32 12345678 c=16",
        rotr32(0x12345678u, 16u),
        0x56781234u
    )

    expect_u32(
        "rotl32 12345678 c=31",
        rotl32(0x12345678u, 31u),
        0x091A2B3Cu
    )

    expect_u32(
        "rotr32 12345678 c=31",
        rotr32(0x12345678u, 31u),
        0x2468ACF0u
    )

    /*
        255 % 32 == 31
    */

    expect_u32(
        "rotl32 12345678 c=255",
        rotl32(0x12345678u, 255u),
        0x091A2B3Cu
    )

    expect_u32(
        "rotr32 12345678 c=255",
        rotr32(0x12345678u, 255u),
        0x2468ACF0u
    )
}


[test]
def test_expected_64() { // nolint:STYLE038

    /*
        zero
    */

    expect_u64(
        "rotl64 zero c=7",
        rotl64(0ul, 7u),
        0ul
    )

    expect_u64(
        "rotr64 zero c=7",
        rotr64(0ul, 7u),
        0ul
    )


    /*
        single low bit
    */

    expect_u64(
        "rotl64 bit0 c=1",
        rotl64(0x0000000000000001ul, 1u),
        0x0000000000000002ul
    )

    expect_u64(
        "rotr64 bit0 c=1",
        rotr64(0x0000000000000001ul, 1u),
        0x8000000000000000ul
    )

    expect_u64(
        "rotl64 bit0 c=7",
        rotl64(0x0000000000000001ul, 7u),
        0x0000000000000080ul
    )

    expect_u64(
        "rotr64 bit0 c=7",
        rotr64(0x0000000000000001ul, 7u),
        0x0200000000000000ul
    )


    /*
        highest bit
    */

    expect_u64(
        "rotl64 msb c=1",
        rotl64(0x8000000000000000ul, 1u),
        0x0000000000000001ul
    )

    expect_u64(
        "rotr64 msb c=1",
        rotr64(0x8000000000000000ul, 1u),
        0x4000000000000000ul
    )

    expect_u64(
        "rotl64 msb c=7",
        rotl64(0x8000000000000000ul, 7u),
        0x0000000000000040ul
    )

    expect_u64(
        "rotr64 msb c=7",
        rotr64(0x8000000000000000ul, 7u),
        0x0100000000000000ul
    )


    /*
        all bits
    */

    expect_u64(
        "rotl64 all c=7",
        rotl64(0xFFFFFFFFFFFFFFFFul, 7u),
        0xFFFFFFFFFFFFFFFFul
    )

    expect_u64(
        "rotr64 all c=7",
        rotr64(0xFFFFFFFFFFFFFFFFul, 7u),
        0xFFFFFFFFFFFFFFFFul
    )


    /*
        alternating 1010...
    */

    expect_u64(
        "rotl64 AAAAAAAAAAAAAAAA c=1",
        rotl64(0xAAAAAAAAAAAAAAAAul, 1u),
        0x5555555555555555ul
    )

    expect_u64(
        "rotr64 AAAAAAAAAAAAAAAA c=1",
        rotr64(0xAAAAAAAAAAAAAAAAul, 1u),
        0x5555555555555555ul
    )


    /*
        alternating 0101...
    */

    expect_u64(
        "rotl64 5555555555555555 c=1",
        rotl64(0x5555555555555555ul, 1u),
        0xAAAAAAAAAAAAAAAAul
    )

    expect_u64(
        "rotr64 5555555555555555 c=1",
        rotr64(0x5555555555555555ul, 1u),
        0xAAAAAAAAAAAAAAAAul
    )


    /*
        arbitrary asymmetric pattern
    */

    expect_u64(
        "rotl64 0123456789ABCDEF c=1",
        rotl64(0x0123456789ABCDEFul, 1u),
        0x02468ACF13579BDEul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=1",
        rotr64(0x0123456789ABCDEFul, 1u),
        0x8091A2B3C4D5E6F7ul
    )

    expect_u64(
        "rotl64 0123456789ABCDEF c=7",
        rotl64(0x0123456789ABCDEFul, 7u),
        0x91A2B3C4D5E6F780ul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=7",
        rotr64(0x0123456789ABCDEFul, 7u),
        0xDE02468ACF13579Bul
    )

    expect_u64(
        "rotl64 0123456789ABCDEF c=31",
        rotl64(0x0123456789ABCDEFul, 31u),
        0xC4D5E6F78091A2B3ul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=31",
        rotr64(0x0123456789ABCDEFul, 31u),
        0x13579BDE02468ACFul
    )

    expect_u64(
        "rotl64 0123456789ABCDEF c=32",
        rotl64(0x0123456789ABCDEFul, 32u),
        0x89ABCDEF01234567ul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=32",
        rotr64(0x0123456789ABCDEFul, 32u),
        0x89ABCDEF01234567ul
    )

    expect_u64(
        "rotl64 0123456789ABCDEF c=33",
        rotl64(0x0123456789ABCDEFul, 33u),
        0x13579BDE02468ACFul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=33",
        rotr64(0x0123456789ABCDEFul, 33u),
        0xC4D5E6F78091A2B3ul
    )

    expect_u64(
        "rotl64 0123456789ABCDEF c=63",
        rotl64(0x0123456789ABCDEFul, 63u),
        0x8091A2B3C4D5E6F7ul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=63",
        rotr64(0x0123456789ABCDEFul, 63u),
        0x02468ACF13579BDEul
    )

    /*
        255 % 64 == 63
    */

    expect_u64(
        "rotl64 0123456789ABCDEF c=255",
        rotl64(0x0123456789ABCDEFul, 255u),
        0x8091A2B3C4D5E6F7ul
    )

    expect_u64(
        "rotr64 0123456789ABCDEF c=255",
        rotr64(0x0123456789ABCDEFul, 255u),
        0x02468ACF13579BDEul
    )
}


/*
    ------------------------------------------------------------
    Full 32-bit test matrix
    ------------------------------------------------------------
*/


[test]
def test_rotations_32() { // nolint:STYLE038

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

        expect_u32(
            "rotl32 identity c=0 value={value}",
            rotl32(value, 0u),
            value
        )

        expect_u32(
            "rotr32 identity c=0 value={value}",
            rotr32(value, 0u),
            value
        )


        for (c in counts) {

            let left = rotl32(value, c)
            let right = rotr32(value, c)

            /*
                Compare against independent reference.
            */

            expect_u32(
                "rotl32 reference value={value} c={c}",
                left,
                reference_rotl32(value, c)
            )

            expect_u32(
                "rotr32 reference value={value} c={c}",
                right,
                reference_rotr32(value, c)
            )


            /*
                rotl -> rotr must restore original.
            */

            expect_u32(
                "rotl32->rotr32 value={value} c={c}",
                rotr32(left, c),
                value
            )


            /*
                rotr -> rotl must restore original.
            */

            expect_u32(
                "rotr32->rotl32 value={value} c={c}",
                rotl32(right, c),
                value
            )


            /*
                Counter is periodic modulo 32.
            */

            expect_u32(
                "rotl32 periodic +32 value={value} c={c}",
                rotl32(value, c + 32u),
                left
            )

            expect_u32(
                "rotr32 periodic +32 value={value} c={c}",
                rotr32(value, c + 32u),
                right
            )


            /*
                Also explicitly compare against c & 31.
            */

            expect_u32(
                "rotl32 modulo-32 value={value} c={c}",
                left,
                rotl32(value, c & 31u)
            )

            expect_u32(
                "rotr32 modulo-32 value={value} c={c}",
                right,
                rotr32(value, c & 31u)
            )
        }
    }


    /*
        All bits set must be invariant for every requested counter.
    */

    for (c in counts) {
        expect_u32(
            "rotl32 all-bits invariant c={c}",
            rotl32(0xFFFFFFFFu, c),
            0xFFFFFFFFu
        )

        expect_u32(
            "rotr32 all-bits invariant c={c}",
            rotr32(0xFFFFFFFFu, c),
            0xFFFFFFFFu
        )
    }
}


/*
    ------------------------------------------------------------
    Full 64-bit test matrix
    ------------------------------------------------------------
*/


[test]
def test_rotations_64() { // nolint:STYLE038

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

        expect_u64(
            "rotl64 identity c=0 value={value}",
            rotl64(value, 0u),
            value
        )

        expect_u64(
            "rotr64 identity c=0 value={value}",
            rotr64(value, 0u),
            value
        )


        for (c in counts) {

            let left = rotl64(value, c)
            let right = rotr64(value, c)


            /*
                Independent reference.
            */

            expect_u64(
                "rotl64 reference value={value} c={c}",
                left,
                reference_rotl64(value, c)
            )

            expect_u64(
                "rotr64 reference value={value} c={c}",
                right,
                reference_rotr64(value, c)
            )


            /*
                rotl -> rotr restores original.
            */

            expect_u64(
                "rotl64->rotr64 value={value} c={c}",
                rotr64(left, c),
                value
            )


            /*
                rotr -> rotl restores original.
            */

            expect_u64(
                "rotr64->rotl64 value={value} c={c}",
                rotl64(right, c),
                value
            )


            /*
                Counter is periodic modulo 64.
            */

            expect_u64(
                "rotl64 periodic +64 value={value} c={c}",
                rotl64(value, c + 64u),
                left
            )

            expect_u64(
                "rotr64 periodic +64 value={value} c={c}",
                rotr64(value, c + 64u),
                right
            )


            /*
                Explicit c & 63 check.
            */

            expect_u64(
                "rotl64 modulo-64 value={value} c={c}",
                left,
                rotl64(value, c & 63u)
            )

            expect_u64(
                "rotr64 modulo-64 value={value} c={c}",
                right,
                rotr64(value, c & 63u)
            )
        }
    }


    /*
        All bits set must be invariant for every requested counter.
    */

    for (c in counts) {
        expect_u64(
            "rotl64 all-bits invariant c={c}",
            rotl64(0xFFFFFFFFFFFFFFFFul, c),
            0xFFFFFFFFFFFFFFFFul
        )

        expect_u64(
            "rotr64 all-bits invariant c={c}",
            rotr64(0xFFFFFFFFFFFFFFFFul, c),
            0xFFFFFFFFFFFFFFFFul
        )
    }
}


/*
    ------------------------------------------------------------
    Cross-properties
    ------------------------------------------------------------
*/


[test]
def test_cross_properties_32() {
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

            expect_u32(
                "rotl32 == opposite rotr32 value={value} c={c}",
                rotl32(value, c),
                rotr32(value, opposite)
            )

            expect_u32(
                "rotr32 == opposite rotl32 value={value} c={c}",
                rotr32(value, c),
                rotl32(value, opposite)
            )
        }
    }
}


[test]
def test_cross_properties_64() {
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

            expect_u64(
                "rotl64 == opposite rotr64 value={value} c={c}",
                rotl64(value, c),
                rotr64(value, opposite)
            )

            expect_u64(
                "rotr64 == opposite rotl64 value={value} c={c}",
                rotr64(value, c),
                rotl64(value, opposite)
            )
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
    unsafe {
        return reinterpret<u32>(value)
    }
}


def private bits_f64(value : f64) : u64 {
    unsafe {
        return reinterpret<u64>(value)
    }
}


def private as_f32(bits : u32) : f32 {
    unsafe {
        return reinterpret<f32>(bits)
    }
}


def private as_f64(bits : u64) : f64 {
    unsafe {
        return reinterpret<f64>(bits)
    }
}


[test]
def test_fabs() { // nolint:STYLE038
    expect_u32("fabsf(-0.0)", bits_f32(fabsf(as_f32(0x80000000u))), 0x00000000u)
    expect_u32("fabsf(+0.0)", bits_f32(fabsf(as_f32(0x00000000u))), 0x00000000u)
    expect_u32("fabsf(-1.5)", bits_f32(fabsf(as_f32(0xbfc00000u))), 0x3fc00000u)
    expect_u32("fabsf(-inf)", bits_f32(fabsf(as_f32(0xff800000u))), 0x7f800000u)
    expect_u32("fabsf(-nan)", bits_f32(fabsf(as_f32(0xffc00000u))), 0x7fc00000u)

    expect_u64("fabs(-0.0)", bits_f64(fabs(as_f64(0x8000000000000000ul))), 0x0000000000000000ul)
    expect_u64("fabs(-1.5)", bits_f64(fabs(as_f64(0xbff8000000000000ul))), 0x3ff8000000000000ul)
    expect_u64("fabs(-inf)", bits_f64(fabs(as_f64(0xfff0000000000000ul))), 0x7ff0000000000000ul)
}


[test]
def test_floorf() { // nolint:STYLE038
    expect_u32("floorf(+0.0)", bits_f32(floorf(as_f32(0x00000000u))), 0x00000000u)
    expect_u32("floorf(-0.0)", bits_f32(floorf(as_f32(0x80000000u))), 0x80000000u)
    expect_u32("floorf(0.5)", bits_f32(floorf(as_f32(0x3f000000u))), 0x00000000u)
    expect_u32("floorf(1.5)", bits_f32(floorf(as_f32(0x3fc00000u))), 0x3f800000u)
    expect_u32("floorf(-0.5)", bits_f32(floorf(as_f32(0xbf000000u))), 0xbf800000u)
    expect_u32("floorf(-1.5)", bits_f32(floorf(as_f32(0xbfc00000u))), 0xc0000000u)
    expect_u32("floorf(2.0)", bits_f32(floorf(as_f32(0x40000000u))), 0x40000000u)
    expect_u32("floorf(FLT_MAX)", bits_f32(floorf(as_f32(0x7f7fffffu))), 0x7f7fffffu)
    expect_u32("floorf(-FLT_MAX)", bits_f32(floorf(as_f32(0xff7fffffu))), 0xff7fffffu)
    expect_u32("floorf(inf)", bits_f32(floorf(as_f32(0x7f800000u))), 0x7f800000u)
    expect_u32("floorf(-inf)", bits_f32(floorf(as_f32(0xff800000u))), 0xff800000u)
    expect_u32("floorf(nan)", bits_f32(floorf(as_f32(0x7fc00000u))), 0x7fc00000u)
}


[test]
def test_ceilf() { // nolint:STYLE038
    expect_u32("ceilf(+0.0)", bits_f32(ceilf(as_f32(0x00000000u))), 0x00000000u)
    expect_u32("ceilf(-0.0)", bits_f32(ceilf(as_f32(0x80000000u))), 0x80000000u)
    expect_u32("ceilf(0.5)", bits_f32(ceilf(as_f32(0x3f000000u))), 0x3f800000u)
    expect_u32("ceilf(1.5)", bits_f32(ceilf(as_f32(0x3fc00000u))), 0x40000000u)
    // -0.5 rounds up to negative zero, not to +0.0.
    expect_u32("ceilf(-0.5)", bits_f32(ceilf(as_f32(0xbf000000u))), 0x80000000u)
    expect_u32("ceilf(-1.5)", bits_f32(ceilf(as_f32(0xbfc00000u))), 0xbf800000u)
    expect_u32("ceilf(FLT_MAX)", bits_f32(ceilf(as_f32(0x7f7fffffu))), 0x7f7fffffu)
    expect_u32("ceilf(inf)", bits_f32(ceilf(as_f32(0x7f800000u))), 0x7f800000u)
    expect_u32("ceilf(-inf)", bits_f32(ceilf(as_f32(0xff800000u))), 0xff800000u)
    expect_u32("ceilf(nan)", bits_f32(ceilf(as_f32(0x7fc00000u))), 0x7fc00000u)
}


[test]
def test_rintf() { // nolint:STYLE038
    // Halves round to even, unlike math::round which rounds away from zero.
    expect_u32("rintf(0.5)", bits_f32(rintf(as_f32(0x3f000000u))), 0x00000000u)
    expect_u32("rintf(1.5)", bits_f32(rintf(as_f32(0x3fc00000u))), 0x40000000u)
    expect_u32("rintf(2.5)", bits_f32(rintf(as_f32(0x40200000u))), 0x40000000u)
    expect_u32("rintf(4.5)", bits_f32(rintf(as_f32(0x40900000u))), 0x40800000u)
    expect_u32("rintf(-0.5)", bits_f32(rintf(as_f32(0xbf000000u))), 0x80000000u)
    expect_u32("rintf(-1.5)", bits_f32(rintf(as_f32(0xbfc00000u))), 0xc0000000u)
    expect_u32("rintf(-2.5)", bits_f32(rintf(as_f32(0xc0200000u))), 0xc0000000u)
    // The smallest denormal rounds to a zero of its own sign.
    expect_u32("rintf(min denormal)", bits_f32(rintf(as_f32(0x00000001u))), 0x00000000u)
    expect_u32("rintf(-min denormal)", bits_f32(rintf(as_f32(0x80000001u))), 0x80000000u)
    expect_u32("rintf(-0.0)", bits_f32(rintf(as_f32(0x80000000u))), 0x80000000u)
    expect_u32("rintf(FLT_MAX)", bits_f32(rintf(as_f32(0x7f7fffffu))), 0x7f7fffffu)
    expect_u32("rintf(inf)", bits_f32(rintf(as_f32(0x7f800000u))), 0x7f800000u)
    expect_u32("rintf(nan)", bits_f32(rintf(as_f32(0x7fc00000u))), 0x7fc00000u)
}


[test]
def test_rint() { // nolint:STYLE038
    expect_u64("rint(0.5)", bits_f64(rint(as_f64(0x3fe0000000000000ul))), 0x0000000000000000ul)
    expect_u64("rint(1.5)", bits_f64(rint(as_f64(0x3ff8000000000000ul))), 0x4000000000000000ul)
    expect_u64("rint(2.5)", bits_f64(rint(as_f64(0x4004000000000000ul))), 0x4000000000000000ul)
    expect_u64("rint(-0.5)", bits_f64(rint(as_f64(0xbfe0000000000000ul))), 0x8000000000000000ul)
    expect_u64("rint(-1.5)", bits_f64(rint(as_f64(0xbff8000000000000ul))), 0xc000000000000000ul)
    expect_u64("rint(-2.5)", bits_f64(rint(as_f64(0xc004000000000000ul))), 0xc000000000000000ul)
    expect_u64("rint(min denormal)", bits_f64(rint(as_f64(0x0000000000000001ul))), 0x0000000000000000ul)
    expect_u64("rint(min normal)", bits_f64(rint(as_f64(0x0010000000000000ul))), 0x0000000000000000ul)
    expect_u64("rint(-0.0)", bits_f64(rint(as_f64(0x8000000000000000ul))), 0x8000000000000000ul)
    expect_u64("rint(inf)", bits_f64(rint(as_f64(0x7ff0000000000000ul))), 0x7ff0000000000000ul)
    expect_u64("rint(nan)", bits_f64(rint(as_f64(0x7ff8000000000000ul))), 0x7ff8000000000000ul)
}


/*
    ------------------------------------------------------------
    Main
    ------------------------------------------------------------
*/


[export]
def main {

    /*
        Сначала explicit constants:
        если implementation и reference одновременно имеют одинаковую
        логическую ошибку, эти тесты всё равно её поймают.
    */

    test_expected_32()
    test_expected_64()


    /*
        Затем полная матрица.
    */

    test_rotations_32()
    test_rotations_64()


    /*
        Дополнительная связь между left/right rotations.
    */

    test_cross_properties_32()
    test_cross_properties_64()


    /*
        Наконец libm-функции из d_m3UnaryOp_f.
    */

    test_fabs()
    test_floorf()
    test_ceilf()
    test_rintf()
    test_rint()


    print("test_m3_math_utils: all rotation and libm tests passed\n")
}
