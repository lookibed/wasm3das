---
name: daslang-testing
description: dastest conventions for writing and running component tests (test discovery, [test] functions, assertions, expect-files). Invoke before adding or editing anything under tests/integration/.
---

# daslang testing (wasm3das)

Read the release bundle's instructions in full first:
`$DASLANG_ROOT/skills/writing_tests.md`.

wasm3das specifics:

- Tests live in `tests/integration/test_*.das`, one file per ported C layer; the whole
  suite is run with `mcp__daslang__run_test` on `<repo>/tests/integration` (or a single
  file), and authoritatively with the pinned CLI: `scripts/gate.sh test`, which is
  `$DASLANG_ROOT/bin/daslang $DASLANG_ROOT/dastest/dastest.das -- --test tests/integration`.
- `tests/manual/` holds the manual fixture corpus and the `run_fixtures.py` benchmark
  harness. It contains no `.das` and is never compiled, linted or run by the gate.
- Tests verify behaviour against the C reference in `wasm3c/`; cite the C function and
  line being mirrored in a comment when the expected value is non-obvious.
- Runtime/lifecycle changes must also pass the `fib32.wasm` regression through result
  retrieval and teardown without a crash (AGENTS.md).
