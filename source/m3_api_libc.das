options gen2
options indenting = 4

module m3_api_libc shared public

require ./m3_bind.das public


/*
    Conservative Gen2 port of the spectest half of m3_api_libc.c.

    Scope: SuppressLookupFailure, m3_spectest_dummy and m3_LinkSpecTest, which
    are what the spec testsuite modules need in order to link. The libc half of
    the same C file (m3_libc_abort/exit/memset/memmove/print/printf/clock_ms and
    m3_LinkLibC) needs the m3Api memory-argument macro family and is not ported
    yet; it is listed as remaining work in PORTING_MANIFEST.md.

    This wasm3 revision's m3_LinkSpecTest links only the seven spectest.print*
    functions. It does not provide spectest.global_i32/i64/f32/f64,
    spectest.memory or spectest.table: wasm3 has no host-global and no
    host-memory/table import mechanism, so a spec module importing those still
    fails to link. That is C behaviour, not a gap in the port.

    C-macro adaptations, applied once here:
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list
      (runtime, _ctx, _sp, _mem); the port spells that list out.
    - m3ApiSuccess() expands to `return m3Err_none`.
*/


// ============================================================================
// 1. SuppressLookupFailure
// ============================================================================


def private SuppressLookupFailure(i_result : M3Result) : M3Result {
    if (i_result == m3Err_functionLookupFailed) {
        return m3Err_none
    } else {
        return i_result
    }
}


// ============================================================================
// 2. m3_spectest_dummy
// ============================================================================


// C: m3ApiRawFunction (m3_spectest_dummy) { m3ApiSuccess (); }
def public m3_spectest_dummy(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    return m3Err_none
}


// ============================================================================
// 3. m3_LinkSpecTest
// ============================================================================


// C parameter `module` renamed to `_module`: `module` is a daslang keyword.
def public m3_LinkSpecTest(var _module : IM3Module) : M3Result {
    let spectest = "spectest"

    // C declares `M3Result result = m3Err_none;` first; the initialiser is
    // dead there too, because the first `_ (...)` overwrites it before any
    // read, so the first link becomes the declaration here.
    var result : M3Result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print", "v()", @@m3_spectest_dummy))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print_i32", "v(i)", @@m3_spectest_dummy))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print_i64", "v(I)", @@m3_spectest_dummy))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print_f32", "v(f)", @@m3_spectest_dummy))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print_f64", "v(F)", @@m3_spectest_dummy))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print_i32_f32", "v(if)", @@m3_spectest_dummy))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, spectest, "print_i64_f64", "v(IF)", @@m3_spectest_dummy))

    return result
}
