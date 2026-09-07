options gen2
options indenting = 4

def op_a(var a : int&; var b : int&) : string {
    a += b
    return "a"
}

[export]
def main() {
    var b2 : uint64
    unsafe { b2 = reinterpret<uint64>(@@op_a) }
    print("via @@ direct nonzero={b2 != 0ul}\n")
}
