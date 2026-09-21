# Executor design: the missing `M3_MUSTTAIL` and what an operation costs

Decided 2026-09-06 (RunLoop dispatch), 2026-09-08 (operand-reader expansion),
2026-09-21 (C's form of the operation ABI restored, section 6) and 2026-09-22
(the LLVM JIT's own dispatch, section 7).
Owners: `source/m3_exec.das`, `source/m3_exec_defs.das`,
`source/m3_exec_expand.das`, `source/m3_compile.das`, `source/m3_core.das`.
This document replaces the working notes `exec_trampoline_design.md` and
`interp_node_cost_2026-09-08.md`; every number below comes from them.

## 1. The problem

C wasm3 threads its interpreter through the code pages: every `op_*` ends with

```c
#define nextOpDirect()   M3_MUSTTAIL return nextOpImpl()
#define nextOpImpl()     ((IM3Operation)(* _pc))(_pc + 1, _sp, _mem, _r0, _fp0)
```

`M3_MUSTTAIL` turns that into a jump, so a whole wasm function body executes in
a single native frame and the registers `_pc/_sp/_mem/_r0/_fp0` stay in machine
registers. Daslang has no tail calls. Spelled as an ordinary call, every
executed wasm operation nested one more Daslang frame plus native frames: the
native stack, not the wasm stack limit of `op_Entry`, bounded wasm recursion,
and each operation paid two calls instead of one.

## 2. The RunLoop dispatcher

One idea, two changes: **the operation no longer calls its successor; it returns
to a dispatch loop and hands its updated state back through its own
parameters.**

### The operation ABI takes its five inputs by reference

```das
typedef public IM3Operation = function<(var _pc : pc_t&; var _sp : m3stack_t&;
    var _mem : M3MemoryHeader?&; var _r0 : m3reg_t&; var _fp0 : f64&) : M3Result>
```

C passes `d_m3OpSig` by value and the callee's copies flow into the next
operation as arguments. Here the dispatcher owns the five values and every
operation mutates them in place, which is exactly "the values that would have
been passed to the next operation". The 509 operation bodies already assign
`_r0`, `_fp0`, `_mem` and advance `_pc`, so nothing else in them changes.

Measured alternatives on the 0.6.4 interpreter (10M calls of a five-argument
operation returning an `M3Result`; baseline call about 29 ns):

| what the callee does on top of being called | added ns per call |
|---|---|
| write five values into five scalar globals | +79 |
| write five values into one global struct | +110 |
| write five values through a cached global struct pointer | +90 |
| write five values through a state pointer passed as a sixth argument | +50 |
| **update the caller's values through reference parameters** | **+0** |

A global read or write costs 8-16 ns in the interpreter and the loop would have
to read the state back, so an interpreter-state struct is slower than the nested
calls it replaces. Reference parameters remove the write-back entirely: the
dispatcher's locals are the interpreter state. Passing five references costs the
same as passing five values (1.22 s against 1.31 s per 10M iterations).

### `nextOpDirect` means "return to my dispatcher"

```das
var public m3Ret_nextOp : M3Result       // unique sentinel, compared by pointer

[inline] def nextOpDirect(...5 by reference...) : M3Result { return m3Ret_nextOp }
[inline] def jumpOpDirect(var _pc : pc_t&; PC : pc_t) : M3Result { _pc = PC; return m3Ret_nextOp }

def RunLoop(var _pc : pc_t; ... by value ...) : M3Result {
    while (true) {
        let operation = reinterpret<IM3Operation>(_pc[0])
        _pc = _pc + 1
        r = operation(_pc, _sp, _mem, _r0, _fp0)
        if (reinterpret<void?>(r) != nextOpId) { break }
    }
    return r
}
```

- `[inline]` splices the two helpers into the call site, so `return
  nextOpDirect (_pc, _sp, _mem, _r0, _fp0)` costs no call and the bodies keep
  the C spelling verbatim.
- The sentinel is compared by pointer, like the loop ids, never by content.
  **It must be `var`, not `let`**: a `let` string global is constant-folded and
  the JIT and the AOT build materialise their own copy at another address, so
  every operation looks like a trap (`Error: m3: dispatch the operation at
  _pc`). C relies on one static `const char *` object with one address; `var`
  is the faithful spelling. A `let` sentinel would save 7 ns per op and is not
  taken for that reason. Any other pointer comparison of an `M3Result` or a
  loop id against a `let` global has the same exposure.
- `nextOpImpl`, `jumpOpImpl` and `RunCode` are `RunLoop`: in C those macros
  mean "run the code at this pc to completion and give me its result".

### Nesting: one Daslang frame per wasm frame, not per operation

C makes a real (non-tail) call in exactly three places and the port keeps them:

| site | C | port |
|---|---|---|
| `op_Call`, `op_CallIndirect` | `Call (...)`, which tail-jumps into the callee | `Call` calls `nextOpImpl`, a nested `RunLoop` |
| `op_Entry` | `m3ret_t r = nextOpImpl ()` | nested `RunLoop` |
| `op_Loop` | `do { r = nextOpImpl (); } while (r == _pc)` | nested `RunLoop` per iteration |

A wasm call nests a bounded number of Daslang frames (`op_Call` -> `Call` ->
`RunLoop` -> `op_Entry` -> `RunLoop`), independent of how many operations the
callee executes.

### Traps, loop ids and the stack check

The `M3Result` protocol is untouched: a trap is any `M3Result` other than
`m3Err_none` and the sentinel, `RunLoop` returns it unchanged and the enclosing
`op_Entry`/`op_Loop`/`Call` sees what C sees; `op_ContinueLoop` still returns
the loop's pc reinterpreted into an `M3Result` and `op_Loop` compares it by
pointer (a code-page address can collide with neither the sentinel nor
`m3Err_none`); `op_Entry` keeps `_sp + maxStackSlots < _mem->maxStack`, so
`[trap] stack overflow` comes from the wasm stack limit (`--stack-size`).

The compiler emits the same words: `IM3Operation` values are stored in the code
pages, immediates keep their layout, `op_Compile`'s self-rewrite rewinds `_pc`
so the dispatcher re-reads the patched `op_Call` word. Operation names, order,
comments and immediates are untouched; the deviation is documented once at the
top of `m3_exec.das` and in the manifest row.

### Stack sizes

Probed with `call.0.wasm`'s `runaway` (the spec suite's deepest
`assert_exhaustion`) and the default 64 KiB wasm stack: `options stack` of
6 MiB reaches `[trap] stack overflow` from `op_Entry`; 4 MiB dies as a Daslang
"fast call depth limit exceeded" first. The interpreter also consumes native
stack per Daslang frame, so the two limits stay in proportion: with 6 MiB,
`ulimit -s 16384` traps cleanly and the default 8 MiB thread stack still
crashes. `app/wasm3.das` reserves 64 MiB against `scripts/wasm3`'s `ulimit -s
262144`, roughly a 10x margin that allows a `--stack-size` much larger than
the default. The standalone binary reserves a 256 MiB thread stack itself
(`native/standalone_main.cpp`) and needs no launcher.

### Results of the dispatch change

Wall clock around `scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib N`:

| build | fib 30 | fib 35 |
|---|---|---|
| before, one Daslang frame per executed operation | 19.37 s | ~223 s (extrapolated) |
| trampoline, `nextOpDirect` a plain function | 15.45 s | — |
| trampoline, `nextOpDirect` `[inline]` | 8.33 s / 8.88 s | 101.4 s |

## 3. What one operation costs: ~8 ns per evaluated node

Measuring device: a synthetic code page (N copies of one operation word plus its
immediates, terminated by an operation returning `m3Err_none`) driven through
the real `RunLoop`, N * passes times. No parser, no compiler, no wasm module;
a candidate spelling is priced before it is written into the port. The harness
is a few dozen lines outside the tree (`tmp/opbench.das`). Numbers are the
minimum of five interleaved runs on a loaded 4-core machine; medians sit 3-8 %
higher, the ordering is stable.

    dispatch only (an operation that just returns the sentinel)     56 ns/op

    op_i32_Add_ss, nested plain-call helpers (before)              283 ns/op
    op_i32_Add_ss, nested helpers marked [inline]                  272 ns/op
    op_i32_Add_ss, flat [inline] helpers, _sp by value             214 ns/op
    op_i32_Add_ss, flat [inline] helpers, _sp by reference         204 ns/op
    the same operation with the expansion written out by hand      140 ns/op
    the same, expanded by source/m3_exec_expand.das                128 ns/op

The daslang interpreter evaluates one node per statement, per call and per
inline splice; dividing the differences by the node counts of the
post-optimisation dumps (`mcp__daslang__ast_dump`, `mode=source`) gives a
consistent **~8 ns per evaluated node**. Consequences, in the order applied:

1. **A nested helper chain is the cost, not the call.** `slot_i32` called
   `slot_ptr_i32` called `immediate_i32`. Marking the chain `[inline]` without
   flattening changes nothing (272 vs 274): each splice keeps its own body,
   block and result temporary. Flattening each helper into the single C macro
   expansion is the win.
2. **An `[inline]` argument passed by value is copied into a temporary**; a
   by-reference argument only binds. `_sp` by reference is worth 10 ns per
   operation with two operand slots.
3. **`[inline]` is a loss for a function with many by-value parameters.**
   `Call` and `nextOpImpl` take the five registers by value; splicing them
   replaces one call node with five copies plus a result temporary (fib 28:
   4.04 s inlined against 3.91 s). Both are deliberately plain calls, with a
   comment saying so.
4. **An `[inline]` splice always keeps a result temporary** (`var _inlN_res;
   _inlN_res = <expr>;` plus the caller's copy); a by-reference return is
   rejected. That is the gap between 204 and 140 ns/op, and closing it needs a
   compile-time macro that rewrites the call site: `m3_exec_expand.das`.
5. **The dispatch loop.** The sentinel test as the `while` condition instead of
   an `if`/`break` pair removes two nodes per operation (56 -> 53 ns). Dropping
   the `operation` temporary is a loss (64 vs 56).
6. **`memset8` for `c_memset`**: `op_Entry` zeroes locals on every wasm call and
   `op_MemFill` fills memory; the element loop cost one node per byte. C calls
   `memset` there. `c_memmove` hands disjoint ranges to `memcpy`.

Measured and rejected: `[inline]` on the unflattened chain (noise); flat helper
without the `unsafe { }` block, per-expression `unsafe(...)` instead (204 vs
184: the wrappers are nodes); `[inline]` on `Call`/`nextOpImpl`/`jumpOpImpl`
(loss); dispatch without the `operation` temporary (loss); a `let` sentinel
(7 ns real, not taken, see above).

### The known daslang defect in the way

`_pc++` used as a value (`reinterpret<i32 const?>(_pc++)[0]`, the literal shape
of `#define immediate(TYPE) * ((TYPE *) _pc++)`) compiles but aborts the 0.6.4
interpreter at run time with `EXCEPTION: internal integration error, missing
WrapType implementation or it's not included` for `pc_t` (`void??`), local or
reference parameter alike. So no call macro can emit C's operand reader as one
side-effecting expression; every helper spells the advance as a separate
`_pc++` statement. Worth a reduced upstream reproducer.

## 4. The preprocessor daslang does not have: `m3_exec_expand.das`

A compile-time pass, not a function. It runs before type inference on the
`m3_exec` module only and rewrites every call of the 28 operand readers
(`immediate`, `slot`, `slot_ptr` families) at its use site into the reader's
own read expression followed by its own `_pc++` statement, which is what the C
preprocessor leaves there. Because the advance must stay a separate statement,
a `[call_macro]` emitting one expression was never an option; moving statements
around a block is a pass macro's job. Two properties keep the 509 bodies
untouched:

- the expansion is **cloned from the `[inline]` helper it replaces**, so
  `m3_exec.das` stays the single transcription of the C macros; a helper whose
  body is not shaped like the macro it ports (`unsafe { let value = <read>;
  _pc++; return value }`) is a compile error, not a silent skip;
- **evaluation order is preserved**: one reader in a statement that always
  completes expands in place with the advance as the next statement; two or
  more readers, or a statement that may not complete (return, if, loop), bind a
  temporary each in call order, each followed by its own advance; a reader in
  a short-circuit `&&`/`||` or a `?:` arm is refused. All 641 call sites take
  the in-place path.

`bool_reg` is not rewritten: with no side effect and one by-value argument its
splice already folds to one node. The pass requires `daslib/ast` only and
registers through `add_new_pre_infer_macro`, because `daslib/ast_boost` costs
another 170 ms of startup and `daslib/templates_boost` (needed for `qmacro`)
another 440 ms, a 38 % startup regression; the price is writing the three
generated nodes by hand with six `__rtti` casts. Note that `macro_error` from a
pass does not stop compilation on 0.6.4; `macro_sticky_error` does.

    module requiring nothing      0.055 s   (daslang process floor)
    + daslib/ast                  0.070 s
    + daslib/ast_boost            0.241 s
    + daslib/templates_boost      0.680 s

Measured with the device above, minimum of five interleaved runs:

| operation | flat `[inline]` | expanded | AST nodes |
|---|---|---|---|
| `op_i32_Add_ss` | 206 ns/op | 128 ns/op | 64 -> 44 |
| `op_u32_LessThan_ss` | 191 ns/op | 122 ns/op | 59 -> 39 |
| `op_SetSlot_i32` | 117 ns/op | 91 ns/op | 29 -> 19 |
| an operation with no operand read | 76 ns/op | 71 ns/op | unchanged |

An operand read costs 65 ns before the pass and 28 ns after it. Wall clock with
startup subtracted: fib 28 1.99 -> 1.62 s, `chipmunk_hash_scene 600`
7.52 -> 5.85 s, `lodepng_roundtrip_hash 0` 1.49 -> 1.22 s. Startup cost of the
pass (`-log-compile-time`, `app/wasm3.das`): 1.490 -> 1.558 s at the minimum
(+4.6 %), 1.498 -> 1.596 s at the median (+6.5 %); simulation itself gets
faster (0.082 -> 0.072 s), the macro module costs 65 ms to compile plus 7 ms to
simulate plus 15 ms for `daslib/ast`.

### Results on the manual fixtures (2026-09-09)

`tests/manual/run_fixtures.py --runtimes wasmtime,wasm3,das`, 98 checks, quiet
machine, baseline = `main` at `9cdd03d`, candidate = flat readers + expansion
pass + `memset8` + the dispatch loop + `-no-dynamic-modules` + `options
never_inline = true` in the cold modules. All 86 documented results match in
both runs.

| | baseline | branch | ratio |
|---|---|---|---|
| sum over 98 checks, interpreter | 452.8 s | 274.8 s | 1.65x |
| per-row ratio | | | min 1.51x, median 1.65x, max 2.05x |
| start-up (`fixtures/add` row) | 2.45 s | 1.53 s | 1.6x |
| binjgb 16 frames (three rows) | 35.2–35.9 s | 22.4–23.2 s | 1.52–1.58x |
| chipmunk 600 steps (five rows) | 11.6–14.1 s | 7.0–8.9 s | 1.53–1.74x |
| wasm3 C, sum (control) | 2.06 s | 2.01 s | |

The flat readers and the dispatch loop gave 1.2–1.3x on execution, the
expansion pass another 1.22–1.29x on top, `-no-dynamic-modules` 0.13 s and
`never_inline` in the cold modules 0.57 s off every start-up.

## 5. Verification

`tests/integration/test_m3_exec.das`, `test_m3_compile.das`,
`test_fib32_regression.das`, `test_lang_modules.das`, `test_spec_core.das`
(16 503 assertions, 0 failures), `scripts/gate.sh`, and the original
`run-spec-test.py` (17 863/17 863) and `run-wasi-test.py` (12/12), see
`docs/test-suites.md`.

## 6. The C form restored (2026-09-21, PR #54, pending the emitter patch)

The trampoline of section 2 exists because a daslang call in tail position
nests a frame. On the ctx tier that turned out to be a property of daslang's
`-ctx` emitter, not of the language: the emitter routed every call into a
required module through `Context::fnByMangledName` + `das_invoke_function`
(`docs/native-build.md`, section 7, E1), a shape gcc cannot sibling-call. With
the three-line emitter patch that calls the emitted foreign functions directly,
gcc turns C's own form of the operation ABI into C's own machine code:

- `IM3Operation` takes the five registers **by value** (`d_m3OpSig`);
- `nextOpImpl`/`jumpOpImpl` are `((IM3Operation)(* _pc))(_pc + 1, d_m3OpArgs)`;
- `nextOpDirect`/`jumpOpDirect` are `return nextOpImpl(...)` /
  `return jumpOpImpl(...)`; `RunLoop` and the sentinel are gone; the 509
  operation bodies are untouched (their signatures drop the `&`).

objdump of `op_i32_Add_ss` in the resulting binary ends with the epilogue and
`jmp *%r9`: the operation chain is a chain of jumps with the registers in
machine registers, which is what `M3_MUSTTAIL` produces for C. Measured on the
same corpus and machine as the tables above (quiet stand, gcc 11.4):

| tier | fib 35, wall | corpus, execution without start | vs C wasm3 |
|---|---:|---:|---|
| C wasm3 | 0.371 s | 2.68–2.72 s | 1.0x |
| ctx, trampoline, stock emitter | 1.65 s | 4.15–4.26 s | 4.4x / 1.6x |
| ctx, trampoline, patched emitter | 1.15 s | 3.69–3.87 s | 3.1x / 1.4x |
| ctx, C form, stock emitter | 1.26 s | — | 3.4x |
| **ctx, C form, patched emitter** | **0.438 s** | **1.60–1.63 s** | **1.18x / 0.6x** |
| exe, C form | 2.25 s (unchanged) | — | the LLVM JIT emits no tail call for `return f(...)` |
| interpreter, C form | fib 30: 3.2–4.0 s against 2.49 s | — | 1.3–1.6x slower than the trampoline |

Correctness of the C-form + patch binary: spec 17863/17863, WASI fast 7/7,
fixtures 86/86 twice; the interpreter tier passes dastest (119, 4 skipped),
lint and the spec's runaway recursions (`call`, `call_indirect`, `i32`:
568/568) on the 64 MiB context stack as it did before the trampoline.

So the trampoline is a per-tier trade: it is the right dispatcher for the
daslang interpreter and the wrong one for a native build once the emitter calls
directly. The port keeps one source (the C form, PR #54) and pays 1.3–1.6x on
the interpreter tier, whose users are the gate and development; the shipped
tier is ctx. Two asks to daslang remain: the emitter patch itself
(`notes/upstream_cases/ctx_direct_calls.patch`), and tail-call emission in the
LLVM JIT for `return f(args)` with matching signatures, which would carry the
same win to the exe tier (25 ms start).

## 7. The LLVM JIT's own dispatch (2026-09-22)

Section 6 ends with "the LLVM JIT emits no tail call for `return f(...)`". That
is true only for a call **through a function value**, which is what the C form
is: `((IM3Operation)(* _pc))(...)`. daslang lowers such an invoke to the generic
wrapper ABI — the five registers are written into an argument buffer on the
stack and the target is reached with `call *%rax` — and LLVM cannot turn that
into a tail call, so under `-jit` and `-exe` a wasm loop nests one native frame
per executed operation. A **direct** call in return position, with the same
signature, is a sibling-call jump for LLVM exactly as it is for gcc; a
64-operation micro-model measured 2.1–2.6 ns per dispatched step for the direct
shape against 33–41 ns for the invoke.

The port therefore keeps C's form as the source form and lets an infer pass
change it for that one tier. `prog.policies.jit_enabled` is set by `-jit` and by
`-exe` and is false for the daslang interpreter and for the `-aot`/`-ctx`
emission, so `M3ExecDispatchPass` (`source/m3_exec_expand.das`) runs only under
the JIT and replaces six placeholder bodies of `m3_exec.das`:

| placeholder | source form (every other tier) | JIT form |
|---|---|---|
| `m3_OpWord(op)` | `reinterpret<u64>(op)` — the cast C's `EmitWord(page, op)` macro does | `m3_OpIndex(op)`, the operation's index |
| `nextOpImpl`, `jumpOpImpl` | `((IM3Operation)(* pc))(pc + 1, ...)` | `return m3_DispatchOp(pc, ...)` |
| `m3_DispatchOp` | `return m3Err_none` (never called) | `let idx = m3_WordIndex(_pc)` and the generated dispatch, whose leaves are `return op_<name>(_pc, _sp, _mem, _r0, _fp0)` |
| `m3_OpAt`, `m3_OpCount` | `@@op_NoOp`, `0` | the same tree over `@@op_<name>`, and the count, for the reverse map `m3_OpIndex` |

The index is the position of the operation in the `op_*` names of `m3_exec`
sorted by byte order, so it is a function of the source alone. Nothing outside
`m3_exec` sees it: the compile tables of `m3_compile.das` keep C's
`IM3Operation` values (`c_setSetOps`, the `M3OP(...)` rows, `c_opNull`,
`IsNoOp`), and every emission of an operation word — `EmitOp`,
`EnsureCodePageNumLines`, `CompileRawFunction` and the `op_Compile`
self-rewrite — goes through `m3_OpWord`. `op_NoOp` moved from `m3_compile.das`
to `m3_exec.das` because `Compile_Select` emits it unguarded on a polymorphic
stack, so it does reach a code page and needs an index like any other
operation; `nextOpImpl`, `jumpOpImpl`, `nextOpDirect`, `jumpOpDirect` and
`RunCode` moved from `m3_exec_defs.das` for the same reason the dispatch lives
there — only `m3_exec.das` sees every `op_*` for a direct call.

The shape of the dispatch is an empirical question, so it is an option,
`options _m3_dispatch` at the top of `m3_exec.das` (it has to be that file:
`m3_exec` is a `shared` module and compiles as a program of its own, so the
`ProgramPtr` the pass is handed carries that module's options, not the entry
file's; the leading underscore is what makes daslang accept an unregistered
option):

- `"chain"` (the measured default) — one `if (idx == k) return op_k(...)` per
  operation, which LLVM folds into a switch with a jump table;
- `"tree"` — a balanced `if (idx < mid)` tree;
- `"noinline"` — the tree, with `[hint(noinline)]` added by the pass to every
  operation, so LLVM cannot inline a small one into the dispatch.

What objdump shows on the cached DLL is in `docs/native-build.md`, section 6,
E9, with the measurements. In one line: before, the operation already ended in
`jmp nextOpImpl` but `nextOpImpl` was 156 bytes that spilled the five registers
into a 0x50-byte argument buffer, loaded `SimFunction::jitFunction` and
`call`ed it — a frame per operation; after, `nextOpImpl` is a single 5-byte
`jmp` into `m3_DispatchOp` and the dispatch's arms are `jmp`s back into the
operations, so nothing in the chain allocates. The one thing that differs between the shapes is the dispatch's own
prologue: with `"tree"` and `"chain"` LLVM inlines roughly half the operations
into it and hoists their constants, so the dispatch pushes six registers,
allocates a frame and loads four SSE constants before the first comparison (91
and 79 bytes); with `"noinline"` the dispatch starts with `mov (%rdi),%eax` and
is 11 bytes from entry to the first branch. That `"noinline"` still does not
win says the prologue is not the dominant term — the comparisons are — which is
why `"chain"`, whose jump table costs one indirect jump instead of nine
compares, is the default; `"tree"` is the one shape that is not worth having,
since it loses fib 35 against the plain C form.

## 8. Open

- A second expansion layer for the `OP_*` helpers of `m3_math_utils` and
  `m3MemData` in load/store ops through the same pre-infer macro, estimated
  5–15 % on heavy rows (`docs/native-build.md`, item B5).
- The `_pc++`-as-value defect above, to be reduced and filed upstream.
- The two daslang asks of section 6. The JIT one
  (`notes/upstream_cases/jit_invoke_musttail.md`) would make section 7's
  dispatch unnecessary: with `musttail` on an invoke in return position the C
  form itself would tail-jump and the pass could be deleted.
