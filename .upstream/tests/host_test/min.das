options gen2
options indenting = 4
// The interpreter nests one Daslang frame per executed op; the decoder is deep.
options stack = 67_108_864

require ./host_common.das


// Daslang counterpart of wasm3c/host_test/min.c: load a module and call its
// exported h264mp4_probe_width. Usage: min.das -- <module.wasm>
[export]
def main : int {
    let argv <- process_argv("min")
    if (length(argv) < 2) { return 1 }
    var wasm <- read_file(argv[1])
    if (empty(wasm)) {
        err_write("open failed\n")
        return 1
    }

    var env = m3_NewEnvironment()
    var runtime = m3_NewRuntime(env, 64u * 1024u, null)
    if (load_module(env, runtime, wasm) != m3Err_none) { return 1 }

    var fn : IM3Function
    var r = m3_FindFunction(fn, runtime, "h264mp4_probe_width")
    if (r != m3Err_none) {
        err_write("find: {r}\n")
        return 1
    }
    err_write("calling probe_width\n")
    r = call0(fn)
    if (r != m3Err_none) {
        err_write("call: {r}\n")
        return 1
    }
    var res = 0
    result_i32(fn, res)
    out_write("width={res}\n")
    return 0
}
