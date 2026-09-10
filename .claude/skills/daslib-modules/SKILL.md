---
name: daslib-modules
description: Conventions and catalog of daslib standard library modules (base + boost pairs, strings, json, fio, jobque, rtti, math). Invoke when picking a daslib module or reading its API.
---

# daslib modules (wasm3das)

Read `$DASLANG_ROOT/skills/daslib_modules.md` in full first. Related references
already bundled in the `daslang` skill: `.claude/skills/daslang/references/modules-and-stdlib.md`.

Look up the real API with `mcp__daslang__list_module_api` and `mcp__daslang__describe_type`
instead of reading daslib sources by hand; the pinned daslang commit
(`scripts/daslang_pin`, built at `$DASLANG_ROOT`) is the version that matters,
not a stale upstream checkout.
