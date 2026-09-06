options gen2
options indenting = 4

module m3_compile shared public

require ./m3_core.das
require ./m3_types.das
require ./m3_code.das public
require ./m3_exec.das
require ./m3_exec_defs.das public
require ./m3_function.das public
require ./m3_module.das
require math


// ============================================================================
// m3_compile.h definitions
// ============================================================================


/* C m3_compile.h: anonymous enum with the opcode constants the compiler walks against */
let public c_waOp_block : m3opcode_t = 0x02
let public c_waOp_loop : m3opcode_t = 0x03
let public c_waOp_if : m3opcode_t = 0x04
let public c_waOp_else : m3opcode_t = 0x05
let public c_waOp_end : m3opcode_t = 0x0b
let public c_waOp_branch : m3opcode_t = 0x0c
let public c_waOp_branchTable : m3opcode_t = 0x0e
let public c_waOp_branchIf : m3opcode_t = 0x0d
let public c_waOp_call : m3opcode_t = 0x10
let public c_waOp_getLocal : m3opcode_t = 0x20
let public c_waOp_setLocal : m3opcode_t = 0x21
let public c_waOp_teeLocal : m3opcode_t = 0x22
let public c_waOp_getGlobal : m3opcode_t = 0x23
let public c_waOp_store_f32 : m3opcode_t = 0x38
let public c_waOp_store_f64 : m3opcode_t = 0x39
let public c_waOp_i32_const : m3opcode_t = 0x41
let public c_waOp_i64_const : m3opcode_t = 0x42
let public c_waOp_f32_const : m3opcode_t = 0x43
let public c_waOp_f64_const : m3opcode_t = 0x44
let public c_waOp_extended : m3opcode_t = 0xfc
let public c_waOp_memoryCopy : m3opcode_t = 0xfc0a
let public c_waOp_memoryFill : m3opcode_t = 0xfc0b

/* C m3_compile.h: static const u16 c_m3RegisterUnallocated / c_slotUnused */
let public c_m3RegisterUnallocated : int = 0
let public c_slotUnused : int = 0xffff


/* C m3_compile.h: typedef struct M3OpInfo {...} M3OpInfo; */
typedef M3CompilerMutable = function<(var io_compilation : IM3Compilation; i_opcode : m3opcode_t) : M3Result>

struct M3OpInfo {
    // DEBUG inactive: name field absent.

    stackOffset : int
    _type : int                   // C field `type`; keyword-safe Daslang spelling (widened)

    // for most operations:
    // [0]= top operand in register, [1]= top operand in stack, [2]= both operands in stack
    operations : IM3Operation[4]

    compiler : M3CompilerMutable
}



/* C m3_compile.h: static const u16 + static inline helpers */
def public IsRegisterAllocated(var o : IM3Compilation; i_register : u32) : bool {
    return o.regStackIndexPlusOne[i_register] != c_m3RegisterUnallocated
}

def public IsStackPolymorphic(var o : IM3Compilation) : bool {
    return o._block.isPolymorphic
}

def public IsRegisterSlotAlias(i_slot : int) : bool {
    return i_slot >= d_m3Reg0SlotAlias && i_slot != c_slotUnused
}

def public IsFpRegisterSlotAlias(i_slot : int) : bool {
    return i_slot == d_m3Fp0SlotAlias
}

def public IsIntRegisterSlotAlias(i_slot : int) : bool {
    return i_slot == d_m3Reg0SlotAlias
}




//
// Conservative Gen2 port of m3_compile.c.
// C preprocessor-only dispatch helpers are represented as local constructor
// helpers below; runtime/compiler semantics and public C names are preserved.
//

let d_indent = "     | %s"
let i_32 : int = int(u8(M3ValueType.c_m3Type_i32))
let i_64 : int = int(u8(M3ValueType.c_m3Type_i64))
let f_32 : int = int(u8(M3ValueType.c_m3Type_f32))
let f_64 : int = int(u8(M3ValueType.c_m3Type_f64))
let none : int = int(u8(M3ValueType.c_m3Type_none))
let any : int = 0xff

let c_ioSlotCount : int = int((d_m3Use32BitSlots ? 1u : 0u) + 1u)

/* C stores NULL in absent operation-table slots. Daslang function values are
   non-nullable, so absent slots hold these explicit no-op sentinels instead;
   the C `op == null` checks become IsNoOp(op)/IsNoCompiler(fn). The sentinels
   are never meant to execute — they trap loudly if reached. */
def public op_NoOp(var _pc : pc_t; var _sp : m3stack_t; var _mem : M3MemoryHeader?; var _r0 : m3reg_t; var _fp0 : f64) : M3Result {
    return m3Err_noCompiler
}

let public c_opNull : IM3Operation = @@op_NoOp

def public IsNoOp(i_operation : IM3Operation) : bool {
    return i_operation == c_opNull
}

def public c_noCompilerImpl(var io_compilation : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    return m3Err_noCompiler
}

let public c_noCompiler : M3CompilerMutable = @@c_noCompilerImpl

def public IsNoCompiler(i_compiler : M3CompilerMutable) : bool {
    return i_compiler == c_noCompiler
}

typedef public IM3OpInfo = M3OpInfo const?



def GetPC(var o : IM3Compilation) : pc_t {
    var page = o.page
    return GetPagePC(page)
}


def EnsureCodePageNumLines(var o : IM3Compilation; var i_numLines : u32) : M3Result {
    var result : M3Result = m3Err_none
    i_numLines += 2u

    if (NumFreeLines(o.page) < i_numLines) {
        var page = AcquireCodePageWithCapacity(o.runtime, i_numLines)
        if (page != null) {
                        d_m3Assert(NumFreeLines(o.page) >= 2u)
            EmitWord(o.page, @@op_Branch)
            EmitWord(o.page, GetPagePC(page))
            ReleaseCodePage(o.runtime, o.page)
            o.page = page
        } else {
            result = m3Err_mallocFailedCodePage
        }
    }
    return result
}


def EmitOp(var o : IM3Compilation; i_operation : IM3Operation) : M3Result {
    var result : M3Result = m3Err_none
    // C: d_m3Assert (i_operation or IsStackPolymorphic (o)); NULL is the c_opNull sentinel here.
    d_m3Assert(!IsNoOp(i_operation) || IsStackPolymorphic(o))

    // page may be null when compile-walking bytecode without emitting.
    if (o.page != null) {
        // DEBUG-only numEmits tracking is compiled out when DEBUG is inactive.

        result = EnsureCodePageNumLines(o, d_m3CodePageFreeLinesThreshold)
        if (result == m3Err_none) {
            // d_m3LogEmit/d_m3RecordBacktraces are inactive: the C log_emit
            // and EmitMappingEntry calls are compiled out.
            EmitWord(o.page, i_operation)
        }
    }
    return result
}


def EmitConstant32(var o : IM3Compilation; i_immediate : u32) {
    if (o.page != null) {
        EmitWord32(o.page, i_immediate)
    }
}


def EmitSlotOffset(var o : IM3Compilation; i_offset : i32) {
    if (o.page != null) {
        EmitWord32(o.page, u32(i_offset))
    }
}


def EmitPointer(var o : IM3Compilation; i_pointer : void const?) : pc_t {
    var ptr : pc_t = GetPagePC(o.page)
    if (o.page != null) {
        EmitWord_impl(o.page, unsafe(reinterpret<void?>(i_pointer)))
    }
    return ptr
}


def ReservePointer(var o : IM3Compilation) : void? {
    var ptr : pc_t = GetPagePC(o.page)
    EmitPointer(o, null)
    unsafe {
        return reinterpret<void?>(ptr)
    }
}


let c_preserveSetSlot = fixed_array<IM3Operation>(
    c_opNull, @@op_PreserveSetSlot_i32, @@op_PreserveSetSlot_i64,
    @@op_PreserveSetSlot_f32, @@op_PreserveSetSlot_f64)
let c_setSetOps = fixed_array<IM3Operation>(
    c_opNull, @@op_SetSlot_i32, @@op_SetSlot_i64, @@op_SetSlot_f32, @@op_SetSlot_f64)
let c_setGlobalOps = fixed_array<IM3Operation>(
    c_opNull, @@op_SetGlobal_i32, @@op_SetGlobal_i64, @@op_SetGlobal_f32, @@op_SetGlobal_f64)
let c_setRegisterOps = fixed_array<IM3Operation>(
    c_opNull, @@op_SetRegister_i32, @@op_SetRegister_i64, @@op_SetRegister_f32, @@op_SetRegister_f64)

let c_intSelectOps = fixed_array(
    fixed_array<IM3Operation>(@@op_Select_i32_rss, @@op_Select_i32_srs, @@op_Select_i32_ssr, @@op_Select_i32_sss),
    fixed_array<IM3Operation>(@@op_Select_i64_rss, @@op_Select_i64_srs, @@op_Select_i64_ssr, @@op_Select_i64_sss))

let c_fpSelectOps = fixed_array(
    fixed_array(
        fixed_array<IM3Operation>(@@op_Select_f32_sss, @@op_Select_f32_srs, @@op_Select_f32_ssr),
        fixed_array<IM3Operation>(@@op_Select_f32_rss, @@op_Select_f32_rrs, @@op_Select_f32_rsr)),
    fixed_array(
        fixed_array<IM3Operation>(@@op_Select_f64_sss, @@op_Select_f64_srs, @@op_Select_f64_ssr),
        fixed_array<IM3Operation>(@@op_Select_f64_rss, @@op_Select_f64_rrs, @@op_Select_f64_rsr)))


def AcquireCompilationCodePage(var o : IM3Compilation; var o_codePage : IM3CodePage&) : M3Result {
    var result : M3Result = m3Err_none
    var page = AcquireCodePage(o.runtime)
    if (page != null) {
        // d_m3EnableCodePageRefCounting == false: the C codePageRefs block is compiled out.
    } else {
        result = m3Err_mallocFailedCodePage
    }
    o_codePage = page
    return result
}


def ReleaseCompilationCodePage(var o : IM3Compilation) {
    ReleaseCodePage(o.runtime, o.page)
}


def GetTypeNumSlots(i_type : int) : int {
    if (i_type == int(u8(M3ValueType.c_m3Type_v128))) {
        if (d_m3Use32BitSlots) {
            return 4
        }
        return 2
    }
    if (d_m3Use32BitSlots && Is64BitType(u8(i_type))) {
        return 2
    }
    return 1
}


def AlignSlotToType(var io_slot : int&; i_type : int) {
    let numSlots = GetTypeNumSlots(i_type)
    let mask = numSlots - 1
    io_slot = (io_slot + mask) & ~mask
}


def GetStackTopIndex(var o : IM3Compilation) : int {
    d_m3Assert(o.stackIndex > o.stackFirstDynamicIndex || IsStackPolymorphic(o))
    return o.stackIndex - 1
}


def GetStackTypeFromTop(var o : IM3Compilation; var i_offset : int) : int {
    var _type : int = int(u8(M3ValueType.c_m3Type_none))
    i_offset++
    if (o.stackIndex >= i_offset) {
        let index = o.stackIndex - i_offset
        if (index >= o.stackFirstDynamicIndex) {
            _type = o.typeStack[index]
        }
    }
    return _type
}


def GetStackTopType(var o : IM3Compilation) : int {
    return GetStackTypeFromTop(o, 0)
}


def GetStackTypeFromBottom(var o : IM3Compilation; i_offset : int) : int {
    var _type : int = int(u8(M3ValueType.c_m3Type_none))
    if (i_offset < o.stackIndex) {
        _type = o.typeStack[i_offset]
    }
    return _type
}


def IsConstantSlot(var o : IM3Compilation; i_slot : int) : bool {
    return i_slot >= o.slotFirstConstIndex && i_slot < o.slotMaxConstIndex
}


def IsSlotAllocated(var o : IM3Compilation; i_slot : int) : bool {
    return o.m3Slots[i_slot] != 0
}


def IsStackIndexInRegister(var o : IM3Compilation; i_stackIndex : i32) : bool {
    d_m3Assert(i_stackIndex < o.stackIndex || IsStackPolymorphic(o))
    if (i_stackIndex >= 0 && i_stackIndex < o.stackIndex) {
        return o.wasmStack[i_stackIndex] >= d_m3Reg0SlotAlias
    }
    return false
}


def GetNumBlockValuesOnStack(var o : IM3Compilation) : int {
    return o.stackIndex - o._block.blockStackIndex
}

def IsStackTopInRegister(var o : IM3Compilation) : bool {
    return IsStackIndexInRegister(o, GetStackTopIndex(o))
}

def IsStackTopMinus1InRegister(var o : IM3Compilation) : bool {
    return IsStackIndexInRegister(o, GetStackTopIndex(o) - 1)
}

def IsStackTopMinus2InRegister(var o : IM3Compilation) : bool {
    return IsStackIndexInRegister(o, GetStackTopIndex(o) - 2)
}

def IsStackTopInSlot(var o : IM3Compilation) : bool {
    return !IsStackTopInRegister(o)
}

def IsValidSlot(i_slot : int) : bool {
    return i_slot < int(d_m3MaxFunctionSlots)
}


def GetStackTopSlotNumber(var o : IM3Compilation) : int {
    let i = GetStackTopIndex(o)
    var slot : int = c_slotUnused
    if (i >= 0) {
        slot = o.wasmStack[i]
    }
    return slot
}


def GetSlotForStackIndex(var o : IM3Compilation; i_stackIndex : int) : int {
    d_m3Assert(i_stackIndex < o.stackIndex || IsStackPolymorphic(o))
    var slot : int = c_slotUnused
    if (i_stackIndex < o.stackIndex) {
        slot = o.wasmStack[i_stackIndex]
    }
    return slot
}


def GetExtraSlotForStackIndex(var o : IM3Compilation; i_stackIndex : int) : int {
    var baseSlot = GetSlotForStackIndex(o, i_stackIndex)
    if (baseSlot != c_slotUnused) {
        baseSlot += GetTypeNumSlots(GetStackTypeFromBottom(o, i_stackIndex)) - 1
    }
    return baseSlot
}


def TouchSlot(var o : IM3Compilation; i_slot : int) {
    o.maxStackSlots = max(o.maxStackSlots, i_slot + 1)
}


def MarkSlotAllocated(var o : IM3Compilation; i_slot : int) {
    d_m3Assert(o.m3Slots[i_slot] == 0)
    o.m3Slots[i_slot] = 1
    o.slotMaxAllocatedIndexPlusOne = max(o.slotMaxAllocatedIndexPlusOne, i_slot + 1)
    TouchSlot(o, i_slot)
}


def MarkSlotsAllocated(var o : IM3Compilation; var i_slot : int; var i_numSlots : int) : M3Result {
    if (i_slot + i_numSlots > int(d_m3MaxFunctionSlots)) {
        return m3Err_functionStackOverflow
    }
    while (i_numSlots != 0) {
        MarkSlotAllocated(o, i_slot)
        i_slot++
        i_numSlots--
    }
    return m3Err_none
}


def MarkSlotsAllocatedByType(var o : IM3Compilation; i_slot : int; i_type : int) : M3Result {
    return MarkSlotsAllocated(o, i_slot, GetTypeNumSlots(i_type))
}


def AllocateSlotsWithinRange(var o : IM3Compilation; var o_slot : int&; i_type : int; var i_startSlot : int; i_endSlot : int) : M3Result {
    var result : M3Result = m3Err_functionStackOverflow
    let numSlots = GetTypeNumSlots(i_type)
    let searchOffset = numSlots - 1
    AlignSlotToType(i_startSlot, i_type)

    var i = i_startSlot
    while (i + searchOffset < i_endSlot) {
        if (i + searchOffset < int(d_m3MaxFunctionSlots) &&
            o.m3Slots[i] == 0 && o.m3Slots[i + searchOffset] == 0) {
            result = MarkSlotsAllocated(o, i, numSlots)
            if (result != m3Err_none) {
                return result
            }
            o_slot = i
            return m3Err_none
        }
        i += numSlots
    }
    return result
}


def AllocateSlots(var o : IM3Compilation; var o_slot : int&; i_type : int) : M3Result {
    return AllocateSlotsWithinRange(o, o_slot, i_type, o.slotFirstDynamicIndex, int(d_m3MaxFunctionSlots))
}


def AllocateConstantSlots(var o : IM3Compilation; var o_slot : int&; i_type : int) : M3Result {
    let maxTableIndex = o.slotFirstConstIndex + int(d_m3MaxConstantTableSize)
    return AllocateSlotsWithinRange(o, o_slot, i_type, o.slotFirstConstIndex,
        min(o.slotFirstDynamicIndex, maxTableIndex))
}


def IncrementSlotUsageCount(var o : IM3Compilation; i_slot : int) : M3Result {
    d_m3Assert(i_slot < int(d_m3MaxFunctionSlots))
    d_m3Assert(o.m3Slots[i_slot] > 0)
    if (o.m3Slots[i_slot] < 0xff) {
        o.m3Slots[i_slot]++
        return m3Err_none
    }
    return "slot usage count overflow"
}


def DeallocateSlot(var o : IM3Compilation; var i_slot : int; i_type : int) {
    d_m3Assert(i_slot >= o.slotFirstDynamicIndex)
    d_m3Assert(i_slot < o.slotMaxAllocatedIndexPlusOne)
    var i : int = 0
    let count = GetTypeNumSlots(i_type)
    while (i < count) {
        d_m3Assert(o.m3Slots[i_slot] != 0)
        o.m3Slots[i_slot]--
        i++
        i_slot++
    }
}


def IsRegisterTypeAllocated(var o : IM3Compilation; i_type : int) : bool {
    var regSelect : u32 = 0u
    if (IsFpType(u8(i_type))) { regSelect = 1u }
    return IsRegisterAllocated(o, regSelect)
}


def AllocateRegister(var o : IM3Compilation; i_register : u32; i_stackIndex : int) {
    d_m3Assert(!IsRegisterAllocated(o, i_register))
    o.regStackIndexPlusOne[i_register] = i_stackIndex + 1
}


def DeallocateRegister(var o : IM3Compilation; i_register : u32) {
    d_m3Assert(IsRegisterAllocated(o, i_register))
    o.regStackIndexPlusOne[i_register] = c_m3RegisterUnallocated
}


def GetRegisterStackIndex(var o : IM3Compilation; i_register : u32) : int {
    d_m3Assert(IsRegisterAllocated(o, i_register))
    return o.regStackIndexPlusOne[i_register] - 1
}


def GetMaxUsedSlotPlusOne(var o : IM3Compilation) : int {
    while (o.slotMaxAllocatedIndexPlusOne > o.slotFirstDynamicIndex) {
        if (IsSlotAllocated(o, o.slotMaxAllocatedIndexPlusOne - 1)) {
            break
        }
        o.slotMaxAllocatedIndexPlusOne--
    }
    return o.slotMaxAllocatedIndexPlusOne
}


def PreserveRegisterIfOccupied(var o : IM3Compilation; i_registerType : int) : M3Result {
    var regSelect : u32 = 0u
    if (IsFpType(u8(i_registerType))) { regSelect = 1u }
    if (IsRegisterAllocated(o, regSelect)) {
        let stackIndex = GetRegisterStackIndex(o, regSelect)
        DeallocateRegister(o, regSelect)
        let _type = GetStackTypeFromBottom(o, stackIndex)
        var slot : int = c_slotUnused
        var result = AllocateSlots(o, slot, _type)
        if (result != m3Err_none) { return result }
        o.wasmStack[stackIndex] = slot

        if (_type < 5) {
            result = EmitOp(o, c_setSetOps[_type])
            if (result != m3Err_none) { return result }
        } else {
            return m3Err_functionStackOverflow
        }
        EmitSlotOffset(o, slot)
    }
    return m3Err_none
}


def PreserveRegisters(var o : IM3Compilation) : M3Result {
    var result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_f64)))
    if (result != m3Err_none) { return result }
    result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_i64)))
    return result
}


def PreserveNonTopRegisters(var o : IM3Compilation) : M3Result {
    let stackTop = GetStackTopIndex(o)
    if (stackTop >= 0) {
        if (IsRegisterAllocated(o, 0u) && GetRegisterStackIndex(o, 0u) != stackTop) {
            let result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_i64)))
            if (result != m3Err_none) { return result }
        }
        if (IsRegisterAllocated(o, 1u) && GetRegisterStackIndex(o, 1u) != stackTop) {
            let result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_f64)))
            if (result != m3Err_none) { return result }
        }
    }
    return m3Err_none
}


def Push(var o : IM3Compilation; i_type : int; i_slot : int) : M3Result {
    if (!d_m3HasFloat && (i_type == int(u8(M3ValueType.c_m3Type_f32)) || i_type == int(u8(M3ValueType.c_m3Type_f64)))) {
        return m3Err_unknownOpcode
    }
    let stackIndex = o.stackIndex
    o.stackIndex++
    if (stackIndex < int(d_m3MaxFunctionStackHeight)) {
        o.wasmStack[stackIndex] = i_slot
        o.typeStack[stackIndex] = i_type
        if (IsRegisterSlotAlias(i_slot)) {
            var regSelect : u32 = 0u
            if (IsFpRegisterSlotAlias(i_slot)) { regSelect = 1u }
            AllocateRegister(o, regSelect, stackIndex)
        }
        // compiled out under the active configuration: d_m3LogWasmStack == false
        return m3Err_none
    }
    return m3Err_functionStackOverflow
}


def PushRegister(var o : IM3Compilation; i_type : int) : M3Result {
    d_m3Assert(d_m3Reg0SlotAlias > int(d_m3MaxFunctionSlots))
    d_m3Assert(i_type != 0 || IsStackPolymorphic(o))
    var slot : int = d_m3Reg0SlotAlias
    if (IsFpType(u8(i_type))) { slot = d_m3Fp0SlotAlias }
    return Push(o, i_type, slot)
}


def Pop(var o : IM3Compilation) : M3Result {
    if (o.stackIndex > o._block.blockStackIndex) {
        o.stackIndex--
        let slot = o.wasmStack[o.stackIndex]
        let _type = o.typeStack[o.stackIndex]
        if (IsRegisterSlotAlias(slot)) {
            var regSelect : u32 = 0u
            if (IsFpRegisterSlotAlias(slot)) { regSelect = 1u }
            DeallocateRegister(o, regSelect)
        } elif (slot >= o.slotMaxAllocatedIndexPlusOne) {
            return m3Err_functionStackUnderrun
        } elif (slot >= o.slotFirstDynamicIndex) {
            let mutableSlot = slot
            DeallocateSlot(o, mutableSlot, _type)
        }
    } elif (!IsStackPolymorphic(o)) {
        return m3Err_functionStackUnderrun
    }
    return m3Err_none
}


def PopType(var o : IM3Compilation; i_type : int) : M3Result {
    let topType = GetStackTopType(o)
    if (i_type == topType || o._block.isPolymorphic) {
        return Pop(o)
    }
    return m3Err_typeMismatch
}


def _PushAllocatedSlotAndEmit(var o : IM3Compilation; i_type : int; i_doEmit : bool) : M3Result {
    var slot : int = c_slotUnused
    var result = AllocateSlots(o, slot, i_type)
    if (result != m3Err_none) { return result }
    result = Push(o, i_type, slot)
    if (result != m3Err_none) { return result }
    if (i_doEmit) { EmitSlotOffset(o, slot) }
    return m3Err_none
}


def PushAllocatedSlotAndEmit(var o : IM3Compilation; i_type : int) : M3Result {
    return _PushAllocatedSlotAndEmit(o, i_type, true)
}

def PushAllocatedSlot(var o : IM3Compilation; i_type : int) : M3Result {
    return _PushAllocatedSlotAndEmit(o, i_type, false)
}


def PushConst(var o : IM3Compilation; i_word : u64; i_type : int) : M3Result {
    if (o.page == null) { return m3Err_none }

    var matchFound = false
    let is64BitType = Is64BitType(u8(i_type))
    let numRequiredSlots = GetTypeNumSlots(i_type)
    let numUsedConstSlots = o.slotMaxConstIndex - o.slotFirstConstIndex

    if (numRequiredSlots == 2 && numUsedConstSlots >= 2) {
        var firstConstSlot = o.slotFirstConstIndex
        AlignSlotToType(firstConstSlot, int(u8(M3ValueType.c_m3Type_i64)))
        var slot = firstConstSlot
        while (slot < o.slotMaxConstIndex - 1) {
            if (IsSlotAllocated(o, slot) && IsSlotAllocated(o, slot + 1)) {
                var constant : u64
                unsafe { memcpy(unsafe(addr(constant)), unsafe(addr(o.constants[slot - o.slotFirstConstIndex])), (typeinfo sizeof(type<u64>))) }
                if (constant == i_word) {
                    matchFound = true
                    let result = Push(o, i_type, slot)
                    if (result != m3Err_none) { return result }
                    break
                }
            }
            slot += 2
        }
    } elif (numRequiredSlots == 1) {
        var i : int = 0
        while (i < numUsedConstSlots) {
            let slot = o.slotFirstConstIndex + i
            if (IsSlotAllocated(o, slot)) {
                var matches = false
                if (is64BitType) {
                    var constant : u64
                    unsafe { memcpy(unsafe(addr(constant)), unsafe(addr(o.constants[i])), (typeinfo sizeof(type<u64>))) }
                    matches = constant == i_word
                } else {
                    var constant : u32
                    unsafe { memcpy(unsafe(addr(constant)), unsafe(addr(o.constants[i])), (typeinfo sizeof(type<u32>))) }
                    // C: matches = (constant == i_word) compares the zero-extended u32
                    // with the full u64, so a sign-extended negative i32 never matches.
                    matches = u64(constant) == i_word
                }
                if (matches) {
                    matchFound = true
                    let result = Push(o, i_type, slot)
                    if (result != m3Err_none) { return result }
                    break
                }
            }
            i++
        }
    }

    if (!matchFound) {
        var slot : int = c_slotUnused
        var result = AllocateConstantSlots(o, slot, i_type)
        if (result != m3Err_none || slot == c_slotUnused) {
            result = m3Err_none
            if (is64BitType) {
                result = EmitOp(o, @@op_Const64)
                if (result != m3Err_none) { return result }
                EmitWord64(o.page, i_word)
            } else {
                result = EmitOp(o, @@op_Const32)
                if (result != m3Err_none) { return result }
                EmitWord32(o.page, u32(i_word))
            }
            return PushAllocatedSlotAndEmit(o, i_type)
        }

        let constTableIndex = slot - o.slotFirstConstIndex
        d_m3Assert(constTableIndex < int(d_m3MaxConstantTableSize))
        if (is64BitType) {
            unsafe { memcpy(unsafe(addr(o.constants[constTableIndex])), unsafe(addr(i_word)), (typeinfo sizeof(type<u64>))) }
        } else {
            let word32 = u32(i_word)
            unsafe { memcpy(unsafe(addr(o.constants[constTableIndex])), unsafe(addr(word32)), (typeinfo sizeof(type<u32>))) }
        }

        result = Push(o, i_type, slot)
        if (result != m3Err_none) { return result }
        o.slotMaxConstIndex = max(slot + numRequiredSlots, o.slotMaxConstIndex)
    }

    return m3Err_none
}


def EmitSlotNumOfStackTopAndPop(var o : IM3Compilation) : M3Result {
    if (IsStackTopInSlot(o)) {
        EmitSlotOffset(o, GetStackTopSlotNumber(o))
    }
    return Pop(o)
}


def AddTrapRecord(var o : IM3Compilation) : M3Result {
    return m3Err_none
}


def UnwindBlockStack(var o : IM3Compilation) : M3Result {
    var popCount : u32 = 0u
    while (o.stackIndex > o._block.blockStackIndex) {
        let result = Pop(o)
        if (result != m3Err_none) { return result }
        popCount++
    }
    // compiled out under the active configuration: m3log (compile, "unwound stack top: %d", popCount)
    return m3Err_none
}


def SetStackPolymorphic(var o : IM3Compilation) : M3Result {
    o._block.isPolymorphic = true
        return UnwindBlockStack(o)
}


def PatchBranches(var o : IM3Compilation) {
    var pc = GetPC(o)
    var patches = o._block.patches
    o._block.patches = null

    unsafe {
        while (patches != null) {
                        var patch = reinterpret<pc_t?>(patches)
            let next = patch[0]
            unsafe { patch[0] = pc }
            patches = unsafe(reinterpret<pc_t>(next))
        }
    }
}


def CopyStackIndexToSlot(var o : IM3Compilation; i_destSlot : int; i_stackIndex : int) : M3Result {
    let _type = GetStackTypeFromBottom(o, i_stackIndex)
    let inRegister = IsStackIndexInRegister(o, i_stackIndex)
    var op : IM3Operation
    if (inRegister) {
        op = c_setSetOps[_type]
    } elif (Is64BitType(u8(_type))) {
        op = @@op_CopySlot_64
    } else {
        op = @@op_CopySlot_32
    }
    let result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    EmitSlotOffset(o, i_destSlot)
    if (!inRegister) {
        EmitSlotOffset(o, GetSlotForStackIndex(o, i_stackIndex))
    }
    return m3Err_none
}


def CopyStackTopToSlot(var o : IM3Compilation; i_destSlot : int) : M3Result {
    return CopyStackIndexToSlot(o, i_destSlot, GetStackTopIndex(o))
}


def PreservedCopyTopSlot(var o : IM3Compilation; i_destSlot : int; i_preserveSlot : int) : M3Result {
    d_m3Assert(i_destSlot != i_preserveSlot)
    let _type = GetStackTopType(o)
    var op : IM3Operation
    if (IsStackTopInRegister(o)) {
        op = c_preserveSetSlot[_type]
    } elif (Is64BitType(u8(_type))) {
        op = @@op_PreserveCopySlot_64
    } else {
        op = @@op_PreserveCopySlot_32
    }
    let result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    EmitSlotOffset(o, i_destSlot)
    if (IsStackTopInSlot(o)) { EmitSlotOffset(o, GetStackTopSlotNumber(o)) }
    EmitSlotOffset(o, i_preserveSlot)
    return m3Err_none
}


def CopyStackTopToRegister(var o : IM3Compilation; i_updateStack : bool) : M3Result {
    if (IsStackTopInSlot(o)) {
        let _type = GetStackTopType(o)
        var result = PreserveRegisterIfOccupied(o, _type)
        if (result != m3Err_none) { return result }
        result = EmitOp(o, c_setRegisterOps[_type])
        if (result != m3Err_none) { return result }
        EmitSlotOffset(o, GetStackTopSlotNumber(o))
        if (i_updateStack) {
            result = PopType(o, _type)
            if (result != m3Err_none) { return result }
            result = PushRegister(o, _type)
            if (result != m3Err_none) { return result }
        }
    }
    return m3Err_none
}


def FindReferencedLocalWithinCurrentBlock(var o : IM3Compilation; var o_preservedSlotNumber : int&; i_localSlot : u32) : M3Result {
    var scope = unsafe(addr(o._block))
    var startIndex = scope.blockStackIndex

    while (scope.opcode == c_waOp_block) {
        scope = scope.outer
        if (scope == null) { break }
        startIndex = scope.blockStackIndex
    }

    o_preservedSlotNumber = int(i_localSlot)
    var i = u32(startIndex)
    while (i < u32(o.stackIndex)) {
        if (o.wasmStack[i] == int(i_localSlot)) {
            if (o_preservedSlotNumber == int(i_localSlot)) {
                let _type = GetStackTypeFromBottom(o, int(i))
                d_m3Assert(_type != int(u8(M3ValueType.c_m3Type_none)))
                let result = AllocateSlots(o, o_preservedSlotNumber, _type)
                if (result != m3Err_none) { return result }
            } else {
                let result = IncrementSlotUsageCount(o, o_preservedSlotNumber)
                if (result != m3Err_none) { return result }
            }
            o.wasmStack[i] = o_preservedSlotNumber
        }
        i++
    }
    return m3Err_none
}


def GetBlockScope(var o : IM3Compilation; var o_scope : IM3CompilationScope&; var i_depth : u32) : M3Result {
    var scope : IM3CompilationScope = unsafe(addr(o._block))
    while (i_depth != 0u) {
        scope = scope.outer
        if (scope == null) { return "invalid block depth" }
        i_depth--
    }
    o_scope = scope
    return m3Err_none
}


def CopyStackSlotsR(var o : IM3Compilation; i_targetSlotStackIndex : int; i_stackIndex : int; i_endStackIndex : int; var i_tempSlot : int) : M3Result {
    if (i_stackIndex < i_endStackIndex) {
        let srcSlot = GetSlotForStackIndex(o, i_stackIndex)
        let _type = GetStackTypeFromBottom(o, i_stackIndex)
        let numSlots = GetTypeNumSlots(_type)
        let extraSlot = numSlots - 1
        let targetSlot = GetSlotForStackIndex(o, i_targetSlotStackIndex)
        var preserveIndex = i_stackIndex
        var collisionSlot = srcSlot

        if (targetSlot != srcSlot) {
            var checkIndex = i_stackIndex + 1
            while (checkIndex < i_endStackIndex) {
                let otherSlot1 = GetSlotForStackIndex(o, checkIndex)
                let otherSlot2 = GetExtraSlotForStackIndex(o, checkIndex)
                if (targetSlot == otherSlot1 || targetSlot == otherSlot2 || targetSlot + extraSlot == otherSlot1) {
                    if (i_tempSlot >= int(d_m3MaxFunctionSlots)) { return m3Err_functionStackOverflow }
                    let result = CopyStackIndexToSlot(o, i_tempSlot, checkIndex)
                    if (result != m3Err_none) { return result }
                    o.wasmStack[checkIndex] = i_tempSlot
                    i_tempSlot += GetTypeNumSlots(int(u8(M3ValueType.c_m3Type_i64)))
                    TouchSlot(o, i_tempSlot - 1)
                    preserveIndex = checkIndex
                    collisionSlot = otherSlot1
                    break
                }
                checkIndex++
            }

            let result = CopyStackIndexToSlot(o, targetSlot, i_stackIndex)
            if (result != m3Err_none) { return result }
                        o.wasmStack[i_stackIndex] = targetSlot
        }

        let result = CopyStackSlotsR(o, i_targetSlotStackIndex + 1, i_stackIndex + 1, i_endStackIndex, i_tempSlot)
        if (result != m3Err_none) { return result }
        o.wasmStack[i_stackIndex] = srcSlot
        o.wasmStack[preserveIndex] = collisionSlot
    }
    return m3Err_none
}


def ResolveBlockResults(var o : IM3Compilation; var i_targetBlock : IM3CompilationScope; i_isBranch : bool) : M3Result {
    // compiled out under the active configuration: d_m3LogWasmStack == false
    let isLoop = i_targetBlock.opcode == c_waOp_loop && i_isBranch
    let numParams = int(GetFuncTypeNumParams(i_targetBlock._type))
    let numResults = int(GetFuncTypeNumResults(i_targetBlock._type))
    var slotRecords = i_targetBlock.exitStackIndex
    var numValues : int
    if (!isLoop) {
        numValues = numResults
        slotRecords += numParams
    } else {
        numValues = numParams
    }

    let blockHeight = GetNumBlockValuesOnStack(o)
    if ((i_isBranch && blockHeight < numValues) || (!i_isBranch && blockHeight != numValues)) {
        return m3Err_typeCountMismatch
    }

    if (numValues != 0) {
        var endIndex = GetStackTopIndex(o) + 1
        var numRemValues = numValues
        if (!isLoop && IsFpType(u8(GetStackTopType(o)))) {
            let result = CopyStackTopToRegister(o, false)
            if (result != m3Err_none) { return result }
            endIndex--
            numRemValues--
        }
        var tempSlot = o.maxStackSlots
        AlignSlotToType(tempSlot, int(u8(M3ValueType.c_m3Type_i64)))
        let result = CopyStackSlotsR(o, slotRecords, endIndex - numRemValues, endIndex, tempSlot)
        if (result != m3Err_none) { return result }
        // compiled out under the active configuration: d_m3LogWasmStack == false
    }
    return m3Err_none
}


def ReturnValues(var o : IM3Compilation; var i_functionBlock : IM3CompilationScope; i_isBranch : bool) : M3Result {
    // compiled out under the active configuration: d_m3LogWasmStack == false
    var numReturns = int(GetFuncTypeNumResults(i_functionBlock._type))
    let blockHeight = GetNumBlockValuesOnStack(o)
    if (!IsStackPolymorphic(o) && ((i_isBranch && blockHeight < numReturns) || (!i_isBranch && blockHeight != numReturns))) {
        return m3Err_typeCountMismatch
    }

    if (numReturns != 0) {
        var returnSlot = numReturns * c_ioSlotCount
        var stackTop = GetStackTopIndex(o)
        var i : int = 0
        while (i < numReturns) {
            let returnType : int = int(GetFuncTypeResultType(i_functionBlock._type, u16(numReturns - 1 - i)))
            var stackType = GetStackTypeFromTop(o, i)
            if (IsStackPolymorphic(o) && stackType == int(u8(M3ValueType.c_m3Type_none))) { stackType = returnType }
            if (returnType != stackType) { return m3Err_typeMismatch }
            if (!IsStackPolymorphic(o)) {
                returnSlot -= c_ioSlotCount
                let result = CopyStackIndexToSlot(o, returnSlot, stackTop)
                if (result != m3Err_none) { return result }
                stackTop--
            }
            i++
        }
        if (!i_isBranch) {
            while (numReturns != 0) {
                let result = Pop(o)
                if (result != m3Err_none) { return result }
                numReturns--
            }
        }
    }
    return m3Err_none
}


def Compile_Const_i32(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var value : i32
    var result = ReadLEB_i32(value, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    // C passes the i32 to the u64 parameter of PushConst: integer promotion
    // sign-extends it, which is what makes the constant-slot search miss
    // negative i32 constants (see PushConst). Kept as in C.
    result = PushConst(o, u64(i64(value)), int(u8(M3ValueType.c_m3Type_i32)))
    return result
}


def Compile_Const_i64(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var value : i64
    var result = ReadLEB_i64(value, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    result = PushConst(o, u64(value), int(u8(M3ValueType.c_m3Type_i64)))
    return result
}


def Compile_Const_f32(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    if (!d_m3ImplementFloat) { return m3Err_unknownOpcode }
    var value : f32
    let result = Read_f32(value, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    let bits = unsafe(reinterpret<u32>(value))
        return PushConst(o, u64(bits), int(u8(M3ValueType.c_m3Type_f32))) }


def Compile_Const_f64(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    if (!d_m3ImplementFloat) { return m3Err_unknownOpcode }
    var value : f64
    let result = Read_f64(value, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    let bits = unsafe(reinterpret<u64>(value))
        return PushConst(o, bits, int(u8(M3ValueType.c_m3Type_f64))) }


def Compile_ExtendedOpcode(var o : IM3Compilation; var i_opcode : m3opcode_t) : M3Result {
    if (!d_m3CascadedOpcodes) { return m3Err_unknownOpcode }
    var opcode : u8
    var result = Read_u8(opcode, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
        i_opcode = m3opcode_t((int(i_opcode) << 8) | int(opcode))
    let opInfo = GetOpInfo(i_opcode)
    if (opInfo == null) { return m3Err_unknownOpcode }
    let compiler = opInfo.compiler
    // C: _throwif (m3Err_noCompiler, not compiler); NULL is the c_noCompiler sentinel here.
    if (IsNoCompiler(compiler)) { return m3Err_noCompiler }
    result = compiler(o, i_opcode)
    if (result == m3Err_none) { o.previousOpcode = i_opcode }
    return result
}


def Compile_Return(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    if (!IsStackPolymorphic(o)) {
        var functionScope : IM3CompilationScope
        var result = GetBlockScope(o, functionScope, u32(o._block.depth))
        if (result != m3Err_none) { return result }
        result = ReturnValues(o, functionScope, true)
        if (result != m3Err_none) { return result }
        result = EmitOp(o, @@op_Return)
        if (result != m3Err_none) { return result }
        return SetStackPolymorphic(o)
    }
    return m3Err_none
}


def ValidateBlockEnd(var o : IM3Compilation) : M3Result {
    return m3Err_none
}


def Compile_End(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    if (o._block.depth == 0) {
        ValidateBlockEnd(o)
        if (o._function != null) {
            let result = ReturnValues(o, unsafe(addr(o._block)), false)
            if (result != m3Err_none) { return result }
        }
        return EmitOp(o, @@op_Return)
    }
    return m3Err_none
}


def Compile_SetLocal(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var localIndex : u32
    var result = ReadLEB_u32(localIndex, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    if (localIndex >= GetFunctionNumArgsAndLocals(o._function)) { return "local index out of bounds" }

    let localSlot = GetSlotForStackIndex(o, int(localIndex))
    var preserveSlot : int
    result = FindReferencedLocalWithinCurrentBlock(o, preserveSlot, u32(localSlot))
    if (result != m3Err_none) { return result }
    if (preserveSlot == localSlot) {
        result = CopyStackTopToSlot(o, localSlot)
    } else {
        result = PreservedCopyTopSlot(o, localSlot, preserveSlot)
    }
    if (result != m3Err_none) { return result }
    if (i_opcode != c_waOp_teeLocal) { return Pop(o) }
    return m3Err_none
}


def Compile_GetLocal(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var localIndex : u32
    let result = ReadLEB_u32(localIndex, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    if (localIndex >= GetFunctionNumArgsAndLocals(o._function)) { return "local index out of bounds" }
    return Push(o, GetStackTypeFromBottom(o, int(localIndex)), GetSlotForStackIndex(o, int(localIndex)))
}


def Compile_GetGlobal(var o : IM3Compilation; i_global : M3Global?) : M3Result {
    var op : IM3Operation = @@op_GetGlobal_s32
    if (Is64BitType(i_global._type)) { op = @@op_GetGlobal_s64 }
    let result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    EmitPointer(o, unsafe(addr(i_global.valueBits)))
    return PushAllocatedSlotAndEmit(o, int(i_global._type))
}


def Compile_SetGlobal(var o : IM3Compilation; var i_global : M3Global?) : M3Result {
    if (!i_global.isMutable) { return m3Err_settingImmutableGlobal }
    let _type = GetStackTopType(o)
    var op : IM3Operation
    if (IsStackTopInRegister(o)) {
        op = c_setGlobalOps[_type]
    } elif (Is64BitType(u8(_type))) {
        op = @@op_SetGlobal_s64
    } else {
        op = @@op_SetGlobal_s32
    }
    let result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    EmitPointer(o, unsafe(addr(i_global.valueBits)))
    if (IsStackTopInSlot(o)) { EmitSlotOffset(o, GetStackTopSlotNumber(o)) }
    return Pop(o)
}


def Compile_GetSetGlobal(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var globalIndex : u32
    let result = ReadLEB_u32(globalIndex, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    if (globalIndex >= o._module.numGlobals) { return m3Err_globaIndexOutOfBounds }
    if (o._module.globals == null) {
        return ErrorCompile(m3Err_globalMemoryNotAllocated, o, "module '{o._module.name}' is missing global memory")
    }
    var global : IM3Global

    unsafe { global = addr(o._module.globals[globalIndex]) }
    if (i_opcode == c_waOp_getGlobal) { return Compile_GetGlobal(o, global) }
    return Compile_SetGlobal(o, global)
}


def EmitPatchingBranchPointer(var o : IM3Compilation; var i_scope : IM3CompilationScope) {
    var patch = EmitPointer(o, i_scope.patches)
        i_scope.patches = patch
}


def EmitPatchingBranch(var o : IM3Compilation; var i_scope : IM3CompilationScope) : M3Result {
    let result = EmitOp(o, @@op_Branch)
    if (result != m3Err_none) { return result }
    EmitPatchingBranchPointer(o, i_scope)
    return m3Err_none
}


def Compile_Branch(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var depth : u32
    var result = ReadLEB_u32(depth, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    var scope : IM3CompilationScope
    result = GetBlockScope(o, scope, depth)
    if (result != m3Err_none) { return result }

    if (scope.opcode == c_waOp_loop) {
        if (i_opcode == c_waOp_branchIf) {
            if (int(GetFuncTypeNumParams(scope._type)) != 0) {
                var op = @@op_BranchIfPrologue_s
                if (IsStackTopInRegister(o)) { op = @@op_BranchIfPrologue_r }
                result = EmitOp(o, op)
                if (result != m3Err_none) { return result }
                result = EmitSlotNumOfStackTopAndPop(o)
                if (result != m3Err_none) { return result }
                var jumpTo = unsafe(reinterpret<pc_t?>(ReservePointer(o)))
                result = ResolveBlockResults(o, scope, true)
                if (result != m3Err_none) { return result }
                result = EmitOp(o, @@op_ContinueLoop)
                if (result != m3Err_none) { return result }
                EmitPointer(o, scope.pc)
                unsafe { jumpTo[0] = GetPC(o) }
            } else {
                result = CopyStackTopToRegister(o, false)
                if (result != m3Err_none) { return result }
                result = PopType(o, int(u8(M3ValueType.c_m3Type_i32)))
                if (result != m3Err_none) { return result }
                result = EmitOp(o, @@op_ContinueLoopIf)
                if (result != m3Err_none) { return result }
                EmitPointer(o, scope.pc)
            }
        } else {
            result = EmitOp(o, @@op_ContinueLoop)
            if (result != m3Err_none) { return result }
            EmitPointer(o, scope.pc)
            o._block.isPolymorphic = true
        }
        return m3Err_none
    }

    var jumpTo : pc_t? = null
    let isReturn = scope.depth == 0
    let targetHasResults = int(GetFuncTypeNumResults(scope._type)) != 0

    if (i_opcode == c_waOp_branchIf) {
        if (targetHasResults || isReturn) {
            var op = @@op_BranchIfPrologue_s
                if (IsStackTopInRegister(o)) { op = @@op_BranchIfPrologue_r }
            result = EmitOp(o, op)
            if (result != m3Err_none) { return result }
            result = EmitSlotNumOfStackTopAndPop(o)
            if (result != m3Err_none) { return result }
            jumpTo = unsafe(reinterpret<pc_t?>(ReservePointer(o)))
        } else {
            var op = @@op_BranchIf_s
            if (IsStackTopInRegister(o)) { op = @@op_BranchIf_r }
            result = EmitOp(o, op)
            if (result != m3Err_none) { return result }
            result = EmitSlotNumOfStackTopAndPop(o)
            if (result != m3Err_none) { return result }
            EmitPatchingBranchPointer(o, scope)
            return m3Err_none
        }
    }

    if (!IsStackPolymorphic(o)) {
        if (isReturn) {
            result = ReturnValues(o, scope, true)
            if (result != m3Err_none) { return result }
            result = EmitOp(o, @@op_Return)
        } else {
            result = ResolveBlockResults(o, scope, true)
            if (result != m3Err_none) { return result }
            result = EmitPatchingBranch(o, scope)
        }
        if (result != m3Err_none) { return result }
    }

    if (jumpTo != null) { unsafe { jumpTo[0] = GetPC(o) } }
    if (i_opcode == c_waOp_branch) { return SetStackPolymorphic(o) }
    return m3Err_none
}


def Compile_BranchTable(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var targetCount : u32
    var result = ReadLEB_u32(targetCount, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_i64)))
    if (result != m3Err_none) { return result }
    let slot = GetStackTopSlotNumber(o)
    result = Pop(o)
    if (result != m3Err_none) { return result }

    let numCodeLines = targetCount + 4u
    result = EnsureCodePageNumLines(o, numCodeLines)
    if (result != m3Err_none) { return result }
    result = EmitOp(o, @@op_BranchTable)
    if (result != m3Err_none) { return result }
    EmitSlotOffset(o, slot)
    EmitConstant32(o, targetCount)

    var continueOpPage : IM3CodePage = null
    targetCount++
    var i : u32 = 0u
    while (i < targetCount) {
        var target : u32
        result = ReadLEB_u32(target, o.wasm, o.wasmEnd)
        if (result != m3Err_none) { return result }
        var scope : IM3CompilationScope
        result = GetBlockScope(o, scope, target)
        if (result != m3Err_none) { return result }
        result = AcquireCompilationCodePage(o, continueOpPage)
        if (result != m3Err_none) { return result }

        let startPC = GetPagePC(continueOpPage)
        var savedPage = o.page
        o.page = continueOpPage

        if (scope.opcode == c_waOp_loop) {
            result = ResolveBlockResults(o, scope, true)
            if (result == m3Err_none) { result = EmitOp(o, @@op_ContinueLoop) }
            if (result == m3Err_none) { EmitPointer(o, scope.pc) }
        } elif (!IsStackPolymorphic(o)) {
            if (scope.depth == 0) {
                result = ReturnValues(o, scope, true)
                if (result == m3Err_none) { result = EmitOp(o, @@op_Return) }
            } else {
                result = ResolveBlockResults(o, scope, true)
                if (result == m3Err_none) { result = EmitPatchingBranch(o, scope) }
            }
        }

        if (result != m3Err_none) { return result }
        ReleaseCompilationCodePage(o)
        o.page = savedPage
        EmitPointer(o, startPC)
        i++
    }
    return SetStackPolymorphic(o)
}


def CompileCallArgsAndReturn(var o : IM3Compilation; var o_stackOffset : int&; var i_type : IM3FuncType; i_isIndirect : bool) : M3Result {
    var topSlot = GetMaxUsedSlotPlusOne(o)
    topSlot = max(1, topSlot)
    AlignSlotToType(topSlot, int(u8(M3ValueType.c_m3Type_i64)))
    o_stackOffset = topSlot
    if (i_isIndirect) {
        let result = Pop(o)
        if (result != m3Err_none) { return result }
    }

    var numArgs = int(GetFuncTypeNumParams(i_type))
    var numRets = int(GetFuncTypeNumResults(i_type))
    var argTop = topSlot + (numArgs + numRets) * c_ioSlotCount
    while (numArgs != 0) {
        argTop -= c_ioSlotCount
        var result = CopyStackTopToSlot(o, argTop)
        if (result != m3Err_none) { return result }
        result = Pop(o)
        if (result != m3Err_none) { return result }
        numArgs--
    }

    var i : int = 0
    while (numRets != 0) {
        var _type : int = int(GetFuncTypeResultType(i_type, u16(i)))
        var result = Push(o, _type, topSlot)
        if (result != m3Err_none) { return result }
        result = MarkSlotsAllocatedByType(o, topSlot, _type)
        if (result != m3Err_none) { return result }
        topSlot += c_ioSlotCount
        i++
        numRets--
    }
    return m3Err_none
}


def Compile_Call(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var functionIndex : u32
    var result = ReadLEB_u32(functionIndex, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    var _function = Module_GetFunction(o._module, functionIndex)
    if (_function == null) { return m3Err_functionLookupFailed }

        if (_function._module == null) {
        return ErrorCompile(m3Err_functionImportMissing, o, "'{GetFunctionImportModuleName(_function)}.{m3_GetFunctionName(_function)}'")
    }

    var slotTop : int
    result = CompileCallArgsAndReturn(o, slotTop, _function.funcType, false)
    if (result != m3Err_none) { return result }
    var op : IM3Operation
    var operand : void const?
    if (_function.compiled != null) {
        op = @@op_Call
        operand = unsafe(reinterpret<void const?>(_function.compiled))
    } else {
        op = @@op_Compile
        operand = unsafe(reinterpret<void const?>(_function))
    }
    result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    EmitPointer(o, operand)
    EmitSlotOffset(o, slotTop)
    return m3Err_none
}


def Compile_CallIndirect(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var typeIndex : u32
    var result = ReadLEB_u32(typeIndex, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    var tableIndex : u32
    result = ReadLEB_u32(tableIndex, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    if (typeIndex >= o._module.numFuncTypes) { return "function call type index out of range" }

    if (IsStackTopInRegister(o)) {
        result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_i32)))
        if (result != m3Err_none) { return result }
    }
    let tableIndexSlot = GetStackTopSlotNumber(o)
    var execTop : int
    var _type : IM3FuncType
    unsafe { _type = o._module.funcTypes[int(typeIndex)] }
    result = CompileCallArgsAndReturn(o, execTop, _type, true)
    if (result != m3Err_none) { return result }
    result = EmitOp(o, @@op_CallIndirect)
    if (result != m3Err_none) { return result }
    EmitSlotOffset(o, tableIndexSlot)
    EmitPointer(o, o._module)
    EmitPointer(o, _type)
    EmitSlotOffset(o, execTop)
    return m3Err_none
}


def Compile_Memory_Size(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var reserved : i8
    var result = ReadLEB_i7(reserved, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_i32)))
    if (result != m3Err_none) { return result }
    result = EmitOp(o, @@op_MemSize)
    if (result != m3Err_none) { return result }
    return PushRegister(o, int(u8(M3ValueType.c_m3Type_i32)))
}


def Compile_Memory_Grow(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var reserved : i8
    var result = ReadLEB_i7(reserved, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    result = CopyStackTopToRegister(o, false)
    if (result != m3Err_none) { return result }
    result = PopType(o, int(u8(M3ValueType.c_m3Type_i32)))
    if (result != m3Err_none) { return result }
    result = EmitOp(o, @@op_MemGrow)
    if (result != m3Err_none) { return result }
    return PushRegister(o, int(u8(M3ValueType.c_m3Type_i32)))
}


def Compile_Memory_CopyFill(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var sourceMemoryIdx : u32 = 0u
    var targetMemoryIdx : u32
    var op : IM3Operation
    var result : M3Result = m3Err_none
    if (i_opcode == c_waOp_memoryCopy) {
        result = ReadLEB_u32(sourceMemoryIdx, o.wasm, o.wasmEnd)
        if (result != m3Err_none) { return result }
        op = @@op_MemCopy
    } else {
        op = @@op_MemFill
    }
    result = ReadLEB_u32(targetMemoryIdx, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    result = CopyStackTopToRegister(o, false)
    if (result != m3Err_none) { return result }
    result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    result = PopType(o, int(u8(M3ValueType.c_m3Type_i32)))
    if (result != m3Err_none) { return result }
    result = EmitSlotNumOfStackTopAndPop(o)
    if (result != m3Err_none) { return result }
    return EmitSlotNumOfStackTopAndPop(o)
}


def ReadBlockType(var o : IM3Compilation; var o_blockType : IM3FuncType&) : M3Result {
    var _type : i64
    var result = ReadLebSigned(_type, 33u, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    if (_type < 0l) {
        var valueType : u8
        result = NormalizeType(valueType, i8(_type))
        if (result != m3Err_none) { return result }
                o_blockType = o._module.environment.retFuncTypes[int(valueType)]
    } else {
        if (u64(_type) >= u64(o._module.numFuncTypes)) { return "func type out of bounds" }
        unsafe { o_blockType = o._module.funcTypes[int(_type)] }
            }
    return m3Err_none
}


def PreserveArgsAndLocals(var o : IM3Compilation) : M3Result {
    if (o.stackIndex > o.stackFirstDynamicIndex) {
        let numArgsAndLocals = GetFunctionNumArgsAndLocals(o._function)
        var i : u32 = 0u
        while (i < numArgsAndLocals) {
            let slot = GetSlotForStackIndex(o, int(i))
            var preservedSlotNumber : int
            let result = FindReferencedLocalWithinCurrentBlock(o, preservedSlotNumber, u32(slot))
            if (result != m3Err_none) { return result }
            if (preservedSlotNumber != slot) {
                let _type = GetStackTypeFromBottom(o, int(i))
                d_m3Assert(_type != int(u8(M3ValueType.c_m3Type_none)))
                var op : IM3Operation = @@op_CopySlot_32
                if (Is64BitType(u8(_type))) { op = @@op_CopySlot_64 }
                // Original C intentionally ignores EmitOp's result here.
                EmitOp(o, op)
                EmitSlotOffset(o, preservedSlotNumber)
                EmitSlotOffset(o, slot)
            }
            i++
        }
    }
    return m3Err_none
}


def Compile_LoopOrBlock(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var result = PreserveRegisters(o)
    if (result != m3Err_none) { return result }
    result = PreserveArgsAndLocals(o)
    if (result != m3Err_none) { return result }
    var blockType : IM3FuncType
    result = ReadBlockType(o, blockType)
    if (result != m3Err_none) { return result }

    if (i_opcode == c_waOp_loop) {
        let numParams = int(GetFuncTypeNumParams(blockType))
        if (numParams != 0) {
            let numValues = GetNumBlockValuesOnStack(o)
            d_m3Assert(numValues >= numParams)
            if (numValues >= numParams) {
                let stackTop = GetStackTopIndex(o) + 1
                var i = stackTop - numParams
                while (i < stackTop) {
                    let slot = GetSlotForStackIndex(o, i)
                    let _type = GetStackTypeFromBottom(o, i)
                    if (IsConstantSlot(o, slot)) {
                        var newSlot : int = c_slotUnused
                        result = AllocateSlots(o, newSlot, _type)
                        if (result != m3Err_none) { return result }
                        result = CopyStackIndexToSlot(o, newSlot, i)
                        if (result != m3Err_none) { return result }
                        o.wasmStack[i] = newSlot
                    }
                    i++
                }
            }
        }
        result = EmitOp(o, @@op_Loop)
        if (result != m3Err_none) { return result }
    }
    return CompileBlock(o, blockType, i_opcode)
}


def CompileElseBlock(var o : IM3Compilation; var o_startPC : pc_t&; var i_blockType : IM3FuncType) : M3Result {
    var savedPage = o.page
    var elsePage : IM3CodePage
    var result = AcquireCompilationCodePage(o, elsePage)
    if (result != m3Err_none) { return result }
    o_startPC = GetPagePC(elsePage)
    o.page = elsePage
    result = CompileBlock(o, i_blockType, c_waOp_else)
    if (result == m3Err_none) { result = EmitOp(o, @@op_Branch) }
    if (result == m3Err_none) { EmitPointer(o, GetPagePC(savedPage)) }
    if (o.page != savedPage) { ReleaseCompilationCodePage(o) }
    o.page = savedPage
    return result
}


def Compile_If(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var result = PreserveNonTopRegisters(o)
    if (result != m3Err_none) { return result }
    result = PreserveArgsAndLocals(o)
    if (result != m3Err_none) { return result }

    var op : IM3Operation = @@op_If_s
    if (IsStackTopInRegister(o)) { op = @@op_If_r }
    result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    result = EmitSlotNumOfStackTopAndPop(o)
    if (result != m3Err_none) { return result }
    var pc = unsafe(reinterpret<pc_t?>(ReservePointer(o)))

    var blockType : IM3FuncType
    result = ReadBlockType(o, blockType)
    if (result != m3Err_none) { return result }
    let stackIndex = o.stackIndex
    result = CompileBlock(o, blockType, i_opcode)
    if (result != m3Err_none) { return result }

    if (o.previousOpcode == c_waOp_else) {
        o.stackIndex = stackIndex
        var startPC : pc_t
        result = CompileElseBlock(o, startPC, blockType)
        if (result != m3Err_none) { return result }
        unsafe { pc[0] = startPC }
    } elif (int(GetFuncTypeNumResults(blockType)) != 0) {
        unsafe { o.wasm = o.wasm - 1 }
        o.stackIndex = stackIndex
        var startPC : pc_t
        result = CompileElseBlock(o, startPC, blockType)
        if (result != m3Err_none) { return result }
        unsafe { pc[0] = startPC }
    } else {
        unsafe { pc[0] = GetPC(o) }
    }
    return m3Err_none
}


def Compile_Select(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var slots = fixed_array(c_slotUnused, c_slotUnused, c_slotUnused)
    let _type = GetStackTypeFromTop(o, 1)
    var op : IM3Operation = c_opNull
    var result : M3Result = m3Err_none

    if (IsFpType(u8(_type))) {
        if (!d_m3HasFloat) { return m3Err_unknownOpcode }
        if (!IsStackTopMinus1InRegister(o) && !IsStackTopMinus2InRegister(o)) {
            result = PreserveRegisterIfOccupied(o, _type)
            if (result != m3Err_none) { return result }
        }
        let selectorInReg = IsStackTopInRegister(o)
        slots[0] = GetStackTopSlotNumber(o)
        result = Pop(o)
        if (result != m3Err_none) { return result }
        var opIndex : u32 = 0u
        var i : u32 = 1u
        while (i <= 2u) {
            if (IsStackTopInRegister(o)) { opIndex = i } else { slots[i] = GetStackTopSlotNumber(o) }
            result = Pop(o)
            if (result != m3Err_none) { return result }
            i++
        }
        var selectorIndex : u32 = 0u
        if (selectorInReg) { selectorIndex = 1u }
        op = c_fpSelectOps[_type - int(u8(M3ValueType.c_m3Type_f32))][selectorIndex][opIndex]
    } elif (IsIntType(u8(_type))) {
        if (!IsStackTopInRegister(o) && !IsStackTopMinus1InRegister(o) && !IsStackTopMinus2InRegister(o)) {
            result = PreserveRegisterIfOccupied(o, _type)
            if (result != m3Err_none) { return result }
        }
        var opIndex : u32 = 3u
        var i : u32 = 0u
        while (i < 3u) {
            if (IsStackTopInRegister(o)) { opIndex = i } else { slots[i] = GetStackTopSlotNumber(o) }
            result = Pop(o)
            if (result != m3Err_none) { return result }
            i++
        }
        op = c_intSelectOps[_type - int(u8(M3ValueType.c_m3Type_i32))][opIndex]
    } elif (!IsStackPolymorphic(o)) {
        return m3Err_functionStackUnderrun
    }

    // Original C does not propagate EmitOp here.
    EmitOp(o, op)
    var i : u32 = 0u
    while (i < 3u) {
        if (IsValidSlot(slots[i])) { EmitSlotOffset(o, slots[i]) }
        i++
    }
    return PushRegister(o, _type)
}


def Compile_Drop(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    let result = Pop(o)
    // compiled out under the active configuration: d_m3LogWasmStack == false
    return result
}


def Compile_Nop(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    return m3Err_none
}


def Compile_Unreachable(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var result = AddTrapRecord(o)
    if (result != m3Err_none) { return result }
    result = EmitOp(o, @@op_Unreachable)
    if (result != m3Err_none) { return result }
    return SetStackPolymorphic(o)
}


def Compile_Operator(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    let opInfo = GetOpInfo(i_opcode)
    if (opInfo == null) { return m3Err_unknownOpcode }
    var result : M3Result = m3Err_none
    var op : IM3Operation = c_opNull

    if (IsFpType(u8(GetStackTopType(o))) && IsIntType(u8(opInfo._type))) {
        result = PreserveRegisterIfOccupied(o, opInfo._type)
        if (result != m3Err_none) { return result }
    }

    if (opInfo.stackOffset == 0) {
        if (IsStackTopInRegister(o)) {
            op = opInfo.operations[0]
        } else {
            result = PreserveRegisterIfOccupied(o, opInfo._type)
            if (result != m3Err_none) { return result }
            op = opInfo.operations[1]
        }
    } else {
        if (IsStackTopInRegister(o)) {
            op = opInfo.operations[0]
            if (IsStackTopMinus1InRegister(o)) {
                d_m3Assert(i_opcode == c_waOp_store_f32 || i_opcode == c_waOp_store_f64)
                op = opInfo.operations[3]
            }
        } elif (IsStackTopMinus1InRegister(o)) {
            op = opInfo.operations[1]
            if (IsNoOp(op)) { op = opInfo.operations[0] }
        } else {
            result = PreserveRegisterIfOccupied(o, opInfo._type)
            if (result != m3Err_none) { return result }
            op = opInfo.operations[2]
        }
    }

    // C: if (op) ... ; an absent table entry is the c_opNull sentinel here.
    if (!IsNoOp(op)) {
        result = EmitOp(o, op)
        if (result != m3Err_none) { return result }
        result = EmitSlotNumOfStackTopAndPop(o)
        if (result != m3Err_none) { return result }
        if (opInfo.stackOffset < 0) {
            result = EmitSlotNumOfStackTopAndPop(o)
            if (result != m3Err_none) { return result }
        }
        if (opInfo._type != int(u8(M3ValueType.c_m3Type_none))) {
            result = PushRegister(o, opInfo._type)
            if (result != m3Err_none) { return result }
        }
        return m3Err_none
    }

    // C (non-DEBUG): ErrorCompile ("no operation found for opcode", o, "%x", i_opcode)
    return ErrorCompile("no operation found for opcode", o, "{int(i_opcode):x}")
}


def Compile_Convert(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    let opInfo = GetOpInfo(i_opcode)
    if (opInfo == null) { return m3Err_unknownOpcode }
    let destInSlot = IsRegisterTypeAllocated(o, opInfo._type)
    let sourceInSlot = IsStackTopInSlot(o)
    var opIndex : u32 = 0u
    if (destInSlot) { opIndex += 2u }
    if (sourceInSlot) { opIndex++ }
    let op = opInfo.operations[opIndex]
    var result = EmitOp(o, op)
    if (result != m3Err_none) { return result }
    result = EmitSlotNumOfStackTopAndPop(o)
    if (result != m3Err_none) { return result }
    if (destInSlot) { return PushAllocatedSlotAndEmit(o, opInfo._type) }
    return PushRegister(o, opInfo._type)
}


def Compile_Load_Store(var o : IM3Compilation; i_opcode : m3opcode_t) : M3Result {
    var alignHint : u32
    var memoryOffset : u32
    var result = ReadLEB_u32(alignHint, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
    result = ReadLEB_u32(memoryOffset, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }
        let opInfo = GetOpInfo(i_opcode)
    if (opInfo == null) { return m3Err_unknownOpcode }
    if (IsFpType(u8(opInfo._type))) {
        result = PreserveRegisterIfOccupied(o, int(u8(M3ValueType.c_m3Type_f64)))
        if (result != m3Err_none) { return result }
    }
    result = Compile_Operator(o, i_opcode)
    if (result != m3Err_none) { return result }
    EmitConstant32(o, memoryOffset)
    return m3Err_none
}


def CompileRawFunction(var io_module : IM3Module; var io_function : IM3Function; i_function : void const?; i_userdata : void const?) : M3Result {
    d_m3Assert(io_module.runtime != null)
    var page = AcquireCodePageWithCapacity(io_module.runtime, 4u)
    if (page == null) { return m3Err_mallocFailedCodePage }
    io_function.compiled = GetPagePC(page)
    io_function._module = io_module
    EmitWord(page, @@op_CallRawFunction)
    EmitWord_impl(page, unsafe(reinterpret<void?>(i_function)))
    EmitWord(page, io_function)
    EmitWord_impl(page, unsafe(reinterpret<void?>(i_userdata)))
    ReleaseCodePage(io_module.runtime, page)
    return m3Err_none
}


// C preprocessor operation-list expansion, kept local to this table construction.
def M3OP(name : string; stackOffset : int; _type : int; o0 : IM3Operation; o1 : IM3Operation; o2 : IM3Operation; o3 : IM3Operation; compiler : M3CompilerMutable) : M3OpInfo {
    /* C: #define M3OP(NAME, ...) { __VA_ARGS__ } — the array literal becomes the fixed argument list above. */
    return M3OpInfo(stackOffset = stackOffset, _type = _type, operations = fixed_array(o0, o1, o2, o3), compiler = compiler)
}

def M3OP_RESERVED() : M3OpInfo {
    return M3OpInfo(stackOffset = 0, _type = int(u8(M3ValueType.c_m3Type_none)),
        operations = fixed_array(c_opNull, c_opNull, c_opNull, c_opNull), compiler = c_noCompiler)
}

def M3OP_F(name : string; stackOffset : int; _type : int; o0 : IM3Operation; o1 : IM3Operation; o2 : IM3Operation; o3 : IM3Operation; compiler : M3CompilerMutable) : M3OpInfo {
    if (d_m3HasFloat) { return M3OP(name, stackOffset, _type, o0, o1, o2, o3, compiler) }
    if (d_m3NoFloatDynamic) {
        return M3OP(name, stackOffset, _type,
            @@op_Unsupported, @@op_Unsupported, @@op_Unsupported, @@op_Unsupported, compiler)
    }
    return M3OP_RESERVED()
}

var c_operations : M3OpInfo[253]
var c_operationsFC : M3OpInfo[12]
var c_operationsInitialized : bool = false

// C: `const M3OpInfo c_operations []` is a static initialiser (m3_compile.c).
// Daslang fills the table at context start through [init]. A host that does
// not run [init] for required shared modules (dastest with a test file that
// declares a module) reaches it through m3_NewEnvironment instead, so the
// fill is guarded and idempotent.
[init]
def init_compile_operation_tables() {
    if (c_operationsInitialized) return
    c_operationsInitialized = true
    c_operations = fixed_array(
    M3OP("unreachable", 0, none, @@op_Unreachable, c_opNull, c_opNull, c_opNull, @@Compile_Unreachable), // 0x00
    M3OP("nop", 0, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Nop), // 0x01
    M3OP("block", 0, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_LoopOrBlock), // 0x02
    M3OP("loop", 0, none, @@op_Loop, c_opNull, c_opNull, c_opNull, @@Compile_LoopOrBlock), // 0x03
    M3OP("if", -1, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_If), // 0x04
    M3OP("else", 0, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Nop), // 0x05
    M3OP_RESERVED(), // 0x06
    M3OP_RESERVED(), // 0x07
    M3OP_RESERVED(), // 0x08
    M3OP_RESERVED(), // 0x09
    M3OP_RESERVED(), // 0x0a
    M3OP("end", 0, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_End), // 0x0b
    M3OP("br", 0, none, @@op_Branch, c_opNull, c_opNull, c_opNull, @@Compile_Branch), // 0x0c
    M3OP("br_if", -1, none, @@op_BranchIf_r, @@op_BranchIf_s, c_opNull, c_opNull, @@Compile_Branch), // 0x0d
    M3OP("br_table", -1, none, @@op_BranchTable, c_opNull, c_opNull, c_opNull, @@Compile_BranchTable), // 0x0e
    M3OP("return", 0, any, @@op_Return, c_opNull, c_opNull, c_opNull, @@Compile_Return), // 0x0f
    M3OP("call", 0, any, @@op_Call, c_opNull, c_opNull, c_opNull, @@Compile_Call), // 0x10
    M3OP("call_indirect", 0, any, @@op_CallIndirect, c_opNull, c_opNull, c_opNull, @@Compile_CallIndirect), // 0x11
    M3OP("return_call", 0, any, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Call), // 0x12
    M3OP("return_call_indirect", 0, any, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_CallIndirect), // 0x13
    M3OP_RESERVED(), // 0x14
    M3OP_RESERVED(), // 0x15
    M3OP_RESERVED(), // 0x16
    M3OP_RESERVED(), // 0x17
    M3OP_RESERVED(), // 0x18
    M3OP_RESERVED(), // 0x19
    M3OP("drop", -1, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Drop), // 0x1a
    M3OP("select", -2, any, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Select), // 0x1b
    M3OP_RESERVED(), // 0x1c
    M3OP_RESERVED(), // 0x1d
    M3OP_RESERVED(), // 0x1e
    M3OP_RESERVED(), // 0x1f
    M3OP("local.get", 1, any, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_GetLocal), // 0x20
    M3OP("local.set", 1, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_SetLocal), // 0x21
    M3OP("local.tee", 0, any, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_SetLocal), // 0x22
    M3OP("global.get", 1, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_GetSetGlobal), // 0x23
    M3OP("global.set", 1, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_GetSetGlobal), // 0x24
    M3OP_RESERVED(), // 0x25
    M3OP_RESERVED(), // 0x26
    M3OP_RESERVED(), // 0x27
    M3OP("i32.load", 0, i_32, @@op_i32_Load_i32_r, @@op_i32_Load_i32_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x28
    M3OP("i64.load", 0, i_64, @@op_i64_Load_i64_r, @@op_i64_Load_i64_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x29
    M3OP_F("f32.load", 0, f_32, @@op_f32_Load_f32_r, @@op_f32_Load_f32_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x2a
    M3OP_F("f64.load", 0, f_64, @@op_f64_Load_f64_r, @@op_f64_Load_f64_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x2b
    M3OP("i32.load8_s", 0, i_32, @@op_i32_Load_i8_r, @@op_i32_Load_i8_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x2c
    M3OP("i32.load8_u", 0, i_32, @@op_i32_Load_u8_r, @@op_i32_Load_u8_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x2d
    M3OP("i32.load16_s", 0, i_32, @@op_i32_Load_i16_r, @@op_i32_Load_i16_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x2e
    M3OP("i32.load16_u", 0, i_32, @@op_i32_Load_u16_r, @@op_i32_Load_u16_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x2f
    M3OP("i64.load8_s", 0, i_64, @@op_i64_Load_i8_r, @@op_i64_Load_i8_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x30
    M3OP("i64.load8_u", 0, i_64, @@op_i64_Load_u8_r, @@op_i64_Load_u8_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x31
    M3OP("i64.load16_s", 0, i_64, @@op_i64_Load_i16_r, @@op_i64_Load_i16_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x32
    M3OP("i64.load16_u", 0, i_64, @@op_i64_Load_u16_r, @@op_i64_Load_u16_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x33
    M3OP("i64.load32_s", 0, i_64, @@op_i64_Load_i32_r, @@op_i64_Load_i32_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x34
    M3OP("i64.load32_u", 0, i_64, @@op_i64_Load_u32_r, @@op_i64_Load_u32_s, c_opNull, c_opNull, @@Compile_Load_Store), // 0x35
    M3OP("i32.store", -2, none, @@op_i32_Store_i32_rs, @@op_i32_Store_i32_sr, @@op_i32_Store_i32_ss, c_opNull, @@Compile_Load_Store), // 0x36
    M3OP("i64.store", -2, none, @@op_i64_Store_i64_rs, @@op_i64_Store_i64_sr, @@op_i64_Store_i64_ss, c_opNull, @@Compile_Load_Store), // 0x37
    M3OP_F("f32.store", -2, none, @@op_f32_Store_f32_rs, @@op_f32_Store_f32_sr, @@op_f32_Store_f32_ss, @@op_f32_Store_f32_rr, @@Compile_Load_Store), // 0x38
    M3OP_F("f64.store", -2, none, @@op_f64_Store_f64_rs, @@op_f64_Store_f64_sr, @@op_f64_Store_f64_ss, @@op_f64_Store_f64_rr, @@Compile_Load_Store), // 0x39
    M3OP("i32.store8", -2, none, @@op_i32_Store_u8_rs, @@op_i32_Store_u8_sr, @@op_i32_Store_u8_ss, c_opNull, @@Compile_Load_Store), // 0x3a
    M3OP("i32.store16", -2, none, @@op_i32_Store_i16_rs, @@op_i32_Store_i16_sr, @@op_i32_Store_i16_ss, c_opNull, @@Compile_Load_Store), // 0x3b
    M3OP("i64.store8", -2, none, @@op_i64_Store_u8_rs, @@op_i64_Store_u8_sr, @@op_i64_Store_u8_ss, c_opNull, @@Compile_Load_Store), // 0x3c
    M3OP("i64.store16", -2, none, @@op_i64_Store_i16_rs, @@op_i64_Store_i16_sr, @@op_i64_Store_i16_ss, c_opNull, @@Compile_Load_Store), // 0x3d
    M3OP("i64.store32", -2, none, @@op_i64_Store_i32_rs, @@op_i64_Store_i32_sr, @@op_i64_Store_i32_ss, c_opNull, @@Compile_Load_Store), // 0x3e
    M3OP("memory.size", 1, i_32, @@op_MemSize, c_opNull, c_opNull, c_opNull, @@Compile_Memory_Size), // 0x3f
    M3OP("memory.grow", 1, i_32, @@op_MemGrow, c_opNull, c_opNull, c_opNull, @@Compile_Memory_Grow), // 0x40
    M3OP("i32.const", 1, i_32, @@op_Const32, c_opNull, c_opNull, c_opNull, @@Compile_Const_i32), // 0x41
    M3OP("i64.const", 1, i_64, @@op_Const64, c_opNull, c_opNull, c_opNull, @@Compile_Const_i64), // 0x42
    M3OP_F("f32.const", 1, f_32, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Const_f32), // 0x43
    M3OP_F("f64.const", 1, f_64, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Const_f64), // 0x44
    M3OP("i32.eqz", 0, i_32, @@op_i32_EqualToZero_r, @@op_i32_EqualToZero_s, c_opNull, c_opNull, c_noCompiler), // 0x45
    M3OP("i32.eq", -1, i_32, @@op_i32_Equal_rs, c_opNull, @@op_i32_Equal_ss, c_opNull, c_noCompiler), // 0x46
    M3OP("i32.ne", -1, i_32, @@op_i32_NotEqual_rs, c_opNull, @@op_i32_NotEqual_ss, c_opNull, c_noCompiler), // 0x47
    M3OP("i32.lt_s", -1, i_32, @@op_i32_LessThan_rs, @@op_i32_LessThan_sr, @@op_i32_LessThan_ss, c_opNull, c_noCompiler), // 0x48
    M3OP("i32.lt_u", -1, i_32, @@op_u32_LessThan_rs, @@op_u32_LessThan_sr, @@op_u32_LessThan_ss, c_opNull, c_noCompiler), // 0x49
    M3OP("i32.gt_s", -1, i_32, @@op_i32_GreaterThan_rs, @@op_i32_GreaterThan_sr, @@op_i32_GreaterThan_ss, c_opNull, c_noCompiler), // 0x4a
    M3OP("i32.gt_u", -1, i_32, @@op_u32_GreaterThan_rs, @@op_u32_GreaterThan_sr, @@op_u32_GreaterThan_ss, c_opNull, c_noCompiler), // 0x4b
    M3OP("i32.le_s", -1, i_32, @@op_i32_LessThanOrEqual_rs, @@op_i32_LessThanOrEqual_sr, @@op_i32_LessThanOrEqual_ss, c_opNull, c_noCompiler), // 0x4c
    M3OP("i32.le_u", -1, i_32, @@op_u32_LessThanOrEqual_rs, @@op_u32_LessThanOrEqual_sr, @@op_u32_LessThanOrEqual_ss, c_opNull, c_noCompiler), // 0x4d
    M3OP("i32.ge_s", -1, i_32, @@op_i32_GreaterThanOrEqual_rs, @@op_i32_GreaterThanOrEqual_sr, @@op_i32_GreaterThanOrEqual_ss, c_opNull, c_noCompiler), // 0x4e
    M3OP("i32.ge_u", -1, i_32, @@op_u32_GreaterThanOrEqual_rs, @@op_u32_GreaterThanOrEqual_sr, @@op_u32_GreaterThanOrEqual_ss, c_opNull, c_noCompiler), // 0x4f
    M3OP("i64.eqz", 0, i_32, @@op_i64_EqualToZero_r, @@op_i64_EqualToZero_s, c_opNull, c_opNull, c_noCompiler), // 0x50
    M3OP("i64.eq", -1, i_32, @@op_i64_Equal_rs, c_opNull, @@op_i64_Equal_ss, c_opNull, c_noCompiler), // 0x51
    M3OP("i64.ne", -1, i_32, @@op_i64_NotEqual_rs, c_opNull, @@op_i64_NotEqual_ss, c_opNull, c_noCompiler), // 0x52
    M3OP("i64.lt_s", -1, i_32, @@op_i64_LessThan_rs, @@op_i64_LessThan_sr, @@op_i64_LessThan_ss, c_opNull, c_noCompiler), // 0x53
    M3OP("i64.lt_u", -1, i_32, @@op_u64_LessThan_rs, @@op_u64_LessThan_sr, @@op_u64_LessThan_ss, c_opNull, c_noCompiler), // 0x54
    M3OP("i64.gt_s", -1, i_32, @@op_i64_GreaterThan_rs, @@op_i64_GreaterThan_sr, @@op_i64_GreaterThan_ss, c_opNull, c_noCompiler), // 0x55
    M3OP("i64.gt_u", -1, i_32, @@op_u64_GreaterThan_rs, @@op_u64_GreaterThan_sr, @@op_u64_GreaterThan_ss, c_opNull, c_noCompiler), // 0x56
    M3OP("i64.le_s", -1, i_32, @@op_i64_LessThanOrEqual_rs, @@op_i64_LessThanOrEqual_sr, @@op_i64_LessThanOrEqual_ss, c_opNull, c_noCompiler), // 0x57
    M3OP("i64.le_u", -1, i_32, @@op_u64_LessThanOrEqual_rs, @@op_u64_LessThanOrEqual_sr, @@op_u64_LessThanOrEqual_ss, c_opNull, c_noCompiler), // 0x58
    M3OP("i64.ge_s", -1, i_32, @@op_i64_GreaterThanOrEqual_rs, @@op_i64_GreaterThanOrEqual_sr, @@op_i64_GreaterThanOrEqual_ss, c_opNull, c_noCompiler), // 0x59
    M3OP("i64.ge_u", -1, i_32, @@op_u64_GreaterThanOrEqual_rs, @@op_u64_GreaterThanOrEqual_sr, @@op_u64_GreaterThanOrEqual_ss, c_opNull, c_noCompiler), // 0x5a
    M3OP_F("f32.eq", -1, i_32, @@op_f32_Equal_rs, c_opNull, @@op_f32_Equal_ss, c_opNull, c_noCompiler), // 0x5b
    M3OP_F("f32.ne", -1, i_32, @@op_f32_NotEqual_rs, c_opNull, @@op_f32_NotEqual_ss, c_opNull, c_noCompiler), // 0x5c
    M3OP_F("f32.lt", -1, i_32, @@op_f32_LessThan_rs, @@op_f32_LessThan_sr, @@op_f32_LessThan_ss, c_opNull, c_noCompiler), // 0x5d
    M3OP_F("f32.gt", -1, i_32, @@op_f32_GreaterThan_rs, @@op_f32_GreaterThan_sr, @@op_f32_GreaterThan_ss, c_opNull, c_noCompiler), // 0x5e
    M3OP_F("f32.le", -1, i_32, @@op_f32_LessThanOrEqual_rs, @@op_f32_LessThanOrEqual_sr, @@op_f32_LessThanOrEqual_ss, c_opNull, c_noCompiler), // 0x5f
    M3OP_F("f32.ge", -1, i_32, @@op_f32_GreaterThanOrEqual_rs, @@op_f32_GreaterThanOrEqual_sr, @@op_f32_GreaterThanOrEqual_ss, c_opNull, c_noCompiler), // 0x60
    M3OP_F("f64.eq", -1, i_32, @@op_f64_Equal_rs, c_opNull, @@op_f64_Equal_ss, c_opNull, c_noCompiler), // 0x61
    M3OP_F("f64.ne", -1, i_32, @@op_f64_NotEqual_rs, c_opNull, @@op_f64_NotEqual_ss, c_opNull, c_noCompiler), // 0x62
    M3OP_F("f64.lt", -1, i_32, @@op_f64_LessThan_rs, @@op_f64_LessThan_sr, @@op_f64_LessThan_ss, c_opNull, c_noCompiler), // 0x63
    M3OP_F("f64.gt", -1, i_32, @@op_f64_GreaterThan_rs, @@op_f64_GreaterThan_sr, @@op_f64_GreaterThan_ss, c_opNull, c_noCompiler), // 0x64
    M3OP_F("f64.le", -1, i_32, @@op_f64_LessThanOrEqual_rs, @@op_f64_LessThanOrEqual_sr, @@op_f64_LessThanOrEqual_ss, c_opNull, c_noCompiler), // 0x65
    M3OP_F("f64.ge", -1, i_32, @@op_f64_GreaterThanOrEqual_rs, @@op_f64_GreaterThanOrEqual_sr, @@op_f64_GreaterThanOrEqual_ss, c_opNull, c_noCompiler), // 0x66
    M3OP("i32.clz", 0, i_32, @@op_u32_Clz_r, @@op_u32_Clz_s, c_opNull, c_opNull, c_noCompiler), // 0x67
    M3OP("i32.ctz", 0, i_32, @@op_u32_Ctz_r, @@op_u32_Ctz_s, c_opNull, c_opNull, c_noCompiler), // 0x68
    M3OP("i32.popcnt", 0, i_32, @@op_u32_Popcnt_r, @@op_u32_Popcnt_s, c_opNull, c_opNull, c_noCompiler), // 0x69
    M3OP("i32.add", -1, i_32, @@op_i32_Add_rs, c_opNull, @@op_i32_Add_ss, c_opNull, c_noCompiler), // 0x6a
    M3OP("i32.sub", -1, i_32, @@op_i32_Subtract_rs, @@op_i32_Subtract_sr, @@op_i32_Subtract_ss, c_opNull, c_noCompiler), // 0x6b
    M3OP("i32.mul", -1, i_32, @@op_i32_Multiply_rs, c_opNull, @@op_i32_Multiply_ss, c_opNull, c_noCompiler), // 0x6c
    M3OP("i32.div_s", -1, i_32, @@op_i32_Divide_rs, @@op_i32_Divide_sr, @@op_i32_Divide_ss, c_opNull, c_noCompiler), // 0x6d
    M3OP("i32.div_u", -1, i_32, @@op_u32_Divide_rs, @@op_u32_Divide_sr, @@op_u32_Divide_ss, c_opNull, c_noCompiler), // 0x6e
    M3OP("i32.rem_s", -1, i_32, @@op_i32_Remainder_rs, @@op_i32_Remainder_sr, @@op_i32_Remainder_ss, c_opNull, c_noCompiler), // 0x6f
    M3OP("i32.rem_u", -1, i_32, @@op_u32_Remainder_rs, @@op_u32_Remainder_sr, @@op_u32_Remainder_ss, c_opNull, c_noCompiler), // 0x70
    M3OP("i32.and", -1, i_32, @@op_u32_And_rs, c_opNull, @@op_u32_And_ss, c_opNull, c_noCompiler), // 0x71
    M3OP("i32.or", -1, i_32, @@op_u32_Or_rs, c_opNull, @@op_u32_Or_ss, c_opNull, c_noCompiler), // 0x72
    M3OP("i32.xor", -1, i_32, @@op_u32_Xor_rs, c_opNull, @@op_u32_Xor_ss, c_opNull, c_noCompiler), // 0x73
    M3OP("i32.shl", -1, i_32, @@op_u32_ShiftLeft_rs, @@op_u32_ShiftLeft_sr, @@op_u32_ShiftLeft_ss, c_opNull, c_noCompiler), // 0x74
    M3OP("i32.shr_s", -1, i_32, @@op_i32_ShiftRight_rs, @@op_i32_ShiftRight_sr, @@op_i32_ShiftRight_ss, c_opNull, c_noCompiler), // 0x75
    M3OP("i32.shr_u", -1, i_32, @@op_u32_ShiftRight_rs, @@op_u32_ShiftRight_sr, @@op_u32_ShiftRight_ss, c_opNull, c_noCompiler), // 0x76
    M3OP("i32.rotl", -1, i_32, @@op_u32_Rotl_rs, @@op_u32_Rotl_sr, @@op_u32_Rotl_ss, c_opNull, c_noCompiler), // 0x77
    M3OP("i32.rotr", -1, i_32, @@op_u32_Rotr_rs, @@op_u32_Rotr_sr, @@op_u32_Rotr_ss, c_opNull, c_noCompiler), // 0x78
    M3OP("i64.clz", 0, i_64, @@op_u64_Clz_r, @@op_u64_Clz_s, c_opNull, c_opNull, c_noCompiler), // 0x79
    M3OP("i64.ctz", 0, i_64, @@op_u64_Ctz_r, @@op_u64_Ctz_s, c_opNull, c_opNull, c_noCompiler), // 0x7a
    M3OP("i64.popcnt", 0, i_64, @@op_u64_Popcnt_r, @@op_u64_Popcnt_s, c_opNull, c_opNull, c_noCompiler), // 0x7b
    M3OP("i64.add", -1, i_64, @@op_i64_Add_rs, c_opNull, @@op_i64_Add_ss, c_opNull, c_noCompiler), // 0x7c
    M3OP("i64.sub", -1, i_64, @@op_i64_Subtract_rs, @@op_i64_Subtract_sr, @@op_i64_Subtract_ss, c_opNull, c_noCompiler), // 0x7d
    M3OP("i64.mul", -1, i_64, @@op_i64_Multiply_rs, c_opNull, @@op_i64_Multiply_ss, c_opNull, c_noCompiler), // 0x7e
    M3OP("i64.div_s", -1, i_64, @@op_i64_Divide_rs, @@op_i64_Divide_sr, @@op_i64_Divide_ss, c_opNull, c_noCompiler), // 0x7f
    M3OP("i64.div_u", -1, i_64, @@op_u64_Divide_rs, @@op_u64_Divide_sr, @@op_u64_Divide_ss, c_opNull, c_noCompiler), // 0x80
    M3OP("i64.rem_s", -1, i_64, @@op_i64_Remainder_rs, @@op_i64_Remainder_sr, @@op_i64_Remainder_ss, c_opNull, c_noCompiler), // 0x81
    M3OP("i64.rem_u", -1, i_64, @@op_u64_Remainder_rs, @@op_u64_Remainder_sr, @@op_u64_Remainder_ss, c_opNull, c_noCompiler), // 0x82
    M3OP("i64.and", -1, i_64, @@op_u64_And_rs, c_opNull, @@op_u64_And_ss, c_opNull, c_noCompiler), // 0x83
    M3OP("i64.or", -1, i_64, @@op_u64_Or_rs, c_opNull, @@op_u64_Or_ss, c_opNull, c_noCompiler), // 0x84
    M3OP("i64.xor", -1, i_64, @@op_u64_Xor_rs, c_opNull, @@op_u64_Xor_ss, c_opNull, c_noCompiler), // 0x85
    M3OP("i64.shl", -1, i_64, @@op_u64_ShiftLeft_rs, @@op_u64_ShiftLeft_sr, @@op_u64_ShiftLeft_ss, c_opNull, c_noCompiler), // 0x86
    M3OP("i64.shr_s", -1, i_64, @@op_i64_ShiftRight_rs, @@op_i64_ShiftRight_sr, @@op_i64_ShiftRight_ss, c_opNull, c_noCompiler), // 0x87
    M3OP("i64.shr_u", -1, i_64, @@op_u64_ShiftRight_rs, @@op_u64_ShiftRight_sr, @@op_u64_ShiftRight_ss, c_opNull, c_noCompiler), // 0x88
    M3OP("i64.rotl", -1, i_64, @@op_u64_Rotl_rs, @@op_u64_Rotl_sr, @@op_u64_Rotl_ss, c_opNull, c_noCompiler), // 0x89
    M3OP("i64.rotr", -1, i_64, @@op_u64_Rotr_rs, @@op_u64_Rotr_sr, @@op_u64_Rotr_ss, c_opNull, c_noCompiler), // 0x8a
    M3OP_F("f32.abs", 0, f_32, @@op_f32_Abs_r, @@op_f32_Abs_s, c_opNull, c_opNull, c_noCompiler), // 0x8b
    M3OP_F("f32.neg", 0, f_32, @@op_f32_Negate_r, @@op_f32_Negate_s, c_opNull, c_opNull, c_noCompiler), // 0x8c
    M3OP_F("f32.ceil", 0, f_32, @@op_f32_Ceil_r, @@op_f32_Ceil_s, c_opNull, c_opNull, c_noCompiler), // 0x8d
    M3OP_F("f32.floor", 0, f_32, @@op_f32_Floor_r, @@op_f32_Floor_s, c_opNull, c_opNull, c_noCompiler), // 0x8e
    M3OP_F("f32.trunc", 0, f_32, @@op_f32_Trunc_r, @@op_f32_Trunc_s, c_opNull, c_opNull, c_noCompiler), // 0x8f
    M3OP_F("f32.nearest", 0, f_32, @@op_f32_Nearest_r, @@op_f32_Nearest_s, c_opNull, c_opNull, c_noCompiler), // 0x90
    M3OP_F("f32.sqrt", 0, f_32, @@op_f32_Sqrt_r, @@op_f32_Sqrt_s, c_opNull, c_opNull, c_noCompiler), // 0x91
    M3OP_F("f32.add", -1, f_32, @@op_f32_Add_rs, c_opNull, @@op_f32_Add_ss, c_opNull, c_noCompiler), // 0x92
    M3OP_F("f32.sub", -1, f_32, @@op_f32_Subtract_rs, @@op_f32_Subtract_sr, @@op_f32_Subtract_ss, c_opNull, c_noCompiler), // 0x93
    M3OP_F("f32.mul", -1, f_32, @@op_f32_Multiply_rs, c_opNull, @@op_f32_Multiply_ss, c_opNull, c_noCompiler), // 0x94
    M3OP_F("f32.div", -1, f_32, @@op_f32_Divide_rs, @@op_f32_Divide_sr, @@op_f32_Divide_ss, c_opNull, c_noCompiler), // 0x95
    M3OP_F("f32.min", -1, f_32, @@op_f32_Min_rs, c_opNull, @@op_f32_Min_ss, c_opNull, c_noCompiler), // 0x96
    M3OP_F("f32.max", -1, f_32, @@op_f32_Max_rs, c_opNull, @@op_f32_Max_ss, c_opNull, c_noCompiler), // 0x97
    M3OP_F("f32.copysign", -1, f_32, @@op_f32_CopySign_rs, @@op_f32_CopySign_sr, @@op_f32_CopySign_ss, c_opNull, c_noCompiler), // 0x98
    M3OP_F("f64.abs", 0, f_64, @@op_f64_Abs_r, @@op_f64_Abs_s, c_opNull, c_opNull, c_noCompiler), // 0x99
    M3OP_F("f64.neg", 0, f_64, @@op_f64_Negate_r, @@op_f64_Negate_s, c_opNull, c_opNull, c_noCompiler), // 0x9a
    M3OP_F("f64.ceil", 0, f_64, @@op_f64_Ceil_r, @@op_f64_Ceil_s, c_opNull, c_opNull, c_noCompiler), // 0x9b
    M3OP_F("f64.floor", 0, f_64, @@op_f64_Floor_r, @@op_f64_Floor_s, c_opNull, c_opNull, c_noCompiler), // 0x9c
    M3OP_F("f64.trunc", 0, f_64, @@op_f64_Trunc_r, @@op_f64_Trunc_s, c_opNull, c_opNull, c_noCompiler), // 0x9d
    M3OP_F("f64.nearest", 0, f_64, @@op_f64_Nearest_r, @@op_f64_Nearest_s, c_opNull, c_opNull, c_noCompiler), // 0x9e
    M3OP_F("f64.sqrt", 0, f_64, @@op_f64_Sqrt_r, @@op_f64_Sqrt_s, c_opNull, c_opNull, c_noCompiler), // 0x9f
    M3OP_F("f64.add", -1, f_64, @@op_f64_Add_rs, c_opNull, @@op_f64_Add_ss, c_opNull, c_noCompiler), // 0xa0
    M3OP_F("f64.sub", -1, f_64, @@op_f64_Subtract_rs, @@op_f64_Subtract_sr, @@op_f64_Subtract_ss, c_opNull, c_noCompiler), // 0xa1
    M3OP_F("f64.mul", -1, f_64, @@op_f64_Multiply_rs, c_opNull, @@op_f64_Multiply_ss, c_opNull, c_noCompiler), // 0xa2
    M3OP_F("f64.div", -1, f_64, @@op_f64_Divide_rs, @@op_f64_Divide_sr, @@op_f64_Divide_ss, c_opNull, c_noCompiler), // 0xa3
    M3OP_F("f64.min", -1, f_64, @@op_f64_Min_rs, c_opNull, @@op_f64_Min_ss, c_opNull, c_noCompiler), // 0xa4
    M3OP_F("f64.max", -1, f_64, @@op_f64_Max_rs, c_opNull, @@op_f64_Max_ss, c_opNull, c_noCompiler), // 0xa5
    M3OP_F("f64.copysign", -1, f_64, @@op_f64_CopySign_rs, @@op_f64_CopySign_sr, @@op_f64_CopySign_ss, c_opNull, c_noCompiler), // 0xa6
    M3OP("i32.wrap/i64", 0, i_32, @@op_i32_Wrap_i64_r, @@op_i32_Wrap_i64_s, c_opNull, c_opNull, c_noCompiler), // 0xa7
    M3OP_F("i32.trunc_s/f32", 0, i_32, @@op_i32_Trunc_f32_r_r, @@op_i32_Trunc_f32_r_s, @@op_i32_Trunc_f32_s_r, @@op_i32_Trunc_f32_s_s, @@Compile_Convert), // 0xa8
    M3OP_F("i32.trunc_u/f32", 0, i_32, @@op_u32_Trunc_f32_r_r, @@op_u32_Trunc_f32_r_s, @@op_u32_Trunc_f32_s_r, @@op_u32_Trunc_f32_s_s, @@Compile_Convert), // 0xa9
    M3OP_F("i32.trunc_s/f64", 0, i_32, @@op_i32_Trunc_f64_r_r, @@op_i32_Trunc_f64_r_s, @@op_i32_Trunc_f64_s_r, @@op_i32_Trunc_f64_s_s, @@Compile_Convert), // 0xaa
    M3OP_F("i32.trunc_u/f64", 0, i_32, @@op_u32_Trunc_f64_r_r, @@op_u32_Trunc_f64_r_s, @@op_u32_Trunc_f64_s_r, @@op_u32_Trunc_f64_s_s, @@Compile_Convert), // 0xab
    M3OP("i64.extend_s/i32", 0, i_64, @@op_i64_Extend_i32_r, @@op_i64_Extend_i32_s, c_opNull, c_opNull, c_noCompiler), // 0xac
    M3OP("i64.extend_u/i32", 0, i_64, @@op_i64_Extend_u32_r, @@op_i64_Extend_u32_s, c_opNull, c_opNull, c_noCompiler), // 0xad
    M3OP_F("i64.trunc_s/f32", 0, i_64, @@op_i64_Trunc_f32_r_r, @@op_i64_Trunc_f32_r_s, @@op_i64_Trunc_f32_s_r, @@op_i64_Trunc_f32_s_s, @@Compile_Convert), // 0xae
    M3OP_F("i64.trunc_u/f32", 0, i_64, @@op_u64_Trunc_f32_r_r, @@op_u64_Trunc_f32_r_s, @@op_u64_Trunc_f32_s_r, @@op_u64_Trunc_f32_s_s, @@Compile_Convert), // 0xaf
    M3OP_F("i64.trunc_s/f64", 0, i_64, @@op_i64_Trunc_f64_r_r, @@op_i64_Trunc_f64_r_s, @@op_i64_Trunc_f64_s_r, @@op_i64_Trunc_f64_s_s, @@Compile_Convert), // 0xb0
    M3OP_F("i64.trunc_u/f64", 0, i_64, @@op_u64_Trunc_f64_r_r, @@op_u64_Trunc_f64_r_s, @@op_u64_Trunc_f64_s_r, @@op_u64_Trunc_f64_s_s, @@Compile_Convert), // 0xb1
    M3OP_F("f32.convert_s/i32", 0, f_32, @@op_f32_Convert_i32_r_r, @@op_f32_Convert_i32_r_s, @@op_f32_Convert_i32_s_r, @@op_f32_Convert_i32_s_s, @@Compile_Convert), // 0xb2
    M3OP_F("f32.convert_u/i32", 0, f_32, @@op_f32_Convert_u32_r_r, @@op_f32_Convert_u32_r_s, @@op_f32_Convert_u32_s_r, @@op_f32_Convert_u32_s_s, @@Compile_Convert), // 0xb3
    M3OP_F("f32.convert_s/i64", 0, f_32, @@op_f32_Convert_i64_r_r, @@op_f32_Convert_i64_r_s, @@op_f32_Convert_i64_s_r, @@op_f32_Convert_i64_s_s, @@Compile_Convert), // 0xb4
    M3OP_F("f32.convert_u/i64", 0, f_32, @@op_f32_Convert_u64_r_r, @@op_f32_Convert_u64_r_s, @@op_f32_Convert_u64_s_r, @@op_f32_Convert_u64_s_s, @@Compile_Convert), // 0xb5
    M3OP_F("f32.demote/f64", 0, f_32, @@op_f32_Demote_f64_r, @@op_f32_Demote_f64_s, c_opNull, c_opNull, c_noCompiler), // 0xb6
    M3OP_F("f64.convert_s/i32", 0, f_64, @@op_f64_Convert_i32_r_r, @@op_f64_Convert_i32_r_s, @@op_f64_Convert_i32_s_r, @@op_f64_Convert_i32_s_s, @@Compile_Convert), // 0xb7
    M3OP_F("f64.convert_u/i32", 0, f_64, @@op_f64_Convert_u32_r_r, @@op_f64_Convert_u32_r_s, @@op_f64_Convert_u32_s_r, @@op_f64_Convert_u32_s_s, @@Compile_Convert), // 0xb8
    M3OP_F("f64.convert_s/i64", 0, f_64, @@op_f64_Convert_i64_r_r, @@op_f64_Convert_i64_r_s, @@op_f64_Convert_i64_s_r, @@op_f64_Convert_i64_s_s, @@Compile_Convert), // 0xb9
    M3OP_F("f64.convert_u/i64", 0, f_64, @@op_f64_Convert_u64_r_r, @@op_f64_Convert_u64_r_s, @@op_f64_Convert_u64_s_r, @@op_f64_Convert_u64_s_s, @@Compile_Convert), // 0xba
    M3OP_F("f64.promote/f32", 0, f_64, @@op_f64_Promote_f32_r, @@op_f64_Promote_f32_s, c_opNull, c_opNull, c_noCompiler), // 0xbb
    M3OP_F("i32.reinterpret/f32", 0, i_32, @@op_i32_Reinterpret_f32_r_r, @@op_i32_Reinterpret_f32_r_s, @@op_i32_Reinterpret_f32_s_r, @@op_i32_Reinterpret_f32_s_s, @@Compile_Convert), // 0xbc
    M3OP_F("i64.reinterpret/f64", 0, i_64, @@op_i64_Reinterpret_f64_r_r, @@op_i64_Reinterpret_f64_r_s, @@op_i64_Reinterpret_f64_s_r, @@op_i64_Reinterpret_f64_s_s, @@Compile_Convert), // 0xbd
    M3OP_F("f32.reinterpret/i32", 0, f_32, @@op_f32_Reinterpret_i32_r_r, @@op_f32_Reinterpret_i32_r_s, @@op_f32_Reinterpret_i32_s_r, @@op_f32_Reinterpret_i32_s_s, @@Compile_Convert), // 0xbe
    M3OP_F("f64.reinterpret/i64", 0, f_64, @@op_f64_Reinterpret_i64_r_r, @@op_f64_Reinterpret_i64_r_s, @@op_f64_Reinterpret_i64_s_r, @@op_f64_Reinterpret_i64_s_s, @@Compile_Convert), // 0xbf
    M3OP("i32.extend8_s", 0, i_32, @@op_i32_Extend8_s_r, @@op_i32_Extend8_s_s, c_opNull, c_opNull, c_noCompiler), // 0xc0
    M3OP("i32.extend16_s", 0, i_32, @@op_i32_Extend16_s_r, @@op_i32_Extend16_s_s, c_opNull, c_opNull, c_noCompiler), // 0xc1
    M3OP("i64.extend8_s", 0, i_64, @@op_i64_Extend8_s_r, @@op_i64_Extend8_s_s, c_opNull, c_opNull, c_noCompiler), // 0xc2
    M3OP("i64.extend16_s", 0, i_64, @@op_i64_Extend16_s_r, @@op_i64_Extend16_s_s, c_opNull, c_opNull, c_noCompiler), // 0xc3
    M3OP("i64.extend32_s", 0, i_64, @@op_i64_Extend32_s_r, @@op_i64_Extend32_s_s, c_opNull, c_opNull, c_noCompiler), // 0xc4
    // C: the d_m3DebugOp / d_m3DebugTypedOp rows that follow 0xc4 exist only
    // under `#ifdef DEBUG` for code-page logging ("the order doesn't matter").
    // In the release build the designated initialiser for 0xfc leaves
    // 0xc5..0xfb zero-filled: no operations, no compiler. An earlier port
    // placed those DEBUG rows at real opcode indices, so byte 0xc5 compiled
    // to op_Compile; every wasm opcode in this range is invalid.
    M3OP_RESERVED(), // 0xc5
    M3OP_RESERVED(), // 0xc6
    M3OP_RESERVED(), // 0xc7
    M3OP_RESERVED(), // 0xc8
    M3OP_RESERVED(), // 0xc9
    M3OP_RESERVED(), // 0xca
    M3OP_RESERVED(), // 0xcb
    M3OP_RESERVED(), // 0xcc
    M3OP_RESERVED(), // 0xcd
    M3OP_RESERVED(), // 0xce
    M3OP_RESERVED(), // 0xcf
    M3OP_RESERVED(), // 0xd0
    M3OP_RESERVED(), // 0xd1
    M3OP_RESERVED(), // 0xd2
    M3OP_RESERVED(), // 0xd3
    M3OP_RESERVED(), // 0xd4
    M3OP_RESERVED(), // 0xd5
    M3OP_RESERVED(), // 0xd6
    M3OP_RESERVED(), // 0xd7
    M3OP_RESERVED(), // 0xd8
    M3OP_RESERVED(), // 0xd9
    M3OP_RESERVED(), // 0xda
    M3OP_RESERVED(), // 0xdb
    M3OP_RESERVED(), // 0xdc
    M3OP_RESERVED(), // 0xdd
    M3OP_RESERVED(), // 0xde
    M3OP_RESERVED(), // 0xdf
    M3OP_RESERVED(), // 0xe0
    M3OP_RESERVED(), // 0xe1
    M3OP_RESERVED(), // 0xe2
    M3OP_RESERVED(), // 0xe3
    M3OP_RESERVED(), // 0xe4
    M3OP_RESERVED(), // 0xe5
    M3OP_RESERVED(), // 0xe6
    M3OP_RESERVED(), // 0xe7
    M3OP_RESERVED(), // 0xe8
    M3OP_RESERVED(), // 0xe9
    M3OP_RESERVED(), // 0xea
    M3OP_RESERVED(), // 0xeb
    M3OP_RESERVED(), // 0xec
    M3OP_RESERVED(), // 0xed
    M3OP_RESERVED(), // 0xee
    M3OP_RESERVED(), // 0xef
    M3OP_RESERVED(), // 0xf0
    M3OP_RESERVED(), // 0xf1
    M3OP_RESERVED(), // 0xf2
    M3OP_RESERVED(), // 0xf3
    M3OP_RESERVED(), // 0xf4
    M3OP_RESERVED(), // 0xf5
    M3OP_RESERVED(), // 0xf6
    M3OP_RESERVED(), // 0xf7
    M3OP_RESERVED(), // 0xf8
    M3OP_RESERVED(), // 0xf9
    M3OP_RESERVED(), // 0xfa
    M3OP_RESERVED(), // 0xfb
    M3OP("0xFC", 0, int(u8(M3ValueType.c_m3Type_unknown)), c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_ExtendedOpcode), // 0xfc
)
    c_operationsFC = fixed_array(
    M3OP_F("i32.trunc_s:sat/f32", 0, i_32, @@op_i32_TruncSat_f32_r_r, @@op_i32_TruncSat_f32_r_s, @@op_i32_TruncSat_f32_s_r, @@op_i32_TruncSat_f32_s_s, @@Compile_Convert), // 0x00
    M3OP_F("i32.trunc_u:sat/f32", 0, i_32, @@op_u32_TruncSat_f32_r_r, @@op_u32_TruncSat_f32_r_s, @@op_u32_TruncSat_f32_s_r, @@op_u32_TruncSat_f32_s_s, @@Compile_Convert), // 0x01
    M3OP_F("i32.trunc_s:sat/f64", 0, i_32, @@op_i32_TruncSat_f64_r_r, @@op_i32_TruncSat_f64_r_s, @@op_i32_TruncSat_f64_s_r, @@op_i32_TruncSat_f64_s_s, @@Compile_Convert), // 0x02
    M3OP_F("i32.trunc_u:sat/f64", 0, i_32, @@op_u32_TruncSat_f64_r_r, @@op_u32_TruncSat_f64_r_s, @@op_u32_TruncSat_f64_s_r, @@op_u32_TruncSat_f64_s_s, @@Compile_Convert), // 0x03
    M3OP_F("i64.trunc_s:sat/f32", 0, i_64, @@op_i64_TruncSat_f32_r_r, @@op_i64_TruncSat_f32_r_s, @@op_i64_TruncSat_f32_s_r, @@op_i64_TruncSat_f32_s_s, @@Compile_Convert), // 0x04
    M3OP_F("i64.trunc_u:sat/f32", 0, i_64, @@op_u64_TruncSat_f32_r_r, @@op_u64_TruncSat_f32_r_s, @@op_u64_TruncSat_f32_s_r, @@op_u64_TruncSat_f32_s_s, @@Compile_Convert), // 0x05
    M3OP_F("i64.trunc_s:sat/f64", 0, i_64, @@op_i64_TruncSat_f64_r_r, @@op_i64_TruncSat_f64_r_s, @@op_i64_TruncSat_f64_s_r, @@op_i64_TruncSat_f64_s_s, @@Compile_Convert), // 0x06
    M3OP_F("i64.trunc_u:sat/f64", 0, i_64, @@op_u64_TruncSat_f64_r_r, @@op_u64_TruncSat_f64_r_s, @@op_u64_TruncSat_f64_s_r, @@op_u64_TruncSat_f64_s_s, @@Compile_Convert), // 0x07
    M3OP_RESERVED(), // 0x08
    M3OP_RESERVED(), // 0x09
    M3OP("memory.copy", 0, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Memory_CopyFill), // 0x0a
    M3OP("memory.fill", 0, none, c_opNull, c_opNull, c_opNull, c_opNull, @@Compile_Memory_CopyFill), // 0x0b
)
}



def GetOpInfo(opcode : m3opcode_t) : IM3OpInfo {
    let opcodeValue = int(opcode)
    let prefix = opcodeValue >> 8
    if (prefix == 0) {
        if (opcodeValue < 253) {
            return unsafe(addr(c_operations[opcodeValue]))
        }
    } elif (prefix == int(c_waOp_extended)) {
        let extended = opcodeValue & 0xff
        if (extended < 12) {
            return unsafe(addr(c_operationsFC[extended]))
        }
    }
    return null
}


def CompileBlockStatements(var o : IM3Compilation) : M3Result {
    var validEnd = false
    while (m3_ptr_addr(o.wasm) < m3_ptr_addr(o.wasmEnd)) {
        // compiled out under the active configuration: d_m3EnableOpTracing == false

        var opcode : m3opcode_t
        o.lastOpcodeStart = o.wasm
        var result = Read_opcode(opcode, o.wasm, o.wasmEnd)
        if (result != m3Err_none) { return result }
        // compiled out under the active configuration: opcode logging disabled

        if (o._function == null) {
            let allowed = (
                opcode == c_waOp_i32_const || opcode == c_waOp_i64_const ||
                opcode == c_waOp_f32_const || opcode == c_waOp_f64_const ||
                opcode == c_waOp_getGlobal || opcode == c_waOp_end
            )
            if (!allowed) { return m3Err_restrictedOpcode }
        }

        let opinfo = GetOpInfo(opcode)
        if (opinfo == null) {
            return ErrorCompile(m3Err_unknownOpcode, o, "opcode '{int(opcode):x}' not available")
        }
        if (!IsNoCompiler(opinfo.compiler)) {
            result = opinfo.compiler(o, opcode)
        } else {
            result = Compile_Operator(o, opcode)
        }
        if (result != m3Err_none) { return result }

        o.previousOpcode = opcode
        if (opcode == c_waOp_else) {
            if (o._block.opcode != c_waOp_if) { return m3Err_wasmMalformed }
            validEnd = true
            break
        } elif (opcode == c_waOp_end) {
            validEnd = true
            break
        }
    }
    if (!validEnd) { return m3Err_wasmMalformed }
    return m3Err_none
}


def PushBlockResults(var o : IM3Compilation) : M3Result {
    let numResults = int(GetFuncTypeNumResults(o._block._type))
    var i : int = 0
    while (i < numResults) {
        var _type : int = int(GetFuncTypeResultType(o._block._type, u16(i)))
        var result : M3Result
        if (i == numResults - 1 && IsFpType(u8(_type))) {
            result = PushRegister(o, _type)
        } else {
            result = PushAllocatedSlot(o, _type)
        }
        if (result != m3Err_none) { return result }
        i++
    }
    return m3Err_none
}


def CompileBlock(var o : IM3Compilation; var i_blockType : IM3FuncType; i_blockOpcode : m3opcode_t) : M3Result {
    d_m3Assert(!IsRegisterAllocated(o, 0u))
    d_m3Assert(!IsRegisterAllocated(o, 1u))

    var outerScope = o._block
    var _block = unsafe(addr(o._block))
    _block.outer = unsafe(addr(outerScope))
    _block.pc = GetPagePC(o.page)
    _block.patches = null
    _block._type = i_blockType
    _block.depth++
    _block.opcode = i_blockOpcode

    var stackIndex = o.stackIndex
    let numParams = int(GetFuncTypeNumParams(i_blockType))

    if (i_blockOpcode != c_waOp_else) {
        var i : int = 0
        while (i < numParams) {
            var _type : int = int(GetFuncTypeParamType(i_blockType, u16(numParams - 1 - i)))
            let result = PopType(o, _type)
            if (result != m3Err_none) { return result }
            i++
        }
    } else {
        if (IsStackPolymorphic(o) && o._block.blockStackIndex + numParams > o.stackIndex) {
            o.stackIndex = o._block.blockStackIndex
        } else {
            o.stackIndex -= numParams
        }
    }

    let paramIndex = o.stackIndex
    _block.exitStackIndex = paramIndex
    o.stackIndex = stackIndex

    // These three calls are deliberately unchecked in the C source.
    PushBlockResults(o)
    stackIndex = o.stackIndex
    var numResults = int(GetFuncTypeNumResults(i_blockType))
    while (numResults != 0) {
        Pop(o)
        numResults--
    }
    // C's while(numResults--) performs one final unsigned decrement on exit.
    numResults = 0xffff

    _block.blockStackIndex = stackIndex
    o.stackIndex = stackIndex

    var i : int = 0
    while (i < numParams) {
        var _type : int = int(GetFuncTypeParamType(i_blockType, u16(i)))
        let slot = GetSlotForStackIndex(o, paramIndex + i)
        Push(o, _type, slot)
        if (slot >= o.slotFirstDynamicIndex && slot != c_slotUnused) {
            let result = MarkSlotsAllocatedByType(o, slot, _type)
            if (result != m3Err_none) { return result }
        }
        i++
    }

    var result = CompileBlockStatements(o)
    if (result != m3Err_none) { return result }
    result = ValidateBlockEnd(o)
    if (result != m3Err_none) { return result }

    if (o._function != null) {
        if (!IsStackPolymorphic(o)) {
            result = ResolveBlockResults(o, unsafe(addr(o._block)), false)
            if (result != m3Err_none) { return result }
        }
        result = UnwindBlockStack(o)
        if (result != m3Err_none) { return result }

        if (!((i_blockOpcode == c_waOp_if && numResults != 0) || o.previousOpcode == c_waOp_else)) {
            o.stackIndex = o._block.exitStackIndex
            result = PushBlockResults(o)
            if (result != m3Err_none) { return result }
        }
    }

    PatchBranches(o)
    o._block = outerScope
    return m3Err_none
}


def CompileLocals(var o : IM3Compilation) : M3Result {
    var numLocals : u32 = 0u
    var numLocalBlocks : u32
    var result = ReadLEB_u32(numLocalBlocks, o.wasm, o.wasmEnd)
    if (result != m3Err_none) { return result }

    var l : u32 = 0u
    while (l < numLocalBlocks) {
        var varCount : u32
        var waType : i8
        var localType : u8
        result = ReadLEB_u32(varCount, o.wasm, o.wasmEnd)
        if (result != m3Err_none) { return result }
        result = ReadLEB_i7(waType, o.wasm, o.wasmEnd)
        if (result != m3Err_none) { return result }
        result = NormalizeType(localType, waType)
        if (result != m3Err_none) { return result }
        numLocals += varCount
                while (varCount != 0u) {
            result = PushAllocatedSlot(o, int(localType))
            if (result != m3Err_none) { return result }
            varCount--
        }
        l++
    }

    if (o._function != null) { o._function.numLocals = u16(numLocals) }
    return m3Err_none
}


def ReserveConstants(var o : IM3Compilation) : M3Result {
    var numConstantSlots : int = 0
    var wa = o.wasm
    while (m3_ptr_addr(wa) < m3_ptr_addr(o.wasmEnd)) {
        var code : m3opcode_t
        unsafe { code = m3opcode_t(wa[0]) }
        unsafe { wa = wa + 1 }
        var addSlots : int = 0
        if (code == c_waOp_i32_const || code == c_waOp_f32_const) {
            addSlots = 1
        } elif (code == c_waOp_i64_const || code == c_waOp_f64_const) {
            addSlots = GetTypeNumSlots(int(u8(M3ValueType.c_m3Type_i64)))
        }
        if (numConstantSlots + addSlots >= int(d_m3MaxConstantTableSize)) { break }
        numConstantSlots += addSlots
    }

    AlignSlotToType(numConstantSlots, int(u8(M3ValueType.c_m3Type_i64)))
        o.slotFirstDynamicIndex = o.slotFirstConstIndex + numConstantSlots
    if (o.slotFirstDynamicIndex >= int(d_m3MaxFunctionSlots)) {
        return m3Err_functionStackOverflow
    }
    return m3Err_none
}


def CompileFunction(var io_function : IM3Function) : M3Result {
    if (io_function.wasm == null) { return "function body is missing" }

    var funcType = io_function.funcType

    var runtime = io_function._module.runtime
    runtime.compilation = M3Compilation()
    var o = unsafe(addr(runtime.compilation))
    d_m3Assert(d_m3MaxFunctionSlots >=
        d_m3MaxFunctionStackHeight * ((d_m3Use32BitSlots ? 1u : 0u) + 1u))
    o.runtime = runtime
    o._module = io_function._module
    o._function = io_function
    o.wasm = io_function.wasm
    o.wasmEnd = io_function.wasmEnd
    o._block._type = funcType

    var result : M3Result
    var size : u32
    var pc : pc_t = null

    result = ReadLEB_u32(size, o.wasm, o.wasmEnd)
    if (result == m3Err_none) {
        d_m3Assert(size == u32(m3_ptr_addr(o.wasmEnd) - m3_ptr_addr(o.wasm)))
        result = AcquireCompilationCodePage(o, o.page)
    }
    if (result == m3Err_none) {
        pc = GetPagePC(o.page)

        let numRetSlots = int(GetFunctionNumReturns(o._function)) * c_ioSlotCount
        var i : int = 0
        while (i < numRetSlots) {
            MarkSlotAllocated(o, i)
            i++
        }
        o._function.numRetSlots = u16(numRetSlots)
        o.slotFirstDynamicIndex = numRetSlots

        let numArgs = int(GetFunctionNumArgs(o._function))
        i = 0
        while (i < numArgs && result == m3Err_none) {
            let _type = GetFunctionArgType(o._function, u32(i))
            result = PushAllocatedSlot(o, int(_type))
            if (result == m3Err_none) {
                o.slotFirstDynamicIndex += c_ioSlotCount
            }
            i++
        }

        if (result == m3Err_none) {
            o.slotMaxAllocatedIndexPlusOne = o.slotFirstDynamicIndex
            o._function.numRetAndArgSlots = u16(o.slotFirstDynamicIndex)
            o.slotFirstLocalIndex = o.slotFirstDynamicIndex
            result = CompileLocals(o)
        }

        if (result == m3Err_none) {
            let maxSlot = GetMaxUsedSlotPlusOne(o)
            o._function.numLocalBytes = u16((maxSlot - o.slotFirstLocalIndex) * (typeinfo sizeof(type<m3slot_t>)))
            o.slotFirstConstIndex = maxSlot
            o.slotMaxConstIndex = maxSlot
            result = ReserveConstants(o)
        }

        if (result == m3Err_none) {
            o.maxStackSlots = o.slotFirstDynamicIndex
            o.slotMaxAllocatedIndexPlusOne = o.slotFirstDynamicIndex
            o._block.blockStackIndex = o.stackIndex
            o.stackFirstDynamicIndex = o.stackIndex

            result = EmitOp(o, @@op_Entry)
        }
        if (result == m3Err_none) {
            EmitPointer(o, io_function)
            result = CompileBlockStatements(o)
        }
        if (result == m3Err_none && o.previousOpcode != c_waOp_end) {
            result = m3Err_wasmMalformed
        }

        if (result == m3Err_none) {
            io_function.compiled = pc
            io_function.maxStackSlots = u16(o.maxStackSlots)

            let numConstantSlots = o.slotMaxConstIndex - o.slotFirstConstIndex

            io_function.numConstantBytes = u16(numConstantSlots * (typeinfo sizeof(type<m3slot_t>)))
            if (numConstantSlots != 0) {
                var constantsPtr : void?
                unsafe { constantsPtr = addr<void?>(o.constants[0]) }
                io_function.constants = m3_CopyMem(constantsPtr, u64(io_function.numConstantBytes))
                if (io_function.constants == null) {
                    result = m3Err_mallocFailed
                }
            }
        }
    }

    // Mirrors the C _catch path: release is reached for every failure after _try begins.
    ReleaseCompilationCodePage(o)
    return result
}

// ============================================================================
// ErrorCompile (C m3_core.h macro family)
// ============================================================================


/* C: #define ErrorCompile(RESULT, COMP, FORMAT, ...) — C varargs formats are
   interpolated into the message at each call site; __FILE__/__LINE__ are
   dropped (Daslang has no equivalent). */
def public ErrorCompile(i_result : M3Result; var o : IM3Compilation; i_errorMessage : cstr_t) : M3Result {
    return m3Error(i_result, o.runtime, o._module, null, "", 0u, i_errorMessage)
}
