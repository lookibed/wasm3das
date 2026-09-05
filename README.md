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
[`PORTING_MANIFEST.md`](PORTING_MANIFEST.md). The stages every pull request
passes, from intake to post-merge, are described in
[`docs/development-pipeline.md`](docs/development-pipeline.md).

## Repository layout

| Path | Purpose |
|---|---|
| `source/` | Daslang port modules |
| `tests/` | Component tests for completed porting increments |
| `wasm3c/` | Vendored C reference tree |
| `.github/workflows/daslang-quality.yml` | Required pull-request quality gate |
| `scripts/gate.sh` | The gate itself: compile, three lint profiles, tests, repository invariants; shared by CI and the hook |
| `scripts/check_repo_invariants.sh` | Formatter verify, test discovery, manifest consistency, file headers |
| `.githooks/pre-push` | Runs `scripts/gate.sh` locally before every push |
| `.lint_config` | Repo lint policy consumed by the gate |
| `docs/` | Design decisions (memory ownership) |
| `notes/` | Dated working notes and session handoffs |
| `AGENTS.md` | Rules for AI coding agents |
| `PORTING_MANIFEST.md` | Port coverage and review state |

## Local verification

The project is currently verified with Daslang 0.6.4 from upstream commit
`1524b3bf62e7decbfe530dc5f2e794b296fa1e68`.

```sh
DASLANG_ROOT=/path/to/daScript DASLANG="$DASLANG_ROOT/bin/daslang" scripts/gate.sh
```

With the toolchain at `tmp/daslang-toolchain` (the default), plain
`scripts/gate.sh` is enough. The script runs, in order: `-compile-only` on
every file under `source/` and `tests/`, the three lint profiles with the repo
policy in `.lint_config`, the dastest suite, and the repository invariants
(formatter verify, every test file has `[test]`, every source file has a
manifest row, every file starts with the two `options` lines). A single stage
can be run by name: `scripts/gate.sh lint-style`.

CI runs the same script. A pull request that changes none of the gate's inputs
(`source/`, `tests/`, `scripts/`, `.githooks/`, the workflow, `.lint_config`,
`PORTING_MANIFEST.md`) reports a green status within seconds without building
the toolchain.

The same gate runs locally before every push once the repository hooks are
enabled:

```sh
git config core.hooksPath .githooks
```

## Contributions

Work in feature branches and open a pull request into `main`. Direct pushes to
`main` are not part of the project workflow. A pull request is accepted only
after the required Daslang quality gate passes and the code owner approves it.

Pull requests are merged with **squash and merge**: `main` receives one commit
per pull request, and the individual commits stay visible in the pull request
itself. GitHub deletes the head branch automatically after the merge. Because
squashed commits never appear in `main`, delete the local branch with
`git branch -D <branch>` after `git pull`; `git branch --merged` will not list
it.

