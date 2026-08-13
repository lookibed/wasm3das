#include <stdio.h>
#include <stdlib.h>
#include "wasm3.h"

int main(int argc, char **argv) {
    if (argc < 2) return 1;
    FILE *f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "open failed\n"); return 1; }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *wasm = malloc(sz); fread(wasm, 1, sz, f); fclose(f);

    IM3Environment env = m3_NewEnvironment();
    IM3Runtime runtime = m3_NewRuntime(env, 64 * 1024, NULL);
    IM3Module module;
    M3Result r = m3_ParseModule(env, &module, wasm, sz);
    if (r) { fprintf(stderr, "parse: %s\n", r); return 1; }
    r = m3_LoadModule(runtime, module);
    if (r) { fprintf(stderr, "load: %s\n", r); return 1; }

    IM3Function fn;
    r = m3_FindFunction(&fn, runtime, "h264mp4_probe_width");
    if (r) { fprintf(stderr, "find: %s\n", r); return 1; }
    fprintf(stderr, "calling probe_width\n");
    r = m3_CallV(fn);
    if (r) { fprintf(stderr, "call: %s\n", r); return 1; }
    int32_t res = 0;
    m3_GetResultsV(fn, &res);
    printf("width=%d\n", res);
    return 0;
}
