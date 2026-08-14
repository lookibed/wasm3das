options gen2
options indenting = 4

module m3_math_utils public

require math
require strings public
require m3_core public


/*
    m3_math_utils.h -> m3_math_utils.das

    m3_core.das определяет:

        i32
        u32
        i64
        u64
        f32
        f64

        M3Result
        m3Err_none
        m3ResultIsError(result)

        m3Err_trapDivisionByZero
        m3Err_trapIntegerOverflow
        m3Err_trapIntegerConversion

    Аналоги C-preprocessor include guard в Daslang не нужны:
    модуль загружается один раз через require.

    ВАЖНО:

        В C newTrap(err) был макросом вида `return err`.
        Имитировать его функцией бессмысленно: обычный
        `return m3Err_trap...` выражает то же самое напрямую.

        Trap-capable функции возвращают M3Result:

            def OP_...( ... ) : M3Result {
                if (...) {
                    return m3Err_trap...
                }
                ...
                return m3Err_none
            }

        А вызывающий opcode должен делать:

            let result = OP_...(RES, A, B)
            if (m3ResultIsError(result)) {
                return result
            }

        Иначе M3Result не поднимется вверх до runtime boundary.
*/


/*
    builtin_popcount
    builtin_ctz
    builtin_clz

    В Daslang эти операции уже являются portable intrinsics.
*/

def builtin_popcount(x : u32) : int {
    return int(popcnt(x))
}

def builtin_ctz(x : u32) : int {
    return int(ctz(x))
}

def builtin_clz(x : u32) : int {
    return int(clz(x))
}


def builtin_popcountll(x : u64) : int {
    return int(popcnt(x))
}

def builtin_ctzll(value : u64) : int {
    return int(ctz(value))
}

def builtin_clzll(value : u64) : int {
    return int(clz(value))
}


/*
    signbit

    В C исходнике был отдельный ESP8266/ESP32 workaround.
    В Daslang платформенная развилка не нужна.

    reinterpret<T> является unsafe bit-cast, то есть здесь это
    прямой аналог чтения IEEE754 sign bit.
*/

def signbit(x : f32) : bool {
    unsafe {
        return (reinterpret<u32>(x) & 0x80000000u) != 0u
    }
}

def signbit(x : f64) : bool {
    unsafe {
        return (reinterpret<u64>(x) & 0x8000000000000000ul) != 0ul
    }
}


/*
    AVR fallbacks

    В обычном Daslang эти платформенные fallback-функции вообще
    не требуются. Они оставлены, чтобы сохранить структуру исходника.
*/

def rintf(arg : f32) : f32 {
    var ux : u32

    unsafe {
        ux = reinterpret<u32>(arg)
    }

    ux &= 0x7FFFFFFFu

    if (ux == 0u || ux > 0x5A000000u) {
        return arg
    }

    return round(arg)
}


def rint(arg : f64) : f64 {
    var bits : u64

    unsafe {
        bits = reinterpret<u64>(arg)
    }

    let ux = u32(bits >> 32ul) & 0x7FFFFFFFu
    let low = u32(bits & 0xFFFFFFFFul)

    if ((ux == 0u && low == 0u) || ux > 0x433FFFFFu) {
        return arg
    }

    return round(arg)
}


/*
    strtoull

    C API:

        uint64_t strtoull(
            const char * str,
            char ** endptr,
            int base
        )

    В pure Daslang char** был бы совершенно неидиоматичным.
    endptr здесь является индексом первого непрочитанного символа.

    То есть:

        var endptr = 0
        let value = strtoull("0xff rest", endptr, 0)

    после вызова:
        value  == 255
        endptr == 4
*/

def strtoull( // nolint:STYLE038
    str : string;
    var endptr : int&;
    base_value : int
) : u64 {
    var result = 0ul
    var p = 0
    var base = base_value

    let str_len = length(str)

    while (p < str_len) {
        let ch = character_at(str, p) // nolint:PERF003

        if (ch == ' ' || ch == '\t') {
            p++
        } else {
            break
        }
    }

    if (base == 0) {
        if (
            p < str_len &&
            character_at(str, p) == '0' && // nolint:PERF003
            p + 1 < str_len &&
            (
                character_at(str, p + 1) == 'x' || // nolint:PERF003
                character_at(str, p + 1) == 'X' // nolint:PERF003
            )
        ) {
            base = 16
            p += 2

        } elif (
            p < str_len &&
            character_at(str, p) == '0' // nolint:PERF003
        ) {
            base = 8
            p++

        } else {
            base = 10
        }

    } elif (
        base == 16 &&
        p < str_len &&
        character_at(str, p) == '0' && // nolint:PERF003
        p + 1 < str_len &&
        (
            character_at(str, p + 1) == 'x' || // nolint:PERF003
            character_at(str, p + 1) == 'X' // nolint:PERF003
        )
    ) {
        p += 2
    }

    while (p < str_len) {
        let ch = character_at(str, p) // nolint:PERF003

        var digit = 0

        if (ch >= '0' && ch <= '9') { // nolint:PERF014
            digit = ch - '0'

        } elif (ch >= 'a' && ch <= 'f') {
            digit = ch - 'a' + 10

        } elif (ch >= 'A' && ch <= 'F') {
            digit = ch - 'A' + 10

        } else {
            break
        }

        if (digit >= base) {
            break
        }

        result = result * u64(base) + u64(digit)
        p++
    }

    endptr = p

    return result
}


/*
    Вариант C-style без endptr.
*/

def strtoull(str : string; base : int) : u64 {
    var endptr = 0
    return strtoull(str, endptr, base)
}


/*
    Rotr, Rotl
*/

def rotl32(n : u32; c_value : uint) : u32 {
    let mask = uint(8 * typeinfo sizeof(n) - 1)
    let c = c_value & mask & 31u

    return (n << c) | (n >> ((0u - c) & mask))
}


def rotr32(n : u32; c_value : uint) : u32 {
    let mask = uint(8 * typeinfo sizeof(n) - 1)
    let c = c_value & mask & 31u

    return (n >> c) | (n << ((0u - c) & mask))
}


def rotl64(n : u64; c_value : uint) : u64 {
    let mask = uint(8 * typeinfo sizeof(n) - 1)
    let c = c_value & mask & 63u
    let shift = u64(c)
    let shift_back = u64((0u - c) & mask)

    return (n << shift) | (n >> shift_back)
}


def rotr64(n : u64; c_value : uint) : u64 {
    let mask = uint(8 * typeinfo sizeof(n) - 1)
    let c = c_value & mask & 63u
    let shift = u64(c)
    let shift_back = u64((0u - c) & mask)

    return (n >> shift) | (n << shift_back)
}


/*
    Integer Div, Rem

    C macros заменены generic-функциями.

    RES остаётся output lvalue, поэтому код вызова практически
    идентичен C:

        OP_DIV_U(RES, A, B)
*/


def OP_DIV_U(
    var RES : auto(TT)&;
    A : TT;
    B : TT
) : M3Result {
    if (B == TT(0)) {
        return m3Err_trapDivisionByZero
    }

    RES = A / B

    return m3Err_none
}


def OP_REM_U(
    var RES : auto(TT)&;
    A : TT;
    B : TT
) : M3Result {
    if (B == TT(0)) {
        return m3Err_trapDivisionByZero
    }

    RES = A % B

    return m3Err_none
}


/*
    Signed WebAssembly division.

    В C здесь был compile-time тест на representation signed integer:

        #if (INT_MIN != -INT_MAX)

    Для Daslang отдельная платформенная версия не нужна.
    WebAssembly semantics требуют явной проверки INT_MIN / -1.
*/

def OP_DIV_S(
    var RES : auto(TT)&;
    A : TT;
    B : TT;
    TYPE_MIN : TT
) : M3Result {
    if (B == TT(0)) {
        return m3Err_trapDivisionByZero
    }

    if (B == TT(-1) && A == TYPE_MIN) {
        return m3Err_trapIntegerOverflow
    }

    RES = A / B

    return m3Err_none
}


def OP_REM_S(
    var RES : auto(TT)&;
    A : TT;
    B : TT;
    TYPE_MIN : TT
) : M3Result {
    if (B == TT(0)) {
        return m3Err_trapDivisionByZero
    }

    if (B == TT(-1) && A == TYPE_MIN) {
        RES = TT(0)
        return m3Err_none
    }

    RES = A % B

    return m3Err_none
}


/*
    Trunc

    OP_TRUNC в C принимал TYPE как macro parameter.

    В Daslang TYPE вообще не нужен:
    тип RES захватывается как auto(TT), после чего TT(A)
    является явным numeric conversion.
*/

def OP_TRUNC(
    var RES : auto(TT)&;
    A;
    RMIN;
    RMAX
) : M3Result {
    if (is_nan(A)) {
        return m3Err_trapIntegerConversion
    }

    if (A <= RMIN || A >= RMAX) {
        return m3Err_trapIntegerOverflow
    }

    RES = TT(A)

    return m3Err_none
}


def OP_I32_TRUNC_F32(var RES : i32&; A : f32) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -2147483904.0f,
        2147483648.0f
    )
}


def OP_U32_TRUNC_F32(var RES : u32&; A : f32) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -1.0f,
        4294967296.0f
    )
}


def OP_I32_TRUNC_F64(var RES : i32&; A : f64) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -2147483649.0lf,
        2147483648.0lf
    )
}


def OP_U32_TRUNC_F64(var RES : u32&; A : f64) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -1.0lf,
        4294967296.0lf
    )
}


def OP_I64_TRUNC_F32(var RES : i64&; A : f32) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -9223373136366403584.0f,
        9223372036854775808.0f
    )
}


def OP_U64_TRUNC_F32(var RES : u64&; A : f32) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -1.0f,
        18446744073709551616.0f
    )
}


def OP_I64_TRUNC_F64(var RES : i64&; A : f64) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -9223372036854777856.0lf,
        9223372036854775808.0lf
    )
}


def OP_U64_TRUNC_F64(var RES : u64&; A : f64) : M3Result {
    return OP_TRUNC(
        RES,
        A,
        -1.0lf,
        18446744073709551616.0lf
    )
}


/*
    Saturating truncation
*/

def OP_TRUNC_SAT(
    var RES : auto(TT)&;
    A;
    RMIN;
    RMAX;
    IMIN : TT;
    IMAX : TT
) {
    if (is_nan(A)) {
        RES = TT(0)

    } elif (A <= RMIN) {
        RES = IMIN

    } elif (A >= RMAX) {
        RES = IMAX

    } else {
        RES = TT(A)
    }
}


def OP_I32_TRUNC_SAT_F32(var RES : i32&; A : f32) {
    OP_TRUNC_SAT(
        RES,
        A,
        -2147483904.0f,
        2147483648.0f,
        -2147483647 - 1,
        2147483647
    )
}


def OP_U32_TRUNC_SAT_F32(var RES : u32&; A : f32) {
    OP_TRUNC_SAT(
        RES,
        A,
        -1.0f,
        4294967296.0f,
        0u,
        0xFFFFFFFFu
    )
}


def OP_I32_TRUNC_SAT_F64(var RES : i32&; A : f64) {
    OP_TRUNC_SAT(
        RES,
        A,
        -2147483649.0lf,
        2147483648.0lf,
        -2147483647 - 1,
        2147483647
    )
}


def OP_U32_TRUNC_SAT_F64(var RES : u32&; A : f64) {
    OP_TRUNC_SAT(
        RES,
        A,
        -1.0lf,
        4294967296.0lf,
        0u,
        0xFFFFFFFFu
    )
}


def OP_I64_TRUNC_SAT_F32(var RES : i64&; A : f32) {
    OP_TRUNC_SAT(
        RES,
        A,
        -9223373136366403584.0f,
        9223372036854775808.0f,
        -9223372036854775807l - 1l,
        9223372036854775807l
    )
}


def OP_U64_TRUNC_SAT_F32(var RES : u64&; A : f32) {
    OP_TRUNC_SAT(
        RES,
        A,
        -1.0f,
        18446744073709551616.0f,
        0ul,
        0xFFFFFFFFFFFFFFFFul
    )
}


def OP_I64_TRUNC_SAT_F64(var RES : i64&; A : f64) {
    OP_TRUNC_SAT(
        RES,
        A,
        -9223372036854777856.0lf,
        9223372036854775808.0lf,
        -9223372036854775807l - 1l,
        9223372036854775807l
    )
}


def OP_U64_TRUNC_SAT_F64(var RES : u64&; A : f64) {
    OP_TRUNC_SAT(
        RES,
        A,
        -1.0lf,
        18446744073709551616.0lf,
        0ul,
        0xFFFFFFFFFFFFFFFFul
    )
}


/*
    Min, Max

    WebAssembly min/max не полностью эквивалентны обычным min/max:
      - NaN должен распространяться
      - min(+0, -0) -> -0
      - max(+0, -0) -> +0

    Поэтому оставляем исходную реализацию.
*/


def _nan_f32() : f32 {
    let inf = 1.0f / 0.0f   // nolint:LINT006 - deliberate NaN construction
    return inf / inf        // nolint:LINT007 - deliberate NaN construction
}


def _nan_f64() : f64 {
    let inf = 1.0lf / 0.0lf   // nolint:LINT006 - deliberate NaN construction
    return inf / inf          // nolint:LINT007 - deliberate NaN construction
}


def min_f32(a : f32; b : f32) : f32 {
    if (is_nan(a) || is_nan(b)) {
        return _nan_f32()
    }

    if (a == 0.0f && a == b) {
        if (signbit(a)) {
            return a
        } else {
            return b
        }
    }

    if (a > b) {
        return b
    }

    return a
}


def max_f32(a : f32; b : f32) : f32 {
    if (is_nan(a) || is_nan(b)) {
        return _nan_f32()
    }

    if (a == 0.0f && a == b) {
        if (signbit(a)) {
            return b
        } else {
            return a
        }
    }

    if (a > b) {
        return a
    }

    return b
}


def min_f64(a : f64; b : f64) : f64 {
    if (is_nan(a) || is_nan(b)) {
        return _nan_f64()
    }

    if (a == 0.0lf && a == b) {
        if (signbit(a)) {
            return a
        } else {
            return b
        }
    }

    if (a > b) {
        return b
    }

    return a
}


def max_f64(a : f64; b : f64) : f64 {
    if (is_nan(a) || is_nan(b)) {
        return _nan_f64()
    }

    if (a == 0.0lf && a == b) {
        if (signbit(a)) {
            return b
        } else {
            return a
        }
    }

    if (a > b) {
        return a
    }

    return b
}
