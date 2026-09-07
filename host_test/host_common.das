options gen2
options indenting = 4

module host_common shared public

require daslib/fio
require ../source/m3_parse.das public


/*
    Shared helpers for the host programs in this directory, the Daslang
    counterparts of the C programs in wasm3c/host_test. They use the public
    wasm3.h API directly (m3_NewEnvironment, m3_ParseModule, m3_CallV,
    m3_GetResultsV, m3_GetMemory); the port's API is the same, and the
    helpers below only replace the libc pieces the C programs call
    (fopen/fread, argv, fprintf (stderr, ...), memcpy, m3_CallV's varargs).
*/


// C: argv after the interpreter's own arguments; argv[0] is the program.
def process_argv(program : string) : array<string> {
    var raw <- get_command_line_arguments()
    var result : array<string>
    result |> push(program)
    var seen = false
    for (a in raw) {
        if (seen) {
            result |> push(a)
        } elif (a == "--") {
            seen = true
        }
    }
    return <- result
}


// C: fopen/fseek/ftell/fread of a whole file; empty when it cannot be read.
def read_file(path : string) : array<u8> {
    var bytes : array<u8>
    fopen(path, "rb") $(f) {
        if (f != null) {
            let st = fstat(f)
            bytes |> resize(int64(st.size))
            fread(f, bytes)
        }
    }
    return <- bytes
}


def err_write(text : string) {
    fprint(fstderr(), text)
    fflush(fstderr())
}


def out_write(text : string) {
    fprint(fstdout(), text)
    fflush(fstdout())
}


// C: m3_ParseModule + m3_LoadModule with the two error reports of the host
// programs (`parse: %s`, `load: %s`).
def load_module(var env : IM3Environment; var runtime : IM3Runtime; var bytes : array<u8>) : M3Result {
    var _module : IM3Module
    var r = m3_ParseModule(env, _module, unsafe(addr(bytes[0])), u32(length(bytes)))
    if (r != m3Err_none) {
        err_write("parse: {r}\n")
        return r
    }
    r = m3_LoadModule(runtime, _module)
    if (r != m3Err_none) {
        err_write("load: {r}\n")
        m3_FreeModule(_module)
        return r
    }
    return m3Err_none
}


// C: m3_CallV (fn, i32 args...) — the varargs become an array of tagged i32.
def call_i32(var fn : IM3Function; args : array<int>) : M3Result {
    var tagged : array<M3TaggedValue>
    tagged |> resize(length(args))
    for (a, t in args, tagged) {
        t._type = M3ValueType.c_m3Type_i32
        tagged_set_i32(t, a)
    }
    return m3_CallV(fn, tagged)
}


def call0(var fn : IM3Function) : M3Result {
    let none : array<int>
    return call_i32(fn, none)
}


// C: int32_t res; m3_GetResultsV (fn, &res)
def result_i32(var fn : IM3Function; var o_value : int&) : M3Result {
    var rets : array<M3TaggedValue>
    let r = m3_GetResultsV(fn, rets)
    if (r == m3Err_none && !empty(rets)) {
        o_value = tagged_get_i32(rets[0])
    }
    return r
}


// C: memcpy (mem + ptr, src, len) into the linear memory returned by m3_GetMemory.
def copy_into_memory(var mem : u8?; offset : int; var src : array<u8>) {
    unsafe {
        memcpy(reinterpret<void?>(mem + offset), addr<void?>(src[0]), u64(long_length(src)))
    }
}


// C: memcpy (dst, mem + ptr, len) out of the linear memory.
def copy_from_memory(mem : u8?; offset : int; size : int) : array<u8> {
    var out : array<u8>
    out |> resize(size)
    unsafe {
        memcpy(addr<void?>(out[0]), reinterpret<void?>(mem + offset), u64(size))
    }
    return <- out
}
