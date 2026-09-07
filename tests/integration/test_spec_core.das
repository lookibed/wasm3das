options gen2
options indenting = 4
// The executor nests one Daslang frame per executed op (no M3_MUSTTAIL), and
// the spec suite calls deeply recursive functions (fac, call, switch).
// options stack counts only in the program root, which under dastest is this file.
options stack = 8_388_608

// No `module` declaration, like tests/integration/test_m3_exec.das: a named test module
// does not get the [init] of required shared modules under dastest.

require dastest/testing_boost
require daslib/fio
require daslib/json
require daslib/json_boost
require strings
require ../../source/m3_parse.das
require ../../source/m3_api_libc.das


/*
    WebAssembly core specification suite driven from Daslang.

    This is the Daslang equivalent of wasm3c/test/run-spec-test.py: it reads a
    `<name>.json` produced by `wast2json`, replays its commands against the
    ported runtime and judges the results exactly as the Python runner does.

    Correspondence with run-spec-test.py:
    - `module`      -> repl `:init` + `:load`: a fresh runtime on the shared
                       environment, then m3_ParseModule / m3_LoadModule.
    - `assert_return`, `action`, `assert_trap` -> repl `:invoke`, i.e.
                       m3_FindFunction / m3_Call / m3_GetResults.
    - `assert_invalid`, `assert_malformed`, `assert_unlinkable`,
      `assert_uninstantiable` -> ignored (the Python runner ignores them too;
                       wasm3 has no validator).
    - every other command type is counted as skipped.

    Judging differs from the Python runner in one deliberate way: the Python
    default `--format fp` prints floats with six/ten decimals and compares the
    text, which its own banner calls a loose comparison. Here results are
    compared as raw bit patterns, with the one leniency the Python runner
    encodes in normalizeResults(): every NaN, whether spelled
    "nan:canonical", "nan:arithmetic" or a concrete payload, matches any NaN.

    The suite itself is not vendored (it is 3300 files); the tests skip when
    SPEC_DIR is absent, which is the case in CI. To run them locally, unpack
    https://github.com/wasm3/wasm-core-testsuite/archive/opam-1.1.1.zip into
    tmp/spec/ so that SPEC_DIR below exists.
*/


let SPEC_DIR = "tmp/spec/wasm-core-testsuite-opam-1.1.1/core"


// Files that must be 100% green. Adding a file here makes a regression fail.
let SPEC_GREEN = fixed_array(
    "i32",
    "i64",
    "int_literals",
    "int_exprs",
    "local_get",
    "local_set",
    "local_tee",
    "nop",
    "block",
    "loop",
    "br",
    "br_if",
    "br_table",
    "if",
    "select",
    "return",
    "unreachable",
    "call",
    "call_indirect",
    "func",
    "labels",
    "switch",
    "stack",
    "forward",
    "fac",
    "left-to-right",
    "unwind",
    "traps",
    "endianness",
    "address",
    "align",
    "memory",
    "memory_redundancy",
    "memory_size",
    "memory_trap",
    "load",
    "store",
    "float_memory",
    "conversions",
    "f32_bitwise",
    "f64_bitwise",
    "f32_cmp",
    "f64_cmp",
    "f32",
    "f64",
    "float_literals",
    "float_misc",
    "float_exprs",
    "const",
    "global",
    "memory_grow",
    "start",
    "exports",
    "elem",
    "names",
    "func_ptrs")


// Files that are run for information only. None of them contains an invoke
// this runner can judge: they are validation/encoding files whose commands are
// all assert_malformed/assert_invalid, or they need the module registry
// (`register`), host globals/memories/tables, or the native stack guard
// (assert_exhaustion) that this port does not have yet. They are printed so a
// later change that starts running their assertions is visible.
let SPEC_INFO = fixed_array(
    "custom",
    "comments",
    "inline-module",
    "token",
    "type",
    "unreached-invalid",
    "utf8-custom-section-id",
    "utf8-import-field",
    "utf8-import-module",
    "utf8-invalid-encoding",
    "binary",
    "binary-leb128",
    "skip-stack-guard-page",
    "data",
    "table",
    "imports",
    "linking")


struct SpecStats {
    total_run : int
    success : int
    failed : int
    skipped : int
    modules : int
    moduleFailed : int
}


def private add(var a : SpecStats&; b : SpecStats) {
    a.total_run += b.total_run
    a.success += b.success
    a.failed += b.failed
    a.skipped += b.skipped
    a.modules += b.modules
    a.moduleFailed += b.moduleFailed
}


// Runtime state carried across the commands of one json file. `wasmBins` owns
// every loaded binary: M3Module keeps pointers into it (wasmStart, every
// M3Function.wasm), exactly like the C repl's wasm_bins array.
struct SpecSession {
    env : IM3Environment
    runtime : IM3Runtime
    wasmBins : array<array<u8>>
    moduleOk : bool
}


let private TRAP_PREFIX = "[trap] "


def private spec_dir_present() : bool {
    var st : FStat
    if (!stat(SPEC_DIR, st)) {
        return false
    }
    return st.is_dir
}


def private read_bytes(path : string) : array<u8> {
    var bytes : array<u8>
    fopen(path, "rb") $(f) {
        if (f != null) {
            var st : FStat
            if (fstat(f, st)) {
                bytes |> resize(int64(st.size))
                fread(f, bytes)
            }
        }
    }
    return <- bytes
}


// Spec values are unsigned decimal bit patterns ("4294967295", f32 as u32
// bits, f64 as u64 bits), so one u64 holds any of them.
def private parse_bits(text : string) : u64 {
    return to_uint64(text)
}


def private is_nan_bits(valueType : string; bits : u64) : bool {
    if (valueType == "f32") {
        return (bits & 0x7f800000ul) == 0x7f800000ul && (bits & 0x7ffffful) != 0ul
    } elif (valueType == "f64") {
        return (bits & 0x7ff0000000000000ul) == 0x7ff0000000000000ul && (bits & 0xffffffffffffful) != 0ul
    }
    return false
}


def private type_mask(valueType : string) : u64 {
    return (valueType == "i64" || valueType == "f64") ? 0xfffffffffffffffful : 0xfffffffful
}


// run-spec-test.py normalizeResults(): NaN of any spelling matches any NaN;
// everything else is compared value by value.
def private value_matches(valueType : string; expected : string; actual : u64) : bool {
    let mask = type_mask(valueType)
    let a = actual & mask
    if (valueType == "f32" || valueType == "f64") {
        if (expected == "nan:canonical" || expected == "nan:arithmetic") {
            return is_nan_bits(valueType, a)
        }
        let e = parse_bits(expected) & mask
        if (is_nan_bits(valueType, e)) {
            return is_nan_bits(valueType, a)
        }
        return a == e
    }
    return a == (parse_bits(expected) & mask)
}


def private jarray_size(v : JsonValue?) : int {
    if (v == null) {
        return 0
    }
    if (v.value is _array) {
        return length(v.value as _array)
    }
    return 0
}


// C repl_init: free the runtime, keep the environment, create a new runtime.
def private session_init(var s : SpecSession) {
    if (s.runtime != null) {
        m3_FreeRuntime(s.runtime)
    }
    s.runtime = m3_NewRuntime(s.env, 64u * 1024u, null)
    s.moduleOk = false
}


def private session_load(var s : SpecSession; path : string; modname : string; var st : SpecStats&) {
    session_init(s)
    st.modules++

    var bytes <- read_bytes(path)
    if (empty(bytes)) {
        st.moduleFailed++
        return
    }
    s.wasmBins |> emplace(bytes)
    let index = length(s.wasmBins) - 1

    var _module : IM3Module
    var result : M3Result
    unsafe {
        result = m3_ParseModule(s.env, _module, addr(s.wasmBins[index][0]),
                                u32(length(s.wasmBins[index])))
    }
    if (result != m3Err_none) {
        st.moduleFailed++
        return
    }
    result = m3_LoadModule(s.runtime, _module)
    if (result != m3Err_none) {
        // C repl_load: a module that failed to load stays owned by the caller.
        m3_FreeModule(_module)
        st.moduleFailed++
        return
    }

    // C repl_load continues with m3_SetModuleName + link_all. Of link_all only
    // m3_LinkSpecTest is available: m3_LinkLibC needs the unported m3Api memory
    // macros, and WASI/tracer/gas are compiled out. Deviation from C: a link
    // failure does not m3_FreeModule here, because m3_LoadModule already handed
    // the module to the runtime and m3_FreeRuntime releases it (the C on_error
    // path double-frees it).
    m3_SetModuleName(_module, modname)
    result = m3_LinkSpecTest(_module)
    if (result != m3Err_none) {
        st.moduleFailed++
        return
    }
    s.moduleOk = true
}


// repl `:invoke`: find, call, collect the raw result bits. Returns the M3Result;
// o_rets holds one raw bit pattern per return value on success.
def private spec_invoke(var s : SpecSession; field : string; action : JsonValue?;
                        var o_rets : array<u64>&) : M3Result {
    var _function : IM3Function
    var result = m3_FindFunction(_function, s.runtime, field)
    if (result != m3Err_none) {
        return result
    }

    var argBits : array<u64>
    let jargs = action?["args"]
    if (jargs.value is _array) {
        argBits |> reserve(jarray_size(jargs))
        for (a in jargs.value as _array) {
            argBits |> push(parse_bits(a?["value"] ?? ""))
        }
    }
    // argBits is complete before any address is taken: a later push would move it.
    var argPtrs : array<void?>
    argPtrs |> reserve(length(argBits))
    for (a in argBits) {
        argPtrs |> push(unsafe(addr<void?>(a)))
    }

    result = m3_Call(_function, u32(length(argBits)), argPtrs)
    if (result != m3Err_none) {
        return result
    }

    let retc = m3_GetRetCount(_function)
    o_rets |> resize(int(retc))
    for (r in o_rets) {
        r = 0ul
    }
    var retPtrs : array<void?>
    retPtrs |> reserve(int(retc))
    for (r in o_rets) {
        retPtrs |> push(unsafe(addr<void?>(r)))
    }
    return m3_GetResults(_function, retc, retPtrs)
}


// run-spec-test.py combineResults(): "<value>:<type>, <value>:<type>".
def private describe_expected(expected : JsonValue?) : string {
    var count = 0
    let text = build_string() $(var writer) {
        if (expected.value is _array) {
            for (e in expected.value as _array) {
                if (count > 0) {
                    writer |> write(", ")
                }
                writer |> write("{e?["value"] ?? "?"}:{e?["type"] ?? "?"}")
                count++
            }
        }
    }
    return count == 0 ? "<Empty Stack>" : text
}


def private describe_actual(expected : JsonValue?; rets : array<u64>) : string {
    var count = 0
    let text = build_string() $(var writer) {
        if (expected.value is _array) {
            for (e in expected.value as _array) {
                if (count > 0) {
                    writer |> write(", ")
                }
                let valueType = e?["type"] ?? "?"
                let bits = count < length(rets) ? (rets[count] & type_mask(valueType)) : 0ul
                writer |> write("{bits:d}:{valueType}")
                count++
            }
        }
    }
    return count == 0 ? "<Empty Stack>" : text
}


// run-spec-test.py `blacklist`, entry by entry:
//   "float_exprs.wast:* f32.nonarithmetic_nan_bitpattern*" — an f32 signalling
//       NaN is quieted because wasm3 keeps f32 register values in a f64 (_fp0).
//   "imports.wast:*" — the whole file.
//   "names.wast:* *.wasm \x00*" — exported names that start with a NUL. Such a
//       name reaches Daslang as the empty string, since Daslang strings are
//       NUL-terminated, so the empty field is the same case.
def private is_blacklisted(source : string; field : string) : bool {
    return (source == "imports" ||
            (source == "float_exprs" && starts_with(field, "f32.nonarithmetic_nan_bitpattern")) ||
            (source == "names" && field == ""))
}


// run-spec-test.py trapmap: the spec spells the unreachable trap "unreachable".
def private expected_trap_result(text : string) : M3Result {
    let mapped = text == "unreachable" ? "unreachable executed" : text
    return "{TRAP_PREFIX}{mapped}"
}


def private run_command(var s : SpecSession; cmd : JsonValue?; var st : SpecStats&;
                        source : string; var reported : int&) {
    let cmdType = cmd?["type"] ?? ""
    let action = cmd?["action"]
    let line = cmd?["line"] ?? 0

    if (cmdType == "assert_invalid" || cmdType == "assert_malformed" ||
        cmdType == "assert_unlinkable" || cmdType == "assert_uninstantiable") {
        return
    }
    if (cmdType != "assert_return" && cmdType != "assert_trap" && cmdType != "action") {
        // assert_exhaustion needs the native stack guard; register/other types
        // are not implemented, exactly as in run-spec-test.py.
        st.skipped++
        return
    }
    let field = action?["field"] ?? ""
    // run-spec-test.py skips a non-invoke action, an invoke in a registered
    // module ("invoking in modules not implemented") and blacklisted tests; a
    // module that failed to load leaves nothing to invoke.
    if ((action?["type"] ?? "") != "invoke" ||
        (action?["module"] ?? "") != "" ||
        is_blacklisted(source, field) ||
        !s.moduleOk) {
        st.skipped++
        return
    }

    st.total_run++

    var rets : array<u64>
    let result = spec_invoke(s, field, action, rets)
    let resultText : string = result

    var ok = false
    var expectText = ""
    var actualText = ""
    if (cmdType == "assert_trap") {
        let want = expected_trap_result(cmd?["text"] ?? "")
        let wantText : string = want
        expectText = "trap {wantText}"
        actualText = result == m3Err_none ? "result" : "error {resultText}"
        ok = result == want
    } elif (cmdType == "action") {
        expectText = "<Anything>"
        actualText = result == m3Err_none ? "result" : "error {resultText}"
        ok = result == m3Err_none
    } else {
        let expected = cmd?["expected"]
        expectText = "result {describe_expected(expected)}"
        if (result != m3Err_none) {
            actualText = "error {resultText}"
        } else {
            actualText = "result {describe_actual(expected, rets)}"
            ok = jarray_size(expected) == length(rets)
            if (ok) {
                var i = 0
                for (e in expected.value as _array) {
                    if (!value_matches(e?["type"] ?? "", e?["value"] ?? "", rets[i])) {
                        ok = false
                    }
                    i++
                }
            }
        }
    }

    if (ok) {
        st.success++
    } else {
        st.failed++
        if (reported < 5) {
            reported++
            print("    FAIL {source}:{line} {field}(...)\n")
            print("      expected: {expectText}\n")
            print("      actual:   {actualText}\n")
        }
    }
}


def private run_json(name : string) : SpecStats {
    var st : SpecStats
    let jsonPath = "{SPEC_DIR}/{name}.json"
    let text = fread(jsonPath)
    if (text == "") {
        print("  {name}.json: missing\n")
        return st
    }

    var error = ""
    var root = read_json(text, error)
    if (root == null) {
        print("  {name}.json: json error {error}\n")
        return st
    }

    var s : SpecSession
    s.env = m3_NewEnvironment()
    var reported = 0

    let commands = root?["commands"]
    if (commands.value is _array) {
        for (cmd in commands.value as _array) {
            if ((cmd?["type"] ?? "") == "module") {
                // C repl_load names the module after the file (modname_from_fn).
                let filename = cmd?["filename"] ?? ""
                session_load(s, "{SPEC_DIR}/{filename}", stem(filename), st)
            } else {
                run_command(s, cmd, st, name, reported)
            }
        }
    }

    if (s.runtime != null) {
        m3_FreeRuntime(s.runtime)
    }
    m3_FreeEnvironment(s.env)
    delete_json(root)

    print("  {name}: run {st.total_run} ok {st.success} fail {st.failed} skip {st.skipped}" +
          " (modules {st.modules}, unloadable {st.moduleFailed})\n")
    return st
}


[test]
def test_spec_core_green(t : T?) {
    if (!spec_dir_present()) {
        t |> skip("{SPEC_DIR} is absent; download the wasm-core-testsuite to run the spec suite")
        return
    }
    print("spec core (must be green):\n")
    var total : SpecStats
    for (name in SPEC_GREEN) {
        let st = run_json(name)
        total |> add(st)
        t |> equal(st.failed, 0, "{name}.json failures")
        t |> success(st.total_run > 0, "{name}.json ran at least one assertion")
    }
    print("total: run {total.total_run} ok {total.success} fail {total.failed}" +
          " skip {total.skipped}\n")
}


[test]
def test_spec_core_report(t : T?) {
    if (!spec_dir_present()) {
        t |> skip("{SPEC_DIR} is absent; download the wasm-core-testsuite to run the spec suite")
        return
    }
    print("spec core (informational):\n")
    var total : SpecStats
    for (name in SPEC_INFO) {
        total |> add(run_json(name))
    }
    print("total: run {total.total_run} ok {total.success} fail {total.failed}" +
          " skip {total.skipped}\n")
    t |> success(true, "informational spec files reported")
}
