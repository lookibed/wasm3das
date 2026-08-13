#include <stdio.h>
#include <stdlib.h>
#include "wasm3.h"

int main(void) {
    fprintf(stderr, "start\n");
    IM3Environment env = m3_NewEnvironment();
    fprintf(stderr, "env=%p\n", (void*)env);
    if (!env) return 1;
    IM3Runtime runtime = m3_NewRuntime(env, 256 * 1024, NULL);
    fprintf(stderr, "runtime=%p\n", (void*)runtime);
    if (!runtime) return 1;
    m3_FreeRuntime(runtime);
    m3_FreeEnvironment(env);
    fprintf(stderr, "done\n");
    return 0;
}
