---
name: daslang-leak-detection
description: Diagnosing daslang memory leaks and teardown crashes (--das-profiler-leaks, --track-smart-ptr, GC APP LEAK, HandleRegistry, jobque leaks). Invoke when a runtime test crashes on free/delete or the leak dump is non-empty.
---

# daslang leak detection (wasm3das)

Read `tmp/daslang/skills/memory_leak_detection.md` in full first, then
`tmp/daslang/skills/jobque_debugging.md` if channels or job status are involved.

wasm3das context: every `M3*` object is a host allocation (`m3_Malloc_Impl` /
`m3_Free_Impl`), never `new`/`delete` (AGENTS.md, "Allocation and pointer semantics",
`docs/memory-ownership.md`). A `free(): invalid pointer` or SIGSEGV in teardown almost
always means an object was released through the wrong allocator, or a Daslang `delete`
walked the pointer fields of a host-allocated struct. See
`notes/dap_tooling_update_2026-09-04.md` for the recorded teardown investigation and use
the `daslang-dap-debugging` skill to step through it.
