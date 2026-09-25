---
name: eden-port
description: Orchestrates the autonomous port of wasm3das to the EdenSpark editor sandbox, module by module, through the eden-porter / eden-verifier / eden-reviewer agents and the scripts/eden gates, recording progress in docs/eden-port/STATE.json. Invoke for "/eden-port", "continue the Eden port", "port the next module", or as the procedure behind `/goal scripts/eden/goal_check.sh exits 0`.
---

# eden-port: the orchestration loop

You are the orchestrator of the wasm3das Eden port. The design is
`docs/eden-port/DESIGN.md`, the manual `docs/eden-port/PIPELINE.md`, the
ledger `docs/eden-port/STATE.json`. All paths below are relative to the
repository `modules/wasm3das` inside the Eden project; run scripts from
there. The goal condition is `scripts/eden/goal_check.sh` exiting 0.

Work until the goal is reached or you are blocked on something only the
user can do (the editor is not running, a tool is missing). Never stop
because "a lot was done"; the next module is always the next step.

## 0. Session start

1. `git status --short` — if the tree is dirty from an interrupted run, read
   `git diff --stat`, decide whether the partial work belongs to the module
   whose status is `porting`/`verify` and either keep it (the porter will
   continue from it) or `git stash` it with a message naming the module.
2. `scripts/eden/goal_check.sh --quick` — the ledger and git state.
3. `scripts/eden/edenmcp get_game_status` — the editor must answer. If it
   does not, tell the user exactly: "Eden editor is not running; open the
   project from the launcher, then re-run", and stop. This is the one
   blocking condition.
4. `scripts/eden/install_host.sh` then `scripts/eden/gate.sh` — the current
   state must be green before new work starts. If it is not, the module
   whose status is `verify`/`done` and whose tests fail is the one to fix:
   set it back to `porting` and go to step 2 of the loop with the gate output
   as the findings.

## 1. The loop, one module at a time

Pick the first module in `STATE.json` order whose status is not `done`
(`blocked` modules are picked again after every other module is done). Then:

1. **Mark** its status `porting` (edit STATE.json with the Edit tool; commit
   together with the port, not alone).
2. **Port**: spawn the `eden-porter` agent with the prompt
   `Port module <name> for Eden. <findings from a previous round, verbatim,
   or "first attempt">`. Wait for its report. If it reports a gate it could
   not make green, re-spawn it once with the report as findings; if still
   red, mark the module `blocked` with the reason in a `blocked` field and
   continue with the next module (the blockage is reported to the user at
   the end, with the reason).
3. **Verify**: spawn `eden-verifier` with `Verify module <name>.` If
   `BLOCKED: editor`, stop the session as in 0.3. If `FAIL`, re-spawn
   `eden-porter` with the findings verbatim and go back to 3. Allow at most
   4 port/verify rounds per module; after that mark `blocked` with the last
   findings and continue.
4. **Review**: set status `verify`; spawn `eden-reviewer` with
   `Review module <name>.` If `DEFECTS`, re-spawn `eden-porter` with the
   defect list, then `eden-verifier` again (step 3), then the reviewer again;
   at most 2 review rounds, then `blocked`.
5. **Done**: run `scripts/eden/gate.sh` yourself one last time (it is fast
   once the agents have run it), set status `done`, and commit everything of
   the module in one commit:
   `eden: port <name> (<n> tests, <k> dropped)` with a body listing the
   deviations from the porter's report. No footers, no agent metadata
   (CLAUDE.md rule).
6. Print one line of progress: `eden-port: <name> done (<done>/<total>)`
   and go to 1.

Modules `lang_modules` and `app` are ported the same way; for `app` the
porter's target files are `.local/app/wasm3_eden.das` (from
`.upstream/app/wasm3.das`, with `fio` allowed there) and the `wasm3_run`
cheat in `.eden_host/main.das`; the verifier's gate then includes
`scripts/eden/spec.sh` and `scripts/eden/wasi.sh --fast`, which take
minutes to hours: run them in the background with the Bash tool and poll.

## 2. When the design is wrong

If a porter or reviewer shows that a rule of DESIGN.md cannot be followed
(a construct the editor rejects that the design assumed, a handle model that
cannot express a C behavior), do not work around it silently: measure the
fact with a probe (PIPELINE.md §7), update DESIGN.md §1 or §4 with the
measured fact and the new rule, commit that as `eden: design - <what
changed>`, and only then re-run the porter. The design is the contract every
later module relies on.

## 3. Finish

When every module is `done`, run `scripts/eden/goal_check.sh` (the full
gate with spec and WASI). If green, write `docs/eden-port/RESULT.md` with
the numbers (tests, spec pass count, WASI list, the commit), commit it, and
report to the user with the four numbers and how to run the tests in the
editor (`wasm3_tests` cheat, `wasm3_run`). If not green, the failing stage
names the module to reopen (`spec`/`wasi` → `app` or the executor); set that
module back to `porting` with the failure as findings and continue the loop.
