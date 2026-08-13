#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "wasm3.h"

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *wasm = malloc(sz); fread(wasm, 1, sz, f); fclose(f);
    f = fopen(argv[2], "rb");
    fseek(f, 0, SEEK_END); long msz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *mp4 = malloc(msz); fread(mp4, 1, msz, f); fclose(f);

    IM3Environment env = m3_NewEnvironment();
    IM3Runtime runtime = m3_NewRuntime(env, 256 * 1024, NULL);
    IM3Module module;
    M3Result r = m3_ParseModule(env, &module, wasm, sz);
    if (r) { fprintf(stderr, "parse: %s\n", r); return 1; }
    r = m3_LoadModule(runtime, module);
    if (r) { fprintf(stderr, "load: %s\n", r); return 1; }

    IM3Function fReset, fAlloc, fLoad, fDecode, fW;
    m3_FindFunction(&fReset, runtime, "h264mp4_host_reset");
    m3_FindFunction(&fAlloc, runtime, "h264mp4_host_alloc");
    m3_FindFunction(&fLoad, runtime, "h264mp4_host_load");
    m3_FindFunction(&fDecode, runtime, "h264mp4_host_decode_frame");
    m3_FindFunction(&fW, runtime, "h264mp4_host_get_width");
    if (!fReset || !fAlloc || !fLoad || !fDecode || !fW) { fprintf(stderr, "missing export\n"); return 1; }
    fprintf(stderr, "step0 exports ok\n");

    int32_t res;
    r = m3_CallV(fReset); if (r) { fprintf(stderr, "reset: %s\n", r); return 1; }
    fprintf(stderr, "step1 reset ok\n");

    r = m3_CallV(fAlloc, (int32_t)msz); if (r) { fprintf(stderr, "alloc: %s\n", r); return 1; }
    int32_t ptr = 0;
    m3_GetResultsV(fAlloc, &ptr);
    fprintf(stderr, "step2 alloc ptr=%d\n", ptr);

    uint32_t mem_len = 0;
    uint8_t *mem = m3_GetMemory(runtime, &mem_len, 0);
    fprintf(stderr, "step3 memory len=%u base=%p\n", mem_len, (void*)mem);
    if (ptr <= 0 || ptr + msz > mem_len) { fprintf(stderr, "bad ptr\n"); return 1; }
    memcpy(mem + ptr, mp4, (size_t)msz);
    fprintf(stderr, "step4 wrote mp4\n");

    r = m3_CallV(fLoad, ptr, (int32_t)msz); if (r) { fprintf(stderr, "load: %s\n", r); return 1; }
    m3_GetResultsV(fLoad, &res);
    fprintf(stderr, "step5 load res=%d\n", res);

    r = m3_CallV(fDecode, 0); if (r) { fprintf(stderr, "decode: %s\n", r); return 1; }
    m3_GetResultsV(fDecode, &res);
    fprintf(stderr, "step6 decode res=%d\n", res);

    r = m3_CallV(fW); if (r) { fprintf(stderr, "w: %s\n", r); return 1; }
    m3_GetResultsV(fW, &res);
    fprintf(stderr, "step7 width=%d\n", res);
    return 0;
}
