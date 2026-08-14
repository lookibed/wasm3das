options gen2
options indenting = 4

module m3_parse shared public

require ./m3_module.das public


/*
    First m3_parse.c stage only:
      ParseType_Table
      ParseType_Memory
      ParseSection_Start
      ParseSection_Element

    No table parser, module allocation, section dispatcher, import/export parser,
    compiler integration, or function-array access is introduced at this stage.
*/


// ============================================================================
// 1. ParseType_Table
// ============================================================================


[unused_argument(io_module, i_bytes, i_end)]
def public ParseType_Table(io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    let result = m3Err_none
    return result
}


// ============================================================================
// 2. ParseType_Memory
// ============================================================================


def public ParseType_Memory(
    var o_memory : M3MemoryInfo&;
    var io_bytes : bytes_t&;
    i_end : cbytes_t
) : M3Result {
    var result : M3Result
    var flag : u8 = 0u8

    result = ReadLEB_u7(flag, io_bytes, i_end)       // really a u1
    if (!empty(result)) {
        return result
    }

    result = ReadLEB_u32(o_memory.initPages, io_bytes, i_end)
    if (!empty(result)) {
        return result
    }

    o_memory.maxPages = 0u
    if ((u32(flag) & (1u << 0u)) != 0u) {
        result = ReadLEB_u32(o_memory.maxPages, io_bytes, i_end)
        if (!empty(result)) {
            return result
        }
    }

    o_memory.pageSize = 0u
    if ((u32(flag) & (1u << 3u)) != 0u) {
        var logPageSize : u32 = 0u
        result = ReadLEB_u32(logPageSize, io_bytes, i_end)
        if (!empty(result)) {
            return result
        }
        o_memory.pageSize = 1u << logPageSize
    }

    return result
}


// ============================================================================
// 3. ParseSection_Start
// ============================================================================


def public ParseSection_Start(
    var io_module : IM3Module;
    var i_bytes : bytes_t;
    i_end : cbytes_t
) : M3Result {
    var result : M3Result
    var startFuncIndex : u32 = 0u

    result = ReadLEB_u32(startFuncIndex, i_bytes, i_end)
    if (!empty(result)) {
        return result
    }

    if (startFuncIndex < io_module.numFunctions) {
        io_module.startFunction = i32(startFuncIndex)
    } else {
        result = "start function index out of bounds"
    }

    return result
}


// ============================================================================
// 4. ParseSection_Element
// ============================================================================


def public ParseSection_Element(
    var io_module : IM3Module;
    var i_bytes : bytes_t;
    i_end : cbytes_t
) : M3Result {
    var result : M3Result
    var numSegments : u32 = 0u

    result = ReadLEB_u32(numSegments, i_bytes, i_end)
    if (!empty(result)) {
        return result
    }

    if (numSegments > u32(d_m3MaxSaneElementSegments)) {
        return "too many element segments"
    }

    io_module.elementSection = i_bytes
    // C stores cbytes_t in the bytes_t field; preserve the pointer bits explicitly.
    io_module.elementSectionEnd = unsafe(reinterpret<bytes_t>(intptr(i_end)))
    io_module.numElementSegments = numSegments

    return result
}
