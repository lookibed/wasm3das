options gen2
options indenting = 4
// The executor nests one Daslang frame per executed op (no M3_MUSTTAIL), so
// running anything from a spec module needs a larger context stack; options
// stack counts only in the program root, which under dastest is this file.
options stack = 4_194_304

// No `module` declaration, like tests/integration/test_fib32_regression.das: under dastest
// a test file that names its module does not run the [init] functions of
// required shared modules.

require dastest/testing_boost
require daslib/fio
require daslib/json
require daslib/json_boost
require strings
require ../../source/m3_parse.das
require ../../source/m3_api_libc.das


/*
    Bulk load of the WebAssembly core testsuite.

    The fixture is the binary form of the spec suite (wast2json output): one
    <name>.json per .wast file plus the .wasm modules it references. Every
    command in the JSON that carries a "filename" names one module and states
    what the spec expects of it:

      module               a valid module: must parse and load
      assert_invalid       fails validation
      assert_malformed     fails decoding
      assert_unlinkable    decodes, but cannot be instantiated
      assert_uninstantiable  traps while instantiating

    wasm3 is not a validating runtime, so it accepts many assert_invalid
    modules; those counts are reported, not asserted. What is asserted is the
    other direction: every module the suite calls valid must go through
    m3_ParseModule and m3_LoadModule, and no input of any kind may crash the
    process.

    The pinned counts below were cross-checked against C wasm3 on 2026-09-06:
    a driver built from wasm3c/source (parse -> load -> m3_LinkSpecTest -> free,
    the same sequence as load_one) produced the identical M3Result for all 2706
    modules, including every rejection message. Any future difference in these
    numbers is therefore a divergence from C, not a change of expectations.

    The suite is a local download (tmp/ is machine-local and git-ignored), so
    the whole test skips when the directory is absent, as it is in CI.

    Paths are relative to the repository root: dastest runs with the repo root
    as its working directory.
*/


let SPEC_DIR = "tmp/spec/wasm-core-testsuite-opam-1.1.1/core"


struct SpecCounts {
    files : int                 // .wasm files walked
    parsed : int                // m3_ParseModule returned m3Err_none
    loaded : int                // ... and so did m3_LoadModule
    validTotal : int            // referenced by a "module" command
    validLoaded : int
    invalidTotal : int          // referenced by an assert_* command
    invalidRejected : int       // ... and rejected by parse or load
    linkedImports : int         // spectest imports bound by m3_LinkSpecTest
}


def private read_file(path : string) : array<u8> {
    var bytes : array<u8>
    fopen(path, "rb") $(f) {
        if (f != null) {
            let st = fstat(f)
            bytes |> resize(int64(st.size))
            fread(f, bytes)
        }
    }
    return <- bytes
}


def private spec_dir_present() : bool {
    let st = stat(SPEC_DIR)
    return st.is_valid && st.is_dir
}


// filename -> the command type that references it, from every *.json in the
// suite directory. A .wasm not in the table is not referenced by any command.
def private read_expectations(var o_expect : table<string; string>) {
    dir(SPEC_DIR) $(fn) {
        if (!ends_with(fn, ".json")) {
            return
        }
        let text = fread("{SPEC_DIR}/{fn}")
        var error = ""
        let jv = read_json(text, error)
        if (jv == null) {
            return
        }
        let cmds = jv?["commands"]
        if (cmds == null || !(cmds.value is _array)) {
            return
        }
        for (c in cmds.value as _array) {
            let name = c?["filename"] ?? ""
            if (!empty(name)) {
                o_expect[name] = c?["type"] ?? ""
            }
        }
    }
}


struct LoadOutcome {
    result : M3Result           // first failing step, or m3Err_none
    parsed : bool               // m3_ParseModule returned m3Err_none
    memoryImported : bool       // module declares an imported linear memory
    hasElementSegments : bool   // module has a non-empty element section
    linked : int                // spectest imports bound by m3_LinkSpecTest
}


// Parse, load, link and release one module.
def private load_one(path : string) : LoadOutcome {
    var outcome : LoadOutcome
    outcome.result = m3Err_none

    // binary.4.wasm is a zero-byte file: C hands m3_ParseModule the buffer and
    // the length as they are, so the port passes a null cursor with length 0
    // and gets the same m3Err_wasmSectionUnderrun out of Read_u32.
    var bytes <- read_file(path)
    var wasm : cbytes_t = null
    if (!empty(bytes)) {
        wasm = unsafe(addr(bytes[0]))
    }

    var env = m3_NewEnvironment()
    if (env == null) {
        outcome.result = m3Err_mallocFailed
        return outcome
    }
    var runtime = m3_NewRuntime(env, 64u * 1024u, null)
    if (runtime == null) {
        m3_FreeEnvironment(env)
        outcome.result = m3Err_mallocFailed
        return outcome
    }

    var _module : IM3Module
    outcome.result = m3_ParseModule(env, _module, wasm, u32(length(bytes)))

    if (outcome.result == m3Err_none) {
        outcome.parsed = true
        // Read before m3_LoadModule: a failed load frees the module here.
        outcome.memoryImported = _module.memoryImported
        outcome.hasElementSegments = _module.numElementSegments != 0u

        outcome.result = m3_LoadModule(runtime, _module)
        if (outcome.result != m3Err_none) {
            // C repl_load: a module that failed to load is still owned here.
            m3_FreeModule(_module)
            _module = null
        }
    }

    if (outcome.result == m3Err_none) {
        // C main.c links the host modules after m3_LoadModule; m3_LinkSpecTest
        // returns m3Err_moduleNotLinked before that.
        let linkResult = m3_LinkSpecTest(_module)
        if (linkResult == m3Err_none) {
            for (i in 0u.._module.numFunctions) {
                var f : IM3Function
                unsafe { f = addr(_module.functions[i]) }
                if (f.import.moduleUtf8 == "spectest" && f.compiled != null) {
                    outcome.linked++
                }
            }
        }
    }

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
    return outcome
}


/*
    The two C wasm3 limitations that make a spec-valid module fail to load.
    Both are reproduced from the C source, not worked around:

    1. Imported linear memory. m3_env.c InitMemory only sizes memory when
       `not i_module->memoryImported`, and there is no host-memory import
       mechanism, so `mallocated` stays NULL; InitDataSegments then throws
       "unallocated linear memory" unconditionally. The data, imports and
       linking modules that import "spectest" "memory" all land here.

    2. An element segment of zero elements while the table is still empty.
       m3_env.c InitElements grows table0 only `if (endElement >
       io_module->table0Size)`, but runs `_throwifnull (io_module->table0)`
       outside that `if`. A segment with numElements == 0 at offset 0 leaves
       table0 NULL and fails with m3Err_mallocFailed. Section 4 (Table) has no
       parser in C either (s_parsers[4] is NULL), so table0Size is 0 for every
       module whose table comes only from the table section.
*/
def private is_known_c_limitation(o : LoadOutcome) : bool {
    let importedMemoryBlocked = o.result == "unallocated linear memory" && o.memoryImported
    let emptyElementBlocked = o.result == m3Err_mallocFailed && o.hasElementSegments
    return importedMemoryBlocked || emptyElementBlocked
}


[test]
def test_spec_modules_load(t : T?) {
    if (!spec_dir_present()) {
        t |> skip("wasm core testsuite not present at {SPEC_DIR}")
        return
    }

    // `expect` is a daslang keyword, so the table is spelled `expectations`.
    var expectations : table<string; string>
    read_expectations(expectations)
    t |> success(!empty(expectations), "spec json commands reference modules")

    var names : array<string>
    dir(SPEC_DIR) $(fn) {
        if (ends_with(fn, ".wasm")) {
            names |> push(fn)
        }
    }
    sort(names)
    t |> success(!empty(names), "spec directory contains .wasm modules")

    var counts : SpecCounts
    var importedMemory : array<string>
    var emptyElementSegment : array<string>
    var unexpected : array<string>
    var acceptedInvalid = 0

    for (fn in names) {
        counts.files++
        let kind = expectations?[fn] ?? ""
        let outcome = load_one("{SPEC_DIR}/{fn}")
        counts.linkedImports += outcome.linked

        if (outcome.parsed) {
            counts.parsed++
        }
        if (outcome.result == m3Err_none) {
            counts.loaded++
        }

        if (kind == "module") {
            counts.validTotal++
            if (outcome.result == m3Err_none) {
                counts.validLoaded++
            } elif (!is_known_c_limitation(outcome)) {
                unexpected |> push("{fn}: {outcome.result}")
            } elif (outcome.memoryImported) {
                importedMemory |> push(fn)
            } else {
                emptyElementSegment |> push(fn)
            }
        } elif (starts_with(kind, "assert_")) {
            counts.invalidTotal++
            if (outcome.result != m3Err_none) {
                counts.invalidRejected++
            } else {
                acceptedInvalid++
            }
        }
    }

    print("spec modules: {counts.files} .wasm files walked, {counts.parsed} parsed, {counts.loaded} loaded\n")
    print("  valid (\"module\" command): {counts.validTotal}, loaded {counts.validLoaded}, failed {counts.validTotal - counts.validLoaded}\n")
    print("  invalid (assert_*):        {counts.invalidTotal}, rejected {counts.invalidRejected}, accepted {acceptedInvalid}\n")
    print("  spectest imports linked:   {counts.linkedImports}\n")
    print("  not loadable, imported linear memory ({length(importedMemory)}): {importedMemory}\n")
    print("  not loadable, empty element segment ({length(emptyElementSegment)}): {emptyElementSegment}\n")
    for (f in unexpected) {
        print("  UNEXPECTED failure {f}\n")
    }

    // Reaching this point at all is the no-crash assertion: a panic, a bad
    // free or an unbounded allocation in any of the ~2700 modules would have
    // taken the process down before here.
    t |> success(true, "no crash over the whole testsuite")
    t |> equal(length(unexpected), 0, "every valid spec module loads or hits a known C limitation")
    // The two documented C limitations, pinned so that a regression that adds
    // a new failure to either bucket is visible.
    t |> equal(length(importedMemory), 28, "valid modules blocked by imported linear memory")
    t |> equal(length(emptyElementSegment), 5, "valid modules blocked by the empty element segment")
    t |> equal(counts.validLoaded, 820, "valid spec modules loaded")
    // Same total the C reference driver reports over the same 2706 files.
    t |> equal(counts.loaded, 2523, "modules of any expectation that load")
    t |> success(counts.linkedImports > 0, "spectest imports linked through m3_LinkSpecTest")
}


// ============================================================================
// Linking: an import called from wasm through op_CallRawFunction
// ============================================================================


var private g_rawCalls = 0
var private g_lastI32 = 0


// C: m3ApiRawFunction (counting_print_i32). m3ApiGetArg (int32_t, i_value)
// reads one 32-bit slot off _sp and advances it.
def private counting_print_i32(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    g_rawCalls++
    unsafe {
        g_lastI32 = *reinterpret<i32?>(_sp)
    }
    return m3Err_none
}


def private counting_dummy(runtime : IM3Runtime; _ctx : IM3ImportContext; _sp : u64?; _mem : void?) : M3Result {
    g_rawCalls++
    return m3Err_none
}


/*
    core/imports.1.wasm imports the seven spectest print functions and exports
    print32 (i32) -> () and print64 (i64) -> (), whose bodies call them. The
    module is the binary of imports.wast line 24; imports.json asserts
    (invoke "print32" (i32.const 13)).

    Linking every import to a counting raw function and invoking print32 goes
    through m3_LinkRawFunction -> FindAndLinkFunction -> ValidateSignature ->
    CompileRawFunction, and at run time through op_CallRawFunction.
*/
[test]
def test_spec_link_raw_function(t : T?) {
    if (!spec_dir_present()) {
        t |> skip("wasm core testsuite not present at {SPEC_DIR}")
        return
    }

    var bytes <- read_file("{SPEC_DIR}/imports.1.wasm")
    t |> success(!empty(bytes), "imports.1.wasm is readable")
    if (empty(bytes)) return

    var env = m3_NewEnvironment()
    var runtime = m3_NewRuntime(env, 64u * 1024u, null)
    var _module : IM3Module
    t |> equal(m3_ParseModule(env, _module, unsafe(addr(bytes[0])), u32(length(bytes))), m3Err_none, "m3_ParseModule imports.1")
    if (_module == null) return
    t |> equal(m3_LoadModule(runtime, _module), m3Err_none, "m3_LoadModule imports.1")

    // C m3_bind.c FindAndLinkFunction: m3Err_functionLookupFailed when the
    // module imports nothing under that name.
    t |> equal(m3_LinkRawFunction(_module, "spectest", "no_such_import", "v()", @@counting_dummy),
        m3Err_functionLookupFailed, "unknown import name")
    // C ValidateSignature: AreFuncTypesEqual against the import's own type.
    t |> equal(m3_LinkRawFunction(_module, "spectest", "print_i32", "v(F)", @@counting_dummy),
        "function signature mismatch", "wrong signature")

    g_rawCalls = 0
    g_lastI32 = 0
    // m3_api_libc.c m3_LinkSpecTest wraps every link in SuppressLookupFailure,
    // so a module that imports only some of the seven still links cleanly.
    t |> equal(m3_LinkSpecTest(_module), m3Err_none, "m3_LinkSpecTest")
    // spectest.print_f64_f64 exists in the 1.1.1 spec harness but not in the
    // C m3_LinkSpecTest list; link it here so no import is left uncompiled.
    t |> equal(m3_LinkRawFunction(_module, "spectest", "print_f64_f64", "v(FF)", @@counting_dummy), m3Err_none, "link print_f64_f64")
    // C: const bool wildcardModule = (strcmp (i_moduleName, "*") == 0).
    t |> equal(m3_LinkRawFunction(_module, "*", "print_f32", "v(f)", @@counting_dummy), m3Err_none, "wildcard module name")
    t |> equal(m3_LinkRawFunction(_module, "spectest", "print_i32", "v(i)", @@counting_print_i32), m3Err_none, "link print_i32")

    var print32 : IM3Function
    t |> equal(m3_FindFunction(print32, runtime, "print32"), m3Err_none, "m3_FindFunction print32")
    if (print32 != null) {
        var args : array<M3TaggedValue>
        args |> resize(1)
        args[0]._type = M3ValueType.c_m3Type_i32
        tagged_set_i32(args[0], 13)
        t |> equal(m3_CallV(print32, args), m3Err_none, "m3_CallV print32(13)")
        t |> success(g_rawCalls > 0, "op_CallRawFunction reached the host function")
        t |> equal(g_lastI32, 13, "host function saw the wasm argument")
    }

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
}
