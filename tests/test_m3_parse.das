options gen2
options indenting = 4

module test_m3_parse

require dastest/testing_boost
require ../source/m3_parse.das


def private fail(message : string) {
    panic("test_m3_parse: {message}")
}


def private check(condition : bool; message : string) {
    if (!condition) {
        fail(message)
    }
}


def private check_result(actual : M3Result; expected : M3Result; message : string) {
    if (actual != expected) {
        fail("{message}: expected '{expected}', got '{actual}'")
    }
}


def private cursor_offset(start : bytes_t; cursor : bytes_t) : int {
    return int(intptr(cursor) - intptr(start))
}


def private init_bounds(
                        var buf : array<u8>;
                        var start : bytes_t&;
                        var end : cbytes_t&
                        ) {
    check(!empty(buf), "test buffer must not be empty")
    start = unsafe(addr(buf[0]))
    end = unsafe(reinterpret<cbytes_t>(intptr(start) + u64(long_length(buf))))
}


def private check_memory_case(
                              var buf : array<u8>;
                              expected_result : M3Result;
                              expected_pos : int;
                              expected_init : u32;
                              expected_max : u32;
                              expected_page : u32;
                              case_name : string
                              ) {
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_bounds(buf, start, end)
    cursor = start

    var memory = M3MemoryInfo(initPages = 91u, maxPages = 92u, pageSize = 93u)
    let result = ParseType_Memory(memory, cursor, end)

    check_result(result, expected_result, "{case_name} result")
    check(cursor_offset(start, cursor) == expected_pos, "{case_name} cursor")
    check(memory.initPages == expected_init, "{case_name} initPages")
    check(memory.maxPages == expected_max, "{case_name} maxPages")
    check(memory.pageSize == expected_page, "{case_name} pageSize")
}


def private check_memory_successes() {
    var flag0 <- [u8(0x00), u8(0x03)]
    check_memory_case(flag0, m3Err_none, 2, 3u, 0u, 0u, "flag 0")

    var maxFlag <- [u8(0x01), u8(0x02), u8(0x05)]
    check_memory_case(maxFlag, m3Err_none, 3, 2u, 5u, 0u, "flag bit 0")

    var pageFlag <- [u8(0x08), u8(0x01), u8(0x10)]
    check_memory_case(pageFlag, m3Err_none, 3, 1u, 0u, 65536u, "flag bit 3")

    var bothFlags <- [u8(0x09), u8(0x02), u8(0x09), u8(0x0c)]
    check_memory_case(bothFlags, m3Err_none, 4, 2u, 9u, 4096u, "flags 0+3")

    var unknownFlag <- [u8(0x02), u8(0x07)]
    check_memory_case(unknownFlag, m3Err_none, 2, 7u, 0u, 0u, "unknown flag bit")
}


def private check_memory_truncation() {
    var flagBuf <- [u8(0x00)]
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_bounds(flagBuf, start, end)
    cursor = end
    var memory = M3MemoryInfo(initPages = 11u, maxPages = 12u, pageSize = 13u)
    check_result(ParseType_Memory(memory, cursor, end), m3Err_wasmUnderrun, "truncated flag")
    check(cursor_offset(start, cursor) == 1, "truncated flag cursor")
    check(memory.initPages == 11u && memory.maxPages == 12u && memory.pageSize == 13u,
        "truncated flag preserves memory")

    var overflowFlag <- [u8(0x81)]
    init_bounds(overflowFlag, start, end)
    cursor = start
    check_result(ParseType_Memory(memory, cursor, end), m3Err_lebOverflow, "overflow flag")
    check(cursor_offset(start, cursor) == 1, "overflow flag cursor")
    check(memory.initPages == 11u && memory.maxPages == 12u && memory.pageSize == 13u,
        "overflow flag preserves memory")

    var initBuf <- [u8(0x00), u8(0x81)]
    check_memory_case(initBuf, m3Err_wasmUnderrun, 2, 1u, 92u, 93u, "truncated initPages")

    var maxBuf <- [u8(0x01), u8(0x02), u8(0x81)]
    check_memory_case(maxBuf, m3Err_wasmUnderrun, 3, 2u, 1u, 93u, "truncated maxPages")

    var logBuf <- [u8(0x08), u8(0x02), u8(0x81)]
    check_memory_case(logBuf, m3Err_wasmUnderrun, 3, 2u, 0u, 0u, "truncated logPageSize")
}


def private check_memory_shift_boundaries() {
    var minimum <- [u8(0x08), u8(0x01), u8(0x00)]
    check_memory_case(minimum, m3Err_none, 3, 1u, 0u, 1u, "logPageSize 0")

    var ordinary <- [u8(0x08), u8(0x01), u8(0x10)]
    check_memory_case(ordinary, m3Err_none, 3, 1u, 0u, 65536u, "logPageSize 16")

    // 31 is the largest defined shift for the C u32 expression `1u << logPageSize`.
    var boundary <- [u8(0x08), u8(0x01), u8(0x1f)]
    check_memory_case(boundary, m3Err_none, 3, 1u, 0u, 0x80000000u, "logPageSize 31")
}


def private parse_start(var moduleValue : M3Module&; var buf : array<u8>) : M3Result {
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_bounds(buf, start, end)
    cursor = start
    return ParseSection_Start(unsafe(addr(moduleValue)), cursor, end)
}


def private check_start_section() {
    var moduleValue : M3Module
    moduleValue.numFunctions = 3u

    var first <- [u8(0x00)]
    check_result(parse_start(moduleValue, first), m3Err_none, "start index 0")
    check(moduleValue.startFunction == 0, "start index 0 stored")

    var last <- [u8(0x02)]
    check_result(parse_start(moduleValue, last), m3Err_none, "start last index")
    check(moduleValue.startFunction == 2, "start last index stored")

    moduleValue.startFunction = 77
    var atCount <- [u8(0x03)]
    check_result(parse_start(moduleValue, atCount), "start function index out of bounds", "start at count")
    check(moduleValue.startFunction == 77, "start at count preserves previous value")

    var large <- [u8(0xff), u8(0xff), u8(0xff), u8(0xff), u8(0x0f)]
    check_result(parse_start(moduleValue, large), "start function index out of bounds", "large start")
    check(moduleValue.startFunction == 77, "large start preserves previous value")

    var truncated <- [u8(0x81)]
    check_result(parse_start(moduleValue, truncated), m3Err_wasmUnderrun, "truncated start index")
    check(moduleValue.startFunction == 77, "truncated start preserves previous value")
}


def private check_element_case(
                               var buf : array<u8>;
                               expected_count : u32;
                               expected_prefix : int;
                               case_name : string
                               ) {
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_bounds(buf, start, end)
    cursor = start

    var moduleValue : M3Module
    let result = ParseSection_Element(unsafe(addr(moduleValue)), cursor, end)

    check_result(result, m3Err_none, "{case_name} result")
    check(moduleValue.numElementSegments == expected_count, "{case_name} count")
    check(cursor_offset(start, moduleValue.elementSection) == expected_prefix, "{case_name} section start")
    check(moduleValue.elementSectionEnd == end, "{case_name} section end")
}


def private check_element_section() {
    var zero <- [u8(0x00), u8(0xaa)]
    check_element_case(zero, 0u, 1, "element zero")

    var ordinary <- [u8(0x05), u8(0xaa), u8(0xbb)]
    check_element_case(ordinary, 5u, 1, "element ordinary")

    var maximum <- [u8(0x80), u8(0xad), u8(0xe2), u8(0x04), u8(0xcc)]
    check_element_case(maximum, u32(d_m3MaxSaneElementSegments), 4, "element maximum")

    var above <- [u8(0x81), u8(0xad), u8(0xe2), u8(0x04), u8(0xdd)]
    var start : bytes_t
    var cursor : bytes_t
    var end : cbytes_t
    init_bounds(above, start, end)
    cursor = start

    var moduleValue = M3Module(
        numElementSegments = 17u,
        elementSection = start,
        elementSectionEnd = start
    )
    check_result(ParseSection_Element(unsafe(addr(moduleValue)), cursor, end),
        "too many element segments", "element above sane limit")
    check(moduleValue.numElementSegments == 17u, "element overflow preserves count")
    check(moduleValue.elementSection == start, "element overflow preserves start")
    check(moduleValue.elementSectionEnd == start, "element overflow preserves end")
    let preservedStart = moduleValue.elementSection
    let preservedEnd = moduleValue.elementSectionEnd

    var truncated <- [u8(0x81)]
    init_bounds(truncated, start, end)
    cursor = start
    check_result(ParseSection_Element(unsafe(addr(moduleValue)), cursor, end),
        m3Err_wasmUnderrun, "truncated element count")
    check(moduleValue.numElementSegments == 17u, "truncated element preserves count")
    check(moduleValue.elementSection == preservedStart, "truncated element preserves start")
    check(moduleValue.elementSectionEnd == preservedEnd, "truncated element preserves end")
}


[test]
def test_parse_type_table() {
    check_result(ParseType_Table(null, null, null), m3Err_none, "ParseType_Table")
}


[test]
def test_parse_type_memory() {
    check_memory_successes()
    check_memory_truncation()
    check_memory_shift_boundaries()
}


[test]
def test_parse_section_start() {
    check_start_section()
}


[test]
def test_parse_section_element() {
    check_element_section()
}


[export]
def main() {
    test_parse_type_table()
    test_parse_type_memory()
    test_parse_section_start()
    test_parse_section_element()
    print("test_m3_parse: all tests passed\n")
}
