options gen2
options indenting = 4

module abi_runtime shared public

require modules/wasm3das/source/m3_parse public     // m3_ParseModule
require modules/wasm3das/source/m3_env public       // runtime, calls, results
require modules/wasm3das/source/m3_module public    // m3_FreeModule, m3_SetModuleName
require modules/wasm3das/source/m3_bind public      // m3_LinkRawFunctionEx
require modules/wasm3das/source/m3_api_defs public  // the raw-call frame helpers the generated wrappers use
require modules/wasm3das/source/m3_exec             // g_ops and the hooks (abi_reload_report)
require strings
require math
require daslib/strings_boost                        // join

/*
    abi_runtime.das: the core of the Eden guest ABI (docs/eden-abi/ABI.md).

    Hand-written; the generated bindings (source/abi/gen/) build on it:
      - AbiInstance: one guest module in its own wasm3 runtime, with the
        state the ABI keeps about it (linked packages, bound exports, the
        last error, the re-entrancy flag, the clock origin)
      - abi_instantiate / abi_destroy: parse + memory budget + load / unlink
        every package + free
      - abi_link_one: one import of a package, linked by name; a function
        the guest does not import is not an error
      - abi_check_imports: after linking, every import of the guest must be
        resolved and belong to the world, else instantiation fails with the
        full list (ABI.md 2: no stub that traps later)
      - abi_call: the one path of every export call, with the re-entrancy
        guard and the faulted state (ABI.md 5, 6)
      - abi_get_str / abi_get_bytes: the checked readers of the (ptr, len)
        pairs the generated import wrappers decode (ABI.md 3)
      - abi_trap / abi_take_trap: how a host implementation fails the guest
      - abi_place_bytes: host -> guest data through eden_alloc (ABI.md 4)

    Engine-free: runs in the local runner and in the editor alike.
*/


// ============================================================================
// Types
// ============================================================================


// a (ptr, len) range of the guest's linear memory, already bounds-checked
// by the wrapper that made it; valid only during the import call
struct AbiBytes {
    ptr : int = 0
    len : int = 0
}


struct AbiConfig {
    stackBytes : uint = 64u * 1024u          // the wasm3 operand stack
    maxMemoryBytes : int64 = 80l * 1048576l  // linear memory cap, initial and grown (the editor's heap is 100 MiB)
    fuseOps : bool = false                   // optional operation fusion (M3Runtime.edenFuseOps); off = C's operations
}


struct AbiInstance {
    id : int = 0                  // > 0; the runtime's userdata, the key of every package's implementation table
    name : string                 // for messages
    env : M3Environment = M3Environment()
    rt : M3Runtime = M3Runtime()
    wasmModule : IM3Module = -1
    world : string                // set by abi_bind_<world>
    linked : array<string>        // packages linked, in order
    unlinkers : array<function<(id : int) : void>>
    exports : table<string; IM3Function>
    error : string                // the last failure ("" = none)
    faulted : bool = false        // a trap happened; every further call fails with `error`
    inCall : string               // the export running now ("" = none)
    startTicks : int64 = 0l       // ref_time_ticks at creation (eden_core.time_us)
    alive : bool = false          // instantiated and not destroyed
    // hot reload (ABI.md 7): function values die with a reload; these let a
    // host re-link the instance in place, keeping its memory and state
    rawCallIndex : table<string; int>   // "package.function" -> its slot in rt.rawCalls
    probe : function<() : bool>          // a function value; stale after a reload
    relinking : bool = false             // between abi_relink_begin and abi_relink_end
    relinked : array<string>             // packages linked again since abi_relink_begin
}


let public ABI_PAGE_BYTES = 65536l


var private g_nextInstanceId = 1
var private g_pendingTrap = ""


// ============================================================================
// Traps from host implementations (ABI.md 5)
// ============================================================================


// A host implementation calls this and returns; the generated wrapper turns
// it into "[trap] <package>.<function>: <message>"
def public abi_trap(message : string) {
    g_pendingTrap = empty(message) ? "trap" : message
}


def public abi_take_trap() : string {
    let t = g_pendingTrap
    g_pendingTrap = ""
    return t
}


def public abi_trap_message(package : string; func : string; message : string) : M3Result {
    return "[trap] {package}.{func}: {message}"
}


// ============================================================================
// Argument readers of the generated import wrappers (ABI.md 3)
// ============================================================================


// reads (ptr, len); the range must lie in linear memory
def public abi_get_bytes(rt : M3Runtime; var f : M3ApiFrame; var o_bytes : AbiBytes&) : M3Result {
    let ptr = m3ApiGetArg_u32(rt, f)
    let len = m3ApiGetArg_i32(rt, f)
    if (len < 0) {
        return "negative length {len}"
    }
    let size = int64(length(rt.mem))
    if (int64(ptr) + int64(len) > size) {
        return "range [{int64(ptr)}, {int64(ptr) + int64(len)}) outside linear memory of {size} bytes"
    }
    o_bytes.ptr = int(ptr)
    o_bytes.len = len
    return m3Err_none
}


// reads (ptr, len) as UTF-8 text; a NUL byte cannot live in a daslang string
def public abi_get_str(rt : M3Runtime; var f : M3ApiFrame; var o_text : string&) : M3Result {
    var b = AbiBytes()
    let r = abi_get_bytes(rt, f, b)
    if (r != m3Err_none) {
        return r
    }
    for (i in range(b.len)) {
        if (rt.mem[b.ptr + i] == 0u8) {
            return "string contains a NUL byte at {i}"
        }
    }
    // built in place: no temporary byte array (the script heap is only
    // collected between engine frames, and a guest step can make many calls)
    o_text = build_string() $(var w) {
        for (i in range(b.len)) {
            write_char(w, int(rt.mem[b.ptr + i]))
        }
    }
    return m3Err_none
}


def public abi_get_bool(rt : M3Runtime; var f : M3ApiFrame) : bool {
    return m3ApiGetArg_i32(rt, f) != 0
}


// ============================================================================
// Memory access for host code
// ============================================================================


def public abi_byte(rt : M3Runtime; b : AbiBytes; i : int) : uint8 {
    return rt.mem[b.ptr + i]
}


def public abi_set_byte(var rt : M3Runtime; b : AbiBytes; i : int; v : uint8) {
    rt.mem[b.ptr + i] = v
}


// a copy of guest memory [ptr, ptr + len); empty when out of range
def public abi_read_bytes(inst : AbiInstance; ptr : int; len : int) : array<uint8> {
    var out : array<uint8>
    if (ptr < 0 || len < 0 || int64(ptr) + int64(len) > int64(length(inst.rt.mem))) {
        return <- out
    }
    resize(out, len)
    for (i in range(len)) {
        out[i] = inst.rt.mem[ptr + i]
    }
    return <- out
}


// ============================================================================
// Instances
// ============================================================================


// parse, check the memory budget, load. On failure the returned instance
// has alive = false and `error` set; nothing needs to be destroyed
def public abi_instantiate(bytes : array<uint8>; name : string; config : AbiConfig = AbiConfig()) : AbiInstance {
    var inst = AbiInstance()
    inst.id = g_nextInstanceId++
    inst.name = name
    inst.startTicks = ref_time_ticks()
    inst.env <- m3_NewEnvironment()
    inst.rt <- m3_NewRuntime(inst.env, config.stackBytes, inst.id)
    inst.rt.edenFuseOps = config.fuseOps
    let parsed = m3_ParseModule(inst.rt, bytes)
    if (parsed._0 != m3Err_none) {
        inst.error = "{name}: parse failed: {parsed._0}"
        abi_release(inst)
        return <- inst
    }
    let wasmModule = parsed._1
    let mi = inst.rt.modules[wasmModule].memoryInfo
    let initBytes = int64(mi.initPages) * ABI_PAGE_BYTES
    if (initBytes > config.maxMemoryBytes) {
        inst.error = "{name}: initial linear memory {initBytes} bytes ({mi.initPages} pages) exceeds the budget of {config.maxMemoryBytes} bytes"
        m3_FreeModule(inst.rt, wasmModule)
        abi_release(inst)
        return <- inst
    }
    if (inst.rt.modules[wasmModule].memoryImported) {
        inst.error = "{name}: the module imports its memory ({inst.rt.modules[wasmModule].memoryImport.moduleUtf8}.{inst.rt.modules[wasmModule].memoryImport.fieldUtf8}); the ABI requires a module-defined memory"
        m3_FreeModule(inst.rt, wasmModule)
        abi_release(inst)
        return <- inst
    }
    let loaded = m3_LoadModule(inst.rt, wasmModule)
    if (loaded != m3Err_none) {
        inst.error = "{name}: load failed: {loaded}"
        m3_FreeModule(inst.rt, wasmModule)
        abi_release(inst)
        return <- inst
    }
    m3_SetModuleName(inst.rt, wasmModule, name)
    inst.wasmModule = wasmModule
    inst.probe = @@abi_probe_alive
    // memory.grow past the budget fails in the guest (returns -1) instead
    // of allocating past the editor's heap
    let budgetPages = uint(config.maxMemoryBytes / ABI_PAGE_BYTES)
    if (inst.rt.memory.maxPages > budgetPages) {
        inst.rt.memory.maxPages = budgetPages
    }
    inst.alive = true
    return <- inst
}


def private abi_release(var inst : AbiInstance) {
    m3_FreeRuntime(inst.rt)
    m3_FreeEnvironment(inst.env)
    inst.alive = false
}


// unlinks every package (their per-instance state goes away) and frees the
// runtime. Safe to call twice
def public abi_destroy(var inst : AbiInstance) {
    if (!inst.alive) {
        return
    }
    // after a hot reload without a relink the unlinkers are dead function
    // values: their per-instance state cannot be reached any more, and the
    // runtime is freed regardless (hosts relink before destroying)
    for (u in inst.unlinkers) {
        try {
            invoke(u, inst.id)
        } recover {
            print("[abi] {inst.name}: an unlinker did not survive a hot reload; relink before abi_destroy\n")
        }
    }
    clear(inst.unlinkers)
    clear(inst.linked)
    clear(inst.exports)
    abi_release(inst)
}


// microseconds since the instance was created
def public abi_time_us(inst_start : int64) : int64 {
    return get_time_nsec(inst_start) / 1000l
}


// ============================================================================
// Linking (ABI.md 2, 7)
// ============================================================================


// links one import by name. A function the guest does not import is fine;
// a signature mismatch is not. While relinking, the function value replaces
// the one in its rt.rawCalls slot: compiled code keeps calling the slot
def public abi_link_one(var inst : AbiInstance; package : string; func : string; signature : string; call : M3RawCall) : M3Result {
    let key = "{package}.{func}"
    if (inst.relinking) {
        if (inst.rawCallIndex |> key_exists(key)) {
            inst.rt.rawCalls[inst.rawCallIndex[key]] = call
        }
        return m3Err_none
    }
    let before = length(inst.rt.rawCalls)
    let r = m3_LinkRawFunctionEx(inst.rt, inst.wasmModule, package, func, signature, call, inst.id)
    if (r == m3Err_functionLookupFailed) {
        return m3Err_none
    }
    if (r != m3Err_none) {
        return "{inst.name}: import {package}.{func}: {r} (the host signature is {signature})"
    }
    if (length(inst.rt.rawCalls) > before) {
        inst.rawCallIndex[key] = before
    }
    return m3Err_none
}


def public abi_register_package(var inst : AbiInstance; package : string; unlink : function<(id : int) : void>) {
    if (inst.relinking) {
        push(inst.relinked, package)
    } else {
        push(inst.linked, package)
    }
    push(inst.unlinkers, unlink)
}


// ============================================================================
// Hot reload (ABI.md 7)
// ============================================================================


def private abi_probe_alive() : bool {
    return true
}


// what survived a hot reload, without invoking anything: the number of
// null function values in the op table, the hooks and the instance's
// raw calls (a diagnostic for hosts and the gate)
def public abi_reload_report(inst : AbiInstance) : string {
    var nullOps = 0
    for (op in g_ops) {
        if (op == null) {
            nullOps++
        }
    }
    var nullRaw = 0
    if (inst.alive) {
        for (c in inst.rt.rawCalls) {
            if (c == null) {
                nullRaw++
            }
        }
    }
    var probeAlive = false
    try {
        probeAlive = invoke(inst.probe)
    } recover {
        probeAlive = false
    }
    return "ops={length(g_ops)} nullOps={nullOps} compileHook={CompileFunctionHook != null} resizeHook={ResizeMemoryHook != null} rawCalls={length(inst.rt.rawCalls)} nullRaw={nullRaw} probe={probeAlive}"
}


// true when the instance's function values died with a hot reload of the
// scripts: calling it would panic inside wasm3. The host then relinks it
// Measured in the editor (0.9.0.34): after a reload every carried function
// value whose type mentions M3Runtime is null (all of g_ops, both hooks,
// every rt.rawCalls entry), while a `function<() : bool>` survives. So the
// null checks decide; the probe covers a future editor that fails
// differently
def public abi_is_stale(inst : AbiInstance) : bool {
    if (!inst.alive) {
        return false
    }
    if (CompileFunctionHook == null || ResizeMemoryHook == null || length(g_ops) == 0 || g_ops[0] == null) {
        return true
    }
    for (c in inst.rt.rawCalls) {
        if (c == null) {
            return true
        }
    }
    var alive = false
    try {
        alive = invoke(inst.probe)
    } recover {
        alive = false
    }
    return !alive
}


// starts relinking a live instance after a hot reload: the wasm3 op tables
// and hooks are rebuilt, the unlinkers dropped (the host's link functions
// register fresh ones). Then the host links every package again, exactly
// as it did at first (same packages, fresh implementations) and calls
// abi_relink_end
def public abi_relink_begin(var inst : AbiInstance) {
    m3_EdenRewireTables()
    clear(inst.unlinkers)
    clear(inst.relinked)
    inst.relinking = true
}


def public abi_relink_end(var inst : AbiInstance) : M3Result {
    inst.relinking = false
    inst.probe = @@abi_probe_alive
    var missing : array<string>
    for (p in inst.linked) {
        var found = false
        for (q in inst.relinked) {
            if (p == q) {
                found = true
            }
        }
        if (!found) {
            push(missing, p)
        }
    }
    if (length(missing) > 0) {
        inst.faulted = true
        inst.error = "{inst.name}: relink left packages without implementations: {join(missing, ", ")}"
        return inst.error
    }
    return m3Err_none
}


// host state keyed by the instance id that must go away with the instance
def public abi_on_destroy(var inst : AbiInstance; forget : function<(id : int) : void>) {
    push(inst.unlinkers, forget)
}


def public abi_is_linked(inst : AbiInstance; package : string) : bool {
    for (p in inst.linked) {
        if (p == package) {
            return true
        }
    }
    return false
}


// every import must be resolved and come from a package of the world
def public abi_check_imports(inst : AbiInstance; world : string; packages : array<string>) : M3Result {
    var problems : array<string>
    let numImports = int(inst.rt.modules[inst.wasmModule].numFuncImports)
    for (i in range(numImports)) {
        let f = inst.rt.modules[inst.wasmModule].functions[i]
        let modName = inst.rt.functions[f].import.moduleUtf8
        let field = inst.rt.functions[f].import.fieldUtf8
        var inWorld = false
        for (p in packages) {
            if (p == modName) {
                inWorld = true
            }
        }
        if (!inWorld) {
            push(problems, "{modName}.{field} (package not in world {world})")
        } elif (inst.rt.functions[f].compiled == -1) {
            push(problems, "{modName}.{field} (package not linked by the host)")
        }
    }
    if (length(problems) == 0) {
        return m3Err_none
    }
    return "{inst.name}: unresolved imports: {join(problems, ", ")}"
}


// looks up the exports of a world; a missing required one is an error
def public abi_bind_exports(var inst : AbiInstance; required : array<string>; optional : array<string>) : M3Result {
    var missing : array<string>
    for (name in required) {
        var func : IM3Function = -1
        let r = m3_FindFunction(inst.rt, func, name)
        if (r == m3Err_none) {
            inst.exports[name] = func
        } else {
            push(missing, name)
        }
    }
    for (name in optional) {
        var func : IM3Function = -1
        if (m3_FindFunction(inst.rt, func, name) == m3Err_none) {
            inst.exports[name] = func
        }
    }
    if (length(missing) == 0) {
        return m3Err_none
    }
    return "{inst.name}: missing required exports: {join(missing, ", ")}"
}


def public abi_has_export(inst : AbiInstance; name : string) : bool {
    return inst.exports |> key_exists(name)
}


// ============================================================================
// Export calls (ABI.md 5, 6)
// ============================================================================


// calls an export with raw argument bits; true when it returned normally.
// On false, inst.error says why; a trap also sets inst.faulted
def public abi_call(var inst : AbiInstance; name : string; args : array<uint64>; var rets : array<uint64>) : bool {
    clear(rets)
    if (!inst.alive) {
        inst.error = "{inst.name}: {name}: the instance is not alive"
        return false
    }
    if (inst.faulted) {
        return false
    }
    if (!empty(inst.inCall)) {
        inst.error = "{inst.name}: reentrant call: {name} while {inst.inCall} runs"
        return false
    }
    if (!(inst.exports |> key_exists(name))) {
        inst.error = "{inst.name}: export not provided: {name}"
        return false
    }
    if (abi_is_stale(inst)) {
        inst.error = "{inst.name}: {name}: stale after a hot reload of the scripts; relink the instance (abi_relink_begin / link / abi_relink_end)"
        return false
    }
    let func = inst.exports[name]
    inst.inCall = name
    var r = m3_Call(inst.rt, func, args)
    inst.inCall = ""
    if (r == m3Err_none) {
        let retCount = m3_GetRetCount(inst.rt, func)
        r = m3_GetResults(inst.rt, func, retCount, rets)
        if (r != m3Err_none) {
            inst.error = "{inst.name}: {name}: results: {r}"
            return false
        }
        return true
    }
    inst.faulted = true
    inst.error = "{inst.name}: {name}: {r}"
    return false
}


// copies bytes into guest memory allocated with eden_alloc; 0 on failure
// (inst.error says why). The caller frees with abi_free_guest
def public abi_place_bytes(var inst : AbiInstance; bytes : array<uint8>) : int {
    var inscope args : array<uint64>
    push(args, m3_bits_from_i32(max(length(bytes), 1)))
    var inscope rets : array<uint64>
    if (!abi_call(inst, "eden_alloc", args, rets)) {
        return 0
    }
    let ptr = int(m3_bits_to_i32(rets[0]))
    if (ptr == 0 || int64(ptr) + int64(length(bytes)) > int64(length(inst.rt.mem))) {
        inst.error = "{inst.name}: eden_alloc({length(bytes)}) returned {ptr}"
        return 0
    }
    for (b, i in bytes, count()) {
        inst.rt.mem[ptr + i] = b
    }
    return ptr
}


def public abi_place_str(var inst : AbiInstance; text : string) : int {
    var inscope bytes : array<uint8>
    resize(bytes, length(text))
    for (i in range(length(text))) {
        bytes[i] = uint8(character_at(text, i))
    }
    return abi_place_bytes(inst, bytes)
}


def public abi_free_guest(var inst : AbiInstance; ptr : int) {
    if (ptr == 0 || inst.faulted) {
        return
    }
    var inscope args : array<uint64>
    push(args, m3_bits_from_i32(ptr))
    var inscope rets : array<uint64>
    abi_call(inst, "eden_free", args, rets)
}
