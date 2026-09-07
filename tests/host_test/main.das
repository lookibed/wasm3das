options gen2
options indenting = 4
// The interpreter nests one Daslang frame per executed op; the decoder is deep.
options stack = 67_108_864

require daslib/fio
require math
require strings
require ./host_common.das


// Daslang counterpart of wasm3c/host_test/main.c: decode up to N frames of an
// MP4 through the h264mp4_host_* exports and write each as a binary PPM.
// Usage: main.das -- <module.wasm> <clip.mp4> <outdir> [maxframes]


def private clamp(v : int) : u8 {
    if (v < 0) { return 0u8 }
    if (v > 255) { return 255u8 }
    return u8(v)
}


// C: m3_CallV (f); m3_GetResultsV (f, &v) for the getters without arguments.
def private get_i32(var fn : IM3Function) : int {
    var value = 0
    call0(fn)
    result_i32(fn, value)
    return value
}


[export]
def main : int {
    let argv <- process_argv("main")
    if (length(argv) < 4) {
        err_write("usage: {argv[0]} <wasm> <mp4> <outdir> [maxframes]\n")
        return 1
    }
    let wasm_path = argv[1]
    let mp4_path = argv[2]
    let out_dir = argv[3]
    let max_frames = length(argv) > 4 ? int(argv[4]) : 12

    var wasm <- read_file(wasm_path)
    if (empty(wasm)) {
        err_write("open wasm failed\n")
        return 1
    }
    var mp4 <- read_file(mp4_path)
    if (empty(mp4)) {
        err_write("open mp4 failed\n")
        return 1
    }

    let t0 = ref_time_ticks()

    var env = m3_NewEnvironment()
    if (env == null) {
        err_write("env failed\n")
        return 1
    }
    var runtime = m3_NewRuntime(env, 256u * 1024u, null)
    if (runtime == null) {
        err_write("runtime failed\n")
        return 1
    }
    if (load_module(env, runtime, wasm) != m3Err_none) { return 1 }

    var fReset : IM3Function
    var fAlloc : IM3Function
    var fLoad : IM3Function
    var fDecode : IM3Function
    var fW : IM3Function
    var fH : IM3Function
    var fYP : IM3Function
    var fUP : IM3Function
    var fVP : IM3Function
    var fYS : IM3Function
    var fUS : IM3Function
    var fVS : IM3Function
    m3_FindFunction(fReset, runtime, "h264mp4_host_reset")
    m3_FindFunction(fAlloc, runtime, "h264mp4_host_alloc")
    m3_FindFunction(fLoad, runtime, "h264mp4_host_load")
    m3_FindFunction(fDecode, runtime, "h264mp4_host_decode_frame")
    m3_FindFunction(fW, runtime, "h264mp4_host_get_width")
    m3_FindFunction(fH, runtime, "h264mp4_host_get_height")
    m3_FindFunction(fYP, runtime, "h264mp4_host_get_y_ptr")
    m3_FindFunction(fUP, runtime, "h264mp4_host_get_u_ptr")
    m3_FindFunction(fVP, runtime, "h264mp4_host_get_v_ptr")
    m3_FindFunction(fYS, runtime, "h264mp4_host_get_y_size")
    m3_FindFunction(fUS, runtime, "h264mp4_host_get_u_size")
    m3_FindFunction(fVS, runtime, "h264mp4_host_get_v_size")
    if (fReset == null || fAlloc == null || fLoad == null || fDecode == null || fW == null || fH == null ||
        fYP == null || fUP == null || fVP == null || fYS == null || fUS == null || fVS == null) {
        err_write("missing export\n")
        return 1
    }

    var mem_len = 0u
    var wasm_mem = m3_GetMemory(runtime, mem_len, 0u)
    let mlen = length(mp4)

    var decoded = 0
    for (fi in range(max_frames)) {
        var res = 0
        var r = call0(fReset)
        if (r != m3Err_none) {
            err_write("reset: {r}\n")
            break
        }
        var ptr = 0
        r = call_i32(fAlloc, [mlen])
        if (r != m3Err_none) {
            err_write("alloc: {r}\n")
            break
        }
        r = result_i32(fAlloc, ptr)
        if (r != m3Err_none) {
            err_write("alloc res: {r}\n")
            break
        }
        if (ptr <= 0) { break }
        wasm_mem = m3_GetMemory(runtime, mem_len, 0u)
        if (ptr + mlen > int(mem_len)) {
            err_write("alloc beyond memory\n")
            break
        }
        copy_into_memory(wasm_mem, ptr, mp4)
        r = call_i32(fLoad, [ptr, mlen])
        if (r != m3Err_none) {
            err_write("load: {r}\n")
            break
        }
        r = result_i32(fLoad, res)
        if (r != m3Err_none || res != 1) {
            err_write("load res {res}\n")
            break
        }
        r = call_i32(fDecode, [fi])
        if (r != m3Err_none) {
            err_write("decode: {r}\n")
            break
        }
        r = result_i32(fDecode, res)
        if (r != m3Err_none || res != 1) { break }

        let w = get_i32(fW)
        let h = get_i32(fH)
        let yp = get_i32(fYP)
        let up = get_i32(fUP)
        let vp = get_i32(fVP)
        let ys = get_i32(fYS)
        let us = get_i32(fUS)
        let vs = get_i32(fVS)
        if (w <= 0 || h <= 0 || yp <= 0 || ys <= 0) { break }

        wasm_mem = m3_GetMemory(runtime, mem_len, 0u)
        if (yp + ys > int(mem_len) || up + us > int(mem_len) || vp + vs > int(mem_len)) { break }

        let y <- copy_from_memory(wasm_mem, yp, ys)
        let u <- copy_from_memory(wasm_mem, up, us)
        let v <- copy_from_memory(wasm_mem, vp, vs)

        let uw = w / 2
        let outpath = "{out_dir}/sample_frame{fi < 10 ? "00" : (fi < 100 ? "0" : "")}{fi}.ppm"
        var written = false
        fopen(outpath, "wb") $(out) {
            if (out == null) { return }
            fwrite(out, "P6\n{w} {h}\n255\n")
            var rgb : array<u8>
            rgb |> resize(w * h * 3)
            var o = 0
            for (row in range(h)) {
                let yrow = row * w
                let uvrow = (row / 2) * uw
                for (col in range(w)) {
                    let yy = float(y[yrow + col])
                    let idx = uvrow + col / 2
                    let cb = float(u[idx]) - 128.0
                    let cr = float(v[idx]) - 128.0
                    rgb[o] = clamp(int(math::round(yy + 1.402 * cr)))
                    rgb[o + 1] = clamp(int(math::round(yy - 0.344136 * cb - 0.714136 * cr)))
                    rgb[o + 2] = clamp(int(math::round(yy + 1.772 * cb)))
                    o += 3
                }
            }
            fwrite(out, rgb)
            written = true
        }
        if (!written) {
            err_write("open out failed\n")
            break
        }
        decoded++
    }

    let elapsed = get_time_usec(t0)
    out_write("Decoded frames: {decoded}\n")
    out_write("Elapsed: {float(elapsed) / 1000.0} ms\n")

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
    return 0
}
