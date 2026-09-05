options gen2
options indenting = 4

require dastest/testing_boost
require ../source/m3_env.das
require ../source/m3_exec.das


/*
    Component test for m3_env.das phase-2 scope: the execution-hook wiring
    performed by m3_NewEnvironment. C m3_exec.h reaches CompileFunction and
    ResizeMemory through its include cycle; the Daslang port replaces those
    edges with global function bindings registered at environment creation.
    Runtime behaviour of the wired functions belongs to the fib32 integration
    test (phase 5).
*/


def private expect_true(name : string; actual : bool) {
    if (!actual) {
        panic("{name}: expected true, got false")
    }
}


def private expect_hooks_wired(stage : string) {
    expect_true("{stage}: CompileFunctionHook wired", CompileFunctionHook != null)
    expect_true("{stage}: ResizeMemoryHook wired", ResizeMemoryHook != null)
}


// Bindings are var, not let: const bindings propagate pointee-constness and
// the env API takes mutable IM3Environment / IM3Runtime values.
[test]
def test_env_new_environment_wires_hooks() {
    var env = m3_NewEnvironment()
    expect_true("environment allocated", env != null)
    expect_hooks_wired("first m3_NewEnvironment")
    m3_FreeEnvironment(env)
}


[test]
def test_env_hook_wiring_is_idempotent() {
    var first = m3_NewEnvironment()
    expect_true("first environment allocated", first != null)

    var second = m3_NewEnvironment()
    expect_true("second environment allocated", second != null)
    expect_hooks_wired("repeated m3_NewEnvironment")

    m3_FreeEnvironment(second)
    m3_FreeEnvironment(first)
}


[test]
def test_env_new_runtime_environment_survives_wiring() {
    var env = m3_NewEnvironment()
    expect_true("environment allocated", env != null)

    var runtime = m3_NewRuntime(env, 65536u, null)
    expect_true("runtime allocated", runtime != null)
    expect_true("runtime keeps environment", runtime.environment == env)
    expect_hooks_wired("after m3_NewRuntime")

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
}


[test]
def test_env_runtime_releases_linked_module_without_owning_environment() {
    var env = m3_NewEnvironment()
    expect_true("environment allocated for linked module", env != null)

    var runtime = m3_NewRuntime(env, 64u * 1024u, null)
    expect_true("runtime allocated for linked module", runtime != null)

    var linkedModule : IM3Module = new M3Module(environment = env, runtime = runtime)
    runtime.modules = linkedModule

    m3_FreeRuntime(runtime)
    m3_FreeEnvironment(env)
}


[export]
def main() {
    test_env_new_environment_wires_hooks()
    test_env_hook_wiring_is_idempotent()
    test_env_new_runtime_environment_survives_wiring()
    test_env_runtime_releases_linked_module_without_owning_environment()
    print("test_m3_env: all tests passed\n")
}
