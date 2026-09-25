options gen2
options indenting = 4

module m3_exception shared public

require modules/wasm3das/source/m3_config public   // Eden: project-root-relative path (upstream: ./m3_config.das)


/*
    Conservative Gen2 port of m3_exception.h.

    The C header is a pure macro layer emulating try/catch over the M3Result
    convention (m3Err_none == success). It has no runtime surface of its own;
    the port expands each macro in place at its call sites:

        _try                ->  var result : M3Result = m3Err_none

        _(TRY)              ->  result = TRY
                                if (result != m3Err_none) {
                                    EXCEPTION_PRINT(result)
                                    return result              // goto _catch
                                }

        _throw(ERROR)       ->  result = ERROR
                                EXCEPTION_PRINT(result)
                                return result                  // goto _catch

        _throwif(ERROR, C)  ->  if (C) { result = ERROR; EXCEPTION_PRINT(result); return result }

        _throwifnull(PTR)   ->  _throwif(m3Err_mallocFailed, PTR == null)
                                Eden: PTR is a handle, so the condition is
                                `handle == -1` (DESIGN.md section 4.1)

    Daslang has no goto: every expansion reaches the equivalent of the C
    `_catch` label by returning `result` directly from the failure point.
    The label itself carries no additional code in wasm3, so the translation
    is exact for every call shape the interpreter uses.

    C: EXCEPTION_PRINT(ERROR)

    Active only under d_m3EnableExceptionBreakpoint, where it forwards to
    ExceptionBreakpoint (m3_info.c). The active configuration sets
    d_m3EnableExceptionBreakpoint to false and compiles the macro to nothing,
    so no runtime helper is emitted here.

    Eden: deviations from the upstream port (.upstream/source/m3_exception.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md):
      - the require of m3_config is Eden-project-root relative
        (`require modules/wasm3das/source/m3_config public`, DESIGN
        section 6) instead of `./m3_config.das`; it stays a public re-export
        so users of m3_exception see the configuration as upstream does;
      - the `_throwifnull(PTR)` expansion tests a handle against -1 instead
        of a pointer against null, because the Eden port refers to runtime
        data by index (DESIGN section 4.1); the C error, m3Err_mallocFailed,
        is unchanged.
    Nothing else changes: the module still declares no function, type or
    constant, and M3Result with the m3Err_* strings stay in m3_core.das as
    in C (m3_core.h / wasm3.h). The expansion contract above is exercised
    by tests/eden/test_m3_exception.das.
*/
