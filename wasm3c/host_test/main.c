#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "wasm3.h"

static uint8_t clamp(int v) {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return (uint8_t)v;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <wasm> <mp4> <outdir> [maxframes]\n", argv[0]);
        return 1;
    }
    const char *wasm_path = argv[1];
    const char *mp4_path = argv[2];
    const char *out_dir = argv[3];
    int max_frames = argc > 4 ? atoi(argv[4]) : 12;

    FILE *f = fopen(wasm_path, "rb");
    if (!f) { fprintf(stderr, "open wasm failed\n"); return 1; }
    fseek(f, 0, SEEK_END); long wlen = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *wasm = malloc(wlen); fread(wasm, 1, wlen, f); fclose(f);

    f = fopen(mp4_path, "rb");
    if (!f) { fprintf(stderr, "open mp4 failed\n"); return 1; }
    fseek(f, 0, SEEK_END); long mlen = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *mp4 = malloc(mlen); fread(mp4, 1, mlen, f); fclose(f);

    clock_t t0 = clock();

    IM3Environment env = m3_NewEnvironment();
    if (!env) { fprintf(stderr, "env failed\n"); return 1; }
    IM3Runtime runtime = m3_NewRuntime(env, 256 * 1024, NULL);
    if (!runtime) { fprintf(stderr, "runtime failed\n"); return 1; }
    IM3Module module;
    M3Result r = m3_ParseModule(env, &module, wasm, wlen);
    if (r) { fprintf(stderr, "parse: %s\n", r); return 1; }
    r = m3_LoadModule(runtime, module);
    if (r) { fprintf(stderr, "load: %s\n", r); return 1; }

    IM3Function fReset, fAlloc, fLoad, fDecode, fW, fH;
    IM3Function fYP, fUP, fVP, fYS, fUS, fVS;
    m3_FindFunction(&fReset, runtime, "h264mp4_host_reset");
    m3_FindFunction(&fAlloc, runtime, "h264mp4_host_alloc");
    m3_FindFunction(&fLoad, runtime, "h264mp4_host_load");
    m3_FindFunction(&fDecode, runtime, "h264mp4_host_decode_frame");
    m3_FindFunction(&fW, runtime, "h264mp4_host_get_width");
    m3_FindFunction(&fH, runtime, "h264mp4_host_get_height");
    m3_FindFunction(&fYP, runtime, "h264mp4_host_get_y_ptr");
    m3_FindFunction(&fUP, runtime, "h264mp4_host_get_u_ptr");
    m3_FindFunction(&fVP, runtime, "h264mp4_host_get_v_ptr");
    m3_FindFunction(&fYS, runtime, "h264mp4_host_get_y_size");
    m3_FindFunction(&fUS, runtime, "h264mp4_host_get_u_size");
    m3_FindFunction(&fVS, runtime, "h264mp4_host_get_v_size");
    if (!fReset || !fAlloc || !fLoad || !fDecode || !fW || !fH ||
        !fYP || !fUP || !fVP || !fYS || !fUS || !fVS) {
        fprintf(stderr, "missing export\n"); return 1;
    }

    uint32_t mem_len = 0;
    uint8_t *wasm_mem = m3_GetMemory(runtime, &mem_len, 0);

    int decoded = 0;
    char outpath[512];
    for (int fi = 0; fi < max_frames; fi++) {
        int32_t res;
        if ((r = m3_CallV(fReset))) { fprintf(stderr, "reset: %s\n", r); break; }
        int32_t ptr = 0;
        if ((r = m3_CallV(fAlloc, (int32_t)mlen))) { fprintf(stderr, "alloc: %s\n", r); break; }
        if ((r = m3_GetResultsV(fAlloc, &ptr))) { fprintf(stderr, "alloc res: %s\n", r); break; }
        if (ptr <= 0) break;
        wasm_mem = m3_GetMemory(runtime, &mem_len, 0);
        if (ptr + mlen > mem_len) { fprintf(stderr, "alloc beyond memory\n"); break; }
        memcpy(wasm_mem + ptr, mp4, (size_t)mlen);
        if ((r = m3_CallV(fLoad, ptr, (int32_t)mlen))) { fprintf(stderr, "load: %s\n", r); break; }
        if ((r = m3_GetResultsV(fLoad, &res)) || res != 1) { fprintf(stderr, "load res %d\n", res); break; }
        if ((r = m3_CallV(fDecode, fi))) { fprintf(stderr, "decode: %s\n", r); break; }
        if ((r = m3_GetResultsV(fDecode, &res)) || res != 1) break;

        int32_t w, h, yp, up, vp, ys, us, vs;
        m3_CallV(fW); m3_GetResultsV(fW, &w);
        m3_CallV(fH); m3_GetResultsV(fH, &h);
        m3_CallV(fYP); m3_GetResultsV(fYP, &yp);
        m3_CallV(fUP); m3_GetResultsV(fUP, &up);
        m3_CallV(fVP); m3_GetResultsV(fVP, &vp);
        m3_CallV(fYS); m3_GetResultsV(fYS, &ys);
        m3_CallV(fUS); m3_GetResultsV(fUS, &us);
        m3_CallV(fVS); m3_GetResultsV(fVS, &vs);
        if (w <= 0 || h <= 0 || yp <= 0 || ys <= 0) break;

        wasm_mem = m3_GetMemory(runtime, &mem_len, 0);
        if (yp + ys > mem_len || up + us > mem_len || vp + vs > mem_len) break;

        uint8_t *y = malloc(ys), *u = malloc(us), *v = malloc(vs);
        memcpy(y, wasm_mem + yp, (size_t)ys);
        memcpy(u, wasm_mem + up, (size_t)us);
        memcpy(v, wasm_mem + vp, (size_t)vs);

        int uw = w / 2;
        snprintf(outpath, sizeof outpath, "%s/sample_frame%03d.ppm", out_dir, fi);
        FILE *out = fopen(outpath, "wb");
        if (!out) { fprintf(stderr, "open out failed\n"); break; }
        fprintf(out, "P6\n%d %d\n255\n", w, h);
        for (int row = 0; row < h; row++) {
            int yrow = row * w;
            int uvrow = (row / 2) * uw;
            for (int col = 0; col < w; col++) {
                float yy = (float)y[yrow + col];
                int idx = uvrow + col / 2;
                float cb = (float)u[idx] - 128.0f;
                float cr = (float)v[idx] - 128.0f;
                uint8_t rgb[3];
                rgb[0] = clamp((int)roundf(yy + 1.402f * cr));
                rgb[1] = clamp((int)roundf(yy - 0.344136f * cb - 0.714136f * cr));
                rgb[2] = clamp((int)roundf(yy + 1.772f * cb));
                fwrite(rgb, 1, 3, out);
            }
        }
        fclose(out);
        free(y); free(u); free(v);
        decoded++;
    }

    double elapsed = (double)(clock() - t0) / CLOCKS_PER_SEC;
    printf("Decoded frames: %d\n", decoded);
    printf("Elapsed: %.1f ms\n", elapsed * 1000.0);

    m3_FreeRuntime(runtime);
    m3_FreeEnvironment(env);
    free(wasm); free(mp4);
    return 0;
}
