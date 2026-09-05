# Runtime recovery context (archived from AGENTS.md on 2026-09-05)

These sections described the state of one recovery effort (GLM and Qwen
sessions, August 2026) and were moved out of `AGENTS.md` so that the rulebook
holds only standing rules. They remain the best record of why `source/` looks
the way it does. Verify every claim against the current tree before acting on it.

## Provenance of the current `source/` tree

Before Qwen, GLM performed large mechanical C-to-Daslang merge/fix passes,
including:

- Python/regex rewrites of `m3_parse.das` and `m3_module.das`;
- an `m3log(...)` stripper that once truncated the starts of both files;
- pointer-typedef rewrites that could turn an existing pointer alias into
  effective pointer-to-pointer semantics;
- generic emulations of `m3_Free` and `m3_ReallocArray`, later replaced with
  explicit C-macro expansion;
- function moves between `m3_env` and `m3_module` that temporarily produced
  duplicate definitions.

Many of those defects were subsequently fixed. Do not assume that the current
tree is corrupt, and do not assume that it is canonical merely because it
compiles. When code looks suspicious, establish its provenance before adding
another workaround.

Useful checkpoints. They live on `origin/wip/runtime-layer`; `main` received
them squashed as `3104b5f` ("Record current runtime teardown investigation
state (#3)"):

```text
7c25b78  Fix wasm magic byte order and module deallocation found via DAP stepping
9a2058e  Phase 2: wire CompileFunctionHook/ResizeMemoryHook at m3_NewEnvironment
5fb3c38  Record phase 1 outcome and lint findings distribution
```

`7c25b78` is a useful clean comparison point, not absolute semantic truth.

## Confirmed runtime state

A real `fib32.wasm` run completed parse, load, compile, export lookup,
execution, and result retrieval with these results:

```text
fib(2)  = 1
fib(10) = 55
fib(25) = 75025
```

The runner was a temporary script and is not in the repository. The main
unresolved issue is a teardown `SIGSEGV` with the known path:

```text
m3_FreeRuntime
    -> Runtime_Release
        -> ForEachModule
            -> _FreeModule
                -> m3_FreeModule
```

Priority order at the time:

```text
real wasm correctness -> teardown correctness -> regression -> cleanup
```

The larger Daslang stack used by the temporary fib runner compensates for the
absence of a C `M3_MUSTTAIL` equivalent. Trampoline/tail-call architecture is a
separate future task and must not be mixed with teardown repair.

## Allocation fixes verified during recovery

1. `Module_AddFunction` reads `funcTypes[i_typeIndex]` as the stored pointer
   value, without `addr(slot)`. This preserves `function -> funcType ->
   numArgs/numRets` and avoids false `local index out of bounds` failures.
2. `Environment_Release` releases an `M3FuncType` allocated through
   `m3_Malloc_Impl` with `m3_Free_Impl`, not `delete`. Trace `AllocFuncType`,
   `Environment_AddFuncType`, and `Environment_Release` against C `m3_env.c`.

## Scratch that the recovery sessions left behind

Obsolete Qwen harnesses and probes, all outside Git and already absent on the
2026-09-05 machine:

```text
tools/dapdrive.py
tools/dasdap_mcp.py
tools/teardown_test.das
logs/mcp_probe*.py
logs/probe*.py
logs/run*.json
logs/dasdap_*
logs/cc*.das
logs/callcount.das
logs/free_probe.das
```

If any of these reappear, do not revive them; the DAP contract in `AGENTS.md`
is the only supported debugging path.
