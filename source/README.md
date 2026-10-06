# Eden port of wasm3das

Files in this directory are the Eden-adapted modules of the wasm3das port,
one file per original module, same names as `.upstream/source/`.

Why the split: the Eden editor compiles every non-hidden `.das` file found in
the project tree, and it runs Daslang 0.6.4 in a sandbox that forbids
`unsafe`, `daslib/ast`, `daslib/fio`, threads and network. The original port
(pointer-based, macro-expanded dispatch, typed `addr<T>`) cannot compile there,
so it lives under `.upstream/` where the editor does not look, and modules are
re-done here one by one.

Rules for files here:

- no `unsafe` in any form (no `addr`, `reinterpret`, `intptr`, `memcpy`)
- no `require daslib/ast`, `daslib/fio`, `daslib/jobque_boost`, `daslib/network`
- linear memory, operand stack, globals and tables are arrays indexed by
  offsets, never pointers
- `options stack`, `options rtti`, `daslib/rtti`, `strings_boost`, `json`,
  `math_boost`, `functional`, `algorithm`, `static_let`, `contracts` are fine
