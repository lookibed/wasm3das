options gen2
options indenting = 4

module test_m3_api_defs shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_api_defs
require modules/wasm3das/source/m3_bind
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core
require strings

/*
    test_m3_api_defs.das: the Eden tests of source/m3_api_defs.das.

    There is no upstream test file for this module (the upstream helpers were
    exercised only through m3_api_libc / m3_api_wasi). The tests build raw
    functions with the helpers, link them with m3_LinkRawFunction into a
    hand-assembled module (one import "env" "f", one export "run" that
    passes its parameters to it) and call "run" from the host:
      - test_frame_i_ii: "i(ii)": the result cell at sp, the arguments at
        sp + 2 and sp + 4 (two slot words per cell), the cursor ends at
        sp + 6; the result reaches m3_Call's caller.
      - test_frame_v_i: "v(i)": a void function has no result cell, its
        argument is at sp itself.
      - test_frame_I_IF: "I(IF)": i64 and f64 cells (an i64 above 2^32, a
        negative f64 truncated).
      - test_mem_arg_i_ptr_i: "i(*i)": m3ApiGetArgMem is the offset of a
        data segment; the bytes are read (m3ApiReadString, m3ApiReadBytes)
        and written back (m3ApiWriteBytes) through the helpers.
      - test_mem_null_ptr: "i(*i)" with pointer 0: m3ApiIsNullPtr.
      - test_mem_check_traps: "i(*i)" out of bounds (past the end, at
        0xffffffff) traps with m3Err_trapOutOfBoundsMemoryAccess (C's
        string) out of m3_Call; the last in-bounds byte does not.
      - test_frame_ii_i: "ii(i)": two m3ApiMultiValueReturnType cells, then
        the argument at sp + 4; both results reach m3_GetResults.
    Direct tests of the helpers on a runtime built by hand:
      - test_frame_cursor: m3ApiFrame, the 2-word step of every reader, the
        narrow readers (u8 / u16 of the low bits), m3ApiReturn_* and
        m3ApiMultiValueReturn_* write the cell they are given.
      - test_check_mem_bounds: C's rule on a 100-byte memory (the end is
        inclusive, len 0 at the end passes, a negative offset traps).
      - test_offsets_and_null: m3ApiOffsetToPtr / m3ApiPtrToOffset round
        trip a u32 above 2^31; m3ApiIsNullPtr.
      - test_read_write_mem: m3ApiReadMem* / m3ApiWriteMem* little-endian,
        m3ApiStrnlen (NUL, maxlen, end of memory), m3ApiWriteString.
      - test_trap_and_success: m3ApiTrap / m3ApiSuccess.
*/


// ============================================================================
// Helpers: a module with one import "env" "f" and one export "run"
// ============================================================================


let private T_I32 = 0x7fu8
let private T_I64 = 0x7eu8
let private T_F64 = 0x7cu8


// unsigned LEB128 of a u32
def private leb(var out : array<u8>; value : uint) {
    var v = value
    while (true) {
        let b = v & 0x7fu
        v = v >> 7u
        if (v == 0u) {
            push(out, u8(b))
            break
        }
        push(out, u8(b | 0x80u))
    }
}


def private name(var out : array<u8>; text : string) {
    leb(out, uint(length(text)))
    for (i in range(length(text))) {
        push(out, u8(character_at(text, i)))
    }
}


def private section(var out : array<u8>; id : int; content : array<u8>) {
    push(out, u8(id))
    leb(out, uint(length(content)))
    for (b in content) {
        push(out, b)
    }
}


/*
    (module
      (import "env" "f" (func $f (param PARAMS) (result RESULTS)))
      (memory 1)                                 ;; when withMemory
      (func (export "run") (param PARAMS) (result RESULTS)
        (call $f (local.get 0) ... (local.get n-1)))
      (data (i32.const DATA_AT) "DATA"))         ;; when data != ""
*/
def private import_module(params : array<u8>; results : array<u8>; withMemory : bool; dataAt : int; data : string) : array<u8> {
    var out : array<u8>
    for (b in [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8]) {
        push(out, b)
    }

    var types : array<u8>
    leb(types, 1u)
    push(types, 0x60u8)
    leb(types, uint(length(params)))
    for (p in params) {
        push(types, p)
    }
    leb(types, uint(length(results)))
    for (r in results) {
        push(types, r)
    }
    section(out, 1, types)

    var imports : array<u8>
    leb(imports, 1u)
    name(imports, "env")
    name(imports, "f")
    push(imports, 0x00u8)   // func
    leb(imports, 0u)        // type 0
    section(out, 2, imports)

    var funcs : array<u8>
    leb(funcs, 1u)
    leb(funcs, 0u)
    section(out, 3, funcs)

    if (withMemory) {
        var mems : array<u8>
        leb(mems, 1u)
        push(mems, 0x00u8)  // limits: min only
        leb(mems, 1u)       // one page
        section(out, 5, mems)
    }

    var exports : array<u8>
    leb(exports, 1u)
    name(exports, "run")
    push(exports, 0x00u8)   // func
    leb(exports, 1u)        // func 1 (the import is func 0)
    section(out, 7, exports)

    var body : array<u8>
    leb(body, 0u)           // no locals
    for (i in range(length(params))) {
        push(body, 0x20u8)  // local.get i
        leb(body, uint(i))
    }
    push(body, 0x10u8)      // call 0
    leb(body, 0u)
    push(body, 0x0bu8)      // end
    var code : array<u8>
    leb(code, 1u)
    leb(code, uint(length(body)))
    for (b in body) {
        push(code, b)
    }
    section(out, 10, code)

    if (!empty(data)) {
        var datas : array<u8>
        leb(datas, 1u)
        push(datas, 0x00u8)     // active, memory 0
        push(datas, 0x41u8)     // i32.const DATA_AT (below 64: one sleb byte)
        push(datas, u8(dataAt))
        push(datas, 0x0bu8)     // end
        name(datas, data)       // the bytes, as a vec
        section(out, 11, datas)
    }
    return <- out
}


// a fresh runtime of 64 KiB of stack
def private new_runtime() : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    return <- rt
}


// parses and loads `bytes`, links "env" "f" to `fn` with `signature` and
// finds "run"; -1 when a step fails (the failure is recorded)
def private link_run(var t : TestRun; var rt : M3Runtime; bytes : array<u8>; signature : string; fn : M3RawCall) : IM3Function {
    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "the hand-built module parses")
    if (parsed._0 != m3Err_none) {
        return -1
    }
    is_ok(t, m3_LoadModule(rt, parsed._1), "m3_LoadModule")
    is_ok(t, m3_LinkRawFunction(rt, parsed._1, "env", "f", signature, fn), "link env.f as {signature}")
    var run : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, run, "run"), "m3_FindFunction run")
    return run
}


// what the raw functions saw, relative to their sp
var private g_calls = 0
var private g_retOff = -1
var private g_ret2Off = -1
var private g_argOff = -1
var private g_endOff = -1
var private g_lastI32 = 0
var private g_lastI64 = 0l
var private g_lastF64 = 0.0lf
var private g_lastString = ""
var private g_lastPtr = -1


def private reset_seen() {
    g_calls = 0
    g_retOff = -1
    g_ret2Off = -1
    g_argOff = -1
    g_endOff = -1
    g_lastI32 = 0
    g_lastI64 = 0l
    g_lastF64 = 0.0lf
    g_lastString = ""
    g_lastPtr = -1
}


// ============================================================================
// Raw functions built with the helpers
// ============================================================================


// "i(ii)": a * 10 + b
def private host_i_ii(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)             // m3ApiReturnType (int32_t)
    g_argOff = f.cur - sp
    let a = m3ApiGetArg_i32(rt, f)                  // m3ApiGetArg (int32_t, a)
    let b = m3ApiGetArg_i32(rt, f)                  // m3ApiGetArg (int32_t, b)
    g_calls++
    g_retOff = raw_return - sp
    g_endOff = f.cur - sp
    m3ApiReturn_i32(rt, raw_return, a * 10 + b)     // m3ApiReturn (a * 10 + b)
    return m3ApiSuccess()
}


// "v(i)": records its argument
def private host_v_i(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    g_argOff = f.cur - sp
    g_lastI32 = m3ApiGetArg_i32(rt, f)              // m3ApiGetArg (int32_t, value)
    g_calls++
    g_endOff = f.cur - sp
    return m3ApiSuccess()
}


// "I(IF)": a + i64(b)
def private host_I_IF(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)             // m3ApiReturnType (int64_t)
    let a = m3ApiGetArg_i64(rt, f)                  // m3ApiGetArg (int64_t, a)
    let b = m3ApiGetArg_f64(rt, f)                  // m3ApiGetArg (double, b)
    g_calls++
    g_lastI64 = a
    g_lastF64 = b
    g_endOff = f.cur - sp
    m3ApiReturn_i64(rt, raw_return, a + i64(b))
    return m3ApiSuccess()
}


// "i(*i)": NULL -> -1; otherwise checks (ptr, len), reads the bytes,
// writes them back reversed and returns their sum
def private host_i_ptr_i(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)             // m3ApiReturnType (int32_t)
    let i_ptr = m3ApiGetArgMem(rt, f)               // m3ApiGetArgMem (uint8_t *, i_ptr)
    let i_len = m3ApiGetArg_u32(rt, f)              // m3ApiGetArg (uint32_t, i_len)
    g_calls++
    g_lastPtr = i_ptr

    if (m3ApiIsNullPtr(i_ptr)) {
        m3ApiReturn_i32(rt, raw_return, -1)
        return m3ApiSuccess()
    }
    let check = m3ApiCheckMem(rt, i_ptr, u64(i_len))
    if (check != m3Err_none) {
        return check
    }

    let n = int(i_len)
    g_lastString = m3ApiReadString(rt, i_ptr, n)
    let bytes <- m3ApiReadBytes(rt, i_ptr, n)
    var sum = 0
    var reversed : array<u8>
    for (i in range(n)) {
        sum += int(bytes[i])
        push(reversed, bytes[n - 1 - i])
    }
    m3ApiWriteBytes(rt, i_ptr, reversed)
    m3ApiReturn_i32(rt, raw_return, sum)
    return m3ApiSuccess()
}


// "ii(i)": (x + 1, x * 2)
def private host_ii_i(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let r0 = m3ApiMultiValueReturnType(f)           // m3ApiMultiValueReturnType (int32_t, r0)
    let r1 = m3ApiMultiValueReturnType(f)           // m3ApiMultiValueReturnType (int32_t, r1)
    g_argOff = f.cur - sp
    let x = m3ApiGetArg_i32(rt, f)                  // m3ApiGetArg (int32_t, x)
    g_calls++
    g_retOff = r0 - sp
    g_ret2Off = r1 - sp
    g_endOff = f.cur - sp
    m3ApiMultiValueReturn_i32(rt, r0, x + 1)        // m3ApiMultiValueReturn (r0, x + 1)
    m3ApiMultiValueReturn_i32(rt, r1, x * 2)        // m3ApiMultiValueReturn (r1, x * 2)
    return m3ApiSuccess()
}


// calls run(ptr, len) of an "i(*i)" module; the call result and the i32
def private call_ptr_len(var t : TestRun; var rt : M3Runtime; run : IM3Function; ptr : uint; len : uint) : tuple<M3Result; int> {
    let r = m3_Call(rt, run, [u64(ptr), u64(len)])
    var value = -999
    if (r == m3Err_none) {
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, run, 1u, out), "m3_GetResults run({ptr}, {len})")
        if (length(out) == 1) {
            value = m3_bits_to_i32(out[0])
        }
    }
    return (r, value)
}


// ============================================================================
// Linked from wasm
// ============================================================================


def test_frame_i_ii(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    let run = link_run(t, rt, import_module([T_I32, T_I32], [T_I32], false, 0, ""), "i(ii)", @@host_i_ii)
    if (run != -1) {
        is_ok(t, m3_Call(rt, run, [m3_bits_from_i32(4), m3_bits_from_i32(2)]), "m3_Call run(4, 2)")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, run, 1u, out), "m3_GetResults run(4, 2)")
        if (length(out) == 1) {
            equal(t, m3_bits_to_i32(out[0]), 42, "run(4, 2) = 4 * 10 + 2 (argument order)")
        }
        equal(t, g_calls, 1, "the raw function ran once")
        equal(t, g_retOff, 0, "the result cell is at sp")
        equal(t, g_argOff, 2, "argument 0 is at sp + 2 (one cell = two slot words)")
        equal(t, g_endOff, 6, "the cursor ends after three cells")

        is_ok(t, m3_Call(rt, run, [m3_bits_from_i32(-3), m3_bits_from_i32(7)]), "m3_Call run(-3, 7)")
        var out2 : array<u64>
        is_ok(t, m3_GetResults(rt, run, 1u, out2), "m3_GetResults run(-3, 7)")
        if (length(out2) == 1) {
            equal(t, m3_bits_to_i32(out2[0]), -23, "negative i32 arguments and result")
        }
    }
    m3_FreeRuntime(rt)
}


def test_frame_v_i(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    var none : array<u8>
    let run = link_run(t, rt, import_module([T_I32], none, false, 0, ""), "v(i)", @@host_v_i)
    if (run != -1) {
        is_ok(t, m3_Call(rt, run, [m3_bits_from_i32(77)]), "m3_Call run(77)")
        equal(t, g_calls, 1, "the raw function ran once")
        equal(t, g_lastI32, 77, "the argument of a void function")
        equal(t, g_argOff, 0, "a void function's argument 0 is at sp")
        equal(t, g_endOff, 2, "the cursor ends after one cell")
    }
    m3_FreeRuntime(rt)
}


def test_frame_I_IF(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    let run = link_run(t, rt, import_module([T_I64, T_F64], [T_I64], false, 0, ""), "I(IF)", @@host_I_IF)
    if (run != -1) {
        let big = 1099511627776l   // 2^40 (a hex literal with `l` is a uint64)
        is_ok(t, m3_Call(rt, run, [m3_bits_from_i64(big), m3_bits_from_f64(2.5lf)]), "m3_Call run(2^40, 2.5)")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, run, 1u, out), "m3_GetResults run(2^40, 2.5)")
        if (length(out) == 1) {
            equal(t, m3_bits_to_i64(out[0]), big + 2l, "an i64 result above 2^32")
        }
        equal(t, g_lastI64, big, "the i64 argument")
        equal(t, g_lastF64, 2.5lf, "the f64 argument")
        equal(t, g_endOff, 6, "the cursor ends after three cells")

        is_ok(t, m3_Call(rt, run, [m3_bits_from_i64(-5l), m3_bits_from_f64(-1.5lf)]), "m3_Call run(-5, -1.5)")
        var out2 : array<u64>
        is_ok(t, m3_GetResults(rt, run, 1u, out2), "m3_GetResults run(-5, -1.5)")
        if (length(out2) == 1) {
            equal(t, m3_bits_to_i64(out2[0]), -6l, "negative i64 and f64 (truncated toward zero)")
        }
    }
    m3_FreeRuntime(rt)
}


def test_mem_arg_i_ptr_i(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    let run = link_run(t, rt, import_module([T_I32, T_I32], [T_I32], true, 16, "hello"), "i(*i)", @@host_i_ptr_i)
    if (run != -1) {
        equal(t, int(m3_GetMemorySize(rt)), 65536, "one page of memory")
        let r = call_ptr_len(t, rt, run, 16u, 5u)
        is_ok(t, r._0, "run(16, 5)")
        equal(t, r._1, 104 + 101 + 108 + 108 + 111, "the sum of the bytes of \"hello\"")
        equal(t, g_lastPtr, 16, "m3ApiGetArgMem is the offset")
        equal_str(t, g_lastString, "hello", "m3ApiReadString")
        equal_str(t, m3ApiReadString(rt, 16, 5), "olleh", "m3ApiWriteBytes wrote the reversed bytes")
        equal(t, rt.mem[15], 0u8, "the byte before is untouched")
        equal(t, rt.mem[21], 0u8, "the byte after is untouched")
    }
    m3_FreeRuntime(rt)
}


def test_mem_null_ptr(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    let run = link_run(t, rt, import_module([T_I32, T_I32], [T_I32], true, 16, "hello"), "i(*i)", @@host_i_ptr_i)
    if (run != -1) {
        let r = call_ptr_len(t, rt, run, 0u, 5u)
        is_ok(t, r._0, "run(0, 5)")
        equal(t, r._1, -1, "pointer 0 is m3ApiIsNullPtr")
        equal(t, g_lastPtr, 0, "the NULL offset reached the raw function")
        equal_str(t, m3ApiReadString(rt, 16, 5), "hello", "nothing was written")
    }
    m3_FreeRuntime(rt)
}


def test_mem_check_traps(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    let run = link_run(t, rt, import_module([T_I32, T_I32], [T_I32], true, 16, "hello"), "i(*i)", @@host_i_ptr_i)
    if (run != -1) {
        let inBounds = call_ptr_len(t, rt, run, 65531u, 5u)
        is_ok(t, inBounds._0, "the last 5 bytes are in bounds")
        equal(t, inBounds._1, 0, "zeroed memory sums to 0")
        let past = call_ptr_len(t, rt, run, 65532u, 5u)
        is_err(t, past._0, m3Err_trapOutOfBoundsMemoryAccess, "one byte past the end traps with C's string")
        let high = call_ptr_len(t, rt, run, 0xffffffffu, 1u)
        is_err(t, high._0, m3Err_trapOutOfBoundsMemoryAccess, "offset 0xffffffff traps")
        equal(t, g_lastPtr, -1, "offset 0xffffffff is the int -1")
        let empty = call_ptr_len(t, rt, run, 65536u, 0u)
        is_ok(t, empty._0, "len 0 at the end of memory is in bounds (C's rule)")
    }
    m3_FreeRuntime(rt)
}


def test_frame_ii_i(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    reset_seen()
    let run = link_run(t, rt, import_module([T_I32], [T_I32, T_I32], false, 0, ""), "ii(i)", @@host_ii_i)
    if (run != -1) {
        is_ok(t, m3_Call(rt, run, [m3_bits_from_i32(20)]), "m3_Call run(20)")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, run, 2u, out), "m3_GetResults run(20)")
        equal(t, length(out), 2, "two results")
        if (length(out) == 2) {
            equal(t, m3_bits_to_i32(out[0]), 21, "result 0")
            equal(t, m3_bits_to_i32(out[1]), 40, "result 1")
        }
        equal(t, g_retOff, 0, "result 0 is at sp")
        equal(t, g_ret2Off, 2, "result 1 is at sp + 2")
        equal(t, g_argOff, 4, "the argument follows the two result cells")
        equal(t, g_endOff, 6, "the cursor ends after three cells")
    }
    m3_FreeRuntime(rt)
}


// ============================================================================
// The helpers on a runtime built by hand
// ============================================================================


def test_frame_cursor(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let base = 10
    set_stack_u64(rt, base + 0, 0xdeadbeefcafef00dul)   // cell 0 (its second word is base + 1)
    set_stack_u64(rt, base + 2, 0x1234ul)               // cell 1
    set_stack_u64(rt, base + 4, 0xffffff80ul)           // cell 2
    set_stack_u64(rt, base + 6, 0x7ff00000000000fful)   // cell 3
    var f = m3ApiFrame(base)
    equal(t, f.sp, base, "m3ApiFrame keeps the base")
    equal(t, f.cur, base, "the cursor starts at the base")
    equal(t, m3ApiGetArg_u32(rt, f), 0xcafef00du, "u32 is the low half of the cell")
    equal(t, f.cur, base + 2, "one cell is two slot words")
    equal(t, m3ApiGetArg_u16(rt, f), u16(0x1234), "u16: C reads a uint32_t, then casts")
    equal(t, m3ApiGetArg_u8(rt, f), u8(0x80), "u8: the low byte")
    equal(t, m3ApiGetArg_u64(rt, f), 0x7ff00000000000fful, "u64: the whole cell")
    equal(t, f.cur, base + 8, "four cells read")

    var g = m3ApiFrame(base)
    equal(t, m3ApiGetArg_i32(rt, g), i32(0xcafef00du), "i32 is the low half, signed")
    equal(t, m3ApiGetArg_i64(rt, g), 4660l, "i64 (0x1234)")
    equal(t, m3ApiGetArgMem(rt, g), int(0xffffff80u), "m3ApiGetArgMem: the u32 bits as an int")

    var h = m3ApiFrame(base)
    let r = m3ApiReturnType(h)
    equal(t, r, base, "m3ApiReturnType is the cell at the cursor")
    equal(t, h.cur, base + 2, "and consumes it")
    m3ApiReturn_i32(rt, r, -2)
    equal(t, rt.stack[r], 0xfffffffeul, "m3ApiReturn_i32 writes the word, zero-extended")
    m3ApiReturn_f64(rt, r, 1.5lf)
    equal(t, m3ApiGetArg_f64(rt, m3ApiFrame(base)), 1.5lf, "m3ApiReturn_f64 / m3ApiGetArg_f64")
    m3ApiReturn_f32(rt, r, -0.25)
    equal(t, m3ApiGetArg_f32(rt, m3ApiFrame(base)), -0.25, "m3ApiReturn_f32 / m3ApiGetArg_f32")
    m3ApiReturn_u32(rt, r, 7u)
    m3ApiReturn_i64(rt, r + 2, -1l)
    m3ApiReturn_u64(rt, r + 4, 5ul)
    equal(t, rt.stack[r], 7ul, "m3ApiReturn_u32")
    equal(t, rt.stack[r + 2], 0xfffffffffffffffful, "m3ApiReturn_i64")
    equal(t, rt.stack[r + 4], 5ul, "m3ApiReturn_u64")

    var m = m3ApiFrame(base)
    let m0 = m3ApiMultiValueReturnType(m)
    let m1 = m3ApiMultiValueReturnType(m)
    equal(t, m1 - m0, 2, "multi-value cells are two words apart")
    m3ApiMultiValueReturn_u32(rt, m0, 3u)
    m3ApiMultiValueReturn_i64(rt, m1, -3l)
    equal(t, rt.stack[m0], 3ul, "m3ApiMultiValueReturn_u32")
    equal(t, rt.stack[m1], 0xfffffffffffffffdul, "m3ApiMultiValueReturn_i64")
    m3ApiMultiValueReturn_i32(rt, m0, -1)
    m3ApiMultiValueReturn_u64(rt, m1, 9ul)
    equal(t, rt.stack[m0], 0xfffffffful, "m3ApiMultiValueReturn_i32")
    equal(t, rt.stack[m1], 9ul, "m3ApiMultiValueReturn_u64")
    m3ApiMultiValueReturn_f32(rt, m0, 2.0)
    m3ApiMultiValueReturn_f64(rt, m1, 4.0lf)
    equal(t, stack_f32(rt, m0), 2.0, "m3ApiMultiValueReturn_f32")
    equal(t, stack_f64(rt, m1), 4.0lf, "m3ApiMultiValueReturn_f64")
    m3_FreeRuntime(rt)
}


def test_check_mem_bounds(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    is_ok(t, m3ApiCheckMem(rt, 0, 0ul), "len 0 on an empty memory")
    is_err(t, m3ApiCheckMem(rt, 0, 1ul), m3Err_trapOutOfBoundsMemoryAccess, "one byte of an empty memory")
    resize(rt.mem, 100)
    is_ok(t, m3ApiCheckMem(rt, 0, 100ul), "the whole memory")
    is_ok(t, m3ApiCheckMem(rt, 99, 1ul), "the last byte")
    is_ok(t, m3ApiCheckMem(rt, 100, 0ul), "len 0 at the end")
    is_err(t, m3ApiCheckMem(rt, 1, 100ul), m3Err_trapOutOfBoundsMemoryAccess, "one past the end")
    is_err(t, m3ApiCheckMem(rt, 100, 1ul), m3Err_trapOutOfBoundsMemoryAccess, "at the end")
    is_err(t, m3ApiCheckMem(rt, -1, 0ul), m3Err_trapOutOfBoundsMemoryAccess, "below the memory (C: addr < _mem)")
    is_err(t, m3ApiCheckMem(rt, 0, 0xfffffffffffffffful), m3Err_trapOutOfBoundsMemoryAccess, "a huge length")
    m3_FreeRuntime(rt)
}


def test_offsets_and_null(var t : TestRun; fx : FixtureSource) {
    equal(t, m3ApiOffsetToPtr(16u), 16, "m3ApiOffsetToPtr")
    equal(t, m3ApiPtrToOffset(16), 16u, "m3ApiPtrToOffset")
    equal(t, m3ApiPtrToOffset(m3ApiOffsetToPtr(0x80000000u)), 0x80000000u, "round trip above 2^31")
    check(t, m3ApiIsNullPtr(0), "offset 0 is NULL")
    check(t, !m3ApiIsNullPtr(1), "offset 1 is not NULL")
    check(t, !m3ApiIsNullPtr(m3ApiOffsetToPtr(0xffffffffu)), "offset 0xffffffff is not NULL (C: above _mem)")
}


def test_read_write_mem(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    resize(rt.mem, 32)
    m3ApiWriteMem32(rt, 0, 0x04030201u)
    equal(t, rt.mem[0], 1u8, "WriteMem32 little-endian byte 0")
    equal(t, rt.mem[3], 4u8, "WriteMem32 little-endian byte 3")
    equal(t, m3ApiReadMem32(rt, 0), 0x04030201u, "ReadMem32")
    equal(t, m3ApiReadMem16(rt, 1), u16(0x0302), "ReadMem16 unaligned")
    equal(t, m3ApiReadMem8(rt, 2), 3u8, "ReadMem8")
    m3ApiWriteMem64(rt, 8, 0x0807060504030201ul)
    equal(t, m3ApiReadMem64(rt, 8), 0x0807060504030201ul, "ReadMem64 / WriteMem64")
    equal(t, rt.mem[15], 8u8, "WriteMem64 little-endian byte 7")
    m3ApiWriteMem16(rt, 4, u16(0xbeef))
    equal(t, rt.mem[4], 0xefu8, "WriteMem16 byte 0")
    equal(t, rt.mem[5], 0xbeu8, "WriteMem16 byte 1")
    m3ApiWriteMem8(rt, 6, 0x7fu8)
    equal(t, rt.mem[6], 0x7fu8, "WriteMem8")

    m3ApiWriteString(rt, 16, "abc")
    equal(t, rt.mem[19], 0u8, "WriteString writes no NUL")
    equal(t, m3ApiStrnlen(rt, 16, 100), 3, "strnlen stops at the NUL")
    equal(t, m3ApiStrnlen(rt, 16, 2), 2, "strnlen stops at maxlen")
    m3ApiWriteString(rt, 28, "wxyz")
    equal(t, m3ApiStrnlen(rt, 28, 100), 4, "strnlen stops at the end of memory")
    equal_str(t, m3ApiReadString(rt, 16, 3), "abc", "ReadString")
    let bytes <- m3ApiReadBytes(rt, 28, 4)
    equal(t, length(bytes), 4, "ReadBytes length")
    equal(t, bytes[3], u8('z'), "ReadBytes content")
    m3_FreeRuntime(rt)
}


def test_trap_and_success(var t : TestRun; fx : FixtureSource) {
    is_ok(t, m3ApiSuccess(), "m3ApiSuccess is m3Err_none")
    is_err(t, m3ApiTrap(m3Err_trapExit), m3Err_trapExit, "m3ApiTrap passes its value")
}


def public run_tests_m3_api_defs(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_frame_i_ii")
    test_frame_i_ii(t, fx)
    begin_test(t, "test_frame_v_i")
    test_frame_v_i(t, fx)
    begin_test(t, "test_frame_I_IF")
    test_frame_I_IF(t, fx)
    begin_test(t, "test_mem_arg_i_ptr_i")
    test_mem_arg_i_ptr_i(t, fx)
    begin_test(t, "test_mem_null_ptr")
    test_mem_null_ptr(t, fx)
    begin_test(t, "test_mem_check_traps")
    test_mem_check_traps(t, fx)
    begin_test(t, "test_frame_ii_i")
    test_frame_ii_i(t, fx)
    begin_test(t, "test_frame_cursor")
    test_frame_cursor(t, fx)
    begin_test(t, "test_check_mem_bounds")
    test_check_mem_bounds(t, fx)
    begin_test(t, "test_offsets_and_null")
    test_offsets_and_null(t, fx)
    begin_test(t, "test_read_write_mem")
    test_read_write_mem(t, fx)
    begin_test(t, "test_trap_and_success")
    test_trap_and_success(t, fx)
}
