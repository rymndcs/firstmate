---
name: afk
description: >-
  Enter away-mode supervision when the captain invokes /afk, says they are going afk, `state/.afk` exists, an incoming message starts with `FM_INJECT_MARK`, or any `state/.subsuper-*` marker is involved.
  It sets a durable away-mode flag so the sub-supervisor daemon can self-handle routine wakes and escalate captain-relevant events plus bounded declared-external-wait rechecks as batched digests during walk-away stretches, then exits automatically when any real unmarked message returns firstmate to full per-wake responsiveness.
user-invocable: true
metadata:
  internal: true
---

# afk

Away mode changes presence and reporting, never approval authority.
Use the same policy below for every delivery path.

## Enter or recover

Enter through `bin/fm-afk-launch.sh`, which owns the durable away flag, delivery selection, stale delivery artifacts, and rollback.
The script header and help own exact commands and record formats.

- In the Claude desktop app, select `start-desktop` explicitly.
  The Claude Stop hook owns the foreground coordinator and renewal; do not start a native background daemon or a separate watcher.
  The selected owner is durable and survives restart.
- In every terminal environment, retain the existing pane delivery.
  With a native tracked background tool, prepare with `start-native`, then run `FM_AFK_STATE_PREPARED=1 bin/fm-afk-start.sh` through that tool.
  On a failed native launch, use the launcher's `stop` command to roll back.
  Without a native tracked background tool, use `start` to create a non-visible tracked terminal.
  Never split the captain's active pane or manufacture a detached shell job.

Refreshing the current selection preserves pending delivery evidence.
Stop the existing selection before switching delivery paths.
Firstmate ends every away turn with exactly `·` as its only visible text.
Host-generated failure messages, such as API or authentication errors, are outside firstmate's control and may appear.
Do not send words, acknowledgments, progress messages, questions, or notifications while away.
The selected owner continues supervision after that fixed mark.

## Handle an internal away wake silently

1. Drain the durable wake queue before inspecting or acting.
   A Desktop `Stop hook feedback` carrying the `away-supervisor` envelope is internal even when the host adds text before that envelope.
   It never means the captain returned.
   After reading the Desktop handoff and draining successfully, use the launcher's `acknowledge` command.
   An emitted hook reminder alone is not acknowledgment; the delivery buffer survives until consumption.
2. Reconcile current state before acting on a historical event.
   Clear firstmate-actionable stops already within accepted authority, including eligible tool approvals, guard false positives, and environment recovery, through their existing lifecycle owners.
   Continue unrelated authorized work until it genuinely cannot proceed.
3. Park anything requiring the captain through the existing durable decision procedure in `decision-hold-lifecycle` and task/backlog mechanics in `task-lifecycle`.
   Preserve the original task and unlanded work.
   Record the stable decision key and verify its backlog entry before transferring its open status to `captain-held`.
   Release the worker from waiting for an immediate answer by directing it to stop at that durable decision; do not destroy its session or work.
   Move on to other work without asking or waiting for the captain.
   An unchanged parked condition must never be retried or re-escalated.
4. Keep the current selection as the only supervision owner.
   Desktop renewal is an internal handling turn followed by another Stop; never manually arm a second cycle.
   A real global captain hold remains authoritative and suppresses automatic Desktop turns.
   Never set or clear that global hold to park an individual decision.
5. Finish with exactly `·` as the only visible text, including after an automatic retry or a failure.
   Preserve failures durably for recovery and the return summary.

A difficult correction within accepted intent stays autonomous under the existing authority contract.
Away mode grants no extra permission for merges, ask-user findings, destructive actions, irreversible actions, or security-sensitive choices.
Load the existing authority and recovery skills at their normal triggers.

## Return

The first genuine unmarked captain message, other than another `/afk`, means return.
Current operational input and the host's enclosing Stop feedback remain internal.
The legacy bare `FM_INJECT_MARK` (U+2063 INVISIBLE SEPARATOR) prefix also remains accepted for daemon escalations.
`bin/fm-operational-input.sh` owns operational construction and classification; never use UserPromptSubmit alone as proof of human presence.
Bias genuinely ambiguous messages toward return.

1. Run `bin/fm-afk-return.sh` before acting on the return message.
   It retires the selected delivery path, drains pending wakes, preserves recovery evidence, and checks live firstmate-actionable blockers.
2. Remediate any remaining firstmate-actionable blocker, or durably reclassify and resolve its key through the existing lifecycle, then run `bin/fm-afk-return.sh check`.
   Resume normal supervision while doing this; no blind wait is allowed.
   Captain-only decisions stay parked and do not block this reconciliation.
3. Once the return gate clears, gather a fresh Bearings snapshot through the `bearings` skill and give one concise return summary from current durable work state.
   Do not replay escalation buffers, drained events, or historical status tails.
   Include current decisions and failures, completed work, ongoing work, and what remains queued using Bearings' existing format.
   Then handle the captain's message without producing a second catch-up summary.

Repeated internal wakes and repeated return checks do not create additional summaries.

## Mechanisms and limits

`bin/fm-supervise-daemon.sh` owns shared batching, status deduplication, stale checks, and declared-external-wait rechecks.
Its terminal delivery retains backend existence, busy/composer guards, verified type-once submit, and configured wedge alarms; `docs/herdr-backend.md` owns their backend contracts.
Its Desktop hook delivery retains pending evidence until explicit consumption and renews before the configured hook lifetime.
`docs/watcher-continuity.md` owns Stop continuity, and `docs/turnend-guard.md` owns its failure backstop.
`docs/verification/runtime-backends.md` records active away-delivery evidence and opt-in tests.

A hook requires a live local Claude session and a running machine.
Window closure, app quit, sleep/resume, host-visible silence, and provider or approval interruption must be verified on the Desktop host before unattended use is claimed.
Shell tests and CLI hook tests do not establish those Desktop lifecycle guarantees.
