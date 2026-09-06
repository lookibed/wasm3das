options gen2
options indenting = 4

module m3_env shared public

require ./m3_core.das
require ./m3_types.das public
require ./m3_exec_defs.das
require ./m3_code.das public
require ./m3_function.das
require ./m3_module.das public
require ./m3_compile.das public
require ./m3_exec.das
require strings

let c_m3Type_none : u8 = u8(M3ValueType.c_m3Type_none)
let c_m3Type_i32 : u8 = u8(M3ValueType.c_m3Type_i32)
let c_m3Type_i64 : u8 = u8(M3ValueType.c_m3Type_i64)
let c_m3Type_f32 : u8 = u8(M3ValueType.c_m3Type_f32)
let c_m3Type_f64 : u8 = u8(M3ValueType.c_m3Type_f64)

typedef ModuleVisitor = function<(var i_module : IM3Module; i_info : void?) : void?>

struct M3BacktraceFrame {
}
typedef IM3BacktraceFrame = M3BacktraceFrame?
struct M3BacktraceInfo {
    frames : IM3BacktraceFrame
    lastFrame : IM3BacktraceFrame
}


def m3_value_type(i_type : u8) : M3ValueType {
    unsafe { return reinterpret<M3ValueType>(u32(i_type)) }
}


def tagged_get_i32(i_value : M3TaggedValue) : i32 {
    unsafe {
        let p = addr<i32 const?>(i_value.valueBits)
        return *p
    }
}

def tagged_get_i64(i_value : M3TaggedValue) : i64 {
    unsafe {
        let p = addr<i64 const?>(i_value.valueBits)
        return *p
    }
}

def tagged_get_f32(i_value : M3TaggedValue) : f32 {
    unsafe {
        let p = addr<f32 const?>(i_value.valueBits)
        return *p
    }
}

def tagged_get_f64(i_value : M3TaggedValue) : f64 {
    unsafe {
        let p = addr<f64 const?>(i_value.valueBits)
        return *p
    }
}

def tagged_set_i32(var io_value : M3TaggedValue&; i_value : i32) {
    unsafe {
        var p = addr<i32?>(io_value.valueBits)
        *p = i_value
    }
}

def tagged_set_i64(var io_value : M3TaggedValue&; i_value : i64) {
    unsafe {
        var p = addr<i64?>(io_value.valueBits)
        *p = i_value
    }
}

def tagged_set_f32(var io_value : M3TaggedValue&; i_value : f32) {
    unsafe {
        var p = addr<f32?>(io_value.valueBits)
        *p = i_value
    }
}

def tagged_set_f64(var io_value : M3TaggedValue&; i_value : f64) {
    unsafe {
        var p = addr<f64?>(io_value.valueBits)
        *p = i_value
    }
}


// C: m3_ReallocArray (IM3Function, io_module->table0, endElement, io_module->table0Size)
// in InitElements - the macro's sizeof(IM3Function) scaling, expanded once here.
def m3_ReallocFunctionTable(var i_table : IM3Function?; i_newCount, i_oldCount : u32) : IM3Function? {
    var raw : void?
    unsafe { raw = reinterpret<void?>(i_table) }
    let elemSize = u64(typeinfo sizeof(type<IM3Function>))
    let resized = m3_Realloc_Impl(raw, u64(i_newCount) * elemSize, u64(i_oldCount) * elemSize)
    unsafe { return reinterpret<IM3Function?>(resized) }
}


// C spells this inline at every call site (m3_RunStart, m3_CallVL, m3_Call,
// m3_CallArgv): RunCode (i_function->compiled, (m3stack_t) runtime->stack,
// runtime->memory.mallocated, d_m3OpDefaultArgs). d_m3OpDefaultArgs is
// r0 = 0, fp0 = 0.0 under d_m3HasFloat; the profiling/tracing variant with
// d_m3BaseCstr is compiled out.
def RunFunctionCode(var i_function : IM3Function) : M3Result {
    var runtime = i_function._module.runtime
    var pc = i_function.compiled
    var sp : m3stack_t
    unsafe { sp = reinterpret<m3stack_t>(runtime.stack) }
    var mem = runtime.memory.mallocated
    let r0 : m3reg_t = 0l
    let fp0 : f64 = 0.0lf
    return RunCode(pc, sp, mem, r0, fp0)
}


// Conservative Gen2 port of m3_env.c.
// Core wasm3 types, allocators, parsing helpers, and CompileBlock/CompileFunction
// are expected from the shared project layer, matching the existing module graph.
// Daslang has no C va_list; m3_CallV/m3_CallVL and m3_GetResultsV/m3_GetResultsVL
// use typed M3TaggedValue arrays as the Gen2 boundary while preserving stack layout.


def m3_NewEnvironment() : IM3Environment {
    // Port scaffolding (m3_exec.das hook note): C's m3_exec.h reaches the
    // compiler and ResizeMemory through its include cycle; the acyclic
    // Daslang module graph replaces those edges with these global bindings,
    // registered once before any runtime can execute. Idempotent.
    CompileFunctionHook = @@CompileFunction
    ResizeMemoryHook = @@ResizeMemory
    // C: `const M3OpInfo c_operations []` (m3_compile.c) is a static
    // initialiser. The Daslang table is filled by [init], which some hosts
    // skip for required modules; the call is idempotent.
    init_compile_operation_tables()

    // C: m3_AllocStruct (M3Environment) - zeroed host allocation; released
    // with m3_Free_Impl in m3_FreeEnvironment (docs/memory-ownership.md).
    var env : IM3Environment
    unsafe {
        env = reinterpret<IM3Environment>(m3_Malloc_Impl(u64(typeinfo sizeof(type<M3Environment>))))
    }

    if (env != null) {
        var result : M3Result = m3Err_none

        for (ti in int(c_m3Type_none)..(int(c_m3Type_f64) + 1)) {
            let t : u8 = u8(ti)
            var ftype : IM3FuncType = null
            result = AllocFuncType(ftype, 1u)
            if (result != m3Err_none) {
                break
            }

            ftype.numArgs = 0
            if (t == c_m3Type_none) { ftype.numRets = 0 } else { ftype.numRets = 1 }
            ftype.types[0] = t

            Environment_AddFuncType(env, ftype)
            d_m3Assert(int(t) < 5)
            env.retFuncTypes[int(t)] = ftype
        }

        if (result != m3Err_none) {
            m3_FreeEnvironment(env)
            env = null
        }
    }

    return env
}


def Environment_Release(var i_environment : IM3Environment) {
    var ftype = i_environment.funcTypes

    while (ftype != null) {
        var next = ftype.next
        // C: m3_Free (ftype)
        m3_Free_Impl(unsafe(reinterpret<void?>(ftype)))
        ftype = next
    }

    // compiled out under the active configuration: m3log page count
    FreeCodePages(i_environment.pagesReleased)
}


def m3_FreeEnvironment(var i_environment : IM3Environment) {
    if (i_environment != null) {
        Environment_Release(i_environment)
        // C: m3_Free (i_environment)
        m3_Free_Impl(unsafe(reinterpret<void?>(i_environment)))
    }
}


def m3_SetCustomSectionHandler(var i_environment : IM3Environment; i_handler : M3SectionHandler) {
    if (i_environment != null) {
        i_environment.customSectionHandler = i_handler
    }
}


// Returns the same io_funcType or replaces it with an equivalent already interned.
def Environment_AddFuncType(var i_environment : IM3Environment; var io_funcType : IM3FuncType&) {
    var addType = io_funcType
    var newType = i_environment.funcTypes

    while (newType != null) {
        if (AreFuncTypesEqual(newType, addType)) {
            // C: m3_Free (addType) - see Environment_Release note (host malloc).
            m3_Free_Impl(unsafe(reinterpret<void?>(addType)))
            break
        }
        newType = newType.next
    }

    if (newType == null) {
        newType = addType
        newType.next = i_environment.funcTypes
        i_environment.funcTypes = newType
    }

    io_funcType = newType
}








def m3_NewRuntime(var i_environment : IM3Environment; i_stackSizeInBytes : u32; i_userdata : void?) : IM3Runtime {
    // C: m3_AllocStruct (M3Runtime) - zeroed host allocation; released with
    // m3_Free_Impl in m3_FreeRuntime (docs/memory-ownership.md).
    var runtime : IM3Runtime
    unsafe {
        runtime = reinterpret<IM3Runtime>(m3_Malloc_Impl(u64(typeinfo sizeof(type<M3Runtime>))))
    }

    if (runtime != null) {
        m3_ResetErrorInfo(runtime)
        runtime.environment = i_environment
        runtime.userdata = i_userdata

        let allocationSize = u64(i_stackSizeInBytes) + 4ul * u64(typeinfo sizeof(type<m3slot_t>))
        runtime.originStack = m3_Malloc_Impl(allocationSize)

        if (runtime.originStack != null) {
            runtime.stack = runtime.originStack
            runtime.numStackSlots = i_stackSizeInBytes / u32(typeinfo sizeof(type<m3slot_t>))

        } else {
            // C: m3_Free (runtime)
            m3_Free_Impl(unsafe(reinterpret<void?>(runtime)))
            runtime = null
        }
    }

    return runtime
}


def m3_GetUserData(i_runtime : IM3Runtime) : void? {
    if (i_runtime != null) {
        return i_runtime.userdata
    }
    return null
}


def ForEachModule(var i_runtime : IM3Runtime; i_visitor : ModuleVisitor; i_info : void?) : void? {
    var r : void? = null
    var _module = i_runtime.modules

    while (_module != null) {
        var next = _module.next
        r = i_visitor(_module, i_info)
        if (r != null) {
            break
        }
        _module = next
    }

    return r
}


// Module_FreeFunctions and m3_FreeModule live in m3_module.das (m3_module.c).

def _FreeModule(var i_module : IM3Module; i_info : void?) : void? {
    m3_FreeModule(i_module)
    return null
}


def Runtime_Release(var i_runtime : IM3Runtime) {
    ForEachModule(i_runtime, @@_FreeModule, null)
    d_m3Assert(i_runtime.numActiveCodePages == 0)

    Environment_ReleaseCodePages(i_runtime.environment, i_runtime.pagesOpen)
    Environment_ReleaseCodePages(i_runtime.environment, i_runtime.pagesFull)

    // C: m3_Free (i_runtime->originStack) - the macro also nulls the field.
    m3_Free_Impl(i_runtime.originStack)
    i_runtime.originStack = null
    // C: m3_Free (i_runtime->memory.mallocated)
    m3_Free_Impl(unsafe(reinterpret<void?>(i_runtime.memory.mallocated)))
    i_runtime.memory.mallocated = null
}


def m3_FreeRuntime(var i_runtime : IM3Runtime) {
    if (i_runtime != null) {
        // compiled out under the active configuration: m3_PrintProfilerInfo
        Runtime_Release(i_runtime)
        // C: m3_Free (i_runtime)
        m3_Free_Impl(unsafe(reinterpret<void?>(i_runtime)))
    }
}


def EvaluateExpression(var i_module : IM3Module; o_expressed : void?; i_type : u8; var io_bytes : bytes_t&; i_end : cbytes_t) : M3Result {
    var result : M3Result = m3Err_none
    var runtime = M3Runtime(environment = i_module.runtime.environment, numStackSlots = i_module.runtime.numStackSlots, stack = i_module.runtime.stack)


    var stack = unsafe(reinterpret<m3stack_t>(runtime.stack))
    var savedRuntime = i_module.runtime
    i_module.runtime = unsafe(addr(runtime))

    var o = unsafe(addr(runtime.compilation))
    o.runtime = unsafe(addr(runtime))
    o._module = i_module
    o.wasm = io_bytes
    unsafe { o.wasmEnd = reinterpret<bytes_t>(i_end) }
    o.lastOpcodeStart = o.wasm
    o._block.depth = -1

    o.page = AcquireCodePage(unsafe(addr(runtime)))

    if (o.page != null) {
        var ftype = runtime.environment.retFuncTypes[int(i_type)]
        var m3code = GetPagePC(o.page)
        result = CompileBlock(o, ftype, c_waOp_block)

        if (result == m3Err_none && u32(o.maxStackSlots) >= runtime.numStackSlots) {
            result = m3Err_trapStackOverflow
        }

        if (result == m3Err_none) {
            var mem : M3MemoryHeader? = null
            let r0 : m3reg_t = 0l
            let fp0 : f64 = 0.0lf
            let r = RunCode(m3code, stack, mem, r0, fp0)
            if (r == m3Err_none) {
                unsafe {
                    if (SizeOfType(i_type) == u32(typeinfo sizeof(type<u32>))) {
                        var dst32 = reinterpret<u32?>(o_expressed)
                        var src32 = stack
                        *dst32 = *src32
                    } else {
                        var dst64 = reinterpret<u64?>(o_expressed)
                        var src64 = reinterpret<u64?>(stack)
                        *dst64 = *src64
                    }
                }
            }
        }

        ReleaseCodePage(unsafe(addr(runtime)), o.page)
    } else {
        result = m3Err_mallocFailedCodePage
    }

    runtime.originStack = null
    Runtime_Release(unsafe(addr(runtime)))
    i_module.runtime = savedRuntime
    io_bytes = o.wasm

    return result
}


def InitMemory(var io_runtime : IM3Runtime; i_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none

    if (!i_module.memoryImported) {
        let maxPages = i_module.memoryInfo.maxPages
        let pageSize = i_module.memoryInfo.pageSize
        if (maxPages != 0) { io_runtime.memory.maxPages = maxPages } else { io_runtime.memory.maxPages = 65536u }
        if (pageSize != 0) { io_runtime.memory.pageSize = pageSize } else { io_runtime.memory.pageSize = u32(d_m3DefaultMemPageSize) }
        result = ResizeMemory(io_runtime, i_module.memoryInfo.initPages)
    }

    return result
}


def ResizeMemory(var io_runtime : IM3Runtime; i_numPages : u32) : M3Result {
    var result : M3Result = m3Err_none
    let numPagesToAlloc = i_numPages
    var memory = unsafe(addr(io_runtime.memory))
    if (numPagesToAlloc <= memory.maxPages) {
        var numPageBytes = u64(numPagesToAlloc) * u64(io_runtime.memory.pageSize)

        if (d_m3MaxLinearMemoryPages > 0 && numPagesToAlloc > d_m3MaxLinearMemoryPages) {
            return "linear memory limitation exceeded"
        }

        if (io_runtime.memoryLimit != 0u && numPageBytes > u64(io_runtime.memoryLimit)) {
            numPageBytes = u64(io_runtime.memoryLimit)
        }

        let numBytes = numPageBytes + u64(typeinfo sizeof(type<M3MemoryHeader>))
        var numPreviousBytes = u64(memory.numPages) * u64(io_runtime.memory.pageSize)
        if (numPreviousBytes != 0ul) {
            numPreviousBytes += u64(typeinfo sizeof(type<M3MemoryHeader>))
        }

        var oldMem : void?
        unsafe { oldMem = reinterpret<void?>(memory.mallocated) }
        let newMem = m3_Realloc_Impl(oldMem, numBytes, numPreviousBytes)
        if (newMem == null) {
            return m3Err_mallocFailed
        }

        memory.mallocated = unsafe(reinterpret<M3MemoryHeader?>(newMem))
        memory.numPages = numPagesToAlloc
        memory.mallocated.length = numPageBytes
        memory.mallocated.runtime = io_runtime

        unsafe {
            memory.mallocated.maxStack = reinterpret<m3slot_t?>(io_runtime.stack) + int(io_runtime.numStackSlots)
        }


    } else {
        result = m3Err_wasmMemoryOverflow
    }

    return result
}


def InitGlobals(var io_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none

    if (io_module.numGlobals != 0) {
        for (ii in 0..int(io_module.numGlobals)) {
            let i = u32(ii)
            var g : IM3Global
            unsafe { g = addr(io_module.globals[int(i)]) }


            if (g.initExpr != null) {
                var start = g.initExpr
                var globalEnd : bytes_t
                unsafe { globalEnd = g.initExpr + int(g.initExprSize) }
                var valuePtr : void?
                unsafe { valuePtr = addr<void?>(g.valueBits) }
                result = EvaluateExpression(io_module, valuePtr, g._type, start, globalEnd)
                if (result != m3Err_none) {
                    break
                }
            } else {

            }
        }
    }

    return result
}


def InitDataSegments(var io_memory : M3Memory&; var io_module : IM3Module) : M3Result {
    if (io_memory.mallocated == null) {
        return "unallocated linear memory"
    }

    for (ii in 0..int(io_module.numDataSegments)) {
        let i = u32(ii)
        var segment : M3DataSegment?
        unsafe { segment = addr(io_module.dataSegments[int(i)]) }
        var segmentOffset : i32 = 0
        var start = segment.initExpr
        var segmentEnd : bytes_t
        unsafe { segmentEnd = segment.initExpr + int(segment.initExprSize) }
        var offsetPtr : void?
        unsafe { offsetPtr = addr<void?>(segmentOffset) }
        let result = EvaluateExpression(io_module, offsetPtr, c_m3Type_i32, start, segmentEnd)
        if (result != m3Err_none) {
            return result
        }



        if (segmentOffset >= 0 && u64(segmentOffset) + u64(segment.size) <= io_memory.mallocated.length) {
            unsafe {
                let dest = m3MemData(io_memory.mallocated) + segmentOffset
                unsafe { memcpy(dest, segment.data, segment.size) }
            }
        } else {
            return "data segment out of bounds"
        }
    }

    return m3Err_none
}


def InitElements(var io_module : IM3Module) : M3Result {
    var bytes : bytes_t = io_module.elementSection
    let end = io_module.elementSectionEnd

    for (_ii in 0..int(io_module.numElementSegments)) {
        var index = 0u
        var result = ReadLEB_u32(index, bytes, end)
        if (result != m3Err_none) {
            return result
        }

        if (index == 0) {
            var offset : i32 = 0
            result = EvaluateExpression(io_module, unsafe(addr(offset)), c_m3Type_i32, bytes, end)
            if (result != m3Err_none) {
                return result
            }
            if (offset < 0) {
                return "table underflow"
            }

            var numElements = 0u
            result = ReadLEB_u32(numElements, bytes, end)
            if (result != m3Err_none) {
                return result
            }

            let endElement = u64(numElements) + u64(offset)
            if (endElement > u64(d_m3MaxSaneTableSize)) {
                return "table overflow"
            }

            if (endElement > u64(io_module.table0Size)) {
                io_module.table0 = m3_ReallocFunctionTable(io_module.table0, u32(endElement), io_module.table0Size)
                io_module.table0Size = u32(endElement)
            }
            // C: _throwifnull (io_module->table0) - checked whether or not the table grew.
            if (io_module.table0 == null) {
                return m3Err_mallocFailed
            }

            for (ee in 0..int(numElements)) {
                let e = u32(ee)
                var functionIndex = 0u
                result = ReadLEB_u32(functionIndex, bytes, end)
                if (result != m3Err_none) {
                    return result
                }
                if (functionIndex >= io_module.numFunctions) {
                    return "function index out of range"
                }

                var _function : IM3Function
                unsafe { _function = addr(io_module.functions[int(functionIndex)]) }
                d_m3Assert(_function != null)
                unsafe { io_module.table0[int(e + u32(offset))] = _function }
            }
        } else {
            return "element table index must be zero for MVP"
        }
    }

    return m3Err_none
}


def m3_CompileModule(var io_module : IM3Module) : M3Result {
    for (ii in 0..int(io_module.numFunctions)) {
        let i = u32(ii)
        var f : IM3Function
        unsafe { f = addr(io_module.functions[int(i)]) }
        if (f.wasm != null && f.compiled == null) {
            let result = CompileFunction(f)
            if (result != m3Err_none) {
                return result
            }
        }
    }
    return m3Err_none
}


def m3_RunStart(var io_module : IM3Module) : M3Result {
    var result : M3Result = m3Err_none
    var startFunctionTmp : i32 = -1

    if (io_module != null && io_module.startFunction >= 0) {
        var _function : IM3Function
        unsafe { _function = addr(io_module.functions[io_module.startFunction]) }

        if (_function.compiled == null) {
            result = CompileFunction(_function)
            if (result != m3Err_none) {
                return result
            }
        }

        let ftype = _function.funcType
        if (ftype.numArgs != 0 || ftype.numRets != 0) {
            return m3Err_argumentCountMismatch
        }

        // C reads function->module->runtime here for RunCode; RunFunctionCode does the same.
        startFunctionTmp = io_module.startFunction
        io_module.startFunction = -1

        result = RunFunctionCode(_function)

        if (result != m3Err_none) {
            io_module.startFunction = startFunctionTmp
            // compiled out under the active configuration: d_m3EnableExceptionBreakpoint == false
        }
    }

    return result
}


def m3_LoadModule(var io_runtime : IM3Runtime; var io_module : IM3Module) : M3Result {
    if (io_module.runtime != null) {
        return m3Err_moduleAlreadyLinked
    }

    io_module.runtime = io_runtime
    var result = InitMemory(io_runtime, io_module)
    if (result == m3Err_none) { result = InitGlobals(io_module) }
    if (result == m3Err_none) { result = InitDataSegments(io_runtime.memory, io_module) }
    if (result == m3Err_none) { result = InitElements(io_module) }

    if (result != m3Err_none) {
        io_module.runtime = null
        return result
    }

    // compiled out under the active configuration: DEBUG is disabled

    io_module.next = io_runtime.modules
    io_runtime.modules = io_module
    return m3Err_none
}


def m3_FindGlobal(var io_module : IM3Module; i_globalName : string) : IM3Global {
    for (ii in 0..int(io_module.numGlobals)) {
        var g : IM3Global
        unsafe { g = addr(io_module.globals[ii]) }
        if (!empty(g.name) && g.name == i_globalName) { return g }
    }

    for (ii in 0..int(io_module.numGlobals)) {
        var g : IM3Global
        unsafe { g = addr(io_module.globals[ii]) }
        if (!empty(g.import.moduleUtf8) && !empty(g.import.fieldUtf8) && g.import.fieldUtf8 == i_globalName) {
            return g
        }
    }
    return null
}


def m3_GetGlobal(var i_global : IM3Global; var o_value : M3TaggedValue&) : M3Result {
    if (i_global == null) { return m3Err_globalLookupFailed }

    if (i_global._type == c_m3Type_i32) {
        tagged_set_i32(o_value, M3Global_GetI32Value(*i_global))
    } elif (i_global._type == c_m3Type_i64) {
        tagged_set_i64(o_value, M3Global_GetI64Value(*i_global))
    } elif (d_m3HasFloat && i_global._type == c_m3Type_f32) {
        tagged_set_f32(o_value, M3Global_GetF32Value(*i_global))
    } elif (d_m3HasFloat && i_global._type == c_m3Type_f64) {
        tagged_set_f64(o_value, M3Global_GetF64Value(*i_global))
    } else {
        return m3Err_invalidTypeId
    }
    o_value._type = m3_value_type(i_global._type)
    return m3Err_none
}


def m3_SetGlobal(var i_global : IM3Global; i_value : M3TaggedValue) : M3Result {
    if (i_global == null) { return m3Err_globalLookupFailed }
    if (!i_global.isMutable) { return m3Err_globalNotMutable }
    if (i_global._type != u8(i_value._type)) { return m3Err_globalTypeMismatch }

    if (i_global._type == c_m3Type_i32) {
        M3Global_SetI32Value(*i_global, tagged_get_i32(i_value))
    } elif (i_global._type == c_m3Type_i64) {
        M3Global_SetI64Value(*i_global, tagged_get_i64(i_value))
    } elif (d_m3HasFloat && i_global._type == c_m3Type_f32) {
        M3Global_SetF32Value(*i_global, tagged_get_f32(i_value))
    } elif (d_m3HasFloat && i_global._type == c_m3Type_f64) {
        M3Global_SetF64Value(*i_global, tagged_get_f64(i_value))
    } else {
        return m3Err_invalidTypeId
    }
    return m3Err_none
}


def m3_GetGlobalType(var i_global : IM3Global) : M3ValueType {
    return i_global != null ? m3_value_type(i_global._type) : M3ValueType.c_m3Type_none
}


def v_FindFunction(var i_module : IM3Module; i_info : void?) : void? {
    var i_name : string
    unsafe {
        let namePtr = reinterpret<string const?>(i_info)
        i_name = *namePtr
    }

    for (ii in 0..int(i_module.numFunctions)) {
        let i = u32(ii)
        var f : IM3Function
        unsafe { f = addr(i_module.functions[int(i)]) }
        if (!empty(f.export_name) && f.export_name == i_name) {
            return unsafe(reinterpret<void?>(f))
        }
    }

    for (ii in 0..int(i_module.numFunctions)) {
        let i = u32(ii)
        var f : IM3Function
        unsafe { f = addr(i_module.functions[int(i)]) }
        let isImported = !empty(f.import.moduleUtf8) || !empty(f.import.fieldUtf8)
        if (isImported) {
            continue
        }

        for (jj in 0..int(f.numNames)) {
            let j = u32(jj)
            if (!empty(f.names[j]) && f.names[j] == i_name) {
                return unsafe(reinterpret<void?>(f))
            }
        }
    }

    return null
}


def m3_FindFunction(var o_function : IM3Function&; var i_runtime : IM3Runtime; i_functionName : string) : M3Result {
    d_m3Assert(i_runtime != null)
    var _function : IM3Function

    if (i_runtime.modules == null) {
        o_function = null
        return "no modules loaded"
    }

    unsafe {
        _function = reinterpret<IM3Function>(ForEachModule(i_runtime, @@v_FindFunction, addr<void?>(i_functionName)))
    }

    var result : M3Result = m3Err_none
    if (_function != null) {
        if (_function.compiled == null) {
            result = CompileFunction(_function)
        }
    } else {
        result = m3Error(m3Err_functionLookupFailed, i_runtime, i_runtime.modules, null, "", 0u, "'{i_functionName}'")
    }

    if (result != m3Err_none) {
        _function = null
    }
    o_function = _function
    return result
}


def m3_GetTableFunction(var o_function : IM3Function&; var i_module : IM3Module; i_index : u32) : M3Result {
    if (i_index >= i_module.table0Size) {
        return "function index out of range"
    }

    var _function : IM3Function
    unsafe { _function = i_module.table0[int(i_index)] }
    if (_function != null && _function.compiled == null) {
        let result = CompileFunction(_function)
        if (result != m3Err_none) {
            return result
        }
    }

    o_function = _function
    return m3Err_none
}


def checkStartFunction(var i_module : IM3Module) : M3Result {
    d_m3Assert(i_module != null)
    if (i_module.startFunction >= 0) {
        return m3_RunStart(i_module)
    }
    return m3Err_none
}


def m3_GetArgCount(i_function : IM3Function) : u32 {
    if (i_function != null && i_function.funcType != null) {
        return u32(i_function.funcType.numArgs)
    }
    return 0u
}


def m3_GetRetCount(i_function : IM3Function) : u32 {
    if (i_function != null && i_function.funcType != null) {
        return u32(i_function.funcType.numRets)
    }
    return 0u
}


def m3_GetArgType(var i_function : IM3Function; index : u32) : M3ValueType {
    if (i_function != null) {
        var ft = i_function.funcType
        if (ft != null && index < u32(ft.numArgs)) {
            return m3_value_type(GetFuncTypeParamType(ft, u16(index)))
        }
    }
    return M3ValueType.c_m3Type_none
}


def m3_GetRetType(var i_function : IM3Function; index : u32) : M3ValueType {
    if (i_function != null) {
        var ft = i_function.funcType
        if (ft != null && index < u32(ft.numRets)) {
            return m3_value_type(GetFuncTypeResultType(ft, u16(index)))
        }
    }
    return M3ValueType.c_m3Type_none
}


def GetStackPointerForArgs(var i_function : IM3Function) : u8? {
    unsafe {
        var stack = reinterpret<u64?>(i_function._module.runtime.stack)
        stack += int(i_function.funcType.numRets)
        return reinterpret<u8?>(stack)
    }
}


// Typed Gen2 replacement for C varargs. f32 values are represented in M3TaggedValue
// directly instead of relying on C default argument promotion to f64.
// Deviation: C m3_CallVL cannot count a va_list, so it has no argument-count
// check; the typed array makes the m3_Call check (m3Err_argumentCountMismatch)
// available here as well.
def m3_CallVL(var i_function : IM3Function; i_args : array<M3TaggedValue>) : M3Result {
    var runtime = i_function._module.runtime
    var ftype = i_function.funcType

    if (i_function.compiled == null) {
        return m3Err_missingCompiledCode
    }
    if (length(i_args) != int(ftype.numArgs)) {
        return m3Err_argumentCountMismatch
    }

    // compiled out under the active configuration: d_m3RecordBacktraces == false
    m3StackCheckInit()

    var result = checkStartFunction(i_function._module)
    if (result != m3Err_none) {
        return result
    }

    var s = GetStackPointerForArgs(i_function)
    unsafe {
        for (ii in 0..int(ftype.numArgs)) {
            let i = u32(ii)
            let _type = GetFuncTypeParamType(ftype, u16(i))
            let arg = i_args[ii]
            if (_type == c_m3Type_i32) {
                var dst = reinterpret<i32?>(s)
                let value = tagged_get_i32(arg)
                *dst = value
            } elif (_type == c_m3Type_i64) {
                var dst = reinterpret<i64?>(s)
                let value = tagged_get_i64(arg)
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f32) {
                var dst = reinterpret<f32?>(s)
                let value = tagged_get_f32(arg)
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f64) {
                var dst = reinterpret<f64?>(s)
                let value = tagged_get_f64(arg)
                *dst = value
            } else {
                return "unknown argument type"
            }
            s += 8
        }
    }

    result = RunFunctionCode(i_function)
    ReportNativeStackUsage()
    if (result != m3Err_none) { runtime.lastCalled = null } else { runtime.lastCalled = i_function }
    return result
}


def m3_CallV(var i_function : IM3Function; i_args : array<M3TaggedValue>) : M3Result {
    return m3_CallVL(i_function, i_args)
}


def ReportNativeStackUsage() {
    if (d_m3LogNativeStack) {
        let stackUsed = m3StackGetMax()
        print("Native stack used: {stackUsed}\n")
    }
}


def m3_Call(var i_function : IM3Function; i_argc : u32; i_argptrs : array<void const?>) : M3Result {
    var runtime = i_function._module.runtime
    var ftype = i_function.funcType

    if (i_argc != u32(ftype.numArgs)) { return m3Err_argumentCountMismatch }
    if (i_function.compiled == null) { return m3Err_missingCompiledCode }

    // compiled out under the active configuration: d_m3RecordBacktraces == false
    m3StackCheckInit()

    var result = checkStartFunction(i_function._module)
    if (result != m3Err_none) { return result }

    var s = GetStackPointerForArgs(i_function)
    unsafe {
        for (ii in 0..int(ftype.numArgs)) {
            let i = u32(ii)
            let p = i_argptrs[ii]
            let _type = GetFuncTypeParamType(ftype, u16(i))
            if (_type == c_m3Type_i32) {
                var dst = reinterpret<i32?>(s)
                let src = reinterpret<i32 const?>(p)
                let value = *src
                *dst = value
            } elif (_type == c_m3Type_i64) {
                var dst = reinterpret<i64?>(s)
                let src = reinterpret<i64 const?>(p)
                let value = *src
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f32) {
                var dst = reinterpret<f32?>(s)
                let src = reinterpret<f32 const?>(p)
                let value = *src
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f64) {
                var dst = reinterpret<f64?>(s)
                let src = reinterpret<f64 const?>(p)
                let value = *src
                *dst = value
            } else {
                return "unknown argument type"
            }
            s += 8
        }
    }

    result = RunFunctionCode(i_function)
    ReportNativeStackUsage()
    if (result != m3Err_none) { runtime.lastCalled = null } else { runtime.lastCalled = i_function }
    return result
}


def m3_CallArgv(var i_function : IM3Function; i_argc : u32; i_argv : array<string>) : M3Result {
    var ftype = i_function.funcType
    var runtime = i_function._module.runtime

    if (i_argc != u32(ftype.numArgs)) { return m3Err_argumentCountMismatch }
    if (i_function.compiled == null) { return m3Err_missingCompiledCode }

    // compiled out under the active configuration: d_m3RecordBacktraces == false
    m3StackCheckInit()

    var result = checkStartFunction(i_function._module)
    if (result != m3Err_none) { return result }

    var s = GetStackPointerForArgs(i_function)
    unsafe {
        for (ii in 0..int(ftype.numArgs)) {
            let i = u32(ii)
            let text = i_argv[ii]
            let _type = GetFuncTypeParamType(ftype, u16(i))
            if (_type == c_m3Type_i32) {
                var dst = reinterpret<i32?>(s)
                let value = to_int(text)
                *dst = value
            } elif (_type == c_m3Type_i64) {
                var dst = reinterpret<i64?>(s)
                let value = to_int64(text)
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f32) {
                var dst = reinterpret<f32?>(s)
                let value = to_float(text)
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f64) {
                var dst = reinterpret<f64?>(s)
                let value = to_double(text)
                *dst = value
            } else {
                return "unknown argument type"
            }
            s += 8
        }
    }

    result = RunFunctionCode(i_function)
    ReportNativeStackUsage()
    if (result != m3Err_none) { runtime.lastCalled = null } else { runtime.lastCalled = i_function }
    return result
}


def m3_GetResults(var i_function : IM3Function; i_retc : u32; o_retptrs : array<void?>) : M3Result {
    var ftype = i_function.funcType
    var runtime = i_function._module.runtime

    if (i_retc != u32(ftype.numRets)) { return m3Err_argumentCountMismatch }
    if (i_function != runtime.lastCalled) { return "function not called" }

    var s = unsafe(reinterpret<u8?>(runtime.stack))
    unsafe {
        for (ii in 0..int(ftype.numRets)) {
            let i = u32(ii)
            let p = o_retptrs[ii]
            let _type = GetFuncTypeResultType(ftype, u16(i))
            if (_type == c_m3Type_i32) {
                var dst = reinterpret<i32?>(p)
                let src = reinterpret<i32 const?>(s)
                let value = *src
                *dst = value
            } elif (_type == c_m3Type_i64) {
                var dst = reinterpret<i64?>(p)
                let src = reinterpret<i64 const?>(s)
                let value = *src
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f32) {
                var dst = reinterpret<f32?>(p)
                let src = reinterpret<f32 const?>(s)
                let value = *src
                *dst = value
            } elif (d_m3HasFloat && _type == c_m3Type_f64) {
                var dst = reinterpret<f64?>(p)
                let src = reinterpret<f64 const?>(s)
                let value = *src
                *dst = value
            } else {
                return "unknown return type"
            }
            s += 8
        }
    }

    return m3Err_none
}


def m3_GetResultsVL(var i_function : IM3Function; var o_rets : array<M3TaggedValue>&) : M3Result {
    var runtime = i_function._module.runtime
    var ftype = i_function.funcType
    if (i_function != runtime.lastCalled) {
        return "function not called"
    }

    resize(o_rets, int(ftype.numRets))
    var s = unsafe(reinterpret<u8?>(runtime.stack))
    unsafe {
        for (ii in 0..int(ftype.numRets)) {
            let i = u32(ii)
            let _type = GetFuncTypeResultType(ftype, u16(i))
            o_rets[ii]._type = m3_value_type(_type)
            if (_type == c_m3Type_i32) {
                tagged_set_i32(o_rets[ii], *reinterpret<i32?>(s))
            } elif (_type == c_m3Type_i64) {
                tagged_set_i64(o_rets[ii], *reinterpret<i64?>(s))
            } elif (d_m3HasFloat && _type == c_m3Type_f32) {
                tagged_set_f32(o_rets[ii], *reinterpret<f32?>(s))
            } elif (d_m3HasFloat && _type == c_m3Type_f64) {
                tagged_set_f64(o_rets[ii], *reinterpret<f64?>(s))
            } else {
                return "unknown argument type"
            }
            s += 8
        }
    }
    return m3Err_none
}


def m3_GetResultsV(var i_function : IM3Function; var o_rets : array<M3TaggedValue>&) : M3Result {
    return m3_GetResultsVL(i_function, o_rets)
}










// C formats i_errorMessage with vsnprintf into runtime->error_message and the
// ErrorModule/ErrorRuntime macros pass __FILE__/__LINE__; callers here pass
// an already interpolated string and "", 0 for file and line.
def m3Error(i_result : M3Result; var i_runtime : IM3Runtime; var i_module : IM3Module; var i_function : IM3Function;
            i_file : string; i_lineNum : u32; i_errorMessage : string) : M3Result {
    if (d_m3VerboseErrorMessages && i_runtime != null) {
        i_runtime.error.result = i_result
        i_runtime.error.runtime = i_runtime
        i_runtime.error._module = i_module
        i_runtime.error._function = i_function
        i_runtime.error.file = i_file
        i_runtime.error.line = i_lineNum
        i_runtime.error.message = i_errorMessage
    }
    return i_result
}


def m3_GetErrorInfo(var i_runtime : IM3Runtime; var o_info : M3ErrorInfo&) {
    if (i_runtime != null) {
        o_info = i_runtime.error
        m3_ResetErrorInfo(i_runtime)
    }
}


def m3_ResetErrorInfo(var i_runtime : IM3Runtime) {
    if (i_runtime != null) {
        i_runtime.error = M3ErrorInfo()
        i_runtime.error.message = ""
    }
}


// Deviation: C dereferences i_runtime->memory.mallocated unconditionally; the
// port treats a runtime without linear memory as size 0, no pointer.
def m3_GetMemory(var i_runtime : IM3Runtime; var o_memorySizeInBytes : u32&; i_memoryIndex : u32) : u8? {
    d_m3Assert(i_memoryIndex == 0)
    var memory : u8? = null

    if (i_runtime != null && i_runtime.memory.mallocated != null) {
        let size = u32(i_runtime.memory.mallocated.length)
        o_memorySizeInBytes = size
        if (size != 0) {
            memory = m3MemData(i_runtime.memory.mallocated)
        }
    }

    return memory
}


// Deviation: same null guard as m3_GetMemory; C reads mallocated->length directly.
def m3_GetMemorySize(var i_runtime : IM3Runtime) : u32 {
    if (i_runtime == null || i_runtime.memory.mallocated == null) {
        return 0u
    }
    return u32(i_runtime.memory.mallocated.length)
}


def m3_GetBacktrace(i_runtime : IM3Runtime) : M3BacktraceInfo? {
    // compiled out under the active configuration: d_m3RecordBacktraces == false
    return null
}
