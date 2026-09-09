---
name: daslang-dap-debugging
description: Stateful step debugging of .das programs through the daslang-dap MCP server (debug_launch, breakpoints, threads, configuration_done, stack/scopes/variables, stepping, disconnect). Invoke before any runtime investigation that needs breakpoints or stepping.
---

# daslang DAP debugging (wasm3das)

Read first:

- `$DASLANG_ROOT/utils/dap/README.md` (bridge contract, launch and attach workflows)
- `$DASLANG_ROOT/doc/source/reference/utils/dap.rst` (tool-by-tool reference)
- AGENTS.md sections "Runtime-debugging policy" and "DAP session contract"

The `daslang-dap` server in `.mcp.json` runs the bridge `utils/dap/mcp_bridge.py` from
the `$DASLANG_ROOT` checkout — the DAP bridge and `utils/dap` are merged upstream
(daScript PR #3937; the pin carries them) — with `$DASLANG_ROOT/bin/daslang`
as the debuggee executable. Compile, lint and test gates use the same
`$DASLANG_ROOT` (`scripts/build-daslang.sh`, README "Install and run"). The
stepping-race fix and the waiting-worker-shutdown fix are in upstream, carried
by the pin (AGENTS.md, "Agent client configuration").

Canonical launch lifecycle:

```text
debug_launch(file=..., stepping_debugger=true|false; omit port)
  -> debug_set_breakpoints (optional, once per source file)
  -> debug_threads               (mandatory startup gate)
  -> debug_configuration_done
  -> debug_wait_event(stopped|terminated)
after stopped: debug_stack_trace -> debug_scopes -> debug_variables / debug_evaluate
             -> debug_continue | debug_step_in | debug_step_over | debug_step_out
finish:      debug_terminate or debug_disconnect (idempotent; already_disconnected=true is success)
```

Rules: never pick ports by hand, never `pkill daslang` broadly, always `debug_disconnect`
before a new `debug_launch`, and record `session` fields (`return_code`, `close_reason`,
`last_dap_termination`, `process_output_tail`) when a session dies unexpectedly. Use
`$DASLANG_ROOT/utils/dap/_fixture.das` for connection smoke tests, not the wasm3 runtime.
