# Ask-user authority gate

This document is the authoritative human-readable contract for the guard that makes the `ask-user-authority` skill impossible to skip.

The shipped mechanism is `bin/fm-ask-user-pretool-check.sh`, a PreToolUse guard that denies both tool-mediated ways out of an open ask-user finding until that skill has been loaded **for that finding**.

The skill itself is unchanged by this guard.
`.agents/skills/ask-user-authority/SKILL.md` remains the single owner of the decision procedure; this guard only forces it to run.

## Why this exists

`AGENTS.md` section 13 has always said to load `ask-user-authority` before deciding any ask-user finding.
Nothing enforced it.

On 2026-08-24/25 a firstmate primary loaded the skill once early in a long session, then handled roughly a dozen findings across five tickets without invoking it again.
The concrete cost was visible in one of them.
A worker reported that a migration's `COALESCE(body, '')` fallback could produce a task with an empty title that the model would then refuse to save, and offered three options.
Firstmate forwarded all three to the captain.
One `grep` would have settled it: `Crm::Activity` validates `body` presence for every non-file activity and the migration selects only tasks, so the state the fallback guards against cannot occur, and the correct answer was in none of the three options.
The skill's own step 2 is "Reconstruct the accepted contract from the captain's original request", and the captain's original request had already answered it months earlier.

The failure was not "the skill was never loaded".
It was "the skill was loaded, an hour and five tickets ago".
That is why this gate is **per finding** and not per session, and why `test_stale_load_before_finding_is_denied` in `tests/fm-ask-user-pretool-check.test.sh` is the load-bearing regression: a guard that only caught a never-loaded session would look correct and still permit exactly what happened.

## Purpose and boundary

The guard classifies one thing: whether an open ask-user finding has a recorded skill load newer than the finding itself.

It makes no judgment about the decision.
It cannot tell a good escalation from a bad one, and it does not try.
What it removes is the ability to reach either exit from a finding without the procedure having run against that finding.

## The two gated routes

There are exactly two tool-mediated ways firstmate resolves an ask-user finding, and gating one alone just pushes the decision to the other.

| Route | Tool surface | Deny wording |
| --- | --- | --- |
| Ask the captain | the `AskUserQuestion` tool | "asking the captain is one of the two ways out of an ask-user finding" |
| Answer the worker | a shell call invoking `bin/fm-send.sh` | "sending a decision to the worker is one of the two ways out of an ask-user finding" |

The steer route is a two-stage decision, prefilter then classifier, in the same shape the arm and cd guards use.

Stage one is a strict-superset byte-strip fast path in the transport: line-continuation and escape backslashes, quotes, and newlines are dropped before looking for `fm-send`, so ordinary quoting cannot hide the entry point.
A command that does not survive it can never be denied, which is why the fast path deliberately stays broader than the real decision.
It also runs before any state work, so an ordinary command pays one substring test and nothing else.

Stage two is `bin/fm-ask-user-command-policy.mjs`, invoked only once a finding is already known to be open, so the Node process never enters the common path.
It starts from command position: deny when a command word whose basename is `fm-send.sh` is executed anywhere in this program.
It imports `Lexer`, `splitProgram`, and `commandPosition` from `bin/fm-arm-command-policy.mjs`, the sole owner of firstmate's shell classification, so this guard never duplicates shell lexing.

The prefilter alone is not that decision: it matches any *mention* of the script, so it also catches `cat bin/fm-send.sh`, `grep -rn fm-send bin/`, `ls -la bin/fm-send.sh`, and `git log --oneline bin/fm-send.sh`.
Denying those makes the guard a wedge exactly when firstmate is trying to diagnose the thing it gated, and a wrong deny is worse than the problem this guard solves.

What stage two does **not** narrow is the non-decision uses of the real script.
The `--key Escape` nudge in [`stuck-crewmate-recovery`](../.agents/skills/stuck-crewmate-recovery/SKILL.md) and the `updatefirstmate` re-read nudge are genuine invocations of `bin/fm-send.sh`, and they are denied like any other while a finding is open anywhere in this home.
That is an authorized consequence of the deliberate cross-task gating, not something the classifier removed; the operational cost is recorded with the other costs below.

### The escalation rule

Command position alone is not the whole decision, because a program can carry the steer somewhere the node walk cannot place it.
`splitProgram` cuts on operators only, so `for w in rac196 rac197; do bin/fm-send.sh $w ok; done` arrives as three nodes and the middle one is headed by `do`; the steer is never in a command position, and a command-position-only policy allows it.
Answering two workers in one `Bash` call is the realistic agent-mistake shape, so that is not an acceptable gap: a guard a `for` loop walks straight through is not a guard, and a written-down bypass is worse than no guard because the next reader trusts it.

So the policy escalates: **cannot prove it is not a steer, deny.**

This is deliberately **not** the guard's fail-safe rule, and the two must not be collapsed into one.
Fail-safe covers state the guard cannot read - an unreadable status file, a missing tool, an unrecognized payload - and there the answer is allow and stay silent, because the guard has no business blocking work over its own blindness.
This is the opposite case: the guard can read the command, and the command carries a token it cannot rule out as a steer.
Denying is recoverable in one step, because the deny message names the skill to load.
Allowing is not recoverable at all, because the steer goes out unchecked.

Both rules stay intact.
Inside `bin/fm-ask-user-pretool-check.sh`, a missing Node, a missing policy file, or a policy answer the transport does not recognize still allow silently.

Concretely, a word whose basename is `fm-send.sh` is treated as plain data only when the node holding it is a fully placed simple command whose command word is neither a shell reserved word nor a utility that executes what it is handed.
`cat bin/fm-send.sh` is placed, so the path is an argument and stays allowed.
`do bin/fm-send.sh $w ok` is a compound-command body the walk cannot place, and `eval` and `xargs` execute what they are given, so all three deny.
The wrappers `commandPosition` already resolves through - `command`, `env`, `exec`, `nohup`, `sudo`, `timeout` - need no escalation, because it hands back the real command word for them.

Unlike the cd transport, a quoting-decoder marker (`$'…'`, `$"…"`) deliberately does **not** escalate past the fast path.
There, escalation hands an undecidable command to a classifier that can still decide it precisely.
Here the fast path's own answer is *allow*, so escalating past it would mean denying every command containing `$'` for the whole life of an open finding - a far worse failure than the obfuscation it would catch.
Deliberate obfuscation is out of scope under the same agent-mistake threat model those guards use.

### What the classifier covers, empirically

Every row below was produced by running the shipped module directly, `node bin/fm-ask-user-command-policy.mjs --command '<form>'`, not reasoned about.
The behavior is pinned end to end through the guard by `test_mentioning_the_steer_script_is_not_steering`, `test_steer_in_a_compound_command_is_denied`, and `test_steer_the_walk_cannot_place_is_denied`.

Denied because the steer is in a command position:

- a plain invocation, and any path spelling whose basename is `fm-send.sh`;
- ordinary quoting and escaping inside the word, `"bin/fm-send.sh"`, `bin/fm-'send'.sh`, `bin/fm-\send.sh`;
- leading assignments and wrappers, `FM_HOME=/h bin/fm-send.sh …`, `command …`, `env … `, `sudo …`, `timeout …`, `nohup …`;
- a subshell `(…)` or brace group `{ …; }`, a pipeline stage, a backgrounded job, a newline-separated line, and any position in an `&&`/`||`/`;` list, because unlike the cd guard there is no persistence question here - a steer delivers from every one of those positions, so no node is skipped;
- a command substitution, `x=$(bin/fm-send.sh …)`;
- the non-decision invocations, `bin/fm-send.sh rac196 --key Escape` and `FM_HOME=/h bin/fm-send.sh <window> --key Escape`.

Denied by the escalation rule, because the walk could not place the steer token:

- a loop body, `for w in rac196 rac197; do bin/fm-send.sh $w ok; done` and `while read -r w; do bin/fm-send.sh $w ok; done`;
- a conditional body, `if true; then bin/fm-send.sh rac196 ok; fi`;
- a `case` list, `case x in a) bin/fm-send.sh rac196 ok;; esac`, which the lexer rejects outright as unsupported syntax;
- `eval bin/fm-send.sh rac196 ok` and `eval "bin/fm-send.sh rac196 ok"`;
- `xargs -I{} bin/fm-send.sh {} ok`;
- an explicit shell invocation, `bash -c 'bin/fm-send.sh rac196 ok'` and `sh -c 'bin/fm-send.sh rac196 ok'`;
- `find . -name x -exec bin/fm-send.sh {} \;`, and the same for `-execdir`, `-ok`, `-okdir`;
- `nice`, `setsid`, `flock`, `watch`, `parallel`, `ssh`, `su`, and the other utilities that execute what they are handed;
- `time bin/fm-send.sh rac196 ok`, because `time` is a reserved word rather than a command;
- `STEER=bin/fm-send.sh; $STEER rac196 ok`, because the assignment node cannot be placed.

Allowed, because the path is an argument of a placed simple command that only reads it: `cat bin/fm-send.sh`, `grep -rn fm-send bin/`, `grep -rn fm-send.sh bin/`, `ls -la bin/fm-send.sh`, `git log --oneline bin/fm-send.sh`, `wc -l bin/fm-send.sh`, `git diff bin/fm-send.sh`, `shellcheck bin/fm-send.sh`, `find . -name fm-send.sh`, `echo fm-send`.

The escalation is broader than a command-position match, and two consequences are worth stating plainly.

**A read-only loop over the path denies.**
`for f in bin/fm-send.sh; do cat $f; done` is denied even though it only reads the file.
That is the rule working as designed rather than a defect: the walk cannot place that word, and the tie is broken toward the recoverable outcome.
Inspecting the file without a loop, which is what diagnosis actually looks like, is unaffected.

**Stated gap: a heredoc body is never lexed.**
`bash <<EOF` … `bin/fm-send.sh a b` … `EOF` is allowed.
The tokenizer treats a heredoc as a redirection and its body as data it never turns into words, which is correct for the overwhelmingly common case of feeding text to a data sink, and wrong only when the sink is itself a shell.
That shape is outside the agent-mistake threat model this guard shares with the arm and cd guards: an agent skipping the skill reaches for the steer, not for a heredoc-fed interpreter.
Closing it would mean lexing heredoc bodies inside `bin/fm-arm-command-policy.mjs`, which is a change to the shared classifier and a captain-owned call.

### Routes this guard does not cover

Two escalation surfaces are outside a PreToolUse hook's reach, and are recorded here rather than left implicit.

- **Plain chat.** Firstmate escalating a finding as ordinary prose in its reply is not a tool call, so no PreToolUse hook can see it. `AGENTS.md` section 9 explicitly prefers plain chat for a yes-or-no decision, so this is a real residual gap. Closing it would need a turn-end mechanism, not a PreToolUse one.
- **`lavish-axi`.** A structured review surface is a third way to put options in front of the captain. It is a `Bash` call and could be added to the steer prefilter in one line, but it was not in the authorized scope of the change that introduced this guard, and widening the deny surface is a captain-owned call.
- **A steer inside a heredoc body fed to a shell.** Covered under the classifier's stated gap above.

One cost runs the other way, and belongs here rather than being left implicit.
Every non-decision use of `bin/fm-send.sh` is denied too, on any task, while a single finding is open anywhere in this home: the `--key Escape` nudge in [`stuck-crewmate-recovery`](../.agents/skills/stuck-crewmate-recovery/SKILL.md) and the `updatefirstmate` re-read nudge are genuine invocations and the guard cannot tell them from a decision.
That is an authorized consequence of gating the steer entry point across the whole home rather than per task, and it is recoverable in one step: load `ask-user-authority` for the open finding, or launch the session with `FM_ALLOW_ASK_USER=1`.
It is a cost, not a wedge, and the deny message names both routes out.

## Detecting a finding

An ask-user finding is a `needs-decision` line in `state/<id>.status`, closed by a `resolved` (or verified `captain-held`) line carrying the same `[key=<slug>]`.

`bin/fm-classify-lib.sh` is the single owner of that keyed open/resolved fold and this guard never re-implements it.
The guard uses two functions from that owner: `status_open_decisions` for the still-open set, and `status_decision_openings` for the raw opening stream that gives each finding its ordinal.

`blocked` also opens a keyed status decision and is deliberately **outside** this gate.
It means "firstmate action is needed", not "a reviewer asked a product question", and gating it would deny ordinary unblocking work.

That filter has a consequence worth stating, because it is a way the gate goes quiet without anyone choosing it.
`blocked` and `needs-decision` share one keyed fold, so a `blocked` line carrying the same `[key=…]` as an open `needs-decision` **replaces** it, and the finding disappears from this guard's `needs-decision`-only view.
The likely trigger is benign and in-protocol: a worker waiting on the answer reports itself blocked under the same key, and the finding it was waiting on stops being gated.
The fold belongs to `bin/fm-classify-lib.sh` fleet-wide, so this is not a guard defect and is not fixed by loosening the filter here.
Re-raising `needs-decision` under that key increments its ordinal, which makes it a new finding and re-arms the gate.

### Finding identity

A finding's identity is `<task>|<key>|<nth-opening-of-that-key>|<checksum-of-the-note>`.

The ordinal is what makes a reopened key a new finding rather than the old one.
Without it, a worker raising a second question under the same key would inherit the first finding's satisfied proof, which is the same stale-proof bug at a smaller scale.
`test_reopened_key_needs_a_fresh_load` pins this.

## Detecting the load

This is the part that had to be established empirically rather than assumed.
No hook in this repo read the session transcript before this one, so whether a PreToolUse payload even carries a transcript path was unverified.
The validation record below is the evidence; the design depends on all three facts it establishes.

A load is proven only by a **structural** `tool_use` entry in the transcript, never by the skill's name appearing as text.
That distinction is load-bearing: this guard's own deny message names the skill, so a substring match would let the deny text satisfy the very finding it just denied.
`test_deny_text_cannot_satisfy_itself` replays a real deny message back into a transcript and asserts the gate stays shut.

Three accepted forms, each a real load of the skill's content:

- the `Skill` tool invoked with `input.skill == "ask-user-authority"`;
- any tool whose `input.file_path` ends with `ask-user-authority/SKILL.md`;
- a shell command whose `input.command` contains `ask-user-authority/SKILL.md`, which is how a bypass-permissions session reads a file.

### Per-finding, not per-session

Proof is positional, not chronological: status lines carry no timestamps, so a clock comparison was never available.

The guard keeps an observation ledger at `state/.ask-user-authority-guard`, one row per currently-open finding:

```text
<identity>	<transcript-path>	<byte-offset-at-first-sight>
```

A load counts only if it appears in the transcript at or after that finding's recorded offset.
The ledger is rewritten to exactly the currently-open set whenever that set changes, so a resolved finding's row is pruned and the file stays bounded.

A different transcript path means a different session, so the recorded position means nothing in the new file and the finding needs a fresh load there.
A transcript shorter than the recorded offset was rotated or truncated and is treated the same way.

### Why every tool call observes

The guard runs its observation pass on **every** tool call, including calls it could never deny, and this is not incidental.

The ledger records where in the transcript a finding was first seen.
If it were written only on a gated call, first sight would be the `AskUserQuestion` or steer itself, which in a correct session is already **after** firstmate loaded the skill in response to the finding.
The guard would then deny work that was done right, on the very first attempt, every time.

Observing on every call moves first sight to the first tool call after the finding appeared, which precedes any load made in response to it.

Because that pass runs on every tool call, its cost is part of the contract.
Two greps carry it.
A whole-fleet `grep -l needs-decision state/*.status` runs first, ahead of the git scope check and both library sources, and exits the guard outright while no task in the home has ever had an ask-user finding.
It stops short-circuiting permanently after the first one, because status files are append-only and a resolved finding leaves its opening line in place forever.
From then on a per-file `grep -q` at the top of the scan is what keeps the steady state cheap: only files that still mention `needs-decision` are parsed, instead of every status file in the home being folded twice on every tool call.
A line whose verb parses to `needs-decision` must contain that substring, so the skip cannot change the open set.

## Fail-safe, not fail-noisy

A guard that wrongly denies is worse than the problem it solves: it blocks the whole fleet, including the steering needed to unblock it.
Every undeterminable state therefore **allows and stays silent**:

- malformed or empty hook stdin, or a payload with no recognizable tool name;
- missing `jq`;
- an unavailable `bin/fm-classify-lib.sh` or `bin/fm-primary-scope-lib.sh`;
- no readable state directory, or an unreadable status file;
- an absent or unreadable session transcript;
- a transcript whose entry format this guard no longer recognizes;
- a state directory too read-only to hold the ledger;
- a missing Node runtime or a missing `bin/fm-ask-user-command-policy.mjs`, which disarms the steer route only and leaves the `AskUserQuestion` route gated.

The transcript-format probe deserves its own note.
Before treating "no load found" as evidence, the guard confirms it can still parse a recognizable entry in the transcript's recent tail.
A future harness release that changes the transcript shape would otherwise turn every scan into a silent no-match and deny the whole fleet on a format change rather than a policy breach.
Any parse failure disarms the guard instead.

The cost of that choice is stated plainly: an unwritable state directory or an unparseable transcript silently disarms the gate.
A `blocked` line landing on an open finding's key disarms it the same way, for a different reason - see the fold note under "Detecting a finding".
`test_fail_safe_states_allow_silently` and `test_missing_steer_classifier_allows_silently` assert each of these against a fixture that is proven to deny in its baseline, so none of them can pass vacuously.

The gate also has a cost in the other direction, paid while it is armed rather than while it is disarmed, and it is real enough to state next to these.
Every use of `bin/fm-send.sh` is denied on every task while any one finding is open in this home, including the non-decision nudges recorded under "Routes this guard does not cover".
Fail-safe governs what the guard does when it cannot read something; the escalation rule under "The escalation rule" governs what it does when it can read a command but cannot place a steer token in it, and there the tie breaks toward denying.
Both denials are recoverable in one step, which is what makes them costs rather than wedges.

## Scope

The guard fires only in a genuine firstmate primary home, using the shared predicate `fm_primary_scope_matches` from `bin/fm-primary-scope-lib.sh` - the same predicate the session-start nudge, the turn-end guard, and the delegation guard use, so the tracked primary-scoped hooks cannot drift apart.

A marked secondmate home is in scope: it runs its own fleet and decides its own findings.

A crewmate or scout task worktree is a linked git worktree and stays inert.
A worker raises findings and never decides them, and denying a worker's own steering would strand it.

## Escape hatch

`FM_ALLOW_ASK_USER=1` in the session environment allows the call.
Every other value stays closed, including empty, `0`, `yes`, and `true`.

It is an environment variable rather than a flag or a state file for the same reason as `FM_ALLOW_SUBAGENT`: it must be present when the harness process is launched, so no in-session tool call can enable it for the call that follows, and it therefore cannot weaken the per-finding gate from inside a session.

## Output contract

- Allow returns exit 0 with both streams empty.
- Deny returns exit 2 and writes `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[ask-user-authority] ..."}` to stderr.
- Default deny mode also writes `{"decision":"deny","reason":"[ask-user-authority] ..."}` to stdout for Grok.
- `--claude` suppresses stdout completely, because Claude Code ignores a PreToolUse deny when stdout is nonempty.
  This is the same verified quirk recorded in [`arm-pretool-check.md`](arm-pretool-check.md), and the tracked Claude hook therefore passes `--claude`.

The deny message names the finding by task and key, states the remedy as a concrete action, and says explicitly that an earlier load does not count.
A deny that does not tell the reader how to proceed converts a guard into a wedge.

## Harness wiring

| Harness | Status |
| --- | --- |
| Claude | Wired in `.claude/settings.json` under the existing `.*` PreToolUse matcher, and live-verified below. |
| Codex | Not wired. The transport accepts Codex's payload shape, but Codex's transcript location and entry format are unverified, and the guard has no other load evidence. |
| Grok | Not wired. Payload shape accepted, transcript unverified. |
| OpenCode | Not wired. CLI entry form available, transcript unverified. |
| Pi | Not wired. CLI entry form available, transcript unverified. |
| Kimi | Not wired. Crew-only harness in this fleet. |

Wiring another harness requires establishing that harness's transcript path and entry format the same way the Claude record below does.
Do not wire one on the assumption that its payload resembles Claude's.

The Claude matcher is the existing `.*` block rather than a new `AskUserQuestion|Bash` one.
A name-enumerating matcher would reintroduce the fail-open-by-enumeration problem, because a renamed or added tool outside the matcher would never reach the script that owns classification.

## Validation record

### Harness payload probe, Claude Code 2.1.241, 2026-08-25

Run in a scratch git repo with a PreToolUse hook that appended raw stdin to a file, so the payload is the harness's own bytes and not a reconstruction.

A `Bash` call, with the tool input elided for length:

```json
{
  "cwd": "/tmp/.../payload-probe",
  "effort": { "level": "high" },
  "hook_event_name": "PreToolUse",
  "permission_mode": "bypassPermissions",
  "prompt_id": "ac2eb48c-1019-45a9-8283-d53d1bd5819c",
  "session_id": "deacaa7e-6b70-4673-8f0b-7587716ae6e5",
  "tool_input": { "command": "echo probe-marker", "description": "Echo probe marker" },
  "tool_name": "Bash",
  "tool_use_id": "toolu_01FouJ5TZDmHyRGuCfqpRCES",
  "transcript_path": "/home/.../deacaa7e-6b70-4673-8f0b-7587716ae6e5.jsonl"
}
```

An `AskUserQuestion` call, captured from an interactive session because headless `claude -p` does not expose that tool:

```json
{
  "hook_event_name": "PreToolUse",
  "permission_mode": "bypassPermissions",
  "tool_input": { "questions": "<elided>" },
  "tool_name": "AskUserQuestion",
  "tool_use_id": "toolu_01M2KstCyeKhhaVXacGEZCu5",
  "transcript_path": "/home/.../ce32ab29-840a-434d-a6a7-b5efbb9348fd.jsonl"
}
```

A `Skill` call, confirming that an agent-only skill (`user-invocable: false`) is still invoked through the `Skill` tool and carries its name in `tool_input.skill`:

```json
{ "tool_name": "Skill", "tool_input": { "skill": "ask-user-authority" } }
```

**Fact 1: `transcript_path` is present on every PreToolUse payload, and the file exists.**
This is what makes per-finding detection possible at all.
Had it been absent, the fallback would have been a marker written by the skill itself, which is strictly weaker: it depends on the skill running to prove the skill ran, so it can catch a stale re-use but never a skip.
That fallback was not needed and is not implemented.

**Fact 2: the transcript records a skill load as a structural `tool_use` entry.**
Reading the probe transcript back:

```text
["2026-08-24T18:19:38.948Z",[{"name":"Bash","input":{"command":"echo probe-marker","description":"Echo probe marker"}}]]
["2026-08-24T18:20:05.410Z",[{"name":"Skill","input":{"skill":"ask-user-authority"}}]]
```

Entries are JSONL with `.type`, `.timestamp`, and `.message.content[]`; a tool call is `{"type":"tool_use","name":…,"input":…}` inside that array.

**Fact 3: PreToolUse fires before the calling tool's own entry is appended, and a prior skill load is already visible.**
A hook that logged the transcript size and its `tool_use` entries at hook time, across a session told to invoke the skill and then run a Bash command:

```text
=== tool=Skill  bytes=64997
=== tool=Bash   bytes=74977
[{"name":"Skill","skill":"ask-user-authority"}]
```

At the `Skill` hook the transcript held no `tool_use` entries at all; at the following `Bash` hook the `Skill` entry was present and the `Bash` entry was not.
This is what makes the ledger safe: recording the current size at a call can never swallow the load being recorded against it, and a load is visible to the very next call.

### Live gate behavior, Claude Code 2.1.241, 2026-08-25

Run against a scratch primary-shaped home (plain git checkout, `AGENTS.md`, `bin/`, `state/`) with the real hook wired exactly as `.claude/settings.json` wires it.

Steer route denied, with an open finding and no load:

```text
[ask-user-authority] sending a decision to the worker is one of the two ways out of an ask-user
finding, and these open findings have no ask-user-authority load recorded since they appeared:
rac196 [key=title-fallback]. Invoke the ask-user-authority skill now ...
```

`AskUserQuestion` route denied in the same state, captured interactively:

```text
Error: PreToolUse:AskUserQuestion hook error: [.../bin/fm-ask-user-pretool-check.sh --claude]:
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":
"[ask-user-authority] asking the captain is one of the two ways out of an ask-user finding, ..."}
```

Remedy path allowed: a session told to invoke the skill and then steer ran the steer to completion, with `bin/fm-send.sh` producing its output and no hook output.

**The regression itself, live.**
A session was told to (1) invoke the skill, (2) append a `needs-decision` line to a status file, (3) steer.
Step 1 was a genuine skill load in that same session.
Step 3 was denied:

```text
[ask-user-authority] ... these open findings have no ask-user-authority load recorded since they
appeared: rac999 [key=late]. ...
```

That is the 2026-08-24/25 failure reproduced end to end and blocked: a real load, in the same session, an instant earlier, does not satisfy a finding that arrived after it.

### Refreshing this record

`tests/fm-ask-user-gate-live-e2e.test.sh` is the live guard that regenerates the behavior half of this record.
It is opt-in and self-skipping because standard CI has neither a harness binary nor credentials:

```sh
FM_CLAUDE_LIVE_E2E=1 bash tests/fm-ask-user-gate-live-e2e.test.sh
```

It exercises the real installed Claude Code and fails naming the harness and version.
Run it after every Claude upgrade and before trusting the dates above.

Its three cases assert side effects, never model prose.
Each also carries its own structural attempt assertion, because an absent steer marker is equally true of a session that never tried, and no other case can supply that proof: each case is a different session with a different prompt.
A second PreToolUse hook in the lab home records every tool call to `state/attempts.log` and exits 0 without touching any decision, and a case whose log holds no `Bash` attempt at the gated steer fails saying it proved nothing rather than passing.
That is what keeps the file honest against the release it exists to catch: a future Claude that simply declines to try would otherwise leave the deny cases green.

Recorded result on 2026-08-25, claude 2.1.241: all three cases pass.

The AskUserQuestion route is not exercised by that guard, because headless `claude -p` does not expose the tool.
Its live evidence is the interactive capture above; the portable regression pins the tool-name classification.

### Regression coverage

`tests/fm-ask-user-pretool-check.test.sh` is the portable regression, run by CI with no harness.
It pins both routes, the per-finding gate including the stale-load case and the reopened-key case, the fail-safe family against a baseline that is proven to deny, the primary-home scoping, the structural-proof rule against this guard's own deny text, all three transport entry forms, the escape hatch, and the Claude wiring itself.
It also pins the steer classifier from the outside, through the guard rather than against the policy module: inspecting `bin/fm-send.sh` allows, invoking it denies from every shell position listed above, a steer the walk cannot place denies without re-denying inspection, and removing the policy module disarms the steer route alone.
