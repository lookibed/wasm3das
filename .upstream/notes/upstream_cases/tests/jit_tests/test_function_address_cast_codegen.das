options gen2
options indenting = 4

require dastest/testing_boost public

// Codegen coverage for `reinterpret<uint64>(@@fn)` written directly on the
// address-of expression: a VM opcode table that stores every handler together with
// the raw address a profiler later symbolizes by. The JIT has to be able to emit
// this cast at all - a function value is the aggregate { ptr }, and LLVM rejects a
// bitcast from an aggregate to a scalar.
//
// This file deliberately asserts only what does not depend on the cast's *value*;
// the value semantics (non-null, and both spellings agreeing) are pinned by
// tests/language/test_function_address_handles.das.

typedef OpFn = function<(var acc : int&; operand : int) : void>

def op_add(var acc : int&; operand : int) {
    acc += operand
}

def op_mul(var acc : int&; operand : int) {
    acc *= operand
}

def op_neg(var acc : int&; operand : int) {
    acc = operand - acc
}

struct Opcode {
    name : string
    fn : OpFn
    code_address : uint64
}

def build_opcode_table : array<Opcode> {
    var ops : array<Opcode>
    unsafe {
        ops |> push(Opcode(name = "add", fn = @@op_add, code_address = reinterpret<uint64>(@@op_add)))
        ops |> push(Opcode(name = "mul", fn = @@op_mul, code_address = reinterpret<uint64>(@@op_mul)))
        ops |> push(Opcode(name = "neg", fn = @@op_neg, code_address = reinterpret<uint64>(@@op_neg)))
    }
    return <- ops
}

[test]
def test_opcode_table_builds_and_dispatches(t : T?) {
    var ops <- build_opcode_table()
    t |> equal(length(ops), 3, "every opcode was registered")
    var acc = 3
    invoke(ops[0].fn, acc, 4)
    invoke(ops[1].fn, acc, 6)
    invoke(ops[2].fn, acc, 84)
    t |> equal(acc, 42, "dispatch through the table")
}

[test]
def test_recorded_code_address_is_stable(t : T?) {
    var first <- build_opcode_table()
    var again <- build_opcode_table()
    for (i in range(0, length(first))) {
        t |> equal(first[i].code_address, again[i].code_address,
            "the recorded address of {first[i].name} does not change between builds")
    }
}
