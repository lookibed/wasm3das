options gen2
options indenting = 4
// Parsing runs once per module: automatic inlining costs startup only.
options never_inline = true

module m3_parse shared public

require ./m3_core.das
require ./m3_types.das
require ./m3_env.das public
require ./m3_module.das
require ./m3_compile.das

// Conservative Gen2 port of m3_parse.c.
// Parsing order, ownership transfers, partial-state side effects, and M3Result
// propagation intentionally follow the C implementation.
//
// Port adaptations applied uniformly (each documented here once):
// - C handlers take `const u8 * bytes` by value and advance their own copy:
//   the cursor is copied to a local `var bytes : bytes_t` with the const
//   stripped via reinterpret (Read* functions require a mutable cursor).
// - C FreeUtf8String of module-owned strings is a no-op here: Daslang strings
//   own their storage and assignment replaces (frees) the previous value.
// - `var result : M3Result` is spelled explicitly because inference through
//   the const-string return of the readers yields a const-qualified local.
// - C m3_AllocArray(STRUCT, N) macro expands at the call site to a sized
//   m3_Malloc_Impl call (see m3_core.das allocation macro-family note).


def ParseType_Table(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    return m3Err_none
}


def ParseType_Memory(var o_memory : M3MemoryInfo&; var io_bytes : bytes_t&; i_end : cbytes_t) : M3Result {
    var flag : u8 = 0
    var result : M3Result = ReadLEB_u7(flag, io_bytes, i_end)
    if (result != m3Err_none) { return result }

    result = ReadLEB_u32(o_memory.initPages, io_bytes, i_end)
    if (result != m3Err_none) { return result }

    o_memory.maxPages = 0
    if ((u32(flag) & (1u << 0)) != 0) {
        result = ReadLEB_u32(o_memory.maxPages, io_bytes, i_end)
        if (result != m3Err_none) { return result }
    }

    o_memory.pageSize = 0
    if ((u32(flag) & (1u << 3)) != 0) {
        var logPageSize : u32 = 0
        result = ReadLEB_u32(logPageSize, io_bytes, i_end)
        if (result != m3Err_none) { return result }
        o_memory.pageSize = 1u << logPageSize
    }

    return m3Err_none
}


def ParseSection_Type(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var ftype : IM3FuncType = null
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numTypes : u32 = 0

    var result : M3Result = ReadLEB_u32(numTypes, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numTypes > u32(d_m3MaxSaneTypesCount)) {
        return "too many types"
    }

    if (numTypes != 0) {
        unsafe {
            io_module.funcTypes = reinterpret<IM3FuncType?>(
                m3_Malloc_Impl(uint64(typeinfo sizeof(type<IM3FuncType>)) * uint64(numTypes)))
        }
        if (io_module.funcTypes == null) {
            return m3Err_mallocFailed
        }
        io_module.numFuncTypes = numTypes

        for (i in 0u..numTypes) {
            var form : i8 = 0
            result = ReadLEB_i7(form, bytes, i_end)
            if (result != m3Err_none) { break }
            if (form != -32) {
                result = m3Err_wasmMalformed
                break
            }

            var numArgs : u32 = 0
            result = ReadLEB_u32(numArgs, bytes, i_end)
            if (result != m3Err_none) { break }
            if (numArgs > u32(d_m3MaxSaneFunctionArgRetCount)) {
                result = m3Err_tooManyArgsRets
                break
            }

            var argTypes : array<u8>
            resize(argTypes, int(numArgs) + 1)

            for (a in 0u..numArgs) {
                var wasmType : i8 = 0
                var argType : u8 = 0
                result = ReadLEB_i7(wasmType, bytes, i_end)
                if (result != m3Err_none) { break }
                result = NormalizeType(argType, wasmType)
                if (result != m3Err_none) { break }
                argTypes[int(a)] = argType
            }
            if (result != m3Err_none) { break }

            var numRets : u32 = 0
            result = ReadLEB_u32(numRets, bytes, i_end)
            if (result != m3Err_none) { break }
            if (u64(numRets) + u64(numArgs) > u64(d_m3MaxSaneFunctionArgRetCount)) {
                result = m3Err_tooManyArgsRets
                break
            }

            result = AllocFuncType(ftype, numRets + numArgs)
            if (result != m3Err_none) { break }
            ftype.numArgs = u16(numArgs)
            ftype.numRets = u16(numRets)

            var types = unsafe(addr(ftype.types[0]))

            for (r in 0u..numRets) {
                var wasmType : i8 = 0
                var retType : u8 = 0
                result = ReadLEB_i7(wasmType, bytes, i_end)
                if (result != m3Err_none) { break }
                result = NormalizeType(retType, wasmType)
                if (result != m3Err_none) { break }
                unsafe { types[r] = retType }            }
            if (result != m3Err_none) { break }

            for (a in 0u..numArgs) {
                unsafe { types[numRets + a] = argTypes[int(a)] }
            }


            Environment_AddFuncType(io_module.environment, ftype)
            unsafe { io_module.funcTypes[i] = ftype }
            ftype = null
        }
    }

    if (result != m3Err_none) {
        if (ftype != null) {
            m3_Free_Impl(unsafe(reinterpret<void?>(ftype)))
            ftype = null
        }
        m3_Free_Impl(unsafe(reinterpret<void?>(io_module.funcTypes)))
        io_module.funcTypes = null
        io_module.numFuncTypes = 0
    }

    return result
}


def ParseSection_Function(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numFunctions : u32 = 0
    var result : M3Result = ReadLEB_u32(numFunctions, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numFunctions > u32(d_m3MaxSaneFunctionsCount)) {
        return "too many functions"
    }

    result = Module_PreallocFunctions(io_module, io_module.numFunctions + numFunctions)
    if (result != m3Err_none) { return result }

    for (_i in 0u..numFunctions) {
        var funcTypeIndex : u32 = 0
        result = ReadLEB_u32(funcTypeIndex, bytes, i_end)
        if (result != m3Err_none) { return result }

        result = Module_AddFunction(io_module, funcTypeIndex, null)
        if (result != m3Err_none) { return result }
    }

    return m3Err_none
}


def ParseSection_Import(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var importInfo = M3ImportInfo()
    var numImports : u32 = 0

    var result : M3Result = ReadLEB_u32(numImports, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numImports > u32(d_m3MaxSaneImportsCount)) {
        return "too many imports"
    }

    result = Module_PreallocFunctions(io_module, numImports)
    if (result != m3Err_none) { return result }

    for (_i in 0u..numImports) {
        var importKind : u8 = 0

        result = Read_utf8(importInfo.moduleUtf8, bytes, i_end)
        if (result != m3Err_none) { break }
        result = Read_utf8(importInfo.fieldUtf8, bytes, i_end)
        if (result != m3Err_none) { break }
        result = Read_u8(importKind, bytes, i_end)
        if (result != m3Err_none) { break }


        if (importKind == d_externalKind_function) {
            var typeIndex : u32 = 0
            result = ReadLEB_u32(typeIndex, bytes, i_end)
            if (result != m3Err_none) { break }

            result = Module_AddFunction(io_module, typeIndex, unsafe(addr(importInfo)))
            if (result != m3Err_none) { break }
            importInfo = M3ImportInfo()
            io_module.numFuncImports++

        } elif (importKind == d_externalKind_table) {
            // C implementation intentionally leaves table import parsing unimplemented.

        } elif (importKind == d_externalKind_memory) {
            result = ParseType_Memory(io_module.memoryInfo, bytes, i_end)
            if (result != m3Err_none) { break }
            io_module.memoryImported = true
            io_module.memoryImport = importInfo
            importInfo = M3ImportInfo()

        } elif (importKind == d_externalKind_global) {
            var waType : i8 = 0
            // C local `type` renamed to `_type`: `type` is a daslang keyword.
            var _type : u8 = 0
            var isMutable : u8 = 0

            result = ReadLEB_i7(waType, bytes, i_end)
            if (result != m3Err_none) { break }
            result = NormalizeType(_type, waType)
            if (result != m3Err_none) { break }
            result = ReadLEB_u7(isMutable, bytes, i_end)
            if (result != m3Err_none) { break }

            var global : IM3Global = null
            result = Module_AddGlobal(io_module, global, _type, isMutable != 0, true)
            if (result != m3Err_none) { break }
            global.import = importInfo
            importInfo = M3ImportInfo()

        } else {
            result = m3Err_wasmMalformed
            break
        }

        // C frees the unadopted import strings here; string assignment frees.
        importInfo = M3ImportInfo()
    }

    return result
}


def ParseSection_Export(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var utf8 : cstr_t = ""
    var numExports : u32 = 0

    var result : M3Result = ReadLEB_u32(numExports, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numExports > u32(d_m3MaxSaneExportsCount)) {
        return "too many exports"
    }

    for (_i in 0u..numExports) {
        var exportKind : u8 = 0
        var index : u32 = 0

        result = Read_utf8(utf8, bytes, i_end)
        if (result != m3Err_none) { break }
        result = Read_u8(exportKind, bytes, i_end)
        if (result != m3Err_none) { break }
        result = ReadLEB_u32(index, bytes, i_end)
        if (result != m3Err_none) { break }


        if (exportKind == d_externalKind_function) {
            if (index >= io_module.numFunctions) {
                result = m3Err_wasmMalformed
                break
            }
            var func : IM3Function
            unsafe { func = addr(io_module.functions[index]) }
            if (u32(func.numNames) < d_m3MaxDuplicateFunctionImpl) {
                func.names[int(func.numNames)] = utf8
                func.numNames = u16(u32(func.numNames) + 1u)
                func.export_name = utf8
                utf8 = ""
            }

        } elif (exportKind == d_externalKind_global) {
            if (index >= io_module.numGlobals) {
                result = m3Err_wasmMalformed
                break
            }
            var global : IM3Global
            unsafe { global = addr(io_module.globals[index]) }
            global.name = utf8
            utf8 = ""

        } elif (exportKind == d_externalKind_memory) {
            io_module.memoryExportName = utf8
            utf8 = ""

        } elif (exportKind == d_externalKind_table) {
            io_module.table0ExportName = utf8
            utf8 = ""
        }

        // C: FreeUtf8String(utf8) of the unadopted name; strings free on drop.
    }

    return result
}


def ParseSection_Start(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var startFuncIndex : u32 = 0
    let result : M3Result = ReadLEB_u32(startFuncIndex, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (startFuncIndex < io_module.numFunctions) {
        io_module.startFunction = i32(startFuncIndex)
        return m3Err_none
    }

    return "start function index out of bounds"
}


def Parse_InitExpr(var io_module : IM3Module; var io_bytes : bytes_t&; i_end : cbytes_t) : M3Result {
    var compilation = M3Compilation(
        runtime = null,
        _module = io_module,
        wasm = io_bytes,
        wasmEnd = unsafe(reinterpret<bytes_t>(i_end))
    )

    var compilationPtr : IM3Compilation
    unsafe { compilationPtr = addr(compilation) }
    let result = CompileBlockStatements(compilationPtr)
    io_bytes = compilation.wasm
    return result
}


def ParseSection_Element(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numSegments : u32 = 0
    let result : M3Result = ReadLEB_u32(numSegments, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numSegments > u32(d_m3MaxSaneElementSegments)) {
        return "too many element segments"
    }

    io_module.elementSection = bytes
    io_module.elementSectionEnd = unsafe(reinterpret<bytes_t>(i_end))
    io_module.numElementSegments = numSegments
    return m3Err_none
}


def ParseSection_Code(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numFunctions : u32 = 0
    var result : M3Result = ReadLEB_u32(numFunctions, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numFunctions != io_module.numFunctions - io_module.numFuncImports) {
        return "mismatched function count in code section"
    }

    for (f in 0u..numFunctions) {
        var start = bytes
        var size : u32 = 0
        result = ReadLEB_u32(size, bytes, i_end)
        if (result != m3Err_none) { break }

        if (size != 0) {
            unsafe { bytes += size }

            if (intptr(bytes) <= intptr(i_end)) {
                var func = Module_GetFunction(io_module, f + io_module.numFuncImports)
                func._module = io_module
                func.wasm = start
                func.wasmEnd = bytes
            } else {
                result = m3Err_wasmSectionOverrun
                break
            }
        }
    }

    if (result == m3Err_none && intptr(bytes) != intptr(i_end)) {
        result = m3Err_wasmSectionUnderrun
    }

    return result
}


def ParseSection_Data(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numDataSegments : u32 = 0
    var result : M3Result = ReadLEB_u32(numDataSegments, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numDataSegments > u32(d_m3MaxSaneDataSegments)) {
        return "too many data segments"
    }

    unsafe {
        io_module.dataSegments = reinterpret<M3DataSegment?>(
            m3_Malloc_Impl(uint64(typeinfo sizeof(type<M3DataSegment>)) * uint64(numDataSegments)))
    }
    if (io_module.dataSegments == null) {
        return m3Err_mallocFailed
    }
    io_module.numDataSegments = numDataSegments

    for (i in 0u..numDataSegments) {
        var segment : M3DataSegment?
        unsafe { segment = addr(io_module.dataSegments[i]) }

        result = ReadLEB_u32(segment.memoryRegion, bytes, i_end)
        if (result != m3Err_none) { break }

        segment.initExpr = bytes
        result = Parse_InitExpr(io_module, bytes, i_end)
        if (result != m3Err_none) { break }
        segment.initExprSize = u32(intptr(bytes) - intptr(segment.initExpr))

        if (segment.initExprSize <= 1) {
            result = m3Err_wasmMissingInitExpr
            break
        }

        result = ReadLEB_u32(segment.size, bytes, i_end)
        if (result != m3Err_none) { break }
        segment.data = bytes


        unsafe { bytes += segment.size }
        if (intptr(bytes) > intptr(i_end)) {
            result = "data segment underflow"
            break
        }
    }

    return result
}


def ParseSection_Memory(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numMemories : u32 = 0
    // `let`, not `var`: since the ParseType_Memory result is discarded (see
    // below), nothing reassigns this local.
    let result : M3Result = ReadLEB_u32(numMemories, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numMemories > 1) {
        return m3Err_tooManyMemorySections
    }

    // C quirk, preserved: this is the one ParseType_Memory call site without
    // the `_` error-propagating macro, so a truncated memory type leaves
    // io_module->memoryInfo half-written and the section still succeeds.
    // Assigning the result to `result` (which _catch would return) would make
    // the port stricter than C.
    ParseType_Memory(io_module.memoryInfo, bytes, i_end)
    return result
}


def ParseSection_Global(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var numGlobals : u32 = 0
    var result : M3Result = ReadLEB_u32(numGlobals, bytes, i_end)
    if (result != m3Err_none) { return result }

    if (numGlobals > u32(d_m3MaxSaneGlobalsCount)) {
        return "too many globals"
    }

    for (_i in 0u..numGlobals) {
        var waType : i8 = 0
        // C local `type` renamed to `_type`: `type` is a daslang keyword.
        var _type : u8 = 0
        var isMutable : u8 = 0

        result = ReadLEB_i7(waType, bytes, i_end)
        if (result != m3Err_none) { break }
        result = NormalizeType(_type, waType)
        if (result != m3Err_none) { break }
        result = ReadLEB_u7(isMutable, bytes, i_end)
        if (result != m3Err_none) { break }


        var global : IM3Global = null
        result = Module_AddGlobal(io_module, global, _type, isMutable != 0, false)
        if (result != m3Err_none) { break }

        global.initExpr = bytes
        result = Parse_InitExpr(io_module, bytes, i_end)
        if (result != m3Err_none) { break }
        global.initExprSize = u32(intptr(bytes) - intptr(global.initExpr))

        if (global.initExprSize <= 1) {
            result = m3Err_wasmMissingInitExpr
            break
        }
    }

    return result
}


def ParseSection_Name(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var name : cstr_t = ""
    var result : M3Result = m3Err_none

    while (intptr(bytes) < intptr(i_end)) {
        var nameType : u8 = 0
        var payloadLength : u32 = 0

        result = ReadLEB_u7(nameType, bytes, i_end)
        if (result != m3Err_none) { break }
        result = ReadLEB_u32(payloadLength, bytes, i_end)
        if (result != m3Err_none) { break }

        var start = bytes
        if (nameType == 1) {
            var numNames : u32 = 0
            result = ReadLEB_u32(numNames, bytes, i_end)
            if (result != m3Err_none) { break }

            if (numNames > u32(d_m3MaxSaneFunctionsCount)) {
                result = "too many names"
                break
            }

            for (_i in 0u..numNames) {
                var index : u32 = 0
                result = ReadLEB_u32(index, bytes, i_end)
                if (result != m3Err_none) { break }
                result = Read_utf8(name, bytes, i_end)
                if (result != m3Err_none) { break }

                if (index < io_module.numFunctions) {
                    var func : IM3Function
                    unsafe { func = addr(io_module.functions[index]) }
                    if (func.numNames == 0) {
                        func.names[0] = name
                        func.numNames = 1u
                        name = ""
                    }
                }

                // C: FreeUtf8String(name) of the unadopted name; strings free on drop.
            }
            if (result != m3Err_none) { break }
        }

        unsafe { bytes = start + payloadLength }
    }

    return result
}


def ParseSection_Custom(var io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var bytes : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    var name : cstr_t = ""
    var result : M3Result = Read_utf8(name, bytes, i_end)
    if (result != m3Err_none) {
        return result
    }


    if (name == "name") {
        result = ParseSection_Name(io_module, bytes, i_end)
    } elif (io_module.environment.customSectionHandler != null) {
        result = io_module.environment.customSectionHandler(io_module, name, bytes, i_end)
    }

    return result
}


def ParseModuleSection(var o_module : IM3Module; i_sectionType : u8; i_bytes : bytes_t; i_numBytes : u32) : M3Result {
    let end = unsafe(i_bytes + i_numBytes)

    if (i_sectionType == 0) {
        return ParseSection_Custom(o_module, i_bytes, end)
    } elif (i_sectionType == 1) {
        return ParseSection_Type(o_module, i_bytes, end)
    } elif (i_sectionType == 2) {
        return ParseSection_Import(o_module, i_bytes, end)
    } elif (i_sectionType == 3) {
        return ParseSection_Function(o_module, i_bytes, end)
    } elif (i_sectionType == 5) {
        return ParseSection_Memory(o_module, i_bytes, end)
    } elif (i_sectionType == 6) {
        return ParseSection_Global(o_module, i_bytes, end)
    } elif (i_sectionType == 7) {
        return ParseSection_Export(o_module, i_bytes, end)
    } elif (i_sectionType == 8) {
        return ParseSection_Start(o_module, i_bytes, end)
    } elif (i_sectionType == 9) {
        return ParseSection_Element(o_module, i_bytes, end)
    } elif (i_sectionType == 10) {
        return ParseSection_Code(o_module, i_bytes, end)
    } elif (i_sectionType == 11) {
        return ParseSection_Data(o_module, i_bytes, end)
    }

    return m3Err_none
}


def public m3_ParseModule(var i_environment : IM3Environment; var o_module : IM3Module&; i_bytes : cbytes_t; i_numBytes : u32) : M3Result {
    // C local `module` renamed to `_module`: `module` is a daslang keyword.
    var _module : IM3Module
    var result : M3Result


    // C: module = m3_AllocStruct (M3Module) - zeroed host allocation; released
    // with m3_Free_Impl in m3_FreeModule (docs/memory-ownership.md).
    unsafe {
        _module = reinterpret<IM3Module>(m3_Malloc_Impl(u64(typeinfo sizeof(type<M3Module>))))
    }
    if (_module == null) {
        o_module = null
        return m3Err_mallocFailed
    }

    _module.name = ".unnamed"
    _module.startFunction = -1
    _module.environment = i_environment

    var pos : bytes_t = unsafe(reinterpret<bytes_t>(i_bytes))
    // Pointer advance via intptr math: daslang refuses nested ptr_add inside unsafe().
    var end : bytes_t = unsafe(reinterpret<bytes_t>(intptr(i_bytes) + u64(i_numBytes)))

    _module.wasmStart = pos
    _module.wasmEnd = end

    var magic : u32 = 0
    var version : u32 = 0

    result = Read_u32(magic, pos, end)
    if (result == m3Err_none) {
        result = Read_u32(version, pos, end)
    }
    if (result == m3Err_none && magic != 0x6d736100u) {
        result = m3Err_wasmMalformed
    }
    if (result == m3Err_none && version != 1u) {
        result = m3Err_incompatibleWasmVersion
    }

    let sectionsOrder = [1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8, 9u8, 12u8, 10u8, 11u8, 0u8]
    // C uint8_t expectedSection: daslang has no u8 arithmetic, int scalar.
    var expectedSection : int = 0

    while (result == m3Err_none && intptr(pos) < intptr(end)) {
        var section : u8 = 0
        result = ReadLEB_u7(section, pos, end)
        if (result != m3Err_none) { break }

        if (section != 0) {
            var found = false
            while (!found) {
                if (expectedSection >= 13) {
                    result = m3Err_misorderedWasmSection
                    break
                }

                let expected = sectionsOrder[expectedSection]
                expectedSection++
                if (expected == section) {
                    found = true
                } elif (expectedSection >= 12) {
                    result = m3Err_misorderedWasmSection
                    break
                }
            }
            if (result != m3Err_none) { break }
        }

        var sectionLength : u32 = 0
        result = ReadLEB_u32(sectionLength, pos, end)
        if (result != m3Err_none) { break }

        var sectionEnd = unsafe(pos + sectionLength)
        if (intptr(sectionEnd) > intptr(end)) {
            result = m3Err_wasmMalformed
            break
        }

        result = ParseModuleSection(_module, section, pos, sectionLength)
        if (result != m3Err_none) { break }

        pos = sectionEnd
    }

    if (result != m3Err_none) {
        m3_FreeModule(_module)
        _module = null
    }

    o_module = _module
    return result
}
