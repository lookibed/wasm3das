options gen2

module m3_exec shared public

require math
require ./m3_core.das public
require ./m3_types.das public
require ./m3_math_utils.das public
require ./m3_exec_defs.das public

// Conservative Gen2 port of m3_exec.h.
// The threaded-interpreter ABI, op_* names, register/slot forms, trap propagation,
// memory checks, and immediate layout are intentionally kept close to wasm3.

let INT32_MIN : i32 = -2147483647 - 1
let INT64_MIN : i64 = -9223372036854775807l - 1l








def pushBacktraceFrame(_pc : pc_t; _mem : M3MemoryHeader?) {
    // d_m3RecordBacktraces == false: the C body calls PushBacktraceFrame and
    // is compiled out. The backtrace layer is not ported yet.
}

def newTrap(_pc : pc_t; _mem : M3MemoryHeader?; err : M3Result) : M3Result {
    pushBacktraceFrame(_pc, _mem)
    return err
}

def forwardTrap(err : M3Result) : M3Result {
    return err
}



/*
    C m3_exec.h calls CompileFunction (m3_compile.c) for lazy compilation on
    the op_Entry/op_Call paths. The C header cycle between m3_exec.h and
    m3_compile.h cannot be expressed in an acyclic Daslang module graph, so
    the compiler implementation is registered in this hook; m3_env.das wires
    it when the full module set loads.
*/

var public CompileFunctionHook : function<(var io_function : IM3Function) : M3Result>

var public ResizeMemoryHook : function<(var io_runtime : IM3Runtime; i_numPages : u32) : M3Result>

// C: M3Result ResizeMemory (IM3Runtime io_runtime, u32 i_numPages) — m3_env.c,
// registered by m3_env.das (see CompileFunctionHook note). Private: m3_env.das
// defines the real ResizeMemory and must not see this bridge as a second candidate.
def private ResizeMemory(io_runtime : IM3Runtime; i_numPages : u32) : M3Result {
    if (ResizeMemoryHook == null) {
        return "memory resize hook is not wired"
    }
    unsafe {
        var rt = reinterpret<IM3Runtime>(io_runtime)
        return ResizeMemoryHook(rt, i_numPages)
    }
}

def private CompileFunction(io_function : IM3Function) : M3Result {
    if (CompileFunctionHook == null) {
        return "lazy compilation hook is not wired"
    }
    unsafe {
        var f = reinterpret<IM3Function>(io_function)
        return CompileFunctionHook(f)
    }
}


// ============================================================================
// C string.h replacements for op_MemCopy / op_MemFill
// ============================================================================


def c_memmove(dst : u8?; src : u8?; size : u32) {
    unsafe {
        var dptr = reinterpret<u8?>(dst)
        var sptr = reinterpret<u8?>(src)
        if (size == 0u) { return }
        let d = reinterpret<i64>(dptr)
        let s = reinterpret<i64>(sptr)
        if (d < s) {
            for (i in 0..int(size)) { dptr[i] = sptr[i] }
        } else {
            var i = int(size) - 1
            while (i >= 0) { dptr[i] = sptr[i]; i-- }
        }
    }
}

def c_memset(dst : u8?; value : u8; size : u32) {
    unsafe {
        var dptr = reinterpret<u8?>(dst)
        for (i in 0..int(size)) { dptr[i] = value }
    }
}

// ============================================================================
// libm replacements (C copysignf/copysign/nearbyintf/nearbyint)
// ============================================================================


def copysign_f32(a : f32; b : f32) : f32 {
    unsafe {
        let abits = reinterpret<u32>(a)
        let bbits = reinterpret<u32>(b)
        return reinterpret<f32>((abits & 0x7fffffffu) | (bbits & 0x80000000u))
    }
}

def copysign_f64(a : f64; b : f64) : f64 {
    unsafe {
        let abits = reinterpret<u64>(a)
        let bbits = reinterpret<u64>(b)
        return reinterpret<f64>((abits & 0x7ffffffffffffffful) | (bbits & 0x8000000000000000ul))
    }
}

// C nearbyintf/nearbyint under the default FE_TONEAREST mode: round half to even.
def nearest_f32(x : f32) : f32 {
    let r = floor(f64(x))
    let diff = f64(x) - r
    if (diff < 0.5lf) { return x }
    if (diff > 0.5lf) { return f32(r + 1.0lf) }
    return f32(r + (fmod(r, 2.0lf) == 0.0lf ? 0.0lf : 1.0lf))
}

def nearest_f64(x : f64) : f64 {
    let r = floor(x)
    let diff = x - r
    if (diff < 0.5lf) { return x }
    if (diff > 0.5lf) { return r + 1.0lf }
    return r + (fmod(r, 2.0lf) == 0.0lf ? 0.0lf : 1.0lf)
}

def bool_reg(value : bool) : m3reg_t {
    if (value) { return 1l }
    return 0l
}

def immediate_i32(var _pc : pc_t&) : i32 {
    unsafe {
        let p = reinterpret<i32 const?>(_pc)
        let value = p[0]
        _pc++
        return value
    }
}

def immediate_u32(var _pc : pc_t&) : u32 {
    unsafe {
        let p = reinterpret<u32 const?>(_pc)
        let value = p[0]
        _pc++
        return value
    }
}

def immediate_pc(var _pc : pc_t&) : pc_t {
    unsafe {
        var value = reinterpret<pc_t>(_pc[0])
        _pc++
        return value
    }
}

def immediate_code(var _pc : pc_t&) : code_t {
    unsafe {
        let value = _pc[0]
        _pc++
        return value
    }
}

def immediate_function(var _pc : pc_t&) : IM3Function {
    return unsafe(reinterpret<IM3Function>(immediate_code(_pc)))
}

def immediate_module(var _pc : pc_t&) : IM3Module {
    return unsafe(reinterpret<IM3Module>(immediate_code(_pc)))
}

def immediate_functype(var _pc : pc_t&) : IM3FuncType {
    return unsafe(reinterpret<IM3FuncType>(immediate_code(_pc)))
}

def immediate_rawcall(var _pc : pc_t&) : M3RawCall {
    return unsafe(reinterpret<M3RawCall>(immediate_code(_pc)))
}

def slot_ptr_i8(var _pc : pc_t&; _sp : m3stack_t) : i8? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<i8?>(_sp + offset)
    }
}

def slot_i8(var _pc : pc_t&; _sp : m3stack_t) : i8 {
    unsafe {
        return slot_ptr_i8(_pc, _sp)[0]
    }
}

def slot_ptr_u8(var _pc : pc_t&; _sp : m3stack_t) : u8? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<u8?>(_sp + offset)
    }
}

def slot_u8(var _pc : pc_t&; _sp : m3stack_t) : u8 {
    unsafe {
        return slot_ptr_u8(_pc, _sp)[0]
    }
}

def slot_ptr_i16(var _pc : pc_t&; _sp : m3stack_t) : i16? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<i16?>(_sp + offset)
    }
}

def slot_i16(var _pc : pc_t&; _sp : m3stack_t) : i16 {
    unsafe {
        return slot_ptr_i16(_pc, _sp)[0]
    }
}

def slot_ptr_u16(var _pc : pc_t&; _sp : m3stack_t) : u16? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<u16?>(_sp + offset)
    }
}

def slot_u16(var _pc : pc_t&; _sp : m3stack_t) : u16 {
    unsafe {
        return slot_ptr_u16(_pc, _sp)[0]
    }
}

def slot_ptr_i32(var _pc : pc_t&; _sp : m3stack_t) : i32? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<i32?>(_sp + offset)
    }
}

def slot_i32(var _pc : pc_t&; _sp : m3stack_t) : i32 {
    unsafe {
        return slot_ptr_i32(_pc, _sp)[0]
    }
}

def slot_ptr_u32(var _pc : pc_t&; _sp : m3stack_t) : u32? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<u32?>(_sp + offset)
    }
}

def slot_u32(var _pc : pc_t&; _sp : m3stack_t) : u32 {
    unsafe {
        return slot_ptr_u32(_pc, _sp)[0]
    }
}

def slot_ptr_i64(var _pc : pc_t&; _sp : m3stack_t) : i64? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<i64?>(_sp + offset)
    }
}

def slot_i64(var _pc : pc_t&; _sp : m3stack_t) : i64 {
    unsafe {
        return slot_ptr_i64(_pc, _sp)[0]
    }
}

def slot_ptr_u64(var _pc : pc_t&; _sp : m3stack_t) : u64? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<u64?>(_sp + offset)
    }
}

def slot_u64(var _pc : pc_t&; _sp : m3stack_t) : u64 {
    unsafe {
        return slot_ptr_u64(_pc, _sp)[0]
    }
}

def slot_ptr_f32(var _pc : pc_t&; _sp : m3stack_t) : f32? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<f32?>(_sp + offset)
    }
}

def slot_f32(var _pc : pc_t&; _sp : m3stack_t) : f32 {
    unsafe {
        return slot_ptr_f32(_pc, _sp)[0]
    }
}

def slot_ptr_f64(var _pc : pc_t&; _sp : m3stack_t) : f64? {
    let offset = immediate_i32(_pc)
    unsafe {
        return reinterpret<f64?>(_sp + offset)
    }
}

def slot_f64(var _pc : pc_t&; _sp : m3stack_t) : f64 {
    unsafe {
        return slot_ptr_f64(_pc, _sp)[0]
    }
}

def Call(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let possible_trap = m3_Yield()
    if (possible_trap != m3Err_none) { return possible_trap }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand == i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand != i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand < i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand > i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand <= i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(i32(_r0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand >= i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand == _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand != _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand < _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand > _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand <= _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(_r0 >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand >= _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand < u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand > u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand <= u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(u32(_r0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand >= u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand < u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand > u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand <= u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(u64(_r0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand >= u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand == f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand != f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand < f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand > f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand <= f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(f32(_fp0) >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand >= f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Equal_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand == _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Equal_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 == operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_NotEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand != _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_NotEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 != operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 < operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand < _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 < operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThan_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 > operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThan_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand > _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThan_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 > operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 <= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand <= _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_LessThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 <= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThanOrEqual_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(_fp0 >= operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThanOrEqual_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand >= _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_GreaterThanOrEqual_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _r0 = bool_reg(operand1 >= operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def OP_ADD_32(a, b : i32) : i32 { unsafe { return reinterpret<i32>(reinterpret<u32>(a) + reinterpret<u32>(b)) } }
def OP_ADD_64(a, b : i64) : i64 { unsafe { return reinterpret<i64>(reinterpret<u64>(a) + reinterpret<u64>(b)) } }
def OP_SUB_32(a, b : i32) : i32 { unsafe { return reinterpret<i32>(reinterpret<u32>(a) - reinterpret<u32>(b)) } }
def OP_SUB_64(a, b : i64) : i64 { unsafe { return reinterpret<i64>(reinterpret<u64>(a) - reinterpret<u64>(b)) } }
def OP_MUL_32(a, b : i32) : i32 { unsafe { return reinterpret<i32>(reinterpret<u32>(a) * reinterpret<u32>(b)) } }
def OP_MUL_64(a, b : i64) : i64 { unsafe { return reinterpret<i64>(reinterpret<u64>(a) * reinterpret<u64>(b)) } }

def OP_SHL_32(x, n : u32) : u32 { return x << (n % 32u) }
def OP_SHL_64(x, n : u64) : u64 { return x << (n % 64ul) }
def OP_SHR_32(x, n : u32) : u32 { return x >> (n % 32u) }
def OP_SHR_64(x, n : u64) : u64 { return x >> (n % 64ul) }

def public op_i32_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_ADD_32(operand, i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_ADD_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_ADD_64(operand, _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = OP_ADD_64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_MUL_32(operand, i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_MUL_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_MUL_64(operand, _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = OP_MUL_64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_SUB_32(i32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_SUB_32(operand, i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(OP_SUB_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_SUB_64(_r0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = OP_SUB_64(operand, _r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = OP_SUB_64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftLeft_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftLeft_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftLeft_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftLeft_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_64(u64(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftLeft_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_64(operand, u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftLeft_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHL_64(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(i32(_r0) >> i32(u32(operand) % 32u))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(operand >> i32(u32(i32(_r0)) % 32u))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    _r0 = m3reg_t(operand1 >> i32(u32(operand2) % 32u))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = (_r0 >> i64(u64(operand) % 64ul))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = (operand >> i64(u64(_r0) % 64ul))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    _r0 = (operand1 >> i64(u64(operand2) % 64ul))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftRight_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_64(u64(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftRight_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_64(operand, u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_ShiftRight_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(OP_SHR_64(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_And_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand & u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_And_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand1 & operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Or_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand | u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Or_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand1 | operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Xor_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand ^ u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Xor_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(operand1 ^ operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_And_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand & u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_And_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand1 & operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Or_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand | u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Or_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand1 | operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Xor_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand ^ u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Xor_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(operand1 ^ operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand + f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 + operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand * f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 * operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(f32(_fp0) - operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand - f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 - operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(f32(_fp0) / operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(operand / f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(operand1 / operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Add_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand + _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Add_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 + operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Multiply_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand * _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Multiply_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 * operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Subtract_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (_fp0 - operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Subtract_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand - _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Subtract_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 - operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (_fp0 / operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (operand / _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = (operand1 / operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotl_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotl32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotl_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotl32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotl_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotl32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotr_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotr32(u32(_r0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotr_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotr32(operand, u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Rotr_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    _r0 = m3reg_t(rotr32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotl_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotl64(u64(_r0), u32(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotl_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotl64(operand, u32(u64(_r0) % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotl_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotl64(operand1, u32(operand2 % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotr_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotr64(u64(_r0), u32(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotr_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotr64(operand, u32(u64(_r0) % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Rotr_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    _r0 = m3reg_t(rotr64(operand1, u32(operand2 % 64ul)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_DIV_U(RES, u32(_r0), operand)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_DIV_U(RES, operand, u32(_r0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_DIV_U(RES, operand1, operand2)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_REM_U(RES, u32(_r0), operand)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_REM_U(RES, operand, u32(_r0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u32(_pc, _sp)
    let operand1 = slot_u32(_pc, _sp)
    var RES : u32
    let result = OP_REM_U(RES, operand1, operand2)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_DIV_S(RES, i32(_r0), operand, INT32_MIN)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_DIV_S(RES, operand, i32(_r0), INT32_MIN)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_DIV_S(RES, operand1, operand2, INT32_MIN)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_REM_S(RES, i32(_r0), operand, INT32_MIN)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_REM_S(RES, operand, i32(_r0), INT32_MIN)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    var RES : i32
    let result = OP_REM_S(RES, operand1, operand2, INT32_MIN)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_DIV_U(RES, u64(_r0), operand)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_DIV_U(RES, operand, u64(_r0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_DIV_U(RES, operand1, operand2)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_REM_U(RES, u64(_r0), operand)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_REM_U(RES, operand, u64(_r0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_u64(_pc, _sp)
    let operand1 = slot_u64(_pc, _sp)
    var RES : u64
    let result = OP_REM_U(RES, operand1, operand2)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Divide_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_DIV_S(RES, _r0, operand, INT64_MIN)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Divide_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_DIV_S(RES, operand, _r0, INT64_MIN)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Divide_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_DIV_S(RES, operand1, operand2, INT64_MIN)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Remainder_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_REM_S(RES, _r0, operand, INT64_MIN)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Remainder_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_REM_S(RES, operand, _r0, INT64_MIN)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Remainder_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    var RES : i64
    let result = OP_REM_S(RES, operand1, operand2, INT64_MIN)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Min_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(min_f32(f32(_fp0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Min_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(min_f32(operand, f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Min_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(min_f32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Max_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(max_f32(f32(_fp0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Max_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(max_f32(operand, f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Max_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(max_f32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_CopySign_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(copysign_f32(f32(_fp0), operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_CopySign_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(copysign_f32(operand, f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_CopySign_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    _fp0 = f64(copysign_f32(operand1, operand2))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Min_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = min_f64(_fp0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Min_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = min_f64(operand, _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Min_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = min_f64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Max_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = max_f64(_fp0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Max_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = max_f64(operand, _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Max_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = max_f64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_CopySign_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = copysign_f64(_fp0, operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_CopySign_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = copysign_f64(operand, _fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_CopySign_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    _fp0 = copysign_f64(operand1, operand2)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Abs_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::abs(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Abs_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::abs(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Ceil_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::ceil(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Ceil_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::ceil(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Floor_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::floor(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Floor_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::floor(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Trunc_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::trunc(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Trunc_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::trunc(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Sqrt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64((math::sqrt(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Sqrt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64((math::sqrt(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Nearest_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(nearest_f32(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Nearest_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(nearest_f32(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Negate_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(-(f32(_fp0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Negate_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f32(_pc, _sp)
    _fp0 = f64(-(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Abs_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::abs(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Abs_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::abs(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Ceil_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::ceil(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Ceil_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::ceil(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Floor_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::floor(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Floor_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::floor(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Trunc_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::trunc(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Trunc_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::trunc(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Sqrt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (math::sqrt(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Sqrt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (math::sqrt(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Nearest_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = rint(_fp0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Nearest_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = nearest_f64(operand)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Negate_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = (-(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Negate_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_f64(_pc, _sp)
    _fp0 = (-(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_EqualToZero_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = bool_reg(i32(_r0) == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_EqualToZero_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = bool_reg(operand == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_EqualToZero_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = bool_reg(_r0 == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_EqualToZero_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = bool_reg(operand == 0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Clz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(clz(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Clz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(clz(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Ctz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(ctz(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Ctz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(ctz(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Popcnt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(popcnt(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Popcnt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u32(_pc, _sp)
    _r0 = m3reg_t(popcnt(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Clz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(clz(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Clz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(clz(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Ctz_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(ctz(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Ctz_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(ctz(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Popcnt_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(popcnt(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Popcnt_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_u64(_pc, _sp)
    _r0 = m3reg_t(popcnt(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Wrap_i64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(u32(u64(_r0) & 0xfffffffful))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Wrap_i64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = m3reg_t(u32(u64(operand) & 0xfffffffful))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend8_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(i32(i8(i32(_r0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend8_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(i32(i8(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend16_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(i32(i16(i32(_r0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Extend16_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i32(_pc, _sp)
    _r0 = m3reg_t(i32(i16(operand)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend8_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i8(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend8_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = i64(i8(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend16_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i16(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend16_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = i64(i16(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let operand = slot_i64(_pc, _sp)
    _r0 = i64(i32(operand))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    let result = OP_I32_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    let result = OP_U32_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, f32(_fp0))
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F32(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    let result = OP_I64_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, _fp0)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_Trunc_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    let result = OP_U64_TRUNC_F64(RES, source)
    if (result != m3Err_none) { return result }
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F32(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F32(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, _fp0)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, _fp0)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    var RES : i32
    OP_I32_TRUNC_SAT_F64(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, _fp0)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, _fp0)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u32_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u32(_pc, _sp)
    var RES : u32
    OP_U32_TRUNC_SAT_F64(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, source)
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F32(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, f32(_fp0))
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, f32(_fp0))
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F32(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, _fp0)
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, source)
    _r0 = RES
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, _fp0)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    var RES : i64
    OP_I64_TRUNC_SAT_F64(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, _fp0)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, source)
    _r0 = m3reg_t(RES)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, _fp0)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_u64_TruncSat_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_u64(_pc, _sp)
    var RES : u64
    OP_U64_TRUNC_SAT_F64(RES, source)
    unsafe { dest[0] = RES }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_i32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_i32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(slot_i32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_u32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Extend_u32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = i64(slot_u32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Demote_f64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Demote_f64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(slot_f64(_pc, _sp)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Promote_f32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Promote_f32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(slot_f32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(i32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(i32(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(u32(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(u32(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(_r0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_i64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(f32(u64(_r0)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(u64(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    _fp0 = f64(f32(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Convert_u64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = f32(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(i32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(i32(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(u32(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(u32(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u32(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(_r0)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(_r0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_i64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(u64(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(u64(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    _fp0 = f64(source)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Convert_u64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_u64(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = f64(source) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(unsafe(reinterpret<i32>(f32(_fp0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    _r0 = m3reg_t(unsafe(reinterpret<i32>(source)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i32>(f32(_fp0))) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i32_Reinterpret_f32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f32(_pc, _sp)
    var dest = slot_ptr_i32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i32>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = unsafe(reinterpret<i64>(_fp0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    _r0 = unsafe(reinterpret<i64>(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_i64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i64>(_fp0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_i64_Reinterpret_f64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_f64(_pc, _sp)
    var dest = slot_ptr_i64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<i64>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(unsafe(reinterpret<f32>(i32(_r0))))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    _fp0 = f64(unsafe(reinterpret<f32>(source)))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f32>(i32(_r0))) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Reinterpret_i32_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i32(_pc, _sp)
    var dest = slot_ptr_f32(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f32>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_r_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = unsafe(reinterpret<f64>(_r0))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_r_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    _fp0 = unsafe(reinterpret<f64>(source))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_s_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f64>(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f64_Reinterpret_i64_s_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let source = slot_i64(_pc, _sp)
    var dest = slot_ptr_f64(_pc, _sp)
    unsafe { dest[0] = unsafe(reinterpret<f64>(source)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_GetGlobal_s32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u32?>(immediate_code(_pc)))
    unsafe { slot_ptr_u32(_pc, _sp)[0] = global[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_GetGlobal_s64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u64?>(immediate_code(_pc)))
    unsafe { slot_ptr_u64(_pc, _sp)[0] = global[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u32?>(immediate_code(_pc)))
    unsafe { global[0] = u32(_r0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u64?>(immediate_code(_pc)))
    unsafe { global[0] = u64(_r0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Call(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var callPC = immediate_pc(_pc)
    let stackOffset = immediate_i32(_pc)
    let memory = m3MemInfo(_mem)
    var sp = unsafe(_sp + stackOffset)
    let r = Call(callPC, sp, _mem, 0l, 0.0lf)
    _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
    if (r == m3Err_none) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    pushBacktraceFrame(_pc, _mem)
    return forwardTrap(r)
}

def public op_CallIndirect(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let tableIndex = slot_u32(_pc, _sp)
    let _module = immediate_module(_pc)
    let _type = immediate_functype(_pc)
    let stackOffset = immediate_i32(_pc)
    let memory = m3MemInfo(_mem)
    var sp = unsafe(_sp + stackOffset)
    var r : M3Result = m3Err_none
    if (tableIndex < _module.table0Size) {
        let _function = unsafe(_module.table0[tableIndex])
        if (_function != null) {
            if (_type == _function.funcType) {
                var compiled : pc_t = unsafe(reinterpret<pc_t>(_function.compiled))
                if (compiled == null) { r = CompileFunction(_function) }
                if (r == m3Err_none) {
                    r = Call(compiled, sp, _mem, 0l, 0.0lf)
                    _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
                    if (r == m3Err_none) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
                    pushBacktraceFrame(_pc, _mem)
                    return forwardTrap(r)
                }
            } else { r = m3Err_trapIndirectCallTypeMismatch }
        } else { r = m3Err_trapTableElementIsNull }
    } else { r = m3Err_trapTableIndexOutOfRange }
    if (r != m3Err_none) { return newTrap(_pc, _mem, r) }
    return forwardTrap(r)
}

def public op_CallRawFunction(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var ctx : M3ImportContext
    let call = immediate_rawcall(_pc)
    ctx._function = immediate_function(_pc)
    ctx.userdata = immediate_code(_pc)
    let sp = unsafe(reinterpret<u64?>(_sp))
    let memory = m3MemInfo(_mem)
    var runtime = m3MemRuntime(_mem)
    let stack_backup = runtime.stack
    runtime.stack = sp
    let possible_trap = call(runtime, unsafe(addr(ctx)), sp, m3MemData(_mem))
    runtime.stack = stack_backup
    if (possible_trap != m3Err_none) { _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated)); pushBacktraceFrame(_pc, _mem) }
    return forwardTrap(possible_trap)
}

def public op_MemSize(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let memory = m3MemInfo(_mem)
    _r0 = m3reg_t(memory.numPages)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_MemGrow(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let runtime = m3MemRuntime(_mem)
    let memory = unsafe(addr(runtime.memory))
    let numPagesToGrow = i32(_r0)
    if (numPagesToGrow >= 0) {
        _r0 = m3reg_t(memory.numPages)
        if (numPagesToGrow != 0) {
            let requiredPages = memory.numPages + u32(numPagesToGrow)
            let r = ResizeMemory(runtime, requiredPages)
            if (r != m3Err_none) { _r0 = -1l }
            _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
        }
    } else { _r0 = -1l }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_MemCopy(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let size = u32(_r0)
    let source = u64(slot_u32(_pc, _sp))
    let destination = u64(slot_u32(_pc, _sp))
    if (destination + u64(size) <= _mem.length) {
        if (source + u64(size) <= _mem.length) {
            let dst = unsafe(m3MemData(_mem) + int64(destination))
            let src = unsafe(m3MemData(_mem) + int64(source))
            unsafe { c_memmove(dst, src, size) }
            return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
        }
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_MemFill(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let size = u32(_r0)
    let byte = slot_u32(_pc, _sp)
    let destination = u64(slot_u32(_pc, _sp))
    if (destination + u64(size) <= _mem.length) {
        unsafe { c_memset(m3MemData(_mem) + int64(destination), u8(byte), size) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_Compile(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe {
        var rewrite = (_pc - 1)
        rewrite[0] = unsafe(reinterpret<code_t>(@@op_Call))
    }
    let _function = immediate_function(_pc)
    var result : M3Result = m3Err_none
    if (_function.compiled == null) { result = CompileFunction(_function) }
    if (result == m3Err_none) {
        unsafe { _pc-- }
        unsafe { _pc[0] = reinterpret<code_t>(_function.compiled) }
        unsafe { _pc-- }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, result)
}

def public op_Entry(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = 0l
    _fp0 = 0.0lf
    let _function = immediate_function(_pc)
    let memory = m3MemInfo(_mem)
    let stackEnd = unsafe(_sp + int(_function.maxStackSlots))
if (d_m3SkipStackCheck || intptr(stackEnd) < intptr(_mem.maxStack)) {
        // DEBUG-only hit counter omitted when DEBUG is not part of the Das module configuration.
        var stack = unsafe(reinterpret<u8?>(unsafe(_sp + int(_function.numRetAndArgSlots))))
        c_memset(stack, 0u8, u32(_function.numLocalBytes))
        unsafe { stack = stack + int(_function.numLocalBytes) }
        if (_function.constants != null) { unsafe { memcpy(stack, _function.constants, int(_function.numConstantBytes)) } }
        let r = nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
        if (r != m3Err_none) {
            _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
            // d_m3RecordBacktraces == false: the C FillBacktraceFunctionInfo call is compiled out.
        }
        return forwardTrap(r)
    }
    return newTrap(_pc, _mem, m3Err_trapStackOverflow)
}

def public op_Loop(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = 0l
    _fp0 = 0.0lf
    var r : M3Result
    let memory = m3MemInfo(_mem)
    while (true) {
        r = nextOpImpl(_pc, _sp, _mem, _r0, _fp0)
        _mem = unsafe(reinterpret<M3MemoryHeader?>(memory.mallocated))
        if (r != unsafe(reinterpret<M3Result>(_pc))) { break }
    }
    return forwardTrap(r)
}

def public op_Branch(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe {
        var branch = reinterpret<pc_t>(_pc[0])
        return jumpOpDirect(branch, _sp, _mem, _r0, _fp0)
    }
}

def public op_If_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    var elsePC = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(elsePC, _sp, _mem, _r0, _fp0)
}

def public op_If_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    var elsePC = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(elsePC, _sp, _mem, _r0, _fp0)
}

def public op_BranchTable(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var branchIndex = slot_u32(_pc, _sp)
    let numTargets = immediate_u32(_pc)
    var branches = unsafe(reinterpret<pc_t?>(_pc))
    if (branchIndex > numTargets) { branchIndex = numTargets }
    unsafe {
        var target : pc_t = branches[int(branchIndex)]
        return jumpOpDirect(target, _sp, _mem, _r0, _fp0)
    }
}

def public op_SetRegister_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = m3reg_t(slot_i32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe { slot_ptr_i32(_pc, _sp)[0] = i32(_r0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_i32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_i32(_pc, _sp)
    var preserve = slot_ptr_i32(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe { stack[0] = i32(_r0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _r0 = slot_i64(_pc, _sp)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe { slot_ptr_i64(_pc, _sp)[0] = _r0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_i64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_i64(_pc, _sp)
    var preserve = slot_ptr_i64(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe { stack[0] = _r0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = f64(slot_f32(_pc, _sp))
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe { slot_ptr_f32(_pc, _sp)[0] = f32(_fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_f32(_pc, _sp)
    var preserve = slot_ptr_f32(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe { stack[0] = f32(_fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetRegister_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    _fp0 = slot_f64(_pc, _sp)
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetSlot_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    unsafe { slot_ptr_f64(_pc, _sp)[0] = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveSetSlot_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var stack = slot_ptr_f64(_pc, _sp)
    var preserve = slot_ptr_f64(_pc, _sp)
    unsafe { preserve[0] = stack[0] }
    unsafe { stack[0] = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_CopySlot_32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dst = slot_ptr_u32(_pc, _sp)
    var src = slot_ptr_u32(_pc, _sp)
    unsafe { dst[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveCopySlot_32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u32(_pc, _sp)
    var src = slot_ptr_u32(_pc, _sp)
    var preserve = slot_ptr_u32(_pc, _sp)
    unsafe { preserve[0] = dest[0] }
    unsafe { dest[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_CopySlot_64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dst = slot_ptr_u64(_pc, _sp)
    var src = slot_ptr_u64(_pc, _sp)
    unsafe { dst[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_PreserveCopySlot_64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var dest = slot_ptr_u64(_pc, _sp)
    var src = slot_ptr_u64(_pc, _sp)
    var preserve = slot_ptr_u64(_pc, _sp)
    unsafe { preserve[0] = dest[0] }
    unsafe { dest[0] = src[0] }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_DumpStack(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let opcodeIndex = immediate_u32(_pc)
    let stackHeight = immediate_u32(_pc)
    let _function = immediate_function(_pc)
    // d_m3EnableOpTracing == false: the C op tracing print is compiled out.
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(operand1) } else { _r0 = m3reg_t(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(operand1) } else { _r0 = m3reg_t(i32(_r0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(i32(_r0)) } else { _r0 = m3reg_t(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i32_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i32(_pc, _sp)
    let operand1 = slot_i32(_pc, _sp)
    if (condition != 0) { _r0 = m3reg_t(operand1) } else { _r0 = m3reg_t(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = operand1 } else { _r0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = operand1 } else { _r0 = _r0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = _r0 } else { _r0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_i64_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_i64(_pc, _sp)
    let operand1 = slot_i64(_pc, _sp)
    if (condition != 0) { _r0 = operand1 } else { _r0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(f32(_fp0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(f32(_fp0)) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f32(_pc, _sp)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_rrs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand1 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(operand1) } else { _fp0 = f64(f32(_fp0)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f32_rsr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f32(_pc, _sp)
    if (condition != 0) { _fp0 = f64(f32(_fp0)) } else { _fp0 = f64(operand2) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_sss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_srs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_ssr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    let operand2 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = _fp0 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_rss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f64(_pc, _sp)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_rrs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand1 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = operand1 } else { _fp0 = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Select_f64_rsr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let operand2 = slot_f64(_pc, _sp)
    if (condition != 0) { _fp0 = _fp0 } else { _fp0 = operand2 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Return(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    m3StackCheck()
    return m3Err_none
}

def public op_BranchIf_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return jumpOpDirect(branch, _sp, _mem, _r0, _fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_BranchIf_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return jumpOpDirect(branch, _sp, _mem, _r0, _fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_BranchIfPrologue_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(branch, _sp, _mem, _r0, _fp0)
}

def public op_BranchIfPrologue_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = slot_i32(_pc, _sp)
    var branch = immediate_pc(_pc)
    if (condition != 0) { return nextOpDirect(_pc, _sp, _mem, _r0, _fp0) }
    return jumpOpDirect(branch, _sp, _mem, _r0, _fp0)
}

def public op_ContinueLoop(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    m3StackCheck()
    let loopId = immediate_code(_pc)
    return unsafe(reinterpret<M3Result>(loopId))
}

def public op_ContinueLoopIf(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let condition = i32(_r0)
    let loopId = immediate_code(_pc)
    if (condition != 0) { return unsafe(reinterpret<M3Result>(loopId)) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Const32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let p = unsafe(reinterpret<u32 const?>(_pc))
    let value = unsafe(p[0])
    unsafe { _pc++ }
    unsafe { slot_ptr_u32(_pc, _sp)[0] = value }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Const64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var value : u64
    unsafe {
        let p = reinterpret<u64 const?>(_pc)
        value = p[0]
        if (M3_SIZEOF_PTR == 4) { _pc += 2 } else { _pc++ }
    }
    unsafe { slot_ptr_u64(_pc, _sp)[0] = value }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_Unsupported(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return newTrap(_pc, _mem, "unsupported instruction executed")
}

def public op_Unreachable(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    m3StackCheck()
    return newTrap(_pc, _mem, m3Err_trapUnreachable)
}

def public op_End(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    m3StackCheck()
    return m3Err_none
}

def public op_SetGlobal_s32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u32?>(immediate_code(_pc)))
    unsafe { global[0] = slot_u32(_pc, _sp) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_s64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<u64?>(immediate_code(_pc)))
    unsafe { global[0] = slot_u64(_pc, _sp) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_f32(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<f32?>(immediate_code(_pc)))
    unsafe { global[0] = f32(_fp0) }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_SetGlobal_f64(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var global = unsafe(reinterpret<f64?>(immediate_code(_pc)))
    unsafe { global[0] = _fp0 }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

def public op_f32_Load_f32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var value : f32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<f32>))) }
        _fp0 = f64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Load_f32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var value : f32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<f32>))) }
        _fp0 = f64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Load_f64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var value : f64
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<f64>))) }
        _fp0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Load_f64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var value : f64
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<f64>))) }
        _fp0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i8>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i8>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u8>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u8>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i16>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i16>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u16>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_u16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u16>))) }
        _r0 = m3reg_t(i32(value))
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i32>))) }
        _r0 = m3reg_t(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Load_i32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i32>))) }
        _r0 = m3reg_t(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i8>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i8>)) <= _mem.length) {
        var value : i8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i8>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u8_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u8>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u8_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var value : u8
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u8>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i16>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var value : i16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i16>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u16_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u16>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u16_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u16>)) <= _mem.length) {
        var value : u16
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u16>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i32>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var value : i32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i32>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u32_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u32>)) <= _mem.length) {
        var value : u32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u32>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_u32_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u32>)) <= _mem.length) {
        var value : u32
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<u32>))) }
        _r0 = i64(value)
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i64_r(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let offset = immediate_u32(_pc)
    var operand = u64(u32(_r0))
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var value : i64
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i64>))) }
        _r0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Load_i64_s(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var value : i64
        unsafe { memcpy(addr(value), m3MemData(_mem) + int64(operand), u64(typeinfo sizeof(type<i64>))) }
        _r0 = value
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var val = f32(_fp0)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f32_Store_f32_rr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f32>)) <= _mem.length) {
        var val = f32(_fp0)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var val = _fp0
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_f64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_f64_Store_f64_rr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<f64>)) <= _mem.length) {
        var val = _fp0
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<f64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_u8_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var val = u8(i32(_r0))
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<u8>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_u8_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var val = u8(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<u8>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_u8_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var val = u8(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<u8>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i16_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var val = i16(i32(_r0))
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i16>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i16_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var val = i16(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i16>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i16_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var val = i16(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i16>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i32_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var val = i32(_r0)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i32_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i32_Store_i32_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i32(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_u8_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var val = u8(_r0)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<u8>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_u8_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var val = u8(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<u8>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_u8_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<u8>)) <= _mem.length) {
        var val = u8(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<u8>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i16_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var val = i16(_r0)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i16>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i16_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var val = i16(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i16>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i16_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i16>)) <= _mem.length) {
        var val = i16(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i16>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i32_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var val = i32(_r0)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i32_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var val = i32(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i32_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i32>)) <= _mem.length) {
        var val = i32(value)
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i32>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i64_rs(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var val = _r0
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i64_sr(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(u32(_r0))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def public op_i64_Store_i64_ss(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    let value = slot_i64(_pc, _sp)
    var operand = u64(slot_u32(_pc, _sp))
    let offset = immediate_u32(_pc)
    operand += u64(offset)
    if (d_m3SkipMemoryBoundsCheck || operand + u64(typeinfo sizeof(type<i64>)) <= _mem.length) {
        var val = value
        unsafe { memcpy(m3MemData(_mem) + int64(operand), addr(val), u64(typeinfo sizeof(type<i64>))) }
        return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
    }
    return newTrap(_pc, _mem, m3Err_trapOutOfBoundsMemoryAccess)
}

def debugOp(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64; i_opcode : string) : M3Result {
    if (d_m3EnableOpTracing) { print("{i_opcode}\n") }
    return nextOpDirect(_pc, _sp, _mem, _r0, _fp0)
}

// profileOp (d_m3EnableOpProfiling) is compiled out under the active
// configuration, together with its C definition in m3_exec_defs.h.