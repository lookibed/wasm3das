---
name: daslang-dap-debugging
description: Stateful step debugging of .das programs through the daslang-dap MCP server (debug_launch, breakpoints, threads, configuration_done, stack/scopes/variables, stepping, disconnect). Invoke before any runtime investigation that needs breakpoints or stepping.
---

# daslang DAP debugging (wasm3das)

Read first:

- `/root/daScript/utils/dap/README.md` (bridge contract, launch and attach workflows)
- `/root/daScript/doc/source/reference/utils/dap.rst` (tool-by-tool reference)
- AGENTS.md sections "Runtime-debugging policy" and "DAP session contract"

The `daslang-dap` server in `.mcp.json` is the `bin/watchdog` stdio front of the
`/root/daScript` checkout over `utils/dap/main.das`, with that checkout's `bin/daslang`
as the debuggee executable (the same daslang the MCP compiler and the LSP use). The
bridge spawns the debuggee with `--das-wait-debugger`, picks a free local port and
connects; `optimize=false` keeps every source statement so breakpoints stop where the
source says.

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
`last_dap_termination`, `process_output_tail`) when a session dies unexpectedly. A
breakpoint reported `verified: false` before `configurationDone` is normal in
instrumentation mode; the `breakpoint changed` event verifies it. A `continue` inside a
loop re-hits the same breakpoint; wait for `terminated` only after the last hit. The
debuggee prints `[daslang atexit] FATAL: g_envTotal=1` on exit; that is upstream noise, not
a crash. Use `/root/daScript/utils/dap/_fixture.das` for connection smoke tests, not the
wasm3 runtime.
