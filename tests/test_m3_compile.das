options gen2
options indenting = 4

// This file declares a module on purpose: under dastest that suppresses the
// [init] functions of required shared modules (daslang 0.6.4 @ 1524b3bf),
// which is exactly the host situation the guard in m3_NewEnvironment covers.
module test_m3_compile

require dastest/testing_boost
require ../source/m3_env.das


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

    m3_FreeEnvironment(env)
}
