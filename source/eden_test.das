options gen2
options indenting = 4

module eden_test shared public

require strings

/*
    eden_test.das: the test framework of the Eden port.

    Pure Daslang, no macros and no file access, because the EdenSpark editor
    compiles it in its sandbox (docs/eden-port/DESIGN.md section 1). The same
    test modules run in three places: the local runner (.local/run_tests.das,
    daslang on the command line), the Eden host (.eden_host/main.das, cheat
    `wasm3_tests`) and any future harness. A test is a plain function

        def test_x(var t : TestRun; fx : FixtureSource)

    called from the module's run_tests_<module>(var t; fx). Checks record
    failures in `t` instead of panicking, so one failing check never hides
    the others and the summary line is always printed.
*/


struct TestRun {
    passed : int = 0
    failed : int = 0
    failures : array<string>   // "test_name: message"
    current : string = ""      // the running test's name
    verbose : bool = false     // print every check, not only failures
}


struct FixtureSource {
    // returns the bytes of a fixture named by its path under wasm3c/test/
    // ("lang/fib32.wasm"), or an empty array when it is missing
    load : lambda<(name : string) : array<uint8>>
}


// `print` ends the line in the editor's console but not on the daslang
// command line, so every line printed here carries its own "\n" (the
// editor then shows an empty line after it, which is harmless)
def public out(line : string) {
    print("{line}\n")
}


def public begin_test(var t : TestRun; name : string) {
    t.current = name
    if (t.verbose) {
        out("[eden_test] {name}")
    }
}


def public record(var t : TestRun; ok : bool; msg : string) {
    if (ok) {
        t.passed++
        if (t.verbose) {
            out("  ok  {msg}")
        }
    } else {
        t.failed++
        let line = "{t.current}: {msg}"
        push(t.failures, line)
        out("  FAIL {line}")
    }
}


def public check(var t : TestRun; cond : bool; msg : string) {
    record(t, cond, msg)
}


def public equal(var t : TestRun; got : auto(T); want : T; msg : string) {
    let ok = got == want
    record(t, ok, ok ? msg : "{msg} (got {got}, want {want})")
}


def public equal_str(var t : TestRun; got : string; want : string; msg : string) {
    let ok = got == want
    record(t, ok, ok ? msg : "{msg} (got \"{got}\", want \"{want}\")")
}


def public not_equal(var t : TestRun; got : auto(T); notWant : T; msg : string) {
    let ok = got != notWant
    record(t, ok, ok ? msg : "{msg} (got {got}, which must differ from {notWant})")
}


def public is_ok(var t : TestRun; result : string; msg : string) {
    // M3Result convention: "" is success
    let ok = result == ""
    record(t, ok, ok ? msg : "{msg} (result \"{result}\")")
}


def public is_err(var t : TestRun; result : string; want : string; msg : string) {
    let ok = result == want
    record(t, ok, ok ? msg : "{msg} (result \"{result}\", want \"{want}\")")
}


def public load_fixture(fx : FixtureSource; name : string) : array<uint8> {
    var bytes <- invoke(fx.load, name)
    return <- bytes
}


def public summary(t : TestRun) : string {
    // parsed by scripts/eden/test.sh and scripts/eden/eden_gate.sh; keep the shape
    return "WASM3 TESTS pass={t.passed} fail={t.failed}"
}


def public print_report(t : TestRun) {
    for (line in t.failures) {
        out("FAILED {line}")
    }
    out(summary(t))
}


def public empty_fixture_source() : FixtureSource {
    var fx = FixtureSource()
    fx.load <- @(name : string) : array<uint8> {
        var none : array<uint8>
        return <- none
    }
    return <- fx
}
