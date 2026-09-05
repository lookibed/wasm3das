options gen2
options indenting = 4

module m3_module shared public

require ./m3_core.das public
require ./m3_types.das public
require ./m3_function.das public
require ./m3_exception.das public

// Conservative Gen2 port of m3_module.c.


def Module_FreeFunctions(var i_module : IM3Module) {
    for (i in 0u..i_module.numFunctions) {
        unsafe {
            var func : IM3Function = addr(i_module.functions[i])
            Function_Release(func)
        }
    }
}


def m3_FreeModule(var i_module : IM3Module) {
    if (i_module != null) {

        // C frees this container without following its borrowed links. Detach
        // them before releasing any owned child storage or finalizing the
        // managed M3Module value.
        i_module.runtime = null
        i_module.environment = null
        i_module.next = null

        Module_FreeFunctions(i_module)

        m3_Free_Impl(i_module.functions)
        i_module.functions = null
        m3_Free_Impl(i_module.funcTypes)
        i_module.funcTypes = null
        m3_Free_Impl(i_module.dataSegments)
        i_module.dataSegments = null
        m3_Free_Impl(i_module.table0)
        i_module.table0 = null

        for (i in 0u..i_module.numGlobals) {
            unsafe {
                var globalPtr : IM3Global = addr(i_module.globals[i])
                globalPtr.name = ""
                var importInfo : IM3ImportInfo = addr(i_module.globals[i].import)
                FreeImportInfo(importInfo[0])
            }
        }

        m3_Free_Impl(i_module.globals)
        i_module.globals = null
        i_module.memoryExportName = ""
        i_module.table0ExportName = ""

        unsafe {
            var memoryImport : IM3ImportInfo = addr(i_module.memoryImport)
            FreeImportInfo(memoryImport[0])
        }

        // C: m3_Free(i_module) - host free of m3_AllocStruct. In this port the
        // module object is created with Daslang `new M3Module()` by
        // m3_ParseModule (managed struct with string fields, mirroring
        // m3_NewRuntime), so it must be released with Daslang `delete`.
        unsafe { delete i_module }
        i_module = null
    }
}


def Module_AddGlobal(var io_module : IM3Module; var o_global : IM3Global&; i_type : u8; i_mutable : bool; i_isImported : bool) : M3Result {
    let index = io_module.numGlobals
    io_module.numGlobals++

    unsafe {
        io_module.globals = reinterpret<M3Global?>(m3_Realloc_Impl(io_module.globals,
            uint64(typeinfo sizeof(type<M3Global>)) * uint64(io_module.numGlobals), uint64(typeinfo sizeof(type<M3Global>)) * uint64(index)))
    }
    if (io_module.globals == null) {
        return m3Err_mallocFailed
    }

    unsafe {
        var global : IM3Global = addr(io_module.globals[index])
        global._type = i_type
        global.imported = i_isImported
        global.isMutable = i_mutable

        o_global = global
    }

    return m3Err_none
}


def Module_PreallocFunctions(var io_module : IM3Module; i_totalFunctions : u32) : M3Result {
    if (i_totalFunctions > io_module.allFunctions) {
        unsafe {
            io_module.functions = reinterpret<M3Function?>(m3_Realloc_Impl(io_module.functions,
                uint64(typeinfo sizeof(type<M3Function>)) * uint64(i_totalFunctions), uint64(typeinfo sizeof(type<M3Function>)) * uint64(io_module.allFunctions)))
        }
        io_module.allFunctions = i_totalFunctions

        if (io_module.functions == null) {
            return m3Err_mallocFailed
        }
    }

    return m3Err_none
}


def Module_AddFunction(var io_module : IM3Module; i_typeIndex : u32; i_importInfo : IM3ImportInfo) : M3Result {
    let index = io_module.numFunctions
    io_module.numFunctions++

    let result = Module_PreallocFunctions(io_module, io_module.numFunctions)
    if (result != m3Err_none) {
        return result
    }

    if (i_typeIndex >= io_module.numFuncTypes) {
        return "type sig index out of bounds"
    }

    unsafe {
        // C: IM3FuncType ft = io_module->funcTypes[i_typeIndex] - funcTypes is an
        // ARRAY OF POINTERS (IM3FuncType *), so the element VALUE is the func type;
        // addr(slot) would bind the slot itself and misread numRets/numArgs as 0.
        var ft : IM3FuncType = io_module.funcTypes[i_typeIndex]
        var func : IM3Function = Module_GetFunction(io_module, index)
        func.funcType = ft

        if (i_importInfo != null && func.numNames == 0) {
            let importCopy : M3ImportInfo = i_importInfo[0]
            func.import = importCopy
            func.names[0] = importCopy.fieldUtf8
            func.numNames = 1
        }
    }

    return m3Err_none
}


def Module_GenerateNames(var i_module : IM3Module) {
    for (i in 0u..i_module.numFunctions) {
        unsafe {
            var func : IM3Function = addr(i_module.functions[i])

            if (func.numNames == 0) {
                let buff = "$func{i}"
                func.names[0] = buff
                func.numNames = 1
            }
        }
    }

    for (i in 0u..i_module.numGlobals) {
        unsafe {
            var global : IM3Global = addr(i_module.globals[i])

            if (empty(global.name)) {
                global.name = "$global{i}"
            }
        }
    }
}


def Module_GetFunction(var i_module : IM3Module; i_functionIndex : u32) : IM3Function {
    var func : IM3Function = null

    if (i_functionIndex < i_module.numFunctions) {
        unsafe { func = addr(i_module.functions[i_functionIndex]) }
    }

    return func
}


def m3_GetModuleName(var i_module : IM3Module) : string {
    if (i_module == null || empty(i_module.name)) {
        return ".unnamed"
    }

    return i_module.name
}


def m3_SetModuleName(var i_module : IM3Module; name : string) {
    if (i_module != null) {
        i_module.name = name
    }
}


def m3_GetModuleRuntime(var i_module : IM3Module) : IM3Runtime {
    if (i_module != null) {
        return i_module.runtime
    }
    return null
}
