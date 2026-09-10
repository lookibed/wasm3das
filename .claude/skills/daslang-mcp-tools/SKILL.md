---
name: daslang-mcp-tools
description: Reference for the daslang MCP server tools (compile_check, lint, grep_usage, outline, find_symbol, run_test, format_file, cpp_* and live_* tools). Invoke when choosing how to search, compile, lint, or run .das code.
---

# daslang MCP tools (wasm3das)

Read the full tool table and notes first:
`$DASLANG_ROOT/skills/mcp_tools.md`.

How the server is wired in this project (`.mcp.json`): the `daslang` server is
`$DASLANG_ROOT/utils/mcp/mcp_supervisor.py` with `--repo-root .`, so the daslang child
runs with cwd = wasm3das root and the pinned binary `$DASLANG_ROOT/bin/daslang`
(`DASLANG_MCP_BIN`; the supervisor takes no `--bin` option). `DASLANG_ROOT` is the
daslang checkout at the commit of `scripts/daslang_pin`, built by
`scripts/build-daslang.sh` (README "Install and run"); the server needs the dasHV
module of that build, which is why the build set keeps dasHV enabled.

Path conventions that follow from that:

- `compile_check`, `lint`, `run_test`, `run_script`, `format_file`, `find_symbol`,
  `goto_definition`, `find_references`, `type_of`: project-relative paths work
  (`source/m3_core.das`), absolute paths work too.
- `grep_usage` and `outline` resolve relative paths against the toolchain root, so always
  pass absolute paths under the repository root: `directory: <repo>/source`,
  `file: <repo>/source/m3_env.das`.
- `cpp_grep_usage`, `cpp_outline`, `cpp_find_symbol` are for the C reference in
  `wasm3c/source`; pass absolute paths as well.
- The MCP results are development aids. The pinned CLI gate in AGENTS.md is authoritative.
