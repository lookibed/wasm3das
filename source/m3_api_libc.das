options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (host functions run once
// per import call, so inlining costs startup only) is dropped, as in m3_bind:
// the option is untested in the editor (DESIGN.md section 1).

module m3_api_libc shared public

require modules/wasm3das/source/m3_bind public       // Eden: project-root-relative path (upstream: ./m3_bind.das)
require modules/wasm3das/source/m3_api_defs public   // Eden: project-root-relative path (upstream: ./m3_api_defs.das)
require strings                                      // Eden: character_at for HEXDIGITS and the "(null)" literal (upstream: peek_data)
require math
// Eden: the upstream `require daslib/fio` (stdout) is gone: the sandbox
// refuses fio, and the output goes to rt.stdoutBuffer (DESIGN 4.7).


/*
    Conservative Gen2 port of m3_api_libc.c.

    C order is preserved: m3_libc_abort, m3_libc_exit, m3_libc_memset,
    m3_libc_memmove, m3_libc_print, internal_itoa, m3_libc_printf,
    m3_libc_clock_ms, SuppressLookupFailure, m3_spectest_dummy,
    m3_LinkSpecTest, m3_LinkLibC.

    This wasm3 revision's m3_LinkSpecTest links only the seven spectest.print*
    functions. It does not provide spectest.global_i32/i64/f32/f64,
    spectest.memory or spectest.table: wasm3 has no host-global and no
    host-memory/table import mechanism, so a spec module importing those still
    fails to link. That is C behaviour, not a gap in the port.

    C-macro adaptations, applied once here:
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list; the
      port spells that list out. `_sp` is a cursor in C (`_sp++` inside the
      argument macros), so every raw function starts with a cursor and hands
      it to the m3Api* helpers of m3_api_defs.das.
    - m3ApiSuccess() expands to `return m3Err_none`.
    - m3ApiTrap(VALUE) expands to `return VALUE`.
    - m3ApiCheckMem(addr, len) is a function returning M3Result, so the C macro
      body `{ if (...) m3ApiTrap(...) }` becomes a call plus
      `if (result != m3Err_none) { return result }`.

    C `typedef uint32_t wasm_ptr_t; typedef uint32_t wasm_size_t;` are spelled
    as u32 at the sites that use them.

    Eden: deviations from the upstream port (.upstream/source/m3_api_libc.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.2, 4.5,
    4.7, 4.7c). The sandbox has no pointers and no files:
      - the requires are Eden-project-root relative (DESIGN section 6);
        daslib/fio is dropped; `options never_inline` is dropped.
      - every raw function is an M3RawCall
        `(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result`
        (C: `runtime, _ctx, _sp, _mem`) and opens with
        `var f = m3ApiFrame(sp)`, the cursor of m3_api_defs; the upstream
        reinterpret lines that re-declared `_sp` and the runtime are gone.
        `raw_return` is a cell index, m3ApiReturn_T(rt, raw_return, v)
        writes it.
      - a linear-memory pointer (i_ptr, o_dst, i_src, i_fmt, i_args,
        string_temp) is its offset into rt.mem (int); C's `*i_fmt++` reads
        rt.mem[fmt] and steps the index, C's `*i_args++` (a wasm_ptr_t*)
        reads the u32 with m3ApiReadMem32 and steps the index by 4.
      - memset / memmove are loops over rt.mem (C: libc memset / memmove on
        the host pointers). memmove keeps libc's overlap rule: the copy runs
        in the direction that keeps the source bytes intact. The upstream
        chunking for the pointer builtins has no counterpart. The upstream
        private helpers libc_memset / libc_memcpy / libc_memmove /
        libc_strnlen are replaced by libc_memset / libc_memmove over rt.mem
        and by m3ApiStrnlen of m3_api_defs.
      - stdout (C: `FILE* file = stdout`, putc / fputc / fputs / fwrite /
        fflush) is rt.stdoutBuffer : array<u8> (DESIGN 4.7). The private
        helpers libc_putc, libc_fputs and libc_fwrite append bytes; the
        output never passes through a daslang string, so a NUL byte from
        `%c` or from `_debug` survives (DESIGN 4.7c). fflush has nothing to
        do. The Eden host mirrors the buffer to `print`.
      - internal_itoa fills a caller-supplied array<u8> (C: `char s[]`),
        without the terminating NUL (the caller uses its length, C:
        `strnlen (buffer, sizeof(buffer))`); the reversal is C's in-place
        swap loop.
      - C reads the format one byte past a NUL that follows a lone `%`
        (the byte after the terminator, within the linear memory in
        practice). The port reads that byte too; a read at or beyond the
        end of rt.mem (C: past the linear memory, undefined behaviour) is
        taken as 0, which ends the format (libc_fmt_char).
      - clock_ms: C returns `clock() / (CLOCKS_PER_SEC/1000)`, the process
        CPU time in milliseconds. The sandbox has no CPU clock; the port
        returns the monotonic wall-clock milliseconds since the first call,
        from daslang's builtin `ref_time_ticks()` / `get_time_nsec(ref)`
        (both in the builtin module, which the editor accepts; upstream
        used the same pair). Both start near zero and both are used by wasm
        modules as a stopwatch. The reference is a module global, which
        the editor carries over a hot reload.
      - m3_LinkSpecTest / m3_LinkLibC take the runtime first (m3_bind's
        m3_LinkRawFunction does), then the module handle.
    Everything else (names, C order, control flow, checks and their order,
    the trap strings) is the C of m3_api_libc.c.
*/


// ============================================================================
// 1. m3_libc_abort
// ============================================================================


// C: m3ApiRawFunction (m3_libc_abort) { m3ApiTrap (m3Err_trapAbort); }
def public m3_libc_abort(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    return m3ApiTrap(m3Err_trapAbort)
}


// ============================================================================
// 2. m3_libc_exit
// ============================================================================


def public m3_libc_exit(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)

    // C: m3ApiGetArg (int32_t, code). The value is unused in C as well; the
    // read is kept because it is the C source, and the result is discarded.
    m3ApiGetArg_i32(rt, f)

    return m3ApiTrap(m3Err_trapExit)
}


// ============================================================================
// 3. m3_libc_memset
// ============================================================================


// Eden: C memset (i_ptr, i_value, i_size) over rt.mem; the byte is
// (unsigned char) i_value, as libc. The range was checked with m3ApiCheckMem
def private libc_memset(var rt : M3Runtime; i_ptr : int; i_value : int; i_size : u32) {
    let value = u8(uint(i_value) & 0xffu)
    for (i in range(int(i_size))) {
        rt.mem[i_ptr + i] = value
    }
}


// Eden: C memmove (o_dst, i_src, i_size) over rt.mem: an overlap is copied
// in the direction that keeps the source bytes intact, exactly as a libc
// memmove does. Both ranges were checked with m3ApiCheckMem
def private libc_memmove(var rt : M3Runtime; o_dst : int; i_src : int; i_size : u32) {
    let n = int(i_size)
    if (n == 0 || o_dst == i_src) {
        return
    }
    if (o_dst < i_src) {
        for (i in range(n)) {
            rt.mem[o_dst + i] = rt.mem[i_src + i]
        }
    } else {
        var i = n
        while (i > 0) {
            i--
            rt.mem[o_dst + i] = rt.mem[i_src + i]
        }
    }
}


def public m3_libc_memset(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                 // m3ApiReturnType (int32_t)

    let i_ptr = m3ApiGetArgMem(rt, f)                   // m3ApiGetArgMem (void*, i_ptr)
    let i_value = m3ApiGetArg_i32(rt, f)                // m3ApiGetArg (int32_t, i_value)
    let i_size = m3ApiGetArg_u32(rt, f)                 // m3ApiGetArg (wasm_size_t, i_size)

    let checked = m3ApiCheckMem(rt, i_ptr, u64(i_size))
    if (checked != m3Err_none) {
        return checked
    }

    libc_memset(rt, i_ptr, i_value, i_size)
    let result = m3ApiPtrToOffset(i_ptr)                // C: memset returns i_ptr

    // C: m3ApiReturn (result) with `int32_t* raw_return` - a 4-byte store.
    m3ApiReturn_u32(rt, raw_return, result)
    return m3ApiSuccess()
}


// ============================================================================
// 4. m3_libc_memmove
// ============================================================================


def public m3_libc_memmove(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                 // m3ApiReturnType (int32_t)

    let o_dst = m3ApiGetArgMem(rt, f)                   // m3ApiGetArgMem (void*, o_dst)
    let i_src = m3ApiGetArgMem(rt, f)                   // m3ApiGetArgMem (void*, i_src)
    let i_size = m3ApiGetArg_u32(rt, f)                 // m3ApiGetArg (wasm_size_t, i_size)

    var checked : M3Result = m3ApiCheckMem(rt, o_dst, u64(i_size))
    if (checked != m3Err_none) {
        return checked
    }
    checked = m3ApiCheckMem(rt, i_src, u64(i_size))
    if (checked != m3Err_none) {
        return checked
    }

    libc_memmove(rt, o_dst, i_src, i_size)
    let result = m3ApiPtrToOffset(o_dst)                // C: memmove returns o_dst

    m3ApiReturn_u32(rt, raw_return, result)
    return m3ApiSuccess()
}


// ============================================================================
// 5. m3_libc_print
// ============================================================================


// Eden: C putc / fputc (ch, stdout): one byte appended to rt.stdoutBuffer
// (C `char`: the low 8 bits)
def private libc_putc(var rt : M3Runtime; ch : int) {
    push(rt.stdoutBuffer, u8(uint(ch) & 0xffu))
}


// Eden: C fputs (text, stdout) of a host literal ("(null)") or of the
// internal_itoa buffer: bytes appended to rt.stdoutBuffer
def private libc_fputs(var rt : M3Runtime; text : string) {
    for (i in range(length(text))) {
        libc_putc(rt, character_at(text, i))
    }
}


// Eden: C fwrite (ptr, 1, len, stdout) of linear memory: rt.mem[ptr ..
// ptr + len) appended to rt.stdoutBuffer byte for byte (DESIGN 4.7c). The
// range was checked with m3ApiCheckMem
def private libc_fwrite(var rt : M3Runtime; ptr : int; len : int) {
    for (i in range(len)) {
        push(rt.stdoutBuffer, rt.mem[ptr + i])
    }
}


def public m3_libc_print(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                 // m3ApiReturnType (uint32_t)

    let i_ptr = m3ApiGetArgMem(rt, f)                   // m3ApiGetArgMem (void*, i_ptr)
    let i_size = m3ApiGetArg_u32(rt, f)                 // m3ApiGetArg (wasm_size_t, i_size)

    let checked = m3ApiCheckMem(rt, i_ptr, u64(i_size))
    if (checked != m3Err_none) {
        return checked
    }

    // C: fwrite (i_ptr, i_size, 1, stdout); fflush (stdout);
    // Eden: appended to rt.stdoutBuffer; there is nothing to flush
    libc_fwrite(rt, i_ptr, int(i_size))

    m3ApiReturn_u32(rt, raw_return, i_size)
    return m3ApiSuccess()
}


// ============================================================================
// 6. internal_itoa
// ============================================================================


// C: static char const HEXDIGITS[0x10] = { '0', ..., 'F' }, indexed by digit.
let private HEXDIGITS = "0123456789ABCDEF"


/*
    C: static void internal_itoa (int n, char s[], int radix).

    Eden: `s` is an array<u8> the function fills (C: a char buffer of the
    caller); the terminating NUL is not stored, the caller takes
    length(s) where C takes strnlen (buffer, sizeof(buffer)). The digit
    generation, the sign handling and the in-place reversal follow C
    statement for statement.

    Documented deviation (upstream): for n == INT32_MIN the C negation
    `n = -n` overflows, `n % radix` stays negative and C indexes HEXDIGITS
    out of bounds (undefined behaviour, no reproducible output). The port
    takes the absolute value of the digit index, so the operation is
    defined: the loop then ends after one digit, as C's `(n /= radix) > 0`
    does for a negative n.
*/
def private internal_itoa(i_n : int; var s : array<u8>; radix : int) {
    var n = i_n
    let sign = n
    if (sign < 0) {
        n = -n
    }
    clear(s)
    while (true) {   // C: do { s[i++] = HEXDIGITS[n % radix]; } while ((n /= radix) > 0);
        push(s, u8(character_at(HEXDIGITS, abs(n % radix))))
        n /= radix
        if (n <= 0) {
            break
        }
    }

    if (sign < 0) {
        push(s, u8('-'))
    }

    // reverse
    var i = 0
    var j = length(s) - 1
    while (i < j) {
        let c = s[i]
        s[i] = s[j]
        s[j] = c
        i++
        j--
    }
}


// ============================================================================
// 7. m3_libc_printf
// ============================================================================


// Eden: C `*i_fmt` at the format offset `at`; a read at or past the end of
// rt.mem is 0 (C: past the linear memory, undefined; see the header)
def private libc_fmt_char(rt : M3Runtime; at : int) : int {
    if (at < 0 || at >= length(rt.mem)) {
        return 0
    }
    return int(rt.mem[at])
}


/*
    C main body of m3_libc_printf: a minimal printf. It knows %c, %d, %x
    (upper-case digits, a negative value as '-' and the digits of its
    magnitude) and %s; every other character after '%' (including '%'
    itself and the 'l' of %lld, the 'u' of %u, the 'f' of %f) is written as
    it is and consumes no argument.

    Deviations, all local:
    - C's `int32_t length` is spelled `_length`: `length` is the Daslang
      builtin this function calls.
    - C's switch has its `default:` label inside the `case 's'` block (a
      misplaced brace in the C source); because `case 's'` ends with `break`
      the observable behaviour is that of a normal `default`, which is what the
      chain of `if`s below implements.
    - Eden: C writes with putc/fputc/fputs/fwrite on stdout and never
      flushes; the port appends the same bytes to rt.stdoutBuffer in the same
      order, so a trap in the middle leaves exactly the bytes C would have
      written.
    - Eden: i_fmt, i_args and string_temp are offsets into rt.mem (see the
      header).
*/
def public m3_libc_printf(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                 // m3ApiReturnType (int32_t)

    let i_fmt = m3ApiGetArgMem(rt, f)                   // m3ApiGetArgMem (const char*, i_fmt)
    let i_args = m3ApiGetArgMem(rt, f)                  // m3ApiGetArgMem (wasm_ptr_t*, i_args)

    if (m3ApiIsNullPtr(i_fmt)) {
        m3ApiReturn_i32(rt, raw_return, 0)
        return m3ApiSuccess()
    }

    var checked : M3Result = m3ApiCheckMem(rt, i_fmt, 1ul)
    if (checked != m3Err_none) {
        return checked
    }
    let fmt_len = m3ApiStrnlen(rt, i_fmt, 1024)
    checked = m3ApiCheckMem(rt, i_fmt, u64(fmt_len) + 1ul)   // include `\0`
    if (checked != m3Err_none) {
        return checked
    }

    // C: FILE* file = stdout;
    // Eden: rt.stdoutBuffer (libc_putc / libc_fputs / libc_fwrite)

    var fmt = i_fmt     // Eden: C's `i_fmt++` cursor
    var args = i_args   // Eden: C's `i_args++` cursor, in bytes
    var _length = 0
    var buffer : array<u8>
    while (true) {   // C: while ((ch = *i_fmt++))
        var ch = libc_fmt_char(rt, fmt)
        fmt++
        if (ch == 0) {
            break
        }

        if (ch != '%') {
            libc_putc(rt, ch)
            _length++
            continue
        }

        ch = libc_fmt_char(rt, fmt)
        fmt++

        if (ch == 'c') {
            checked = m3ApiCheckMem(rt, args, 4ul)          // sizeof(wasm_ptr_t)
            if (checked != m3Err_none) {
                return checked
            }
            let char_temp = int(m3ApiReadMem32(rt, args) & 0xffu)   // C: char char_temp = *i_args++
            args += 4
            libc_putc(rt, char_temp)
            _length++
        } elif (ch == 'd' || ch == 'x') {
            checked = m3ApiCheckMem(rt, args, 4ul)          // sizeof(wasm_ptr_t)
            if (checked != m3Err_none) {
                return checked
            }
            let int_temp = int(m3ApiReadMem32(rt, args))    // C: int int_temp = *i_args++
            args += 4
            internal_itoa(int_temp, buffer, ch == 'x' ? 16 : 10)
            for (b in buffer) {                             // C: fputs (buffer, file)
                libc_putc(rt, int(b))
            }
            _length += length(buffer)
        } elif (ch == 's') {
            checked = m3ApiCheckMem(rt, args, 4ul)          // sizeof(wasm_ptr_t)
            if (checked != m3Err_none) {
                return checked
            }

            let arg = m3ApiReadMem32(rt, args)
            let string_temp = m3ApiOffsetToPtr(arg)         // C: (const char*)m3ApiOffsetToPtr(*i_args++)
            args += 4
            var string_len = 0
            if (m3ApiIsNullPtr(string_temp)) {
                // C: string_temp = "(null)"; string_len = 6;
                string_len = 6
                libc_fputs(rt, "(null)")
            } else {
                string_len = m3ApiStrnlen(rt, string_temp, 1024)
                checked = m3ApiCheckMem(rt, string_temp, u64(string_len) + 1ul)
                if (checked != m3Err_none) {
                    return checked
                }
                libc_fwrite(rt, string_temp, string_len)    // C: fwrite (string_temp, 1, string_len, file)
            }
            _length += string_len
        } else {
            libc_putc(rt, ch)                               // C: default: fputc (ch, file)
            _length++
        }
    }

    m3ApiReturn_i32(rt, raw_return, _length)
    return m3ApiSuccess()
}


// ============================================================================
// 8. m3_libc_clock_ms
// ============================================================================


/*
    C returns `clock() / (CLOCKS_PER_SEC/1000)`, i.e. the process CPU time in
    milliseconds. Daslang exposes no CPU clock, only the monotonic
    ref_time_ticks()/get_time_nsec() pair, so the port returns the wall-clock
    milliseconds elapsed since the first call. Both start near zero at program
    start and both are used by wasm modules only as a stopwatch, so the
    difference is visible only when the module is descheduled.
    Eden: the same pair works in the editor (builtin module); see the header.
*/
var private s_clock_ref = 0l


def public m3_libc_clock_ms(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    var f = m3ApiFrame(sp)
    let raw_return = m3ApiReturnType(f)                 // m3ApiReturnType (uint32_t)

    if (s_clock_ref == 0l) {
        s_clock_ref = ref_time_ticks()
    }
    let clock_ms = get_time_nsec(s_clock_ref) / 1000000l

    m3ApiReturn_u32(rt, raw_return, u32(clock_ms))
    return m3ApiSuccess()
}


// ============================================================================
// 9. SuppressLookupFailure
// ============================================================================


def private SuppressLookupFailure(i_result : M3Result) : M3Result {
    if (i_result == m3Err_functionLookupFailed) {
        return m3Err_none
    } else {
        return i_result
    }
}


// ============================================================================
// 10. m3_spectest_dummy
// ============================================================================


// C: m3ApiRawFunction (m3_spectest_dummy) { m3ApiSuccess (); }
def public m3_spectest_dummy(var rt : M3Runtime; ctx : M3ImportContext; sp : int) : M3Result {
    return m3ApiSuccess()
}


// ============================================================================
// 11. m3_LinkSpecTest
// ============================================================================


// C parameter `module` renamed to `_module`: `module` is a daslang keyword.
// Eden: the runtime first (see the header)
def public m3_LinkSpecTest(var rt : M3Runtime; _module : IM3Module) : M3Result {
    let spectest = "spectest"

    // C declares `M3Result result = m3Err_none;` first; the initialiser is
    // dead there too, because the first `_ (...)` overwrites it before any
    // read, so the first link becomes the declaration here.
    var result : M3Result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print", "v()", @@m3_spectest_dummy))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print_i32", "v(i)", @@m3_spectest_dummy))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print_i64", "v(I)", @@m3_spectest_dummy))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print_f32", "v(f)", @@m3_spectest_dummy))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print_f64", "v(F)", @@m3_spectest_dummy))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print_i32_f32", "v(if)", @@m3_spectest_dummy))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, spectest, "print_i64_f64", "v(IF)", @@m3_spectest_dummy))

    return result
}


// ============================================================================
// 12. m3_LinkLibC
// ============================================================================


// C parameter `module` renamed to `_module`: `module` is a daslang keyword.
// Eden: the runtime first (see the header)
def public m3_LinkLibC(var rt : M3Runtime; _module : IM3Module) : M3Result {
    let env = "env"

    // As in m3_LinkSpecTest, C's dead `M3Result result = m3Err_none;`
    // initialiser becomes the declaration of the first link.
    var result : M3Result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "_debug", "i(*i)", @@m3_libc_print))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "_memset", "*(*ii)", @@m3_libc_memset))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "_memmove", "*(**i)", @@m3_libc_memmove))
    if (result != m3Err_none) {
        return result
    }
    // just alias of memmove
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "_memcpy", "*(**i)", @@m3_libc_memmove))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "_abort", "v()", @@m3_libc_abort))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "_exit", "v(i)", @@m3_libc_exit))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "clock_ms", "i()", @@m3_libc_clock_ms))
    if (result != m3Err_none) {
        return result
    }
    result = SuppressLookupFailure(m3_LinkRawFunction(rt, _module, env, "printf", "i(**)", @@m3_libc_printf))

    return result
}
