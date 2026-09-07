options gen2
options indenting = 4

// This file declares a module on purpose: under dastest that suppresses the
// [init] functions of required shared modules (daslang 0.6.4 @ 1524b3bf),
// which is exactly the host situation the guard in m3_NewEnvironment covers.
module test_m3_compile

require dastest/testing_boost
require daslib/fio
require ../../source/m3_parse.das


/*
    Component test for m3_compile.das: the operation table.

    C keeps `const M3OpInfo c_operations []` as a static initialiser
    (wasm3c/source/m3_compile.c). The port fills the table in
    init_compile_operation_tables, reached from [init] and from
    m3_NewEnvironment. GetOpInfo must therefore hand out entries whose
    compiler is either a real function or the c_noCompiler sentinel, never a
    null pointer, once an environment exists.
*/


def private null_compiler_count() : int {
    var count = 0
    for (i in range(253)) {
        if (c_operations[i].compiler == null) {
            count++
        }
    }
    return count
}


[test]
def test_operation_table_after_new_environment(t : T?) {
    var env = m3_NewEnvironment()
    t |> success(env != null, "m3_NewEnvironment")
    if (env == null) return

    t |> equal(null_compiler_count(), 0, "entries with a null compiler pointer")

    // i32.lt_u (0x49) has no dedicated compiler in C: NULL, so Compile_Operator runs.
    let ltU = GetOpInfo(uint16(0x49))
    t |> success(ltU != null, "GetOpInfo i32.lt_u")
    if (ltU != null) {
        t |> success(IsNoCompiler(ltU.compiler), "i32.lt_u routes to Compile_Operator")
        t |> success(!IsNoOp(ltU.operations[0]), "i32.lt_u has a register-form operation")
    }

    // call (0x10) has Compile_Call.
    let callInfo = GetOpInfo(uint16(0x10))
    t |> success(callInfo != null, "GetOpInfo call")
    if (callInfo != null) {
        t |> success(callInfo.compiler != null && !IsNoCompiler(callInfo.compiler), "call has a dedicated compiler")
    }

    // Opcodes past the table and unknown prefixes yield no entry, as in C.
    t |> success(GetOpInfo(uint16(0xfd)) == null, "0xfd has no opinfo")
    t |> success(GetOpInfo(uint16(0xfc0c)) == null, "extended 0x0c has no opinfo")

    // Calling the initialiser again must not disturb the table.
    init_compile_operation_tables()
    t |> equal(null_compiler_count(), 0, "table intact after a second initialisation")

    // C: the rows after 0xc4 are DEBUG-only logging entries; the release
    // table is zero-filled up to the 0xfc dispatcher. GetOpInfo hands them
    // out without operations or compiler, exactly like the reserved 0x06.
    let debugRow = GetOpInfo(uint16(0xc5))
    t |> success(debugRow != null && IsNoCompiler(debugRow.compiler) && IsNoOp(debugRow.operations[0]), "0xc5 is empty like a reserved row")
    let lastGap = GetOpInfo(uint16(0xfb))
    t |> success(lastGap != null && IsNoCompiler(lastGap.compiler), "0xfb is empty")
    let extended = GetOpInfo(uint16(0xfc))
    t |> success(extended != null && !IsNoCompiler(extended.compiler), "0xfc dispatches extended opcodes")

    m3_FreeEnvironment(env)
}


// ============================================================================
// CompileFunction over hand-written bodies
// ============================================================================


let FIB32_PATH = "wasm3c/test/lang/fib32.wasm"


struct CompileFixture {
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


// fib32.wasm gives a loaded module whose only function has type (i32) -> i32;
// its body is then replaced by the bytes under test and recompiled.
def private load_fib32(t : T?) : CompileFixture {
    var fx : CompileFixture
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


// C CompileFunction reads the body size first, then the locals, then the
// code; `body` holds exactly what follows the size byte.
def private compile_body(var fx : CompileFixture; var body : array<u8>) : M3Result {
    var wasm : array<u8>
    wasm |> push(u8(length(body)))
    wasm |> push_from(body)
    fx.fib.wasm = unsafe(addr(wasm[0]))
    fx.fib.wasmEnd = unsafe(reinterpret<bytes_t>(intptr(fx.fib.wasm) + u64(long_length(wasm))))
    fx.fib.compiled = null
    return CompileFunction(fx.fib)
}


def private free_fixture(var fx : CompileFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


[test]
def test_compile_negative_i32_constants_keep_the_c_slot_behaviour(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // i32.const -1; drop; i32.const -1; drop; local.get 0; end
    // C promotes the i32 -1 to the u64 PushConst parameter by sign extension,
    // so the constant-slot search never matches it against the stored u32:
    // two slots, numConstantBytes = 2 * sizeof (m3slot_t).
    var negative <- [u8(0x00), u8(0x41), u8(0x7f), u8(0x1a), u8(0x41), u8(0x7f), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    t |> equal(compile_body(fx, negative), m3Err_none, "compile negative constants")
    t |> equal(int(fx.fib.numConstantBytes), 8, "two constant slots for two -1 (C quirk)")

    // i32.const 1 twice: the search matches and the slot is shared.
    var positive <- [u8(0x00), u8(0x41), u8(0x01), u8(0x1a), u8(0x41), u8(0x01), u8(0x1a), u8(0x20), u8(0x00), u8(0x0b)]
    t |> equal(compile_body(fx, positive), m3Err_none, "compile positive constants")
    t |> equal(int(fx.fib.numConstantBytes), 4, "one constant slot for two 1")

    free_fixture(fx)
}


// C CopyStackTopToSlot narrows the i16 GetStackTopIndex result to u16:
// `CopyStackIndexToSlot (o, i_destSlot, (u16) stackTop)`. On a polymorphic
// stack the top index is -1 and the cast makes it 65535, so every index helper
// reads it as out of range. Both bodies below reach that path; without the
// narrowing the port indexed typeStack[-1] and aborted the compilation.
[test]
def test_compile_stack_top_after_unreachable(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // unreachable; local.set 0; local.get 0; end -> Compile_SetLocal takes the
    // CopyStackTopToSlot branch (the local is not referenced in this block).
    var setLocal <- [u8(0x00), u8(0x00), u8(0x21), u8(0x00), u8(0x20), u8(0x00), u8(0x0b)]
    t |> equal(compile_body(fx, setLocal), m3Err_none, "local.set after unreachable")

    // unreachable; call 0; end -> the argument copy in CompileCallArgsAndReturn.
    var call <- [u8(0x00), u8(0x00), u8(0x10), u8(0x00), u8(0x0b)]
    t |> equal(compile_body(fx, call), m3Err_none, "call after unreachable")

    free_fixture(fx)
}


[test]
def test_compile_rejects_reserved_and_unknown_opcodes(t : T?) {
    var fx = load_fib32(t)
    if (fx.fib == null) return

    // Each body first pushes local 0 so the dynamic stack is not empty when the
    // bad opcode is compiled (the port's d_m3Assert is always on, unlike C's).

    // 0x06 is a reserved row: GetOpInfo finds it, no compiler, Compile_Operator
    // finds no operation. C: ErrorCompile ("no operation found for opcode", ...).
    var reserved <- [u8(0x00), u8(0x20), u8(0x00), u8(0x06), u8(0x0b)]
    t |> equal(compile_body(fx, reserved), "no operation found for opcode", "reserved 0x06")

    // 0xc5 is one of the DEBUG-only rows in C and must behave like 0x06.
    var debugOnly <- [u8(0x00), u8(0x20), u8(0x00), u8(0xc5), u8(0x0b)]
    t |> equal(compile_body(fx, debugOnly), "no operation found for opcode", "DEBUG-only 0xc5")

    // 0xfd is past the table: GetOpInfo returns NULL. C: m3Err_unknownOpcode.
    var unknown <- [u8(0x00), u8(0x20), u8(0x00), u8(0xfd), u8(0x0b)]
    t |> equal(compile_body(fx, unknown), m3Err_unknownOpcode, "unknown 0xfd")

    free_fixture(fx)
}
