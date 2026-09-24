# standalone context: every call into a required module goes through `fnByMangledName` + `das_invoke_function`

daslang 0.6.4, master `1969ad4d4` (2026-09-17). Reproduced with `utils/aot/main.das -- -ctx` on any program whose hot code lives in required modules; the case below is wasm3das (`app/wasm3.das` requiring `source/*.das`).

## What happens

`CppAot.isHybridCall` (`daslib/aot_cpp.das:3838`) answers `true` for every function outside the entry module:

```das
if (func.flags.noAot || func.flags.aotHybrid || func.moreFlags.requestJit) return true;
return func._module != program.getThisModule;
```

so `visitExprCall`/`visitExprCallFunc` emit

```cpp
das_invoke_function<char *>::invoke<...>(__context__, nullptr,
    Func(__context__->fnByMangledName(/*@m3_exec::RunLoop ...*/ 0x74b859ccd334c48d)), ...)
```

for a callee that the very same translation unit defines as an ordinary `inline` C++ function with a forward declaration at the top (a standalone context emits every used foreign function, `foreignUsedFunctions`). In the wasm3das context that is 1734 call sites, every call between the interpreter's own functions included (`RunLoop`, `nextOpImpl`, the `op_*` operations calling their helpers); only calls from the entry module are direct. Each such call costs a Context lookup plus an indirect call, and no C++ inlining across it.

## Proposed change

In a standalone context, a foreign function that is emitted into the unit is called directly. Three lines: `CppAot` gets `directForeign : table<uint64>` (mangled-name hashes), `isHybridCall` consults it before falling back to the module test, and `genStandaloneSrc` fills it from `foreignUsedFunctions(program, false)` before visiting the entry module. `[no_aot]`, `[hybrid]` and `requestJit` functions keep the lookup, and `ExprAddr` (`@@fn`) keeps `queryByMNH` because it needs a `SimFunction`. Patch attached (`ctx_direct_calls.patch`, against master `1969ad4d4`).

## Measured (wasm3das, Ryzen 7 7435HS, gcc 11.4, the same emitted program before and after)

- lookup sites in the generated unit: 1734 -> 310 (the remaining ones are `@@fn` addresses for the compile tables);
- `fib32.wasm --func fib 35`, wall, median of 3 interleaved: 1.65 s -> 1.15 s (C wasm3 reference 0.37 s);
- the 98-check fixture corpus, execution without process start: 4.15-4.26 s -> 3.80-4.15 s, all 86 documented results unchanged;
- `run-spec-test.py` through the patched binary: 17863/17863.

The per-module `-aot` path has the same lookup at every cross-module call; there the callee lives in another unit, so a direct call needs the callee's declaration in the caller's unit (the emitted `inline` definitions would have to become external), which this patch does not attempt.
