options gen2
options indenting = 4
// The interpreter nests one Daslang frame per executed op; the decoder is deep.
options stack = 67_108_864

require ./host_common.das


// Daslang counterpart of wasm3c/host_test/min2.c: copy an MP4 into the
// module's memory through h264mp4_host_alloc and decode the first frame.
// Usage: min2.das -- <module.wasm> <clip.mp4>
[export]
def main : int {
    let argv <- process_argv("min2")
    if (length(argv) < 3) { return 1 }
    var wasm <- read_file(argv[1])
    var mp4 <- read_file(argv[2])

    var env = m3_NewEnvironment()
    var runtime = m3_NewRuntime(env, 256u * 1024u, null)
    if (load_module(env, runtime, wasm) != m3Err_none) { return 1 }

    var fReset : IM3Function
    var fAlloc : IM3Function
    var fLoad : IM3Function
    var fDecode : IM3Function
    var fW : IM3Function
    m3_FindFunction(fReset, runtime, "h264mp4_host_reset")
    m3_FindFunction(fAlloc, runtime, "h264mp4_host_alloc")
    m3_FindFunction(fLoad, runtime, "h264mp4_host_load")
    m3_FindFunction(fDecode, runtime, "h264mp4_host_decode_frame")
    m3_FindFunction(fW, runtime, "h264mp4_host_get_width")
    if (fReset == null || fAlloc == null || fLoad == null || fDecode == null || fW == null) {
        err_write("missing export\n")
        return 1
    }
    err_write("step0 exports ok\n")

    var res = 0
    var r = call0(fReset)
    if (r != m3Err_none) {
        err_write("reset: {r}\n")
        return 1
    }
    err_write("step1 reset ok\n")

    let msz = length(mp4)
    r = call_i32(fAlloc, [msz])
    if (r != m3Err_none) {
        err_write("alloc: {r}\n")
        return 1
    }
    var ptr = 0
    result_i32(fAlloc, ptr)
    err_write("step2 alloc ptr={ptr}\n")

    var mem_len = 0u
    var mem = m3_GetMemory(runtime, mem_len, 0u)
    err_write("step3 memory len={int(mem_len)} base={intptr(mem)}\n")
    if (ptr <= 0 || ptr + msz > int(mem_len)) {
        err_write("bad ptr\n")
        return 1
    }
    copy_into_memory(mem, ptr, mp4)
    err_write("step4 wrote mp4\n")

    r = call_i32(fLoad, [ptr, msz])
    if (r != m3Err_none) {
        err_write("load: {r}\n")
        return 1
    }
    result_i32(fLoad, res)
    err_write("step5 load res={res}\n")

    r = call_i32(fDecode, [0])
    if (r != m3Err_none) {
        err_write("decode: {r}\n")
        return 1
    }
    result_i32(fDecode, res)
    err_write("step6 decode res={res}\n")

    r = call0(fW)
    if (r != m3Err_none) {
        err_write("w: {r}\n")
        return 1
    }
    result_i32(fW, res)
    err_write("step7 width={res}\n")
    return 0
}
