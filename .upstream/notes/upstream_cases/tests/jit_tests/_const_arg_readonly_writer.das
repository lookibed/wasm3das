options gen2
options indenting = 4

module _const_arg_readonly_writer

// The same write as the routes of test_const_arg_readonly.das, in a separate
// das-module so that the call crosses a codegen partition (the default
// --jit-split-modules). No inlining hint here: LLVM cannot inline across the
// partition, so the call site is resolved against the DECLARATION and its
// parameter attributes alone.
def public store_int(dst : void?; v : int) {
    unsafe {
        var p = reinterpret<int?>(dst)
        *p = v
    }
}
