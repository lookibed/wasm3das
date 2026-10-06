# Exported builds of the Eden project: how they are made and how fast they run

Measured 2026-10-06 on EdenSpark 1.0.0.19.

## 1. What Export does

The hub (the `EdenSpark` window: `eden.exe` without a project) has the
Export button on a game's page. The editor's MCP server does not reach the
hub. A process watcher caught what the button runs:

```
eden.exe <project>/main.das --out-build-file <project>/.project/project.eden
         --base-path <project> --base-path <eden>/win64/../
         -config:video/driver:t=stub -config:video/threadedWindow:b=no
```

That step compiles every script under the **publish rules** and packs the
project into `project.eden` (19 MB here). The hub then writes
`<launcher>/standalone_builds/<project id>/<game>.zip` (not
`.project/standalone_<version>` as the docs say) holding:

- `.project/project.eden`;
- the installation's `win64/eden.exe` (the same binary as the editor),
  `Remarks.dll`, `crashpad_*`, `D3D12/*`, `LICENSE-eden`;
- the five `*.vromfs.bin`, `compiledShaders/*`,
  `content/sandbox/sandbox.vromfs.bin`, `eden.config.blk`,
  `default_resolution.blk`;
- `run.bat` = `@start win64/eden.exe .project/project.eden`.

## 2. Doing it from a script or MCP

On the Windows side, next to the MCP bridge (`C:\Users\Andry\.edenspark\`):

| Tool | What |
|---|---|
| `eden_build.py <project> [--export] [--name n] [--autobench]` | the package step, then (with `--export`) the same folder and zip as the hub |
| `eden_desktop.py windows / shot / click / close / procs` | the hub and the editor driven by screenshots and the mouse |
| MCP tools of the bridge | `eden_build`, `desktop_run_build`, `desktop_stop_process`, `desktop_windows`, `desktop_screenshot`, `desktop_click`, `desktop_processes`, next to the editor's own tools (after `/mcp` reconnect) |

The scripted export reproduces the hub's output. It was compared with the
zip of a hub export, file list and contents, and the build runs.

## 3. Publish rules the editor does not show

- **A deprecated call fails the build.** In the editor it is only a
  warning. `engine.input.global_input_state` as a whole is deprecated: its
  `update` "will prevent publishing the game". The Eden ABI host
  (`eden/abi_eden_host.das`) therefore reads keys, mouse buttons, mouse
  movement and the wheel through action sets (`eden_abi_keys`,
  `eden_abi_mouse`, `eden_abi_pad`).
- **No way to tell a build from the editor in script.**
  `is_standalone_exe()` is about `daslang -exe` and is false in both.
  `get_command_line_arguments()` panics in the game context ("can't delete
  locked array" inside `builtin.das`). The host uses an asset flag
  instead: `assets/wasm/autobench.data` is `0` in the project and `1` only
  in builds made with `eden_build.py --autobench`.

## 4. Does a build run faster? No

The engine settings of a build (its log) say `daScript: init INTERPRET
mode`, `aot lib size=0` and `llvm_jit_enabled:b=no`. Overriding with
`-config:llvm_jit_enabled:b=yes` is refused: "not allowed for overwrite".
`eden.exe` has no LLVM in it. `eden-aot-windows-x86_64.exe` is
`daslang -aot` (das to C++); using its output needs a C++ toolchain and a
rebuilt engine, and Export does not use it.

The same work, timed by the host's autobench (cheat `abi_autobench` in the
editor, by itself on the 30th frame in an `--autobench` build):

| Benchmark | Editor ms | Build ms | Result (both) |
|---|---:|---:|---|
| daslang loop (8 x 1M array mix + 2M sqrt) | 165 | 171 | `0x73ae83aa` |
| wasm3das `fib(24)` (lang/fib32.wasm) | 196 | 198 | 46368 |
| binjgb, 4 frames through the ABI (instantiate included) | 9605 | 10507 | 838717591 |

Builds run the same interpreter at the same speed, within noise. The
"AOT to C++" of the EdenSpark 1.0 announcement is not part of the Export
path.

Engine limits printed in the same log: `game_das_max_heap_allocated`,
`game_das_max_string_heap_allocated` and `game_das_max_static_variables_size`
are each 104857600 (100 MiB). `game_das_very_safe_context` and
`game_das_force_inscope_pod` are on: the heap is collected between frames
and POD locals are scoped. `game_das_enable_serialization` is on: compiled
programs are cached ("das: serialize").
