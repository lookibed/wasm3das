options gen2
options indenting = 4

module m3_exception shared public

require ./m3_config.das public
require ./m3_core.das public


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

    Daslang has no goto: every expansion reaches the equivalent of the C
    `_catch` label by returning `result` directly from the failure point.
    The label itself carries no additional code in wasm3, so the translation
    is exact for every call shape the interpreter uses.

    C: EXCEPTION_PRINT(ERROR)

    Active only under d_m3EnableExceptionBreakpoint, where it forwards to
    ExceptionBreakpoint (m3_info.c). The active configuration sets
    d_m3EnableExceptionBreakpoint to false and compiles the macro to nothing,
    so no runtime helper is emitted here.
*/
