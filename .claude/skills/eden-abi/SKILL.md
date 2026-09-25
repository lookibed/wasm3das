---
name: eden-abi
description: Orchestrates work on the Eden guest ABI (docs/eden-abi) case by case - binjgb, PureDOOM, Unity - through the abi-porter / abi-verifier / abi-reviewer agents and scripts/abi/gate.sh, recording progress in docs/eden-abi/STATE.json. Invoke for "/eden-abi <case>", "continue the ABI work", "port PureDOOM to the ABI", or as the procedure behind `/goal scripts/abi/goal_check.sh <case> exits 0`.
---

# eden-abi: the orchestration loop

The spec is `docs/eden-abi/ABI.md`, the plan `PLAN.md`, the manual
`PIPELINE.md`, the ledger `STATE.json`. Paths are relative to the
repository `modules/wasm3das`. The goal of a case is
`scripts/abi/goal_check.sh <case>` exiting 0.

Work until the goal is reached or you are blocked on something only the
owner can do (the editor is not running, a decision PLAN.md section 6 lists
as the owner's, a toolchain is missing). Never stop because much was done.

## 0. Session start

1. `git status --short`; a dirty tree from an interrupted run belongs to
   the item marked `working`/`verify`: keep it or stash it with its name.
2. `scripts/abi/goal_check.sh <case> --quick`.
3. `scripts/eden/edenmcp get_game_status` must answer; else tell the owner
   "Eden editor is not running; open the project from the launcher, then
   re-run" and stop.
4. `scripts/eden/install_host.sh` and `scripts/abi/gate.sh`: the current
   state must be green before new work. If not, the failing stage names the
   item to reopen.

## 1. The loop, one item at a time

Take the first item of the case whose status is neither `done` nor
deferred.

1. Mark it `working` (Edit STATE.json; committed with the work).
2. Spawn `abi-porter` (general-purpose agent, model opus, with the charter
   `.claude/agents/abi-porter.md` as its instructions) with: the case, the
   item, and the findings of the previous round verbatim or "first
   attempt".
3. Spawn `abi-verifier` the same way. `BLOCKED: editor`: stop as in 0.3.
   `FAIL`: back to 2 with the findings; at most 4 rounds, then mark the
   item `blocked` with the last findings and continue with the next item.
4. Mark `verify`; spawn `abi-reviewer`. `DEFECTS`: back to 2 (then 3, 4);
   at most 2 review rounds, then `blocked`.
5. Run `scripts/abi/gate.sh` yourself, mark the item `done` with an
   `evidence` line (what proves it), and commit the item in one commit
   `abi: <case>: <item>` (repository rules: no amend, no attribution
   footers, see CLAUDE.md).

A decision the plan leaves to the owner (PLAN.md section 6) is not taken by
an agent: mark the item `blocked` with the question, continue with items
that do not depend on it, and ask the owner at the end.

## 2. End of session

Report per item: done (evidence), blocked (why, what is needed), and the
gate's last lines. Update PLAN.md when a measurement changed a decision.
