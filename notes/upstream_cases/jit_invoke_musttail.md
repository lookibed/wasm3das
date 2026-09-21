# LLVM JIT: a call through a function value is never a tail call; a threaded interpreter needs it to be

daslang 0.6.4, fork master `d6dbcfd75` (2026-09-21). `modules/dasLLVM/daslib/llvm_jit.das`: `visitExprInvoke` -> `build_call_dispatch`; `include/daScript/simulate/simulate.h`: `SimFunction`.

## What happens

An invoke of a `function<...>` value is lowered as: extract the `SimFunction *` from the `Func`, load `SimFunction::jitFunction`, and if it is set call it with the generic JIT ABI `vec4f (Context *, vec4f * args, void * cmres)` - the arguments packed into a `vec4f` array on the caller's stack, the result unpacked from a `vec4f`, `context->stopFlags` cleared after the call - else fall to `jit_call_or_fastcall`. `jitFunction` is the public wrapper of the function; the native-signature body (`impl`, hidden visibility) is what a direct call to a known function uses.

For a call in return position this means no tail call is possible: the callee's signature is the wrapper's, not the caller's, and the argument array is a caller alloca that escapes. A threaded interpreter (wasm3das: every operation ends with `return operation(_pc + 1, _sp, _mem, _r0, _fp0)` where `operation` is read from the code page, C's `M3_MUSTTAIL return nextOpImpl()`) therefore nests one LLVM frame per executed operation until the wasm function returns. Micro-model (`notes/upstream_cases/tests/jit_tests/dispatch.das`, `-jit` at O3, 2 000 000 steps): one flat invoke costs 4.4 ns; the same invoke as a chain costs 209 ns per step, the frames and the pages they touch; a chain of DIRECT calls of the same shape costs 1.3 ns per step, because LLVM tail-calls a direct call whose signature matches the caller's. In the port the JIT and `-exe` tiers run fib(35) 4-5x slower than the same program's `-ctx` build, where g++ emits `jmp *%r9`.

## Proposed change

Give the JIT the native entry of a jitted function and let an invoke use it:

1. `SimFunction` gains `void * jitImpl` beside `jitFunction` (the impl of the same function, native signature `ret (args..., Context *)`; null for anything not jitted); `das_instrument_jit` / `das_remove_jit` set and clear it with `jitFunction`.
2. `build_call_dispatch`, for a `function<...>` value whose type is "simple" (every argument and the result a scalar, pointer, string or handle passed by value, no cmres, no blocks): load `jitImpl`; if non-null call it directly with the native arguments and `Context *`, else keep today's path.
3. In `visitExprReturn`, when the returned expression is such an invoke and the caller's own signature matches the callee's (the threaded-interpreter case), emit the direct call as `musttail` followed by `ret`: the tail-jump chain C gets from `M3_MUSTTAIL`.

Until then the port carries a stand-in, and since 2026-09-22 it carries it in the merged source: an infer pass gated on `prog.policies.jit_enabled` turns the code-page word into an operation index and `nextOpImpl` into a generated dispatch of DIRECT calls, for the JIT tiers only (`docs/execution-design.md` section 7). Every other tier compiles C's form unchanged, so the `-ctx` tier keeps its replicated `jmp *%r9` and loses nothing. objdump of the cached DLL: every operation is six instructions ending in `jmp m3_DispatchOp`, `nextOpImpl` is a single five-byte `jmp`, and the dispatch ends in `jmp` into the operations. What the stand-in cannot avoid is the central dispatch itself - its own prologue and its comparisons - which is what the change proposed above would remove: with `musttail` on the invoke the C form would tail-jump straight from operation to operation, with no index, no pass and no dispatch function at all.
