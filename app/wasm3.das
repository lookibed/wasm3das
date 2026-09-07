options gen2
options indenting = 4
// C M3_MUSTTAIL is replaced by the RunLoop dispatcher of m3_exec_defs.das
// (notes/exec_trampoline_design.md): ops return to the loop, and only a
// wasm call nests Daslang frames, a bounded number per wasm frame.
// `options stack` counts only in the program root, which for the command
// line tool is this file.
//
// The size is chosen so that the wasm stack limit checked by op_Entry
// (m3_exec.das, C m3_exec.h `_sp + maxStackSlots < _mem->maxStack`) is
// reached before the Daslang context stack: an unbounded wasm recursion must
// end as `[trap] stack overflow`, which is what the spec suite's
// assert_exhaustion cases expect, not as a Daslang "stack overflow"
// exception that kills the process. The default 64 KiB wasm stack needs
// about 6 MiB; 64 MiB leaves room for a much larger `--stack-size`.
options stack = 67_108_864

// Conservative Gen2 port of wasm3c/platforms/app/main.c.
//
// Scope: everything the original spec-test driver (wasm3c/test/run-spec-test.py)
// drives through `--repl` — :init, :version, :exit, :load, :load-hex,
// :invoke, :get-global, :set-global, :compile, :dump — plus the non-REPL
// `wasm3 <file> [args...]` path that wasm3c/test/run-wasi-test.py drives,
// including the `#if defined(LINK_WASI)` branch of repl_call.
//
// Out of scope, and marked at the site: gas metering, the tracer and
// backtrace recording. The gas block of main.c is guarded by
// `#if defined(GAS_LIMIT)`; this port omits it entirely, together with
// print_gas_used, because the module it meters ("metering"."usegas") is a
// wasm-metering artefact no test in this repository uses.
//
// main.c has no stdin/stdout mode switching: the Windows `_setmode(_O_BINARY)`
// dance lives in the WASI layer, not here, so there is nothing to port.

require daslib/fio
require math
require strings
require ../source/m3_parse.das
require ../source/m3_api_libc.das
require ../source/m3_api_wasi.das


// C: #define MAX_MODULES 16
let MAX_MODULES = 16

// C wasm3.h: #define M3_VERSION "0.5.2". The public header is not ported yet,
// so the version string lives here, next to its only consumer.
let M3_VERSION = "0.5.2"


var env : IM3Environment
var runtime : IM3Runtime

/*
    C keeps `static u8* wasm_bins[MAX_MODULES]` of malloc'ed binaries because
    a parsed M3Module keeps pointers into the buffer it was parsed from. The
    port keeps the same ownership with Daslang arrays: the outer array may
    reallocate, but the data pointer of each inner array does not move, so
    `addr(bin[0])` handed to m3_ParseModule stays valid until repl_free.
*/
var wasm_bins : array<array<u8>>
var wasm_bins_qty = 0

/*
    C repl_call ends a WASI `_start` that trapped with m3Err_trapExit by
    calling libc exit(wasi_ctx->exit_code), which leaves the process from
    inside repl_call. Daslang has no exit(), so the request travels to main()
    in these two variables and main() returns the code, skipping the _onfatal
    epilogue exactly as exit() skips it.
*/
var exit_requested = false
var exit_code = 0


// ============================================================================
// Small C library helpers that Daslang does not provide verbatim
// ============================================================================


def private out_write(text : string) {
    fprint(fstdout(), text)
    fflush(fstdout())
}


def private err_write(text : string) {
    fprint(fstderr(), text)
    fflush(fstderr())
}


/*
    A C `const char*` walked by index. Daslang character_at() is O(n), so the
    bytes of a string are copied once and then indexed like the C pointer.
*/
def private str_bytes(text : string) : array<u8> {
    var bytes : array<u8>
    peek_data(text) $(data) {
        bytes := data
    }
    return <- bytes
}


/*
    C fgets(cmd_buff, 2048, stdin). Daslang fgets returns at most 16383
    characters per call, so a line is assembled until the newline arrives.
    Returns "" only at end of file, which is C's `!fgets(...)`.
*/
def private read_line() : string {
    var chunks : array<string>
    while (true) {
        let chunk = fgets(fstdin())
        if (empty(chunk)) { break }
        chunks |> push(chunk)
        if (chunk |> ends_with("\n")) { break }
    }
    let count = length(chunks)
    return build_string() $(var w) {
        for (i in 0 .. count) {
            w |> write(chunks[i])
        }
    }
}


// C strtoul/strtoull with base 10. Wraps like the C unsigned conversion; a
// leading '-' negates, as strtoul does.
def private strtoull_10(text : string) : u64 {
    let s = str_bytes(text)
    let n = length(s)
    var i = 0
    while (i < n) {
        let c = int(s[i])
        if (c != 32 && (c < 9 || c > 13)) { break }
        i++
    }
    var negative = false
    if (i < n) {
        let c = int(s[i])
        if (c == 45) {
            negative = true
            i++
        } elif (c == 43) {
            i++
        }
    }
    var value = 0ul
    while (i < n) {
        let c = int(s[i])
        if (!is_number(c)) { break }
        value = value * 10ul + u64(c - 48)
        i++
    }
    return negative ? 0ul - value : value
}


/*
    C printf "%" PRIu32 / "%" PRIu64. Daslang renders u32 and u64 in
    hexadecimal in string interpolation, so the unsigned decimal form the
    spec-test runner parses is produced explicitly.
*/
def private utoa(i_value : u64) : string {
    if (i_value == 0ul) { return "0" }
    var digits : array<int>
    var value = i_value
    while (value != 0ul) {
        digits |> push(int(value % 10ul))
        value /= 10ul
    }
    let count = length(digits)
    return build_string() $(var w) {
        for (i in 0 .. count) {
            w |> write_char(48 + digits[count - 1 - i])
        }
    }
}


// C isxdigit + strtol(hex, NULL, 16) on a two character buffer.
def private hex_value(c : int) : int {
    if (is_number(c)) { return c - 48 }
    if (c >= 97 && c <= 102) { return c - 87 }
    if (c >= 65 && c <= 70) { return c - 55 }
    return -1
}


// ============================================================================
// main.c
// ============================================================================


/*
    C link_all calls m3_LinkSpecTest, m3_LinkLibC and, when built with WASI,
    m3_LinkWASI, then binds the optional "metering"."usegas" raw function.
    The tracer (`#if defined(d_m3HasTracer)`) and the gas block
    (`#if defined(GAS_LIMIT)`) are not part of this build, so only the three
    linkers remain.
*/
def link_all(var _module : IM3Module) : M3Result {
    if (_module == null) { return m3Err_moduleNotLinked }
    var res = m3_LinkSpecTest(_module)
    if (res != m3Err_none) { return res }

    res = m3_LinkLibC(_module)
    if (res != m3Err_none) { return res }

    res = m3_LinkWASI(_module)
    if (res != m3Err_none) { return res }

    return res
}


def modname_from_fn(fn : string) : string {
    let sep = str_bytes("/\\:*?")
    var name = fn
    for (si in 0 .. length(sep)) {
        let c = sep[si]
        let s = str_bytes(name)
        var off = -1
        for (i in 0 .. length(s)) {
            if (s[i] == c) { off = i }
        }
        if (off >= 0) { name = slice(name, off + 1) }
    }
    return name
}


def repl_load(fn : string) : M3Result {
    var result : M3Result
    var _module : IM3Module

    var wasm : array<u8>
    var fsize : u32

    var f = fopen(fn, "rb")
    if (f == null) {
        return "cannot open file"
    }
    fseek(f, 0l, seek_end)
    fsize = u32(ftell(f))
    fseek(f, 0l, seek_set)

    if (fsize < 8u) {
        fclose(f)
        return "file is too small"
    } elif (fsize > 256u * 1024u * 1024u) {
        fclose(f)
        return "file is too big"
    }

    wasm |> resize(int(fsize))
    if (fread(f, wasm) != int(fsize)) {
        fclose(f)
        return "cannot read file"
    }
    fclose(f)

    unsafe {
        result = m3_ParseModule(env, _module, addr(wasm[0]), fsize)
    }
    if (result != m3Err_none) {
        // C on_error: m3_FreeModule(module) then free(wasm).
        m3_FreeModule(_module)
        return result
    }

    result = m3_LoadModule(runtime, _module)
    if (result != m3Err_none) {
        m3_FreeModule(_module)
        return result
    }

    m3_SetModuleName(_module, modname_from_fn(fn))

    result = link_all(_module)
    if (result != m3Err_none) {
        m3_FreeModule(_module)
        return result
    }

    // C: if (wasm_bins_qty < MAX_MODULES) wasm_bins[wasm_bins_qty++] = wasm.
    // Beyond MAX_MODULES C simply leaks the buffer, which keeps it alive for
    // the module; Daslang has no leak, so the buffer is always retained and
    // only the slot counter follows the C bound.
    if (wasm_bins_qty < MAX_MODULES) { wasm_bins_qty++ }
    wasm_bins |> emplace(wasm)

    return result
}


def repl_load_hex(fsize : u32) : M3Result {
    var result : M3Result

    if (fsize < 8u) {
        return "file is too small"
    } elif (fsize > 10u * 1024u * 1024u) {
        return "file too big"
    }

    var wasm : array<u8>
    wasm |> resize(int(fsize))

    {   // Load hex data from stdin
        var wasm_idx = 0
        var hi = -1
        var sawEol = false
        while (!sawEol) {
            // C reads stdin one character at a time until fsize bytes have
            // been decoded and then consumes the newline with fgets. Daslang
            // has no buffered getc on FILE*, so the line is consumed in
            // fgets-sized chunks; non-hex characters are skipped the same way.
            let chunk = fgets(fstdin())
            if (empty(chunk)) { return "cannot read EOL" }
            let s = str_bytes(chunk)
            let n = length(s)
            for (k in 0 .. n) {
                let d = hex_value(int(s[k]))
                if (d < 0) { continue }
                if (hi < 0) {
                    hi = d
                } else {
                    if (wasm_idx < int(fsize)) {
                        wasm[wasm_idx] = u8(hi * 16 + d)
                        wasm_idx++
                    }
                    hi = -1
                }
            }
            if (s[n - 1] == u8(10)) { sawEol = true }
        }
        if (wasm_idx != int(fsize)) { return "cannot read file" }
    }

    // C leaks this buffer on purpose: the module parses pointers into it and
    // repl_load_hex never registers it in wasm_bins. The port retains it in
    // wasm_bins instead, so it lives exactly as long as the runtime that
    // owns the module and is released by repl_free.
    wasm_bins |> emplace(wasm)
    let bin_idx = length(wasm_bins) - 1

    var _module : IM3Module
    unsafe {
        result = m3_ParseModule(env, _module, addr(wasm_bins[bin_idx][0]), fsize)
    }
    if (result != m3Err_none) { return result }

    result = m3_LoadModule(runtime, _module)
    if (result != m3Err_none) { return result }

    result = link_all(_module)

    return result
}


/*
    C print_backtrace walks m3_GetBacktrace. d_m3RecordBacktraces is off in
    this port's configuration, so m3_GetBacktrace returns null and C prints
    nothing; the function is kept for structural fidelity.
*/
def print_backtrace() {
    let info = m3_GetBacktrace(runtime)
    if (info == null) { return }
    err_write("==== wasm backtrace:\n")
}


def repl_call(name : string; argc : int; argv : array<string>) : M3Result {
    var func : IM3Function
    var result = m3_FindFunction(func, runtime, name)
    if (result != m3Err_none) { return result }

    if (argc != 0 && (name == "main" || name == "_main")) {
        return "passing arguments to libc main() not implemented"
    }

    if (name == "_start") {
        // C: #if defined(LINK_WASI)
        // C rewrites argv[0] in the caller's vector; the parameter is const
        // here, so the vector is copied first. main.c never reads it again.
        var wasi_argv <- argv_tail(argv, 0)

        // Strip wasm file path
        if (argc > 0) {
            wasi_argv[0] = modname_from_fn(wasi_argv[0])
        }

        var wasi_ctx = m3_GetWasiContext()
        wasi_ctx.argc = u32(argc)
        wasi_ctx.argv := wasi_argv

        // C: m3_CallArgv(func, 0, NULL) - _start takes no wasm arguments;
        // argv reaches the module through the WASI context.
        let no_argv : array<string>
        result = m3_CallArgv(func, 0u, no_argv)

        // print_gas_used() is compiled out with the gas block.

        if (result == m3Err_trapExit) {
            // C: exit (wasi_ctx->exit_code). Daslang has no libc exit(), so
            // the request is recorded and main() returns the code without
            // running the _onfatal epilogue, which is what exit() does.
            exit_requested = true
            exit_code = wasi_ctx.exit_code
        }

        return result
    }

    let arg_count = int(m3_GetArgCount(func))
    let ret_count = int(m3_GetRetCount(func))
    if (argc < arg_count) {
        return "not enough arguments"
    } elif (argc > arg_count) {
        return "too many arguments"
    }

    result = m3_CallArgv(func, u32(argc), argv)
    if (result != m3Err_none) { return result }

    var valbuff : array<u64>
    valbuff |> resize(128)
    var valptrs : array<void?>
    valptrs |> reserve(ret_count)
    unsafe {
        for (i in 0 .. ret_count) {
            valptrs |> push(addr<void?>(valbuff[i]))
        }
    }
    result = m3_GetResults(func, u32(ret_count), valptrs)
    if (result != m3Err_none) { return result }

    if (ret_count <= 0) {
        err_write("Result: <Empty Stack>\n")
    }
    unsafe {
        for (i in 0 .. ret_count) {
            let p = addr(valbuff[i])
            let _type = m3_GetRetType(func, u32(i))
            if (_type == M3ValueType.c_m3Type_i32) {
                err_write("Result: {*reinterpret<i32 const?>(p)}\n")
            } elif (_type == M3ValueType.c_m3Type_i64) {
                err_write("Result: {*reinterpret<i64 const?>(p)}\n")
            } elif (_type == M3ValueType.c_m3Type_f32) {
                // C uses PRIf32 ("%f"); Daslang prints the shortest round-trip form.
                err_write("Result: {*reinterpret<f32 const?>(p)}\n")
            } elif (_type == M3ValueType.c_m3Type_f64) {
                err_write("Result: {*reinterpret<f64 const?>(p)}\n")
            } else {
                return "unknown return type"
            }
        }
    }

    return result
}


// :invoke is used by spec tests, so it treats floats as raw data
def repl_invoke(name : string; argc : int; argv : array<string>) : M3Result {
    var func : IM3Function
    var result = m3_FindFunction(func, runtime, name)
    if (result != m3Err_none) { return result }

    let arg_count = int(m3_GetArgCount(func))
    let ret_count = int(m3_GetRetCount(func))

    if (argc > 128) {
        return "arguments limit reached"
    } elif (argc < arg_count) {
        return "not enough arguments"
    } elif (argc > arg_count) {
        return "too many arguments"
    }

    // C: static uint64_t valbuff[128]; static const void* valptrs[128];
    // both memset to zero before use.
    var valbuff : array<u64>
    valbuff |> resize(128)

    var argptrs : array<void?>          // C: const void *; see m3_Call's deviation note
    argptrs |> reserve(argc)
    unsafe {
        for (i in 0 .. argc) {
            argptrs |> push(addr<void?>(valbuff[i]))
            let _type = m3_GetArgType(func, u32(i))
            if (_type == M3ValueType.c_m3Type_i32 || _type == M3ValueType.c_m3Type_f32) {
                // C: *(u32*)(s) = strtoul(argv[i], NULL, 10)
                *addr<u32?>(valbuff[i]) = u32(strtoull_10(argv[i]))
            } elif (_type == M3ValueType.c_m3Type_i64 || _type == M3ValueType.c_m3Type_f64) {
                // C: *(u64*)(s) = strtoull(argv[i], NULL, 10)
                valbuff[i] = strtoull_10(argv[i])
            } else {
                return "unknown argument type"
            }
        }
    }

    result = m3_Call(func, u32(argc), argptrs)
    if (result != m3Err_none) { return result }

    // reuse valbuff for return values
    for (i in 0 .. length(valbuff)) { valbuff[i] = 0ul }
    var retptrs : array<void?>
    retptrs |> reserve(ret_count)
    unsafe {
        for (i in 0 .. ret_count) {
            retptrs |> push(addr<void?>(valbuff[i]))
        }
    }
    result = m3_GetResults(func, u32(ret_count), retptrs)
    if (result != m3Err_none) { return result }

    // C prints the values with a sequence of fprintf(stderr, ...) calls; the
    // port formats them first so that "unknown return type" can still leave
    // the function without having written a partial line.
    var values : array<string>
    values |> reserve(ret_count)
    for (i in 0 .. ret_count) {
        let _type = m3_GetRetType(func, u32(i))
        if (_type == M3ValueType.c_m3Type_i32) {
            values |> push("{utoa(valbuff[i] & 0xFFFFFFFFul)}:i32")
        } elif (_type == M3ValueType.c_m3Type_f32) {
            values |> push("{utoa(valbuff[i] & 0xFFFFFFFFul)}:f32")
        } elif (_type == M3ValueType.c_m3Type_i64) {
            values |> push("{utoa(valbuff[i])}:i64")
        } elif (_type == M3ValueType.c_m3Type_f64) {
            values |> push("{utoa(valbuff[i])}:f64")
        } else {
            return "unknown return type"
        }
    }
    let count = length(values)
    err_write(build_string() $(var w) {
        w |> write("Result: ")
        if (ret_count <= 0) {
            w |> write("<Empty Stack>")
        }
        for (i in 0 .. count) {
            if (i != 0) { w |> write(", ") }
            w |> write(values[i])
        }
        w |> write("\n")
    })

    return result
}


def repl_global_get(name : string) : M3Result {
    var g = m3_FindGlobal(runtime.modules, name)

    var tagged : M3TaggedValue
    let err = m3_GetGlobal(g, tagged)
    if (err != m3Err_none) { return err }

    if (tagged._type == M3ValueType.c_m3Type_i32) {
        err_write("{utoa(u64(u32(tagged_get_i32(tagged))))}:i32\n")
    } elif (tagged._type == M3ValueType.c_m3Type_i64) {
        err_write("{utoa(u64(tagged_get_i64(tagged)))}:i64\n")
    } elif (tagged._type == M3ValueType.c_m3Type_f32) {
        // C uses PRIf32/PRIf64 ("%f"); Daslang prints the shortest
        // round-trip form, so "42" here where C prints "42.000000".
        err_write("{tagged_get_f32(tagged)}:f32\n")
    } elif (tagged._type == M3ValueType.c_m3Type_f64) {
        err_write("{tagged_get_f64(tagged)}:f64\n")
    } else {
        return m3Err_invalidTypeId
    }
    return m3Err_none
}


def repl_global_set(name : string; value : string) : M3Result {
    var g = m3_FindGlobal(runtime.modules, name)

    var tagged : M3TaggedValue
    tagged._type = m3_GetGlobalType(g)

    if (tagged._type == M3ValueType.c_m3Type_i32) {
        tagged_set_i32(tagged, i32(u32(strtoull_10(value))))
    } elif (tagged._type == M3ValueType.c_m3Type_i64) {
        tagged_set_i64(tagged, i64(strtoull_10(value)))
    } elif (tagged._type == M3ValueType.c_m3Type_f32) {
        tagged_set_f32(tagged, float(to_double(value)))
    } elif (tagged._type == M3ValueType.c_m3Type_f64) {
        tagged_set_f64(tagged, to_double(value))
    } else {
        return m3Err_invalidTypeId
    }

    return m3_SetGlobal(g, tagged)
}


def repl_compile() : M3Result {
    return m3_CompileModule(runtime.modules)
}


def repl_dump() : M3Result {
    var len = 0u
    let mem = m3_GetMemory(runtime, len, 0u)
    if (mem != null) {
        var f = fopen("wasm3_dump.bin", "wb")
        if (f == null) {
            return "cannot open file"
        }
        var bytes : array<u8>
        bytes |> resize(int(len))
        unsafe {
            for (i in 0 .. int(len)) { bytes[i] = mem[i] }
        }
        if (fwrite(f, bytes) != int(len)) {
            fclose(f)
            return "cannot write file"
        }
        fclose(f)
    }
    return m3Err_none
}


def repl_free() {
    if (runtime != null) {
        m3_FreeRuntime(runtime)
        runtime = null
    }

    // C: for (i = 0; i < wasm_bins_qty; i++) free(wasm_bins[i]).
    wasm_bins |> clear()
    wasm_bins_qty = 0
}


def repl_init(stack : u32) : M3Result {
    repl_free()
    runtime = m3_NewRuntime(env, stack, null)
    if (runtime == null) {
        return "m3_NewRuntime failed"
    }
    return m3Err_none
}


/*
    C main.c names this static helper `unescape`. It is spelled
    unescape_argv here because the Daslang `strings` module exports its own
    builtin `unescape`, and the two overloads are indistinguishable at every
    call site. The body is the C switch, character for character.
*/
def private unescape_argv(buff : string) : string {
    let s = str_bytes(buff)
    let n = length(s)
    return build_string() $(var w) {
        var i = 0
        while (i < n) {
            let c = int(s[i])
            if (c == 92 && i + 1 < n) {       // '\\'
                let e = int(s[i + 1])
                if (e == 48) {                // '0'
                    w |> write_char(0)
                } elif (e == 98) {            // 'b'
                    w |> write_char(8)
                } elif (e == 110) {           // 'n'
                    w |> write_char(10)
                } elif (e == 114) {           // 'r'
                    w |> write_char(13)
                } elif (e == 116) {           // 't'
                    w |> write_char(9)
                } elif (e == 120 && i + 3 < n) {   // 'x'
                    let hi = hex_value(int(s[i + 2]))
                    let lo = hex_value(int(s[i + 3]))
                    w |> write_char(max(hi, 0) * 16 + max(lo, 0))
                    i += 2
                } else {
                    // Otherwise just pass the letter. Also handles '\\'
                    w |> write_char(e)
                }
                i += 2
            } else {
                w |> write_char(c)
                i++
            }
        }
    }
}


def private split_argv(str : string) : array<string> {
    var result : array<string>
    let s = str_bytes(str)
    var curr = 0
    var len = 0
    let n = length(s)
    for (i in 0 .. n) {
        let c = int(s[i])
        if (c == 32 || c == 10 || c == 13 || c == 9) {
            if (len != 0) {   // Found space after non-space
                result |> push(slice(str, curr, i))
                len = 0
            }
        } else {
            if (len == 0) {   // Found non-space after space
                curr = i
            }
            len++
        }
    }
    if (len != 0) { result |> push(slice(str, curr, n)) }
    return <- result
}


/*
    The option words the port still accepts *after* the file operand. C stops
    scanning at the first word that does not start with '-' and never looks at
    options again, so it has no need for this list; the port needs it for the
    rescan documented in main_run. Only the long spellings are listed: the
    `-h` and `-f` aliases stay pre-file options, because a wasm program's own
    `-f` argument (Brotli's `-c -f`) must not be swallowed.
*/
let POST_FILE_OPTIONS = [
    "--help", "--wasm3-help", "--version", "--repl", "--dump-on-trap",
    "--compile", "--stack-size", "--gas-limit", "--dir", "--func"
]


def private is_post_file_option(arg : string) : bool {
    for (opt in POST_FILE_OPTIONS) {
        if (arg == opt) { return true }
    }
    return false
}


// C passes `argv + start`; Daslang has no pointer into an array<string>, so
// the tail is copied.
def private argv_tail(argv : array<string>; start : int) : array<string> {
    var result <- [for (i in start .. length(argv)); argv[i]]
    return <- result
}


def print_version() {
    let wasm3_env = get_env_variable("WASM3")
    let wasm3_arch = get_env_variable("WASM3_ARCH")

    let self_hosting = (!empty(wasm3_arch) || !empty(wasm3_env)) ? " self-hosting" : ""
    let arch = !empty(wasm3_arch) ? wasm3_arch : M3_ARCH
    out_write("Wasm3 v{M3_VERSION}{self_hosting} on {arch}\n")

    // C: printf("Build: " __DATE__ " " __TIME__ ", " M3_COMPILER_VER "\n").
    // The port has no __DATE__/__TIME__; the compiler identification is the
    // pinned Daslang toolchain.
    out_write("Build: Daslang port, {M3_COMPILER_VER}\n")
}


def print_usage() {
    out_write("Usage:\n")
    out_write("  wasm3 [options] <file> [args...]\n")
    out_write("  wasm3 --repl [file]\n")
    out_write("Options:\n")
    out_write("  --func <function>     function to run       default: _start\n")
    out_write("  --stack-size <size>   stack size in bytes   default: 64KB\n")
    out_write("  --compile             disable lazy compilation\n")
    out_write("  --dump-on-trap        dump wasm memory\n")
    out_write("  --gas-limit           set gas limit\n")
}


/*
    The process arguments as C main() sees them: argv[0] is the program name,
    the rest is everything the wrapper passed after `--`. daslang's own
    argv[0..1] (interpreter and script) are dropped.
*/
def private process_argv() : array<string> {
    var raw <- get_command_line_arguments()
    var result : array<string>
    result |> push("wasm3")
    var seen = false
    for (a in raw) {
        if (seen) {
            result |> push(a)
        } elif (a == "--") {
            seen = true
        }
    }
    return <- result
}


/*
    C main() up to the `_onfatal` label.

    Return value: -1 is the C `goto _onfatal`, and the epilogue lives in
    main(). Any other value is one of C main()'s early `return N` statements
    (--help, --version, print_usage, :exit, end of stdin), which leave main
    without running the _onfatal epilogue or freeing the runtime.
*/
def private main_run(var result : M3Result&) : int {
    var argRepl = false
    var argDumpOnTrap = false
    var argCompile = false
    var argFile = ""
    var haveFile = false
    var argFunc = "_start"
    var argStackSize = 64u * 1024u

    let i_argv <- process_argv()
    var i_pos = 0
    var i_argc = length(i_argv)

    // ARGV_SHIFT(): skip executable name
    i_argc--
    i_pos++

    // C: ARGV_SHIFT()/ARGV_SET(x) expanded inline.
    var scanning = true
    while (scanning) {
        while (i_argc > 0) {
            let arg = i_argv[i_pos]
            // C: `if (arg[0] != '-') break`. The second half is part of the
            // rescan deviation below: once the file operand has been taken,
            // every remaining word belongs to the wasm program, so only the
            // option words main.c knows are still consumed and
            // `wasm3 c-ray.wasm -s 32x32` reaches the module intact.
            if (first_character(arg) != 45 || (haveFile && !is_post_file_option(arg))) { break }

            i_argc--
            i_pos++
            // --wasm3-help is the alias scripts/wasm3 substitutes for --help
            // and -h, which the daslang CLI consumes before the script runs.
            if (arg == "--help" || arg == "-h" || arg == "--wasm3-help") {
                print_usage()
                return 0
            } elif (arg == "--version") {
                print_version()
                return 0
            } elif (arg == "--repl") {
                argRepl = true
            } elif (arg == "--dump-on-trap") {
                argDumpOnTrap = true
            } elif (arg == "--compile") {
                argCompile = true
            } elif (arg == "--stack-size") {
                var tmp = "65536"
                if (i_argc > 0) {
                    tmp = i_argv[i_pos]
                    i_argc--
                    i_pos++
                }
                argStackSize = u32(strtoull_10(tmp))
            } elif (arg == "--gas-limit") {
                // Gas metering is not ported; the value is consumed and ignored.
                if (i_argc > 0) {
                    i_argc--
                    i_pos++
                }
            } elif (arg == "--dir") {
                if (i_argc > 0) {
                    i_argc--
                    i_pos++
                }
            } elif (arg == "--func" || arg == "-f") {
                if (i_argc > 0) {
                    argFunc = i_argv[i_pos]
                    i_argc--
                    i_pos++
                }
            }
        }

        if (haveFile || i_argc <= 0) { break }

        if ((argRepl && i_argc > 1) || (!argRepl && i_argc < 1)) {
            print_usage()
            return 1
        }

        // ARGV_SET(argFile)
        argFile = i_argv[i_pos]
        haveFile = true
        i_argc--
        i_pos++

        /*
            Deviation from C, marked: main.c stops option scanning at the
            first non-option word, so `wasm3 file.wasm --func fib 25` would
            pass "--func" as a function argument. The port rescans after the
            file operand so both C's `wasm3 --func fib file.wasm 25` and the
            file-first spelling used by this repository's smoke tests work.
            The rescan is limited to the option words main.c knows, so a wasm
            program's own `-s`, `-c`, `-f`-style arguments still reach it.
        */
        scanning = i_argc > 0 && is_post_file_option(i_argv[i_pos])
    }

    if (!haveFile) {
        if ((argRepl && i_argc > 1) || (!argRepl && i_argc < 1)) {
            print_usage()
            return 1
        }
    }

    result = repl_init(argStackSize)
    if (result != m3Err_none) {
        err_write("Error: [Fatal] repl_init: {result}\n")
        return -1
    }

    if (haveFile) {
        result = repl_load(argFile)
        if (result != m3Err_none) {
            err_write("Error: [Fatal] repl_load: {result}\n")
            return -1
        }

        if (argCompile) {
            repl_compile()
        }

        if (!argRepl) {
            if (argFunc == "_start") {
                // C: repl_call(argFunc, i_argc+1, i_argv-1), i.e. the wasm
                // file name becomes argv[0] for WASI.
                result = repl_call(argFunc, i_argc + 1, argv_tail(i_argv, i_pos - 1))
            } else {
                result = repl_call(argFunc, i_argc, argv_tail(i_argv, i_pos))
            }

            // C: repl_call already left the process through exit() when a
            // WASI _start ended with m3Err_trapExit; nothing below runs.
            if (exit_requested) { return -1 }

            if (result != m3Err_none) {
                if (argDumpOnTrap) {
                    repl_dump()
                }
                print_backtrace()
                return -1
            }
        }
    }

    while (argRepl) {
        out_write("wasm3> ")
        let cmd_buff = read_line()
        if (empty(cmd_buff)) {
            return 0
        }
        let argv <- split_argv(cmd_buff)
        let argc = length(argv)
        if (argc <= 0) {
            continue
        }
        result = m3Err_none
        if (argv[0] == ":init") {
            result = repl_init(argStackSize)
        } elif (argv[0] == ":version") {
            print_version()
        } elif (argv[0] == ":exit") {
            repl_free()
            return 0
        } elif (argv[0] == ":load") {               // :load <filename>
            result = argc > 1 ? repl_load(argv[1]) : "not enough arguments"
        } elif (argv[0] == ":load-hex") {           // :load-hex <size>\n <hex-encoded-binary>
            result = argc > 1 ? repl_load_hex(u32(strtoull_10(argv[1]))) : "not enough arguments"
        } elif (argv[0] == ":get-global") {
            result = argc > 1 ? repl_global_get(argv[1]) : "not enough arguments"
        } elif (argv[0] == ":set-global") {
            result = argc > 2 ? repl_global_set(argv[1], argv[2]) : "not enough arguments"
        } elif (argv[0] == ":dump") {
            result = repl_dump()
        } elif (argv[0] == ":compile") {
            result = repl_compile()
        } elif (argv[0] == ":invoke") {
            result = argc > 1 ? repl_invoke(unescape_argv(argv[1]), argc - 2, argv_tail(argv, 2)) : "not enough arguments"
        } elif (first_character(argv[0]) == 58) {   // ':'
            result = "no such command"
        } else {
            result = repl_call(unescape_argv(argv[0]), argc - 1, argv_tail(argv, 1))
            if (exit_requested) { return -1 }
            if (result != m3Err_none) {
                print_backtrace()
            }
        }

        if (result == m3Err_trapExit) {
            // C: TODO fprintf(stderr, M3_ARCH "-wasi: exit(%d)\n", runtime->exit_code)
        } elif (result != m3Err_none) {
            var info : M3ErrorInfo
            m3_GetErrorInfo(runtime, info)
            err_write("Error: {result} ({info.message})\n")
        }
    }

    // The C `while (argRepl)` loop is left only by one of the returns above;
    // with argRepl false control falls through to _onfatal.
    return -1
}


[export]
def main : int {
    var result = m3Err_none
    env = m3_NewEnvironment()
    runtime = null

    // m3_PrintM3Info() is commented out in C as well.

    let early = main_run(result)

    // C: repl_call ends a WASI _start that trapped with m3Err_trapExit by
    // calling exit (wasi_ctx->exit_code), so neither the _onfatal epilogue
    // nor m3_FreeRuntime/m3_FreeEnvironment runs.
    if (exit_requested) {
        fflush(fstdout())
        fflush(fstderr())
        return exit_code
    }

    if (early >= 0) {
        fflush(fstdout())
        fflush(fstderr())
        return early
    }

    // C: _onfatal:
    if (result != m3Err_none) {
        var text = "Error: {result}"
        if (runtime != null) {
            var info : M3ErrorInfo
            m3_GetErrorInfo(runtime, info)
            if (!empty(info.message)) {
                text += " ({info.message})"
            }
        }
        err_write("{text}\n")
    }

    // C: m3_FreeRuntime(runtime); m3_FreeEnvironment(env). repl_free also
    // releases the retained wasm binaries, which C leaks at exit.
    repl_free()
    m3_FreeEnvironment(env)
    env = null

    fflush(fstdout())
    fflush(fstderr())
    return result != m3Err_none ? 1 : 0
}
