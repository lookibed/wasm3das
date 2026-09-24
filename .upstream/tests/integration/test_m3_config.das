options gen2
options indenting = 4

require dastest/testing_boost
require ../../source/m3_config.das


def private fail(name : string; expected; actual) {
    panic("{name}: expected {expected}, got {actual}")
}


def private expect_eq(name : string; expected; actual) {
    if (actual != expected) {
        fail(name, expected, actual)
    }
}


def private expect_true(name : string; actual : bool) {
    if (!actual) {
        panic("{name}: expected true, got false")
    }
}


def private expect_false(name : string; actual : bool) {
    if (actual) {
        panic("{name}: expected false, got true")
    }
}


def private is_power_of_two(value : uint) : bool {
    return value != 0u && (value & (value - 1u)) == 0u
}


def private observed_little_endian() : bool {
    var probe : uint16 = uint16(0x0102)
    var bytes : uint8[2]

    unsafe {
        memcpy(addr(bytes[0]), addr(probe), 2)
    }

    if (bytes[0] == uint8(0x02) && bytes[1] == uint8(0x01)) {
        return true
    }
    if (bytes[0] == uint8(0x01) && bytes[1] == uint8(0x02)) {
        return false
    }

    panic("unexpected uint16 byte representation: first={bytes[0]}, second={bytes[1]}")
    return false
}


def private check_general_defaults() {
    expect_eq("d_m3CodePageAlignSize", 32768u, d_m3CodePageAlignSize)
    expect_eq("d_m3MaxFunctionStackHeight", 2000u, d_m3MaxFunctionStackHeight)
    expect_eq("d_m3MaxLinearMemoryPages", 65536u, d_m3MaxLinearMemoryPages)
    expect_eq("d_m3MaxFunctionSlots", 4000u, d_m3MaxFunctionSlots)
    expect_eq("d_m3MaxConstantTableSize", 120u, d_m3MaxConstantTableSize)
    expect_eq("d_m3MaxDuplicateFunctionImpl", 3u, d_m3MaxDuplicateFunctionImpl)
    expect_true("d_m3CascadedOpcodes", d_m3CascadedOpcodes)
    expect_true("d_m3VerboseErrorMessages", d_m3VerboseErrorMessages)
    expect_eq("d_m3FixedHeap", 0u, d_m3FixedHeap)
    expect_eq("d_m3FixedHeapAlign", 16u, d_m3FixedHeapAlign)
    expect_eq("d_m3ProfilerSlotMask", 0xffffu, d_m3ProfilerSlotMask)
    expect_false("d_m3RecordBacktraces", d_m3RecordBacktraces)
    expect_false("d_m3EnableExceptionBreakpoint", d_m3EnableExceptionBreakpoint)
}


def private check_derived_values() {
    expect_eq(
        "d_m3MaxFunctionSlots relation",
        d_m3MaxFunctionStackHeight * 2u,
        d_m3MaxFunctionSlots
    )
    expect_true("d_m3CodePageAlignSize power of two", is_power_of_two(d_m3CodePageAlignSize))
    expect_true("d_m3FixedHeapAlign power of two", is_power_of_two(d_m3FixedHeapAlign))
    expect_true(
        "d_m3FixedHeapAlign divides code-page alignment",
        d_m3CodePageAlignSize % d_m3FixedHeapAlign == 0u
    )
    expect_eq("WebAssembly linear-memory page limit", 65536u, d_m3MaxLinearMemoryPages)
}


def private check_platform_values() {
    let actual_ptr_size = uint(typeinfo sizeof(default<void?>))
    let actual_long_size = uint(typeinfo sizeof(default<int64>))

    expect_eq("M3_SIZEOF_PTR", actual_ptr_size, M3_SIZEOF_PTR)
    expect_true("supported pointer size", M3_SIZEOF_PTR == 4u || M3_SIZEOF_PTR == 8u)
    expect_eq("M3_SIZEOF_LONG", actual_long_size, M3_SIZEOF_LONG)
    expect_eq("Daslang int64 size", 8u, M3_SIZEOF_LONG)

    if (M3_ARCH == "") {
        panic("M3_ARCH must not be empty")
    }

    let rv64 = M3_ARCH == "riscv64" || M3_ARCH == "riscv_64"
    expect_eq("d_m3Use32BitSlots target selection", !rv64, d_m3Use32BitSlots)
    expect_eq("M3_SIZEOF_SLOT", d_m3Use32BitSlots ? 4u : 8u, M3_SIZEOF_SLOT)
    expect_eq("M3_HAS_TAIL_CALL", M3_ARCH != "wasm32", M3_HAS_TAIL_CALL)
}


def private check_endianness() {
    if (M3_LITTLE_ENDIAN == M3_BIG_ENDIAN) {
        panic("exactly one of M3_LITTLE_ENDIAN/M3_BIG_ENDIAN must be true")
    }

    let actual_little = observed_little_endian()
    expect_eq("M3_LITTLE_ENDIAN actual byte order", actual_little, M3_LITTLE_ENDIAN)
    expect_eq("M3_BIG_ENDIAN actual byte order", !actual_little, M3_BIG_ENDIAN)
}


def private check_profiling_and_tracing_defaults() {
    expect_false("d_m3EnableOpProfiling", d_m3EnableOpProfiling)
    expect_false("d_m3EnableOpTracing", d_m3EnableOpTracing)
    expect_false("d_m3EnableWasiTracing", d_m3EnableWasiTracing)
    expect_eq("d_m3EnableStrace", 0u, d_m3EnableStrace)
}


def private check_logging_defaults() {
    expect_false("d_m3LogParse", d_m3LogParse)
    expect_false("d_m3LogModule", d_m3LogModule)
    expect_false("d_m3LogCompile", d_m3LogCompile)
    expect_false("d_m3LogWasmStack", d_m3LogWasmStack)
    expect_false("d_m3LogEmit", d_m3LogEmit)
    expect_false("d_m3LogCodePages", d_m3LogCodePages)
    expect_false("d_m3LogRuntime", d_m3LogRuntime)
    expect_false("d_m3LogNativeStack", d_m3LogNativeStack)
    expect_false("d_m3LogHeapOps", d_m3LogHeapOps)
    expect_false("d_m3LogTimestamps", d_m3LogTimestamps)
}


def private check_other_defaults() {
    expect_true("d_m3HasFloat", d_m3HasFloat)
    expect_false("d_m3NoFloatDynamic", d_m3NoFloatDynamic)
    expect_true("d_m3ImplementFloat", d_m3ImplementFloat)
    expect_eq(
        "float configuration relation",
        d_m3HasFloat || d_m3NoFloatDynamic,
        d_m3ImplementFloat
    )

    expect_false("d_m3SkipStackCheck", d_m3SkipStackCheck)
    expect_false("d_m3SkipMemoryBoundsCheck", d_m3SkipMemoryBoundsCheck)
    expect_false("d_m3EnableCodePageRefCounting", d_m3EnableCodePageRefCounting)
}



def private check_immutable_globals() {
    expect_true("d_m3CodePageAlignSize is immutable", typeinfo is_const(d_m3CodePageAlignSize))
    expect_true("d_m3MaxFunctionStackHeight is immutable", typeinfo is_const(d_m3MaxFunctionStackHeight))
    expect_true("d_m3MaxLinearMemoryPages is immutable", typeinfo is_const(d_m3MaxLinearMemoryPages))
    expect_true("d_m3MaxFunctionSlots is immutable", typeinfo is_const(d_m3MaxFunctionSlots))
    expect_true("d_m3FixedHeap is immutable", typeinfo is_const(d_m3FixedHeap))
    expect_true("d_m3Use32BitSlots is immutable", typeinfo is_const(d_m3Use32BitSlots))
    expect_true("d_m3RecordBacktraces is immutable", typeinfo is_const(d_m3RecordBacktraces))
    expect_true("d_m3HasFloat is immutable", typeinfo is_const(d_m3HasFloat))
    expect_true("M3_SIZEOF_PTR is immutable", typeinfo is_const(M3_SIZEOF_PTR))
    expect_true("M3_SIZEOF_SLOT is immutable", typeinfo is_const(M3_SIZEOF_SLOT))
}


def private run_all_checks() {
    check_general_defaults()
    check_derived_values()
    check_platform_values()
    check_endianness()
    check_profiling_and_tracing_defaults()
    check_logging_defaults()
    check_other_defaults()
    check_immutable_globals()
}


[test]
def test_m3_config_all() {
    run_all_checks()
}


[export]
def main() {
    run_all_checks()
    print("test_m3_config: all tests passed\n")
}
