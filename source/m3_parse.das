options gen2
options indenting = 4
// Eden: the upstream `options never_inline = true` (parsing runs once per
// module, so automatic inlining costs startup only) is dropped: the option is
// untested in the editor (DESIGN.md section 1) and the interpreter is the
// only tier of the Eden port.

module m3_parse shared public

require modules/wasm3das/source/m3_core            // Eden: project-root-relative path (upstream: ./m3_core.das)
require modules/wasm3das/source/m3_types           // Eden: project-root-relative path (upstream: ./m3_types.das)
require modules/wasm3das/source/m3_env public      // Eden: project-root-relative path (upstream: ./m3_env.das)
require modules/wasm3das/source/m3_module          // Eden: project-root-relative path (upstream: ./m3_module.das)
require modules/wasm3das/source/m3_function        // Eden: AllocFuncType, FreeImportInfo (upstream: through m3_env)
require modules/wasm3das/source/m3_compile         // Eden: project-root-relative path (upstream: ./m3_compile.das)

// Conservative Gen2 port of m3_parse.c.
// Parsing order, ownership transfers, partial-state side effects, and M3Result
// propagation intentionally follow the C implementation.
//
// Port adaptations applied uniformly (each documented here once):
// - C handlers take `bytes_t i_bytes` by value and advance it: the Eden
//   handlers copy the index into `var pos : bytes_t = i_bytes` (the m3_core
//   readers take the cursor by reference).
// - C's `m3_Free (utf8)` / `m3_Free (name)` of module-owned strings is a
//   no-op here: Daslang strings own their storage and assignment replaces
//   (frees) the previous value.
// - `var result : M3Result` is spelled explicitly because inference through
//   the const-string return of the readers yields a const-qualified local.
// - C m3_AllocArray(STRUCT, N) macro expands at the call site to a sized
//   m3_Malloc_Impl call (see m3_core.das allocation macro-family note).

/*
    Eden: deviations from the upstream port (.upstream/source/m3_parse.das)
    for the EdenSpark sandbox (docs/eden-port/DESIGN.md sections 4.1, 5, 6).
    The sandbox has no raw pointers: the runtime owns every arena, a module,
    function, global or func type is a handle into rt.modules /
    rt.functions / rt.globals / rt.funcTypes (-1 = NULL), and a byte cursor
    is an index into the module's copy of the binary.
      - requires are Eden-project-root relative (DESIGN section 6); m3_env
        stays a public re-export; m3_function is required directly for
        AllocFuncType and FreeImportInfo. The upstream `options
        never_inline` is dropped (see the options).
      - m3_ParseModule(var rt : M3Runtime; i_bytes : array<u8>) :
        tuple<M3Result; IM3Module> (DESIGN 4.1; C: the environment, an
        IM3Module out-pointer, the byte pointer and its length). The module
        is a new slot of rt.modules registered with `runtime = -1` (not
        linked; m3_LoadModule links it). The module owns `wasm`, a copy of
        the binary (C keeps a pointer into the caller's bytes), and every
        position (wasmStart/wasmEnd, elementSection/elementSectionEnd, a
        function's wasm/wasmEnd, a global's or data segment's initExpr, a
        data segment's data) is an index into that copy. The environment
        of C (module->environment) is rt.environment, so the custom section
        handler is read from there. On failure C frees the module
        (m3_FreeModule) and returns NULL: here m3_FreeModule leaves a
        released slot (handles into rt.modules are never reused) and the
        returned handle is -1. The func types, functions and globals the
        failed parse appended stay in the arenas as released slots, as
        m3_FreeModule leaves them.
      - every section parser takes the runtime first, then the module
        handle, then C's `i_bytes, i_end` as indices into
        rt.modules[io_module].wasm; the C by-value cursor is a local `pos`.
        The byte readers of m3_core take the array first
        (`(bytes; var o_value; var io_pos; i_end)`, DESIGN section 6).
      - ParseType_Memory(bytes, o_memory, io_bytes, i_end): the byte array
        first, then C's parameters (the reader convention of m3_core).
        ParseType_Table(rt, io_module, i_bytes, i_end) keeps C's empty body.
      - ParseModuleSection: C's `s_parsers` table of function pointers is an
        if-chain in the same index order (as upstream); its NULL entries
        (4: Table, 12: DataCount; C has no ParseSection_Table or
        ParseSection_DataCount) and every id above 12 skip the section.
      - ParseSection_Type: the module's `funcTypes` handle array is
        allocated with m3_Malloc_Impl and filled with -1 (C: calloc's NULL
        pointers; an int element's default 0 would be a valid handle).
        AllocFuncType appends a slot to rt.funcTypes and
        Environment_AddFuncType interns it (the survivor is the existing
        equal type, whose handle the module stores). C's `m3_Free (ftype)`
        on error (a type allocated but not yet interned) pops that last
        slot of the arena.
      - Module_AddFunction takes the explicit `i_isImport` flag (DESIGN 4.1,
        m3_module): ParseSection_Function passes `M3ImportInfo(), false` for
        C's NULL, ParseSection_Import the import and `true` for `& import`.
        Imports are added first and counted in numFuncImports, which is how
        m3_env tells an import (index < numFuncImports).
      - exports (DESIGN 4.1, the NULL-vs-"" rule): ParseSection_Export sets
        a function's `isExported` together with export_name (only when C
        sets export_name, i.e. numNames < d_m3MaxDuplicateFunctionImpl) and
        a global's `isExported` together with its name, so a function or
        global exported as "" is found by "". The memory and table export
        names stay plain strings (m3_types has no flag for them; C's NULL
        and "" read the same there).
      - Parse_InitExpr: C builds a stack M3Compilation with runtime NULL and
        only module/wasm/wasmEnd set. The compilation is rt.compilation
        here, so it is saved, replaced by a fresh M3Compilation (runtime
        -1, page -1: nothing is emitted, C's `o->page` NULL) for the walk,
        and restored afterwards. As C, the walk is not guarded: m3Error
        records into rt.error where C's NULL runtime records nothing
        (m3_types).
      - ParseSection_Code: a body's range is recorded as wasm/wasmEnd
        indices and moduleIdx is set, only for bodies with size != 0, as C
        does. ownsWasmCode stays false: C's assignment is commented out
        (the module owns the bytes).
      - pointer sums that may pass the end (`pos + sectionLength`, a code
        body or data segment size, a name subsection's payloadLength) are
        computed in i64, so a u32 length near 4 GiB cannot wrap an int
        index; the C comparisons against the end are unchanged. In
        ParseSection_Name a position past the end ends the loop, as C's
        `i_bytes < i_end` does; the index is clamped to the end.
      - m3_ParseModule's section-order loop is C's
        `while (sectionsOrder[expectedSection++] != section)` with the
        throw at `expectedSection >= 12`; the upstream extra guard
        (`expectedSection >= 13`, unreachable) is not kept.
    Everything else (names, order, control flow, checks, their order and
    the error strings) is the C of m3_parse.c.
*/


def ParseType_Table(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    let result : M3Result = m3Err_none

    return result
}


// Eden: the byte array first, then C's parameters (see the header)
def ParseType_Memory(bytes : array<u8>; var o_memory : M3MemoryInfo&; var io_bytes : bytes_t&; i_end : cbytes_t) : M3Result {
    var flag : u8 = 0u8

    var result : M3Result = ReadLEB_u7(bytes, flag, io_bytes, i_end)   // really a u1
    if (result != m3Err_none) {
        return result
    }
    result = ReadLEB_u32(bytes, o_memory.initPages, io_bytes, i_end)
    if (result != m3Err_none) {
        return result
    }

    o_memory.maxPages = 0u
    if ((u32(flag) & (1u << 0u)) != 0u) {
        result = ReadLEB_u32(bytes, o_memory.maxPages, io_bytes, i_end)
        if (result != m3Err_none) {
            return result
        }
    }

    o_memory.pageSize = 0u
    if ((u32(flag) & (1u << 3u)) != 0u) {
        var logPageSize : u32 = 0u
        result = ReadLEB_u32(bytes, logPageSize, io_bytes, i_end)
        if (result != m3Err_none) {
            return result
        }
        o_memory.pageSize = 1u << logPageSize
    }

    return result
}


def ParseSection_Type(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var ftype : IM3FuncType = -1
    var pos : bytes_t = i_bytes

    // C: _try {
    var numTypes : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numTypes, pos, i_end)

    if (result == m3Err_none && numTypes > u32(d_m3MaxSaneTypesCount)) {
        result = "too many types"   // C: _throwif
    }

    if (result == m3Err_none && numTypes != 0u) {
        // table of IM3FuncType (that point to the actual M3FuncType struct in the Environment)
        // Eden: handles, -1 = NULL (C: calloc's NULL pointers; see the header)
        m3_Malloc_Impl(rt.modules[io_module].funcTypes, int(numTypes))
        for (i in range(int(numTypes))) {
            rt.modules[io_module].funcTypes[i] = -1
        }
        // C: _throwifnull (io_module->funcTypes); Eden: allocation cannot fail observably (m3_core)
        rt.modules[io_module].numFuncTypes = numTypes

        for (i in range(int(numTypes))) {
            var form : i8 = i8(0)
            result = ReadLEB_i7(rt.modules[io_module].wasm, form, pos, i_end)
            if (result != m3Err_none) {
                break
            }
            if (form != i8(-32)) {   // for Wasm MVP
                result = m3Err_wasmMalformed   // C: _throwif
                break
            }

            var numArgs : u32 = 0u
            result = ReadLEB_u32(rt.modules[io_module].wasm, numArgs, pos, i_end)
            if (result != m3Err_none) {
                break
            }

            if (numArgs > u32(d_m3MaxSaneFunctionArgRetCount)) {
                result = m3Err_tooManyArgsRets   // C: _throwif
                break
            }
            var argTypes : array<u8>   // C: u8 argTypes[numArgs+1]; // make ubsan happy
            resize(argTypes, int(numArgs) + 1)
            for (a in range(int(numArgs))) {
                var wasmType : i8 = i8(0)
                var argType : u8 = 0u8
                result = ReadLEB_i7(rt.modules[io_module].wasm, wasmType, pos, i_end)
                if (result != m3Err_none) {
                    break
                }
                result = NormalizeType(argType, wasmType)
                if (result != m3Err_none) {
                    break
                }

                argTypes[a] = argType
            }
            if (result != m3Err_none) {
                break
            }

            var numRets : u32 = 0u
            result = ReadLEB_u32(rt.modules[io_module].wasm, numRets, pos, i_end)
            if (result != m3Err_none) {
                break
            }
            if (u64(numRets) + u64(numArgs) > u64(d_m3MaxSaneFunctionArgRetCount)) {
                result = m3Err_tooManyArgsRets   // C: _throwif
                break
            }

            result = AllocFuncType(rt, ftype, numRets + numArgs)
            if (result != m3Err_none) {
                break
            }
            rt.funcTypes[ftype].numArgs = u16(numArgs)
            rt.funcTypes[ftype].numRets = u16(numRets)

            for (r in range(int(numRets))) {
                var wasmType : i8 = i8(0)
                var retType : u8 = 0u8
                result = ReadLEB_i7(rt.modules[io_module].wasm, wasmType, pos, i_end)
                if (result != m3Err_none) {
                    break
                }
                result = NormalizeType(retType, wasmType)
                if (result != m3Err_none) {
                    break
                }

                rt.funcTypes[ftype].types[r] = retType
            }
            if (result != m3Err_none) {
                break
            }
            // C: memcpy (ftype->types + numRets, argTypes, numArgs)
            for (a in range(int(numArgs))) {
                rt.funcTypes[ftype].types[int(numRets) + a] = argTypes[a]
            }

            Environment_AddFuncType(rt, ftype)
            rt.modules[io_module].funcTypes[i] = ftype
            ftype = -1   // ownership transferred to environment
        }
    }

    // C: } _catch:
    if (result != m3Err_none) {
        // C: m3_Free (ftype); Eden: the allocated, not yet interned type is
        // the last slot of the arena (see the header)
        if (ftype != -1 && ftype == length(rt.funcTypes) - 1) {
            pop(rt.funcTypes)
        }
        ftype = -1
        // FIX: M3FuncTypes in the table are leaked
        m3_Free_Impl(rt.modules[io_module].funcTypes)
        rt.modules[io_module].numFuncTypes = 0u
    }

    return result
}


def ParseSection_Function(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var numFunctions : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numFunctions, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (numFunctions > u32(d_m3MaxSaneFunctionsCount)) {
        return "too many functions"   // C: _throwif
    }

    result = Module_PreallocFunctions(rt, io_module, rt.modules[io_module].numFunctions + numFunctions)
    if (result != m3Err_none) {
        return result
    }

    for (_i in range(int(numFunctions))) {
        var funcTypeIndex : u32 = 0u
        result = ReadLEB_u32(rt.modules[io_module].wasm, funcTypeIndex, pos, i_end)
        if (result != m3Err_none) {
            return result
        }

        // C: Module_AddFunction (io_module, funcTypeIndex, NULL /* import info */)
        // Eden: the explicit i_isImport flag (see the header)
        result = Module_AddFunction(rt, io_module, funcTypeIndex, M3ImportInfo(), false)
        if (result != m3Err_none) {
            return result
        }
    }

    return result
}


def ParseSection_Import(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var importInfo = M3ImportInfo()   // C local `import`: a gen2 keyword

    var numImports : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numImports, pos, i_end)

    if (result == m3Err_none && numImports > u32(d_m3MaxSaneImportsCount)) {
        result = "too many imports"   // C: _throwif
    }

    // Most imports are functions, so we won't waste much space anyway (if any)
    if (result == m3Err_none) {
        result = Module_PreallocFunctions(rt, io_module, numImports)
    }

    if (result == m3Err_none) {
        for (_i in range(int(numImports))) {
            var importKind : u8 = 0u8

            result = Read_utf8(rt.modules[io_module].wasm, importInfo.moduleUtf8, pos, i_end)
            if (result != m3Err_none) {
                break
            }
            result = Read_utf8(rt.modules[io_module].wasm, importInfo.fieldUtf8, pos, i_end)
            if (result != m3Err_none) {
                break
            }
            result = Read_u8(rt.modules[io_module].wasm, importKind, pos, i_end)
            if (result != m3Err_none) {
                break
            }

            if (importKind == d_externalKind_function) {
                var typeIndex : u32 = 0u
                result = ReadLEB_u32(rt.modules[io_module].wasm, typeIndex, pos, i_end)
                if (result != m3Err_none) {
                    break
                }

                // C: Module_AddFunction (io_module, typeIndex, & import); Eden: i_isImport (see the header)
                result = Module_AddFunction(rt, io_module, typeIndex, importInfo, true)
                if (result != m3Err_none) {
                    break
                }
                importInfo = M3ImportInfo()   // C: import = clearImport

                rt.modules[io_module].numFuncImports++

            } elif (importKind == d_externalKind_table) {
                //                  result = ParseType_Table (& i_bytes, i_end);
                pass

            } elif (importKind == d_externalKind_memory) {
                result = ParseType_Memory(rt.modules[io_module].wasm, rt.modules[io_module].memoryInfo, pos, i_end)
                if (result != m3Err_none) {
                    break
                }
                rt.modules[io_module].memoryImported = true
                rt.modules[io_module].memoryImport = importInfo
                importInfo = M3ImportInfo()   // C: import = clearImport

            } elif (importKind == d_externalKind_global) {
                var waType : i8 = i8(0)
                var _type : u8 = 0u8   // C local `type`: a gen2 keyword
                var isMutable : u8 = 0u8

                result = ReadLEB_i7(rt.modules[io_module].wasm, waType, pos, i_end)
                if (result != m3Err_none) {
                    break
                }
                result = NormalizeType(_type, waType)
                if (result != m3Err_none) {
                    break
                }
                result = ReadLEB_u7(rt.modules[io_module].wasm, isMutable, pos, i_end)
                if (result != m3Err_none) {
                    break
                }

                var global : IM3Global = -1
                result = Module_AddGlobal(rt, io_module, global, _type, isMutable != 0u8, true)   // isImport
                if (result != m3Err_none) {
                    break
                }
                rt.globals[global].import = importInfo
                importInfo = M3ImportInfo()   // C: import = clearImport

            } else {
                result = m3Err_wasmMalformed   // C: _throw
                break
            }

            FreeImportInfo(importInfo)
        }
    }

    // C: _catch:
    FreeImportInfo(importInfo)

    return result
}


def ParseSection_Export(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes
    var utf8 : cstr_t = ""

    var numExports : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numExports, pos, i_end)

    if (result == m3Err_none && numExports > u32(d_m3MaxSaneExportsCount)) {
        result = "too many exports"   // C: _throwif
    }

    if (result == m3Err_none) {
        for (_i in range(int(numExports))) {
            var exportKind : u8 = 0u8
            var index : u32 = 0u

            result = Read_utf8(rt.modules[io_module].wasm, utf8, pos, i_end)
            if (result != m3Err_none) {
                break
            }
            result = Read_u8(rt.modules[io_module].wasm, exportKind, pos, i_end)
            if (result != m3Err_none) {
                break
            }
            result = ReadLEB_u32(rt.modules[io_module].wasm, index, pos, i_end)
            if (result != m3Err_none) {
                break
            }

            if (exportKind == d_externalKind_function) {
                if (index >= rt.modules[io_module].numFunctions) {
                    result = m3Err_wasmMalformed   // C: _throwif
                    break
                }
                let func : IM3Function = rt.modules[io_module].functions[int(index)]   // C: &(io_module->functions [index])
                if (u32(rt.functions[func].numNames) < d_m3MaxDuplicateFunctionImpl) {
                    let n = int(rt.functions[func].numNames)
                    rt.functions[func].names[n] = utf8   // C: func->names[func->numNames++] = utf8
                    rt.functions[func].numNames = u16(n + 1)
                    rt.functions[func].export_name = utf8
                    rt.functions[func].isExported = true   // Eden: C's export_name != NULL (see the header)
                    utf8 = ""   // ownership transferred to M3Function
                }
            } elif (exportKind == d_externalKind_global) {
                if (index >= rt.modules[io_module].numGlobals) {
                    result = m3Err_wasmMalformed   // C: _throwif
                    break
                }
                let global : IM3Global = rt.modules[io_module].globals[int(index)]   // C: &(io_module->globals [index])
                // C: m3_Free (global->name); strings own their storage
                rt.globals[global].name = utf8
                rt.globals[global].isExported = true   // Eden: C's name != NULL (see the header)
                utf8 = ""   // ownership transferred to M3Global
            } elif (exportKind == d_externalKind_memory) {
                // C: m3_Free (io_module->memoryExportName); strings own their storage
                rt.modules[io_module].memoryExportName = utf8
                utf8 = ""   // ownership transferred to M3Module
            } elif (exportKind == d_externalKind_table) {
                // C: m3_Free (io_module->table0ExportName); strings own their storage
                rt.modules[io_module].table0ExportName = utf8
                utf8 = ""   // ownership transferred to M3Module
            }

            utf8 = ""   // C: m3_Free (utf8)
        }
    }

    // C: _catch: m3_Free (utf8)
    utf8 = ""
    return result
}


def ParseSection_Start(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var startFuncIndex : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, startFuncIndex, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (startFuncIndex < rt.modules[io_module].numFunctions) {
        rt.modules[io_module].startFunction = i32(startFuncIndex)
    } else {
        result = "start function index out of bounds"
    }

    return result
}


// Eden: the compilation is rt.compilation, saved and restored around the
// walk (see the header)
def Parse_InitExpr(var rt : M3Runtime; io_module : IM3Module; var io_bytes : bytes_t&; i_end : cbytes_t) : M3Result {
    var result : M3Result = m3Err_none

    // this doesn't generate code pages. just walks the wasm bytecode to find the end

    // C: M3Compilation compilation; compilation = (M3Compilation){ .runtime = NULL, .module = io_module, .wasm = * io_bytes, .wasmEnd = i_end };
    var savedCompilation <- rt.compilation
    rt.compilation <- M3Compilation()
    rt.compilation.runtime = -1
    rt.compilation.moduleIdx = io_module
    rt.compilation.wasm = io_bytes
    rt.compilation.wasmEnd = i_end

    result = CompileBlockStatements(rt)

    io_bytes = rt.compilation.wasm

    rt.compilation <- savedCompilation   // Eden: the runtime's compilation comes back

    return result
}


def ParseSection_Element(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var numSegments : u32 = 0u
    let result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numSegments, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (numSegments > u32(d_m3MaxSaneElementSegments)) {
        return "too many element segments"   // C: _throwif
    }

    rt.modules[io_module].elementSection = pos
    rt.modules[io_module].elementSectionEnd = i_end
    rt.modules[io_module].numElementSegments = numSegments

    return result
}


def ParseSection_Code(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var numFunctions : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numFunctions, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (numFunctions != rt.modules[io_module].numFunctions - rt.modules[io_module].numFuncImports) {
        return "mismatched function count in code section"   // C: _throw
    }

    for (f in range(int(numFunctions))) {
        let start : bytes_t = pos

        var size : u32 = 0u
        result = ReadLEB_u32(rt.modules[io_module].wasm, size, pos, i_end)
        if (result != m3Err_none) {
            break
        }

        if (size != 0u) {
            // C: const u8 * ptr = i_bytes; i_bytes += size; Eden: in i64 (see the header)
            let next : i64 = i64(pos) + i64(size)

            if (next <= i64(i_end)) {
                pos = int(next)

                // C: the commented-out local-block walk over `ptr` is not ported (as upstream)

                let func : IM3Function = Module_GetFunction(rt, io_module, u32(f) + rt.modules[io_module].numFuncImports)

                rt.functions[func].moduleIdx = io_module
                rt.functions[func].wasm = start
                rt.functions[func].wasmEnd = pos
                //func->ownsWasmCode = io_module->hasWasmCodeCopy;
                //                func->numLocals = numLocals;
            } else {
                result = m3Err_wasmSectionOverrun   // C: _throw
                break
            }
        }
    }

    // C: _catch:
    if (result == m3Err_none && pos != i_end) {
        result = m3Err_wasmSectionUnderrun
    }

    return result
}


def ParseSection_Data(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var numDataSegments : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numDataSegments, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (numDataSegments > u32(d_m3MaxSaneDataSegments)) {
        return "too many data segments"   // C: _throwif
    }

    m3_Malloc_Impl(rt.modules[io_module].dataSegments, int(numDataSegments))
    // C: _throwifnull (io_module->dataSegments); Eden: allocation cannot fail observably (m3_core)
    rt.modules[io_module].numDataSegments = numDataSegments

    for (i in range(int(numDataSegments))) {
        // C: M3DataSegment * segment = & io_module->dataSegments [i];
        // Eden: rt.modules[io_module].dataSegments[i], written in place

        result = ReadLEB_u32(rt.modules[io_module].wasm, rt.modules[io_module].dataSegments[i].memoryRegion, pos, i_end)
        if (result != m3Err_none) {
            break
        }

        rt.modules[io_module].dataSegments[i].initExpr = pos
        result = Parse_InitExpr(rt, io_module, pos, i_end)
        if (result != m3Err_none) {
            break
        }
        rt.modules[io_module].dataSegments[i].initExprSize = u32(pos - rt.modules[io_module].dataSegments[i].initExpr)

        if (rt.modules[io_module].dataSegments[i].initExprSize <= 1u) {
            result = m3Err_wasmMissingInitExpr   // C: _throwif
            break
        }

        result = ReadLEB_u32(rt.modules[io_module].wasm, rt.modules[io_module].dataSegments[i].size, pos, i_end)
        if (result != m3Err_none) {
            break
        }
        rt.modules[io_module].dataSegments[i].data = pos

        // C: i_bytes += segment->size; Eden: in i64 (see the header)
        let next : i64 = i64(pos) + i64(rt.modules[io_module].dataSegments[i].size)

        if (next > i64(i_end)) {
            result = "data segment underflow"   // C: _throwif
            break
        }
        pos = int(next)
    }

    return result
}


def ParseSection_Memory(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    // TODO: MVP; assert no memory imported

    var numMemories : u32 = 0u
    let result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numMemories, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (numMemories > 1u) {
        return m3Err_tooManyMemorySections   // C: _throwif
    }

    // C quirk, preserved (as upstream): the one ParseType_Memory call site
    // without the `_` macro, so a truncated memory type leaves memoryInfo
    // half-written and the section still succeeds.
    ParseType_Memory(rt.modules[io_module].wasm, rt.modules[io_module].memoryInfo, pos, i_end)

    return result
}


def ParseSection_Global(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var numGlobals : u32 = 0u
    var result : M3Result = ReadLEB_u32(rt.modules[io_module].wasm, numGlobals, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (numGlobals > u32(d_m3MaxSaneGlobalsCount)) {
        return "too many globals"   // C: _throwif
    }

    for (_i in range(int(numGlobals))) {
        var waType : i8 = i8(0)
        var _type : u8 = 0u8   // C local `type`: a gen2 keyword
        var isMutable : u8 = 0u8

        result = ReadLEB_i7(rt.modules[io_module].wasm, waType, pos, i_end)
        if (result != m3Err_none) {
            break
        }
        result = NormalizeType(_type, waType)
        if (result != m3Err_none) {
            break
        }
        result = ReadLEB_u7(rt.modules[io_module].wasm, isMutable, pos, i_end)
        if (result != m3Err_none) {
            break
        }

        var global : IM3Global = -1
        result = Module_AddGlobal(rt, io_module, global, _type, isMutable != 0u8, false)   // isImport
        if (result != m3Err_none) {
            break
        }

        rt.globals[global].initExpr = pos
        result = Parse_InitExpr(rt, io_module, pos, i_end)
        if (result != m3Err_none) {
            break
        }
        rt.globals[global].initExprSize = u32(pos - rt.globals[global].initExpr)

        if (rt.globals[global].initExprSize <= 1u) {
            result = m3Err_wasmMissingInitExpr   // C: _throwif
            break
        }
    }

    return result
}


def ParseSection_Name(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes
    var result : M3Result = m3Err_none

    var name : cstr_t = ""

    while (pos < i_end) {
        var nameType : u8 = 0u8
        var payloadLength : u32 = 0u

        result = ReadLEB_u7(rt.modules[io_module].wasm, nameType, pos, i_end)
        if (result != m3Err_none) {
            break
        }
        result = ReadLEB_u32(rt.modules[io_module].wasm, payloadLength, pos, i_end)
        if (result != m3Err_none) {
            break
        }

        let start : bytes_t = pos
        if (nameType == 1u8) {
            var numNames : u32 = 0u
            result = ReadLEB_u32(rt.modules[io_module].wasm, numNames, pos, i_end)
            if (result != m3Err_none) {
                break
            }

            if (numNames > u32(d_m3MaxSaneFunctionsCount)) {
                result = "too many names"   // C: _throwif
                break
            }

            for (_i in range(int(numNames))) {
                var index : u32 = 0u
                result = ReadLEB_u32(rt.modules[io_module].wasm, index, pos, i_end)
                if (result != m3Err_none) {
                    break
                }
                result = Read_utf8(rt.modules[io_module].wasm, name, pos, i_end)
                if (result != m3Err_none) {
                    break
                }

                if (index < rt.modules[io_module].numFunctions) {
                    let func : IM3Function = rt.modules[io_module].functions[int(index)]   // C: &(io_module->functions [index])
                    if (rt.functions[func].numNames == u16(0)) {
                        rt.functions[func].names[0] = name
                        rt.functions[func].numNames = u16(1)
                        name = ""   // transfer ownership
                    }
                    //                          else m3log (parse, "prenamed: %s", io_module->functions [index].name);
                }

                name = ""   // C: m3_Free (name)
            }
            if (result != m3Err_none) {
                break
            }
        }

        // C: i_bytes = start + payloadLength; Eden: in i64, a position past
        // the end ends the loop as C's pointer compare does (see the header)
        let next : i64 = i64(start) + i64(payloadLength)
        pos = next < i64(i_end) ? int(next) : i_end
    }

    return result
}


def ParseSection_Custom(var rt : M3Runtime; io_module : IM3Module; i_bytes : bytes_t; i_end : cbytes_t) : M3Result {
    var pos : bytes_t = i_bytes

    var name : cstr_t = ""
    var result : M3Result = Read_utf8(rt.modules[io_module].wasm, name, pos, i_end)
    if (result != m3Err_none) {
        return result
    }

    if (name == "name") {   // C: strcmp (name, "name") == 0
        result = ParseSection_Name(rt, io_module, pos, i_end)
        if (result != m3Err_none) {
            return result
        }
    } elif (rt.environment.customSectionHandler != null) {   // C: io_module->environment->customSectionHandler
        let handler = rt.environment.customSectionHandler
        result = invoke(handler, rt, io_module, name, pos, i_end)
        if (result != m3Err_none) {
            return result
        }
    }

    name = ""   // C: m3_Free (name)

    return result
}


def ParseModuleSection(var rt : M3Runtime; o_module : IM3Module; i_sectionType : u8; i_bytes : bytes_t; i_numBytes : u32) : M3Result {
    var result : M3Result = m3Err_none

    // C: static M3Parser s_parsers [] = { Custom, Type, Import, Function,
    // NULL /* 4: TODO Table */, Memory, Global, Export, Start, Element, Code,
    // Data, NULL /* 12: TODO DataCount */ }; if (i_sectionType <= 12) parser = s_parsers [i_sectionType];
    // Eden: the table is this if-chain in the same order (see the header)
    let end : cbytes_t = i_bytes + int(i_numBytes)

    if (i_sectionType == 0u8) {
        result = ParseSection_Custom(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 1u8) {
        result = ParseSection_Type(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 2u8) {
        result = ParseSection_Import(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 3u8) {
        result = ParseSection_Function(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 5u8) {
        result = ParseSection_Memory(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 6u8) {
        result = ParseSection_Global(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 7u8) {
        result = ParseSection_Export(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 8u8) {
        result = ParseSection_Start(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 9u8) {
        result = ParseSection_Element(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 10u8) {
        result = ParseSection_Code(rt, o_module, i_bytes, end)
    } elif (i_sectionType == 11u8) {
        result = ParseSection_Data(rt, o_module, i_bytes, end)
    } else {
        // compiled out under the active configuration: m3log skipped section type
        pass
    }

    return result
}


// C: M3Result m3_ParseModule (IM3Environment i_environment, IM3Module * o_module, cbytes_t i_bytes, u32 i_numBytes)
// Eden: the runtime first, the bytes are copied into the module; returns the
// result and the module handle, -1 on failure (see the header)
def public m3_ParseModule(var rt : M3Runtime; i_bytes : array<u8>) : tuple<M3Result; IM3Module> {
    var result : M3Result = m3Err_none

    // C: _try { module = m3_AllocStruct (M3Module); _throwifnull (module);
    // Eden: a new slot of the module arena (allocation cannot fail observably)
    var _module : IM3Module = length(rt.modules)   // C local `module`: a gen2 keyword
    m3_Realloc_Impl(rt.modules, _module + 1, _module)
    rt.modules[_module].name = ".unnamed"
    rt.modules[_module].startFunction = -1
    //module->hasWasmCodeCopy = false;
    // C: module->environment = i_environment; Eden: rt.environment (see the header)
    rt.modules[_module].runtime = -1   // Eden: not linked until m3_LoadModule (DESIGN 4.1)

    // Eden: the module's copy of the binary (see the header)
    rt.modules[_module].wasm := i_bytes

    var pos : bytes_t = 0
    let end : cbytes_t = length(rt.modules[_module].wasm)

    rt.modules[_module].wasmStart = pos
    rt.modules[_module].wasmEnd = end

    var magic : u32 = 0u
    var version : u32 = 0u
    result = Read_u32(rt.modules[_module].wasm, magic, pos, end)
    if (result == m3Err_none) {
        result = Read_u32(rt.modules[_module].wasm, version, pos, end)
    }

    if (result == m3Err_none && magic != 0x6d736100u) {
        result = m3Err_wasmMalformed   // C: _throwif
    }
    if (result == m3Err_none && version != 1u) {
        result = m3Err_incompatibleWasmVersion   // C: _throwif
    }

    let sectionsOrder = fixed_array<u8>(1u8, 2u8, 3u8, 4u8, 5u8, 6u8, 7u8, 8u8, 9u8, 12u8, 10u8, 11u8, 0u8)   // 0 is a placeholder
    var expectedSection : int = 0   // C: u8

    while (result == m3Err_none && pos < end) {
        var section : u8 = 0u8
        result = ReadLEB_u7(rt.modules[_module].wasm, section, pos, end)
        if (result != m3Err_none) {
            break
        }

        if (section != 0u8) {
            // Ensure sections appear only once and in order
            // C: while (sectionsOrder[expectedSection++] != section) { _throwif (m3Err_misorderedWasmSection, expectedSection >= 12); }
            while (true) {
                let expected = sectionsOrder[expectedSection]
                expectedSection++
                if (expected == section) {
                    break
                }
                if (expectedSection >= 12) {
                    result = m3Err_misorderedWasmSection
                    break
                }
            }
            if (result != m3Err_none) {
                break
            }
        }

        var sectionLength : u32 = 0u
        result = ReadLEB_u32(rt.modules[_module].wasm, sectionLength, pos, end)
        if (result != m3Err_none) {
            break
        }
        // C: _throwif (m3Err_wasmMalformed, pos + sectionLength > end); Eden: in i64 (see the header)
        if (i64(pos) + i64(sectionLength) > i64(end)) {
            result = m3Err_wasmMalformed
            break
        }

        result = ParseModuleSection(rt, _module, section, pos, sectionLength)
        if (result != m3Err_none) {
            break
        }

        pos += int(sectionLength)
    }

    // C: } _catch:
    if (result != m3Err_none) {
        m3_FreeModule(rt, _module)   // Eden: a released slot (see the header)
        _module = -1
    }

    // C: * o_module = module;
    return (result, _module)
}
