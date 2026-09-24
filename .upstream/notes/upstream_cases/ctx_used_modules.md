# standalone context: every default C++ module the compiler loaded is registered at start, used or not

daslang 0.6.4, master `1969ad4d4` (2026-09-17). Reproduced with `utils/aot/main.das -- -ctx` on any program that requires a compile-time-only module (a macro module that requires `daslib/ast`) and reaches at least one C++ module beyond the builtin one; the case is wasm3das (`app/wasm3.das`, whose `m3_exec_expand.das` macro module requires `daslib/ast`).

## What happens

`collectLinkedModules` (`daslib/aot_cpp.das`) starts from the modules the runtime program uses (`collectUsedModules`: functions, structures, enums, handled types) and then, as soon as that set holds any C++ module other than `Module_BuiltIn`, adds every C++ module of `DEFAULT_MODULE_ORDER` the compiler loaded:

```das
let isDefault = DEFAULT_MODULE_ORDER |> find_index(string(mod.cppClassName)) >= 0
if ((isDefault || (linked |> key_exists(mod))) && canAotModule(mod)) {
    insertWithDependencies(linked, visited, mod)
}
```

For wasm3das that registers `rtti_core` and `ast_core`, which only the macro expansion needed at compile time. The standalone binary then runs their constructors at every process start: with a timed copy of the host, of a 20 ms start the module registration is 17 ms, of which `ast_core` is 6 ms and `rtti_core` 2 ms (`$` 8 ms, `math` + `strings` + `fio_core` 2.5 ms, `Module::Initialize` 2 ms), and the binary carries 13 MB of code nothing calls (44.8 MB against 31.8 MB).

## Proposed change

Register the used modules plus their C++ dependencies, which the `insertWithDependencies` walk on the next line already does: drop the `isDefault ||` term. A module whose constructor requires another by name declares that dependency, so the walk brings it in. Patch attached (`ctx_used_modules.patch`, on top of `ctx_direct_calls.patch`, against master `1969ad4d4`).

## Measured (wasm3das, Ryzen 7 7435HS, gcc 11.4)

- the emitted module table: `$`, `math`, `strings`, `rtti_core`, `ast_core`, `fio_core` -> `$`, `math`, `strings`, `fio_core`;
- the binary: 44.8 MB -> 31.8 MB unstripped;
- the process start (`fib32.wasm --func fib 1`, wall, 30 runs): see `docs/native-build.md`, section 7, E5;
- `run-spec-test.py` through the patched binary: 17863/17863; `run-wasi-test.py`: 12/12.

What is left of the start after this is the constructor of the builtin module itself (about 8 ms: its function tables exist for the compiler, which a standalone context never runs) and `Module::Initialize`; a runtime-only registration of the builtin module would be the next step and is a separate ask.
