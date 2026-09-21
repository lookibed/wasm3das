# LLVM JIT: `p++` / `p--` on a pointer is a runtime call, `p += 1` is an intrinsic

daslang 0.6.4, fork master `d6dbcfd75` (2026-09-21). `modules/dasLLVM/daslib/llvm_jit_intrin.das`, table `g_intrin_lookup`, "pointer math".

## What happens

The table intrinsifies `$::i_das_ptr_set_add`, `$::i_das_ptr_add`, `$::i_das_ptr_set_sub` and `$::i_das_ptr_sub`, so `p += n`, `p + n`, `p -= n` and `p - n` become a GEP. `p++` and `p--` lower to `$::i_das_ptr_inc` / `$::i_das_ptr_dec`, which are not in the table, so the JIT emits a call through the builtin's function pointer with the pointer variable passed BY REFERENCE:

```
mov    %rdi,(%rsp)              ; _pc spilled to the frame
mov    0x6ebd2(%rip),%rax       ; $::i_das_ptr_inc
mov    $0x8,%esi
mov    %rsp,%rdi                ; &_pc
call   *(%rax)
mov    (%rsp),%rsi              ; _pc reloaded
```

(objdump of a cached DLL of wasm3das, `m3_exec::op_SetRegister_i32`). Two consequences beyond the call itself: the variable lives in memory for the rest of the function, and because its address escaped, LLVM refuses to turn a following `return f(...)` into a tail call - the whole function keeps its frame. In wasm3das every operand reader ended with `_pc++`, so every one of the 500 interpreter operations paid this and none of them tail-called its successor; spelling the readers `_pc += 1` gave the same operation an 11-instruction body ending in `jmp`.

## Proposed change

Two more rows in `g_intrin_lookup`, `"$::i_das_ptr_inc"` and `"$::i_das_ptr_dec"`, lowered exactly like `i_das_ptr_set_add` / `i_das_ptr_set_sub` with the element size as the constant. The port carries the `+= 1` spelling meanwhile.
