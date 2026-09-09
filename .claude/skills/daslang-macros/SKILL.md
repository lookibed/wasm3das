---
name: daslang-macros
description: Compile-time macros and AST programming in daslang (quote/qmacro, [macro] passes, TypeDeclPtr/ExpressionPtr ownership). Invoke before writing or debugging any macro or AST-manipulating code.
---

# daslang macros (wasm3das)

Read `$DASLANG_ROOT/skills/das_macros.md` in full first; the concise reference is
`.claude/skills/daslang/references/macros.md`.

In wasm3das macros are used sparingly. Prefer a literal port of the C construct; reach for a
macro only when Daslang cannot express the C form directly, and document the C line it
replaces. The one production macro is `source/m3_exec_expand.das`, the pre-infer pass that
does at the use site what the C preprocessor does for `immediate`/`slot`/`slot_ptr`
(`notes/interp_node_cost_2026-09-08.md`); it requires `daslib/ast` only, because
`ast_boost` and `templates_boost` cost ~0.65 s of startup, and `macro_error` from a pass
does not stop compilation on 0.6.4 (`macro_sticky_error` does).
