Mode: omp async-job supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Source `__FM_X_MODE_ENV__` first when X mode is active.
3. First cycle: arm with omp's tracked background job, as its own call:

   `bash` with `async: true` and `timeout: 0` on:
   `[ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; exec bin/fm-watch-arm.sh`

4. The call returns a job id, not the arm's status.
   Read `proc://<job-id>` once for the arm's one-line status; reading it does not consume the completion delivery.
5. Trust only that one-line status.
   `watcher: started ...` or `watcher: attached ...` means a live cycle exists.
   On attach, the job follows verified identity-matched successors instead of exiting when the first cycle ends.
6. Failure or missing cycle only: `watcher: FAILED ...` means supervision is down; fix and re-arm.
7. After a successful start or attach status, end the turn.
   The async job remains the live wait until it returns an actionable wake or failure.
8. Waiting is silent: never poll the job, call `wait` on it, or kill it.
9. Never use shell `&` for firstmate supervision.
10. Never bundle the arm onto another command.
    A shell `&`, a truncating pipe, or bundling is denied automatically by the seatbelt in `.omp/extensions/fm-primary-omp.ts`.

omp delivers a finished async job as a new turn, even when the session is idle.
When the arm job's completion arrives:
1. Run `bin/fm-wake-drain.sh` first.
2. Read the reason line from the delivered job output.
3. Handle `signal`, `stale`, `check`, or `heartbeat` using the harness-neutral contract in `AGENTS.md`.
4. Ordinary wake: re-arm the next cycle with the same async `bin/fm-watch-arm.sh` call if work remains in flight or X mode still needs polling.
5. Do not invent a wake from an attach-status line alone.
   Drain the queue and act only on real wake records or a real watcher reason line.
   Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
   See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract.

After the captain interrupts a turn, omp folds a later job completion into context instead of starting a turn, so drain on the next turn, after acting on any direct captain order.
`/new` and quitting omp cancel every job this session owns; re-arm after either.

The project extension `.omp/extensions/fm-primary-omp.ts` runs `bin/fm-turnend-guard.sh` on omp's `session_stop` event as a backstop, not the normal wake path.
omp defers that event while any async job is still running, so a healthy armed watcher never triggers it.
[`turnend-guard.md`](../turnend-guard.md) owns the guard contract.
After any forced continuation, arm the watcher with the async protocol above.

omp discovers that extension only from the launch directory, so start the primary from the repo root and never with `--no-extensions`.
Interactive TUI primary sessions are the supported supervision host; do not run the primary firstmate as one-shot `omp -p`.
