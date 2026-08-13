# wasm3das

`wasm3das` is a manual port of the [Wasm3](https://github.com/wasm3/wasm3)
WebAssembly interpreter from C to Daslang. The goal is structural fidelity: the
port keeps the original files, function and variable names, ordering, and
control flow wherever Daslang can express them safely.

This is work in progress. It does not yet execute complete WebAssembly modules.
The WASI integration layer is intentionally outside the current scope.

## Development method

- Port one bounded C layer at a time.
- Preserve behavior, including relevant edge cases and parser quirks.
- Adapt C pointers, unions, ownership, and conditional fields explicitly.
- Do not substitute a different algorithm merely because its output is similar.
- Review each increment against the reference C source in `wasm3c/`.
- Require compiler diagnostics, three lint profiles, focused tests, the complete
  test suite, and working Daslang MCP/LSP protocol tests.

The current file-by-file status and known blockers are recorded in
[`PORTING_MANIFEST.md`](PORTING_MANIFEST.md).

## Repository layout

| Path | Purpose |
|---|---|
| `source/` | Daslang port modules |
| `tests/` | Component tests for completed porting increments |
| `wasm3c/` | Vendored C reference tree |
| `.github/workflows/daslang-quality.yml` | Required pull-request quality gate |
| `PORTING_MANIFEST.md` | Port coverage and review state |

## Local verification

The project is currently verified with Daslang 0.6.4 from upstream commit
`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`.

```sh
DASLANG_ROOT=/path/to/daScript
DASLANG="$DASLANG_ROOT/bin/daslang"

for file in source/*.das tests/*.das; do
    "$DASLANG" -compile-only "$file"
done

for profile in paranoid-only perf-only style-only; do
    "$DASLANG" "$DASLANG_ROOT/utils/lint/main.das" -- \
        --"$profile" source tests
done

"$DASLANG" "$DASLANG_ROOT/dastest/dastest.das" -- --test tests
```

## Contributions

Work in feature branches and open a pull request into `main`. Direct pushes to
`main` are not part of the project workflow. A pull request is accepted only
after the required Daslang quality gate passes and the code owner approves it.

