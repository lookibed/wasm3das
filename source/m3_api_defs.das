options gen2
options indenting = 4

module m3_api_defs shared public

require ./m3_env.das public


/*
    Port of the m3Api* macro family of wasm3.h (lines 347-385) that host
    functions (m3_api_libc.c, m3_api_wasi.c) use to read their arguments and
    the linear memory.

    C macros work on the raw-function parameters by name: `_sp` is advanced
    with `_sp++` as arguments are consumed, `_mem` is the linear memory base,
    `runtime` gives the memory size. The port spells every macro as a
    function; the raw function keeps its own cursor:

        def m3_libc_memset(runtime : IM3Runtime; _ctx : IM3ImportContext; var _sp : u64?; var _mem : void?) : M3Result {
            var sp = _sp
            var raw_return = m3ApiReturnType(sp)        // m3ApiReturnType (int32_t)
            var i_ptr = m3ApiGetArgMem(sp, _mem)       // m3ApiGetArgMem (void*, i_ptr)
            let i_value = m3ApiGetArg_i32(sp)          // m3ApiGetArg (int32_t, i_value)
            let i_size = m3ApiGetArg_u32(sp)           // m3ApiGetArg (uint32_t, i_size)
            let check = m3ApiCheckMem(runtime, _mem, i_ptr, u64(i_size))
            if (check != m3Err_none) { return check }  // m3ApiCheckMem traps
            ...
            m3ApiReturn_i32(raw_return, i32(result))   // m3ApiReturn (result)
            return m3Err_none
        }

    m3ApiTrap(VALUE) is `return VALUE`, m3ApiSuccess() is `return m3Err_none`.
    Little-endian hosts only: the M3_BIG_ENDIAN branch of the ReadMem/WriteMem
    macros is not represented (as everywhere in this port).
*/


// ============================================================================
// Offsets and pointers
// ============================================================================


// C: # define m3ApiOffsetToPtr(offset)   (void*)((uint8_t*)_mem + (uint32_t)(offset))
def m3ApiOffsetToPtr(_mem : void?; offset : u32) : void? {
    unsafe {
        return reinterpret<void?>(intptr(_mem) + u64(offset))
    }
}


// C: # define m3ApiPtrToOffset(ptr)      (uint32_t)((uint8_t*)ptr - (uint8_t*)_mem)
def m3ApiPtrToOffset(_mem : void?; ptr : void?) : u32 {
    return u32(intptr(ptr) - intptr(_mem))
}


// C: # define m3ApiIsNullPtr(addr)       ((void*)(addr) <= _mem)
def m3ApiIsNullPtr(_mem : void?; _addr : void?) : bool {
    return intptr(_addr) <= intptr(_mem)
}


// C: # define m3ApiCheckMem(addr, len)   { if (M3_UNLIKELY(((void*)(addr) < _mem) ||
//        ((uint64_t)(uintptr_t)(addr) + (len)) > ((uint64_t)(uintptr_t)(_mem)+m3_GetMemorySize(runtime))))
//        m3ApiTrap(m3Err_trapOutOfBoundsMemoryAccess); }
// The caller returns the result when it is not m3Err_none.
def m3ApiCheckMem(runtime : IM3Runtime; _mem : void?; _addr : void?; len : u64) : M3Result {
    let base = intptr(_mem)
    let address = intptr(_addr)
    if (address < base || address + len > base + u64(m3_GetMemorySize(runtime))) {
        return m3Err_trapOutOfBoundsMemoryAccess
    }
    return m3Err_none
}


// ============================================================================
// Stack slots: return value and arguments (each consumes one 64-bit slot)
// ============================================================================


// C: # define m3ApiReturnType(TYPE)                 TYPE* raw_return = ((TYPE*) (_sp++));
def m3ApiReturnType(var _sp : u64?&) : u64? {
    var raw_return = _sp
    unsafe {
        _sp = _sp + 1
    }
    return raw_return
}


// C: # define m3ApiGetArg(TYPE, NAME)  TYPE NAME = (sizeof(TYPE) >= sizeof(uint32_t)) ? (*((TYPE *)(_sp++))) : ...
// Only the 32/64-bit instantiations wasm3's host modules use are spelled out.
def m3ApiGetArg_i32(var _sp : u64?&) : i32 {
    unsafe {
        let value = reinterpret<i32?>(_sp)[0]
        _sp = _sp + 1
        return value
    }
}


def m3ApiGetArg_u32(var _sp : u64?&) : u32 {
    unsafe {
        let value = reinterpret<u32?>(_sp)[0]
        _sp = _sp + 1
        return value
    }
}


def m3ApiGetArg_i64(var _sp : u64?&) : i64 {
    unsafe {
        let value = reinterpret<i64?>(_sp)[0]
        _sp = _sp + 1
        return value
    }
}


def m3ApiGetArg_u64(var _sp : u64?&) : u64 {
    unsafe {
        let value = _sp[0]
        _sp = _sp + 1
        return value
    }
}


def m3ApiGetArg_f32(var _sp : u64?&) : f32 {
    unsafe {
        let value = reinterpret<f32?>(_sp)[0]
        _sp = _sp + 1
        return value
    }
}


def m3ApiGetArg_f64(var _sp : u64?&) : f64 {
    unsafe {
        let value = reinterpret<f64?>(_sp)[0]
        _sp = _sp + 1
        return value
    }
}


// C: # define m3ApiGetArgMem(TYPE, NAME)            TYPE NAME = (TYPE)m3ApiOffsetToPtr(* ((uint32_t *) (_sp++)));
def m3ApiGetArgMem(var _sp : u64?&; _mem : void?) : void? {
    let offset = m3ApiGetArg_u32(_sp)
    return m3ApiOffsetToPtr(_mem, offset)
}


// C: # define m3ApiReturn(VALUE)                   { *raw_return = (VALUE); return m3Err_none;}
// The store keeps the C width: `TYPE* raw_return` writes sizeof(TYPE) bytes.
// Every one of these takes `raw_return` as `var`: the parameter is written
// through, and a non-`var` pointer parameter gets the LLVM `readonly`
// attribute from the daslang JIT (upstream #3991), which folds the caller's
// read of the return slot from `--jit-opt-level=1` upwards.
def m3ApiReturn_i32(var raw_return : u64?; value : i32) {
    unsafe {
        reinterpret<i32?>(raw_return)[0] = value
    }
}


def m3ApiReturn_u32(var raw_return : u64?; value : u32) {
    unsafe {
        reinterpret<u32?>(raw_return)[0] = value
    }
}


def m3ApiReturn_i64(var raw_return : u64?; value : i64) {
    unsafe {
        reinterpret<i64?>(raw_return)[0] = value
    }
}


def m3ApiReturn_u64(var raw_return : u64?; value : u64) {
    unsafe {
        raw_return[0] = value
    }
}


def m3ApiReturn_f32(var raw_return : u64?; value : f32) {
    unsafe {
        reinterpret<f32?>(raw_return)[0] = value
    }
}


def m3ApiReturn_f64(var raw_return : u64?; value : f64) {
    unsafe {
        reinterpret<f64?>(raw_return)[0] = value
    }
}


// ============================================================================
// Linear memory reads and writes (little-endian branch of wasm3.h)
// ============================================================================


def m3ApiReadMem8(ptr : void?) : u8 {
    unsafe {
        return reinterpret<u8?>(ptr)[0]
    }
}


def m3ApiReadMem16(ptr : void?) : u16 {
    unsafe {
        return reinterpret<u16?>(ptr)[0]
    }
}


def m3ApiReadMem32(ptr : void?) : u32 {
    unsafe {
        return reinterpret<u32?>(ptr)[0]
    }
}


def m3ApiReadMem64(ptr : void?) : u64 {
    unsafe {
        return reinterpret<u64?>(ptr)[0]
    }
}


// `ptr` is `var` for the same reason as `raw_return` above: these four store
// into the guest's linear memory through the parameter (upstream #3991).
def m3ApiWriteMem8(var ptr : void?; val : u8) {
    unsafe {
        reinterpret<u8?>(ptr)[0] = val
    }
}


def m3ApiWriteMem16(var ptr : void?; val : u16) {
    unsafe {
        reinterpret<u16?>(ptr)[0] = val
    }
}


def m3ApiWriteMem32(var ptr : void?; val : u32) {
    unsafe {
        reinterpret<u32?>(ptr)[0] = val
    }
}


def m3ApiWriteMem64(var ptr : void?; val : u64) {
    unsafe {
        reinterpret<u64?>(ptr)[0] = val
    }
}
