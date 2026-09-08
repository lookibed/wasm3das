# What one wasm operation costs in the daslang interpreter

2026-09-08. Owner of the change this note documents: `source/m3_exec.das`,
`source/m3_exec_defs.das`, `source/m3_core.das`.

## The measuring device

A synthetic code page — N copies of one operation word plus its immediates,
terminated by an operation that returns `m3Err_none` — driven through the real
`RunLoop`, N * passes times. One iteration is exactly one executed wasm
operation, with no parser, no compiler and no wasm module involved, so a
candidate spelling can be priced before it is written into the port. The
harness lives outside the tree (`tmp/opbench.das`, git-ignored); it is a few
dozen lines and is trivially reconstructed from this note.

Every number below is the **minimum of five interleaved runs** on a loaded
4-core machine. Medians of the same series sit 3-8% higher; the ordering is
stable across runs, the absolute level is not.

## The result that matters

    dispatch only (an operation that just returns the sentinel)     56 ns/op

    op_i32_Add_ss, nested plain-call helpers (before)              283 ns/op
    op_i32_Add_ss, nested helpers marked [inline]                  272 ns/op
    op_i32_Add_ss, flat [inline] helpers, _sp by value             214 ns/op
    op_i32_Add_ss, flat [inline] helpers, _sp by reference         204 ns/op
    the same operation with the expansion written out by hand      140 ns/op
    the same, expanded by source/m3_exec_expand.das                128 ns/op

The daslang interpreter evaluates **one node per statement, per call and per
inline splice**, and the four points above differ only in how many nodes an
operand read leaves behind. Dividing the differences by the node counts of the
post-optimisation dumps (`mcp__daslang__ast_dump`, `mode=source`) gives a
consistent **~8 ns per evaluated node**. That single number explains every
result in this note.

## Consequences, in the order they were applied

1. **A nested helper chain is the cost, not the call.** `slot_i32` called
   `slot_ptr_i32` called `immediate_i32`: three calls per operand. Marking the
   chain `[inline]` without flattening it changes nothing (272 vs 274), because
   each splice keeps its own body, its own block and its own result temporary.
   Flattening each helper into the single C macro expansion — which is what the
   C preprocessor writes at the use site anyway — is the win.

2. **An `[inline]` argument passed by value is copied into a temporary.**
   A by-reference argument only binds. `_sp` by reference is worth 10 ns per
   operation with two operand slots.

3. **`[inline]` is therefore a loss for a function with many by-value
   parameters.** `Call` and `nextOpImpl` take the five interpreter registers by
   value; splicing them replaces one call node with five argument copies plus a
   result temporary. Measured on fib 28: 4.04 s with them inlined against
   3.91 s without. Both are deliberately left as plain calls, with a comment
   saying so, so that the next reader does not "fix" them.

4. **An `[inline]` splice always keeps a result temporary.** Even a body that
   is a single `return <expr>` becomes `var _inlN_res; _inlN_res = <expr>;`
   followed by the caller's own copy. There is no spelling that avoids it: a
   by-reference return is rejected (`[inline] result must be by-value`). This
   is the whole of the remaining gap between the flat `[inline]` helpers
   (204 ns/op) and the hand-written expansion (140 ns/op), and closing it would
   need a compile-time macro that rewrites the call site, not a function.
   That macro is `source/m3_exec_expand.das`; see the section below.

5. **The dispatch loop.** Turning the sentinel test from an `if`/`break` pair
   in the body into the `while` condition removes two nodes per executed
   operation: 56 -> 53 ns for the empty operation. Dropping the `operation`
   temporary was measured too and is *not* a win (the pointer has to be
   recovered with an extra subtraction).

6. **`memset8` for `c_memset`.** `op_Entry` zeroes a function's locals on every
   wasm call and `op_MemFill` fills linear memory; the element loop cost one
   interpreter node per byte. C calls `memset` there, and `memset8` is its
   daslang builtin. `c_memmove` likewise hands disjoint ranges to `memcpy`,
   which is what C's `memmove` does with them.

## What was measured and rejected

| idea | result |
|---|---|
| `[inline]` on the nested helper chain, unflattened | 272 vs 274 ns/op — noise |
| flat helper without the `unsafe { }` block (per-expression `unsafe(...)`) | 204 vs 184 ns/op — the extra `unsafe(...)` wrappers are nodes |
| `[inline]` on `Call` / `nextOpImpl` / `jumpOpImpl` | fib 28 4.04 s vs 3.91 s — a loss, see 3 |
| dispatch without the `operation` temporary | 64 vs 56 ns/op — a loss |
| a `let` (constant-folded) dispatch sentinel instead of the `var` global | 49 vs 56 ns/op — a real 7 ns/op, **not taken**: `m3Ret_nextOp` is compared by pointer and a `let` string global lets a backend materialise its own copy of the literal, which is exactly what the `var` in `m3_exec_defs.das` exists to prevent (the JIT and AOT builds depend on it) |

## The known daslang defect in the way

`_pc++` used as a *value* (`reinterpret<i32 const?>(_pc++)[0]`, the literal
shape of C's `#define immediate(TYPE) * ((TYPE *) _pc++)`) aborts the
0.6.4-RC2 interpreter at run time with

    EXCEPTION: internal integration error, missing WrapType implementation
    or it's not included

for `pc_t` (`void??`), both for a local and for a reference parameter. It
compiles cleanly. This is what stops a call macro from emitting C's operand
reader as one side-effecting expression, so every helper here has to spell the
advance as a separate `_pc++` statement. Worth a reduced upstream reproducer.

## Closing the last gap: the preprocessor daslang does not have

`source/m3_exec_expand.das` (2026-09-08) is consequence 4 acted on. It is a
compile-time pass, not a function: it runs before type inference on the
`m3_exec` module and rewrites every call of the 28 operand readers at its use
site into the reader's own read expression followed by its own `_pc++`
statement — which is what the C preprocessor leaves there, and what the
hand-written expansion measured above is. Because the advance must stay a
separate statement (the defect above), a `[call_macro]` emitting one expression
was never an option; the rewrite has to move statements around a block, which
is a pass macro's job.

Two properties make it safe to leave the 509 bodies alone:

- the expansion is **cloned from the `[inline]` helper it replaces**, so
  `m3_exec.das` stays the single transcription of the C macros. A helper whose
  body is not shaped like the macro it ports (`unsafe { let value = <read>;
  _pc++; return value }`) is a compile error, not a silent skip;
- **evaluation order is preserved.** One reader in a statement that always
  completes expands in place with the advance as the next statement; two or
  more readers, or a statement that may not complete (a return, an if, a loop),
  bind a temporary each in call order, each immediately followed by its own
  advance. A reader inside a short-circuit `&&`/`||` or a `?:` arm cannot be
  hoisted without changing which reads happen, and is refused. All 641 call
  sites in the port take the in-place path.

`bool_reg` is deliberately not rewritten: with no side effect and one by-value
argument its splice already folds to a single node (`_r0 = (a < b) ? 1 : 0`).

Measured with the device at the top of this note, minimum of five interleaved
runs against the same tree without the pass:

| operation | flat `[inline]` | expanded | AST nodes |
|---|---|---|---|
| `op_i32_Add_ss` | 206 ns/op | 128 ns/op | 64 -> 44 |
| `op_u32_LessThan_ss` | 191 ns/op | 122 ns/op | 59 -> 39 |
| `op_SetSlot_i32` | 117 ns/op | 91 ns/op | 29 -> 19 |
| an operation with no operand read | 76 ns/op | 71 ns/op | unchanged |

so an operand read costs 65 ns before the pass and 28 ns after it, and the
whole gap consequence 4 describes is gone. Wall clock, minimum of three to four
interleaved A/B pairs with the startup subtracted: fib 28 1.99 -> 1.62 s,
`chipmunk_hash_scene 600` 7.52 -> 5.85 s, `lodepng_roundtrip_hash 0`
1.49 -> 1.22 s.

**What the pass costs at startup.** `-log-compile-time`, same machine, total
compile of `app/wasm3.das`: 1.495 s -> 1.554 s (+3.9%), and the process to
`Result:` on a trivial call 1.581 s -> 1.649 s (+4.3%). The pass itself is
67 ms of that, against which the optimizer saves 44 ms on the smaller `m3_exec`
tree (`m3_exec` alone: 0.531 s -> 0.534 s). The rest is the macro module
itself: 65 ms to compile plus 7 ms to simulate, and 15 ms for `daslib/ast`.
That last number is why the pass requires `daslib/ast` alone and registers
through `add_new_pre_infer_macro` instead of the `[pre_infer_macro]`
annotation: `daslib/ast_boost` costs another 170 ms and
`daslib/templates_boost` (needed for `qmacro`) another 440 ms, which would have
made the whole thing a 38% startup regression. The price of writing the three
generated nodes by hand is `is`/`as` on AST pointers, a variant macro of
`ast_boost`, which the module spells as six `__rtti` casts.

    module requiring nothing      0.055 s   (daslang process floor)
    + daslib/ast                  0.070 s
    + daslib/ast_boost            0.241 s
    + daslib/templates_boost      0.680 s
