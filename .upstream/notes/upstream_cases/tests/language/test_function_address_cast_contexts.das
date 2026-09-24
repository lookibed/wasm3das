options gen2
options indenting = 4

require dastest/testing_boost public

// `reinterpret<uint64>(@@fn)` has one meaning: the address of fn, the same value
// the cast yields when fn is first held in a variable or parameter. This file
// writes that cast in every ordinary syntactic position a program uses to take a
// callback's address and checks each against the reference handle. The
// reference comes through a parameter, which is the spelling that is correct in
// every tier.

typedef OpFn = function<(var acc : int&; operand : int) : void>

def op_add(var acc : int&; operand : int) {
    acc += operand
}

struct Slot {
    h : uint64
}

def handle_of(f : OpFn) : uint64 {
    return unsafe(reinterpret<uint64>(f))
}

def identity(h : uint64) : uint64 {
    return h
}

def store_through_pointer(var p : void??) {
    unsafe {
        p[0] = reinterpret<void?>(reinterpret<uint64>(@@op_add))
    }
}

[test]
def test_reference_handle_is_not_null(t : T?) {
    t |> success(handle_of(@@op_add) != 0ul, "the handle through a parameter is the reference")
}

[test]
def test_assignment_to_a_local(t : T?) {
    var h : uint64
    unsafe { h = reinterpret<uint64>(@@op_add) }
    t |> equal(h, handle_of(@@op_add), "h = reinterpret<uint64>(@@op_add)")
}

[test]
def test_declaration_with_initializer(t : T?) {
    let h = unsafe(reinterpret<uint64>(@@op_add))
    t |> equal(h, handle_of(@@op_add), "let h = reinterpret<uint64>(@@op_add)")
}

[test]
def test_function_argument(t : T?) {
    t |> equal(identity(unsafe(reinterpret<uint64>(@@op_add))), handle_of(@@op_add),
        "f(reinterpret<uint64>(@@op_add))")
}

[test]
def test_fixed_array_element_store(t : T?) {
    var fa : uint64[2]
    unsafe { fa[1] = reinterpret<uint64>(@@op_add) }
    t |> equal(fa[1], handle_of(@@op_add), "fa[1] = reinterpret<uint64>(@@op_add)")
}

[test]
def test_struct_literal_field(t : T?) {
    var s : Slot
    unsafe { s = Slot(h = reinterpret<uint64>(@@op_add)) }
    t |> equal(s.h, handle_of(@@op_add), "Slot(h = reinterpret<uint64>(@@op_add))")
}

[test]
def test_struct_field_assignment(t : T?) {
    var s : Slot
    unsafe { s.h = reinterpret<uint64>(@@op_add) }
    t |> equal(s.h, handle_of(@@op_add), "s.h = reinterpret<uint64>(@@op_add)")
}

[test]
def test_arithmetic_operand(t : T?) {
    var h : uint64
    unsafe { h = 0ul + reinterpret<uint64>(@@op_add) }
    t |> equal(h, handle_of(@@op_add), "0ul + reinterpret<uint64>(@@op_add)")
}

[test]
def test_store_through_a_pointer(t : T?) {
    var slots = fixed_array<void?>(null, null)
    store_through_pointer(unsafe(addr(slots[0])))
    t |> equal(unsafe(reinterpret<uint64>(slots[0])), handle_of(@@op_add),
        "p[0] = reinterpret<void?>(reinterpret<uint64>(@@op_add))")
}
