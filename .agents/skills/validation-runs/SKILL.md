---
name: validation-runs
description: >-
  Agent-only procedure for a crew-owned no-mistakes validation run.
  Use before triggering a run on a worker, before steering a worker whose run is live, and before answering or deciding a gate that run returns.
  Owns the run invocation, the mid-run requirement boundary, the single supported invalidation abort with its branch-custody recovery, and the exact gate decision message.
user-invocable: false
metadata:
  internal: true
---

# Crew-owned no-mistakes validation runs

This skill is the single owner of how firstmate starts, steers, and gates a no-mistakes validation run that a crewmate drives.
`AGENTS.md` section 7 keeps only the facts that fire before this skill would be loaded: that a no-mistakes ship triggers validation on the same worker after its implementation commit, that the worker owns the run and firstmate never answers its gate, that new requirements route to follow-up work, the test for what counts as a new requirement, that an ask-user finding returns as a `needs-decision` wake, how a validating worker's state is judged on a supervision wake, and the cue that a worker acting on the branch during an active run is duplicating pipeline ownership.
Everything below is the procedure behind those facts.

## Starting a run

Use the harness invocation owned by `harness-adapters` to trigger validation on the worker that made the implementation commit.
That worker then owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.

## Requirements that arrive after the run starts

The routing default is follow-up work, and the exception is a requirement that completely invalidates the work being validated.
`AGENTS.md` section 7 owns the test for what counts as a new requirement.
When firstmate accepts a clarification or supersession after a run starts without invalidating it, send it to that worker and require the generated brief's recorded-intent reconciliation contract before validation proceeds.

## The single supported invalidation abort

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
The worker then runs this sequence, in order:

1. Cancel the active run through no-mistakes axi's supported abort command, and confirm through axi status that the run has stopped, before changing any code.
2. Follow `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
3. Replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, because custody recovery settles branch ownership and not content; this is what keeps the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
4. Validate exactly once against that final head, so no obsolete or intermediate head is ever treated as authoritative.

Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
`AGENTS.md` section 7 owns the detection cue for a worker that duplicates pipeline ownership outside this sequence.

## Gate decisions

Load `ask-user-authority` before deciding an ask-user finding, and never let the implementation worker answer its own finding.
Once the decision is settled, send that same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and the exact response command.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.
