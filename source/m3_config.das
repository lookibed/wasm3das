options gen2
options indenting = 4
options no_global_variables = false

module m3_config shared public

require ./wasm3_defs.das public


/*
    m3_config_platforms.h + m3_config.h -> m3_config.das

    Pure gen2 Daslang compile-time configuration layer for the Wasm3 port.

    C uses #ifndef/#define so applications can replace defaults before the
    headers are parsed. This port intentionally does not reproduce that
    textual preprocessor mechanism. Every public setting below is an immutable
    module `let`: it is selected from the Daslang target and cannot be changed
    as an ordinary mutable runtime global.

    Architecture, compiler and byte order are owned by wasm3_defs.das and are
    imported here rather than re-declared.
*/


// ============================================================================
// m3_config_platforms.h: internal helpers
// ============================================================================


/*
    C token aliases `not`, `and`, `or` are preprocessing compatibility only.
    Daslang has native !, && and || operators, so no declarations are needed.
*/


// ============================================================================
// m3_config_platforms.h: detect / define features
// ============================================================================


/*
    M3_SIZEOF_PTR is a semantic platform value and is retained. The C header
    derives it from UINTPTR_MAX / __SIZEOF_POINTER__; Daslang derives it from
    the actual target pointer representation.
*/
let public M3_SIZEOF_PTR : uint = uint(typeinfo sizeof(default<void?>))


/*
    M3_SIZEOF_LONG is requested by the Daslang port's configuration contract,
    although neither supplied C header defines that symbol. Daslang's `int64`
    is the fixed-width scalar corresponding to the port's `i64`/`...l` values,
    so this compatibility value describes that scalar, not host C ABI `long`.
*/
let public M3_SIZEOF_LONG : uint = uint(typeinfo sizeof(default<int64>))


/*
    Endianness is intentionally NOT duplicated here. M3_LITTLE_ENDIAN and
    M3_BIG_ENDIAN are imported from wasm3_defs.das, which probes the target's
    actual representation. The C M3_BSWAP_* macro family is likewise replaced
    by wasm3_defs.m3_bswap16/32/64 plus explicit endian checks at call sites.
*/


/*
    C compiler attributes M3_WEAK, M3_NO_UBSAN, M3_NOINLINE and M3_MUSTTAIL
    control native C code generation. They are not runtime configuration data
    and have no portable pure-Daslang value, so they are not represented as
    fake booleans or strings.

    Tail-call availability is the one branch with semantic relevance. The C
    default disables it under Emscripten and enables it elsewhere. Daslang's
    wasm target is identified by M3_ARCH from wasm3_defs; native targets keep
    the C default.
*/
let public M3_HAS_TAIL_CALL = M3_ARCH != "wasm32"


/*
    M3_MIN, M3_MAX, M3_INIT and M3_COUNT_OF are C helper macros rather than
    configuration. Daslang already has typed min/max/default/length facilities,
    so reproducing textual macros here would add a second, misleading API.
*/


/*
    AVR short typedef overrides are not applicable: the Wasm3 Daslang port owns
    its fixed-width scalar aliases in m3_core.das and does not use a C ABI.
*/


// ============================================================================
// m3_config_platforms.h: apply settings
// ============================================================================


/*
    vectorcall branches:
      - MSVC/x86_64/MinGW: no special convention in the C header;
      - Windows __vectorcall, ESP IRAM attributes and FOMU section placement:
        native C ABI/storage directives with no pure-Daslang equivalent.

    The current Daslang target uses its own compiler calling convention. No
    mutable runtime switch is introduced.
*/


// ============================================================================
// m3_config_platforms.h: device-specific defaults
// ============================================================================


/*
    ESP8266, ESP32, ARDUINO_AMEBA and TEENSYDUINO lower the C stack-height
    default to 256. ARDUINO_AMEBA / BLUE_PILL / FOMU / ARC32 also select fixed
    heap sizes.

    Those branches are selected by C build-system macros, not by CPU
    architecture. Pure Daslang exposes the target architecture through M3_ARCH
    but does not expose those Arduino/SDK preprocessor identities. Therefore
    these device branches are currently inactive and the generic defaults below
    apply. If a future Daslang platform module exposes a typed device target,
    these values can be selected there without environment variables.
*/


// ============================================================================
// m3_config_platforms.h: platform-specific defaults
// ============================================================================


/*
    ARDUINO / PARTICLE / PLATFORMIO / MBED / ESP / BLUE_PILL / WM_W600 / FOMU
    reduce code-page alignment, constant-table size, stack height and disable
    cascaded opcodes / verbose errors. As above, these are C build identities,
    not architecture identities, so they are intentionally not guessed from
    M3_ARCH. The generic Wasm3 defaults are used for current Daslang targets.
*/


// ============================================================================
// m3_config_platforms.h: architecture-specific defaults
// ============================================================================


/*
    The only architecture branch in the supplied header is RV64, where Wasm3
    selects 64-bit code/stack slots. Daslang target names are supplied by
    wasm3_defs.M3_ARCH. Recognize both spellings used by common toolchains so
    this remains a compile-time target decision rather than a runtime setting.
*/
let private m3_target_is_rv64 = M3_ARCH == "riscv64" || M3_ARCH == "riscv_64"


// ============================================================================
// m3_config.h: general
// ============================================================================


let public d_m3CodePageAlignSize : uint = 32u * 1024u
let public d_m3MaxFunctionStackHeight : uint = 2000u
let public d_m3MaxLinearMemoryPages : uint = 65536u
let public d_m3MaxFunctionSlots : uint = d_m3MaxFunctionStackHeight * 2u
let public d_m3MaxConstantTableSize : uint = 120u
let public d_m3MaxDuplicateFunctionImpl : uint = 3u
let public d_m3CascadedOpcodes = true
let public d_m3VerboseErrorMessages = true


/*
    C's d_m3FixedHeap is deliberately polymorphic at preprocessing time:
    `false` means disabled, while embedded targets replace it with a byte count.
    Daslang needs one static type. Represent it as a byte count where 0 means
    disabled. This preserves both C meanings without mutable settings.
*/
let public d_m3FixedHeap : uint = 0u
let public d_m3FixedHeapAlign : uint = 16u


let public d_m3Use32BitSlots = !m3_target_is_rv64
let public d_m3ProfilerSlotMask : uint = 0xffffu
let public d_m3RecordBacktraces = false
let public d_m3EnableExceptionBreakpoint = false


/*
    Derived typed sizes used by the Daslang port. M3_SIZEOF_SLOT is an explicit
    adaptation helper, not a C macro from the supplied headers. It avoids
    duplicating m3slot_t itself, which belongs to m3_core.das.
*/
let public M3_SIZEOF_SLOT : uint = d_m3Use32BitSlots ? 4u : 8u


// ============================================================================
// m3_config.h: profiling and tracing
// ============================================================================


let public d_m3EnableOpProfiling = false
let public d_m3EnableOpTracing = false
let public d_m3EnableWasiTracing = false
let public d_m3EnableStrace : uint = 0u


// ============================================================================
// m3_config.h: logging
// ============================================================================


let public d_m3LogParse = false
let public d_m3LogModule = false
let public d_m3LogCompile = false
let public d_m3LogWasmStack = false
let public d_m3LogEmit = false
let public d_m3LogCodePages = false
let public d_m3LogRuntime = false
let public d_m3LogNativeStack = false
let public d_m3LogHeapOps = false
let public d_m3LogTimestamps = false


// ============================================================================
// m3_config.h: other
// ============================================================================


let public d_m3HasFloat = true


/*
    In C d_m3NoFloatDynamic is only auto-defined when d_m3HasFloat == 0.
    Typed Daslang configuration cannot model an "undefined" identifier at use
    sites, so the inactive default is represented explicitly as false.
*/
let public d_m3NoFloatDynamic = !d_m3HasFloat
let public d_m3ImplementFloat = d_m3HasFloat || d_m3NoFloatDynamic


let public d_m3SkipStackCheck = false
let public d_m3SkipMemoryBoundsCheck = false


/* C hard-codes this to 0: code-page reference counting is not supported. */
let public d_m3EnableCodePageRefCounting = false
