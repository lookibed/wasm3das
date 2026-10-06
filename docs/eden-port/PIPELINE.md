# The Eden port pipeline: manual

How the autonomous port of wasm3das to the EdenSpark editor runs, how to
start it, watch it, and what it leaves behind. The design it implements is
`DESIGN.md`; the ledger is `STATE.json`.

## 1. Prerequisites (once per machine)

| Need | Where | Check |
|---|---|---|
| Eden editor running with this project open (from the launcher) | Windows | `scripts/eden/edenmcp get_game_status` answers |
| MCP bridge WSL → editor | `C:\Users\Andry\.edenspark\mcp_bridge.py`, registered as MCP server `EdenSpark` (user + local scope) | `claude mcp list` shows EdenSpark connected |
| daslang 0.6.4 build (the editor's version since EdenSpark 1.0; 0.6.3 is no longer a target) | `/root/daScript` (`DASLANG_064` overrides) | `/root/daScript/bin/daslang --version` |
| Windows Python for the bridge/CLI | `C:\Python313\python.exe` | `/mnt/c/Python313/python.exe --version` |
| python3 in WSL for the spec/WASI drivers and coverage.py | | `python3 --version` |

The repository must be checked out at `<Eden project>/modules/wasm3das`
(this project: `.../launcher/projects/01a0d5aa-.../modules/wasm3das`), on
branch `eden`. The launcher regenerates `CLAUDE.md`, `.mcp.json` and
`.claude/` of the *project root* on every open; nothing in `modules/` is
touched by it.

## 2. Start the autonomous run

From the repository, in Claude Code:

```
/goal scripts/eden/goal_check.sh exits 0 (run it from modules/wasm3das); follow the eden-port skill
```

`/goal` re-evaluates the condition after every turn and resumes on
`claude --resume`. The procedure Claude follows is the skill
`.claude/skills/eden-port/SKILL.md`; you can also drive one iteration by
hand with `/eden-port`. Nothing else is needed: the skill installs the host,
checks the editor, picks the next module, runs the agents and commits.

Non-interactive: `claude -p "/goal scripts/eden/goal_check.sh exits 0; follow the eden-port skill"`.

## 3. What happens, per module

```
STATE.json: pick first module not done
   │
   ▼
eden-porter  ── writes source/<m>.das, tests/eden/test_<m>.das, all_tests.das, fixtures.txt
   │            runs compile.sh, coverage.sh, test.sh --both until green
   ▼
eden-verifier ── install_host.sh; gate.sh (compile, coverage, test, host, eden)
   │             audits test adequacy; VERDICT PASS/FAIL (findings → porter, ≤4 rounds)
   ▼
eden-reviewer ── C-fidelity review; CLEAN/DEFECTS (defects → porter → verifier, ≤2 rounds)
   │
   ▼
orchestrator ── gate.sh once more; STATE done; one commit `eden: port <m> (...)`
```

A module that survives the rounds without going green is marked `blocked`
with the reason and is retried after every other module is done; the final
report lists it.

## 4. The gates

| Script | Proves | Runs where |
|---|---|---|
| `scripts/eden/compile.sh` | every Eden-visible file obeys the sandbox (grep rules + `-project sandbox.das_project -compile-only`) with the 0.6.4 build | WSL |
| `scripts/eden/coverage.sh` | every upstream `[test]` has an Eden counterpart or a justified drop | WSL |
| `scripts/eden/test.sh` | the Eden tests pass locally (`WASM3 TESTS pass=N fail=0`) | WSL |
| `scripts/eden/install_host.sh --check` | the project's `main.das` and `assets/wasm/*.data` match the repository | WSL → project root |
| `scripts/eden/eden_gate.sh` | the editor compiles the project, `wasm3_tests` reports `fail=0` and the same pass count as the local run | the editor, via `edenmcp` |
| `scripts/eden/spec.sh` | `run-spec-test.py` default list: pass = `STATE.spec_expected.pass`, 0 fail, 0 crash | WSL, `scripts/eden/wasm3` |
| `scripts/eden/wasi.sh --fast` | `run-wasi-test.py --fast` 7/7 | WSL |
| `scripts/eden/gate.sh` | the applicable ones above, in order | |
| `scripts/eden/goal_check.sh` | ledger complete + clean tree + gate green incl. spec/WASI | the `/goal` condition |

`scripts/eden/edenmcp <tool> [json]` is the editor client used by the gates
(`get_game_status`, `game_play`, `game_restart`, `exec_cheat`, `get_logs`,
`get_screenshot --out file.jpg`, `--list`).

## 5. Watching a run

- Progress: `scripts/eden/goal_check.sh --quick` (ledger + git), or
  `git log --oneline eden` (one commit per module).
- In the editor: the debug text in the Game tab shows the last
  `WASM3 TESTS` summary; the console shows each `FAIL`. Cheats:
  `wasm3_tests`, `wasm3_tests_verbose`, `wasm3_fixture_check <name>`, and
  from module `app` on `wasm3_run <fixture> <function> <args...>`.
- Locally: `scripts/eden/test.sh --verbose`.

## 6. Manual use (optional)

- Port one module by hand: read DESIGN.md, then `.upstream/source/<m>.das`
  next to `wasm3c/source/<m>.c`, write `source/<m>.das` and
  `tests/eden/test_<m>.das`, run `scripts/eden/gate.sh --local`, then
  `scripts/eden/install_host.sh && scripts/eden/eden_gate.sh`.
- Run just the editor gate after editing anything: `scripts/eden/eden_gate.sh`.
- Run one spec file: `scripts/eden/spec.sh .spec-opam-1.1.1/core/i32.json`.
- Edit STATE.json only through the orchestrator or by hand between runs;
  never leave it inconsistent with the tree (goal_check refuses a dirty tree).

## 7. Re-measuring the editor

When the editor updates (the launcher shows a new version, or
`get_das_version()` changes), re-run the probes before trusting DESIGN §1:

1. Temporarily add to the project's `main.das` a cheat
   `[cheat] def probe() { print("DAS_VERSION={get_das_version()}") }` plus
   one `require daslib/<module>` per module to check, `scripts/eden/edenmcp
   game_restart`, read `get_game_status` (first error only) and `get_logs`.
2. Restore `main.das` with `scripts/eden/install_host.sh`.
3. Update DESIGN §1 and `scripts/eden/sandbox.das_project` (the allowed
   lists) with what changed, in one commit.

## 8. Failure modes and what they mean

| Symptom | Meaning | Action |
|---|---|---|
| `eden_gate: editor not reachable` | editor closed, or the bridge lost the port | open the project from the launcher; `claude mcp list` |
| `get_game_status` says `internal error` | more than one Eden-visible file fails to compile | `scripts/eden/compile.sh` names them all |
| editor passes fewer checks than the local run | a fixture is not installed or a test is skipped in the editor | `scripts/eden/install_host.sh`; `wasm3_fixture_check <name>` |
| `compile.sh` green but the editor fails | a 0.6.3/0.6.4 difference the sandbox model does not know | add the construct to DESIGN §1/§6 and to compile.sh's grep rules |
| the editor reports errors at lines that do not exist in the file on disk | the editor missed a file-change notification and compiles a stale in-memory copy | create any new `.das` file in the tree (the editor rescans), delete it, restart; `eden_gate.sh` does this itself before every restart |
| a cheat prints nothing | the cheat panicked before its first `print` (the editor swallows it) | add a `print` at the top, check `get_game_status` for the error text |
| stale cheat names in `list_cheat_commands` | cosmetic, the registry keeps removed names until the editor restarts | ignore |
