options gen2
options indenting = 4

require ./host_common.das


// Daslang counterpart of wasm3c/host_test/smoke.c: environment and runtime
// lifecycle without any module.
[export]
def main : int {
    err_write("start\n")
    var env = m3_NewEnvironment()
    err_write("env={intptr(env)}\n")          // C: %p; Daslang prints u64 in hex
    if (env == null) { return 1 }
    var runtime = m3_NewRuntime(env, 256u * 1024u, null)
    err_write("runtime={intptr(runtime)}\n")
    if (runtime == null) { return 1 }
    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
    err_write("done\n")
    return 0
}
