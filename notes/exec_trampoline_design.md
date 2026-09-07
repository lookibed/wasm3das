# Executor trampoline: replacing the missing `M3_MUSTTAIL`

2026-09-06. Owner of this change: `source/m3_exec.das`, `source/m3_exec_defs.das`,
`source/m3_compile.das`, `tests/test_m3_exec.das`, `tests/test_m3_compile.das`.

## The problem

C wasm3 threads its interpreter through the code pages: every `op_*` ends with

```c
#define nextOpDirect()   M3_MUSTTAIL return nextOpImpl()
#define nextOpImpl()     ((IM3Operation)(* _pc))(_pc + 1, _sp, _mem, _r0, _fp0)
```

`M3_MUSTTAIL` turns that into a jump, so a whole wasm function body executes in a
single native frame, and the registers `_pc/_sp/_mem/_r0/_fp0` stay in machine
registers across operations.

Daslang has no tail calls. The port spelled `nextOpDirect` as an ordinary call, so
every executed wasm operation nested one more Daslang frame (plus native frames of
the interpreter). Consequences:

- `app/wasm3.das` needs `options stack = 64 MiB` and `scripts/wasm3` raises
  `ulimit -s`; the *native* stack, not the wasm stack limit checked by `op_Entry`,
  was the practical bound on wasm recursion depth;
- each operation paid two Daslang calls (`nextOpDirect` and the indirect call it
  makes) instead of one.

## The design

Two changes, one idea: **the operation no longer calls its successor; it returns to
a dispatch loop, and it hands its updated state back through its own parameters.**

### 1. The operation ABI takes its five inputs by reference

```das
typedef public IM3Operation = function<(var _pc : pc_t&; var _sp : m3stack_t&;
    var _mem : M3MemoryHeader?&; var _r0 : m3reg_t&; var _fp0 : f64&) : M3Result>
```

C passes `d_m3OpSig` by value and the callee's copies flow into the next operation
as arguments. In the trampoline the *dispatcher* owns the five values and every
operation mutates them in place, which is the exact equivalent of C's "the values
that would have been passed to the next operation". Nothing else in the 509
operation bodies changes: they already assign to `_r0`, `_fp0`, `_mem` and advance
`_pc` through `immediate_*`/`slot_*`.

This was chosen over the classic shape — "the operation writes pc/sp/mem/r0/fp0
into an interpreter state and returns a status" — after measuring the state
channels on the pinned 0.6.4 interpreter (scratch benchmark, 10M calls of a
five-argument operation returning an `M3Result`):

| what the callee does, on top of being called | added ns per call |
|---|---|
| nothing (baseline five-argument call: ~29 ns) | — |
| write five values into five scalar globals | +79 |
| write five values into one global struct | +110 |
| write five values through a cached global struct pointer | +90 |
| write five values through a state pointer passed as a sixth argument | +50 |
| **update the caller's values through reference parameters** | **+0** |

A Daslang global read or write costs 8-16 ns in the interpreter, and the dispatch
loop has to read the state back as well, so an interpreter-state trampoline would
have been *slower per operation* than the nested calls it replaces — the state has
to travel twice per operation instead of once. Reference parameters remove the
write-back entirely: the dispatcher's locals *are* the interpreter state. A
dispatch loop over an operation taking five reference parameters measured 1.22 s
per 10M iterations against 1.31 s for the same loop passing five values, so
references are not more expensive to pass either. There is consequently nothing to
choose between "a struct on the Daslang stack" and "locals in `RunLoop`": the
locals win because the operations write them in place and no struct exists.

### 2. `nextOpDirect` becomes "return to my dispatcher"

```das
let public m3Ret_nextOp : M3Result       // unique sentinel, compared by pointer

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

- `[inline]` splices the two helpers into the call site, so an operation's
  `return nextOpDirect (_pc, _sp, _mem, _r0, _fp0)` costs no call at all and the
  509 bodies keep the C spelling verbatim.
- The sentinel is compared by pointer, exactly like the loop ids described below,
  never by content; `M3Result` is a Daslang `string`, and string identity survives
  a return (the existing `op_Loop`/`op_ContinueLoop` protocol already depends on
  that).
- `nextOpImpl`, `jumpOpImpl` and `RunCode` are `RunLoop`: in C those macros mean
  "run the code at this pc to completion and give me its result", because every
  operation below them tail-jumps. That is what the loop does.

### Nesting: one Daslang frame per wasm frame, not per operation

C makes a real (non-tail) call in exactly three places, and the port keeps them:

| site | C | port |
|---|---|---|
| `op_Call`, `op_CallIndirect` | `Call (...)`, which tail-jumps into the callee | `Call` calls `nextOpImpl`, i.e. a nested `RunLoop` |
| `op_Entry` | `m3ret_t r = nextOpImpl ()` | nested `RunLoop` |
| `op_Loop` | `do { r = nextOpImpl (); } while (r == _pc)` | nested `RunLoop` per iteration |

So a wasm call still nests a bounded number of Daslang frames (`op_Call` → `Call` →
`RunLoop` → `op_Entry` → `RunLoop`), independent of how many operations the callee
executes. Before this change the depth grew with the number of *operations*
executed since the enclosing `RunCode`.

### Traps, loop ids and `op_Entry`'s stack check

The `M3Result` protocol is untouched:

- a trap is any `M3Result` other than `m3Err_none` and the new sentinel; it leaves
  the operation, `RunLoop` returns it unchanged, and the enclosing
  `op_Entry`/`op_Loop`/`Call` sees exactly what C sees. `forwardTrap`/`newTrap`
  and `d_m3RecordBacktraces == false` are unchanged;
- `op_ContinueLoop`/`op_ContinueLoopIf` still return the loop's pc reinterpreted
  into an `M3Result`, and `op_Loop` still compares it against `_pc` by pointer.
  A loop id can never collide with the sentinel (a code-page address versus a
  string constant) or with `m3Err_none`;
- `op_Entry` keeps its `_sp + maxStackSlots < _mem->maxStack` check, so
  `[trap] stack overflow` still comes from the wasm stack limit
  (`--stack-size`). With the trampoline the native/Daslang stack is no longer the
  first limit to be hit, which is what the spec suite's `assert_exhaustion` cases
  need.

## Results

All numbers from the same machine and the same working tree, wall clock around
`scripts/wasm3 wasm3c/test/lang/fib32.wasm --func fib N`:

| build | fib 30 | fib 35 |
|---|---|---|
| before, one Daslang frame per executed operation | 19.37 s | ~223 s (extrapolated, x11.5) |
| trampoline, `nextOpDirect` a plain function | 15.45 s | — |
| trampoline, `nextOpDirect` `[inline]` | 8.33 s / 8.88 s | 101.4 s |

So the dispatch restructuring is worth 1.25x on its own and 2.3x once the
`[inline]` splice removes the last per-operation call. `[inline]` on the
`immediate_*`/`slot_*`/`bool_reg` helpers was measured too (8.38 s — inside the
noise) and *not* kept: it buys nothing and the annotations would be noise in a
file whose value is its fidelity to C.

Stack, probed with `call.0.wasm`'s `runaway` (the spec suite's deepest
`assert_exhaustion`) and the default 64 KiB wasm stack: `options stack` of
6 MiB reaches `[trap] stack overflow` from `op_Entry`; 4 MiB dies as a Daslang
"fast call depth limit exceeded" first. The interpreter also consumes native
stack per Daslang frame, so the two limits have to stay in proportion: with
`options stack = 6 MiB`, `ulimit -s 16384` traps cleanly and the default 8 MiB
thread stack still crashes with SIGSEGV. `app/wasm3.das` reserves 64 MiB against
`scripts/wasm3`'s `ulimit -s 262144`, which is now roughly a 10x margin — that
margin is what allows a `--stack-size` much larger than the default, so lowering
either is a decision for their owners, not a requirement of this change.

Verification: `tests/test_m3_exec.das`, `tests/test_m3_compile.das`,
`tests/test_fib32_regression.das`, `tests/test_lang_modules.das`,
`tests/test_spec_core.das` (16 503 assertions, 0 failures), `scripts/gate.sh`
(compile, three lint profiles, 123 tests, invariants), the original
`wasm3c/test/run-spec-test.py` (17 863/17 863, 0 crashes) and
`wasm3c/test/run-wasi-test.py --fast` (7/7).

## What is *not* changed

- The compiler emits the same words: `IM3Operation` values are still stored in the
  code pages, immediates keep their layout, `op_Compile`'s self-rewrite still
  works (it rewinds `_pc` so the dispatcher re-reads the patched `op_Call` word).
- Operation names, order, comments and immediates are untouched; the deviation is
  documented once at the top of `m3_exec.das` and in the manifest row.
