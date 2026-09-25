options gen2
options indenting = 4

module m3_env shared public

require modules/wasm3das/source/m3_core                  // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types public          // Eden: project-root-relative path (upstream: ./m3_types.das)
require modules/wasm3das/source/m3_exec_defs             // Eden: project-root-relative path (upstream: ./m3_exec_defs.das)
require modules/wasm3das/source/m3_code public           // Eden: project-root-relative path (upstream: ./m3_code.das)
require modules/wasm3das/source/m3_function              // Eden: project-root-relative path (upstream: ./m3_function.das)
require modules/wasm3das/source/m3_module public         // Eden: project-root-relative path (upstream: ./m3_module.das)
require modules/wasm3das/source/m3_compile public        // Eden: project-root-relative path (upstream: ./m3_compile.das)
require modules/wasm3das/source/m3_exec                  // Eden: project-root-relative path (upstream: ./m3_exec.das)
require math                                             // min (C: M3_MIN)
require strings
require daslib/math_bits                                // Eden: the f32 / f64 views of the u64 value bits (upstream: addr views)


// Conservative Gen2 port of m3_env.c.
// Core wasm3 types, allocators, parsing helpers, and CompileBlock/CompileFunction
// are expected from the shared project layer, matching the existing module graph.
// Daslang has no C va_list; m3_CallV/m3_CallVL and m3_GetResultsV/m3_GetResultsVL
// use typed M3TaggedValue arrays as the Gen2 boundary while preserving stack layout.

/*
    Eden: deviations from the upstream port (.upstream/source/m3_env.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.1 - 4.6).
    The sandbox has no raw pointers: the runtime owns every arena and every
    C pointer is a handle (-1 = NULL) or an index.
      - requires are Eden-project-root relative (DESIGN section 6); m3_types,
        m3_code, m3_module and m3_compile stay public re-exports;
        daslib/math_bits supplies the float views of the value bits. The
        upstream `options never_inline` is dropped (untested in the editor,
        DESIGN section 1).
      - every function takes the runtime first (`var rt : M3Runtime`, C:
        `i_function->module->runtime` or the IM3Runtime argument), then the
        C parameters in C order; a module, function, global or func type is
        its handle into rt.modules / rt.functions / rt.globals /
        rt.funcTypes.
      - the environment (DESIGN 4.1, m3_types): M3Environment is a value.
        m3_NewEnvironment returns it with the hooks wired; its
        retFuncTypes are handles into a runtime's funcTypes arena, so the C
        loop of m3_NewEnvironment that creates them (AllocFuncType +
        Environment_AddFuncType per block result type) runs in
        m3_NewRuntime, on the copy the runtime embeds (rt.environment).
        Environment_Release / m3_FreeEnvironment reset the value (the
        interned types and the released pages live in the runtime).
        m3_SetCustomSectionHandler sets the handler on the value it is given:
        set it before m3_NewRuntime, or on rt.environment.
      - Environment_AddFuncType(rt, io_funcType): the interned list is the
        arena rt.funcTypes (AllocFuncType appended the new type), so an
        equal existing type is searched among the other slots and, when one
        is found, the just-appended slot is popped (C: m3_Free (addType));
        the survivor is the existing handle (DESIGN 4.1).
      - the hooks: m3_NewEnvironment and m3_NewRuntime wire
        CompileFunctionHook = @@CompileFunction and
        ResizeMemoryHook = @@ResizeMemory (upstream: m3_NewEnvironment only);
        m3_NewRuntime also builds the op table and the operation tables
        (m3_build_operations_table; upstream: init_compile_operation_tables
        from m3_NewEnvironment). All idempotent.
      - m3_NewRuntime returns the M3Runtime value (C: a pointer, NULL on
        allocation failure, which cannot happen observably here). The stack
        is rt.stack with exactly numStackSlots = i_stackSizeInBytes / 4 words
        (one u64 word per slot, DESIGN 4.3; C allocates 4 spare slots past
        maxStack that nothing reads) and originStack = 0; op_Entry's
        overflow point is length(rt.stack). userdata is an int token.
      - the module list (C: runtime->modules, linked through module->next)
        is the arena rt.modules: a module is linked while its `runtime` is
        0 (m3_LoadModule sets it, m3_FreeModule clears it). ForEachModule
        visits the linked modules from the highest handle down, which is C's
        order (latest loaded first) when modules are loaded in the order
        they were parsed; Runtime_FirstModule is C's `runtime->modules`
        head. ModuleVisitor takes the runtime, the module handle and the
        info string and returns a handle (C: void *, -1 = NULL).
      - m3_FreeRuntime(rt): Runtime_Release, then the value is reset to
        M3Runtime() (C: m3_Free (runtime)); the stack and the memory are
        freed by emptying rt.stack / rt.mem.
      - EvaluateExpression: C compiles and runs the expression in a
        temporary M3Runtime that shares the module's runtime's environment
        and stack. Its arenas cannot be separated from the runtime here, so
        the same runtime is used and the temporary's own state is emulated:
        rt.compilation, the page lists (pagesOpen, pagesFull), the page
        counters and rt.error are saved, reset for the expression and
        restored afterwards, and the temporary's pages go back to the pool
        (C: Runtime_Release of the temporary, whose module list is empty,
        is its two Environment_ReleaseCodePages calls). The expression runs
        at rt.originStack (C: runtime->stack) with the registers saved and
        restored around it. o_expressed is a u64 (C: void *): a 32-bit
        result replaces its low four bytes only, as C's `* (u32 *)` store
        into a global's union or an i32 local. As in C, a trapping
        expression leaves the result m3Err_none and o_expressed untouched.
      - ResizeMemory: the linear memory is rt.mem (DESIGN 4.2); the resize
        is `resize(rt.mem, numPageBytes)` (zero-filled like m3_Realloc) and
        the M3MemoryHeader writes (length, runtime, maxStack) are absent. A
        size a daslang array cannot hold (above 0x7fffffff bytes) is C's
        failed realloc, m3Err_mallocFailed.
      - InitDataSegments(rt, io_module): C's io_memory is rt.memory / rt.mem.
        C's `not io_memory->mallocated` (ResizeMemory never ran) is
        rt.memory.pageSize == 0 (InitMemory sets it before the first
        ResizeMemory). The segment bytes are copied from the module's `wasm`
        (segment.data is an index into it) into rt.mem.
      - InitElements: table0 grows to endElement with -1 (C: realloc's zero
        fill, NULL); table0 holds function handles. `_throwifnull
        (table0)` has no counterpart (allocation cannot fail observably).
      - the panic guard (DESIGN 4.4a): d_m3Assert panics, and so does an
        array bound. m3_LoadModule, EvaluateExpression, every compilation
        this module starts (GuardedCompileFunction: m3_CompileModule,
        m3_RunStart, m3_FindFunction, m3_GetTableFunction) and every run of
        wasm code (RunFunctionCode: m3_RunStart and the m3_Call family, lazy
        compilation by op_Compile included) run inside try / recover. A
        panic becomes an M3Result "wasm3 panic in <where>" (m3Err_panic*
        below; the recover block cannot read the panic message). A code page
        still held by an interrupted compilation (numActiveCodePages above
        its value before the guarded call) is released, so
        m3_FreeRuntime's assertion keeps holding.
      - RunFunctionCode(rt, f) is C's inline RunCode (function->compiled,
        runtime->stack, ...) of m3_RunStart and the calls: it saves rt.pc,
        rt.sp, rt.r0, rt.fp0 (C passes them by value, so a host function
        re-entering m3_Call does not disturb its caller) and
        rt.originStack, and restores all five on every path. The
        originStack restore matters after a panic: op_CallRawFunction moves
        originStack to the host frame for the call and puts it back only
        when the host function returns, so a panicking host function would
        leave every later m3_Call / m3_GetResults / EvaluateExpression on a
        shifted base (C has no such path: a host function cannot unwind).
        EvaluateExpression's guard restores it the same way. It starts at
        rt.pc = compiled, rt.sp = rt.originStack with cleared registers,
        resets rt.trap (DESIGN 4.4: nothing else clears it), runs RunCode
        and maps the protocol: M3_RETURN is m3Err_none, M3_TRAP is rt.trap.
      - m3_FindGlobal: the import test `moduleUtf8 and fieldUtf8` is the
        global's `imported` flag (an import has both names; "" cannot tell
        C's NULL, DESIGN 4.1). The export test `g->name` (non-NULL) is the
        global's `isExported` flag (m3_types), which m3_parse sets with
        the export name, so a global exported under the name "" is found
        by "" and an unnamed global never is. (C's DEBUG-only
        Module_GenerateNames, which would name every global, is compiled
        out.)
      - v_FindFunction / m3_FindFunction, the NULL-vs-"" rule (DESIGN 4.1):
        C's `f->import.moduleUtf8 or f->import.fieldUtf8` is the function's
        position among the module's imports (index < numFuncImports: the
        parser adds every import first, and only imports, with both names
        set); C's `f->export_name` non-NULL is FunctionIsExported, the
        function's `isExported` flag (m3_types), which m3_parse sets with
        export_name. No name comparison decides whether a function is
        exported. `f->names[j]` for j < numNames is never NULL. So an
        import with field name "" is found neither as an export nor as an
        internal function, a function exported as "" is found by "", and
        an export named "" is found before a local function whose name
        section entry is "".
      - m3_CallV / m3_CallVL take `array<M3TaggedValue>` (C: the variadic
        list; the upstream typed form, with its argument-count check).
        m3_Call(rt, f, i_args : array<u64>) is C's `i_argc, i_argptrs[]`:
        each argument is its value bits (the i32 / f32 ones in the low 32
        bits, the m3_bits_from_* helpers below build them) and argc is
        length(i_args). m3_CallArgv(rt, f, i_argv : array<string>) parses as
        C (strtoul / strtoull / strtod, m3_strtoull / m3_strtod below:
        glibc's strtod in plain daslang, decimal through to_double with
        overflow to +-inf and underflow to +-0, inf / nan (with glibc's
        payload), and exact hexadecimal floats).
        The arguments go to rt.stack from GetStackPointerForArgs =
        rt.originStack + numRets * c_ioSlotCount (C: (u64 *) runtime->stack
        + numRets), one u64 cell = c_ioSlotCount slots per value (C: s += 8);
        a 32-bit value is stored zero-extended (DESIGN 4.4).
      - m3_GetResults(rt, f, i_retc, o_retBits : array<u64>) returns the
        result bits (C: o_retptrs[]); m3_GetResultsV / m3_GetResultsVL fill
        an array<M3TaggedValue> (upstream). Results are read at
        rt.originStack + i * c_ioSlotCount (C: runtime->stack, s += 8).
        tagged_get_* / tagged_set_* and m3_bits_to_* / m3_bits_from_* are
        the typed accessors (upstream: address views).
      - m3_GetMemory(rt, o_memorySizeInBytes, i_memoryIndex) returns the
        index of the first byte in rt.mem, 0, or -1 when the size is 0 (C:
        the u8 pointer, NULL); the bytes are rt.mem, read and written with
        the load_* / store_* accessors of m3_exec_defs. m3_GetMemorySize is
        length(rt.mem). The upstream NULL guards are not needed (rt.mem
        always exists).
      - m3_GetBacktrace returns an empty M3BacktraceInfo (C: NULL,
        d_m3RecordBacktraces == false); frames/lastFrame/next are handles.
      - C's m3Error lives in m3_types (DESIGN 4.1) and the code-page
        functions of m3_env.c (RemoveCodePageOfCapacity ...
        ReleaseCodePage) in m3_code; their places in the C order are marked.
    Everything else (names, order, control flow, checks and error strings)
    is the C of m3_env.c.
*/


// C: the u8 value types of m3_core.h as the upstream port spells them
let c_m3Type_none : u8 = u8(M3ValueType.c_m3Type_none)
let c_m3Type_i32 : u8 = u8(M3ValueType.c_m3Type_i32)
let c_m3Type_i64 : u8 = u8(M3ValueType.c_m3Type_i64)
let c_m3Type_f32 : u8 = u8(M3ValueType.c_m3Type_f32)
let c_m3Type_f64 : u8 = u8(M3ValueType.c_m3Type_f64)


// Eden: the results of a panic caught by the guards (see the header)
let public m3Err_panicLoadModule : M3Result = "wasm3 panic in m3_LoadModule"
let public m3Err_panicEvaluateExpression : M3Result = "wasm3 panic in EvaluateExpression"
let public m3Err_panicCompileFunction : M3Result = "wasm3 panic in CompileFunction"
let public m3Err_panicRunCode : M3Result = "wasm3 panic in RunCode"


/* C m3_env.h: typedef void * (* ModuleVisitor) (IM3Module i_module, void * i_info); */
// Eden: the runtime, the module handle and the info string; returns a
// handle, -1 = NULL (see the header)
typedef public ModuleVisitor = function<(var rt : M3Runtime; i_module : IM3Module; i_info : string) : int>


/* C wasm3.h: typedef struct M3BacktraceFrame {...} M3BacktraceFrame, * IM3BacktraceFrame; */
struct M3BacktraceFrame {
    moduleOffset : u32 = 0u
    functionIdx : IM3Function = -1   // C field `function`; Eden: handle into rt.functions
    next : int = -1                  // Eden: index into M3BacktraceInfo.frames, -1 = NULL
}


/* C wasm3.h: typedef struct M3BacktraceInfo {...} M3BacktraceInfo, * IM3BacktraceInfo; */
struct M3BacktraceInfo {
    frames : array<M3BacktraceFrame>   // Eden: the frame list (C: IM3BacktraceFrame, a linked list)
    lastFrame : int = -1               // Eden: index into frames, -1 = NULL
}


// ============================================================================
// Typed views of the value bits (upstream: address views)
// ============================================================================


// C: (M3ValueType) i_type. Eden: without reinterpret, value by value.
def public m3_value_type(i_type : u8) : M3ValueType {
    var t = M3ValueType.c_m3Type_unknown
    if (i_type == u8(M3ValueType.c_m3Type_none)) {
        t = M3ValueType.c_m3Type_none
    } elif (i_type == u8(M3ValueType.c_m3Type_i32)) {
        t = M3ValueType.c_m3Type_i32
    } elif (i_type == u8(M3ValueType.c_m3Type_i64)) {
        t = M3ValueType.c_m3Type_i64
    } elif (i_type == u8(M3ValueType.c_m3Type_f32)) {
        t = M3ValueType.c_m3Type_f32
    } elif (i_type == u8(M3ValueType.c_m3Type_f64)) {
        t = M3ValueType.c_m3Type_f64
    } elif (i_type == u8(M3ValueType.c_m3Type_v128)) {
        t = M3ValueType.c_m3Type_v128
    }
    return t
}


// Eden: the bits of a value as m3_Call takes them and m3_GetResults returns
// them (a 32-bit value in the low 32 bits, zero-extended)
def public m3_bits_from_i32(i_value : i32) : u64 {
    return u64(u32(i_value))
}

def public m3_bits_from_i64(i_value : i64) : u64 {
    return u64(i_value)
}

def public m3_bits_from_f32(i_value : f32) : u64 {
    return u64(float_bits_to_uint(i_value))
}

def public m3_bits_from_f64(i_value : f64) : u64 {
    return double_bits_to_uint64(i_value)
}

def public m3_bits_to_i32(i_bits : u64) : i32 {
    return i32(u32(i_bits))
}

def public m3_bits_to_i64(i_bits : u64) : i64 {
    return i64(i_bits)
}

def public m3_bits_to_f32(i_bits : u64) : f32 {
    return uint_bits_to_float(u32(i_bits))
}

def public m3_bits_to_f64(i_bits : u64) : f64 {
    return uint64_bits_to_double(i_bits)
}


// the M3TaggedValue union members (upstream: address views of valueBits);
// Eden: a 32-bit member store replaces the low four bytes only, as C's union
// member store does
def public tagged_get_i32(i_value : M3TaggedValue) : i32 {
    return m3_bits_to_i32(i_value.valueBits)
}

def public tagged_get_i64(i_value : M3TaggedValue) : i64 {
    return m3_bits_to_i64(i_value.valueBits)
}

def public tagged_get_f32(i_value : M3TaggedValue) : f32 {
    return m3_bits_to_f32(i_value.valueBits)
}

def public tagged_get_f64(i_value : M3TaggedValue) : f64 {
    return m3_bits_to_f64(i_value.valueBits)
}

def public tagged_set_i32(var io_value : M3TaggedValue&; i_value : i32) {
    io_value.valueBits = (io_value.valueBits & 0xffffffff00000000ul) | m3_bits_from_i32(i_value)
}

def public tagged_set_i64(var io_value : M3TaggedValue&; i_value : i64) {
    io_value.valueBits = m3_bits_from_i64(i_value)
}

def public tagged_set_f32(var io_value : M3TaggedValue&; i_value : f32) {
    io_value.valueBits = (io_value.valueBits & 0xffffffff00000000ul) | m3_bits_from_f32(i_value)
}

def public tagged_set_f64(var io_value : M3TaggedValue&; i_value : f64) {
    io_value.valueBits = m3_bits_from_f64(i_value)
}


// ============================================================================
// C library parsers of m3_CallArgv (strtoul / strtoull / strtod)
// ============================================================================


// C: strtoull (i_text, NULL, 10) (strtoul is the same on LP64): leading white
// space, an optional sign (a '-' negates in unsigned arithmetic), the longest
// decimal prefix; no digits give 0, an out-of-range value ULLONG_MAX.
// Eden: the digits are converted by to_uint64 of the strings module, which
// gives 0 on overflow; a digit prefix that is not all zeros and converts to
// 0 is that overflow.
def private m3_strtoull(i_text : string) : u64 {
    var text = strip_left(i_text)
    var negative = false
    if (length(text) > 0 && (character_at(text, 0) == '-' || character_at(text, 0) == '+')) {
        negative = character_at(text, 0) == '-'
        text = slice(text, 1)
    }
    var nonZeroDigit = false
    var i = 0
    while (i < length(text) && character_at(text, i) >= '0' && character_at(text, i) <= '9') {
        if (character_at(text, i) != '0') {
            nonZeroDigit = true
        }
        i++
    }
    if (i == 0) {
        return 0ul
    }
    let value = to_uint64(slice(text, 0, i))
    if (value == 0ul && nonZeroDigit) {
        return 0xfffffffffffffffful   // C: ERANGE, ULLONG_MAX whatever the sign
    }
    return negative ? (0ul - value) : value
}


// C: strtod (i_text, NULL) as glibc implements it: leading white space, an
// optional sign, then the longest prefix of one of
//   - a decimal float: digits with an optional '.', at least one digit, an
//     optional exponent [eE][+-]digits (taken only when it has a digit);
//   - a hexadecimal float: 0x / 0X, hex digits with an optional '.', at
//     least one hex digit, an optional binary exponent [pP][+-]digits;
//     without a hex digit only the "0" is read;
//   - "inf" or "infinity", "nan" or "nan(n-char-sequence)", any case;
// no conversion gives 0. A value too large gives +-HUGE_VAL (+-inf), one
// too small +-0 or the denormal the rounding gives (ERANGE is not read by
// m3_CallArgv). The sign applies to every form (-0, -inf, -nan).
// Eden: the decimal digits are converted by to_double of the strings module
// (fast_float, correctly rounded), which returns 0 for an out-of-range
// value: a prefix with a nonzero digit that converts to 0 is overflow when
// its leading digit's decimal exponent is >= 0 and underflow otherwise.
// The hexadecimal form is exact: the leading 60 bits of the mantissa, a
// sticky bit for the rest, rounded once to nearest-even into the double
// (or denormal) bits. glibc's NaN payload (the n-char-sequence read as
// strtoull base 0 when it is all digits, its low 51 bits) is kept.
def private is_decimal_digit(c : int) : bool {
    return c >= '0' && c <= '9'
}


// the value of a hex digit, -1 when `c` is not one
def private hex_digit_value(c : int) : int {
    if (c >= '0' && c <= '9') {
        return c - '0'
    } elif (c >= 'a' && c <= 'f') {
        return c - 'a' + 10
    } elif (c >= 'A' && c <= 'F') {
        return c - 'A' + 10
    }
    return -1
}


// true when `text` has `word` at `at`, ASCII case-insensitive
def private has_word_at(text : string; at : int; word : string) : bool {
    if (at + length(word) > length(text)) {
        return false
    }
    for (i in range(length(word))) {
        var c = character_at(text, at + i)
        if (c >= 'A' && c <= 'Z') {
            c += 'a' - 'A'
        }
        if (c != character_at(word, i)) {
            return false
        }
    }
    return true
}


// the optional exponent [+-]digits at `at` (after the 'e' or 'p'): its
// value saturated at +-1000000 and the index past it; `at` itself (no
// exponent) when there is no digit
def private parse_exponent(text : string; at : int; var o_exponent : int&) : int {
    var i = at
    var negative = false
    if (i < length(text) && (character_at(text, i) == '+' || character_at(text, i) == '-')) {
        negative = character_at(text, i) == '-'
        i++
    }
    if (i >= length(text) || !is_decimal_digit(character_at(text, i))) {
        o_exponent = 0
        return at
    }
    var value = 0
    while (i < length(text) && is_decimal_digit(character_at(text, i))) {
        if (value < 1000000) {
            value = value * 10 + (character_at(text, i) - '0')
        }
        i++
    }
    o_exponent = negative ? -value : value
    return i
}


// glibc's NaN payload: strtoull (seq, &end, 0) over the whole sequence
// (0x.. hex, 0.. octal, decimal; ULLONG_MAX when out of range); false when
// the sequence is not all consumed
def private nan_payload(seq : string; var o_payload : u64&) : bool {
    var i = 0
    var base = 10ul
    if (length(seq) >= 2 && character_at(seq, 0) == '0' && (character_at(seq, 1) == 'x' || character_at(seq, 1) == 'X') && length(seq) > 2 && hex_digit_value(character_at(seq, 2)) >= 0) {
        base = 16ul
        i = 2
    } elif (length(seq) >= 1 && character_at(seq, 0) == '0') {
        base = 8ul
    }
    if (i >= length(seq)) {
        return false
    }
    var value = 0ul
    var overflow = false
    while (i < length(seq)) {
        let d = hex_digit_value(character_at(seq, i))
        if (d < 0 || u64(d) >= base) {
            return false
        }
        if (value > (0xfffffffffffffffful - u64(d)) / base) {
            overflow = true
        } else {
            value = value * base + u64(d)
        }
        i++
    }
    o_payload = overflow ? 0xfffffffffffffffful : value
    return true
}


// the hexadecimal float after "0x" at `at` (see m3_strtod); false when it
// has no hex digit
def private parse_hex_float(text : string; at : int; var o_bits : u64&) : bool {
    var i = at
    var mantissa = 0ul       // the leading bits, below 2^64
    var binaryExponent = 0   // value = (mantissa + sticky) * 2^binaryExponent
    var sticky = false
    var anyDigit = false
    var inFraction = false
    while (i < length(text)) {
        let c = character_at(text, i)
        if (c == '.' && !inFraction) {
            inFraction = true
            i++
            continue
        }
        let d = hex_digit_value(c)
        if (d < 0) {
            break
        }
        anyDigit = true
        if ((mantissa >> 60ul) == 0ul) {
            mantissa = (mantissa << 4ul) | u64(d)
            if (inFraction) {
                binaryExponent -= 4
            }
        } else {
            sticky = sticky || d != 0
            if (!inFraction) {
                binaryExponent += 4
            }
        }
        i++
    }
    if (!anyDigit) {
        return false
    }
    if (i < length(text) && (character_at(text, i) == 'p' || character_at(text, i) == 'P')) {
        var exponent = 0
        parse_exponent(text, i + 1, exponent)
        binaryExponent += exponent
    }
    if (mantissa == 0ul) {
        o_bits = 0ul
        return true
    }
    var msb = 63   // the position of the mantissa's leading bit
    while ((mantissa >> u64(msb)) == 0ul) {
        msb--
    }
    let exponent = msb + binaryExponent   // the value is in [2^exponent, 2^(exponent+1))
    if (exponent > 1023) {
        o_bits = 0x7ff0000000000000ul
        return true
    }
    // a normal keeps 53 bits; a denormal counts units of 2^-1074
    let shift = max(msb - 52, -(binaryExponent + 1074))
    var q = 0ul
    if (shift <= 0) {
        q = mantissa << u64(-shift)   // exact: the mantissa has at most 53 bits here
    } elif (shift > 64) {
        q = 0ul                       // below half of 2^-1074: rounds to 0
    } else {
        let half = 1ul << u64(shift - 1)
        let rest = shift == 64 ? mantissa : (mantissa & ((1ul << u64(shift)) - 1ul))
        q = shift == 64 ? 0ul : (mantissa >> u64(shift))
        if (rest > half || (rest == half && (sticky || (q & 1ul) != 0ul))) {
            q++
        }
    }
    if (shift == msb - 52) {
        // normal: the exponent field above the 52 fraction bits; a carry to
        // 2^53 moves into the exponent (and 2^1024 is the inf bits)
        o_bits = (u64(exponent + 1023) << 52ul) + (q - 0x10000000000000ul)
    } else {
        o_bits = q   // denormal (a carry to 2^52 is the smallest normal)
    }
    return true
}


def private m3_strtod(i_text : string) : f64 {
    let text = strip_left(i_text)
    var i = 0
    var negative = false
    if (length(text) > 0 && (character_at(text, 0) == '-' || character_at(text, 0) == '+')) {
        negative = character_at(text, 0) == '-'
        i = 1
    }
    let signBit = negative ? 0x8000000000000000ul : 0ul
    // infinity / nan
    if (has_word_at(text, i, "inf")) {
        return uint64_bits_to_double(signBit | 0x7ff0000000000000ul)
    }
    if (has_word_at(text, i, "nan")) {
        var bits = 0x7ff8000000000000ul
        let open = i + 3
        if (open < length(text) && character_at(text, open) == '(') {
            let close = find(text, ')', open)
            var payload = 0ul
            if (close > open && nan_payload(slice(text, open + 1, close), payload)) {
                bits |= payload & 0x7fffffffffffful
            }
        }
        return uint64_bits_to_double(signBit | bits)
    }
    // hexadecimal
    if (i + 1 < length(text) && character_at(text, i) == '0' && (character_at(text, i + 1) == 'x' || character_at(text, i + 1) == 'X')) {
        var bits = 0ul
        if (parse_hex_float(text, i + 2, bits)) {
            return uint64_bits_to_double(signBit | bits)
        }
        return negative ? -0.0lf : 0.0lf   // only the "0" is read
    }
    // decimal
    let start = i
    var firstNonZero = -1      // the index of the leading nonzero digit
    var point = -1             // the index of the '.'
    var digits = 0
    while (i < length(text)) {
        let c = character_at(text, i)
        if (c == '.' && point == -1) {
            point = i
        } elif (is_decimal_digit(c)) {
            digits++
            if (c != '0' && firstNonZero == -1) {
                firstNonZero = i
            }
        } else {
            break
        }
        i++
    }
    if (digits == 0) {
        return 0.0lf   // no conversion
    }
    let digitsEnd = i
    var exponent = 0
    if (i < length(text) && (character_at(text, i) == 'e' || character_at(text, i) == 'E')) {
        let after = parse_exponent(text, i + 1, exponent)
        if (after != i + 1) {
            i = after   // an 'e' without a digit is not read
        }
    }
    var value = to_double(slice(text, start, i))
    if (value == 0.0lf && firstNonZero != -1) {
        // out of range: the decimal exponent of the leading nonzero digit
        let pointAt = point == -1 ? digitsEnd : point
        let leading = (firstNonZero < pointAt ? pointAt - firstNonZero - 1 : pointAt - firstNonZero) + exponent
        value = leading >= 0 ? uint64_bits_to_double(0x7ff0000000000000ul) : 0.0lf
    }
    return negative ? -value : value
}


// ============================================================================
// m3_env.c
// ============================================================================


// C: m3_NewEnvironment. Eden: the environment is a value (see the header);
// the retFuncTypes loop runs in m3_NewRuntime, whose arena holds the types.
def public m3_NewEnvironment() : M3Environment {
    // Port scaffolding (m3_exec.das hook note): C's m3_exec.h reaches the
    // compiler and ResizeMemory through its include cycle; the acyclic
    // Daslang module graph replaces those edges with these global bindings,
    // registered once before any runtime can execute. Idempotent.
    CompileFunctionHook = @@CompileFunction
    ResizeMemoryHook = @@ResizeMemory

    // C: m3_AllocStruct (M3Environment); Eden: the value, retFuncTypes -1
    var env = M3Environment()

    // C: for (u8 t = c_m3Type_none; t <= c_m3Type_f64; t++) { AllocFuncType ...
    // Environment_AddFuncType (env, & ftype); env->retFuncTypes [t] = ftype; }
    // Eden: in m3_NewRuntime (the func types are the runtime's arena)

    return env
}


// C: Environment_Release. Eden: the interned func types (C: the list freed
// here) and the released code pages (C: FreeCodePages (pagesReleased)) are
// the runtime's; the value is reset.
def public Environment_Release(var i_environment : M3Environment&) {
    i_environment = M3Environment()
}


def public m3_FreeEnvironment(var i_environment : M3Environment&) {
    // C: if (i_environment); Eden: a reference is never NULL
    Environment_Release(i_environment)
    // C: m3_Free (i_environment); Eden: the value is the caller's
}


def public m3_SetCustomSectionHandler(var i_environment : M3Environment&; i_handler : M3SectionHandler) {
    // C: if (i_environment); Eden: a reference is never NULL
    i_environment.customSectionHandler = i_handler
}


// returns the same io_funcType or replaces it with an equivalent that's already in the type linked list
// Eden: the list is the arena rt.funcTypes, which already holds io_funcType
// (AllocFuncType appended it); see the header
def public Environment_AddFuncType(var rt : M3Runtime; var io_funcType : IM3FuncType&) {
    let addType = io_funcType
    var newType : IM3FuncType = -1

    for (candidate in range(length(rt.funcTypes))) {
        if (candidate != addType && AreFuncTypesEqual(rt, candidate, addType)) {
            newType = candidate
            // C: m3_Free (addType); Eden: the just-appended slot is popped
            if (addType == length(rt.funcTypes) - 1) {
                pop(rt.funcTypes)
            }
            break
        }
    }

    if (newType == -1) {
        // C: newType = addType; newType->next = i_environment->funcTypes;
        //    i_environment->funcTypes = newType;
        // Eden: the slot stays in the arena, which is the list
        newType = addType
    }

    io_funcType = newType
}


// C: RemoveCodePageOfCapacity, Environment_AcquireCodePage,
// Environment_ReleaseCodePages: in m3_code (see the header).


// C: IM3Runtime m3_NewRuntime (IM3Environment i_environment, u32 i_stackSizeInBytes, void * i_userdata)
// Eden: returns the runtime value; i_userdata is an int token (see the header)
def public m3_NewRuntime(i_environment : M3Environment; i_stackSizeInBytes : u32; i_userdata : int) : M3Runtime {
    // Eden: the op table and the operation tables (C: static initialisers)
    // and the hooks, before any code of this runtime compiles or runs
    m3_build_operations_table()
    CompileFunctionHook = @@CompileFunction
    ResizeMemoryHook = @@ResizeMemory

    // C: m3_AllocStruct (M3Runtime); Eden: the value (allocation cannot fail observably)
    var runtime = M3Runtime()

    m3_ResetErrorInfo(runtime)

    runtime.environment = i_environment
    runtime.userdata = i_userdata

    // C: runtime->originStack = m3_Malloc ("Wasm Stack", i_stackSizeInBytes + 4*sizeof (m3slot_t));
    // Eden: one u64 word per slot, exactly numStackSlots of them (see the header)
    runtime.numStackSlots = i_stackSizeInBytes / u32(typeinfo sizeof(type<m3slot_t>))
    resize(runtime.stack, int(runtime.numStackSlots))
    runtime.originStack = 0
    // C: runtime->stack = runtime->originStack; Eden: the frame base is originStack (DESIGN 4.4)

    // C m3_NewEnvironment: create FuncTypes for all simple block return ValueTypes
    // Eden: interned into this runtime's arena, the handles in its environment copy
    var result : M3Result = m3Err_none
    for (ti in range(int(c_m3Type_none), int(c_m3Type_f64) + 1)) {
        let t : u8 = u8(ti)
        var ftype : IM3FuncType = -1
        result = AllocFuncType(runtime, ftype, 1u)
        if (result != m3Err_none) {
            break
        }

        runtime.funcTypes[ftype].numArgs = u16(0)
        runtime.funcTypes[ftype].numRets = (t == c_m3Type_none) ? u16(0) : u16(1)
        runtime.funcTypes[ftype].types[0] = t

        Environment_AddFuncType(runtime, ftype)

        d_m3Assert(int(t) < 5)
        runtime.environment.retFuncTypes[int(t)] = ftype
    }
    // C: if (result) { m3_FreeEnvironment (env); env = NULL; }
    // Eden: AllocFuncType cannot fail observably (m3_function)
    d_m3Assert(result == m3Err_none)

    return <- runtime
}


def public m3_GetUserData(i_runtime : M3Runtime) : int {
    // C: i_runtime ? i_runtime->userdata : NULL; Eden: a reference is never NULL
    return i_runtime.userdata
}


// Eden: C's `runtime->modules`, the head of the linked module list: the
// linked module with the highest handle, -1 when none is linked (see the header)
def public Runtime_FirstModule(i_runtime : M3Runtime) : IM3Module {
    var i = length(i_runtime.modules) - 1
    while (i >= 0) {
        if (i_runtime.modules[i].runtime != -1) {
            return i
        }
        i--
    }
    return -1
}


def public ForEachModule(var i_runtime : M3Runtime; i_visitor : ModuleVisitor; i_info : string) : int {
    var r : int = -1

    // C: IM3Module module = i_runtime->modules; while (module) { next = module->next; ... }
    // Eden: the linked modules of the arena, highest handle first
    var _module = length(i_runtime.modules) - 1
    while (_module >= 0) {
        let next = _module - 1
        if (i_runtime.modules[_module].runtime != -1) {
            r = invoke(i_visitor, i_runtime, _module, i_info)
            if (r != -1) {
                break
            }
        }
        _module = next
    }

    return r
}


def public _FreeModule(var i_runtime : M3Runtime; i_module : IM3Module; i_info : string) : int {
    m3_FreeModule(i_runtime, i_module)
    return -1
}


def public Runtime_Release(var i_runtime : M3Runtime) {
    ForEachModule(i_runtime, @@_FreeModule, "")
    d_m3Assert(i_runtime.numActiveCodePages == 0u)

    Environment_ReleaseCodePages(i_runtime, i_runtime.pagesOpen)
    Environment_ReleaseCodePages(i_runtime, i_runtime.pagesFull)

    // C: m3_Free (i_runtime->originStack); Eden: the stack array
    m3_Free_Impl(i_runtime.stack)
    i_runtime.originStack = -1
    // C: m3_Free (i_runtime->memory.mallocated); Eden: the linear memory array
    m3_Free_Impl(i_runtime.mem)
}


def public m3_FreeRuntime(var i_runtime : M3Runtime) {
    // C: if (i_runtime); Eden: a reference is never NULL
    // compiled out under the active configuration: m3_PrintProfilerInfo
    Runtime_Release(i_runtime)
    // C: m3_Free (i_runtime); Eden: the value is reset (see the header)
    i_runtime <- M3Runtime()
}


// C: M3Result EvaluateExpression (IM3Module i_module, void * o_expressed, u8 i_type, bytes_t * io_bytes, cbytes_t i_end)
// Eden: the runtime first; o_expressed is the u64 the value lands in; the
// temporary runtime is emulated on rt (see the header)
def public EvaluateExpression(var rt : M3Runtime; i_module : IM3Module; var o_expressed : u64&; i_type : u8; var io_bytes : bytes_t&; i_end : cbytes_t) : M3Result {
    var result : M3Result = m3Err_none

    // OPTZ: use a simplified interpreter for expressions

    // create a temporary runtime context
    // C: M3Runtime runtime; M3_INIT (runtime); Eden: the state the
    // temporary owns is saved here and reset (see the header)
    var savedCompilation <- rt.compilation
    rt.compilation <- M3Compilation()
    let savedPagesOpen = rt.pagesOpen
    let savedPagesFull = rt.pagesFull
    let savedNumCodePages = rt.numCodePages
    let savedNumActiveCodePages = rt.numActiveCodePages
    let savedError = rt.error
    rt.pagesOpen = -1
    rt.pagesFull = -1
    rt.numCodePages = 0u
    rt.numActiveCodePages = 0u

    // C: runtime.environment / numStackSlots / stack = i_module->runtime's;
    // Eden: the same runtime, so they are rt's
    let stack : m3stack_t = rt.originStack   // C: m3stack_t stack = (m3stack_t) runtime.stack

    // C: IM3Runtime savedRuntime = i_module->runtime; i_module->runtime = & runtime;
    // Eden: the module stays linked to rt, which is the temporary here

    rt.compilation.runtime = 0   // C: o->runtime = & runtime
    rt.compilation.moduleIdx = i_module
    rt.compilation.wasm = io_bytes
    rt.compilation.wasmEnd = i_end
    rt.compilation.lastOpcodeStart = rt.compilation.wasm

    rt.compilation._block.depth = -1  // so that root compilation depth = 0

    //  OPTZ: this code page could be erased after use.  maybe have 'empty' list in addition to full and open?
    rt.compilation.page = AcquireCodePage(rt)  // AcquireUnusedCodePage (...)

    if (rt.compilation.page != -1) {
        let ftype = rt.environment.retFuncTypes[int(i_type)]

        let m3code = GetPagePC(rt, rt.compilation.page)

        // Eden: the registers (C: RunCode's by-value arguments) and the
        // frame base a host function moves (op_CallRawFunction)
        let savedPC = rt.pc
        let savedSP = rt.sp
        let savedR0 = rt.r0
        let savedFP0 = rt.fp0
        let savedOriginStack = rt.originStack

        // Eden: the panic guard (see the header)
        try {
            result = CompileBlock(rt, ftype, c_waOp_block)

            if (result == m3Err_none && u32(rt.compilation.maxStackSlots) >= rt.numStackSlots) {
                result = m3Err_trapStackOverflow
            }

            if (result == m3Err_none) {
                // C: RunCode (m3code, stack, NULL, d_m3OpDefaultArgs)
                rt.pc = m3code
                rt.sp = stack
                rt.r0 = 0ul
                rt.fp0 = 0.0lf
                rt.trap = m3Err_none   // Eden: DESIGN 4.4, the caller of RunCode resets the trap
                let r = RunCode(rt)

                if (r == M3_RETURN) {   // C: if (r == 0)
                    if (SizeOfType(i_type) == u32(typeinfo sizeof(type<u32>))) {
                        // C: * (u32 *) o_expressed = * ((u32 *) stack);
                        o_expressed = (o_expressed & 0xffffffff00000000ul) | u64(stack_u32(rt, stack))
                    } else {
                        // C: * (u64 *) o_expressed = * ((u64 *) stack);
                        o_expressed = stack_u64(rt, stack)
                    }
                }
            }
        } recover {
            result = m3Err_panicEvaluateExpression
        }

        rt.pc = savedPC
        rt.sp = savedSP
        rt.r0 = savedR0
        rt.fp0 = savedFP0
        rt.originStack = savedOriginStack   // Eden: a panic inside a host function skipped op_CallRawFunction's restore

        // TODO: EraseCodePage (...) see OPTZ above
        ReleaseCodePage(rt, rt.compilation.page)
    } else {
        result = m3Err_mallocFailedCodePage
    }

    // C: runtime.originStack = NULL; Runtime_Release (& runtime);
    // Eden: the temporary has no modules and its stack is rt's, so its
    // release is the release of its pages to the pool
    Environment_ReleaseCodePages(rt, rt.pagesOpen)
    Environment_ReleaseCodePages(rt, rt.pagesFull)
    // C: i_module->runtime = savedRuntime; Eden: unchanged (see above)

    io_bytes = rt.compilation.wasm   // C: * io_bytes = o->wasm

    // Eden: the runtime's own state comes back
    rt.compilation <- savedCompilation
    rt.pagesOpen = savedPagesOpen
    rt.pagesFull = savedPagesFull
    rt.numCodePages = savedNumCodePages
    rt.numActiveCodePages = savedNumActiveCodePages
    rt.error = savedError

    return result
}


def public InitMemory(var io_runtime : M3Runtime; i_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none   //d_m3Assert (not io_runtime->memory.wasmPages);

    if (!io_runtime.modules[i_module].memoryImported) {
        let maxPages = io_runtime.modules[i_module].memoryInfo.maxPages
        let pageSize = io_runtime.modules[i_module].memoryInfo.pageSize
        io_runtime.memory.maxPages = maxPages != 0u ? maxPages : 65536u
        io_runtime.memory.pageSize = pageSize != 0u ? pageSize : u32(d_m3DefaultMemPageSize)

        result = ResizeMemory(io_runtime, io_runtime.modules[i_module].memoryInfo.initPages)
    }

    return result
}


def public ResizeMemory(var io_runtime : M3Runtime; i_numPages : u32) : M3Result {
    var result : M3Result = m3Err_none

    let numPagesToAlloc = i_numPages

    // C: M3Memory * memory = & io_runtime->memory; Eden: io_runtime.memory

    // C: #if 0 // Temporary fix for memory allocation ... #endif (inactive)

    if (numPagesToAlloc <= io_runtime.memory.maxPages) {
        var numPageBytes = u64(numPagesToAlloc) * u64(io_runtime.memory.pageSize)

        if (d_m3MaxLinearMemoryPages > 0u && numPagesToAlloc > d_m3MaxLinearMemoryPages) {
            return "linear memory limitation exceeded"   // C: _throwif
        }

        // Limit the amount of memory that gets actually allocated
        if (io_runtime.memoryLimit != 0u) {
            numPageBytes = min(numPageBytes, u64(io_runtime.memoryLimit))
        }

        // C: numBytes = numPageBytes + sizeof (M3MemoryHeader); numPreviousBytes ...;
        //    newMem = m3_Realloc ("Wasm Linear Memory", memory->mallocated, numBytes, numPreviousBytes);
        //    _throwifnull (newMem);
        // Eden: rt.mem is resized in place; a size a daslang array cannot
        // hold is the failed realloc (see the header)
        if (numPageBytes > 0x7ffffffful) {
            return m3Err_mallocFailed
        }
        resize(io_runtime.mem, int(numPageBytes))

        io_runtime.memory.numPages = numPagesToAlloc

        // C: memory->mallocated->length / runtime / maxStack; Eden: absent
        // (length(rt.mem), the runtime itself, length(rt.stack); DESIGN 4.2)
    } else {
        result = m3Err_wasmMemoryOverflow
    }

    return result
}


def public InitGlobals(var io_runtime : M3Runtime; io_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none

    if (io_runtime.modules[io_module].numGlobals != 0u) {
        // placing the globals in their structs isn't good for cache locality, but i don't really know what the global
        // access patterns typically look like yet.

        for (i in range(int(io_runtime.modules[io_module].numGlobals))) {
            let g : IM3Global = io_runtime.modules[io_module].globals[i]   // C: M3Global * g = & io_module->globals [i]

            if (io_runtime.globals[g].initExpr != -1) {   // C: if (g->initExpr)
                var start : bytes_t = io_runtime.globals[g].initExpr
                let globalEnd : cbytes_t = io_runtime.globals[g].initExpr + int(io_runtime.globals[g].initExprSize)
                // C: & g->i64Value; Eden: the value bits, through a local
                var valueBits = io_runtime.globals[g].valueBits
                result = EvaluateExpression(io_runtime, io_module, valueBits, io_runtime.globals[g]._type, start, globalEnd)
                io_runtime.globals[g].valueBits = valueBits

                if (result == m3Err_none) {
                    // io_module->globalMemory [i] = initValue;
                    pass
                } else {
                    break
                }
            } else {
                // importing global
                pass
            }
        }
    }

    return result
}


// C: M3Result InitDataSegments (M3Memory * io_memory, IM3Module io_module)
// Eden: io_memory is rt.memory / rt.mem (see the header)
def public InitDataSegments(var io_runtime : M3Runtime; io_module : IM3Module) : M3Result {
    // C: _throwif ("unallocated linear memory", !(io_memory->mallocated));
    if (io_runtime.memory.pageSize == 0u) {
        return "unallocated linear memory"
    }

    for (i in range(int(io_runtime.modules[io_module].numDataSegments))) {
        // C: M3DataSegment * segment = & io_module->dataSegments [i]; Eden: its fields are read by index

        let initExpr = io_runtime.modules[io_module].dataSegments[i].initExpr
        let initExprSize = io_runtime.modules[io_module].dataSegments[i].initExprSize
        var offsetBits = 0ul   // C: i32 segmentOffset; Eden: its bits
        var start : bytes_t = initExpr
        let result = EvaluateExpression(io_runtime, io_module, offsetBits, c_m3Type_i32, start, initExpr + int(initExprSize))
        if (result != m3Err_none) {
            return result
        }
        let segmentOffset : i32 = i32(u32(offsetBits))

        let size = io_runtime.modules[io_module].dataSegments[i].size
        if (segmentOffset >= 0 && u64(segmentOffset) + u64(size) <= u64(length(io_runtime.mem))) {
            // C: u8 * dest = m3MemData (io_memory->mallocated) + segmentOffset;
            //    memcpy (dest, segment->data, segment->size);
            // Eden: byte by byte from the module's copy of the binary into rt.mem
            let data = io_runtime.modules[io_module].dataSegments[i].data
            for (b in range(int(size))) {
                io_runtime.mem[int(segmentOffset) + b] = io_runtime.modules[io_module].wasm[data + b]
            }
        } else {
            return "data segment out of bounds"   // C: _throw
        }
    }

    return m3Err_none
}


def public InitElements(var io_runtime : M3Runtime; io_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none

    var bytes : bytes_t = io_runtime.modules[io_module].elementSection
    let end : cbytes_t = io_runtime.modules[io_module].elementSectionEnd

    for (_i in range(int(io_runtime.modules[io_module].numElementSegments))) {
        var index : u32 = 0u
        result = ReadLEB_u32(io_runtime.modules[io_module].wasm, index, bytes, end)
        if (result != m3Err_none) {
            return result
        }

        if (index == 0u) {
            var offsetBits = 0ul   // C: i32 offset; Eden: its bits
            result = EvaluateExpression(io_runtime, io_module, offsetBits, c_m3Type_i32, bytes, end)
            if (result != m3Err_none) {
                return result
            }
            let offset : i32 = i32(u32(offsetBits))
            if (offset < 0) {
                return "table underflow"   // C: _throwif
            }

            var numElements : u32 = 0u
            result = ReadLEB_u32(io_runtime.modules[io_module].wasm, numElements, bytes, end)
            if (result != m3Err_none) {
                return result
            }

            let endElement = u64(numElements) + u64(offset)
            if (endElement > u64(d_m3MaxSaneTableSize)) {
                return "table overflow"   // C: _throwif
            }

            // is there any requirement that elements must be in increasing sequence?
            // make sure the table isn't shrunk.
            if (endElement > u64(io_runtime.modules[io_module].table0Size)) {
                // C: io_module->table0 = m3_ReallocArray (IM3Function, io_module->table0, endElement, io_module->table0Size);
                // Eden: the handle array grows, the new entries NULL (-1)
                let oldSize = length(io_runtime.modules[io_module].table0)
                resize(io_runtime.modules[io_module].table0, int(endElement))
                for (e in range(oldSize, int(endElement))) {
                    io_runtime.modules[io_module].table0[e] = -1
                }
                io_runtime.modules[io_module].table0Size = u32(endElement)
            }
            // C: _throwifnull (io_module->table0); Eden: allocation cannot fail observably (m3_core)

            for (e in range(int(numElements))) {
                var functionIndex : u32 = 0u
                result = ReadLEB_u32(io_runtime.modules[io_module].wasm, functionIndex, bytes, end)
                if (result != m3Err_none) {
                    return result
                }
                if (functionIndex >= io_runtime.modules[io_module].numFunctions) {
                    return "function index out of range"   // C: _throwif
                }
                let _function : IM3Function = io_runtime.modules[io_module].functions[int(functionIndex)]   // C: & io_module->functions [functionIndex]
                d_m3Assert(_function != -1)
                io_runtime.modules[io_module].table0[e + int(offset)] = _function
            }
        } else {
            return "element table index must be zero for MVP"   // C: _throw
        }
    }

    return result
}


// Eden: CompileFunction inside the panic guard (see the header); an
// interrupted compilation's code page is released
def private GuardedCompileFunction(var rt : M3Runtime; i_function : IM3Function) : M3Result {
    let activePages = rt.numActiveCodePages
    var result : M3Result = m3Err_panicCompileFunction
    try {
        result = CompileFunction(rt, i_function)
    } recover {
        result = m3Err_panicCompileFunction
        if (rt.numActiveCodePages > activePages) {
            ReleaseCompilationCodePage(rt)
        }
    }
    return result
}


// C spells this inline at every call site (m3_RunStart, m3_CallVL, m3_Call,
// m3_CallArgv): RunCode (i_function->compiled, (m3stack_t) runtime->stack,
// runtime->memory.mallocated, d_m3OpDefaultArgs). d_m3OpDefaultArgs is
// r0 = 0, fp0 = 0.0 under d_m3HasFloat; the profiling/tracing variant with
// d_m3BaseCstr is compiled out.
// Eden: the registers and rt.originStack are saved and restored, rt.trap is
// reset, the run is guarded and the protocol mapped to an M3Result (see the
// header)
def public RunFunctionCode(var rt : M3Runtime; i_function : IM3Function) : M3Result {
    let savedPC = rt.pc
    let savedSP = rt.sp
    let savedR0 = rt.r0
    let savedFP0 = rt.fp0
    let savedOriginStack = rt.originStack
    let activePages = rt.numActiveCodePages

    rt.pc = rt.functions[i_function].compiled
    rt.sp = rt.originStack   // C: (m3stack_t) runtime->stack
    rt.r0 = 0ul
    rt.fp0 = 0.0lf
    rt.trap = m3Err_none

    var result : M3Result = m3Err_panicRunCode
    try {
        let r = RunCode(rt)
        if (r == M3_RETURN) {
            result = m3Err_none
        } elif (r == M3_TRAP) {
            result = rt.trap
        } else {
            // C: the escaped value itself cast to M3Result; no operation lets a loop pc reach this level
            result = "RunCode returned the loop pc {r}"
        }
    } recover {
        result = m3Err_panicRunCode
        if (rt.numActiveCodePages > activePages) {
            ReleaseCompilationCodePage(rt)   // Eden: a lazy compilation (op_Compile) was interrupted
        }
    }

    rt.pc = savedPC
    rt.sp = savedSP
    rt.r0 = savedR0
    rt.fp0 = savedFP0
    rt.originStack = savedOriginStack   // Eden: a panic inside a host function skipped op_CallRawFunction's restore
    return result
}


def public m3_CompileModule(var io_runtime : M3Runtime; io_module : IM3Module) : M3Result {
    for (i in range(int(io_runtime.modules[io_module].numFunctions))) {
        let f : IM3Function = io_runtime.modules[io_module].functions[i]   // C: & io_module->functions [i]
        if (io_runtime.functions[f].wasm != -1 && io_runtime.functions[f].compiled == -1) {
            let result = GuardedCompileFunction(io_runtime, f)   // Eden: guarded (see the header)
            if (result != m3Err_none) {
                return result
            }
        }
    }

    return m3Err_none
}


def public m3_RunStart(var io_runtime : M3Runtime; io_module : IM3Module) : M3Result {
    // C: #ifdef FUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION: not defined

    var result : M3Result = m3Err_none
    var startFunctionTmp : i32 = -1

    if (io_module != -1 && io_runtime.modules[io_module].startFunction >= 0) {
        let _function : IM3Function = io_runtime.modules[io_module].functions[io_runtime.modules[io_module].startFunction]

        if (io_runtime.functions[_function].compiled == -1) {
            result = GuardedCompileFunction(io_runtime, _function)   // Eden: guarded (see the header)
            if (result != m3Err_none) {
                return result
            }
        }

        let ftype = io_runtime.functions[_function].funcTypeIdx
        if (io_runtime.funcTypes[ftype].numArgs != u16(0) || io_runtime.funcTypes[ftype].numRets != u16(0)) {
            return m3Err_argumentCountMismatch   // C: _throw
        }

        // C: IM3Module module = function->module; IM3Runtime runtime = module->runtime; Eden: io_runtime

        startFunctionTmp = io_runtime.modules[io_module].startFunction
        io_runtime.modules[io_module].startFunction = -1

        result = RunFunctionCode(io_runtime, _function)

        if (result != m3Err_none) {
            io_runtime.modules[io_module].startFunction = startFunctionTmp
            // compiled out under the active configuration: EXCEPTION_PRINT (d_m3EnableExceptionBreakpoint == false)
            return result
        }
    }

    return result
}


// TODO: deal with main + side-modules loading efforcement
def public m3_LoadModule(var io_runtime : M3Runtime; io_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none

    if (M3_UNLIKELY(io_runtime.modules[io_module].runtime != -1)) {
        return m3Err_moduleAlreadyLinked
    }

    io_runtime.modules[io_module].runtime = 0   // C: io_module->runtime = io_runtime
    // C: M3Memory * memory = & io_runtime->memory; Eden: InitDataSegments reads rt.memory

    // Eden: the panic guard (see the header)
    try {
        result = InitMemory(io_runtime, io_module)
        if (result == m3Err_none) {
            result = InitGlobals(io_runtime, io_module)
        }
        if (result == m3Err_none) {
            result = InitDataSegments(io_runtime, io_module)
        }
        if (result == m3Err_none) {
            result = InitElements(io_runtime, io_module)
        }
    } recover {
        result = m3Err_panicLoadModule
    }

    if (result != m3Err_none) {
        // C: _catch: io_module->runtime = NULL;
        io_runtime.modules[io_module].runtime = -1
        return result
    }

    // Start func might use imported functions, which are not liked here yet,
    // so it will be called before a function call is attempted (in m3_FindFunction)

    // compiled out under the active configuration: DEBUG Module_GenerateNames

    // C: io_module->next = io_runtime->modules; io_runtime->modules = io_module;
    // Eden: linked by `runtime` above; the arena is the list (see the header)
    return result // ok
}


def public m3_FindGlobal(i_runtime : M3Runtime; io_module : IM3Module; i_globalName : string) : IM3Global {
    // Search exports
    for (i in range(int(i_runtime.modules[io_module].numGlobals))) {
        let g : IM3Global = i_runtime.modules[io_module].globals[i]
        // C: g->name and strcmp (g->name, i_globalName) == 0; Eden: `g->name` non-NULL is the isExported flag (see the header)
        if (i_runtime.globals[g].isExported && i_runtime.globals[g].name == i_globalName) {
            return g
        }
    }

    // Search imports
    for (i in range(int(i_runtime.modules[io_module].numGlobals))) {
        let g : IM3Global = i_runtime.modules[io_module].globals[i]

        // C: g->import.moduleUtf8 and g->import.fieldUtf8; Eden: the import flag (see the header)
        if (i_runtime.globals[g].imported) {
            if (i_runtime.globals[g].import.fieldUtf8 == i_globalName) {
                return g
            }
        }
    }
    return -1
}


def public m3_GetGlobal(i_runtime : M3Runtime; i_global : IM3Global; var o_value : M3TaggedValue&) : M3Result {
    if (i_global == -1) {
        return m3Err_globalLookupFailed
    }

    let _type = i_runtime.globals[i_global]._type
    if (_type == c_m3Type_i32) {
        tagged_set_i32(o_value, M3Global_GetI32Value(i_runtime.globals[i_global]))
    } elif (_type == c_m3Type_i64) {
        tagged_set_i64(o_value, M3Global_GetI64Value(i_runtime.globals[i_global]))
    } elif (d_m3HasFloat && _type == c_m3Type_f32) {
        tagged_set_f32(o_value, M3Global_GetF32Value(i_runtime.globals[i_global]))
    } elif (d_m3HasFloat && _type == c_m3Type_f64) {
        tagged_set_f64(o_value, M3Global_GetF64Value(i_runtime.globals[i_global]))
    } else {
        return m3Err_invalidTypeId
    }

    o_value._type = m3_value_type(_type)
    return m3Err_none
}


def public m3_SetGlobal(var i_runtime : M3Runtime; i_global : IM3Global; i_value : M3TaggedValue) : M3Result {
    if (i_global == -1) {
        return m3Err_globalLookupFailed
    }
    if (!i_runtime.globals[i_global].isMutable) {
        return m3Err_globalNotMutable
    }
    if (i_runtime.globals[i_global]._type != u8(i_value._type)) {
        return m3Err_globalTypeMismatch
    }

    if (i_value._type == M3ValueType.c_m3Type_i32) {
        M3Global_SetI32Value(i_runtime.globals[i_global], tagged_get_i32(i_value))
    } elif (i_value._type == M3ValueType.c_m3Type_i64) {
        M3Global_SetI64Value(i_runtime.globals[i_global], tagged_get_i64(i_value))
    } elif (d_m3HasFloat && i_value._type == M3ValueType.c_m3Type_f32) {
        M3Global_SetF32Value(i_runtime.globals[i_global], tagged_get_f32(i_value))
    } elif (d_m3HasFloat && i_value._type == M3ValueType.c_m3Type_f64) {
        M3Global_SetF64Value(i_runtime.globals[i_global], tagged_get_f64(i_value))
    } else {
        return m3Err_invalidTypeId
    }

    return m3Err_none
}


def public m3_GetGlobalType(i_runtime : M3Runtime; i_global : IM3Global) : M3ValueType {
    return (i_global != -1) ? m3_value_type(i_runtime.globals[i_global]._type) : M3ValueType.c_m3Type_none
}


// Eden: C's `f->import.moduleUtf8 or f->import.fieldUtf8` (see the header):
// the parser adds every import, and only imports, before the module's other
// functions
def private FunctionIsImported(i_runtime : M3Runtime; i_module : IM3Module; i_index : int) : bool {
    return u32(i_index) < i_runtime.modules[i_module].numFuncImports
}


// Eden: C's `f->export_name` is not NULL: the isExported flag the export
// section sets with export_name (see the header)
def private FunctionIsExported(i_runtime : M3Runtime; i_function : IM3Function) : bool {
    return i_runtime.functions[i_function].isExported
}


def public v_FindFunction(var i_runtime : M3Runtime; i_module : IM3Module; i_name : string) : int {
    // Prefer exported functions
    for (i in range(int(i_runtime.modules[i_module].numFunctions))) {
        let f : IM3Function = i_runtime.modules[i_module].functions[i]
        // C: f->export_name and strcmp (f->export_name, i_name) == 0
        if (FunctionIsExported(i_runtime, f) && i_runtime.functions[f].export_name == i_name) {
            return f
        }
    }

    // Search internal functions
    for (i in range(int(i_runtime.modules[i_module].numFunctions))) {
        let f : IM3Function = i_runtime.modules[i_module].functions[i]

        let isImported = FunctionIsImported(i_runtime, i_module, i)   // C: f->import.moduleUtf8 or f->import.fieldUtf8

        if (isImported) {
            continue
        }

        for (j in range(int(i_runtime.functions[f].numNames))) {
            // C: f->names [j] and strcmp (f->names [j], i_name) == 0; Eden: names[j] (j < numNames) is never NULL
            if (i_runtime.functions[f].names[j] == i_name) {
                return f
            }
        }
    }

    return -1
}


// C: M3Result m3_FindFunction (IM3Function * o_function, IM3Runtime i_runtime, const char * const i_functionName)
// Eden: the runtime first
def public m3_FindFunction(var i_runtime : M3Runtime; var o_function : IM3Function&; i_functionName : string) : M3Result {
    var result : M3Result = m3Err_none   // C: d_m3Assert (o_function and i_runtime and i_functionName); Eden: references

    var _function : IM3Function = -1

    let firstModule = Runtime_FirstModule(i_runtime)
    if (firstModule == -1) {   // C: if (not i_runtime->modules)
        result = "no modules loaded"   // C: _throw
    } else {
        _function = ForEachModule(i_runtime, @@v_FindFunction, i_functionName)

        if (_function != -1) {
            if (i_runtime.functions[_function].compiled == -1) {
                result = GuardedCompileFunction(i_runtime, _function)   // Eden: guarded (see the header)
            }
        } else {
            result = m3Error(m3Err_functionLookupFailed, i_runtime, firstModule, -1, "", 0u, "'{i_functionName}'")   // C: ErrorModule
        }
    }

    // C: _catch:
    if (result != m3Err_none) {
        _function = -1
    }

    o_function = _function

    return result
}


// C: M3Result m3_GetTableFunction (IM3Function * o_function, IM3Module i_module, uint32_t i_index)
// Eden: the runtime first
def public m3_GetTableFunction(var i_runtime : M3Runtime; var o_function : IM3Function&; i_module : IM3Module; i_index : u32) : M3Result {
    if (i_index >= i_runtime.modules[i_module].table0Size) {
        return "function index out of range"   // C: _throw
    }

    let _function : IM3Function = i_runtime.modules[i_module].table0[int(i_index)]

    if (_function != -1) {
        if (i_runtime.functions[_function].compiled == -1) {
            let result = GuardedCompileFunction(i_runtime, _function)   // Eden: guarded (see the header)
            if (result != m3Err_none) {
                return result
            }
        }
    }

    o_function = _function
    return m3Err_none
}


def private checkStartFunction(var i_runtime : M3Runtime; i_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none
    d_m3Assert(i_module != -1)

    // Check if start function needs to be called
    if (i_runtime.modules[i_module].startFunction >= 0) {
        result = m3_RunStart(i_runtime, i_module)
    }

    return result
}


def public m3_GetArgCount(i_runtime : M3Runtime; i_function : IM3Function) : u32 {
    if (i_function != -1) {
        let ft = i_runtime.functions[i_function].funcTypeIdx
        if (ft != -1) {
            return u32(i_runtime.funcTypes[ft].numArgs)
        }
    }
    return 0u
}


def public m3_GetRetCount(i_runtime : M3Runtime; i_function : IM3Function) : u32 {
    if (i_function != -1) {
        let ft = i_runtime.functions[i_function].funcTypeIdx
        if (ft != -1) {
            return u32(i_runtime.funcTypes[ft].numRets)
        }
    }
    return 0u
}


def public m3_GetArgType(i_runtime : M3Runtime; i_function : IM3Function; index : u32) : M3ValueType {
    if (i_function != -1) {
        let ft = i_runtime.functions[i_function].funcTypeIdx
        if (ft != -1 && index < u32(i_runtime.funcTypes[ft].numArgs)) {
            return m3_value_type(GetFuncTypeParamType(i_runtime, ft, u16(index)))   // C: d_FuncArgType (ft, index)
        }
    }
    return M3ValueType.c_m3Type_none
}


def public m3_GetRetType(i_runtime : M3Runtime; i_function : IM3Function; index : u32) : M3ValueType {
    if (i_function != -1) {
        let ft = i_runtime.functions[i_function].funcTypeIdx
        if (ft != -1 && index < u32(i_runtime.funcTypes[ft].numRets)) {
            return m3_value_type(GetFuncTypeResultType(i_runtime, ft, u16(index)))   // C: d_FuncRetType (ft, index)
        }
    }
    return M3ValueType.c_m3Type_none
}


// C: u8 * GetStackPointerForArgs (IM3Function i_function)
// Eden: the index into rt.stack of the first argument cell (see the header)
def public GetStackPointerForArgs(i_runtime : M3Runtime; i_function : IM3Function) : int {
    var stack = i_runtime.originStack   // C: (u64 *) i_function->module->runtime->stack
    let ftype = i_runtime.functions[i_function].funcTypeIdx

    stack += int(i_runtime.funcTypes[ftype].numRets) * c_ioSlotCount   // C: stack += ftype->numRets (u64 cells)

    return stack
}


// C: M3Result m3_CallV (IM3Function i_function, ...)
// Eden: the typed argument array (see the header)
def public m3_CallV(var i_runtime : M3Runtime; i_function : IM3Function; i_args : array<M3TaggedValue>) : M3Result {
    return m3_CallVL(i_runtime, i_function, i_args)
}


def private ReportNativeStackUsage() {
    if (d_m3LogNativeStack) {
        let stackUsed = m3StackGetMax()
        print("Native stack used: {stackUsed}\n")   // C: fprintf (stderr, ...)
    }
}


// C: M3Result m3_CallVL (IM3Function i_function, va_list i_args)
// Typed Gen2 replacement for C varargs. f32 values are represented in M3TaggedValue
// directly instead of relying on C default argument promotion to f64.
// Deviation: C m3_CallVL cannot count a va_list, so it has no argument-count
// check; the typed array makes the m3_Call check (m3Err_argumentCountMismatch)
// available here as well.
def public m3_CallVL(var i_runtime : M3Runtime; i_function : IM3Function; i_args : array<M3TaggedValue>) : M3Result {
    // C: IM3Runtime runtime = i_function->module->runtime; Eden: i_runtime
    let ftype = i_runtime.functions[i_function].funcTypeIdx
    var result : M3Result = m3Err_none

    if (i_runtime.functions[i_function].compiled == -1) {
        return m3Err_missingCompiledCode
    }
    if (length(i_args) != int(i_runtime.funcTypes[ftype].numArgs)) {
        return m3Err_argumentCountMismatch
    }

    // compiled out under the active configuration: d_m3RecordBacktraces == false (ClearBacktrace)

    m3StackCheckInit()

    result = checkStartFunction(i_runtime, i_runtime.functions[i_function].moduleIdx)
    if (result != m3Err_none) {
        return result
    }

    var s = GetStackPointerForArgs(i_runtime, i_function)

    for (i in range(int(i_runtime.funcTypes[ftype].numArgs))) {
        let _type = GetFuncTypeParamType(i_runtime, ftype, u16(i))   // C: d_FuncArgType (ftype, i)
        if (_type == c_m3Type_i32) {
            set_stack_i32(i_runtime, s, tagged_get_i32(i_args[i]))
        } elif (_type == c_m3Type_i64) {
            set_stack_i64(i_runtime, s, tagged_get_i64(i_args[i]))
        } elif (d_m3HasFloat && _type == c_m3Type_f32) {
            set_stack_f32(i_runtime, s, tagged_get_f32(i_args[i]))   // C: f32 is passed as f64; Eden: the tagged f32
        } elif (d_m3HasFloat && _type == c_m3Type_f64) {
            set_stack_f64(i_runtime, s, tagged_get_f64(i_args[i]))
        } else {
            return "unknown argument type"
        }
        s += c_ioSlotCount   // C: s += 8
    }

    result = RunFunctionCode(i_runtime, i_function)
    ReportNativeStackUsage()

    i_runtime.lastCalled = (result != m3Err_none) ? -1 : i_function

    return result
}


// C: M3Result m3_Call (IM3Function i_function, uint32_t i_argc, const void * i_argptrs[])
// Eden: i_argc is length(i_args) and each argument is its value bits (see the header)
def public m3_Call(var i_runtime : M3Runtime; i_function : IM3Function; i_args : array<u64>) : M3Result {
    // C: IM3Runtime runtime = i_function->module->runtime; Eden: i_runtime
    let ftype = i_runtime.functions[i_function].funcTypeIdx
    var result : M3Result = m3Err_none

    if (u32(length(i_args)) != u32(i_runtime.funcTypes[ftype].numArgs)) {   // C: i_argc != ftype->numArgs
        return m3Err_argumentCountMismatch
    }
    if (i_runtime.functions[i_function].compiled == -1) {
        return m3Err_missingCompiledCode
    }

    // compiled out under the active configuration: d_m3RecordBacktraces == false (ClearBacktrace)

    m3StackCheckInit()

    result = checkStartFunction(i_runtime, i_runtime.functions[i_function].moduleIdx)
    if (result != m3Err_none) {
        return result
    }

    var s = GetStackPointerForArgs(i_runtime, i_function)

    for (i in range(int(i_runtime.funcTypes[ftype].numArgs))) {
        let _type = GetFuncTypeParamType(i_runtime, ftype, u16(i))   // C: d_FuncArgType (ftype, i)
        if (_type == c_m3Type_i32) {
            set_stack_i32(i_runtime, s, m3_bits_to_i32(i_args[i]))   // C: *(i32*)(s) = *(i32*)i_argptrs[i]
        } elif (_type == c_m3Type_i64) {
            set_stack_i64(i_runtime, s, m3_bits_to_i64(i_args[i]))
        } elif (d_m3HasFloat && _type == c_m3Type_f32) {
            set_stack_f32(i_runtime, s, m3_bits_to_f32(i_args[i]))
        } elif (d_m3HasFloat && _type == c_m3Type_f64) {
            set_stack_f64(i_runtime, s, m3_bits_to_f64(i_args[i]))
        } else {
            return "unknown argument type"
        }
        s += c_ioSlotCount   // C: s += 8
    }

    result = RunFunctionCode(i_runtime, i_function)

    ReportNativeStackUsage()

    i_runtime.lastCalled = (result != m3Err_none) ? -1 : i_function

    return result
}


// C: M3Result m3_CallArgv (IM3Function i_function, uint32_t i_argc, const char * i_argv[])
// Eden: i_argc is length(i_argv) (see the header)
def public m3_CallArgv(var i_runtime : M3Runtime; i_function : IM3Function; i_argv : array<string>) : M3Result {
    let ftype = i_runtime.functions[i_function].funcTypeIdx
    // C: IM3Runtime runtime = i_function->module->runtime; Eden: i_runtime
    var result : M3Result = m3Err_none

    if (u32(length(i_argv)) != u32(i_runtime.funcTypes[ftype].numArgs)) {   // C: i_argc != ftype->numArgs
        return m3Err_argumentCountMismatch
    }
    if (i_runtime.functions[i_function].compiled == -1) {
        return m3Err_missingCompiledCode
    }

    // compiled out under the active configuration: d_m3RecordBacktraces == false (ClearBacktrace)

    m3StackCheckInit()

    result = checkStartFunction(i_runtime, i_runtime.functions[i_function].moduleIdx)
    if (result != m3Err_none) {
        return result
    }

    var s = GetStackPointerForArgs(i_runtime, i_function)

    for (i in range(int(i_runtime.funcTypes[ftype].numArgs))) {
        let _type = GetFuncTypeParamType(i_runtime, ftype, u16(i))   // C: d_FuncArgType (ftype, i)
        if (_type == c_m3Type_i32) {
            set_stack_i32(i_runtime, s, i32(u32(m3_strtoull(i_argv[i]))))   // C: strtoul (i_argv[i], NULL, 10)
        } elif (_type == c_m3Type_i64) {
            set_stack_i64(i_runtime, s, i64(m3_strtoull(i_argv[i])))   // C: strtoull (i_argv[i], NULL, 10)
        } elif (d_m3HasFloat && _type == c_m3Type_f32) {
            set_stack_f32(i_runtime, s, f32(m3_strtod(i_argv[i])))   // strtof would be less portable
        } elif (d_m3HasFloat && _type == c_m3Type_f64) {
            set_stack_f64(i_runtime, s, m3_strtod(i_argv[i]))
        } else {
            return "unknown argument type"
        }
        s += c_ioSlotCount   // C: s += 8
    }

    result = RunFunctionCode(i_runtime, i_function)

    ReportNativeStackUsage()

    i_runtime.lastCalled = (result != m3Err_none) ? -1 : i_function

    return result
}


//u8 * AlignStackPointerTo64Bits (const u8 * i_stack)
//{
//    uintptr_t ptr = (uintptr_t) i_stack;
//    return (u8 *) ((ptr + 7) & ~7);
//}


// C: M3Result m3_GetResults (IM3Function i_function, uint32_t i_retc, const void * o_retptrs[])
// Eden: o_retBits receives the value bits (see the header)
def public m3_GetResults(i_runtime : M3Runtime; i_function : IM3Function; i_retc : u32; var o_retBits : array<u64>) : M3Result {
    let ftype = i_runtime.functions[i_function].funcTypeIdx
    // C: IM3Runtime runtime = i_function->module->runtime; Eden: i_runtime

    if (i_retc != u32(i_runtime.funcTypes[ftype].numRets)) {
        return m3Err_argumentCountMismatch
    }
    if (i_function != i_runtime.lastCalled) {
        return "function not called"
    }

    m3_Malloc_Impl(o_retBits, int(i_runtime.funcTypes[ftype].numRets))   // Eden: the caller's o_retptrs[]

    var s = i_runtime.originStack   // C: u8* s = (u8*) runtime->stack

    for (i in range(int(i_runtime.funcTypes[ftype].numRets))) {
        let _type = GetFuncTypeResultType(i_runtime, ftype, u16(i))   // C: d_FuncRetType (ftype, i)
        if (_type == c_m3Type_i32) {
            o_retBits[i] = u64(stack_u32(i_runtime, s))   // C: *(i32*)o_retptrs[i] = *(i32*)(s)
        } elif (_type == c_m3Type_i64) {
            o_retBits[i] = stack_u64(i_runtime, s)
        } elif (d_m3HasFloat && _type == c_m3Type_f32) {
            o_retBits[i] = u64(stack_u32(i_runtime, s))
        } elif (d_m3HasFloat && _type == c_m3Type_f64) {
            o_retBits[i] = stack_u64(i_runtime, s)
        } else {
            return "unknown return type"
        }
        s += c_ioSlotCount   // C: s += 8
    }
    return m3Err_none
}


// C: M3Result m3_GetResultsV (IM3Function i_function, ...)
// Eden: the typed result array (see the header)
def public m3_GetResultsV(i_runtime : M3Runtime; i_function : IM3Function; var o_rets : array<M3TaggedValue>) : M3Result {
    return m3_GetResultsVL(i_runtime, i_function, o_rets)
}


// C: M3Result m3_GetResultsVL (IM3Function i_function, va_list o_rets)
def public m3_GetResultsVL(i_runtime : M3Runtime; i_function : IM3Function; var o_rets : array<M3TaggedValue>) : M3Result {
    // C: IM3Runtime runtime = i_function->module->runtime; Eden: i_runtime
    let ftype = i_runtime.functions[i_function].funcTypeIdx

    if (i_function != i_runtime.lastCalled) {
        return "function not called"
    }

    m3_Malloc_Impl(o_rets, int(i_runtime.funcTypes[ftype].numRets))   // Eden: the caller's va_arg pointers

    var s = i_runtime.originStack   // C: u8* s = (u8*) runtime->stack
    for (i in range(int(i_runtime.funcTypes[ftype].numRets))) {
        let _type = GetFuncTypeResultType(i_runtime, ftype, u16(i))   // C: d_FuncRetType (ftype, i)
        o_rets[i]._type = m3_value_type(_type)
        if (_type == c_m3Type_i32) {
            tagged_set_i32(o_rets[i], stack_i32(i_runtime, s))   // C: *va_arg(o_rets, i32*) = *(i32*)(s)
        } elif (_type == c_m3Type_i64) {
            tagged_set_i64(o_rets[i], stack_i64(i_runtime, s))
        } elif (d_m3HasFloat && _type == c_m3Type_f32) {
            tagged_set_f32(o_rets[i], stack_f32(i_runtime, s))
        } elif (d_m3HasFloat && _type == c_m3Type_f64) {
            tagged_set_f64(o_rets[i], stack_f64(i_runtime, s))
        } else {
            return "unknown argument type"
        }
        s += c_ioSlotCount   // C: s += 8
    }
    return m3Err_none
}


// C: ReleaseCodePageNoTrack, AcquireCodePageWithCapacity, AcquireCodePage,
// ReleaseCodePage: in m3_code (see the header).


// C: m3Error (d_m3VerboseErrorMessages): in m3_types (see the header).


def public m3_GetErrorInfo(var i_runtime : M3Runtime; var o_info : M3ErrorInfo&) {
    // C: if (i_runtime); Eden: a reference is never NULL
    o_info = i_runtime.error
    m3_ResetErrorInfo(i_runtime)
}


def public m3_ResetErrorInfo(var i_runtime : M3Runtime) {
    // C: if (i_runtime); Eden: a reference is never NULL
    i_runtime.error = M3ErrorInfo()   // C: M3_INIT (i_runtime->error)
    i_runtime.error.message = ""
}


// C: uint8_t * m3_GetMemory (IM3Runtime i_runtime, uint32_t * o_memorySizeInBytes, uint32_t i_memoryIndex)
// Eden: returns the index of the memory's first byte in rt.mem, -1 = NULL (see the header)
def public m3_GetMemory(i_runtime : M3Runtime; var o_memorySizeInBytes : u32&; i_memoryIndex : u32) : int {
    var memory : int = -1
    d_m3Assert(i_memoryIndex == 0u)

    // C: if (i_runtime); Eden: a reference is never NULL
    let size = u32(length(i_runtime.mem))   // C: (u32) i_runtime->memory.mallocated->length

    // C: if (o_memorySizeInBytes); Eden: a reference is never NULL
    o_memorySizeInBytes = size

    if (size != 0u) {
        memory = 0   // C: m3MemData (i_runtime->memory.mallocated)
    }

    return memory
}


def public m3_GetMemorySize(i_runtime : M3Runtime) : u32 {
    return u32(length(i_runtime.mem))   // C: i_runtime->memory.mallocated->length
}


// C: M3BacktraceInfo * m3_GetBacktrace (IM3Runtime i_runtime)
// Eden: an empty info stands for C's NULL (see the header)
def public m3_GetBacktrace(i_runtime : M3Runtime) : M3BacktraceInfo {
    // compiled out under the active configuration: d_m3RecordBacktraces == false
    return <- M3BacktraceInfo()
}
