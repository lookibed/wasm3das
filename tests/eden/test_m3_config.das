options gen2
options indenting = 4

module test_m3_config shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_config

/*
    test_m3_config.das: Eden counterpart of
    .upstream/tests/integration/test_m3_config.das.

    The one upstream [test], test_m3_config_all, runs eight check groups; each
    group is kept as a helper below with the same checks in the same order.
    The fail-fast expect_* helpers of the upstream file (panic on the first
    mismatch) become the recording checks of eden_test (equal / check), so one
    failing value never hides the others.

    Eden: check_endianness cannot observe the host representation (the
    upstream observed_little_endian() copies the bytes of a uint16 through its
    address, which the sandbox forbids); it checks the constant contract of
    wasm3_defs instead, as test_wasm3_defs does: M3_LITTLE_ENDIAN is true
    (wasm is little-endian by definition) and exactly one of the two flags
    is set. Every other check is the upstream one.
*/


def private is_power_of_two(value : uint) : bool {
    return value != 0u && (value & (value - 1u)) == 0u
}


def private check_general_defaults(var t : TestRun) {
    equal(t, d_m3CodePageAlignSize, 32768u, "d_m3CodePageAlignSize")
    equal(t, d_m3MaxFunctionStackHeight, 2000u, "d_m3MaxFunctionStackHeight")
    equal(t, d_m3MaxLinearMemoryPages, 65536u, "d_m3MaxLinearMemoryPages")
    equal(t, d_m3MaxFunctionSlots, 4000u, "d_m3MaxFunctionSlots")
    equal(t, d_m3MaxConstantTableSize, 120u, "d_m3MaxConstantTableSize")
    equal(t, d_m3MaxDuplicateFunctionImpl, 3u, "d_m3MaxDuplicateFunctionImpl")
    check(t, d_m3CascadedOpcodes, "d_m3CascadedOpcodes")
    check(t, d_m3VerboseErrorMessages, "d_m3VerboseErrorMessages")
    equal(t, d_m3FixedHeap, 0u, "d_m3FixedHeap")
    equal(t, d_m3FixedHeapAlign, 16u, "d_m3FixedHeapAlign")
    equal(t, d_m3ProfilerSlotMask, 0xffffu, "d_m3ProfilerSlotMask")
    check(t, !d_m3RecordBacktraces, "d_m3RecordBacktraces")
    check(t, !d_m3EnableExceptionBreakpoint, "d_m3EnableExceptionBreakpoint")
}


def private check_derived_values(var t : TestRun) {
    equal(t, d_m3MaxFunctionSlots, d_m3MaxFunctionStackHeight * 2u, "d_m3MaxFunctionSlots relation")
    check(t, is_power_of_two(d_m3CodePageAlignSize), "d_m3CodePageAlignSize power of two")
    check(t, is_power_of_two(d_m3FixedHeapAlign), "d_m3FixedHeapAlign power of two")
    check(t, d_m3CodePageAlignSize % d_m3FixedHeapAlign == 0u, "d_m3FixedHeapAlign divides code-page alignment")
    equal(t, d_m3MaxLinearMemoryPages, 65536u, "WebAssembly linear-memory page limit")
}


def private check_platform_values(var t : TestRun) {
    let actual_ptr_size = uint(typeinfo sizeof(default<void?>))
    let actual_long_size = uint(typeinfo sizeof(default<int64>))

    equal(t, M3_SIZEOF_PTR, actual_ptr_size, "M3_SIZEOF_PTR")
    check(t, M3_SIZEOF_PTR == 4u || M3_SIZEOF_PTR == 8u, "supported pointer size")
    equal(t, M3_SIZEOF_LONG, actual_long_size, "M3_SIZEOF_LONG")
    equal(t, M3_SIZEOF_LONG, 8u, "Daslang int64 size")

    check(t, M3_ARCH != "", "M3_ARCH must not be empty")

    let rv64 = M3_ARCH == "riscv64" || M3_ARCH == "riscv_64"
    equal(t, d_m3Use32BitSlots, !rv64, "d_m3Use32BitSlots target selection")
    equal(t, M3_SIZEOF_SLOT, d_m3Use32BitSlots ? 4u : 8u, "M3_SIZEOF_SLOT")
    equal(t, M3_HAS_TAIL_CALL, M3_ARCH != "wasm32", "M3_HAS_TAIL_CALL")
}


def private check_endianness(var t : TestRun) {
    check(t, M3_LITTLE_ENDIAN != M3_BIG_ENDIAN, "exactly one of M3_LITTLE_ENDIAN/M3_BIG_ENDIAN must be true")

    // Eden: the upstream observed_little_endian() reads the bytes of a uint16
    // through their address; the sandbox forbids that, and wasm3_defs fixes
    // the byte order to little-endian (see the module header). The expected
    // value is therefore the contract itself rather than an observation.
    let actual_little = true
    equal(t, M3_LITTLE_ENDIAN, actual_little, "M3_LITTLE_ENDIAN actual byte order")
    equal(t, M3_BIG_ENDIAN, !actual_little, "M3_BIG_ENDIAN actual byte order")
}


def private check_profiling_and_tracing_defaults(var t : TestRun) {
    check(t, !d_m3EnableOpProfiling, "d_m3EnableOpProfiling")
    check(t, !d_m3EnableOpTracing, "d_m3EnableOpTracing")
    check(t, !d_m3EnableWasiTracing, "d_m3EnableWasiTracing")
    equal(t, d_m3EnableStrace, 0u, "d_m3EnableStrace")
}


def private check_logging_defaults(var t : TestRun) {
    check(t, !d_m3LogParse, "d_m3LogParse")
    check(t, !d_m3LogModule, "d_m3LogModule")
    check(t, !d_m3LogCompile, "d_m3LogCompile")
    check(t, !d_m3LogWasmStack, "d_m3LogWasmStack")
    check(t, !d_m3LogEmit, "d_m3LogEmit")
    check(t, !d_m3LogCodePages, "d_m3LogCodePages")
    check(t, !d_m3LogRuntime, "d_m3LogRuntime")
    check(t, !d_m3LogNativeStack, "d_m3LogNativeStack")
    check(t, !d_m3LogHeapOps, "d_m3LogHeapOps")
    check(t, !d_m3LogTimestamps, "d_m3LogTimestamps")
}


def private check_other_defaults(var t : TestRun) {
    check(t, d_m3HasFloat, "d_m3HasFloat")
    check(t, !d_m3NoFloatDynamic, "d_m3NoFloatDynamic")
    check(t, d_m3ImplementFloat, "d_m3ImplementFloat")
    equal(t, d_m3ImplementFloat, d_m3HasFloat || d_m3NoFloatDynamic, "float configuration relation")

    check(t, !d_m3SkipStackCheck, "d_m3SkipStackCheck")
    check(t, !d_m3SkipMemoryBoundsCheck, "d_m3SkipMemoryBoundsCheck")
    check(t, !d_m3EnableCodePageRefCounting, "d_m3EnableCodePageRefCounting")
}


def private check_immutable_globals(var t : TestRun) {
    check(t, typeinfo is_const(d_m3CodePageAlignSize), "d_m3CodePageAlignSize is immutable")
    check(t, typeinfo is_const(d_m3MaxFunctionStackHeight), "d_m3MaxFunctionStackHeight is immutable")
    check(t, typeinfo is_const(d_m3MaxLinearMemoryPages), "d_m3MaxLinearMemoryPages is immutable")
    check(t, typeinfo is_const(d_m3MaxFunctionSlots), "d_m3MaxFunctionSlots is immutable")
    check(t, typeinfo is_const(d_m3FixedHeap), "d_m3FixedHeap is immutable")
    check(t, typeinfo is_const(d_m3Use32BitSlots), "d_m3Use32BitSlots is immutable")
    check(t, typeinfo is_const(d_m3RecordBacktraces), "d_m3RecordBacktraces is immutable")
    check(t, typeinfo is_const(d_m3HasFloat), "d_m3HasFloat is immutable")
    check(t, typeinfo is_const(M3_SIZEOF_PTR), "M3_SIZEOF_PTR is immutable")
    check(t, typeinfo is_const(M3_SIZEOF_SLOT), "M3_SIZEOF_SLOT is immutable")
}


// ============================================================================
// The upstream [test]
// ============================================================================


def test_m3_config_all(var t : TestRun; fx : FixtureSource) {
    check_general_defaults(t)
    check_derived_values(t)
    check_platform_values(t)
    check_endianness(t)
    check_profiling_and_tracing_defaults(t)
    check_logging_defaults(t)
    check_other_defaults(t)
    check_immutable_globals(t)
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_config(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_m3_config_all")
    test_m3_config_all(t, fx)
}
