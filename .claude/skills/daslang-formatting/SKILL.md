---
name: daslang-formatting
description: Formatting rules for .das files (gen2 layout, MCP format_file, .lint_config policy). Invoke after creating or modifying any .das file in source/ or tests/integration/.
---

# daslang formatting (wasm3das)

Read the release bundle's instructions in full before formatting:
`$DASLANG_ROOT/skills/das_formatting.md`.

wasm3das rules on top of it:

- Every `.das` starts with `options gen2` and `options indenting = 4` (AGENTS.md); a
  module may add further `options` lines after those two (the cold modules carry
  `options never_inline = true`, see `notes/interp_node_cost_2026-09-08.md`).
- Format with the MCP tool `mcp__daslang__format_file`, never with a shell-invoked
  compiler. Pass absolute paths under the repository root (`<repo>/source/<file>.das`).
- The gate's formatter check is `scripts/check_repo_invariants.sh` (dasfmt `--verify`
  over the four gated directories).
- Do not format scratch files under `tools/`, `logs/`, or `tmp/`.
