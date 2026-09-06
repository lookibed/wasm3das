options gen2
options indenting = 4
// The call arm below executes wasm, and the executor nests one Daslang frame
// per executed op (no M3_MUSTTAIL); options stack counts only in the program
// root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/test_m3_env.das: under dastest a test
// file that names its module does not run the [init] functions of required
// shared modules.

require dastest/testing_boost
require ../source/m3_api_libc.das
require ../source/m3_parse.das


/*
    Component test for the spectest half of m3_api_libc.das (C m3_api_libc.c).

    The fixture is assembled here rather than read from disk so the test runs
    in CI: a module that imports two of the seven functions m3_LinkSpecTest
    knows plus one it does not, and exports a function calling the linked one.

        (module
          (import "spectest" "print_i32" (func $p32 (param i32)))
          (import "spectest" "print_f64" (func $p64 (param f64)))
          (import "spectest" "print_v128" (func $pv (param i32)))
          (func (export "run") (param i32) (result i32)
            (call $p32 (local.get 0))
            (local.get 0)))

    Sections in the order m3_ParseModule enforces: 1 type, 2 import,
    3 function, 7 export, 10 code.
*/
let SPECTEST_WASM = [
    0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
    // type: 0 = (i32)->(), 1 = (f64)->(), 2 = (i32)->(i32)
    0x01u8, 0x0eu8, 0x03u8,
    0x60u8, 0x01u8, 0x7fu8, 0x00u8,
    0x60u8, 0x01u8, 0x7cu8, 0x00u8,
    0x60u8, 0x01u8, 0x7fu8, 0x01u8, 0x7fu8,
    // import: three spectest functions
    0x02u8, 0x41u8, 0x03u8,
    0x08u8, 0x73u8, 0x70u8, 0x65u8, 0x63u8, 0x74u8, 0x65u8, 0x73u8, 0x74u8,
    0x09u8, 0x70u8, 0x72u8, 0x69u8, 0x6eu8, 0x74u8, 0x5fu8, 0x69u8, 0x33u8, 0x32u8,
    0x00u8, 0x00u8,
    0x08u8, 0x73u8, 0x70u8, 0x65u8, 0x63u8, 0x74u8, 0x65u8, 0x73u8, 0x74u8,
    0x09u8, 0x70u8, 0x72u8, 0x69u8, 0x6eu8, 0x74u8, 0x5fu8, 0x66u8, 0x36u8, 0x34u8,
    0x00u8, 0x01u8,
    0x08u8, 0x73u8, 0x70u8, 0x65u8, 0x63u8, 0x74u8, 0x65u8, 0x73u8, 0x74u8,
    0x0au8, 0x70u8, 0x72u8, 0x69u8, 0x6eu8, 0x74u8, 0x5fu8, 0x76u8, 0x31u8, 0x32u8, 0x38u8,
    0x00u8, 0x00u8,
    // function: one local function of type 2
    0x03u8, 0x02u8, 0x01u8, 0x02u8,
    // export: "run" -> func 3
    0x07u8, 0x07u8, 0x01u8,
    0x03u8, 0x72u8, 0x75u8, 0x6eu8,
    0x00u8, 0x03u8,
    // code: local.get 0; call 0; local.get 0; end
    0x0au8, 0x0au8, 0x01u8, 0x08u8,
    0x00u8, 0x20u8, 0x00u8, 0x10u8, 0x00u8, 0x20u8, 0x00u8, 0x0bu8
]


struct SpecTestFixture {
    env : IM3Environment
    runtime : IM3Runtime
    _module : IM3Module
}


def private module_bytes() : array<u8> {
    var bytes : array<u8>
    bytes |> push_from(SPECTEST_WASM)
    return <- bytes
}


// The module bytes must outlive the module: m3_ParseModule stores wasm
// pointers into the caller's buffer.
def private new_fixture(var bytes : array<u8>) : SpecTestFixture {
    var env = m3_NewEnvironment()
    var fx = SpecTestFixture(env = env, runtime = m3_NewRuntime(env, 64u * 1024u, null))
    if (m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes))) != m3Err_none) {
        fx._module = null
    }
    return fx
}


def private free_fixture(var fx : SpecTestFixture) {
    m3_FreeRuntime(fx.runtime)
    m3_FreeEnvironment(fx.env)
}


def private import_compiled(var fx : SpecTestFixture; field : string) : bool {
    for (i in 0u..fx._module.numFuncImports) {
        var f : IM3Function
        unsafe { f = addr(fx._module.functions[i]) }
        if (f.import.moduleUtf8 == "spectest" && f.import.fieldUtf8 == field) {
            return f.compiled != null
        }
    }
    return false
}


// C m3_LinkSpecTest wraps every m3_LinkRawFunction in SuppressLookupFailure,
// so a module that imports only some of the seven names still links cleanly,
// and a spectest import that is not in the C list stays unbound.
[test]
def test_link_spec_test_binds_known_imports(t : T?) {
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    t |> success(fx._module != null, "spectest fixture parses")
    if (fx._module == null) {
        free_fixture(fx)
        return
    }
    t |> equal(fx._module.numFuncImports, 3u, "three function imports")
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_none, "m3_LoadModule")

    t |> equal(m3_LinkSpecTest(fx._module), m3Err_none, "m3_LinkSpecTest")
    t |> success(import_compiled(fx, "print_i32"), "spectest.print_i32 linked")
    t |> success(import_compiled(fx, "print_f64"), "spectest.print_f64 linked")
    // spectest.print_v128 is not in the C m3_LinkSpecTest list; the lookup
    // failure is suppressed and the import stays without compiled code.
    t |> success(!import_compiled(fx, "print_v128"), "unknown spectest name stays unbound")

    free_fixture(fx)
}


// C FindAndLinkFunction throws m3Err_moduleNotLinked before m3_LoadModule, and
// m3_LinkSpecTest does not suppress that result.
[test]
def test_link_spec_test_before_load(t : T?) {
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }
    t |> equal(m3_LinkSpecTest(fx._module), m3Err_moduleNotLinked, "m3_LinkSpecTest before load")
    m3_FreeModule(fx._module)
    fx._module = null
    free_fixture(fx)
}


// m3_spectest_dummy returns m3Err_none and touches no stack slot, so a wasm
// function calling it runs to completion (C m3ApiSuccess).
[test]
def test_spectest_dummy_is_callable_from_wasm(t : T?) {
    var bytes <- module_bytes()
    var fx = new_fixture(bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_none, "m3_LoadModule")
    t |> equal(m3_LinkSpecTest(fx._module), m3Err_none, "m3_LinkSpecTest")

    var run : IM3Function
    t |> equal(m3_FindFunction(run, fx.runtime, "run"), m3Err_none, "m3_FindFunction run")
    if (run != null) {
        var args : array<M3TaggedValue>
        args |> resize(1)
        args[0]._type = M3ValueType.c_m3Type_i32
        tagged_set_i32(args[0], 7)
        t |> equal(m3_CallV(run, args), m3Err_none, "m3_CallV run(7)")

        var rets : array<M3TaggedValue>
        t |> equal(m3_GetResultsV(run, rets), m3Err_none, "m3_GetResultsV")
        if (length(rets) == 1) {
            t |> equal(tagged_get_i32(rets[0]), 7, "run(7) after the dummy import")
        }
    }

    free_fixture(fx)
}
