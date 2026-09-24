options gen2

// Issue #3991: the `const` parameter `dst` is emitted with the LLVM `readonly`
// attribute, the body stores through it, and from --jit-opt-level=1 the
// caller's read of `slot` is folded to its pre-call value.
//
//   $ bin/daslang minimal.das                              -> slot = 41 (want 41)
//   $ bin/daslang -jit minimal.das -- --jit-opt-level=0    -> slot = 41 (want 41)
//   $ bin/daslang -jit minimal.das -- --jit-opt-level=1    -> slot = 0 (want 41)
//   $ bin/daslang -jit minimal.das                         -> slot = 0 (want 41)
//
// [hint(noinline)] only keeps LLVM from inlining the store into view; the
// same callee in a second module fails at O2/O3 without any hint.

[hint(noinline)]
def store_int(dst : void?; v : int) {
    unsafe {
        var p = reinterpret<int?>(dst)
        *p = v
    }
}

[export]
def main {
    var slot = 0
    unsafe {
        store_int(reinterpret<void?>(addr(slot)), 41)
    }
    print("slot = {slot} (want 41)\n")
}
