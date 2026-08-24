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

The steer route uses the same byte-strip prefilter shape as the arm and cd guards: line-continuation and escape backslashes, quotes, and newlines are dropped before looking for `fm-send`, so ordinary quoting cannot hide the entry point.

Unlike those two guards, a quoting-decoder marker (`$'…'`, `$"…"`) deliberately does **not** escalate here.
They escalate to a classifier that can decide precisely; this guard has no such classifier, so escalating would mean denying, and denying every command containing `$'` for the whole life of an open finding is a worse failure than the obfuscation it would catch.
Deliberate obfuscation is out of scope under the same agent-mistake threat model those guards use.

### Routes this guard does not cover

Two escalation surfaces are outside a PreToolUse hook's reach, and are recorded here rather than left implicit.

- **Plain chat.** Firstmate escalating a finding as ordinary prose in its reply is not a tool call, so no PreToolUse hook can see it. `AGENTS.md` section 9 explicitly prefers plain chat for a yes-or-no decision, so this is a real residual gap. Closing it would need a turn-end mechanism, not a PreToolUse one.
- **`lavish-axi`.** A structured review surface is a third way to put options in front of the captain. It is a `Bash` call and could be added to the steer prefilter in one line, but it was not in the authorized scope of the change that introduced this guard, and widening the deny surface is a captain-owned call.

## Detecting a finding

An ask-user finding is a `needs-decision` line in `state/<id>.status`, closed by a `resolved` (or verified `captain-held`) line carrying the same `[key=<slug>]`.

`bin/fm-classify-lib.sh` is the single owner of that keyed open/resolved fold and this guard never re-implements it.
The guard uses two functions from that owner: `status_open_decisions` for the still-open set, and `status_decision_openings` for the raw opening stream that gives each finding its ordinal.

`blocked` also opens a keyed status decision and is deliberately **outside** this gate.
It means "firstmate action is needed", not "a reviewer asked a product question", and gating it would deny ordinary unblocking work.

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
The overwhelmingly common case, no finding open anywhere, costs one `grep` and nothing else.

## Fail-safe, not fail-noisy

A guard that wrongly denies is worse than the problem it solves: it blocks the whole fleet, including the steering needed to unblock it.
Every undeterminable state therefore **allows and stays silent**:

- malformed or empty hook stdin, or a payload with no recognizable tool name;
- missing `jq`;
- an unavailable `bin/fm-classify-lib.sh` or `bin/fm-primary-scope-lib.sh`;
- no readable state directory, or an unreadable status file;
- an absent or unreadable session transcript;
- a transcript whose entry format this guard no longer recognizes;
- a state directory too read-only to hold the ledger.

The transcript-format probe deserves its own note.
Before treating "no load found" as evidence, the guard confirms it can still parse a recognizable entry in the transcript's recent tail.
A future harness release that changes the transcript shape would otherwise turn every scan into a silent no-match and deny the whole fleet on a format change rather than a policy breach.
Any parse failure disarms the guard instead.

The cost of that choice is stated plainly: an unwritable state directory or an unparseable transcript silently disarms the gate.
`test_fail_safe_states_allow_silently` asserts each of these against a fixture that is proven to deny in its baseline, so none of them can pass vacuously.

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
Its three cases assert side effects, never model prose, and case B is the control that proves case A's deny is a real deny rather than a session that never tried.
Recorded result on 2026-08-25, claude 2.1.241: all three cases pass.

The AskUserQuestion route is not exercised by that guard, because headless `claude -p` does not expose the tool.
Its live evidence is the interactive capture above; the portable regression pins the tool-name classification.

### Regression coverage

`tests/fm-ask-user-pretool-check.test.sh` is the portable regression, run by CI with no harness.
It pins both routes, the per-finding gate including the stale-load case and the reopened-key case, the fail-safe family against a baseline that is proven to deny, the primary-home scoping, the structural-proof rule against this guard's own deny text, all three transport entry forms, the escape hatch, and the Claude wiring itself.
