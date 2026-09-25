options gen2
options indenting = 4

module test_m3_parse shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_parse
require modules/wasm3das/source/m3_env
require modules/wasm3das/source/m3_module      // m3_FreeModule
require modules/wasm3das/source/m3_types
require modules/wasm3das/source/m3_core

/*
    test_m3_parse.das: Eden counterpart of
    .upstream/tests/integration/test_m3_parse.das.

    Coverage of the upstream [test]s (4 of 4 ported):
      - test_parse_type_table: ParseType_Table returns m3Err_none (Eden: the
        runtime and -1 handles / indices for C's NULLs).
      - test_parse_type_memory: the flag / initPages / maxPages / logPageSize
        cases, truncations and shift boundaries with the same expected
        results, cursor positions and preserved fields; the cursor is an
        index into the test buffer (upstream: a pointer offset).
      - test_parse_section_start, test_parse_section_element: the same
        cases on a module slot of a runtime whose `wasm` is the test buffer
        (upstream: a stack M3Module and pointers into the buffer); section
        start / end are indices into it.
    Tests added for the Eden shape (no upstream counterpart):
      - test_parse_fixture_structure: lang/fib32.wasm and lang/fib.c.wasm
        parse into the runtime arenas (module not linked, bodies as indices
        into the module's copy, exports with isExported, memory, global and
        data segment of fib.c.wasm).
      - test_parse_fib_end_to_end: lang/fib32.wasm, lang/fib64.wasm,
        lang/fib32_tail.wasm and lang/fib.c.wasm through m3_ParseModule,
        m3_LoadModule, m3_FindFunction("fib"), m3_Call(10) / m3_Call(25),
        m3_GetResults = 55 / 75025.
      - test_parse_malformed: empty and truncated file, bad magic, bad
        version, a section length past the end, misordered / repeated /
        unknown sections, a bad type form and a code count mismatch give
        C's error strings, the handle -1 and a released module slot.
      - test_parse_names: a names.wast-style module (an import whose field
        is "", a function exported as "", a name section with a skipped
        subsection, an out-of-range index and a prenamed function): the
        function exported as "" is found by "" and returns its value.
      - test_parse_custom_section_handler: the handler of rt.environment
        gets the section name and the payload range; its error fails the
        parse, its success does not.
*/


// ============================================================================
// Helpers
// ============================================================================


// a runtime of `stackBytes` bytes of stack from a fresh environment
def private new_runtime(stackBytes : u32) : M3Runtime {
    let env = m3_NewEnvironment()
    var rt <- m3_NewRuntime(env, stackBytes, -1)
    return <- rt
}


// a module slot whose binary is `buf` (upstream: a stack M3Module and
// pointers into the test buffer)
def private add_module(var rt : M3Runtime; buf : array<u8>) : IM3Module {
    let m = length(rt.modules)
    m3_Realloc_Impl(rt.modules, m + 1, m)
    rt.modules[m].wasm := buf
    return m
}


// the wasm header followed by `sections`
def private wasm_binary(sections : array<u8>) : array<u8> {
    var bytes : array<u8>
    for (b in fixed_array<u8>(0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8, 0x00u8, 0x00u8)) {
        push(bytes, b)
    }
    for (b in sections) {
        push(bytes, b)
    }
    return <- bytes
}


// checks a failed parse: C's error, the handle -1, the slot released
def private expect_parse_error(var t : TestRun; var rt : M3Runtime; bytes : array<u8>; want : M3Result; case_name : string) {
    let slot = length(rt.modules)
    let parsed = m3_ParseModule(rt, bytes)
    is_err(t, parsed._0, want, "{case_name} result")
    equal(t, parsed._1, -1, "{case_name} handle")
    equal(t, length(rt.modules), slot + 1, "{case_name} slot allocated")
    if (length(rt.modules) == slot + 1) {
        equal(t, length(rt.modules[slot].wasm), 0, "{case_name} released slot drops the binary")
        equal(t, rt.modules[slot].runtime, -1, "{case_name} released slot not linked")
        equal(t, rt.modules[slot].numFunctions, 0u, "{case_name} released slot has no functions")
    }
}


// ============================================================================
// Upstream: ParseType_Memory
// ============================================================================


def private check_memory_case(
                              var t : TestRun;
                              buf : array<u8>;
                              expected_result : M3Result;
                              expected_pos : int;
                              expected_init : u32;
                              expected_max : u32;
                              expected_page : u32;
                              case_name : string
                              ) {
    check(t, !empty(buf), "test buffer must not be empty")
    var cursor = 0
    let end = length(buf)

    var memory = M3MemoryInfo(initPages = 91u, maxPages = 92u, pageSize = 93u)
    let result = ParseType_Memory(buf, memory, cursor, end)

    is_err(t, result, expected_result, "{case_name} result")
    equal(t, cursor, expected_pos, "{case_name} cursor")
    equal(t, memory.initPages, expected_init, "{case_name} initPages")
    equal(t, memory.maxPages, expected_max, "{case_name} maxPages")
    equal(t, memory.pageSize, expected_page, "{case_name} pageSize")
}


def private check_memory_successes(var t : TestRun) {
    check_memory_case(t, [0x00u8, 0x03u8], m3Err_none, 2, 3u, 0u, 0u, "flag 0")
    check_memory_case(t, [0x01u8, 0x02u8, 0x05u8], m3Err_none, 3, 2u, 5u, 0u, "flag bit 0")
    check_memory_case(t, [0x08u8, 0x01u8, 0x10u8], m3Err_none, 3, 1u, 0u, 65536u, "flag bit 3")
    check_memory_case(t, [0x09u8, 0x02u8, 0x09u8, 0x0cu8], m3Err_none, 4, 2u, 9u, 4096u, "flags 0+3")
    check_memory_case(t, [0x02u8, 0x07u8], m3Err_none, 2, 7u, 0u, 0u, "unknown flag bit")
}


def private check_memory_truncation(var t : TestRun) {
    let flagBuf <- [0x00u8]
    var cursor = length(flagBuf)   // upstream: cursor = end
    let end = length(flagBuf)
    var memory = M3MemoryInfo(initPages = 11u, maxPages = 12u, pageSize = 13u)
    is_err(t, ParseType_Memory(flagBuf, memory, cursor, end), m3Err_wasmUnderrun, "truncated flag")
    equal(t, cursor, 1, "truncated flag cursor")
    check(t, memory.initPages == 11u && memory.maxPages == 12u && memory.pageSize == 13u, "truncated flag preserves memory")

    let overflowFlag <- [0x81u8]
    cursor = 0
    is_err(t, ParseType_Memory(overflowFlag, memory, cursor, length(overflowFlag)), m3Err_lebOverflow, "overflow flag")
    equal(t, cursor, 1, "overflow flag cursor")
    check(t, memory.initPages == 11u && memory.maxPages == 12u && memory.pageSize == 13u, "overflow flag preserves memory")

    check_memory_case(t, [0x00u8, 0x81u8], m3Err_wasmUnderrun, 2, 1u, 92u, 93u, "truncated initPages")
    check_memory_case(t, [0x01u8, 0x02u8, 0x81u8], m3Err_wasmUnderrun, 3, 2u, 1u, 93u, "truncated maxPages")
    check_memory_case(t, [0x08u8, 0x02u8, 0x81u8], m3Err_wasmUnderrun, 3, 2u, 0u, 0u, "truncated logPageSize")
}


def private check_memory_shift_boundaries(var t : TestRun) {
    check_memory_case(t, [0x08u8, 0x01u8, 0x00u8], m3Err_none, 3, 1u, 0u, 1u, "logPageSize 0")
    check_memory_case(t, [0x08u8, 0x01u8, 0x10u8], m3Err_none, 3, 1u, 0u, 65536u, "logPageSize 16")
    // 31 is the largest defined shift for the C u32 expression `1u << logPageSize`.
    check_memory_case(t, [0x08u8, 0x01u8, 0x1fu8], m3Err_none, 3, 1u, 0u, 0x80000000u, "logPageSize 31")
}


// ============================================================================
// Upstream: ParseSection_Start
// ============================================================================


// Eden: the buffer becomes the module's binary, the section is all of it
def private parse_start(var rt : M3Runtime; m : IM3Module; buf : array<u8>) : M3Result {
    rt.modules[m].wasm := buf
    return ParseSection_Start(rt, m, 0, length(buf))
}


def private check_start_section(var t : TestRun) {
    var rt <- new_runtime(4096u)
    var none : array<u8>
    let m = add_module(rt, none)
    rt.modules[m].numFunctions = 3u

    is_err(t, parse_start(rt, m, [0x00u8]), m3Err_none, "start index 0")
    equal(t, rt.modules[m].startFunction, 0, "start index 0 stored")

    is_err(t, parse_start(rt, m, [0x02u8]), m3Err_none, "start last index")
    equal(t, rt.modules[m].startFunction, 2, "start last index stored")

    rt.modules[m].startFunction = 77
    is_err(t, parse_start(rt, m, [0x03u8]), "start function index out of bounds", "start at count")
    equal(t, rt.modules[m].startFunction, 77, "start at count preserves previous value")

    is_err(t, parse_start(rt, m, [0xffu8, 0xffu8, 0xffu8, 0xffu8, 0x0fu8]), "start function index out of bounds", "large start")
    equal(t, rt.modules[m].startFunction, 77, "large start preserves previous value")

    is_err(t, parse_start(rt, m, [0x81u8]), m3Err_wasmUnderrun, "truncated start index")
    equal(t, rt.modules[m].startFunction, 77, "truncated start preserves previous value")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Upstream: ParseSection_Element
// ============================================================================


def private check_element_case(var t : TestRun; buf : array<u8>; expected_count : u32; expected_prefix : int; case_name : string) {
    var rt <- new_runtime(4096u)
    let m = add_module(rt, buf)
    let end = length(buf)

    let result = ParseSection_Element(rt, m, 0, end)

    is_err(t, result, m3Err_none, "{case_name} result")
    equal(t, rt.modules[m].numElementSegments, expected_count, "{case_name} count")
    equal(t, rt.modules[m].elementSection, expected_prefix, "{case_name} section start")
    equal(t, rt.modules[m].elementSectionEnd, end, "{case_name} section end")

    m3_FreeRuntime(rt)
}


def private check_element_section(var t : TestRun) {
    check_element_case(t, [0x00u8, 0xaau8], 0u, 1, "element zero")
    check_element_case(t, [0x05u8, 0xaau8, 0xbbu8], 5u, 1, "element ordinary")
    check_element_case(t, [0x80u8, 0xadu8, 0xe2u8, 0x04u8, 0xccu8], u32(d_m3MaxSaneElementSegments), 4, "element maximum")

    var rt <- new_runtime(4096u)
    let m = add_module(rt, [0x81u8, 0xadu8, 0xe2u8, 0x04u8, 0xddu8])
    let start = 0
    rt.modules[m].numElementSegments = 17u
    rt.modules[m].elementSection = start
    rt.modules[m].elementSectionEnd = start
    is_err(t, ParseSection_Element(rt, m, 0, length(rt.modules[m].wasm)), "too many element segments", "element above sane limit")
    equal(t, rt.modules[m].numElementSegments, 17u, "element overflow preserves count")
    equal(t, rt.modules[m].elementSection, start, "element overflow preserves start")
    equal(t, rt.modules[m].elementSectionEnd, start, "element overflow preserves end")
    let preservedStart = rt.modules[m].elementSection
    let preservedEnd = rt.modules[m].elementSectionEnd

    rt.modules[m].wasm := [0x81u8]
    is_err(t, ParseSection_Element(rt, m, 0, length(rt.modules[m].wasm)), m3Err_wasmUnderrun, "truncated element count")
    equal(t, rt.modules[m].numElementSegments, 17u, "truncated element preserves count")
    equal(t, rt.modules[m].elementSection, preservedStart, "truncated element preserves start")
    equal(t, rt.modules[m].elementSectionEnd, preservedEnd, "truncated element preserves end")

    m3_FreeRuntime(rt)
}


// ============================================================================
// Upstream [test]s
// ============================================================================


def test_parse_type_table(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)
    // upstream: ParseType_Table (null, null, null); Eden: -1 handle and indices
    is_err(t, ParseType_Table(rt, -1, -1, -1), m3Err_none, "ParseType_Table")
    m3_FreeRuntime(rt)
}


def test_parse_type_memory(var t : TestRun; fx : FixtureSource) {
    check_memory_successes(t)
    check_memory_truncation(t)
    check_memory_shift_boundaries(t)
}


def test_parse_section_start(var t : TestRun; fx : FixtureSource) {
    check_start_section(t)
}


def test_parse_section_element(var t : TestRun; fx : FixtureSource) {
    check_element_section(t)
}


// ============================================================================
// Eden: whole modules
// ============================================================================


def test_parse_fixture_structure(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)

    var fib32 <- load_fixture(fx, "lang/fib32.wasm")
    check(t, length(fib32) > 0, "lang/fib32.wasm loaded")
    let parsed = m3_ParseModule(rt, fib32)
    is_ok(t, parsed._0, "parse fib32")
    let m = parsed._1
    check(t, m >= 0, "fib32 handle")
    if (parsed._0 == m3Err_none && m >= 0) {
        equal_str(t, rt.modules[m].name, ".unnamed", "module name")
        equal(t, rt.modules[m].runtime, -1, "registered, not linked")
        equal(t, rt.modules[m].startFunction, -1, "no start function")
        equal(t, length(rt.modules[m].wasm), length(fib32), "the module owns a copy of the binary")
        equal(t, rt.modules[m].wasmStart, 0, "wasmStart")
        equal(t, rt.modules[m].wasmEnd, length(fib32), "wasmEnd")
        equal(t, rt.modules[m].numFuncTypes, 1u, "one type")
        equal(t, rt.modules[m].numFuncImports, 0u, "no imports")
        equal(t, rt.modules[m].numFunctions, 1u, "one function")
        equal(t, length(rt.modules[m].functions), 1, "one function handle")
        let ft = rt.modules[m].funcTypes[0]
        equal(t, int(rt.funcTypes[ft].numArgs), 1, "fib takes one argument")
        equal(t, int(rt.funcTypes[ft].numRets), 1, "fib returns one value")
        // C: the type is interned (the runtime's i32 block type is () -> i32, a different type)
        not_equal(t, ft, rt.environment.retFuncTypes[1], "(i32) -> i32 is not the block type")
        let f = rt.modules[m].functions[0]
        equal(t, rt.functions[f].funcTypeIdx, ft, "function type")
        equal(t, rt.functions[f].moduleIdx, m, "ParseSection_Code sets the module")
        check(t, rt.functions[f].isExported, "fib is exported")
        equal_str(t, rt.functions[f].export_name, "fib", "export_name")
        equal(t, int(rt.functions[f].numNames), 1, "one name")
        equal_str(t, rt.functions[f].names[0], "fib", "names[0]")
        check(t, !rt.functions[f].ownsWasmCode, "ownsWasmCode stays false (commented out in C)")
        // the body: its size byte, then 29 bytes (no locals, the code)
        let w = rt.functions[f].wasm
        check(t, w > 0 && w < length(fib32), "body start is an index into the binary")
        if (w > 0 && w < length(fib32)) {
            equal(t, int(rt.modules[m].wasm[w]), 29, "size byte at the body start")
            equal(t, rt.functions[f].wasmEnd, w + 30, "body end")
            equal(t, int(rt.modules[m].wasm[rt.functions[f].wasmEnd - 1]), 11, "body ends with `end`")
        }
    }

    var fibc <- load_fixture(fx, "lang/fib.c.wasm")
    check(t, length(fibc) > 0, "lang/fib.c.wasm loaded")
    let parsedC = m3_ParseModule(rt, fibc)
    is_ok(t, parsedC._0, "parse fib.c")
    let c = parsedC._1
    check(t, c >= 0 && c != m, "fib.c has its own handle")
    if (parsedC._0 == m3Err_none && c >= 0) {
        equal(t, rt.modules[c].memoryInfo.initPages, 256u, "memory initPages")
        equal(t, rt.modules[c].memoryInfo.maxPages, 256u, "memory maxPages")
        equal_str(t, rt.modules[c].memoryExportName, "memory", "memory export name")
        equal(t, rt.modules[c].numGlobals, 1u, "one global")
        let g = rt.modules[c].globals[0]
        check(t, rt.globals[g].isMutable, "the stack pointer global is mutable")
        check(t, !rt.globals[g].isExported, "the global is not exported")
        equal(t, rt.globals[g].initExprSize, 6u, "global init expression size (i32.const LEB end)")
        equal(t, int(rt.modules[c].wasm[rt.globals[g].initExpr]), 65, "global init expression starts with i32.const")
        equal(t, rt.modules[c].numDataSegments, 1u, "one data segment")
        equal(t, rt.modules[c].dataSegments[0].initExprSize, 4u, "data init expression size")
        equal(t, rt.modules[c].dataSegments[0].size, 3u, "data size")
        let data = rt.modules[c].dataSegments[0].data
        equal(t, int(rt.modules[c].wasm[data]), 192, "data bytes are indices into the binary")
        equal(t, rt.modules[c].numFunctions, 5u, "five functions")
        var fibIdx : IM3Function = -1
        for (h in rt.modules[c].functions) {
            if (rt.functions[h].isExported && rt.functions[h].export_name == "fib") {
                fibIdx = h
            }
        }
        equal(t, fibIdx, rt.modules[c].functions[0], "fib is function 0")
    }

    m3_FreeRuntime(rt)
}


// parse -> load -> find "fib" -> call with 10 and 25
def private run_fib(var t : TestRun; fx : FixtureSource; name : string; is64 : bool) {
    var bytes <- load_fixture(fx, name)
    check(t, length(bytes) > 0, "{name} loaded")
    if (length(bytes) == 0) {
        return
    }
    var rt <- new_runtime(64u * 1024u)
    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "{name}: m3_ParseModule")
    if (parsed._0 != m3Err_none) {
        m3_FreeRuntime(rt)
        return
    }
    let m = parsed._1
    is_ok(t, m3_LoadModule(rt, m), "{name}: m3_LoadModule")
    equal(t, rt.modules[m].runtime, 0, "{name}: linked")
    var f : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, f, "fib"), "{name}: m3_FindFunction fib")
    if (f == -1) {
        m3_FreeRuntime(rt)
        return
    }
    let ns = fixed_array(10, 25)
    let wants = fixed_array(55, 75025)
    for (n, want in ns, wants) {
        let arg = is64 ? m3_bits_from_i64(i64(n)) : m3_bits_from_i32(n)
        is_ok(t, m3_Call(rt, f, [arg]), "{name}: m3_Call fib({n})")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, f, 1u, out), "{name}: m3_GetResults fib({n})")
        if (length(out) == 1) {
            if (is64) {
                equal(t, m3_bits_to_i64(out[0]), i64(want), "{name}: fib({n})")
            } else {
                equal(t, m3_bits_to_i32(out[0]), want, "{name}: fib({n})")
            }
        } else {
            check(t, false, "{name}: one result for fib({n})")
        }
    }
    m3_FreeRuntime(rt)
}


def test_parse_fib_end_to_end(var t : TestRun; fx : FixtureSource) {
    run_fib(t, fx, "lang/fib32.wasm", false)
    run_fib(t, fx, "lang/fib64.wasm", true)
    run_fib(t, fx, "lang/fib32_tail.wasm", false)
    run_fib(t, fx, "lang/fib.c.wasm", false)
}


def test_parse_malformed(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(4096u)

    var emptyFile : array<u8>
    expect_parse_error(t, rt, emptyFile, m3Err_wasmUnderrun, "empty file")
    expect_parse_error(t, rt, [0x00u8, 0x61u8, 0x73u8], m3Err_wasmUnderrun, "truncated magic")
    expect_parse_error(t, rt, [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x01u8, 0x00u8], m3Err_wasmUnderrun, "truncated version")
    expect_parse_error(t, rt, [0x01u8, 0x02u8, 0x03u8, 0x04u8, 0x01u8, 0x00u8, 0x00u8, 0x00u8], m3Err_wasmMalformed, "bad magic")
    expect_parse_error(t, rt, [0x00u8, 0x61u8, 0x73u8, 0x6du8, 0x02u8, 0x00u8, 0x00u8, 0x00u8], m3Err_incompatibleWasmVersion, "bad version")
    // C checks the magic first: bad magic and bad version together report the magic
    expect_parse_error(t, rt, [0x00u8, 0x00u8, 0x00u8, 0x00u8, 0x02u8, 0x00u8, 0x00u8, 0x00u8], m3Err_wasmMalformed, "bad magic before bad version")

    // a type section of 5 bytes with 1 present
    expect_parse_error(t, rt, wasm_binary([0x01u8, 0x05u8, 0x00u8]), m3Err_wasmMalformed, "section length past end")
    // a truncated section length
    expect_parse_error(t, rt, wasm_binary([0x01u8, 0x80u8]), m3Err_wasmUnderrun, "truncated section length")
    // two type sections
    expect_parse_error(t, rt, wasm_binary([0x01u8, 0x01u8, 0x00u8, 0x01u8, 0x01u8, 0x00u8]), m3Err_misorderedWasmSection, "repeated section")
    // function before type
    expect_parse_error(t, rt, wasm_binary([0x03u8, 0x01u8, 0x00u8, 0x01u8, 0x01u8, 0x00u8]), m3Err_misorderedWasmSection, "section out of order")
    // an unknown section id
    expect_parse_error(t, rt, wasm_binary([0x0du8, 0x00u8]), m3Err_misorderedWasmSection, "unknown section id")
    // a type whose form is not 0x60
    expect_parse_error(t, rt, wasm_binary([0x01u8, 0x04u8, 0x01u8, 0x61u8, 0x00u8, 0x00u8]), m3Err_wasmMalformed, "bad type form")
    // one declared function, a code section with none
    expect_parse_error(t, rt, wasm_binary([0x01u8, 0x04u8, 0x01u8, 0x60u8, 0x00u8, 0x00u8, 0x03u8, 0x02u8, 0x01u8, 0x00u8, 0x0au8, 0x01u8, 0x00u8]), "mismatched function count in code section", "code count mismatch")
    // a body longer than its section
    expect_parse_error(t, rt, wasm_binary([0x01u8, 0x04u8, 0x01u8, 0x60u8, 0x00u8, 0x00u8, 0x03u8, 0x02u8, 0x01u8, 0x00u8, 0x0au8, 0x03u8, 0x01u8, 0x05u8, 0x00u8]), m3Err_wasmSectionOverrun, "code body overrun")
    // a function whose type index is out of range
    expect_parse_error(t, rt, wasm_binary([0x03u8, 0x02u8, 0x01u8, 0x00u8]), "type sig index out of bounds", "type index out of bounds")

    // Custom sections may appear anywhere, even after the last section
    let ok = m3_ParseModule(rt, wasm_binary([0x0bu8, 0x01u8, 0x00u8, 0x00u8, 0x02u8, 0x01u8, 0x78u8]))
    is_ok(t, ok._0, "custom section after data")
    check(t, ok._1 >= 0, "a valid module after failures gets a new handle")
    // a handle is never reused: the failed slots stay released
    equal(t, ok._1, length(rt.modules) - 1, "the new module is the last slot")

    m3_FreeRuntime(rt)
}


def test_parse_names(var t : TestRun; fx : FixtureSource) {
    var rt <- new_runtime(64u * 1024u)
    var bytes <- wasm_binary([
        // type: () -> i32
        0x01u8, 0x05u8, 0x01u8, 0x60u8, 0x00u8, 0x01u8, 0x7fu8,
        // import: "env" "" func type 0
        0x02u8, 0x08u8, 0x01u8, 0x03u8, 0x65u8, 0x6eu8, 0x76u8, 0x00u8, 0x00u8, 0x00u8,
        // function: one of type 0
        0x03u8, 0x02u8, 0x01u8, 0x00u8,
        // export: "" func 1
        0x07u8, 0x04u8, 0x01u8, 0x00u8, 0x00u8, 0x01u8,
        // code: i32.const 42
        0x0au8, 0x06u8, 0x01u8, 0x04u8, 0x00u8, 0x41u8, 0x2au8, 0x0bu8,
        // custom "name": a module-name subsection (skipped), then function
        // names 1 -> "loc" (prenamed by its export) and 5 -> "x" (out of range)
        0x00u8, 0x14u8, 0x04u8, 0x6eu8, 0x61u8, 0x6du8, 0x65u8,
        0x00u8, 0x02u8, 0x01u8, 0x6du8,
        0x01u8, 0x09u8, 0x02u8, 0x01u8, 0x03u8, 0x6cu8, 0x6fu8, 0x63u8, 0x05u8, 0x01u8, 0x78u8])
    let parsed = m3_ParseModule(rt, bytes)
    is_ok(t, parsed._0, "parse the names module")
    let m = parsed._1
    if (parsed._0 != m3Err_none || m < 0) {
        m3_FreeRuntime(rt)
        return
    }
    equal(t, rt.modules[m].numFuncImports, 1u, "one import")
    equal(t, rt.modules[m].numFunctions, 2u, "import first, then the local function")
    let imp = rt.modules[m].functions[0]
    let loc = rt.modules[m].functions[1]
    check(t, !rt.functions[imp].isExported, "the import is not exported")
    equal_str(t, rt.functions[imp].import.moduleUtf8, "env", "import module name")
    equal_str(t, rt.functions[imp].import.fieldUtf8, "", "import field name is empty")
    equal(t, int(rt.functions[imp].numNames), 1, "the import is named by its field")
    equal(t, rt.functions[imp].moduleIdx, -1, "an unlinked import has no module")
    check(t, rt.functions[loc].isExported, "the function exported as \"\" is exported")
    equal_str(t, rt.functions[loc].export_name, "", "export_name is empty")
    equal(t, int(rt.functions[loc].numNames), 1, "the name section does not rename an exported function")
    equal_str(t, rt.functions[loc].names[0], "", "names[0] stays the export name")
    equal(t, rt.functions[loc].moduleIdx, m, "the local function belongs to the module")

    is_ok(t, m3_LoadModule(rt, m), "load the names module")
    var f : IM3Function = -1
    is_ok(t, m3_FindFunction(rt, f, ""), "m3_FindFunction \"\"")
    equal(t, f, loc, "\"\" finds the exported function, not the import")
    if (f == loc) {
        var none : array<u64>
        is_ok(t, m3_Call(rt, f, none), "call the function exported as \"\"")
        var out : array<u64>
        is_ok(t, m3_GetResults(rt, f, 1u, out), "results")
        if (length(out) == 1) {
            equal(t, m3_bits_to_i32(out[0]), 42, "the function exported as \"\" returns 42")
        }
    }
    m3_FreeRuntime(rt)
}


// reports its name and payload range as an error
def private failing_handler(var rt : M3Runtime; i_module : IM3Module; i_name : cstr_t; i_start : cbytes_t; i_end : cbytes_t) : M3Result {
    return "handler {i_name} {i_start} {i_end}"
}


def private accepting_handler(var rt : M3Runtime; i_module : IM3Module; i_name : cstr_t; i_start : cbytes_t; i_end : cbytes_t) : M3Result {
    return m3Err_none
}


def test_parse_custom_section_handler(var t : TestRun; fx : FixtureSource) {
    // custom "ab" with payload 0xee 0xff: the section starts at 10, the name
    // ends at 13, the payload ends at 15
    var bytes <- wasm_binary([0x00u8, 0x05u8, 0x02u8, 0x61u8, 0x62u8, 0xeeu8, 0xffu8])

    var rt <- new_runtime(4096u)
    let plain = m3_ParseModule(rt, bytes)
    is_ok(t, plain._0, "no handler: the custom section is skipped")

    rt.environment.customSectionHandler = @@failing_handler
    expect_parse_error(t, rt, bytes, "handler ab 13 15", "handler error")

    rt.environment.customSectionHandler = @@accepting_handler
    let accepted = m3_ParseModule(rt, bytes)
    is_ok(t, accepted._0, "handler success")

    // the "name" section never reaches the handler
    rt.environment.customSectionHandler = @@failing_handler
    let named = m3_ParseModule(rt, wasm_binary([0x00u8, 0x05u8, 0x04u8, 0x6eu8, 0x61u8, 0x6du8, 0x65u8]))
    is_ok(t, named._0, "the name section is parsed, not handed to the handler")
    m3_FreeRuntime(rt)
}


def public run_tests_m3_parse(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_parse_type_table")
    test_parse_type_table(t, fx)
    begin_test(t, "test_parse_type_memory")
    test_parse_type_memory(t, fx)
    begin_test(t, "test_parse_section_start")
    test_parse_section_start(t, fx)
    begin_test(t, "test_parse_section_element")
    test_parse_section_element(t, fx)
    begin_test(t, "test_parse_fixture_structure")
    test_parse_fixture_structure(t, fx)
    begin_test(t, "test_parse_fib_end_to_end")
    test_parse_fib_end_to_end(t, fx)
    begin_test(t, "test_parse_malformed")
    test_parse_malformed(t, fx)
    begin_test(t, "test_parse_names")
    test_parse_names(t, fx)
    begin_test(t, "test_parse_custom_section_handler")
    test_parse_custom_section_handler(t, fx)
}
