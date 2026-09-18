---
name: daslang-mcp-tools
description: Reference for the daslang MCP server tools (compile_check, lint, grep_usage, outline, find_symbol, run_test, format_file, cpp_* and live_* tools). Invoke when choosing how to search, compile, lint, or run .das code.
---

# daslang MCP tools (wasm3das)

Read the full tool table and notes first:
`/root/daScript/skills/mcp_tools.md`.

How the server is wired in this project (`.mcp.json`): the `daslang` server is the
`/root/daScript/bin/watchdog` stdio front, which spawns
`/root/daScript/bin/daslang -ignore-manifest /root/daScript/utils/mcp/main.das` with
cwd = wasm3das root on the first tool call and respawns it after a kill, a rebuild or
the `shutdown` tool; `DAS_LINT_CONFIG_PATH` points it at this repository's
`.lint_config`. The `daslang-dap` server is the same front over `utils/dap/main.das`, and
the LSP plugin (`.claude/skills/daslang-lsp`) runs `watchdog --lsp` from the same
checkout. That checkout is built with the `stddlg` module the watchdog requires and the
dasHV module the server requires.

What follows from that, verified 2026-09-18:

- Every tool resolves a relative path against the wasm3das root (`source/m3_core.das`,
  `directory: source`); absolute paths work too.
- `list_functions`, `aot`, `program_log` and `find_symbol` with `file=` see only the main
  module of the program they compile, so for a `module m3_* shared public` source pass the
  integration test that requires it (`tests/integration/test_m3_<name>.das`) as the file.
  `describe_type` cannot name a project file as its module; use `list_types` on the file.
- `cpp_grep_usage`, `cpp_outline`, `cpp_find_symbol`, `cpp_goto_definition` cover the C
  reference in `wasm3c/` only because `sgconfig.yml` in the repository root maps `*.h`,
  `*.hpp` and `*.c` to ast-grep's C++ grammar; without it every header and `.c` file is
  skipped. `cpp_compile_check` / `cpp_build_info` need a `compile_commands.json`
  (`build_dir`); this repository has none.
- `find_dupe` / `judge_duplicates` need the `anthropic/anthropic` daspkg and an API key;
  `live_*` need a daslang-live script with a GLFW window. Neither is used here.
- The MCP results are development aids. The pinned CLI gate in AGENTS.md is authoritative.
