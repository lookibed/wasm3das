# Upstream regression cases: run log

Every case in this directory was run twice, by the agent that wrote it and
again independently, on the official daslang release bundle `v0.6.4-RC2`
(`bin/daslang --version` → `0.6.4`) installed at `tmp/daslang`, Linux x86_64,
Debian 6.12.107. "Patched JIT" means a scratch copy of the bundle's
`modules/dasLLVM` with `notes/daslang_jit_fixes_2026-09-07.patch` applied,
loaded with `daslang -load_module <copy> ...`; the installed bundle was never
modified. `rm -rf .jitted_scripts` precedes every JIT run: the JIT DLL cache
is keyed by program hash only, so a cached artifact from a patched run makes
a stock run pass spuriously.

`$SDK` = `tmp/daslang`, `$DASTEST` = `$SDK/bin/daslang $SDK/dastest/dastest.das`.

## Exit-code matrix

| Case | File | interpreter | RC2 `-jit` | patched `-jit` | `-aot` generate | `-ctx` |
|---|---|---|---|---|---|---|
| 2, qualified `math::` intrinsic | `tests/math/test_qualified_math_calls.das` | 0, 4/4 | **139 SIGSEGV** | 0, 4/4 | 0 | n/a |
| 3, function↔int cast codegen | `tests/jit_tests/test_function_address_cast_codegen.das` | 0, 2/2 | **1, `Invalid bitcast`** | 0, 2/2 | 0 | n/a |
| 4a, inline cast value | `tests/language/test_function_address_handles.das` | **2, 2 of 4 fail** | 1 (blocked by case 3) | 0, 4/4 | 0 | n/a |
| 4b, inline cast per context | `tests/language/test_function_address_cast_contexts.das` | **6, 6 of 9 fail** | 1 (blocked by case 3) | 0, 9/9 | not run | n/a |
| 1, `-ctx` with a required module's global | `tests-cpp/big/standalone_module_global/` | 0 | n/a | n/a | 0 | **1** |

## Case 2

```
$ $DASTEST -- --test tests/math/test_qualified_math_calls.das
4 tests, 4 passed, 0 failed, 0 errors, 0 skipped                  # exit 0
$ rm -rf .jitted_scripts
$ $DASTEST -jit -jit-no-cache -- --test tests/math/test_qualified_math_calls.das
CRASH: SIGSEGV (Segmentation fault) (signal 11) at address 0x7ffa7d3bc97e   # exit 139
$ $SDK/bin/daslang -load_module <patched>/dasLLVM $SDK/dastest/dastest.das -jit -jit-no-cache -- --test tests/math/test_qualified_math_calls.das
4 tests, 4 passed, 0 failed, 0 errors, 0 skipped                  # exit 0
```

One-line probes `print("{math::<fn>(g_x)}\n")` with `var g_x = 9.0` crash
for `sqrt floor ceil round sin cos log exp2 log2 floori ceili sinh cosh
tanh`; `math::exp` and `math::abs` pass. `-aot` lowers `math::sqrt` to
`SimPolicy<float>::Sqrt(...)`, the same as the unqualified call (generated
C++ inspected, not compiled).

## Case 3

```
$ $DASTEST -- --test tests/jit_tests/test_function_address_cast_codegen.das
2 tests, 2 passed, 0 failed, 0 errors, 0 skipped                  # exit 0
$ $DASTEST -jit -jit-no-cache -- --test tests/jit_tests/test_function_address_cast_codegen.das
Invalid bitcast
  %cast_r = bitcast { ptr } %5 to i64
Invalid bitcast
  %cast_r7 = bitcast { ptr } %9 to i64
Invalid bitcast
  %cast_r15 = bitcast { ptr } %13 to i64
Internal jit error. Failed to get IR of 'build_opcode_table implementation' .
error[50503]: simulate macro llvm_macro::jit_llvm failed to simulate     # exit 1
$ ... -load_module <patched>/dasLLVM ... -jit -jit-no-cache -- --test tests/jit_tests/test_function_address_cast_codegen.das
2 tests, 2 passed, 0 failed, 0 errors, 0 skipped                  # exit 0
```

The reverse cast `reinterpret<OpFn>(handle)` fails the same way
(`bitcast i64 %h to { ptr }`, in `call_handle` of
`tests/language/test_function_address_handles.das`); the third hunk of the
patch covers it.

## Case 4a

```
$ $DASTEST -- --test tests/language/test_function_address_handles.das
--- PASS 'test_handle_through_a_value_is_not_null'
--- PASS 'test_handle_round_trips_back_to_a_callable'
tests/language/test_function_address_handles.das:61: both spellings name the same function
tests/language/test_function_address_handles.das:61:    expected: 0x0
tests/language/test_function_address_handles.das:61:    got: 0x562f1978a000
[E] --- FAIL 'test_both_spellings_produce_the_same_handle'
[E] --- FAIL 'test_dispatch_table_of_inline_handles'
4 tests, 2 passed, 2 failed, 0 errors, 0 skipped                  # exit 2
$ ... -load_module <patched>/dasLLVM ... -jit -jit-no-cache -- --test tests/language/test_function_address_handles.das
4 tests, 4 passed, 0 failed, 0 errors, 0 skipped                  # exit 0
```

dastest prints the first argument of `t |> equal` as "expected": `0x0` is
what the inline spelling produced, the address is the value spelling.

## Case 4b, the context matrix

```
$ $DASTEST -- --test tests/language/test_function_address_cast_contexts.das
--- PASS 'test_reference_handle_is_not_null'
[E] --- FAIL 'test_assignment_to_a_local'          expected: 0x0
[E] --- FAIL 'test_declaration_with_initializer'   expected: 0x0
--- PASS 'test_function_argument'
[E] --- FAIL 'test_fixed_array_element_store'      expected: 0x0
[E] --- FAIL 'test_struct_literal_field'           expected: 0x0
[E] --- FAIL 'test_struct_field_assignment'        expected: 0x0
[E] --- FAIL 'test_arithmetic_operand'             expected: 0x0
--- PASS 'test_store_through_a_pointer'
9 tests, 3 passed, 6 failed, 0 errors, 0 skipped                  # exit 6
$ ... -load_module <patched>/dasLLVM ... -jit -jit-no-cache -- --test tests/language/test_function_address_cast_contexts.das
9 tests, 9 passed, 0 failed, 0 errors, 0 skipped                  # exit 0
```

The same six contexts yield `0x0` with `options optimize = false`, so the
optimizer is not the cause. Two further contexts were probed and left out
of the test because their outcome is not a clean 0: a `return
reinterpret<uint64>(@@fn)` from a helper yields a non-null address that
differs from the reference (in the interpreter and under the patched JIT
alike, not understood), and the cast inside a string interpolation yields
the reference address in the interpreter but does not compile inside a
`[test]` function (`cast requires unsafe`).

## Case 1

```
$ cd tests-cpp/big/standalone_module_global
$ $SDK/bin/daslang standalone_module_global_fixture.das
standalone_module_global: PASSED                                   # exit 0
$ $SDK/bin/daslang $SDK/utils/aot/main.das -- -aot standalone_module_global_fixture.das out_aot/gen.cpp
[I] Aot to out_aot/gen.cpp                                         # exit 0
$ $SDK/bin/daslang $SDK/utils/aot/main.das -- -ctx standalone_module_global_fixture.das out_ctx
daslib/aot_standalone.das:227:33: error[31206]: macro caused exception during visitGlobalLetBody -- invoke null method function, type<aot_standalone::StandaloneContextGen>.visitGlobalLetVariableInit
EXCEPTION: AOT codegen failed: 1 codegen error(s) during emission (see log)
 at daslib/aot_cpp.das:4410:4                                      # exit 1, out_ctx empty
```

Link blocker, isolated with `evidence/link_blocker/samefile_global.das`
(globals in the entry module, which RC2 does generate):

```
$ $SDK/bin/daslang $SDK/utils/aot/main.das -- -ctx samefile_global.das out          # exit 0
$ g++ -std=c++17 -O1 -fno-rtti -I$SDK/include -Iout -c out/samefile_global.das.cpp -o out/ctx.o
$ g++ -std=c++17 -O1 -fno-rtti -I$SDK/include -Iout -c host_main.cpp -o out/host.o
$ g++ out/host.o out/ctx.o -L$SDK/lib -llibDaScript -llibDaScript_runtime -llibDaScript -llibUriParser -lpthread -ldl -lm -o out/samefile_standalone
samefile_global.das.cpp:(.text+0x18aa): undefined reference to `das::InitGlobalVar(das::Context&, das::GlobalVariable*, das::GlobalVarInfo)'
$ nm -C --defined-only $SDK/lib/liblibDaScript_runtime.a | grep InitGlobalVar
0000000000000170 T das::InitGlobalVar(das::Context&, das::GlobalVariable*, das::GlobalVarInfo const&)
$ g++ -std=c++17 -O1 -fno-rtti -I$SDK/include -c abi_shim.cpp -o out/shim.o
$ g++ out/host.o out/ctx.o out/shim.o ... -o out/samefile_standalone          # exit 0
$ ./out/samefile_standalone
get_retries() = 0
get_total_budget_ms() = 0                                          # exit 1: initializers never ran
```

The generated constructor ends with `context.runInitScript()`; the emitted
`__init_script` is never called and `context.globals` is never zeroed.

## Not verified

- The generated `-aot` C++ was inspected, not compiled and run (that needs a
  daslang build, which this project does not do).
- Upstream master commit `8f4d87cac02c` was read, not built and run; the
  claim that it fixes case 1 rests on its diff.
- The `tests-cpp/big/standalone_module_global/CMakeLists.txt` was written
  after `tests-cpp/big/standalone_ctx/CMakeLists.txt` and not configured.

## Impact on wasm3das

`source/m3_exec.das` `op_Compile` writes `op_Call`'s address into a code
page as `rewrite[0] = reinterpret<code_t>(reinterpret<u64>(@@op_Call))`, a
store through a pointer: one of the three contexts in which the interpreter
yields the real address (case 4b). The port therefore works by landing in a
passing context, not by design; spelling it through a local
(`let op = @@op_Call`) is what is correct in every tier and is a candidate
port change once the upstream answer is known.
