options gen2
options indenting = 4

module test_m3_api_libc shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_api_libc
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core
require strings

/*
    test_m3_api_libc.das: Eden counterpart of
    .upstream/tests/integration/test_m3_api_libc.das.

    Coverage of the upstream [test]s (8 of 8 ported), on the same
    hand-assembled modules (SPECTEST_WASM, LIBC_WASM) and with the same
    expectations. Eden: the runtime owns the module (m3_ParseModule takes
    it and returns a handle, -1 when parsing fails), m3_LinkSpecTest /
    m3_LinkLibC take the runtime first, "compiled" is an index into rt.code
    (-1 = not compiled), the linear memory is rt.mem from the index
    m3_GetMemory returns:
      - test_link_spec_test_binds_known_imports
      - test_link_spec_test_before_load
      - test_spectest_dummy_is_callable_from_wasm
      - test_link_libc_binds_known_imports
      - test_libc_memset_fills_linear_memory
      - test_libc_memmove_copies_linear_memory
      - test_libc_memset_out_of_bounds_traps
      - test_libc_abort_and_exit_trap
    Tests added for the Eden shape (no upstream counterpart), on a module
    built by libc_all_module that imports all eight env functions
    m3_LinkLibC knows and exports one wrapper per import ("w_<field>") that
    passes its parameters on:
      - test_link_libc_links_all_imports: every import is compiled after
        m3_LinkLibC and each wrapper reaches its host function (_debug,
        _memset, _memmove, _memcpy, clock_ms, printf run; _abort and _exit
        trap with C's strings).
      - test_debug_writes_bytes: `_debug` appends rt.mem bytes to
        rt.stdoutBuffer byte for byte (a NUL inside survives, DESIGN 4.7c)
        and returns the size.
      - test_printf_formats: every conversion C's minimal printf knows (%c,
        %d, %x, %s, NULL %s) and what it does with the others (%%, %u, %f,
        %lld, a lone '%' before the NUL) lands byte-exact in
        rt.stdoutBuffer, with C's return value.
      - test_printf_null_and_bounds: a NULL format returns 0 and writes
        nothing; an argument list, a %s string and an unterminated format
        at the end of memory trap with m3Err_trapOutOfBoundsMemoryAccess,
        and the bytes written before the trap stay (C never flushes, but
        the bytes are in the stream).
      - test_memcpy_memset_out_of_bounds: _memset, _memcpy (destination and
        source) and _memmove past the end of memory, and at the guest
        pointer 0xffffffff, trap with C's string and leave memory as it was.
      - test_clock_ms: two calls give non-decreasing milliseconds.
*/


// ============================================================================
// The upstream fixtures (the bytes are the upstream test's)
// ============================================================================


/*
    (module
      (import "spectest" "print_i32" (func $p32 (param i32)))
      (import "spectest" "print_f64" (func $p64 (param f64)))
      (import "spectest" "print_v128" (func $pv (param i32)))
      (func (export "run") (param i32) (result i32)
        (call $p32 (local.get 0))
        (local.get 0)))
*/
let private SPECTEST_WASM = [
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


/*
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
*/
let private LIBC_WASM = [
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


def private module_bytes() : array<u8> {
    var bytes : array<u8>
    for (b in SPECTEST_WASM) {
        push(bytes, b)
    }
    return <- bytes
}


def private libc_module_bytes() : array<u8> {
    var bytes : array<u8>
    for (b in LIBC_WASM) {
        push(bytes, b)
    }
    return <- bytes
}


// a fresh runtime of 64 KiB of stack
def private new_runtime() : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, 64u * 1024u, -1)
    return <- rt
}


// Eden: the upstream new_fixture; the module handle, -1 when parsing fails
def private parse_fixture(var rt : M3Runtime; bytes : array<u8>) : IM3Module {
    let parsed = m3_ParseModule(rt, bytes)
    if (parsed._0 != m3Err_none) {
        return -1
    }
    return parsed._1
}


// Eden: upstream import_compiled; `compiled` is an index into rt.code
def private import_compiled(rt : M3Runtime; m : IM3Module; field : string) : bool {
    for (i in range(int(rt.modules[m].numFuncImports))) {
        let f = rt.modules[m].functions[i]
        if (rt.functions[f].import.moduleUtf8 == "spectest" && rt.functions[f].import.fieldUtf8 == field) {
            return rt.functions[f].compiled != -1
        }
    }
    return false
}


// Parse, load and link the libc fixture. Eden: the module handle, -1 when
// parsing fails (the upstream new_libc_fixture)
def private new_libc_fixture(var t : TestRun; var rt : M3Runtime; bytes : array<u8>) : IM3Module {
    let m = parse_fixture(rt, bytes)
    if (m == -1) {
        check(t, false, "libc fixture parses")
        return -1
    }
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule")
    is_ok(t, m3_LinkLibC(rt, m), "m3_LinkLibC")
    return m
}


// Eden: the upstream call_i32x3 through m3_CallV / m3_GetResultsV
def private call_i32x3(var t : TestRun; var rt : M3Runtime; name : string; a : int; b : int; c : int; var o_result : int&) : M3Result {
    var func : IM3Function = -1
    let found = m3_FindFunction(rt, func, name)
    if (found != m3Err_none) {
        check(t, false, "m3_FindFunction {name}")
        return found
    }

    var args : array<M3TaggedValue>
    for (v in [a, b, c]) {
        var arg = M3TaggedValue(_type = M3ValueType.c_m3Type_i32)
        tagged_set_i32(arg, v)
        push(args, arg)
    }

    let result = m3_CallV(rt, func, args)
    if (result != m3Err_none) {
        return result
    }

    var rets : array<M3TaggedValue>
    let got = m3_GetResultsV(rt, func, rets)
    if (got == m3Err_none && length(rets) == 1) {
        o_result = tagged_get_i32(rets[0])
    }
    return got
}


// ============================================================================
// The upstream tests
// ============================================================================


// C m3_LinkSpecTest wraps every m3_LinkRawFunction in SuppressLookupFailure,
// so a module that imports only some of the seven names still links cleanly,
// and a spectest import that is not in the C list stays unbound.
def test_link_spec_test_binds_known_imports(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- module_bytes()
    let m = parse_fixture(rt, bytes)
    check(t, m != -1, "spectest fixture parses")
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    equal(t, rt.modules[m].numFuncImports, 3u, "three function imports")
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule")

    is_ok(t, m3_LinkSpecTest(rt, m), "m3_LinkSpecTest")
    check(t, import_compiled(rt, m, "print_i32"), "spectest.print_i32 linked")
    check(t, import_compiled(rt, m, "print_f64"), "spectest.print_f64 linked")
    // spectest.print_v128 is not in the C m3_LinkSpecTest list; the lookup
    // failure is suppressed and the import stays without compiled code.
    check(t, !import_compiled(rt, m, "print_v128"), "unknown spectest name stays unbound")

    m3_FreeRuntime(rt)
}


// C FindAndLinkFunction throws m3Err_moduleNotLinked before m3_LoadModule, and
// m3_LinkSpecTest does not suppress that result.
def test_link_spec_test_before_load(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- module_bytes()
    let m = parse_fixture(rt, bytes)
    if (m == -1) {
        check(t, false, "spectest fixture parses")
        m3_FreeRuntime(rt)
        return
    }
    is_err(t, m3_LinkSpecTest(rt, m), m3Err_moduleNotLinked, "m3_LinkSpecTest before load")
    m3_FreeModule(rt, m)
    m3_FreeRuntime(rt)
}


// m3_spectest_dummy returns m3Err_none and touches no stack slot, so a wasm
// function calling it runs to completion (C m3ApiSuccess).
def test_spectest_dummy_is_callable_from_wasm(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- module_bytes()
    let m = parse_fixture(rt, bytes)
    if (m == -1) {
        check(t, false, "spectest fixture parses")
        m3_FreeRuntime(rt)
        return
    }
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule")
    is_ok(t, m3_LinkSpecTest(rt, m), "m3_LinkSpecTest")

    var run : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, run, "run"), "m3_FindFunction run")
    if (run != -1) {
        var args : array<M3TaggedValue>
        var arg = M3TaggedValue(_type = M3ValueType.c_m3Type_i32)
        tagged_set_i32(arg, 7)
        push(args, arg)
        is_ok(t, m3_CallV(rt, run, args), "m3_CallV run(7)")

        var rets : array<M3TaggedValue>
        is_ok(t, m3_GetResultsV(rt, run, rets), "m3_GetResultsV")
        equal(t, length(rets), 1, "one result")
        if (length(rets) == 1) {
            equal(t, tagged_get_i32(rets[0]), 7, "run(7) after the dummy import")
        }
    }

    m3_FreeRuntime(rt)
}


// C m3_LinkLibC wraps every m3_LinkRawFunction in SuppressLookupFailure, so a
// module importing only four of the eight env names links cleanly.
def test_link_libc_binds_known_imports(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- libc_module_bytes()
    let m = new_libc_fixture(t, rt, bytes)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    equal(t, rt.modules[m].numFuncImports, 4u, "four function imports")
    for (i in range(int(rt.modules[m].numFuncImports))) {
        let f = rt.modules[m].functions[i]
        check(t, rt.functions[f].compiled != -1, "env.{rt.functions[f].import.fieldUtf8} linked")
    }

    m3_FreeRuntime(rt)
}


// C m3_libc_memset returns m3ApiPtrToOffset(memset(...)), i.e. the destination
// offset, and fills i_size bytes with (unsigned char) i_value.
def test_libc_memset_fills_linear_memory(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- libc_module_bytes()
    let m = new_libc_fixture(t, rt, bytes)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    var size = 0u
    let mem = m3_GetMemory(rt, size, 0u)
    check(t, mem != -1, "linear memory is allocated")
    equal(t, size, 65536u, "one page of linear memory")

    var ret = 0
    is_ok(t, call_i32x3(t, rt, "do_memset", 32, int(0xab), 4, ret), "do_memset(32, 0xab, 4)")
    equal(t, ret, 32, "memset returns the destination offset")
    if (mem != -1) {
        equal(t, rt.mem[mem + 31], 0x00u8, "the byte before the region is untouched")
        equal(t, rt.mem[mem + 32], 0xabu8, "memset byte 0")
        equal(t, rt.mem[mem + 35], 0xabu8, "memset byte 3")
        equal(t, rt.mem[mem + 36], 0x00u8, "the byte after the region is untouched")
    }

    m3_FreeRuntime(rt)
}


// C m3_libc_memmove copies overlap-safe and returns the destination offset.
def test_libc_memmove_copies_linear_memory(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- libc_module_bytes()
    let m = new_libc_fixture(t, rt, bytes)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    var size = 0u
    let mem = m3_GetMemory(rt, size, 0u)
    if (mem == -1) {
        check(t, false, "linear memory is allocated")
        m3_FreeRuntime(rt)
        return
    }
    for (i in 0 .. 8) {
        rt.mem[mem + 16 + i] = u8(i + 1)
    }

    var ret = 0
    // disjoint ranges
    is_ok(t, call_i32x3(t, rt, "do_memmove", 40, 16, 8, ret), "do_memmove(40, 16, 8)")
    equal(t, ret, 40, "memmove returns the destination offset")
    var ok = true
    for (i in 0 .. 8) {
        ok = ok && rt.mem[mem + 40 + i] == u8(i + 1)
    }
    check(t, ok, "disjoint memmove copied 1..8")

    // overlapping, destination above the source: a naive forward copy would
    // smear the first byte over the whole region.
    is_ok(t, call_i32x3(t, rt, "do_memmove", 18, 16, 8, ret), "do_memmove(18, 16, 8)")
    ok = true
    for (i in 0 .. 8) {
        ok = ok && rt.mem[mem + 18 + i] == u8(i + 1)
    }
    check(t, ok, "overlapping memmove up copied 1..8")

    // overlapping, destination below the source
    is_ok(t, call_i32x3(t, rt, "do_memmove", 16, 18, 8, ret), "do_memmove(16, 18, 8)")
    ok = true
    for (i in 0 .. 8) {
        ok = ok && rt.mem[mem + 16 + i] == u8(i + 1)
    }
    check(t, ok, "overlapping memmove down copied 1..8")

    m3_FreeRuntime(rt)
}


// C m3ApiCheckMem traps with m3Err_trapOutOfBoundsMemoryAccess when the region
// leaves linear memory.
def test_libc_memset_out_of_bounds_traps(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- libc_module_bytes()
    let m = new_libc_fixture(t, rt, bytes)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    var ret = 0
    is_err(t, call_i32x3(t, rt, "do_memset", 65530, 0, 100, ret), m3Err_trapOutOfBoundsMemoryAccess, "do_memset past the end of memory traps")

    m3_FreeRuntime(rt)
}


// C m3_libc_abort is m3ApiTrap(m3Err_trapAbort), m3_libc_exit reads its unused
// int32_t code and then m3ApiTrap(m3Err_trapExit).
def test_libc_abort_and_exit_trap(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let bytes <- libc_module_bytes()
    let m = new_libc_fixture(t, rt, bytes)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    var abort_fn : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, abort_fn, "do_abort"), "m3_FindFunction do_abort")
    if (abort_fn != -1) {
        var no_args : array<M3TaggedValue>
        is_err(t, m3_CallV(rt, abort_fn, no_args), m3Err_trapAbort, "do_abort traps with m3Err_trapAbort")
    }

    var exit_fn : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, exit_fn, "do_exit"), "m3_FindFunction do_exit")
    if (exit_fn != -1) {
        var args : array<M3TaggedValue>
        var arg = M3TaggedValue(_type = M3ValueType.c_m3Type_i32)
        tagged_set_i32(arg, 3)
        push(args, arg)
        is_err(t, m3_CallV(rt, exit_fn, args), m3Err_trapExit, "do_exit(3) traps with m3Err_trapExit")
    }

    m3_FreeRuntime(rt)
}


// ============================================================================
// Eden: a module importing all eight env functions of m3_LinkLibC
// ============================================================================


let private T_I32 = 0x7fu8


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


// the eight env imports of m3_LinkLibC, in C order, with the type index of
// libc_all_module: 0 = (i32,i32)->i32, 1 = (i32,i32,i32)->i32, 2 = ()->(),
// 3 = (i32)->(), 4 = ()->i32
let private LIBC_FIELDS = ["_debug", "_memset", "_memmove", "_memcpy", "_abort", "_exit", "clock_ms", "printf"]
let private LIBC_TYPES = [0, 1, 1, 1, 2, 3, 4, 0]
let private TYPE_PARAMS = [2, 3, 0, 1, 0]
let private TYPE_RESULTS = [1, 1, 0, 0, 1]


/*
    (module
      (import "env" "_debug" (func (param i32 i32) (result i32)))           ;; 0
      (import "env" "_memset" (func (param i32 i32 i32) (result i32)))      ;; 1
      (import "env" "_memmove" (func (param i32 i32 i32) (result i32)))     ;; 2
      (import "env" "_memcpy" (func (param i32 i32 i32) (result i32)))      ;; 3
      (import "env" "_abort" (func))                                        ;; 4
      (import "env" "_exit" (func (param i32)))                             ;; 5
      (import "env" "clock_ms" (func (result i32)))                         ;; 6
      (import "env" "printf" (func (param i32 i32) (result i32)))           ;; 7
      (memory 1)
      (func (export "w_<field k>") <type of import k>
        (call k (local.get 0) ... ))                                        ;; 8 + k
      ...)
*/
def private libc_all_module() : array<u8> {
    var out : array<u8>
    for (b in [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8]) {
        push(out, b)
    }

    var types : array<u8>
    leb(types, uint(length(TYPE_PARAMS)))
    for (np, nr in TYPE_PARAMS, TYPE_RESULTS) {
        push(types, 0x60u8)
        leb(types, uint(np))
        for (j in range(np)) {
            push(types, T_I32)
        }
        leb(types, uint(nr))
        for (j in range(nr)) {
            push(types, T_I32)
        }
    }
    section(out, 1, types)

    var imports : array<u8>
    leb(imports, uint(length(LIBC_FIELDS)))
    for (field, ty in LIBC_FIELDS, LIBC_TYPES) {
        name(imports, "env")
        name(imports, field)
        push(imports, 0x00u8)   // func
        leb(imports, uint(ty))
    }
    section(out, 2, imports)

    var funcs : array<u8>
    leb(funcs, uint(length(LIBC_TYPES)))
    for (ty in LIBC_TYPES) {
        leb(funcs, uint(ty))
    }
    section(out, 3, funcs)

    var mems : array<u8>
    leb(mems, 1u)
    push(mems, 0x00u8)  // limits: min only
    leb(mems, 1u)       // one page
    section(out, 5, mems)

    var exports : array<u8>
    leb(exports, uint(length(LIBC_FIELDS)))
    for (field, k in LIBC_FIELDS, count()) {
        name(exports, "w{field}")
        push(exports, 0x00u8)   // func
        leb(exports, uint(length(LIBC_FIELDS) + k))
    }
    section(out, 7, exports)

    var code : array<u8>
    leb(code, uint(length(LIBC_TYPES)))
    for (ty, k in LIBC_TYPES, count()) {
        var body : array<u8>
        leb(body, 0u)           // no locals
        for (i in range(TYPE_PARAMS[ty])) {
            push(body, 0x20u8)  // local.get i
            leb(body, uint(i))
        }
        push(body, 0x10u8)      // call k
        leb(body, uint(k))
        push(body, 0x0bu8)      // end
        leb(code, uint(length(body)))
        for (b in body) {
            push(code, b)
        }
    }
    section(out, 10, code)
    return <- out
}


// parses, loads and links libc_all_module with m3_LinkLibC; the module
// handle, -1 when a step fails (the failure is recorded)
def private new_all_fixture(var t : TestRun; var rt : M3Runtime) : IM3Module {
    let bytes <- libc_all_module()
    let m = parse_fixture(rt, bytes)
    if (m == -1) {
        check(t, false, "the hand-built libc module parses")
        return -1
    }
    is_ok(t, m3_LoadModule(rt, m), "m3_LoadModule")
    is_ok(t, m3_LinkLibC(rt, m), "m3_LinkLibC")
    return m
}


// calls the export `name` with i32 arguments; the call result and the i32
// result (-999 when there is none)
def private call_w(var t : TestRun; var rt : M3Runtime; name : string; args : array<int>) : tuple<M3Result; int> {
    var fn : IM3Function = -1
    let found = m3_FindFunction(rt, fn, name)
    if (found != m3Err_none) {
        check(t, false, "m3_FindFunction {name}")
        return (found, -999)
    }
    var bits : array<u64>
    for (a in args) {
        push(bits, u64(uint(a)))
    }
    let r = m3_Call(rt, fn, bits)
    var value = -999
    if (r == m3Err_none && m3_GetRetCount(rt, fn) == 1u) {
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, fn, 1u, out), "m3_GetResults {name}")
        if (length(out) == 1) {
            value = m3_bits_to_i32(out[0])
        }
    }
    return (r, value)
}


// writes `text` and a terminating NUL at rt.mem[at ..)
def private put_cstr(var rt : M3Runtime; at : int; text : string) {
    for (i in range(length(text))) {
        rt.mem[at + i] = u8(character_at(text, i))
    }
    rt.mem[at + length(text)] = 0u8
}


// writes the u32 argument list of printf at rt.mem[at ..)
def private put_args(var rt : M3Runtime; at : int; args : array<uint>) {
    for (a, i in args, count()) {
        m3ApiWriteMem32(rt, at + 4 * i, a)
    }
}


// the bytes of an ASCII text
def private text_bytes(text : string) : array<u8> {
    var bytes : array<u8>
    for (i in range(length(text))) {
        push(bytes, u8(character_at(text, i)))
    }
    return <- bytes
}


// rt.stdoutBuffer is exactly `want`, byte for byte
def private stdout_is(var t : TestRun; rt : M3Runtime; want : array<u8>; msg : string) {
    var same = length(rt.stdoutBuffer) == length(want)
    if (same) {
        for (a, b in rt.stdoutBuffer, want) {
            same = same && a == b
        }
    }
    record(t, same, same ? msg : "{msg} (got {rt.stdoutBuffer}, want {want})")
}


// clears rt.stdoutBuffer, runs printf(fmt at FMT_AT, args at ARGS_AT)
let private FMT_AT = 256
let private ARGS_AT = 1024
let private STR_AT = 2048


def private printf_case(var t : TestRun; var rt : M3Runtime; fmt : string; args : array<uint>; want : array<u8>; msg : string) {
    clear(rt.stdoutBuffer)
    put_cstr(rt, FMT_AT, fmt)
    put_args(rt, ARGS_AT, args)
    let r = call_w(t, rt, "wprintf", [FMT_AT, ARGS_AT])
    is_ok(t, r._0, "printf \"{fmt}\" runs ({msg})")
    stdout_is(t, rt, want, "printf \"{fmt}\" output ({msg})")
    equal(t, r._1, length(want), "printf \"{fmt}\" returns the byte count ({msg})")
}


// ============================================================================
// Eden tests
// ============================================================================


def test_link_libc_links_all_imports(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let m = new_all_fixture(t, rt)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    equal(t, rt.modules[m].numFuncImports, 8u, "eight function imports")
    for (i in range(int(rt.modules[m].numFuncImports))) {
        let f = rt.modules[m].functions[i]
        check(t, rt.functions[f].compiled != -1, "env.{rt.functions[f].import.fieldUtf8} linked")
        equal_str(t, rt.functions[f].import.fieldUtf8, LIBC_FIELDS[i], "import {i} is {LIBC_FIELDS[i]}")
    }

    put_cstr(rt, 100, "hi")
    let dbg = call_w(t, rt, "w_debug", [100, 2])
    is_ok(t, dbg._0, "w_debug reaches _debug")
    equal(t, dbg._1, 2, "_debug returns the size")

    let ms = call_w(t, rt, "w_memset", [200, int(0x5a), 3])
    is_ok(t, ms._0, "w_memset reaches _memset")
    equal(t, ms._1, 200, "_memset returns the destination")
    equal(t, rt.mem[202], 0x5au8, "_memset wrote the byte")

    let mm = call_w(t, rt, "w_memmove", [300, 200, 3])
    is_ok(t, mm._0, "w_memmove reaches _memmove")
    equal(t, mm._1, 300, "_memmove returns the destination")
    equal(t, rt.mem[302], 0x5au8, "_memmove copied")

    let mc = call_w(t, rt, "w_memcpy", [400, 300, 3])
    is_ok(t, mc._0, "w_memcpy reaches _memcpy (the memmove alias)")
    equal(t, mc._1, 400, "_memcpy returns the destination")
    equal(t, rt.mem[402], 0x5au8, "_memcpy copied")

    var none : array<int>
    let ck = call_w(t, rt, "wclock_ms", none)
    is_ok(t, ck._0, "wclock_ms reaches clock_ms")
    check(t, ck._1 >= 0, "clock_ms is not negative")

    put_cstr(rt, FMT_AT, "ok")
    let pf = call_w(t, rt, "wprintf", [FMT_AT, ARGS_AT])
    is_ok(t, pf._0, "wprintf reaches printf")
    equal(t, pf._1, 2, "printf returns the byte count")

    is_err(t, call_w(t, rt, "w_abort", none)._0, m3Err_trapAbort, "w_abort traps with C's string")
    is_err(t, call_w(t, rt, "w_exit", [9])._0, m3Err_trapExit, "w_exit traps with C's string")

    var want <- text_bytes("hiok")
    stdout_is(t, rt, want, "_debug and printf wrote to rt.stdoutBuffer")
    m3_FreeRuntime(rt)
}


def test_debug_writes_bytes(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let m = new_all_fixture(t, rt)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    let raw = [0x41u8, 0x00u8, 0xffu8, 0x0au8, 0x42u8]
    for (b, i in raw, count()) {
        rt.mem[500 + i] = b
    }
    let r = call_w(t, rt, "w_debug", [500, 5])
    is_ok(t, r._0, "_debug of 5 bytes")
    equal(t, r._1, 5, "_debug returns i_size")
    var want : array<u8>
    for (b in raw) {
        push(want, b)
    }
    stdout_is(t, rt, want, "_debug bytes, NUL and 0xff included, in rt.stdoutBuffer")

    let z = call_w(t, rt, "w_debug", [500, 0])
    is_ok(t, z._0, "_debug of 0 bytes")
    equal(t, z._1, 0, "_debug of 0 bytes returns 0")
    stdout_is(t, rt, want, "_debug of 0 bytes appends nothing")

    is_err(t, call_w(t, rt, "w_debug", [65534, 3])._0, m3Err_trapOutOfBoundsMemoryAccess, "_debug past the end traps")
    stdout_is(t, rt, want, "a trapped _debug appends nothing")
    m3_FreeRuntime(rt)
}


def test_printf_formats(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let m = new_all_fixture(t, rt)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    put_cstr(rt, STR_AT, "wasm")
    var noArgs : array<uint>

    printf_case(t, rt, "plain text", noArgs, text_bytes("plain text"), "no conversion")
    printf_case(t, rt, "[%c]", [uint('Z')], text_bytes("[Z]"), "%c")
    printf_case(t, rt, "%c", [0x141u], text_bytes("A"), "%c takes the low byte")
    printf_case(t, rt, "%d", [42u], text_bytes("42"), "%d")
    printf_case(t, rt, "%d", [0u], text_bytes("0"), "%d of 0")
    printf_case(t, rt, "%d", [uint(-123)], text_bytes("-123"), "%d negative")
    printf_case(t, rt, "%d", [0x7fffffffu], text_bytes("2147483647"), "%d INT32_MAX")
    printf_case(t, rt, "%x", [255u], text_bytes("FF"), "%x upper-case digits")
    printf_case(t, rt, "%x", [0x7fffffffu], text_bytes("7FFFFFFF"), "%x INT32_MAX")
    printf_case(t, rt, "%x", [0xffffffffu], text_bytes("-1"), "%x of -1 is signed")
    printf_case(t, rt, "<%s>", [uint(STR_AT)], text_bytes("<wasm>"), "%s")
    printf_case(t, rt, "%s", [0u], text_bytes("(null)"), "%s of NULL")
    printf_case(t, rt, "100%%", noArgs, text_bytes("100%"), "%% is the default arm")
    printf_case(t, rt, "%u|%d", [7u], text_bytes("u|7"), "%u is not a conversion: 'u', no argument")
    printf_case(t, rt, "%f|%d", [7u], text_bytes("f|7"), "%f is not a conversion")
    printf_case(t, rt, "%lld|%d", [7u], text_bytes("lld|7"), "%lld: 'l' then text")
    printf_case(t, rt, "%d %x %c %s!", [uint(-5), 26u, uint('q'), uint(STR_AT)], text_bytes("-5 1A q wasm!"), "mixed, arguments in order")

    // %c of 0: a NUL byte in the output (DESIGN 4.7c)
    var nulWant : array<u8>
    push(nulWant, u8('a'))
    push(nulWant, 0u8)
    push(nulWant, u8('b'))
    printf_case(t, rt, "a%cb", [0u], nulWant, "%c of NUL")

    // a lone '%' before the terminator: C prints the NUL (default arm) and
    // reads on past it, up to the next NUL
    clear(rt.stdoutBuffer)
    put_cstr(rt, FMT_AT, "a%")
    put_cstr(rt, FMT_AT + 3, "bc")
    let lone = call_w(t, rt, "wprintf", [FMT_AT, ARGS_AT])
    is_ok(t, lone._0, "printf \"a%\" runs")
    var loneWant : array<u8>
    push(loneWant, u8('a'))
    push(loneWant, 0u8)
    push(loneWant, u8('b'))
    push(loneWant, u8('c'))
    stdout_is(t, rt, loneWant, "a lone '%': the NUL, then the bytes after it (C)")
    equal(t, lone._1, 4, "a lone '%': C's count")

    m3_FreeRuntime(rt)
}


def test_printf_null_and_bounds(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let m = new_all_fixture(t, rt)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }

    clear(rt.stdoutBuffer)
    let nul = call_w(t, rt, "wprintf", [0, ARGS_AT])
    is_ok(t, nul._0, "printf(NULL) runs")
    equal(t, nul._1, 0, "printf(NULL) returns 0")
    equal(t, length(rt.stdoutBuffer), 0, "printf(NULL) writes nothing")

    // the argument list at the end of memory: the text before the
    // conversion is written, then m3ApiCheckMem (i_args, 4) traps
    clear(rt.stdoutBuffer)
    put_cstr(rt, FMT_AT, "ab%d")
    is_err(t, call_w(t, rt, "wprintf", [FMT_AT, 65533])._0, m3Err_trapOutOfBoundsMemoryAccess, "%d with arguments past the end traps")
    var ab <- text_bytes("ab")
    stdout_is(t, rt, ab, "the bytes before the trap stay")

    // the second argument crosses the end: the first conversion is written
    clear(rt.stdoutBuffer)
    put_cstr(rt, FMT_AT, "%c%c")
    rt.mem[65532] = u8('x')
    is_err(t, call_w(t, rt, "wprintf", [FMT_AT, 65532])._0, m3Err_trapOutOfBoundsMemoryAccess, "%c%c with the second argument past the end traps")
    var x <- text_bytes("x")
    stdout_is(t, rt, x, "the first %c before the trap stays")

    // %s whose string is not terminated before the end of memory
    clear(rt.stdoutBuffer)
    for (i in range(4)) {
        rt.mem[65532 + i] = u8('s')
    }
    put_cstr(rt, FMT_AT, "%s")
    put_args(rt, ARGS_AT, [65532u])
    is_err(t, call_w(t, rt, "wprintf", [FMT_AT, ARGS_AT])._0, m3Err_trapOutOfBoundsMemoryAccess, "%s without a NUL before the end traps")
    equal(t, length(rt.stdoutBuffer), 0, "a trapped %s writes nothing")

    // %s at the guest pointer 0xffffffff
    put_args(rt, ARGS_AT, [0xffffffffu])
    is_err(t, call_w(t, rt, "wprintf", [FMT_AT, ARGS_AT])._0, m3Err_trapOutOfBoundsMemoryAccess, "%s at 0xffffffff traps")

    // the format itself runs to the end of memory without a NUL
    is_err(t, call_w(t, rt, "wprintf", [65532, ARGS_AT])._0, m3Err_trapOutOfBoundsMemoryAccess, "an unterminated format traps")
    is_err(t, call_w(t, rt, "wprintf", [65536, ARGS_AT])._0, m3Err_trapOutOfBoundsMemoryAccess, "a format at the end of memory traps")
    equal(t, length(rt.stdoutBuffer), 0, "a trapped format writes nothing")

    m3_FreeRuntime(rt)
}


def test_memcpy_memset_out_of_bounds(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let m = new_all_fixture(t, rt)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    for (i in range(16)) {
        rt.mem[65520 + i] = u8(i + 1)
    }

    is_err(t, call_w(t, rt, "w_memset", [65530, 0, 7])._0, m3Err_trapOutOfBoundsMemoryAccess, "_memset one byte past the end traps")
    is_ok(t, call_w(t, rt, "w_memset", [65536, 0, 0])._0, "_memset of 0 bytes at the end passes (C's inclusive bound)")
    is_err(t, call_w(t, rt, "w_memset", [-1, 0, 1])._0, m3Err_trapOutOfBoundsMemoryAccess, "_memset at 0xffffffff traps")
    is_err(t, call_w(t, rt, "w_memcpy", [65530, 0, 7])._0, m3Err_trapOutOfBoundsMemoryAccess, "_memcpy destination past the end traps")
    is_err(t, call_w(t, rt, "w_memcpy", [0, 65530, 7])._0, m3Err_trapOutOfBoundsMemoryAccess, "_memcpy source past the end traps")
    is_err(t, call_w(t, rt, "w_memcpy", [65520, -1, 4])._0, m3Err_trapOutOfBoundsMemoryAccess, "_memcpy source at 0xffffffff traps")
    is_err(t, call_w(t, rt, "w_memmove", [65520, 65528, 9])._0, m3Err_trapOutOfBoundsMemoryAccess, "_memmove source past the end traps")

    var ok = true
    for (i in range(16)) {
        ok = ok && rt.mem[65520 + i] == u8(i + 1)
    }
    check(t, ok, "a trapped call leaves memory as it was")
    m3_FreeRuntime(rt)
}


def test_clock_ms(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime()
    let m = new_all_fixture(t, rt)
    if (m == -1) {
        m3_FreeRuntime(rt)
        return
    }
    var none : array<int>
    let a = call_w(t, rt, "wclock_ms", none)
    let b = call_w(t, rt, "wclock_ms", none)
    is_ok(t, a._0, "clock_ms runs")
    is_ok(t, b._0, "clock_ms runs again")
    check(t, uint(b._1) >= uint(a._1), "clock_ms does not go back ({a._1} then {b._1})")
    m3_FreeRuntime(rt)
}


def public run_tests_m3_api_libc(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_link_spec_test_binds_known_imports")
    test_link_spec_test_binds_known_imports(t, fx)
    begin_test(t, "test_link_spec_test_before_load")
    test_link_spec_test_before_load(t, fx)
    begin_test(t, "test_spectest_dummy_is_callable_from_wasm")
    test_spectest_dummy_is_callable_from_wasm(t, fx)
    begin_test(t, "test_link_libc_binds_known_imports")
    test_link_libc_binds_known_imports(t, fx)
    begin_test(t, "test_libc_memset_fills_linear_memory")
    test_libc_memset_fills_linear_memory(t, fx)
    begin_test(t, "test_libc_memmove_copies_linear_memory")
    test_libc_memmove_copies_linear_memory(t, fx)
    begin_test(t, "test_libc_memset_out_of_bounds_traps")
    test_libc_memset_out_of_bounds_traps(t, fx)
    begin_test(t, "test_libc_abort_and_exit_trap")
    test_libc_abort_and_exit_trap(t, fx)
    begin_test(t, "test_link_libc_links_all_imports")
    test_link_libc_links_all_imports(t, fx)
    begin_test(t, "test_debug_writes_bytes")
    test_debug_writes_bytes(t, fx)
    begin_test(t, "test_printf_formats")
    test_printf_formats(t, fx)
    begin_test(t, "test_printf_null_and_bounds")
    test_printf_null_and_bounds(t, fx)
    begin_test(t, "test_memcpy_memset_out_of_bounds")
    test_memcpy_memset_out_of_bounds(t, fx)
    begin_test(t, "test_clock_ms")
    test_clock_ms(t, fx)
}
