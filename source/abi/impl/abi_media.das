options gen2
options indenting = 4

module abi_media shared public

require modules/wasm3das/source/abi/gen/abi_eden_video public
require modules/wasm3das/source/abi/gen/abi_eden_audio public
require math
require modules/wasm3das/source/m3_math_utils   // isnan (the editor's NaN compares are not IEEE, DESIGN 1 of the port)

/*
    abi_media.das: the pixel and sample conversions every host of
    eden_video / eden_audio shares (the headless host and the Eden host),
    so both accept and reject exactly the same guest data (ABI.md 3, 5).

    Engine-free. Video frames become RGBA8 rows, top row first; audio
    samples become interleaved floats in [-1, 1].
*/


// ============================================================================
// Video
// ============================================================================


def public video_bytes_per_pixel(format : int) : int {
    if (format == EDEN_VIDEO_FORMAT_RGBA8) {
        return 4
    } elif (format == EDEN_VIDEO_FORMAT_RGB565) {
        return 2
    } elif (format == EDEN_VIDEO_FORMAT_INDEXED8) {
        return 1
    }
    return 0
}


// the eden_video.present checks; EDEN_VIDEO_OK or an ERR_* code
def public video_validate(pixels : AbiBytes; width : int; height : int; stride : int; format : int) : int {
    let bpp = video_bytes_per_pixel(format)
    if (bpp == 0) {
        return EDEN_VIDEO_ERR_FORMAT
    }
    if (width < 1 || height < 1 || width > EDEN_VIDEO_MAX_WIDTH || height > EDEN_VIDEO_MAX_HEIGHT) {
        return EDEN_VIDEO_ERR_SIZE
    }
    if (stride < width * bpp) {
        return EDEN_VIDEO_ERR_SIZE
    }
    // the last row needs only width * bpp bytes
    if (int64(stride) * int64(height - 1) + int64(width * bpp) > int64(pixels.len)) {
        return EDEN_VIDEO_ERR_SIZE
    }
    return EDEN_VIDEO_OK
}


// the palette of eden_video.set_palette as 256 RGBA8 entries (missing ones
// opaque black); EDEN_VIDEO_OK or ERR_PALETTE
def public video_read_palette(rt : M3Runtime; colors : AbiBytes; var o_palette : array<uint8>) : int {
    if (colors.len == 0 || colors.len % 4 != 0 || colors.len > 256 * 4) {
        return EDEN_VIDEO_ERR_PALETTE
    }
    resize(o_palette, 256 * 4)
    for (i in range(256)) {
        o_palette[i * 4 + 0] = 0u8
        o_palette[i * 4 + 1] = 0u8
        o_palette[i * 4 + 2] = 0u8
        o_palette[i * 4 + 3] = 255u8
    }
    for (i in range(colors.len)) {
        o_palette[i] = rt.mem[colors.ptr + i]
    }
    return EDEN_VIDEO_OK
}


// a validated frame as RGBA8, width * height * 4 bytes. `palette` is used
// for INDEXED8 (256 entries; an empty palette is all opaque black)
def public video_to_rgba(rt : M3Runtime; pixels : AbiBytes; width : int; height : int; stride : int; format : int;
                         palette : array<uint8>; var o_rgba : array<uint8>) {
    resize(o_rgba, width * height * 4)
    for (y in range(height)) {
        let row = pixels.ptr + y * stride
        let dst = y * width * 4
        if (format == EDEN_VIDEO_FORMAT_RGBA8) {
            for (i in range(width * 4)) {
                o_rgba[dst + i] = rt.mem[row + i]
            }
        } elif (format == EDEN_VIDEO_FORMAT_RGB565) {
            for (x in range(width)) {
                let v = uint(rt.mem[row + x * 2]) | (uint(rt.mem[row + x * 2 + 1]) << 8u)
                let r5 = (v >> 11u) & 31u
                let g6 = (v >> 5u) & 63u
                let b5 = v & 31u
                o_rgba[dst + x * 4 + 0] = uint8((r5 << 3u) | (r5 >> 2u))
                o_rgba[dst + x * 4 + 1] = uint8((g6 << 2u) | (g6 >> 4u))
                o_rgba[dst + x * 4 + 2] = uint8((b5 << 3u) | (b5 >> 2u))
                o_rgba[dst + x * 4 + 3] = 255u8
            }
        } else {
            for (x in range(width)) {
                let idx = int(rt.mem[row + x])
                if (length(palette) == 256 * 4) {
                    o_rgba[dst + x * 4 + 0] = palette[idx * 4 + 0]
                    o_rgba[dst + x * 4 + 1] = palette[idx * 4 + 1]
                    o_rgba[dst + x * 4 + 2] = palette[idx * 4 + 2]
                    o_rgba[dst + x * 4 + 3] = palette[idx * 4 + 3]
                } else {
                    o_rgba[dst + x * 4 + 0] = 0u8
                    o_rgba[dst + x * 4 + 1] = 0u8
                    o_rgba[dst + x * 4 + 2] = 0u8
                    o_rgba[dst + x * 4 + 3] = 255u8
                }
            }
        }
    }
}


// The golden frame digest: FNV-1a over the frame packed to 15-bit RGB555
// little-endian (r << 10 | g << 5 | b, each channel >> 3), row by row.
// It is the parity hash of the binjgb reference fixture
// (Spider tests/manual/real-world-binjgb, module.c hash_current_frame), so
// frames of any host can be compared with its wasmtime baselines.
def public frame_digest_rgb555(rgba : array<uint8>) : int {
    var hash = 2166136261u
    let n = length(rgba) / 4
    for (i in range(n)) {
        let r = uint(rgba[i * 4 + 0]) >> 3u
        let g = uint(rgba[i * 4 + 1]) >> 3u
        let b = uint(rgba[i * 4 + 2]) >> 3u
        let pixel = (r << 10u) | (g << 5u) | b
        hash = (hash ^ (pixel & 0xffu)) * 16777619u
        hash = (hash ^ (pixel >> 8u)) * 16777619u
    }
    return int(hash)
}


// ============================================================================
// Audio
// ============================================================================


def public audio_bytes_per_sample(format : int) : int {
    if (format == EDEN_AUDIO_SAMPLE_S16) {
        return 2
    } elif (format == EDEN_AUDIO_SAMPLE_F32) {
        return 4
    } elif (format == EDEN_AUDIO_SAMPLE_U8) {
        return 1
    }
    return 0
}


def public audio_valid_stream(rate : int; channels : int) : bool {
    return rate >= EDEN_AUDIO_MIN_RATE && rate <= EDEN_AUDIO_MAX_RATE && (channels == 1 || channels == 2)
}


// the number of frames in `samples`, or ERR_ARGS for an unknown format or a
// partial frame
def public audio_frame_count(samples : AbiBytes; format : int; channels : int) : int {
    let bps = audio_bytes_per_sample(format)
    if (bps == 0 || channels < 1) {
        return EDEN_AUDIO_ERR_ARGS
    }
    let frameBytes = bps * channels
    if (samples.len % frameBytes != 0) {
        return EDEN_AUDIO_ERR_ARGS
    }
    return samples.len / frameBytes
}


// validated samples as interleaved floats in [-1, 1]
def public audio_to_float(rt : M3Runtime; samples : AbiBytes; format : int; var o_samples : array<float>) {
    let bps = audio_bytes_per_sample(format)
    let n = samples.len / bps
    resize(o_samples, n)
    for (i in range(n)) {
        let at = samples.ptr + i * bps
        if (format == EDEN_AUDIO_SAMPLE_U8) {
            o_samples[i] = (float(int(rt.mem[at])) - 128.0) / 128.0
        } elif (format == EDEN_AUDIO_SAMPLE_S16) {
            var v = int(uint(rt.mem[at]) | (uint(rt.mem[at + 1]) << 8u))
            if (v >= 32768) {
                v -= 65536
            }
            o_samples[i] = float(v) / 32768.0
        } else {
            let bits = uint(rt.mem[at]) | (uint(rt.mem[at + 1]) << 8u) | (uint(rt.mem[at + 2]) << 16u) | (uint(rt.mem[at + 3]) << 24u)
            let v = m3_bits_to_f32(uint64(bits))
            o_samples[i] = isnan(v) ? 0.0 : clamp(v, -1.0, 1.0)
        }
    }
}


// FNV-1a over raw sample bytes, continued from `hash` (the headless audio
// digest; 0x811c9dc5 starts it)
def public bytes_digest(rt : M3Runtime; b : AbiBytes; hash : uint) : uint {
    var h = hash
    for (i in range(b.len)) {
        h = (h ^ uint(rt.mem[b.ptr + i])) * 16777619u
    }
    return h
}
