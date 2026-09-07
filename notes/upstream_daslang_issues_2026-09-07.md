# daslang bugs found by wasm3das, prepared for upstream

Date: 2026-09-07. Every item below was reduced to a standalone program with no
dependency on the port, then re-run independently of the agent that found it,
on the official release bundle `v0.6.4-RC2` of `GaijinEntertainment/daScript`
(`bin/daslang --version` → `0.6.4`, Linux x86_64, Debian 6.12.107). The
reproducer files live in `notes/upstream_repros/`. Nothing in the daslang
tree was patched; where a fix was verified, it was applied to a scratch copy
of `modules/dasLLVM/daslib` loaded with `-load_module`.

Status per item: **ready** = minimal reproducer, cause located to a line,
fix verified where one exists; **localized** = not minimal, do not file as is.

| # | Component | Title | Status |
|---|---|---|---|
| 1 | `utils/aot -ctx` | standalone context fails for a used, initialized global of a required module; generated contexts do not link | ready; fixed on master by `8f4d87cac02c` (PR #3838), not in RC2 |
| 2 | LLVM JIT | SIGSEGV in codegen on a module-qualified `math::` float intrinsic | ready; fix in `notes/daslang_jit_fixes_2026-09-07.patch`, verified |
| 3 | LLVM JIT | `reinterpret<uint64>(@@fn)` emits an invalid aggregate bitcast | ready; fix in the same patch, verified |
| 4 | interpreter | `reinterpret<uint64>(@@fn)` written inline evaluates to 0 | ready, no fix proposed |
| 5 | LLVM JIT | wrong results at `--jit-opt-level >= 1`, localized to one port function | localized only |

What did **not** reproduce, so it must not be claimed: a qualified `math::sqrt`
with a constant argument (folded before codegen); `reinterpret<uint64>` of a
function value held in a local or typed variable (lowers to a `ptr` global,
works in all tiers); a function value round-tripped through a runtime-indexed
table and a heap slot (correct in interpreter, stock JIT and patched JIT);
`math::min`/`math::max` with qualified names (correct on RC2).

---

## 1. `-ctx`: standalone context generation and linking

**Title:** `-ctx` (standalone context) fails for any used, initialized global
of a required module (`invoke null method function ... visitGlobalLetVariableInit`),
and the emitted `InitGlobalVar` call does not link

**Version:** release bundle `v0.6.4-RC2` (tag object `1d7355bc8d2f`,
2026-08-19), `bin/daslang --version` → `0.6.4`, Linux x86_64. Identical on a
self-built checkout of `1524b3bf` (2026-08-10); only the reported line
differs (243 instead of 227).

**Minimal reproduction** (`notes/upstream_repros/ctx_required_global/`):

`modb14.das`
```
options gen2
options indenting = 4

module modb14

var public g_counter = 0
```

`b14.das`
```
options gen2
options indenting = 4

require modb14

[export]
def main {
    g_counter += 1
    print("{g_counter}\n")
}
```

```
$ $SDK/bin/daslang b14.das                                          # prints 1
$ $SDK/bin/daslang $SDK/utils/aot/main.das -- -aot b14.das b14.aot.cpp   # exit 0
$ $SDK/bin/daslang $SDK/utils/aot/main.das -- -ctx b14.das out           # FAILS
daslib/aot_standalone.das:227:33: error[31206]: macro caused exception during visitGlobalLetBody -- invoke null method function, type<aot_standalone::StandaloneContextGen>.visitGlobalLetVariableInit
EXCEPTION: AOT codegen failed: 1 codegen error(s) during emission (see log)
 at daslib/aot_cpp.das:4410:4
```
Expected: `out/b14.das.h` and `out/b14.das.cpp`, exit 0. Actual: exit 1, no
files.

**Exact condition** (19-case matrix, every failing case has a passing
neighbour that differs in one dimension): the global must belong to a
*required* module, be *used*, and have *any* initializer. `var public g = 0`
fails exactly like an array-of-struct literal; `let`/`var`, `public`/`private`
and the shape of the initializer do not matter. Same-file globals pass (the
`pvar._module == prog.getThisModule` guard skips them); unused globals pass
(`!pvar.flags.used`); `var public g_counter : int` without initializer passes
(`variable.init == null`). `let public g_len = 5` passes only because the
constant is folded at every use and the variable arrives unused: the
generated `.cpp` contains no reference to it. Plain `-aot` succeeds on every
failing program, so this is specific to the standalone-context path.

**Cause (RC2 sources):** `daslib/ast.das:322` declares
`def abstract visitGlobalLetVariableInit(...)`. `class public CppAot`
(`daslib/aot_cpp.das:1349`) overrides `visitGlobalLet` (1525),
`preVisitGlobalLetVariable` (1530), `visitGlobalLetVariable` (1546) and
`preVisitGlobalLetVariableInit` (1555) but not `visitGlobalLetVariableInit`;
the only two mentions of that name in all of `daslib/` are the abstract
declaration and the call. `StandaloneContextGen : CppAot`
(`daslib/aot_standalone.das:197`) calls it on itself:
```
aot_standalone.das:212  def override visitGlobalLet(prog : ProgramPtr) {
                  :216      if (pvar.index < 0 || !pvar.flags.used || pvar._module == prog.getThisModule) return ;
                  :225      preVisitGlobalLetVariableInit(variable, variable.init);
                  :226      visit_expression(variable.init, adapter);
                  :227      variable.init := visitGlobalLetVariableInit(variable, variable.init);   // null slot
```

**Second blocker, the link step.** For a program that does generate, the
emitted constructor calls `InitGlobalVar(context, &context.globalVariables[i],
GlobalVarInfo(...))` (`aot_standalone.das:111-112`).
`include/daScript/simulate/standalone_ctx_utils.h:65` declares it by value:
```
DAS_API void InitGlobalVar(Context &ctx, GlobalVariable* gvar, GlobalVarInfo info);
```
but the shipped library defines only the `const &` form:
```
$ nm -C --defined-only lib/liblibDaScript_runtime.a | grep InitGlobalVar
0000000000000170 T das::InitGlobalVar(das::Context&, das::GlobalVariable*, das::GlobalVarInfo const&)
```
(`liblibDaScript.a` defines neither; the `.so` exports only
`InitGlobalVariable`.) Compiling a successfully generated context (same-file
`var g_counter = 0`) with a minimal host and linking it against
`liblibDaScript.a liblibDaScript_runtime.a liblibDaScript.a liblibUriParser.a
-lpthread -ldl -lm`:
```
a2.das.cpp:(.text+0x615): undefined reference to `das::InitGlobalVar(das::Context&, das::GlobalVariable*, das::GlobalVarInfo)'
```
That is the only undefined reference. A one-function shim defining the
by-value overload and forwarding to the exported symbol makes the link
succeed and the standalone binary print the correct `1`, so the header
declaration is the entire second blocker. The pinned `1524b3bf` checkout shows
the same split: its `src/simulate/standalone_ctx_utils.cpp:38` defines the
`const &` form, so the by-value symbol never existed.

**Fixed on master:** commit `8f4d87cac02c` (PR #3838, merged as
`3a56253acd81`, 2026-08-24) drops the `visitGlobalLetVariableInit` call
(turning `visitGlobalLet` into `preVisitGlobalLet`) and changes the header
to `const GlobalVarInfo &`. `GET /compare/v0.6.4-RC2...8f4d87cac02c` reports
`status: ahead, behind_by: 0`, so the release predates it. Later
standalone-context work (`180d6740948d` PR #3808, `531f01e9883c` PR #3843,
`b7ddddd502ee` PR #3947, `25cd2cd6325e` PR #3950, `dd63155a3e19`,
`b5aa85d13f32`) exists and touches `aot_standalone.das`; whether any of it is
required for this failure was not checked line by line. No open upstream
issue mentions `visitGlobalLetVariableInit` or `InitGlobalVar`.

**Request:** a release that includes at least `8f4d87cac02c`; as shipped,
`-ctx` is unusable for any program whose required module owns an initialized,
used global, and the contexts that do generate cannot be linked.

---

## 2. LLVM JIT: SIGSEGV in codegen on a module-qualified float intrinsic

**Title:** LLVM JIT: SIGSEGV during codegen on a module-qualified `math::`
float intrinsic call (`math::sqrt`, `math::floor`, `math::sin`, ...)

**Reproduction** (`notes/upstream_repros/jit_qualified_sqrt.das`):
```
options gen2
options indenting = 4
require math

var g_x = 9.0

[export]
def main() {
    print("qualified sqrt = {math::sqrt(g_x)}\n")
}
```
The global `var` matters: with a local constant the call is folded and never
reaches the backend.
```
$ bin/daslang jit_qualified_sqrt.das
qualified sqrt = 3                       # exit 0
$ bin/daslang jit_qualified_sqrt.das -jit -jit-no-cache
CRASH: SIGSEGV (Segmentation fault) (signal 11) at address 0x7fc9047bc97e
Stack trace:
  [ 0] [0x1]                             # exit 139
```
Also crashes with `-dry-run` (codegen, not run time). The same file with an
unqualified `sqrt(g_x)` prints `3` under `-jit`. Confirmed identically for
`math::floor`, `math::sin`, `math::floori`, `math::tanh`.

**Cause** (`modules/dasLLVM/daslib/llvm_jit_intrin.das`): the dispatch key
is built from the declaration (`:251`, `:312`,
`"{expr.func._module.name}::{expr.func.name}"`), so both spellings reach the
same handler, but `intrinsic_math_float_op1` (`:1055-1057`),
`intrinsic_math_float_op1_to_int` (`:1059-1066`) and
`intrinsic_math_sinh_cosh_tanh` (`:1158-1160`) pass the call-site spelling
`string(expr.name)` into `intrinsic_math_any_float_op1` (`:1032`), which
builds `"llvm.{expr_name}.f32"` (`:1033`; `.f64` at `:1037`). That yields
`llvm.math::sqrt.f32`; `LLVMLookupIntrinsicID` (`:1045`) returns 0 and
`LLVMGetIntrinsicDeclaration(g_mod, 0, ...)` (`:1046`) dereferences it.
Affected names: `log`, `exp2`, `log2`, `sqrt`, `sin`, `cos`, `round`,
`floor`, `ceil`, `floori`, `ceili`, `sinh`, `cosh`, `tanh`.

**Fix** (second hunk of `notes/daslang_jit_fixes_2026-09-07.patch`; verified
on a scratch copy of the JIT daslib: all probes pass under `-jit`, and the
906-function wasm3das program that used to crash compiles): strip the module
qualifier before building the intrinsic name, and refuse intrinsic id 0 with
a diagnostic. The id-0 guard is worth keeping on its own: every other
`LLVMLookupIntrinsicID` call site in that file is one bad name away from the
same hard crash.

---

## 3. LLVM JIT: `reinterpret<uint64>(@@fn)` emits an invalid bitcast

**Title:** LLVM JIT: `reinterpret<uint64>(@@fn)` written directly on the
address-of expression emits `bitcast { ptr } to i64` and aborts codegen

**Reproduction** (`notes/upstream_repros/jit_reinterpret_fn_direct.das`):
```
options gen2
options indenting = 4

def op_a(var a : int&; var b : int&) : string {
    a += b
    return "a"
}

[export]
def main() {
    var b2 : uint64
    unsafe { b2 = reinterpret<uint64>(@@op_a) }
    print("via @@ direct nonzero={b2 != 0ul}\n")
}
```
```
$ bin/daslang jit_reinterpret_fn_direct.das
via @@ direct nonzero=false              # exit 0; see item 4
$ bin/daslang jit_reinterpret_fn_direct.das -jit -jit-no-cache
Invalid bitcast
  %cast_r = bitcast { ptr } %2 to i64
failed to simulate
error[31206]: macro caused exception during simulate
  .../llvm_jit_run.das:427:12  Internal jit error. Failed to get IR of 'main implementation'.
error[50503]: simulate macro llvm_macro::jit_llvm failed to simulate   # exit 1
```
Also fails with `-dry-run`. The same cast through a variable
(`let f = @@op_a; reinterpret<uint64>(f)`) compiles and runs, because that
form lowers `@@op_a` to a module-level `ptr` global; the inline `@@op_a`
stays the `{ ptr }` aggregate.

**Cause** (`modules/dasLLVM/daslib/llvm_jit.das`, `visitExprCast` `:5557`):
`Type.tFunction` is neither `isPointer` nor `isRefType`, so the chain at
`:5564-5571` misses it and control falls into the equal-size branch at
`:5572-5574`, which emits `LLVMBuildBitCast` from the aggregate to `i64`;
the module verifier rejects it.

**Fix** (first hunk of the same patch; verified): extract element 0 of the
aggregate and `LLVMBuildPtrToInt` it. Afterwards both spellings produce the
same non-zero address.

---

## 4. Interpreter: `reinterpret<uint64>(@@fn)` written inline evaluates to 0

**Title:** Interpreter: `reinterpret<uint64>(@@fn)` written inline evaluates
to 0, while the same cast through a local yields the function address

**Reproduction** (`notes/upstream_repros/interp_reinterpret_fn_direct_vs_var.das`):
```
options gen2
options indenting = 4

def op_a(var a : int&; var b : int&) : string {
    a += b
    return "a"
}

[export]
def main() {
    let f = @@op_a
    var via_var : uint64
    var direct : uint64
    unsafe { via_var = reinterpret<uint64>(f) }
    unsafe { direct = reinterpret<uint64>(@@op_a) }
    print("via_var = {via_var}\n")
    print("direct  = {direct}\n")
}
```
```
$ bin/daslang interp_reinterpret_fn_direct_vs_var.das
via_var = 0x55c5eb5ff500
direct  = 0x0                            # exit 0, no diagnostic
```
Expected: the same address twice.

**Evidence that 0 is wrong rather than specified:** `daslang -aot` lowers
both spellings identically (`das_cast<uint64_t>::cast(__f_rename_at_14_2)`
and `das_cast<uint64_t>::cast(Func(__context__->fnByMangledName(...)))`;
the generated C++ was inspected, not compiled and run); the JIT with the fix
of item 3 prints the same non-zero address for both; and wrapping the direct
form in a second cast, `reinterpret<void?>(reinterpret<uint64>(@@op_a))`,
makes the interpreter yield the correct address, which points at a
constant-folding path on `ExprCast(ExprAddr)` rather than at the cast itself.
wasm3das relies on the nested form (`source/m3_exec.das:3058`); the
single-cast form would silently store a null into a code page.

---

## 5. LLVM JIT: wrong results at `--jit-opt-level >= 1` (localized, not minimal)

With the fixes of items 2 and 3 applied to a scratch JIT daslib, wasm3das
compiles under `-jit` (906 functions) but computes wrong values:

| fixture | interpreted | `-jit` (O3) |
|---|---|---|
| `--func tinyexpr_error_code tests/manual/real-world-tinyexpr/generated/tinyexpr.wasm` | `Result: 6` | `Result: 1` |
| `--func miniz_probe_crc32 tests/manual/real-world-miniz/generated/miniz.wasm` | `Result: 2035028898` | `Result: -101385738` |

`fib32.wasm --func fib 20` is correct in both. Localization:

- `--jit-opt-level=0` gives the correct results; levels 1, 2 and 3 give the
  wrong ones, so the IR is fine and an LLVM optimization pass changes it.
- Forcing single functions to stay interpreted (a scratch-only instrument in
  a copy of `llvm_jit_run.das`): leaving exactly one function,
  `m3_env::EvaluateExpression` (`source/m3_env.das:330-389`), out of the JIT
  restores both results while the other 905 functions stay compiled;
  excluding any other single module or any of the other 58 functions of
  `m3_env` does not help.
- Shape of that function: a stack-local `M3Runtime` struct whose address is
  published into `i_module.runtime`, an interior pointer
  `addr(runtime.compilation)` handed to a callee that mutates it, a call
  through a code page, and the result copied out through `reinterpret<u32?>`
  / `reinterpret<u64?>` of a `void?` out-parameter. C does the same with a
  stack-local `M3Runtime` in `wasm3c/source/m3_env.c` `EvaluateExpression`.
- A standalone probe with a stack-local struct whose address escapes into a
  global and is written by a callee did not reproduce (correct at O0 and O3).

Unverified hypothesis: the JIT may attach `noalias`-style assumptions to
reference or pointer parameters that this function violates (the same memory
is reachable through `runtime`, `i_module.runtime` and the interior pointer),
in which case this is a port-versus-JIT contract question rather than a pure
optimizer bug. Not to be filed until reduced to a standalone program.
