---
name: task-lifecycle
description: >-
  Agent-only procedure for the ship and scout task lifecycle behind the always-loaded authority contract in AGENTS.md section 7.
  Use at intake of every new work request, before writing a brief or spawning a worker, before steering a worker, when a worker reports a PR ready or finished, before cleaning up a landed task, when a scout finishes or is promoted, and before writing or replacing a backlog item note.
  Owns project resolution, secondmate routing, ship-versus-scout classification, surface classification for no-mistakes-prod-only projects, check scope, overlap and serialization judgment, brief authoring, dispatch handoff and steering, the PR-ready signal, cleanup follow-through, scout relay and promotion, and backlog note hygiene.
user-invocable: false
metadata:
  internal: true
---

# task-lifecycle

This skill owns the lifecycle procedure for ship and scout work.
`AGENTS.md` section 7 keeps the always-loaded authority contract: delivery-mode and yolo resolution, approval and merge authority, validation ownership, and the cleanup boundary under hard rule 3.
Referenced scripts own exact commands, flags, and data mechanics.

## Intake

Resolve the project independently for every request.
An explicit project wins, a clear follow-up inherits its referent, and otherwise match the request against the registry, work under way, and project code or README.
Proceed on one confident match while naming the project in plain language; ask one concise question when multiple or no projects plausibly match.

Route by the nature of the work against each registered secondmate scope, not by a non-exclusive clone list.
Send in-scope work to the fitting secondmate unless it is blocked or the captain explicitly redirects it; do not read the secondmate's chat because marked routed replies return through its status or referenced document.
If no secondmate scope fits, use the main home or discuss creating an appropriate persistent secondmate.
For one-off or infrequent operational work, start with the simplest direct end-to-end path.
Do not build wrappers, control planes, policy layers, custom verifiers, or automation unless the direct path exposes a concrete blocker or repeated need that justifies the added machinery.

Before commissioning an investigation, consult existing reports and established evidence.
Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.

On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
Record the resulting mode, yolo, and the one-line reason for any deviation in the backlog item note.
Judge the task's check scope at the same moment and pass it as `bin/fm-brief.sh --checks <full|targeted>`, which refuses a ship brief without it and generates the whole check contract from it: `full` when the change can break things beyond the files it touches, `targeted` when a whole-suite run is disproportionate to it.

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately, up to the live worker limit `bin/fm-spawn.sh` applies, when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Write the task-specific brief under "Briefs" below before spawning.

## Briefs

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then replace every `{TASK}` placeholder with a clear task description, acceptance criteria, constraints, and necessary context before dispatch or seeding.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.

If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.

Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-classify-lib.sh` owns keyed open and resolved semantics.

## Dispatch and steering

After spawning, confirm the worker is processing the brief, handle any trust dialog, and record ship or scout work as under way.
A persistent secondmate is recorded in the secondmate registry and runtime state, never as a backlog work item.

Steer a worker with short single-line messages through fail-closed `fm-send`; put long instructions in a file.
`bin/fm-send.sh` fails closed unless `FM_HOME` is explicit, so a steer cannot silently resolve against another home.
A secondmate's routed reply returns through status or a document pointer, not by firstmate peeking into its chat.
For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.

## PR ready, landing, and cleanup

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Under the brief's recorded-intent reconciliation contract, a no-mistakes worker that could not reconcile an accepted mid-run requirement ends at a keyed `needs-decision` wake over its durable hold instead of `done:`, green CI included; treat that as firstmate's call on follow-up work versus re-validation, not as a finished ship.
Run `bin/fm-pr-check.sh <id> <PR url>` to record the PR and arm the watcher's merge poll.
Tell the captain the PR's full URL, a concise outcome summary, and the no-mistakes risk level when applicable.
Any custom `state/<id>.check.sh` you write yourself follows the authoring contract in `bin/fm-check-register.sh`'s header and must be bound with that script before the watcher may execute it.

After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

## Scout outcome and promotion

Read and relay a completed scout's findings, record its self-contained report as the Done artifact, and re-evaluate the queue.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task, and send that worker the ship instructions the script prints.

## Backlog notes and threads

When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item; use `tasks-axi hold <id> --reason "<reason>" --kind captain` for a captain-gated thread.
Use compatible `tasks-axi` when the configured backend selects it and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to `AGENTS.md` section 6 rather than scattering it through task notes.

## Evaluations

Check this skill against these scenarios after any edit.
- A captain request names no project and matches two registered projects: intake asks which project instead of guessing, and spawns nothing until answered.
- A worker reports a PR ready while its checks are still red: the task is not treated as PR-ready, and the worker is steered to fix the checks first.
- A scout finishes with a report: its findings are relayed, the report is recorded as the Done artifact, and the queue is re-evaluated, with no ship task started unless promotion applies.
