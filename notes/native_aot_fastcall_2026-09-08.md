# Native build: why `-aot-strict` fails on `op_Return`, and what it costs

Date: 2026-09-08. Read-only investigation of the AOT link miss reported by
`tmp/native/bin/wasm3das -aot-strict` (`error[50101]: AOT link failed on
@m3_exec::op_Return`). Nothing in the tree was changed by it; the port-side
fix is recorded below for a later `fix/` PR. The interpreter-speed work of
the same day does not depend on it.

## The miss is exactly one function

A probe host linked against `tmp/native/obj/*.o` compiled `app/wasm3.das`
with the host's policies and, after `simulate`, compared every used
function's `Function::aotHash` with `getGlobalAotLibrary()`: 1060 registered
entries, 906 used functions, one miss: `m3_exec::op_Return`
(`source/m3_exec.das:3396`). An independent confirmation: a scratch rebuild
with the fix below passes `-aot-strict` end to end.

## Cause: `fastCall` decided per module, hashed into the AOT key

`Function::aotHash` includes `Function::flags.fastCall`. `fastCall` is a
whole-program property: a function gets it when its body reduces to one
expression and its address is taken nowhere. The AOT tool compiles each
module as its own root, where `@@op_Return` (taken in
`source/m3_compile.das` for the operation table) is invisible, so
`op_Return` is `fastCall = true` there (`aotHash 0x8801f1f080ef52a9`, the key
in `tmp/native/aot/m3_exec.das.cpp`); the runtime compiles the whole program,
sees the address taken, clears `fastCall` (`aotHash 0x9693308dff1b5bf8`) and
finds no entry. 51 functions of `m3_exec` are `fastCall` on the AOT side;
`op_Return` is the only one whose address another module takes. Rejected
after measurement: the fold of the `let` string global to `null`
(`ReturnConstString null` is identical on both sides), `if (false)` branch
elimination order, `[inline]`, every CodeOfPolicies difference between the
AOT tool and the host, file paths. Side finding: `op_Return` and `op_End`
(identical bodies) register under the same semantic hash and the registry
keeps the first; harmless here, worth mentioning upstream.

## Reproducer, kept for an upstream issue

A two-file program: a module whose `op_ok` reduces to `return <const>` and a
control `op_step` with one more statement; a root that takes `@@op_ok` and
dispatches through a table; a strict host. `-aot` the module, build, run:
`error[50101]: AOT link failed on @aot_fastcall_mod::op_ok`, the control
links. Variants confirm the mechanism: a module that takes its own addresses
links everything; `options no_fast_call = true` in the module links
everything; hiding the constant behind a local does not help (the optimizer
folds it). Verdict: a daslang defect in "AOT per module" plus the semantic
hash; a module-level decision the program consumer may override must not
be part of the key, or `aot_module = true` should treat public functions as
addressable. Files: the scratchpad of the 2026-09-08 session,
`aot-agent/upstream_case/`; to be moved under `notes/upstream_cases/` with
the issue text when filed.

## Port-side workaround (not applied yet)

After `op_Return` in `source/m3_exec.das`, a private global that takes the
address inside the module, so both compilations agree:

```das
let private c_aot_op_Return_ref : IM3Operation = @@op_Return
```

The body of `op_Return` and the C correspondence are unchanged; in the
interpreter it is an unused global. `options no_fast_call = true` is not
recommended: it is program-wide and strips `fastCall` from about 50
functions in the interpreter too.

## Build script

`scripts/build_native.sh` should run the finished binary once with
`-aot-strict` (for example `--func fib wasm3c/test/lang/fib32.wasm 5`) and
fail on `50101`; today a binary with unlinked bodies ships silently and the
one miss was found by accident.

## Cost, measured

Alternating A/B, minimum of 7 runs, start-up (about 1.82 s) subtracted:
`fib 30` 0.300 → 0.281 s, `fib 35` 3.25 → 3.04 s (about 6%; a second round
gave 3.6%), `tinyexpr_error_code` within noise. So the miss costs the native
binary a few percent on call-heavy code, nothing measurable elsewhere.
