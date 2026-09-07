# daslang defects prepared for upstream, as reusable test cases

Date: 2026-09-07. Each defect below is carried by a test case in the format
of the upstream daScript test suite, written without any reference to
wasm3das, that fails on the official release bundle `v0.6.4-RC2` and passes
once the defect is fixed. The files live in `notes/upstream_cases/` in the
layout they would take in the daScript tree; `notes/upstream_cases/RESULTS.md`
is the run log; `notes/daslang_jit_fixes_2026-09-07.patch` is the fix the two
JIT issues propose.

Upstream conventions (read from the daScript checkout of 2026-09-04): tests are
dastest files under `tests/` (`[test] def name(t : T?)` with `t |> equal` /
`success`, discovered by directory walk, `_`-prefixed files hidden), run by
`daslang dastest/dastest.das -- --test tests`; `run_tests_jit` re-runs
`tests/` under `-jit`; `tests/jit_tests` is skipped under `--use-aot`;
`tests-cpp/big/*` are ctest targets labelled `big` that generate, compile,
link and run standalone contexts; `tests/README.md` indexes every test file.
`skills/writing_tests.md` bans `verify`/`assert` in tests.

| # | Defect | Test case (upstream path) | Status on RC2 | Fix |
|---|---|---|---|---|
| 1 | `-ctx` standalone context: emission fails for a used, initialized global of a required module; generated contexts do not link; a linked context never runs its initializers | `tests-cpp/big/standalone_module_global/` | interpreter 0, `-aot` 0, `-ctx` 1 | master `8f4d87cac02c` (PR #3838), not in RC2 |
| 2 | LLVM JIT: SIGSEGV in codegen on a module-qualified `math::` float intrinsic | `tests/math/test_qualified_math_calls.das` | interpreter 4/4, `-jit` SIGSEGV | patch, hunk 3 |
| 3 | LLVM JIT: `reinterpret<uint64>(@@fn)` and `reinterpret<Fn>(handle)` emit an invalid aggregate bitcast | `tests/jit_tests/test_function_address_cast_codegen.das` | interpreter 2/2, `-jit` abort | patch, hunks 1 and 2 |
| 4 | Interpreter: `reinterpret<uint64>(@@fn)` evaluates to 0 in six store contexts | `tests/language/test_function_address_handles.das`, `tests/language/test_function_address_cast_contexts.das` | interpreter 2 of 4 and 6 of 9 fail; patched `-jit` all pass | none proposed |
| 5 | LLVM JIT: wrong results at `--jit-opt-level >= 1`, localized to one function of the port | none yet | not minimal, not to be filed | none |

What did not reproduce and is not claimed: a qualified `math::sqrt` with a
constant argument (folded before codegen); `math::exp`, `math::abs`,
`math::min`, `math::max` with qualified names; `reinterpret<uint64>` of a
function value held in a variable or parameter (correct in every tier); a
function value round-tripped through a runtime-indexed table and a heap slot.

---

## Issue 1

**Title:** v0.6.4-RC2: standalone `-ctx` is unusable: a required module's
initialized global fails emission, the emitted `InitGlobalVar` does not link,
and a context that does link never runs its initializers

A library module that owns its configuration (`var g_limits = Limits(...)`
next to the functions that read it) is the ordinary way to write daslang, and
it survives the interpreter and plain `-aot` unchanged. Put the same program
through `utils/aot/main.das -- -ctx` on the shipped `v0.6.4-RC2` bundle and
nothing about it works: emission aborts with `invoke null method function ...
visitGlobalLetVariableInit`; if the globals are moved into the entry module so
emission succeeds, the generated `.cpp` calls a `das::InitGlobalVar` overload
the shipped runtime library does not define; and if that link is forced with a
forwarding shim, the constructor never runs the global initializers, so every
global reads back as zero. All three are fixed on master by `8f4d87cac02c`
(PR #3838, 2026-08-23), four days after the RC2 tag. This issue is about the
release, and about the ctest lane that would have caught it never running in
CI.

### Test case

Proposed home: `tests-cpp/big/standalone_module_global/`, a sibling of the
existing `tests-cpp/big/standalone_ctx/` (auto-globbed by
`tests-cpp/CMakeLists.txt`). Four files:
`standalone_module_global_dep.das` (a module with `struct Limits`,
`var g_limits = Limits(retries = 3, timeout_ms = 250)`,
`var g_backoff = fixed_array(10, 40, 160)`, `var g_service_name = "ingest"`
and accessors), `standalone_module_global_fixture.das` (requires it, computes
`var g_total_budget_ms = limits().retries * limits().timeout_ms`, exports
`get_retries`, `get_total_budget_ms`, `get_backoff`, `service_name_length`
and a self-checking `main`), `test_standalone_module_global.cpp` (a host that
constructs `standalone_module_global_fixture::Standalone` and expects 3, 750,
10, 40, 160, 6) and `CMakeLists.txt` (custom command running `-ctx`,
executable, `add_test` with label `big`). Full contents in
`notes/upstream_cases/tests-cpp/big/standalone_module_global/`.

### Per tier on v0.6.4-RC2

Interpreter: `standalone_module_global: PASSED`, exit 0. Plain `-aot`: exit 0.

`-ctx`, blocker A:
```
$ $SDK/bin/daslang $SDK/utils/aot/main.das -- -ctx standalone_module_global_fixture.das out_ctx
daslib/aot_standalone.das:227:33: error[31206]: macro caused exception during visitGlobalLetBody -- invoke null method function, type<aot_standalone::StandaloneContextGen>.visitGlobalLetVariableInit
EXCEPTION: AOT codegen failed: 1 codegen error(s) during emission (see log)
 at daslib/aot_cpp.das:4410:4
$ echo $?            # 1, out_ctx empty
```
Expected: the two generated files and exit 0, then the test executable exits 0.
The condition is exact: the global must belong to a required module, be used,
and have any initializer (`var public g = 0` fails like an array-of-struct
literal); same-file globals, unused globals and `var g : int` without
initializer pass; `let`/`var` and `public`/`private` do not matter.

Blocker B, the link (isolated with the same program restated with its globals
in the entry module, which RC2 does generate):
```
$ g++ out/host.o out/ctx.o -L$SDK/lib -llibDaScript -llibDaScript_runtime -llibDaScript -llibUriParser -lpthread -ldl -lm
samefile_global.das.cpp:(.text+0x18aa): undefined reference to `das::InitGlobalVar(das::Context&, das::GlobalVariable*, das::GlobalVarInfo)'
$ nm -C --defined-only $SDK/lib/liblibDaScript_runtime.a | grep InitGlobalVar
0000000000000170 T das::InitGlobalVar(das::Context&, das::GlobalVariable*, das::GlobalVarInfo const&)
```
`include/daScript/simulate/standalone_ctx_utils.h:65` declares the by-value
form; the library defines only `const &`. A one-function forwarding shim
(`evidence/link_blocker/abi_shim.cpp`) makes the link succeed: the signature
mismatch is the whole of blocker B.

Blocker C, the linked context:
```
$ ./out/samefile_standalone
get_retries() = 0
get_total_budget_ms() = 0            # expected 3 and 750; exit 1
```
The generated constructor ends with `context.runInitScript()`; the emitted
`__init_script` is never called and `context.globals` is never zeroed.

### With the fix

Master commit `8f4d87cac02c` ("standalone aot: the constructor actually runs
init", PR #3838) changes the header to `const GlobalVarInfo &` (B), turns
`visitGlobalLet` into `preVisitGlobalLet` without the
`visitGlobalLetVariableInit` call (A), and replaces `runInitScript()` with
`memset(context.globals, ...)` + `__init_script(&context, true)` + the ordered
`[init]` calls (C). `GET /compare/v0.6.4-RC2...8f4d87cac02c` reports
`status: ahead, behind_by: 0`. Master also carries the emit-side regression
test `tests/aot/test_standalone_emit.das` over
`tests/aot/_standalone_cross_module_fixture.das`. Not verified: master was
read, not built and run.

### Requests

1. A release that includes at least `8f4d87cac02c`.
2. Run `ctest -L big` somewhere in CI: `tests-cpp/big/standalone_ctx` already
   links and runs a generated context and is the only lane that catches B
   and C, but every ctest invocation in `.github/workflows/build.yml` is
   `-L small`, and `examples/standalone/` and tutorial 20 are compile-only.

### Where it goes wrong (RC2 sources)

`daslib/ast.das:322` declares `def abstract visitGlobalLetVariableInit`;
`CppAot` (`daslib/aot_cpp.das:1349`) never overrides it;
`daslib/aot_standalone.das:227` calls it on itself after the
`pvar._module == prog.getThisModule` guard at `:216` let a required module's
variable through. `standalone_ctx_utils.h:65` is B; the emitted
`context.runInitScript()` is C.

---

## Issue 2

**Title:** LLVM JIT: SIGSEGV during codegen on a module-qualified `math::`
float intrinsic with a non-constant argument

A program that defines its own `sqrt` (over a vector type, a fixed-point type,
anything) has to spell the builtin one as `math::sqrt`. That program runs
correctly interpreted and lowers identically under `-aot`, but under `-jit`
the compiler dies with a SIGSEGV inside codegen: no diagnostic, no line. The
argument has to be non-constant; a constant is folded before the backend sees
the call.

### Test case

Proposed home: `tests/math/test_qualified_math_calls.das` (`tests/` is
re-run under `-jit` by `run_tests_jit`, and `tests/math` is already in
`DAS_AOT_SUITES`). A vector-math helper whose own `sqrt(Vec2)` overload is the
reason its builtin calls are qualified, exercising `math::sqrt`,
`math::floori`, `math::log` and `math::exp` over an `array<Vec2>` built at run
time; four `[test]` functions. Full contents in
`notes/upstream_cases/tests/math/test_qualified_math_calls.das`.

### Per tier

```
$ bin/daslang dastest/dastest.das -- --test tests/math/test_qualified_math_calls.das
4 tests, 4 passed, 0 failed, 0 errors, 0 skipped        # exit 0
$ rm -rf .jitted_scripts
$ bin/daslang dastest/dastest.das -jit -- --jit-opt-level=3 --test tests/math/test_qualified_math_calls.das
[I] LLVM JIT: 348 functions in 3.55 sec (codegen, O3)   # dastest itself
CRASH: SIGSEGV (Segmentation fault) (signal 11) at address 0x7f1747fbc97e   # exit 139
```
Also crashes with `-dry-run` (codegen, not run time). A one-line form is
enough: `var g_x = 9.0` and `print("{math::sqrt(g_x)}\n")`; with plain
`sqrt(g_x)` both tiers print `3`. Swept one by one, fourteen names crash:
`sqrt floor ceil round sin cos log exp2 log2 floori ceili sinh cosh tanh`;
`math::exp` and `math::abs` do not. `-aot` lowers the qualified call to
`SimPolicy<float>::Sqrt(...)`, exactly like the unqualified one (generated
C++ inspected, not compiled).

### With the fix

Hunk 3 of `notes/daslang_jit_fixes_2026-09-07.patch` (strip the module
qualifier before building the intrinsic name; refuse intrinsic id 0 with a
diagnostic). Applied to a scratch copy of `modules/dasLLVM` loaded with
`-load_module`: `4 tests, 4 passed` under `-jit`, exit 0.

### Where it goes wrong

`modules/dasLLVM/daslib/llvm_jit_intrin.das`: the dispatch key is built from
the declaration (`:251`, `:312`), so both spellings reach the same handler,
but `intrinsic_math_float_op1` (`:1055-1057`),
`intrinsic_math_float_op1_to_int` (`:1059-1066`) and
`intrinsic_math_sinh_cosh_tanh` (`:1158-1160`) pass the call-site spelling
`expr.name` into `intrinsic_math_any_float_op1` (`:1032`), which builds
`"llvm.{expr_name}.f32"`; `LLVMLookupIntrinsicID` answers 0 and
`LLVMGetIntrinsicDeclaration` (`:1046`) dereferences it. The id-0 guard is
worth keeping alone: every other `LLVMLookupIntrinsicID` site in the file is
one bad name away from the same crash.

---

## Issue 3

**Title:** LLVM JIT: `reinterpret<uint64>(@@fn)` and `reinterpret<Fn>(handle)`
emit a bitcast between the function aggregate and `i64` and abort codegen

A VM opcode table or callback registry that keeps, next to every handler, the
handler's raw address as a `uint64` (identity comparison, profiler keying,
handing it to C, casting it back to call it) compiles and runs interpreted
and generates under `-aot`, but cannot be JIT-compiled at all.

### Test case

Proposed home: `tests/jit_tests/test_function_address_cast_codegen.das`
(skipped under `--use-aot` by `tests/.das_test`, the right lane for a codegen
test). An opcode table of three handlers recording
`reinterpret<uint64>(@@op_x)` beside each; two `[test]` functions asserting
only what does not depend on the cast's value (the table builds and
dispatches; the recorded address is stable across two builds). Full contents
in `notes/upstream_cases/tests/jit_tests/test_function_address_cast_codegen.das`.

### Per tier

```
$ bin/daslang dastest/dastest.das -- --test tests/jit_tests/test_function_address_cast_codegen.das
2 tests, 2 passed, 0 failed, 0 errors, 0 skipped        # exit 0
$ rm -rf .jitted_scripts
$ bin/daslang dastest/dastest.das -jit -- --jit-opt-level=3 --test tests/jit_tests/test_function_address_cast_codegen.das
Invalid bitcast
  %cast_r = bitcast { ptr } %5 to i64
Invalid bitcast
  %cast_r7 = bitcast { ptr } %9 to i64
Invalid bitcast
  %cast_r15 = bitcast { ptr } %13 to i64
Internal jit error. Failed to get IR of 'build_opcode_table implementation' .
error[50503]: simulate macro llvm_macro::jit_llvm failed to simulate    # exit 1
```
Also fails with `-dry-run`. The same cast through a value
(`let f = @@op_add; reinterpret<uint64>(f)`) compiles, because that form
lowers `@@op_add` to a module-level `ptr` global; the inline `@@op_add` stays
the `{ ptr }` aggregate. The reverse cast `reinterpret<OpFn>(h)` fails the
same way (`bitcast i64 %h to { ptr }`, in `call_handle` of the companion
test). `-aot` generates without complaint.

### With the fix

Hunks 1 and 2 of `notes/daslang_jit_fixes_2026-09-07.patch`: function to
64-bit integer through `extractvalue` + `ptrtoint`, integer to function
through `inttoptr` + `insertvalue` into an undef `g_t_function`. On the
scratch copy: `2 tests, 2 passed` under `-jit`, exit 0; the companion
`tests/language/test_function_address_handles.das` passes 4/4 under the
patched JIT (interpreter fails it for the reason of issue 4).

### Where it goes wrong

`modules/dasLLVM/daslib/llvm_jit.das`, `visitExprCast` (`:5557`):
`Type.tFunction` is neither `isPointer` nor `isRefType`, so the chain at
`:5564-5571` misses it in both directions and the equal-size branch at
`:5572-5574` emits `LLVMBuildBitCast` between the aggregate and `i64`.

---

## Issue 4

**Title:** Interpreter: `reinterpret<uint64>(@@fn)` evaluates to 0 when the
cast is assigned, initialized from, stored into a field or array, or used as
an arithmetic operand; the same cast through a parameter yields the address

Taking a function's address as an opaque `uint64` handle silently produces
`0` in the interpreter when the cast is written on the `@@fn` expression and
its value is stored: assignment to a local, `let`/`var` initializer, a fixed
array element, a struct literal field, a struct field assignment, an
arithmetic operand. The same cast through a parameter, or passed straight as
a function argument, or stored through a pointer, yields the real address.
There is no diagnostic; the program stores a null handle and finds out later.
`options optimize = false` changes nothing. The JIT with the codegen fix of
issue 3 yields the reference address in every one of those contexts, and
`-aot` lowers the inline spelling to
`das_cast<uint64_t>::cast(Func(__context__->fnByMangledName(...)))`, so the
interpreter is the only tier that answers `0`.

### Test cases

Proposed home: `tests/language/`. `test_function_address_handles.das` is the
practical scenario (a dispatch table storing handles, 4 subtests, 2 fail);
`test_function_address_cast_contexts.das` is the matrix (9 subtests, one per
syntactic context, each compared to the handle taken through a parameter; 6
fail). Full contents in `notes/upstream_cases/tests/language/`.

### Per tier

```
$ bin/daslang dastest/dastest.das -- --test tests/language/test_function_address_cast_contexts.das
--- PASS 'test_reference_handle_is_not_null'
[E] --- FAIL 'test_assignment_to_a_local'          expected: 0x0   got: 0x555e1b1f7580
[E] --- FAIL 'test_declaration_with_initializer'   expected: 0x0
--- PASS 'test_function_argument'
[E] --- FAIL 'test_fixed_array_element_store'      expected: 0x0
[E] --- FAIL 'test_struct_literal_field'           expected: 0x0
[E] --- FAIL 'test_struct_field_assignment'        expected: 0x0
[E] --- FAIL 'test_arithmetic_operand'             expected: 0x0
--- PASS 'test_store_through_a_pointer'
9 tests, 3 passed, 6 failed, 0 errors, 0 skipped    # exit 6
```
(`expected` is the first argument of `t |> equal`, the inline cast.) With the
patched JIT: `9 tests, 9 passed`, exit 0. Reduced to two lines:
```das
let f = @@op_a
unsafe {
    var direct = reinterpret<uint64>(@@op_a)          // 0x0
    print("{reinterpret<uint64>(f)} {direct}\n")      // 0x55c5eb5ff500 0x0
}
```

### With the fix

None proposed; the tests document the expected behaviour. The question for
the maintainer is which answer is intended: if a null handle for the inline
spelling is deliberate, the cast should be rejected at compile time rather
than silently yielding `0`.

### Where it goes wrong

Not localized to a line. The evidence points at the simulation of
`ExprCast` over `ExprAddr` in a store position (the value is right when the
cast feeds a call argument or a pointer store and wrong when it feeds a copy
into a local, a field or an element); the optimizer is not involved. Two
further contexts were probed and left out of the test because they are not a
clean 0: `return reinterpret<uint64>(@@fn)` from a helper yields a non-null
address that differs from the reference in the interpreter and under the
patched JIT alike (not understood), and the cast inside a string
interpolation yields the reference address but does not compile inside a
`[test]` function.

---

## PR A (with issue 2): `jit: strip the module qualifier before building an LLVM intrinsic name`

Problem: as issue 2. Fix: `modules/dasLLVM/daslib/llvm_jit_intrin.das`, new
`jit_unqualified_name()` applied at the top of `intrinsic_math_any_float_op1`,
plus an id-0 guard that reports `failed_E(expr, "missing intrinsic ...")`
instead of handing 0 to `LLVMGetIntrinsicDeclaration`. Regression test:
`tests/math/test_qualified_math_calls.das` (before: interpreter SUCCESS, `-jit`
exit 139; after: 4/4 in both). Files: `llvm_jit_intrin.das` (modified),
`tests/math/test_qualified_math_calls.das` (added), `tests/README.md` (row).
Verification: `bin/daslang dastest/dastest.das -- --test tests/math/...`,
`rm -rf .jitted_scripts`, the same with `-jit -- --jit-opt-level=3`, and
`cmake --build ./build --target run_tests_jit`. Verified on v0.6.4-RC2
through a scratch copy of `modules/dasLLVM` and `-load_module`.

## PR B (with issue 3): `jit: convert function values to and from integers through the aggregate's pointer`

Problem: as issue 3. Fix: `modules/dasLLVM/daslib/llvm_jit.das`,
`visitExprCast`, two branches ahead of the equal-size fallback: function to
`int64`/`uint64` via `extractvalue` element 0 then `ptrtoint`; integer to
function via `inttoptr` to `SimFunction*` then `insertvalue` into an undef
`g_t_function` (the shape `visitExprAddr` builds). Regression tests:
`tests/jit_tests/test_function_address_cast_codegen.das` (pure codegen: passes
interpreted on an unfixed tree, fails only under `-jit`; after: 2/2 in both)
and `tests/language/test_function_address_handles.das` plus
`test_function_address_cast_contexts.das` (value semantics; these also fail on
the interpreter for issue 4, so land them only with that fix or hold them).
Files: `llvm_jit.das` (modified), the three tests (added), `tests/README.md`
(rows). `tests/jit_tests` is skipped under `--use-aot` by `tests/.das_test`.

---

## 5. Not filed: wrong results at `--jit-opt-level >= 1`

With the patch applied to a scratch JIT daslib, wasm3das compiles under `-jit`
(906 functions) but `--func tinyexpr_error_code` returns 1 instead of 6 and
`miniz_probe_crc32` returns -101385738 instead of 2035028898; `fib` is
correct. `--jit-opt-level=0` gives the correct results, levels 1 to 3 the
wrong ones. Forcing single functions to stay interpreted (a scratch-only
instrument in a copy of `llvm_jit_run.das`): leaving exactly
`m3_env::EvaluateExpression` (`source/m3_env.das:330-389`) out of the JIT
restores both results; no other single module or function does. The function
publishes the address of a stack-local `M3Runtime` into `i_module.runtime`,
hands `addr(runtime.compilation)` to a callee that mutates it, calls through
a code page, and copies the result out through `reinterpret<u32?>` /
`reinterpret<u64?>` of a `void?` out-parameter (C does the same with a
stack-local `M3Runtime`). A standalone probe with a stack-local struct whose
address escapes into a global and is written by a callee did not reproduce.
Unverified hypothesis: `noalias`-style assumptions on reference or pointer
parameters that this function violates. Not to be filed until reduced.
