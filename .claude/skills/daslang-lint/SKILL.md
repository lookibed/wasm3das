---
name: daslang-lint
description: Meaning and fixes for daslang lint findings (LINT*, PERF*, STYLE* rules from paranoid, perf_lint and style_lint). Invoke when the LSP or mcp__daslang__lint reports a finding, or before running the three lint profiles.
---

# daslang lint (wasm3das)

Read the rule references in full before acting on a finding:

- `tmp/daslang-toolchain/skills/perf_lint.md` (PERF rules)
- `tmp/daslang-toolchain/skills/style_lint.md` (STYLE rules)
- LINT (paranoid) rules are documented inline next to their checks in
  `tmp/daslang-toolchain/daslib/lint.das` (search for the rule id, e.g. `LINT003`).

wasm3das gate: all three profiles must report zero findings on `source`,
`tests/integration`, `app` and `tests/host_test` (`tests/manual` holds fixtures only
and is never linted):

```sh
export DAS_LINT_CONFIG_PATH="$PWD/.lint_config"
for p in paranoid-only perf-only style-only; do
  tmp/daslang-toolchain/bin/daslang tmp/daslang-toolchain/utils/lint/main.das -- --$p source tests/integration app tests/host_test
done
```

The repo policy file `.lint_config` disables LINT004, LINT012, LINT021, STYLE037 and
STYLE038 with the reason written next to each rule; do not add rules there to silence a
finding that can be fixed in code.

During editing use `mcp__daslang__lint` on the changed file; the LSP plugin pushes the same
findings as warnings after every edit. Fix the code rather than suppressing with `// nolint`
unless the C-faithful construct genuinely cannot be expressed otherwise, and say so in a
comment.
