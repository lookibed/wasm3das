options gen2
options indenting = 4

module test_m3_exception shared public

require modules/wasm3das/source/eden_test
require modules/wasm3das/source/m3_exception

/*
    test_m3_exception.das: Eden tests of source/m3_exception.das.

    There is no upstream test file for this module (STATE.json lists none):
    m3_exception.h is a pure macro layer and the port declares no function,
    type or constant. What the module promises is (1) the public re-export of
    m3_config, which is why this file requires only m3_exception and reads
    the configuration through it, and (2) the expansion table of its header
    comment, one Daslang shape per C macro. Each shape below is written out
    exactly as the header prescribes, inside a small private function, and
    the tests assert the M3Result-convention behaviour the C macros have:
    success is m3Err_none, the first failing `_()` short-circuits to _catch,
    `_throw` always reaches _catch, `_throwif` only when its condition holds,
    `_throwifnull` maps a null handle to m3Err_mallocFailed.

    M3Result and the m3Err_* constants belong to m3_core (module 4, not yet
    ported when this file lands), so the two values the tests need are
    private copies of their C text (wasm3.h: m3Err_none is NULL, which the
    port spells "", m3Err_mallocFailed is "memory allocation failed").

    Eden: _throwifnull tests a handle against -1 instead of a pointer
    against null (DESIGN.md section 4.1), as the module header says.
*/


// C: wasm3.h d_m3ErrorConst (none, NULL); the port spells success ""
let private m3Err_none = ""
// C: wasm3.h d_m3ErrorConst (mallocFailed, "memory allocation failed")
let private m3Err_mallocFailed = "memory allocation failed"


// ============================================================================
// The expansion shapes, one private function per macro
// ============================================================================


// C: _try; _(first); _(second); _catch: return result
// `reached` counts the `_()` sites entered, to show the short-circuit
def private try_chain(first, second : string; var reached : int&) : string {
    var result = m3Err_none              // _try
    reached++
    result = first                       // _(first)
    if (result != m3Err_none) {
        return result                    // goto _catch
    }
    reached++
    result = second                      // _(second)
    if (result != m3Err_none) {
        return result                    // goto _catch
    }
    return result                        // _catch:
}


// C: _try; _throw(error); _catch: return result
def private throw_always(error : string) : string {
    var result = m3Err_none              // _try
    result = error                       // _throw(error)
    return result                        // goto _catch
}


// C: _try; _throwif(error, cond); afterReached = true; _catch: return result
def private throw_if(error : string; cond : bool; var afterReached : bool&) : string {
    var result = m3Err_none              // _try
    if (cond) {                          // _throwif(error, cond)
        result = error
        return result                    // goto _catch
    }
    afterReached = true
    return result                        // _catch:
}


// C: _try; _throwifnull(ptr); afterReached = true; _catch: return result
// Eden: ptr is a handle, null is -1 (DESIGN.md section 4.1)
def private throw_if_null(handle : int; var afterReached : bool&) : string {
    var result = m3Err_none              // _try
    if (handle == -1) {                  // _throwifnull(handle)
        result = m3Err_mallocFailed
        return result                    // goto _catch
    }
    afterReached = true
    return result                        // _catch:
}


// ============================================================================
// The re-export of m3_config and EXCEPTION_PRINT
// ============================================================================


def test_m3_exception_reexports_config(var t : TestRun; fx : FixtureSource) {
    // this module requires only m3_exception; every name below comes
    // through its `require ... m3_config public`, as upstream's
    // `require ./m3_config.das public` provides
    equal(t, d_m3MaxFunctionStackHeight, 2000u, "d_m3MaxFunctionStackHeight through m3_exception")
    equal(t, d_m3CodePageAlignSize, 32768u, "d_m3CodePageAlignSize through m3_exception")
    check(t, d_m3VerboseErrorMessages, "d_m3VerboseErrorMessages through m3_exception")
    check(t, M3_ARCH != "", "wasm3_defs reaches through m3_exception too")
}


def test_exception_print_disabled(var t : TestRun; fx : FixtureSource) {
    // EXCEPTION_PRINT compiles to nothing unless d_m3EnableExceptionBreakpoint
    // is set; the active configuration keeps it off, so the module emits no
    // runtime helper (the header's last paragraph)
    check(t, !d_m3EnableExceptionBreakpoint, "d_m3EnableExceptionBreakpoint is off")
    check(t, typeinfo is_const(d_m3EnableExceptionBreakpoint), "d_m3EnableExceptionBreakpoint is immutable")
}


// ============================================================================
// _try and _(TRY)
// ============================================================================


def test_try(var t : TestRun; fx : FixtureSource) {
    var reached = 0
    let ok = try_chain(m3Err_none, m3Err_none, reached)
    equal_str(t, ok, m3Err_none, "_try starts as m3Err_none and stays so when every _() succeeds")
    equal(t, reached, 2, "every _() site is entered when none fails")

    // the result the caller sees is the M3Result convention: "" is success
    is_ok(t, ok, "_catch of a clean chain is success")
}


def test_try_check(var t : TestRun; fx : FixtureSource) {
    var reached = 0
    let firstFails = try_chain("first failed", m3Err_none, reached)
    is_err(t, firstFails, "first failed", "_() forwards the first failure to _catch")
    equal(t, reached, 1, "the second _() is never entered after the first fails")

    reached = 0
    let secondFails = try_chain(m3Err_none, "second failed", reached)
    is_err(t, secondFails, "second failed", "_() forwards a later failure to _catch")
    equal(t, reached, 2, "a succeeding _() continues to the next site")

    reached = 0
    let bothFail = try_chain("first failed", "second failed", reached)
    is_err(t, bothFail, "first failed", "the first failing _() wins")
    equal(t, reached, 1, "the chain stops at the first failure")
}


// ============================================================================
// _throw
// ============================================================================


def test_throw(var t : TestRun; fx : FixtureSource) {
    is_err(t, throw_always(m3Err_mallocFailed), m3Err_mallocFailed, "_throw reaches _catch with the error")
    is_err(t, throw_always("some error"), "some error", "_throw keeps the error text as is")

    // C: _throw(m3Err_none) jumps to _catch with a NULL result, i.e. success
    is_ok(t, throw_always(m3Err_none), "_throw of m3Err_none is success at _catch")
}


// ============================================================================
// _throwif
// ============================================================================


def test_throwif(var t : TestRun; fx : FixtureSource) {
    var afterReached = false
    let notThrown = throw_if("guarded error", false, afterReached)
    is_ok(t, notThrown, "_throwif with a false condition does not throw")
    check(t, afterReached, "_throwif with a false condition falls through")

    afterReached = false
    let thrown = throw_if("guarded error", true, afterReached)
    is_err(t, thrown, "guarded error", "_throwif with a true condition throws its error")
    check(t, !afterReached, "_throwif with a true condition skips what follows")
}


// ============================================================================
// _throwifnull
// ============================================================================


def test_throwifnull(var t : TestRun; fx : FixtureSource) {
    var afterReached = false
    let nullHandle = throw_if_null(-1, afterReached)
    is_err(t, nullHandle, m3Err_mallocFailed, "_throwifnull of a null handle is m3Err_mallocFailed")
    equal_str(t, nullHandle, "memory allocation failed", "m3Err_mallocFailed keeps the C text")
    check(t, !afterReached, "_throwifnull of a null handle skips what follows")

    afterReached = false
    let firstHandle = throw_if_null(0, afterReached)
    is_ok(t, firstHandle, "_throwifnull of handle 0 does not throw (0 is a valid index)")
    check(t, afterReached, "_throwifnull of handle 0 falls through")

    afterReached = false
    let someHandle = throw_if_null(7, afterReached)
    is_ok(t, someHandle, "_throwifnull of a positive handle does not throw")
    check(t, afterReached, "_throwifnull of a positive handle falls through")
}


// ============================================================================
// Runner
// ============================================================================


def public run_tests_m3_exception(var t : TestRun; fx : FixtureSource) {
    begin_test(t, "test_m3_exception_reexports_config")
    test_m3_exception_reexports_config(t, fx)
    begin_test(t, "test_exception_print_disabled")
    test_exception_print_disabled(t, fx)
    begin_test(t, "test_try")
    test_try(t, fx)
    begin_test(t, "test_try_check")
    test_try_check(t, fx)
    begin_test(t, "test_throw")
    test_throw(t, fx)
    begin_test(t, "test_throwif")
    test_throwif(t, fx)
    begin_test(t, "test_throwifnull")
    test_throwifnull(t, fx)
}
