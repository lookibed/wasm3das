options gen2
options indenting = 4

// The same cast written two ways. Through a local the interpreter yields the
// function's address; written directly on @@op_a it yields 0. The LLVM JIT
// cannot compile the direct form at all.
def op_a(var a : int&; var b : int&) : string {
    a += b
    return "a"
}

[export]
def main() {
    let f = @@op_a
    var via_var : uint64
    var direct : uint64
    unsafe { via_var = reinterpret<uint64>(f) }
    unsafe { direct = reinterpret<uint64>(@@op_a) }
    print("via_var = {via_var}\n")
    print("direct  = {direct}\n")
}
