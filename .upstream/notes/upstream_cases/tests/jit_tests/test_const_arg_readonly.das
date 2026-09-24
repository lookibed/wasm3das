options gen2
options indenting = 4

require dastest/testing_boost
require _const_arg_readonly_writer

// A `const` pointer or reference parameter that the callee writes through after
// an `unsafe` cast. The write is legal daslang: `reinterpret` (and `intptr`)
// produce a fresh, writable pointer, which is how an out-parameter of type
// `void?` is served in every C-shaped API. The JIT nonetheless gives such a
// parameter the LLVM `readonly` attribute, so the module it emits contains a
// definition that stores through a parameter it declares as never written.
// From `--jit-opt-level=1` upwards the optimizer believes the attribute and
// folds the caller's read of that memory to its pre-call value.
//
// Every check below passes in the interpreter and at `--jit-opt-level=0`.

struct Cell {
    a : int
    b : int
}

// const `void?` out-parameter, cast to a typed pointer
[hint(noinline)]
def route_void(dst : void?; v : int) {
    unsafe {
        var p = reinterpret<int?>(dst)
        *p = v
    }
}

// const typed pointer, cast to its own type
[hint(noinline)]
def route_same_type(dst : int?; v : int) {
    unsafe {
        var p = reinterpret<int?>(dst)
        *p = v
    }
}

// const `void?` out-parameter as a memcpy destination
[hint(noinline)]
def route_memcpy(dst : void?; v : int) {
    var src = v
    unsafe {
        memcpy(dst, reinterpret<void?>(addr(src)), 4)
    }
}

// const structure reference, address taken and cast back
[hint(noinline)]
def route_const_ref(c : Cell; v : int) {
    unsafe {
        var p = reinterpret<Cell?>(addr(c))
        p.a = v
    }
}

// the pointer laundered through an integer
[hint(noinline)]
def route_intptr(dst : void?; v : int) {
    unsafe {
        var i = intptr(dst)
        var p = reinterpret<int?>(i)
        *p = v
    }
}

[test]
def test_write_through_const_argument(t : T?) {
    t |> success(!jit_enabled() || is_jit_function(@@route_void))
    t |> run("const void? out-parameter") @(t : T?) {
        var slot = 0
        unsafe {
            route_void(reinterpret<void?>(addr(slot)), 41)
        }
        t |> equal(41, slot)
    }
    t |> run("const typed pointer") @(t : T?) {
        var slot = 0
        unsafe {
            route_same_type(addr(slot), 42)
        }
        t |> equal(42, slot)
    }
    t |> run("const void? memcpy destination") @(t : T?) {
        var slot = 0
        unsafe {
            route_memcpy(reinterpret<void?>(addr(slot)), 43)
        }
        t |> equal(43, slot)
    }
    t |> run("const structure reference") @(t : T?) {
        var cell = Cell(a = 0, b = 0)
        route_const_ref(cell, 44)
        t |> equal(44, cell.a)
    }
    t |> run("pointer laundered through intptr") @(t : T?) {
        var slot = 0
        unsafe {
            route_intptr(reinterpret<void?>(addr(slot)), 45)
        }
        t |> equal(45, slot)
    }
}

// the control: the same body with a `var` parameter. The JIT gives this one no
// `readonly`, LLVM's own inference labels it `writeonly`, and it is correct in
// every mode.
[hint(noinline)]
def route_var_parameter(var dst : void?; v : int) {
    unsafe {
        var p = reinterpret<int?>(dst)
        *p = v
    }
}

[test]
def test_var_parameter_is_the_control(t : T?) {
    var slot = 0
    unsafe {
        route_var_parameter(reinterpret<void?>(addr(slot)), 47)
    }
    t |> equal(47, slot, "the same body with a `var` parameter")
}

[test]
def test_write_through_const_argument_across_modules(t : T?) {
    var slot = 0
    unsafe {
        store_int(reinterpret<void?>(addr(slot)), 46)
    }
    t |> equal(46, slot, "a cross-partition callee needs no inlining hint")
}
