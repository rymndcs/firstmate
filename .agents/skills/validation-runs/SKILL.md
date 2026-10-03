---
name: validation-runs
description: >-
  Agent-only procedure for a crew-owned no-mistakes validation run.
  Use before triggering a run on a worker, before steering a worker whose run is live, on any supervision wake for a worker whose run is live, and before answering or deciding a gate that run returns.
  Owns the run invocation, judging a validating worker's state, the mid-run requirement boundary, the single supported invalidation abort with its branch-custody recovery, and the exact gate decision message.
user-invocable: false
metadata:
  internal: true
---

# Crew-owned no-mistakes validation runs

This skill is the single owner of how firstmate starts, steers, and gates a no-mistakes validation run that a crewmate drives.
`AGENTS.md` section 7 keeps only the facts that fire before this skill would be loaded: that the worker which made the implementation commit drives validation and owns every run and gate-response call, that firstmate never answers that gate itself, that new requirements route to follow-up work, and the test for what counts as a new requirement.
Everything below is the procedure behind those facts.

## Starting a run and judging its state

For a no-mistakes ship, trigger validation on the same worker after its implementation commit.
That worker drives the pipeline and owns every run and gate-response call through the next gate or outcome; firstmate never answers a crew-owned run's gate itself.
An ask-user finding comes back as a `needs-decision` wake, decided under the authority contract in `AGENTS.md` section 7 or escalated to the captain.

Judge validation by the current-code-matched run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed.
A worker hand-editing, committing, aborting, or restarting during an active validation run, outside the single supported invalidation abort, duplicates pipeline ownership; steer it back to the gate response flow.

Use the harness invocation owned by `harness-adapters` to trigger validation on the worker that made the implementation commit.
That worker then owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.

## Requirements that arrive after the run starts

The routing default is follow-up work, and the exception is a requirement that completely invalidates the work being validated.
`AGENTS.md` section 7 owns that routing rule and the test for what counts as a new requirement.
When firstmate accepts a clarification or supersession after a run starts without invalidating it, send it to that worker and require the generated brief's recorded-intent reconciliation contract before validation proceeds.

## The single supported invalidation abort

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
The worker then runs this sequence, in order:

1. Cancel the active run through no-mistakes axi's supported abort command, and confirm through axi status that the run has stopped, before changing any code.
2. Follow `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
3. Replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, because custody recovery settles branch ownership and not content; this is what keeps the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
4. Validate exactly once against that final head, so no obsolete or intermediate head is ever treated as authoritative.

Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
"Starting a run and judging its state" above owns the detection cue for a worker that duplicates pipeline ownership outside this sequence.

## Gate decisions

Load `ask-user-authority` before deciding an ask-user finding, and never let the implementation worker answer its own finding.
Once the decision is settled, send that same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and the exact response command.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.
