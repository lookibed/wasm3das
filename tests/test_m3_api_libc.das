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
    Component test for m3_api_libc.das (C m3_api_libc.c): the spectest half
    first, then the libc half.

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


/*
    The libc half.

        (module
          (import "env" "_memset"  (func $memset  (param i32 i32 i32) (result i32)))
          (import "env" "_memmove" (func $memmove (param i32 i32 i32) (result i32)))
          (import "env" "_abort"   (func $abort))
          (import "env" "_exit"    (func $exit (param i32)))
          (memory (export "memory") 1)
          (func (export "do_memset")  (param i32 i32 i32) (result i32)
            (call $memset  (local.get 0) (local.get 1) (local.get 2)))
          (func (export "do_memmove") (param i32 i32 i32) (result i32)
            (call $memmove (local.get 0) (local.get 1) (local.get 2)))
          (func (export "do_abort") (call $abort))
          (func (export "do_exit") (param i32) (call $exit (local.get 0))))

    Sections in the order m3_ParseModule enforces: 1 type, 2 import,
    3 function, 5 memory, 7 export, 10 code. The memory is what the
    m3ApiGetArgMem / m3ApiCheckMem family needs: without it m3_GetMemorySize
    is zero and every access traps.
*/
let LIBC_WASM = [
    0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8,
    // type: 0 = (i32,i32,i32)->(i32), 1 = ()->(), 2 = (i32)->()
    0x01u8, 0x0fu8, 0x03u8,
    0x60u8, 0x03u8, 0x7fu8, 0x7fu8, 0x7fu8, 0x01u8, 0x7fu8,
    0x60u8, 0x00u8, 0x00u8,
    0x60u8, 0x01u8, 0x7fu8, 0x00u8,
    // import: env._memset, env._memmove, env._abort, env._exit
    0x02u8, 0x37u8, 0x04u8,
    0x03u8, 0x65u8, 0x6eu8, 0x76u8,
    0x07u8, 0x5fu8, 0x6du8, 0x65u8, 0x6du8, 0x73u8, 0x65u8, 0x74u8,
    0x00u8, 0x00u8,
    0x03u8, 0x65u8, 0x6eu8, 0x76u8,
    0x08u8, 0x5fu8, 0x6du8, 0x65u8, 0x6du8, 0x6du8, 0x6fu8, 0x76u8, 0x65u8,
    0x00u8, 0x00u8,
    0x03u8, 0x65u8, 0x6eu8, 0x76u8,
    0x06u8, 0x5fu8, 0x61u8, 0x62u8, 0x6fu8, 0x72u8, 0x74u8,
    0x00u8, 0x01u8,
    0x03u8, 0x65u8, 0x6eu8, 0x76u8,
    0x05u8, 0x5fu8, 0x65u8, 0x78u8, 0x69u8, 0x74u8,
    0x00u8, 0x02u8,
    // function: four local functions of types 0, 0, 1, 2
    0x03u8, 0x05u8, 0x04u8, 0x00u8, 0x00u8, 0x01u8, 0x02u8,
    // memory: one page, no maximum
    0x05u8, 0x03u8, 0x01u8, 0x00u8, 0x01u8,
    // export: memory 0, then functions 4..7
    0x07u8, 0x38u8, 0x05u8,
    0x06u8, 0x6du8, 0x65u8, 0x6du8, 0x6fu8, 0x72u8, 0x79u8, 0x02u8, 0x00u8,
    0x09u8, 0x64u8, 0x6fu8, 0x5fu8, 0x6du8, 0x65u8, 0x6du8, 0x73u8, 0x65u8, 0x74u8, 0x00u8, 0x04u8,
    0x0au8, 0x64u8, 0x6fu8, 0x5fu8, 0x6du8, 0x65u8, 0x6du8, 0x6du8, 0x6fu8, 0x76u8, 0x65u8, 0x00u8, 0x05u8,
    0x08u8, 0x64u8, 0x6fu8, 0x5fu8, 0x61u8, 0x62u8, 0x6fu8, 0x72u8, 0x74u8, 0x00u8, 0x06u8,
    0x07u8, 0x64u8, 0x6fu8, 0x5fu8, 0x65u8, 0x78u8, 0x69u8, 0x74u8, 0x00u8, 0x07u8,
    // code
    0x0au8, 0x23u8, 0x04u8,
    0x0au8, 0x00u8, 0x20u8, 0x00u8, 0x20u8, 0x01u8, 0x20u8, 0x02u8, 0x10u8, 0x00u8, 0x0bu8,
    0x0au8, 0x00u8, 0x20u8, 0x00u8, 0x20u8, 0x01u8, 0x20u8, 0x02u8, 0x10u8, 0x01u8, 0x0bu8,
    0x04u8, 0x00u8, 0x10u8, 0x02u8, 0x0bu8,
    0x06u8, 0x00u8, 0x20u8, 0x00u8, 0x10u8, 0x03u8, 0x0bu8
]


def private libc_module_bytes() : array<u8> {
    var bytes : array<u8>
    bytes |> push_from(LIBC_WASM)
    return <- bytes
}


// Parse, load and link the libc fixture. On success fx._module is not null.
def private new_libc_fixture(t : T?; var bytes : array<u8>) : SpecTestFixture {
    var env = m3_NewEnvironment()
    var fx = SpecTestFixture(env = env, runtime = m3_NewRuntime(env, 64u * 1024u, null))
    if (m3_ParseModule(fx.env, fx._module, unsafe(addr(bytes[0])), u32(length(bytes))) != m3Err_none) {
        fx._module = null
        t |> success(false, "libc fixture parses")
        return fx
    }
    t |> equal(m3_LoadModule(fx.runtime, fx._module), m3Err_none, "m3_LoadModule")
    t |> equal(m3_LinkLibC(fx._module), m3Err_none, "m3_LinkLibC")
    return fx
}


def private mem_base(var fx : SpecTestFixture; var size : u32&) : u8? {
    return m3_GetMemory(fx.runtime, size, 0u)
}


def private call_i32x3(t : T?; var fx : SpecTestFixture; name : string; a : i32; b : i32; c : i32; var o_result : i32&) : M3Result {
    var func : IM3Function
    let found = m3_FindFunction(func, fx.runtime, name)
    if (found != m3Err_none) {
        t |> success(false, "m3_FindFunction {name}")
        return found
    }

    var args : array<M3TaggedValue>
    args |> resize(3)
    args[0]._type = M3ValueType.c_m3Type_i32
    args[1]._type = M3ValueType.c_m3Type_i32
    args[2]._type = M3ValueType.c_m3Type_i32
    tagged_set_i32(args[0], a)
    tagged_set_i32(args[1], b)
    tagged_set_i32(args[2], c)

    let result = m3_CallV(func, args)
    if (result != m3Err_none) { return result }

    var rets : array<M3TaggedValue>
    let got = m3_GetResultsV(func, rets)
    if (got == m3Err_none && length(rets) == 1) {
        o_result = tagged_get_i32(rets[0])
    }
    return got
}


// C m3_LinkLibC wraps every m3_LinkRawFunction in SuppressLookupFailure, so a
// module importing only four of the eight env names links cleanly.
[test]
def test_link_libc_binds_known_imports(t : T?) {
    var bytes <- libc_module_bytes()
    var fx = new_libc_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    t |> equal(fx._module.numFuncImports, 4u, "four function imports")
    for (i in 0u..fx._module.numFuncImports) {
        var f : IM3Function
        unsafe { f = addr(fx._module.functions[i]) }
        t |> success(f.compiled != null, "env.{f.import.fieldUtf8} linked")
    }

    free_fixture(fx)
}


// C m3_libc_memset returns m3ApiPtrToOffset(memset(...)), i.e. the destination
// offset, and fills i_size bytes with (unsigned char) i_value.
[test]
def test_libc_memset_fills_linear_memory(t : T?) {
    var bytes <- libc_module_bytes()
    var fx = new_libc_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var size = 0u
    let mem = mem_base(fx, size)
    t |> success(mem != null, "linear memory is allocated")
    t |> equal(size, 65536u, "one page of linear memory")

    var ret = 0
    t |> equal(call_i32x3(t, fx, "do_memset", 32, int(0xab), 4, ret), m3Err_none, "do_memset(32, 0xab, 4)")
    t |> equal(ret, 32, "memset returns the destination offset")
    unsafe {
        t |> equal(mem[31], 0x00u8, "the byte before the region is untouched")
        t |> equal(mem[32], 0xabu8, "memset byte 0")
        t |> equal(mem[35], 0xabu8, "memset byte 3")
        t |> equal(mem[36], 0x00u8, "the byte after the region is untouched")
    }

    free_fixture(fx)
}


// C m3_libc_memmove copies overlap-safe and returns the destination offset.
[test]
def test_libc_memmove_copies_linear_memory(t : T?) {
    var bytes <- libc_module_bytes()
    var fx = new_libc_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var size = 0u
    var mem = mem_base(fx, size)
    if (mem == null) {
        free_fixture(fx)
        return
    }
    unsafe {
        for (i in 0 .. 8) { mem[16 + i] = u8(i + 1) }
    }

    var ret = 0
    // disjoint ranges
    t |> equal(call_i32x3(t, fx, "do_memmove", 40, 16, 8, ret), m3Err_none, "do_memmove(40, 16, 8)")
    t |> equal(ret, 40, "memmove returns the destination offset")
    unsafe {
        var ok = true
        for (i in 0 .. 8) { ok = ok && mem[40 + i] == u8(i + 1) }
        t |> success(ok, "disjoint memmove copied 1..8")
    }

    // overlapping, destination above the source: a naive forward copy would
    // smear the first byte over the whole region.
    t |> equal(call_i32x3(t, fx, "do_memmove", 18, 16, 8, ret), m3Err_none, "do_memmove(18, 16, 8)")
    unsafe {
        var ok = true
        for (i in 0 .. 8) { ok = ok && mem[18 + i] == u8(i + 1) }
        t |> success(ok, "overlapping memmove up copied 1..8")
    }

    // overlapping, destination below the source
    t |> equal(call_i32x3(t, fx, "do_memmove", 16, 18, 8, ret), m3Err_none, "do_memmove(16, 18, 8)")
    unsafe {
        var ok = true
        for (i in 0 .. 8) { ok = ok && mem[16 + i] == u8(i + 1) }
        t |> success(ok, "overlapping memmove down copied 1..8")
    }

    free_fixture(fx)
}


// C m3ApiCheckMem traps with m3Err_trapOutOfBoundsMemoryAccess when the region
// leaves linear memory.
[test]
def test_libc_memset_out_of_bounds_traps(t : T?) {
    var bytes <- libc_module_bytes()
    var fx = new_libc_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var ret = 0
    t |> equal(call_i32x3(t, fx, "do_memset", 65530, 0, 100, ret),
               m3Err_trapOutOfBoundsMemoryAccess, "do_memset past the end of memory traps")

    free_fixture(fx)
}


// C m3_libc_abort is m3ApiTrap(m3Err_trapAbort), m3_libc_exit reads its unused
// int32_t code and then m3ApiTrap(m3Err_trapExit).
[test]
def test_libc_abort_and_exit_trap(t : T?) {
    var bytes <- libc_module_bytes()
    var fx = new_libc_fixture(t, bytes)
    if (fx._module == null) {
        free_fixture(fx)
        return
    }

    var abort_fn : IM3Function
    t |> equal(m3_FindFunction(abort_fn, fx.runtime, "do_abort"), m3Err_none, "m3_FindFunction do_abort")
    if (abort_fn != null) {
        let no_args : array<M3TaggedValue>
        t |> equal(m3_CallV(abort_fn, no_args), m3Err_trapAbort, "do_abort traps with m3Err_trapAbort")
    }

    var exit_fn : IM3Function
    t |> equal(m3_FindFunction(exit_fn, fx.runtime, "do_exit"), m3Err_none, "m3_FindFunction do_exit")
    if (exit_fn != null) {
        var args : array<M3TaggedValue>
        args |> resize(1)
        args[0]._type = M3ValueType.c_m3Type_i32
        tagged_set_i32(args[0], 3)
        t |> equal(m3_CallV(exit_fn, args), m3Err_trapExit, "do_exit(3) traps with m3Err_trapExit")
    }

    free_fixture(fx)
}
