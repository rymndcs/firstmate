Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and neither away mode nor a captain hold is active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Routine watcher arm and re-arm are owned by the Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`), never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle with no model command and no model tokens.
   An actionable close wakes you through the hook's exit-2 rewake, delivered as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
4. On the one `Stop hook feedback` automatic-mechanism failure notice (`firstmate watcher auto-arm FAILED ...`), drain, inspect the automatic mechanism failure, and do not turn the notice into a repeating manual-arm loop.
5. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and watcher startup path before ending blind.
   Keep the Stop-owned automatic mechanism as the only Claude arm owner.
6. Treat `watcher: started ...` and `watcher: attached ...` inside automatic arm output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a rewake and the next Stop-launched arm, while the bounded turn-end guard prevents a blind Stop when recovery did not start.
   No PreToolUse hook denies fleet commands based on watcher status.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. The turn-end guard (`bin/fm-turnend-guard.sh --claude`) remains the final backstop.
   It uses the same live-watcher and fresh-beacon predicate as the pull guard.
   It allows the stop when a watcher is healthy or the role-verified auto-arm owns recovery, while fresh failure epochs advance the bounded one-time attended fail-open progression described in [`turnend-guard.md`](../turnend-guard.md).
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook foregrounds.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract and the Claude ownership model.

## Captain hold

`state/.captain-hold` intentionally stops automatic Claude turns so the captain's context reminder stays visible until the captain decides.
The Stop auto-arm neither arms nor rewakes while held, including when the hold appears during a cycle, and the Claude turn-end guard allows Stop without a live watcher.
The primary-only `UserPromptSubmit` hook adds context on every real captain reply while held: end the reply by asking the captain to `/stow` then `/clear`, or explicitly dismiss the hold.
Operational injections receive no such context, and a reply alone never clears the marker.
Only an explicit dismissal authorizes `bin/fm-captain-hold.sh clear`; `bin/fm-session-start.sh` also clears it after acquiring the session lock when a new session begins.
Do not manually arm supervision or take automatic wake turns while held.
Events continue to accumulate in the durable wake queue; neither setting the hold nor suppressing a rewake consumes them, and the normal drain delivers them after release.
`bin/fm-captain-hold.sh --help` owns the marker-management commands and its script header owns the one-line reason and timestamp format.
The global context reminder hook is wired separately by the operator.
