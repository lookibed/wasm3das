options gen2
options indenting = 4

module m3_api_libc shared public

require ./m3_bind.das public
require ./m3_api_defs.das public
require daslib/fio
require strings
require math


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
    - m3ApiRawFunction(NAME) expands to the M3RawCall parameter list
      (runtime, _ctx, _sp, _mem); the port spells that list out. `_sp` is a
      cursor in C (`_sp++` inside the argument macros), so every raw function
      starts with `var sp = _sp` and hands `sp` to the m3Api* helpers of
      m3_api_defs.das.
    - m3ApiSuccess() expands to `return m3Err_none`.
    - m3ApiTrap(VALUE) expands to `return VALUE`.
    - m3ApiCheckMem(addr, len) is a function returning M3Result, so the C macro
      body `{ if (...) m3ApiTrap(...) }` becomes a call plus
      `if (result != m3Err_none) { return result }`.

    C `typedef uint32_t wasm_ptr_t; typedef uint32_t wasm_size_t;` are spelled
    as u32 at the sites that use them.
*/


// ============================================================================
// 1. m3_libc_abort
// ============================================================================


// C: m3ApiRawFunction (m3_libc_abort) { m3ApiTrap (m3Err_trapAbort); }
def public m3_libc_abort(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    return m3Err_trapAbort
}


// ============================================================================
// 2. m3_libc_exit
// ============================================================================


def public m3_libc_exit(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))

    // C: m3ApiGetArg (int32_t, code). The value is unused in C as well; the
    // read is kept because it is the C source, and the result is discarded.
    m3ApiGetArg_i32(sp)

    return m3Err_trapExit
}


// ============================================================================
// 3. m3_libc_memset
// ============================================================================


/*
    C memset/memmove/strnlen operate on host pointers into linear memory.
    Daslang has memset8 and memcpy but no memmove, so the byte moves are
    spelled out below; the chunking keeps the `int` byte count of the Daslang
    builtins valid for a linear memory larger than 2 GiB.
*/
let private c_libcChunkMax = 0x10000000u


def private libc_memset(i_ptr : void?; i_value : int; i_size : u32) {
    unsafe {
        var p = reinterpret<u8?>(i_ptr)
        var remaining = i_size
        while (remaining != 0u) {
            let chunk = min(remaining, c_libcChunkMax)
            memset8(reinterpret<void?>(p), u8(uint(i_value) & 0xffu), int(chunk))
            p += int(chunk)
            remaining -= chunk
        }
    }
}


def private libc_memcpy(o_dst : void?; i_src : void?; i_size : u32) {
    unsafe {
        var dst = reinterpret<u8?>(o_dst)
        var src = reinterpret<u8?>(i_src)
        var remaining = i_size
        while (remaining != 0u) {
            let chunk = min(remaining, c_libcChunkMax)
            memcpy(reinterpret<void?>(dst), reinterpret<void?>(src), u64(chunk))
            dst += int(chunk)
            src += int(chunk)
            remaining -= chunk
        }
    }
}


// C memmove. Daslang has no memmove builtin: the non-overlapping case is a
// memcpy, an overlap is copied in the direction that keeps the source bytes
// intact, exactly as a libc memmove does.
def private libc_memmove(o_dst : void?; i_src : void?; i_size : u32) {
    if (i_size == 0u) { return }

    let dst_at = intptr(o_dst)
    let src_at = intptr(i_src)
    if (dst_at == src_at) { return }

    if (dst_at >= src_at + u64(i_size) || src_at >= dst_at + u64(i_size)) {
        libc_memcpy(o_dst, i_src, i_size)
        return
    }

    unsafe {
        var dst = reinterpret<u8?>(o_dst)
        var src = reinterpret<u8?>(i_src)
        if (dst_at < src_at) {
            for (i in 0 .. int(i_size)) {
                dst[i] = src[i]
            }
        } else {
            var i = int(i_size)
            while (i > 0) {
                i--
                dst[i] = src[i]
            }
        }
    }
}


// C strnlen over linear memory.
def private libc_strnlen(i_ptr : void?; i_maxlen : int) : int {
    unsafe {
        let p = reinterpret<u8?>(i_ptr)
        var n = 0
        while (n < i_maxlen && p[n] != 0u8) {
            n++
        }
        return n
    }
}


def public m3_libc_memset(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    /*
        A Daslang function parameter is const, and a const pointer value
        cannot initialise a non-const pointer variable, so the two C
        parameters that are mutable in C - the `_sp` cursor that the argument
        macros advance and the `IM3Runtime` that m3ApiCheckMem takes by
        value - are re-declared here through reinterpret. The pointees are the
        same objects; nothing is copied. The same two lines open every raw
        function below that needs them.
    */
    var sp = unsafe(reinterpret<u64?>(_sp))
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    let raw_return = m3ApiReturnType(sp)                    // m3ApiReturnType (int32_t)

    let i_ptr = m3ApiGetArgMem(sp, _mem)                    // m3ApiGetArgMem (void*, i_ptr)
    let i_value = m3ApiGetArg_i32(sp)                       // m3ApiGetArg (int32_t, i_value)
    let i_size = m3ApiGetArg_u32(sp)                        // m3ApiGetArg (wasm_size_t, i_size)

    let checked = m3ApiCheckMem(rt, _mem, i_ptr, u64(i_size))
    if (checked != m3Err_none) { return checked }

    libc_memset(i_ptr, i_value, i_size)
    let result = m3ApiPtrToOffset(_mem, i_ptr)

    // C: m3ApiReturn (result) with `int32_t* raw_return` - a 4-byte store.
    m3ApiReturn_u32(raw_return, result)
    return m3Err_none
}


// ============================================================================
// 4. m3_libc_memmove
// ============================================================================


def public m3_libc_memmove(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    let raw_return = m3ApiReturnType(sp)                    // m3ApiReturnType (int32_t)

    let o_dst = m3ApiGetArgMem(sp, _mem)                    // m3ApiGetArgMem (void*, o_dst)
    let i_src = m3ApiGetArgMem(sp, _mem)                    // m3ApiGetArgMem (void*, i_src)
    let i_size = m3ApiGetArg_u32(sp)                        // m3ApiGetArg (wasm_size_t, i_size)

    var checked : M3Result = m3ApiCheckMem(rt, _mem, o_dst, u64(i_size))
    if (checked != m3Err_none) { return checked }
    checked = m3ApiCheckMem(rt, _mem, i_src, u64(i_size))
    if (checked != m3Err_none) { return checked }

    libc_memmove(o_dst, i_src, i_size)
    let result = m3ApiPtrToOffset(_mem, o_dst)

    m3ApiReturn_u32(raw_return, result)
    return m3Err_none
}


// ============================================================================
// 5. m3_libc_print
// ============================================================================


def public m3_libc_print(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    let raw_return = m3ApiReturnType(sp)                    // m3ApiReturnType (uint32_t)

    let i_ptr = m3ApiGetArgMem(sp, _mem)                    // m3ApiGetArgMem (void*, i_ptr)
    let i_size = m3ApiGetArg_u32(sp)                        // m3ApiGetArg (wasm_size_t, i_size)

    let checked = m3ApiCheckMem(rt, _mem, i_ptr, u64(i_size))
    if (checked != m3Err_none) { return checked }

    // C: fwrite (i_ptr, i_size, 1, stdout); fflush (stdout);
    // _builtin_write is the raw pointer+length write behind daslib fwrite.
    unsafe {
        _builtin_write(fstdout(), i_ptr, int(i_size))
    }
    fflush(fstdout())

    m3ApiReturn_u32(raw_return, i_size)
    return m3Err_none
}


// ============================================================================
// 6. internal_itoa
// ============================================================================


// C: static char const HEXDIGITS[0x10] = { '0', ..., 'F' }, indexed by digit.
let private HEXDIGITS = "0123456789ABCDEF"


// A C `const char*` walked by index; peek_data copies the bytes once.
def private str_bytes(text : string) : array<u8> {
    var bytes : array<u8>
    peek_data(text) $(data) {
        bytes := data
    }
    return <- bytes
}


/*
    C: static void internal_itoa (int n, char s[], int radix).

    The port returns the string instead of filling a caller-supplied buffer,
    so the caller's `length += strnlen (buffer, sizeof(buffer))` becomes
    `length(text)`; the digit generation, the sign handling and the final
    reversal follow C statement for statement.

    Documented deviation: for n == INT32_MIN the C negation `n = -n` overflows,
    `n % radix` stays negative and C indexes HEXDIGITS out of bounds (undefined
    behaviour, no reproducible output). The port takes the absolute value of
    the digit index, so the operation is defined.
*/
def private internal_itoa(i_n : int; radix : int) : string {
    let digits = str_bytes(HEXDIGITS)

    var n = i_n
    let sign = n
    if (sign < 0) { n = -n }

    var s : array<u8>
    while (true) {   // C: do { ... } while ((n /= radix) > 0);
        s |> push(digits[abs(n % radix)])
        n /= radix
        if (n <= 0) { break }
    }

    if (sign < 0) { s |> push(u8('-')) }

    // reverse
    let count = length(s)
    return build_string() $(var w) {
        for (i in 0 .. count) {
            w |> write_char(int(s[count - 1 - i]))
        }
    }
}


// ============================================================================
// 7. m3_libc_printf
// ============================================================================


/*
    C main body of m3_libc_printf.

    Deviations, all local:
    - C's `int32_t length` is spelled `_length`: `length` is the Daslang
      builtin this function calls for the itoa result.
    - C's switch has its `default:` label inside the `case 's'` block (a
      misplaced brace in the C source); because `case 's'` ends with `break`
      the observable behaviour is that of a normal `default`, which is what the
      chain of `if`s below implements.
    - C writes with putc/fputs/fwrite on stdout and never flushes; the port
      writes the same bytes to fstdout() in the same order and also does not
      flush, so a trap in the middle leaves exactly the bytes C would have
      written.
*/
def public m3_libc_printf(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    var rt = unsafe(reinterpret<IM3Runtime>(runtime))
    let raw_return = m3ApiReturnType(sp)                    // m3ApiReturnType (int32_t)

    let i_fmt = m3ApiGetArgMem(sp, _mem)                    // m3ApiGetArgMem (const char*, i_fmt)
    let i_args = m3ApiGetArgMem(sp, _mem)                   // m3ApiGetArgMem (wasm_ptr_t*, i_args)

    if (m3ApiIsNullPtr(_mem, i_fmt)) {
        m3ApiReturn_i32(raw_return, 0)
        return m3Err_none
    }

    var checked : M3Result = m3ApiCheckMem(rt, _mem, i_fmt, 1ul)
    if (checked != m3Err_none) { return checked }
    let fmt_len = libc_strnlen(i_fmt, 1024)
    checked = m3ApiCheckMem(rt, _mem, i_fmt, u64(fmt_len) + 1ul)   // include `\0`
    if (checked != m3Err_none) { return checked }

    // C: FILE* file = stdout;
    let out_file = fstdout()

    var _length = 0
    unsafe {
        var fmt = reinterpret<u8?>(i_fmt)
        var args = reinterpret<u32?>(i_args)

        while (true) {   // C: while ((ch = *i_fmt++))
            var ch = int(fmt[0])
            fmt += 1
            if (ch == 0) { break }

            if (ch != '%') {
                fwrite(out_file, u8(ch))
                _length++
                continue
            }

            ch = int(fmt[0])
            fmt += 1

            if (ch == 'c') {
                checked = m3ApiCheckMem(rt, _mem, reinterpret<void?>(args), 4ul)
                if (checked != m3Err_none) { return checked }
                let char_temp = u8(args[0] & 0xffu)
                args += 1
                fwrite(out_file, char_temp)
                _length++
            } elif (ch == 'd' || ch == 'x') {
                checked = m3ApiCheckMem(rt, _mem, reinterpret<void?>(args), 4ul)
                if (checked != m3Err_none) { return checked }
                let int_temp = int(args[0])
                args += 1
                let buffer = internal_itoa(int_temp, ch == 'x' ? 16 : 10)
                fwrite(out_file, buffer)
                _length += length(buffer)
            } elif (ch == 's') {
                checked = m3ApiCheckMem(rt, _mem, reinterpret<void?>(args), 4ul)
                if (checked != m3Err_none) { return checked }

                let string_temp = m3ApiOffsetToPtr(_mem, args[0])
                args += 1
                var string_len = 0
                if (m3ApiIsNullPtr(_mem, string_temp)) {
                    // C substitutes the literal "(null)"; the port writes the
                    // same six bytes and leaves string_temp unread.
                    fwrite(out_file, "(null)")
                    string_len = 6
                    _length += string_len
                } else {
                    string_len = libc_strnlen(string_temp, 1024)
                    checked = m3ApiCheckMem(rt, _mem, string_temp, u64(string_len) + 1ul)
                    if (checked != m3Err_none) { return checked }
                    _builtin_write(out_file, string_temp, string_len)
                    _length += string_len
                }
            } else {
                fwrite(out_file, u8(ch))
                _length++
            }
        }
    }

    m3ApiReturn_i32(raw_return, _length)
    return m3Err_none
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
*/
var private s_clock_ref = 0l


def public m3_libc_clock_ms(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    var sp = unsafe(reinterpret<u64?>(_sp))
    let raw_return = m3ApiReturnType(sp)                    // m3ApiReturnType (uint32_t)

    if (s_clock_ref == 0l) { s_clock_ref = ref_time_ticks() }
    let clock_ms = get_time_nsec(s_clock_ref) / 1000000l

    m3ApiReturn_u32(raw_return, u32(clock_ms))
    return m3Err_none
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
def public m3_spectest_dummy(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    return m3Err_none
}


// ============================================================================
// 11. m3_LinkSpecTest
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


// ============================================================================
// 12. m3_LinkLibC
// ============================================================================


// C parameter `module` renamed to `_module`: `module` is a daslang keyword.
def public m3_LinkLibC(var _module : IM3Module) : M3Result {
    let env = "env"

    // As in m3_LinkSpecTest, C's dead `M3Result result = m3Err_none;`
    // initialiser becomes the declaration of the first link.
    var result : M3Result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "_debug", "i(*i)", @@m3_libc_print))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "_memset", "*(*ii)", @@m3_libc_memset))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "_memmove", "*(**i)", @@m3_libc_memmove))
    if (result != m3Err_none) { return result }
    // just alias of memmove
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "_memcpy", "*(**i)", @@m3_libc_memmove))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "_abort", "v()", @@m3_libc_abort))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "_exit", "v(i)", @@m3_libc_exit))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "clock_ms", "i()", @@m3_libc_clock_ms))
    if (result != m3Err_none) { return result }
    result = SuppressLookupFailure(m3_LinkRawFunction(_module, env, "printf", "i(**)", @@m3_libc_printf))

    return result
}
