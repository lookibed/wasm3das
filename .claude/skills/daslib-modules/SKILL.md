---
name: daslib-modules
description: Conventions and catalog of daslib standard library modules (base + boost pairs, strings, json, fio, jobque, rtti, math). Invoke when picking a daslib module or reading its API.
---

# daslib modules (wasm3das)

Read `tmp/daslang/skills/daslib_modules.md` in full first. Related references
already bundled in the `daslang` skill: `.claude/skills/daslang/references/modules-and-stdlib.md`.

Look up the real API with `mcp__daslang__list_module_api` and `mcp__daslang__describe_type`
instead of reading daslib sources by hand; the pinned release bundle
(`scripts/daslang_release.env`, installed at `tmp/daslang`) is the version that matters,
not an upstream daScript checkout.
