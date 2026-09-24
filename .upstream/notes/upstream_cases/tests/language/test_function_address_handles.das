options gen2
options indenting = 4

require dastest/testing_boost public

// A dispatch table that keeps, next to every callback, the callback's address as an
// opaque uint64 - the shape an engine uses when it has to compare callback identity,
// key a profiler by address, or hand the address to C. The two natural spellings of
// "take the address of this function", passing @@fn as a value and casting the
// address-of expression in place, have to produce the same non-null handle.

typedef OpFn = function<(var acc : int&; operand : int) : void>

def op_add(var acc : int&; operand : int) {
    acc += operand
}

def op_mul(var acc : int&; operand : int) {
    acc *= operand
}

def handle_of(f : OpFn) : uint64 {
    return unsafe(reinterpret<uint64>(f))
}

def call_handle(h : uint64; var acc : int&; operand : int) {
    unsafe {
        invoke(reinterpret<OpFn>(h), acc, operand)
    }
}

struct Opcode {
    fn : OpFn
    handle : uint64
}

[test]
def test_handle_through_a_value_is_not_null(t : T?) {
    let h = handle_of(@@op_add)
    t |> success(h != 0ul, "a function handle is not null")
    t |> equal(h, handle_of(@@op_add), "the handle is stable")
    t |> success(h != handle_of(@@op_mul), "distinct functions get distinct handles")
}

[test]
def test_handle_round_trips_back_to_a_callable(t : T?) {
    let h = handle_of(@@op_add)
    var acc = 1
    call_handle(h, acc, 41)
    t |> equal(acc, 42, "a handle cast back to a function is callable")
}

[test]
def test_both_spellings_produce_the_same_handle(t : T?) {
    let via_value = handle_of(@@op_add)
    var inline_cast : uint64
    unsafe {
        inline_cast = reinterpret<uint64>(@@op_add)
    }
    t |> success(inline_cast != 0ul, "reinterpret<uint64>(@@op_add) is not null")
    t |> equal(inline_cast, via_value, "both spellings name the same function")
}

[test]
def test_dispatch_table_of_inline_handles(t : T?) {
    var table_ : array<Opcode>
    unsafe {
        table_ |> push(Opcode(fn = @@op_add, handle = reinterpret<uint64>(@@op_add)))
        table_ |> push(Opcode(fn = @@op_mul, handle = reinterpret<uint64>(@@op_mul)))
    }
    t |> success(table_[0].handle != 0ul, "add handle is not null")
    t |> success(table_[1].handle != 0ul, "mul handle is not null")
    t |> success(table_[0].handle != table_[1].handle, "the two entries are distinguishable")
    t |> equal(table_[0].handle, handle_of(table_[0].fn), "the handle matches the stored callback")
    var acc = 3
    invoke(table_[0].fn, acc, 4)
    invoke(table_[1].fn, acc, 6)
    t |> equal(acc, 42, "dispatch through the table")
}
