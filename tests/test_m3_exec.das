options gen2
options indenting = 4
// The executor nests one Daslang frame per executed op (no M3_MUSTTAIL);
// options stack counts only in the program root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/test_m3_env.das: a named test module
// does not get the [init] of required shared modules under dastest.

require dastest/testing_boost
require daslib/fio
require ../source/m3_parse.das


/*
    Component test for m3_exec.das (C m3_exec.h).

    fib32.wasm provides a loaded module whose only function has the type
    (i32) -> i32. Each test replaces that function's body with hand-written
    WebAssembly bytes, recompiles it and calls it, so the operations run
    through the real compiler and the real threaded-interpreter entry path.
    Expected values are the WebAssembly semantics the C operations implement
    (operand order, trap results, shift masking, rounding of rem_s).
*/


let FIB32_PATH = "wasm3c/test/lang/fib32.wasm"


struct ExecFixture {
    env : IM3Environment
    runtime : IM3Runtime
    fib : IM3Function
}


def private read_file(path : string) : array<u8> {
    var bytes : array<u8>
    fopen(path, "rb") $(f) {
        if (f != null) {
            let st = fstat(f)
            bytes |> resize(int64(st.size))
            fread(f, bytes)
        }
    }
    return <- bytes
}


def private load_fib32(t : T?) : ExecFixture {
    var fx : ExecFixture
    var bytes <- read_file(FIB32_PATH)
    t |> equal(length(bytes), 62, "fib32.wasm size")
    if (empty(bytes)) return fx

    fx.env = m3_NewEnvironment()
    fx.runtime = m3_NewRuntime(fx.env, 64u * 1024u, null)
    var _module : IM3Module
    var result = m3_ParseModule(fx.env, _module, unsafe(addr(bytes[0])), u32(length(bytes)))
    t |> equal(result, m3Err_none, "m3_ParseModule")
    if (result != m3Err_none) return fx
    result = m3_LoadModule(fx.runtime, _module)
    t |> equal(result, m3Err_none, "m3_LoadModule")
    if (result != m3Err_none) {
        m3_FreeModule(_module)
        return fx
    }
    result = m3_FindFunction(fx.fib, fx.runtime, "fib")
    t |> equal(result, m3Err_none, "m3_FindFunction fib")
    return fx
}


def private free_fixture(var fx : ExecFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


// `body` is what follows the body-size byte: the locals declaration and the code.
// The array must outlive the compiled function, so the caller owns it.
def private compile_body(t : T?; var fx : ExecFixture; var wasm : array<u8>; body : array<u8>; name : string) : bool {
    wasm |> push(u8(length(body)))
    wasm |> push_from(body)
    fx.fib.wasm = unsafe(addr(wasm[0]))
    fx.fib.wasmEnd = unsafe(reinterpret<bytes_t>(intptr(fx.fib.wasm) + u64(long_length(wasm))))
    fx.fib.compiled = null
    let result = CompileFunction(fx.fib)
    t |> equal(result, m3Err_none, "compile {name}")
    return result == m3Err_none
}


// Calls the (i32) -> i32 function; returns the trap, or m3Err_none with the value in `out`.
def private call_i32(var fx : ExecFixture; n : int; var out : int&) : M3Result {
    var args : array<M3TaggedValue>
    args |> resize(1)
    args[0]._type = M3ValueType.c_m3Type_i32
    tagged_set_i32(args[0], n)
    let result = m3_CallV(fx.fib, args)
    if (result != m3Err_none) return result
    var rets : array<M3TaggedValue>
    let retResult = m3_GetResultsV(fx.fib, rets)
    if (retResult != m3Err_none) return retResult
    out = tagged_get_i32(rets[0])
    return m3Err_none
}


def private expect_value(t : T?; var fx : ExecFixture; n : int; expected : int; name : string) {
    var out = 0
    t |> equal(call_i32(fx, n, out), m3Err_none, "{name}({n}) result")
    t |> equal(out, expected, "{name}({n})")
}


def private expect_trap(t : T?; var fx : ExecFixture; n : int; expected : M3Result; name : string) {
    var out = 0
    t |> equal(call_i32(fx, n, out), expected, "{name}({n}) trap")
}


[test]
def test_exec_operand_order_and_integer_arithmetic(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // local.get 0; i32.const 3; i32.sub -> the slot operand is the left side.
    let subBody <- [u8(0x00), u8(0x20), u8(0x00), u8(0x41), u8(0x03), u8(0x6b), u8(0x0b)]
    var subWasm : array<u8>
    if (compile_body(t, fx, subWasm, subBody, "sub")) {
        expect_value(t, fx, 10, 7, "sub")
        expect_value(t, fx, 0, -3, "sub")
    }

    // i32.const 1; i32.const 33; i32.shl -> OP_SHL_32 masks the count to 5 bits.
    let shlBody <- [u8(0x00), u8(0x41), u8(0x01), u8(0x41), u8(0x21), u8(0x74), u8(0x0b)]
    var shlWasm : array<u8>
    if (compile_body(t, fx, shlWasm, shlBody, "shl")) {
        expect_value(t, fx, 0, 2, "shl")
    }

    // i32.const 0x80000000; i32.const 1; i32.rotl -> 1.
    let rotlBody <- [u8(0x00), u8(0x41), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x78), u8(0x41), u8(0x01), u8(0x77), u8(0x0b)]
    var rotlWasm : array<u8>
    if (compile_body(t, fx, rotlWasm, rotlBody, "rotl")) {
        expect_value(t, fx, 0, 1, "rotl")
    }

    // OP_CLZ_32 / OP_CTZ_32 special-case zero: clz(0) = ctz(0) = 32; popcnt(0) = 0.
    // local.get 0 feeds each unary op so the argument chooses the value.
    let clzBody <- [u8(0x00), u8(0x20), u8(0x00), u8(0x67), u8(0x0b)]
    var clzWasm : array<u8>
    if (compile_body(t, fx, clzWasm, clzBody, "clz")) {
        expect_value(t, fx, 0, 32, "clz")
        expect_value(t, fx, 1, 31, "clz")
        expect_value(t, fx, -1, 0, "clz")
    }
    let ctzBody <- [u8(0x00), u8(0x20), u8(0x00), u8(0x68), u8(0x0b)]
    var ctzWasm : array<u8>
    if (compile_body(t, fx, ctzWasm, ctzBody, "ctz")) {
        expect_value(t, fx, 0, 32, "ctz")
        expect_value(t, fx, 8, 3, "ctz")
        expect_value(t, fx, -1, 0, "ctz")
    }
    let popBody <- [u8(0x00), u8(0x20), u8(0x00), u8(0x69), u8(0x0b)]
    var popWasm : array<u8>
    if (compile_body(t, fx, popWasm, popBody, "popcnt")) {
        expect_value(t, fx, 0, 0, "popcnt")
        expect_value(t, fx, 7, 3, "popcnt")
        expect_value(t, fx, -1, 32, "popcnt")
    }

    // 64-bit clz/ctz of zero through extend + wrap: i64.clz(0) = i64.ctz(0) = 64.
    let clz64Body <- [u8(0x00), u8(0x20), u8(0x00), u8(0xac), u8(0x79), u8(0xa7), u8(0x0b)]
    var clz64Wasm : array<u8>
    if (compile_body(t, fx, clz64Wasm, clz64Body, "clz64")) {
        expect_value(t, fx, 0, 64, "clz64")
        expect_value(t, fx, 1, 63, "clz64")
    }
    let ctz64Body <- [u8(0x00), u8(0x20), u8(0x00), u8(0xac), u8(0x7a), u8(0xa7), u8(0x0b)]
    var ctz64Wasm : array<u8>
    if (compile_body(t, fx, ctz64Wasm, ctz64Body, "ctz64")) {
        expect_value(t, fx, 0, 64, "ctz64")
        expect_value(t, fx, 16, 4, "ctz64")
    }

    // local.get 0; i64.extend_i32_s; i64.const 3; i64.mul; i32.wrap_i64.
    let i64Body <- [u8(0x00), u8(0x20), u8(0x00), u8(0xac), u8(0x42), u8(0x03), u8(0x7e), u8(0xa7), u8(0x0b)]
    var i64Wasm : array<u8>
    if (compile_body(t, fx, i64Wasm, i64Body, "i64 mul wrap")) {
        expect_value(t, fx, 10, 30, "i64 mul wrap")
        expect_value(t, fx, -4, -12, "i64 mul wrap")
    }

    free_fixture(fx)
}


[test]
def test_exec_division_traps_and_rem_s_quirk(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // local.get 0; i32.const 0; i32.div_s -> OP_DIV_S traps on a zero divisor.
    let divZero <- [u8(0x00), u8(0x20), u8(0x00), u8(0x41), u8(0x00), u8(0x6d), u8(0x0b)]
    var divZeroWasm : array<u8>
    if (compile_body(t, fx, divZeroWasm, divZero, "div_s by zero")) {
        expect_trap(t, fx, 7, m3Err_trapDivisionByZero, "div_s by zero")
    }

    // i32.const INT32_MIN; i32.const -1; i32.div_s -> OP_DIV_S integer overflow.
    let divMin <- [u8(0x00), u8(0x41), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x78), u8(0x41), u8(0x7f), u8(0x6d), u8(0x0b)]
    var divMinWasm : array<u8>
    if (compile_body(t, fx, divMinWasm, divMin, "div_s overflow")) {
        expect_trap(t, fx, 0, m3Err_trapIntegerOverflow, "div_s overflow")
    }

    // i32.const INT32_MIN; i32.const -1; i32.rem_s -> OP_REM_S yields 0 instead of trapping.
    let remMin <- [u8(0x00), u8(0x41), u8(0x80), u8(0x80), u8(0x80), u8(0x80), u8(0x78), u8(0x41), u8(0x7f), u8(0x6f), u8(0x0b)]
    var remMinWasm : array<u8>
    if (compile_body(t, fx, remMinWasm, remMin, "rem_s INT_MIN % -1")) {
        expect_value(t, fx, 0, 0, "rem_s INT_MIN % -1")
    }

    // local.get 0; i32.const 7; i32.rem_u -> unsigned remainder.
    let remU <- [u8(0x00), u8(0x20), u8(0x00), u8(0x41), u8(0x07), u8(0x70), u8(0x0b)]
    var remUWasm : array<u8>
    if (compile_body(t, fx, remUWasm, remU, "rem_u")) {
        expect_value(t, fx, 30, 2, "rem_u")
    }

    free_fixture(fx)
}


// The C d_m3UnaryOp_f rows call libm (fabsf/fabs/floorf/ceilf/rintf/rint).
// Every body below pushes a constant, applies one float operation and returns
// the raw bit pattern (i32.reinterpret_f32, or the sign bit of the f64 result),
// so signed zero is visible in the i32 result of the fixture function.
[test]
def test_exec_float_unary_ops(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // f32.const -0.0; f32.floor; i32.reinterpret_f32 -> floorf keeps -0.0.
    let floorNegZero <- [u8(0x00), u8(0x43), u8(0x00), u8(0x00), u8(0x00), u8(0x80), u8(0x8e), u8(0xbc), u8(0x0b)]
    var floorNegZeroWasm : array<u8>
    if (compile_body(t, fx, floorNegZeroWasm, floorNegZero, "f32.floor(-0.0)")) {
        expect_value(t, fx, 0, int(0x80000000u), "f32.floor(-0.0)")
    }

    // f32.const inf; f32.floor -> floorf returns the infinity unchanged.
    let floorInf <- [u8(0x00), u8(0x43), u8(0x00), u8(0x00), u8(0x80), u8(0x7f), u8(0x8e), u8(0xbc), u8(0x0b)]
    var floorInfWasm : array<u8>
    if (compile_body(t, fx, floorInfWasm, floorInf, "f32.floor(inf)")) {
        expect_value(t, fx, 0, 2139095040, "f32.floor(inf)")
    }

    // f32.const -0.5; f32.ceil -> ceilf returns -0.0, not +0.0.
    let ceilHalf <- [u8(0x00), u8(0x43), u8(0x00), u8(0x00), u8(0x00), u8(0xbf), u8(0x8d), u8(0xbc), u8(0x0b)]
    var ceilHalfWasm : array<u8>
    if (compile_body(t, fx, ceilHalfWasm, ceilHalf, "f32.ceil(-0.5)")) {
        expect_value(t, fx, 0, int(0x80000000u), "f32.ceil(-0.5)")
    }

    // f32.const 2.5; f32.nearest -> rintf rounds the half to even: 2.0.
    let nearest25 <- [u8(0x00), u8(0x43), u8(0x00), u8(0x00), u8(0x20), u8(0x40), u8(0x90), u8(0xbc), u8(0x0b)]
    var nearest25Wasm : array<u8>
    if (compile_body(t, fx, nearest25Wasm, nearest25, "f32.nearest(2.5)")) {
        expect_value(t, fx, 0, 1073741824, "f32.nearest(2.5)")
    }

    // f32.const -0.5; f32.nearest -> -0.0.
    let nearestNegHalf <- [u8(0x00), u8(0x43), u8(0x00), u8(0x00), u8(0x00), u8(0xbf), u8(0x90), u8(0xbc), u8(0x0b)]
    var nearestNegHalfWasm : array<u8>
    if (compile_body(t, fx, nearestNegHalfWasm, nearestNegHalf, "f32.nearest(-0.5)")) {
        expect_value(t, fx, 0, int(0x80000000u), "f32.nearest(-0.5)")
    }

    // f64.const -0.0; f64.abs; i64.reinterpret_f64; i64.const 63; i64.shr_u;
    // i32.wrap_i64 -> the sign bit fabs clears.
    let absNegZero <- [u8(0x00), u8(0x44),
                       u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x80),
                       u8(0x99), u8(0xbd), u8(0x42), u8(0x3f), u8(0x88), u8(0xa7), u8(0x0b)]
    var absNegZeroWasm : array<u8>
    if (compile_body(t, fx, absNegZeroWasm, absNegZero, "f64.abs(-0.0)")) {
        expect_value(t, fx, 0, 0, "f64.abs(-0.0) sign bit")
    }

    // f64.const 2.5; f64.nearest; i32.trunc_f64_s -> rint rounds the half to even.
    let nearest25d <- [u8(0x00), u8(0x44),
                       u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x04), u8(0x40),
                       u8(0x9e), u8(0xaa), u8(0x0b)]
    var nearest25dWasm : array<u8>
    if (compile_body(t, fx, nearest25dWasm, nearest25d, "f64.nearest(2.5)")) {
        expect_value(t, fx, 0, 2, "f64.nearest(2.5)")
    }

    // f64.const -0.5; f64.nearest -> -0.0: the sign bit survives.
    let nearestNegHalfD <- [u8(0x00), u8(0x44),
                            u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0x00), u8(0xe0), u8(0xbf),
                            u8(0x9e), u8(0xbd), u8(0x42), u8(0x3f), u8(0x88), u8(0xa7), u8(0x0b)]
    var nearestNegHalfDWasm : array<u8>
    if (compile_body(t, fx, nearestNegHalfDWasm, nearestNegHalfD, "f64.nearest(-0.5)")) {
        expect_value(t, fx, 0, 1, "f64.nearest(-0.5) sign bit")
    }

    free_fixture(fx)
}


[test]
def test_exec_control_flow(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // sum 1..n with a loop and br_if: op_Loop, op_ContinueLoopIf, local.set/tee.
    // locals: one i32 (sum). loop { sum += i; i -= 1; br_if i } ; sum
    let loopBody <- [u8(0x01), u8(0x01), u8(0x7f),
                     u8(0x03), u8(0x40),
                     u8(0x20), u8(0x01), u8(0x20), u8(0x00), u8(0x6a), u8(0x21), u8(0x01),
                     u8(0x20), u8(0x00), u8(0x41), u8(0x01), u8(0x6b), u8(0x22), u8(0x00),
                     u8(0x0d), u8(0x00),
                     u8(0x0b),
                     u8(0x20), u8(0x01), u8(0x0b)]
    var loopWasm : array<u8>
    if (compile_body(t, fx, loopWasm, loopBody, "loop sum")) {
        expect_value(t, fx, 10, 55, "loop sum")
        expect_value(t, fx, 100, 5050, "loop sum")
    }

    // local.get 0; if (result i32) { 1 } else { 2 }: op_If, the else page and op_Branch back.
    let ifBody <- [u8(0x00), u8(0x20), u8(0x00), u8(0x04), u8(0x7f), u8(0x41), u8(0x01), u8(0x05), u8(0x41), u8(0x02), u8(0x0b), u8(0x0b)]
    var ifWasm : array<u8>
    if (compile_body(t, fx, ifWasm, ifBody, "if/else")) {
        expect_value(t, fx, 5, 1, "if/else")
        expect_value(t, fx, 0, 2, "if/else")
    }

    // i32.const 100; i32.const 200; local.get 0; select -> op_Select picks operand1 when true.
    let selBody <- [u8(0x00), u8(0x41), u8(0xe4), u8(0x00), u8(0x41), u8(0xc8), u8(0x01), u8(0x20), u8(0x00), u8(0x1b), u8(0x0b)]
    var selWasm : array<u8>
    if (compile_body(t, fx, selWasm, selBody, "select")) {
        expect_value(t, fx, 1, 100, "select")
        expect_value(t, fx, 0, 200, "select")
    }

    // unreachable -> op_Unreachable traps.
    let unreachableBody <- [u8(0x00), u8(0x00), u8(0x0b)]
    var unreachableWasm : array<u8>
    if (compile_body(t, fx, unreachableWasm, unreachableBody, "unreachable")) {
        expect_trap(t, fx, 0, m3Err_trapUnreachable, "unreachable")
    }

    free_fixture(fx)
}
