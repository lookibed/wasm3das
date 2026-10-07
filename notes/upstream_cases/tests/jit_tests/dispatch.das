options gen2
options indenting = 4

// Micro-model of the port's threaded dispatch for the LLVM JIT: five by-value
// registers, a code page of function values, every operation returns the call
// of the next (the C form of wasm3, M3_MUSTTAIL return nextOpImpl()).
//
// Run: ulimit -s 4194304; daslang -jit dispatch.das
// (2 000 000 nested steps need the large native stack in the chains that do
// not tail-call). Measured 2026-09-21 on fork master d6dbcfd75, -jit at O3,
// Ryzen 7 7435HS:
//
//     invoke-chain  209 ns/step   (A) invoke through the code page: LLVM
//                                 emits no tail call for a call through a
//                                 function value, so every step nests a frame
//     direct-chain  ~0 ns/step    (B) direct calls of the same shape: LLVM
//                                 tail-calls and folds them into a loop
//     tree          1.3 ns/step   (D) an index word and an if-tree of direct
//                                 calls: tail jumps through the tree
//     flat invoke   4.4 ns/call   (E) one invoke that returns at once, the
//                                 cost of the invoke itself
//
// The issue text is jit_invoke_musttail.md beside this file.

typedef Op = function<(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string>

var g_counter : uint64 = 0ul

// (A) invoke through the code page
def op_dec(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    r0 = r0 - 1ul
    unsafe {
        let next = reinterpret<Op>(pc[0])
        return next(pc + 1, sp, mem, r0, fp0)
    }
}

def op_loop(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    if (r0 == 0ul) {
        g_counter = r0
        return ""
    }
    unsafe {
        var target = reinterpret<uint64?>(pc[0])
        let next = reinterpret<Op>(target[0])
        var tnext = target + 1
        return next(tnext, sp, mem, r0, fp0)
    }
}

// (B) the same shape with direct calls: dec then loop
def direct_dec(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    r0 = r0 - 1ul
    return direct_loop(pc, sp, mem, r0, fp0)
}
def direct_loop(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    if (r0 == 0ul) {
        g_counter = r0
        return ""
    }
    return direct_dec(pc, sp, mem, r0, fp0)
}

// (D) tree dispatch: the code page holds operation indices, every operation
// returns dispatch(...), which selects the callee with a balanced if tree of
// direct calls
def tree_dec(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    r0 = r0 - 1ul
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_loop(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    if (r0 == 0ul) {
        g_counter = r0
        return ""
    }
    unsafe {
        var target = reinterpret<uint64?>(pc[0])
        return tree_dispatch(target, sp, mem, r0, fp0)
    }
}
def tree_f2(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    fp0 = fp0 + 1.0lf
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_f3(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    fp0 = fp0 - 1.0lf
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_f4(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    r0 = r0 + 2ul
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_f5(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    r0 = r0 - 2ul
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_f6(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    fp0 = fp0 * 2.0lf
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_f7(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    fp0 = fp0 * 0.5lf
    return tree_dispatch(pc, sp, mem, r0, fp0)
}
def tree_dispatch(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    var idx : uint64
    unsafe {
        idx = pc[0]
    }
    var npc = unsafe(pc + 1)
    if (idx < 4ul) {
        if (idx < 2ul) {
            if (idx == 0ul) { return tree_dec(npc, sp, mem, r0, fp0) }
            return tree_loop(npc, sp, mem, r0, fp0)
        }
        if (idx == 2ul) { return tree_f2(npc, sp, mem, r0, fp0) }
        return tree_f3(npc, sp, mem, r0, fp0)
    }
    if (idx < 6ul) {
        if (idx == 4ul) { return tree_f4(npc, sp, mem, r0, fp0) }
        return tree_f5(npc, sp, mem, r0, fp0)
    }
    if (idx == 6ul) { return tree_f6(npc, sp, mem, r0, fp0) }
    return tree_f7(npc, sp, mem, r0, fp0)
}

// (E) the plain cost of one invoke: a loop of calls that return at once
def op_ret(var pc : uint64?; var sp : int?; var mem : void?; var r0 : uint64; var fp0 : double) : string {
    g_counter = r0
    return ""
}

[export]
def main() {
    let N = 2_000_000ul
    var page : array<uint64>
    page |> resize(3)
    unsafe {
        page[0] = reinterpret<uint64>(@@op_dec)
        page[1] = reinterpret<uint64>(@@op_loop)
        page[2] = reinterpret<uint64>(addr(page[0]))
    }
    var sp : int? = null
    var mem : void? = null
    // A: invoke through the code page
    var t0 = ref_time_ticks()
    unsafe {
        let first = reinterpret<Op>(page[0])
        let r = first(addr(page[1]), sp, mem, N, 0.0lf)
    }
    let tA = get_time_usec(t0)
    // B: direct call chain
    t0 = ref_time_ticks()
    let rb = direct_dec(null, sp, mem, N, 0.0lf)
    let tB = get_time_usec(t0)
    // C: plain loop
    t0 = ref_time_ticks()
    var n = N
    while (n != 0ul) {
        n = n - 1ul
    }
    g_counter = n
    let tC = get_time_usec(t0)
    // D: tree dispatch, the page: [0=dec, 1=loop, ->page]
    var tpage : array<uint64>
    tpage |> resize(3)
    tpage[0] = 0ul
    tpage[1] = 1ul
    unsafe {
        tpage[2] = reinterpret<uint64>(addr(tpage[0]))
    }
    t0 = ref_time_ticks()
    unsafe {
        let rd = tree_dispatch(addr(tpage[0]), sp, mem, N, 0.0lf)
    }
    let tD = get_time_usec(t0)
    // E: N invokes that return at once
    t0 = ref_time_ticks()
    unsafe {
        let f = reinterpret<Op>(reinterpret<uint64>(@@op_ret))
        var i = N
        while (i != 0ul) {
            let re = f(null, sp, mem, i, 0.0lf)
            i = i - 1ul
        }
    }
    let tE = get_time_usec(t0)
    print("steps {int(N)}: invoke-chain {double(tA) * 1000.0lf / double(N)} ns/step, direct-chain {double(tB) * 1000.0lf / double(N)} ns/step, tree {double(tD) * 1000.0lf / double(N)} ns/step, flat invoke {double(tE) * 1000.0lf / double(N)} ns/call, loop {tC} us\n")
}
