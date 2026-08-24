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
Per finding means "after this finding appeared", and on the ask route it also means per call: an allowed `AskUserQuestion` spends the load it used, so the next one needs its own.
An allowed steer spends nothing, which is a deliberate asymmetry - see "One load buys one escalation to the captain" and the known limit under "The steer route does not consume".

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
- the shells and shell-adjacent runners named in `COMMAND_EXECUTORS`, which is exactly `.`, `bash`, `chroot`, `dash`, `doas`, `eval`, `flock`, `ionice`, `ksh`, `nice`, `parallel`, `runuser`, `setsid`, `sh`, `source`, `ssh`, `stdbuf`, `su`, `watch`, `xargs`, `zsh`, plus `find` under its `-exec` family, and nothing else;
- `time bin/fm-send.sh rac196 ok`, because `time` is a reserved word rather than a command;
- `STEER=bin/fm-send.sh; $STEER rac196 ok`, because the assignment node cannot be placed.

Allowed, because the path is an argument of a placed simple command that only reads it: `cat bin/fm-send.sh`, `grep -rn fm-send bin/`, `grep -rn fm-send.sh bin/`, `ls -la bin/fm-send.sh`, `git log --oneline bin/fm-send.sh`, `wc -l bin/fm-send.sh`, `git diff bin/fm-send.sh`, `shellcheck bin/fm-send.sh`, `find . -name fm-send.sh`, `echo fm-send`.

Deep nesting escalates rather than allows.
The re-lexing recursion has a runaway backstop at eight levels, and a program that runs past it is treated exactly like one the lexer could not tokenize: if the remaining bytes still carry a steer token, it denies.
That escalation is not selective, so inspection is unaffected only *below* the bound: `cat bin/fm-send.sh` wrapped in one to eight subshells allows, and the same command wrapped in nine or more denies, because the bound is reached before any placement is attempted.
`test_deep_nesting_past_the_bound_denies` covers the steer at depths 1, 8, 9, and 16, and the inspection allow at depths 1, 3, and 8, which is the range the sentence above claims.
Nine nested subshells around a `cat` is not a shape anyone writes, so the practical cost is nil, but the claim is bounded here rather than stated absolutely.

### What the escalation costs

The escalation is broader than a command-position match, and it denies a real class of read-only command.
Every row below was verified by running the shipped module.
None of this argues for narrowing the rule - deny-on-unplaceable is the decision - only for the class being written down, since an unwritten cost is the one that surprises the next reader.

**A guarded existence check denies, and so does a loop over the path.**
An `if`/`then` node is headed by a reserved word, so the walk cannot place anything in it and the escalation fires on any steer token it holds:

- `if [ -f bin/fm-send.sh ]; then echo yes; fi` denies;
- `if grep -q fm-send.sh docs/ask-user-guard.md; then echo yes; fi` denies;
- `for f in bin/fm-send.sh; do cat $f; done` denies.

Checking that a thing exists before acting on it is at least as common a diagnosis shape as a bare `cat`, so this is not an exotic corner.
The unguarded spellings of the same intent do allow: `test -f bin/fm-send.sh && echo yes` and `[ -f bin/fm-send.sh ] && echo yes` are ordinary list nodes with placed command words.

**Some wrappers around inspection deny, and some do not.**
`commandPosition` resolves through `command`, `env`, `exec`, `nohup`, `sudo`, and `timeout`, handing back the real command word, so inspection behind those is placed and allowed.
It does not resolve through the executors, so inspection behind one of those escalates instead:

- denied: `nice cat bin/fm-send.sh`, `stdbuf -o0 cat bin/fm-send.sh`, `ssh host cat bin/fm-send.sh`, `watch -n1 ls -la bin/fm-send.sh`;
- allowed: `timeout 5 cat bin/fm-send.sh`, `sudo cat bin/fm-send.sh`, `command cat bin/fm-send.sh`, `env cat bin/fm-send.sh`.

The split is a property of which wrappers the shared classifier unwraps, not a judgment about which ones are safer.

**Stated gap: a heredoc body is never lexed.**
`bash <<EOF` … `bin/fm-send.sh a b` … `EOF` is allowed.
The tokenizer treats a heredoc as a redirection and its body as data it never turns into words, which is correct for the overwhelmingly common case of feeding text to a data sink, and wrong only when the sink is itself a shell.
That shape is outside the agent-mistake threat model this guard shares with the arm and cd guards: an agent skipping the skill reaches for the steer, not for a heredoc-fed interpreter.
Closing it would mean lexing heredoc bodies inside `bin/fm-arm-command-policy.mjs`, which is a change to the shared classifier and a captain-owned call.

**Stated gap: an interpreter one-liner that carries the steer.**
This one was reviewed and deliberately left open; it is a decision, not an oversight.

*What is not covered.*
`COMMAND_EXECUTORS` holds shells and shell-adjacent runners only, so a general-purpose interpreter handed the steer as program text is allowed.
Verified against the shipped module, all of these allow:

- `python3 -c "import subprocess;subprocess.run(['bin/fm-send.sh','rac196','ok'])"`;
- `node -e "require('child_process').execSync('bin/fm-send.sh rac196 ok')"`;
- `perl -e "system(q(bin/fm-send.sh rac196 ok))"`;
- `awk 'BEGIN{system("bin/fm-send.sh rac196 ok")}'`;
- `git rebase --exec "bin/fm-send.sh rac196 ok" main`;
- interpreter one-liners generally, by the same mechanism.

*Why it stays open.*
This guard exists to stop firstmate **forgetting** a skill, not to stop a determined bypass, and that is the same accidental-omission threat model the arm and cd guards use.
A firstmate that skips `ask-user-authority` reaches for `bin/fm-send.sh`, not for a Python one-liner wrapping it.
Adding interpreters to the executor list would deny an ordinary `python3 -c` whenever any finding is open anywhere in the home, and firstmate uses `python3 -c` routinely to edit knowledge files and parse output, entirely unrelated to steering.
That is precisely the wrongly-denies failure two review rounds were spent removing.
A guard that blocks a dozen legitimate commands to close a hole nobody will walk through is a worse guard.

*What would change the answer.*
If a steer ever actually reaches a worker through one of these forms, the gap stops being theoretical and `COMMAND_EXECUTORS` is revisited on that evidence.
Record the incident here when it happens.
A documented gap with no condition for revisiting it decays into a forgotten one, so this trigger is part of the decision rather than a footnote to it.

### Routes this guard does not cover

Two escalation surfaces are outside a PreToolUse hook's reach, and are recorded here rather than left implicit.

- **Plain chat.** Firstmate escalating a finding as ordinary prose in its reply is not a tool call, so no PreToolUse hook can see it. `AGENTS.md` section 9 explicitly prefers plain chat for a yes-or-no decision, so this is a real residual gap. Closing it would need a turn-end mechanism, not a PreToolUse one.
- **`lavish-axi`.** A structured review surface is a third way to put options in front of the captain. It is a `Bash` call and could be added to the steer prefilter in one line, but it was not in the authorized scope of the change that introduced this guard, and widening the deny surface is a captain-owned call.
- **A steer inside a heredoc body fed to a shell.** Covered under the classifier's stated gap above.

### The steer route does not consume

The batch property above survives on `AskUserQuestion` and is **given up** on the steer route.
While a finding is open, the first `bin/fm-send.sh` still needs a load, and later ones ride it.
That is a deliberate limit, recorded here rather than left for the next reader to discover.

The reasoning: every real failure this guard was built for went through the captain - findings forwarded that one `grep` would have settled - so `AskUserQuestion` is where the batch property earns its cost.
The steer route is the backstop against deciding *silently*, and a load before the first delivery does most of that work.
Against that, `bin/fm-send.sh` is also firstmate's ordinary fleet transport, so consuming there taxed things the guard must not obstruct: [`stuck-crewmate-recovery`](../.agents/skills/stuck-crewmate-recovery/SKILL.md) sends an interrupt and then a corrective line, [`updatefirstmate`](../.agents/skills/updatefirstmate/SKILL.md) nudges each updated target in turn, and read-only diagnosis in the escalation class below spent the proof too because it names no target.
Attributing a steer to a task was tried and removed: it narrowed the tax without ending it, and a guard that obstructs the tools used to fix problems is worse than the omission it prevents.
`test_an_allowed_steer_does_not_spend_the_load` pins what ships.

### What the non-decision denial costs

One cost runs the other way from the gaps above, and belongs here rather than being left implicit.
Every non-decision use of `bin/fm-send.sh` is denied too, on any task, while a single finding is open anywhere in this home: the `--key Escape` nudge in `stuck-crewmate-recovery` and the `updatefirstmate` re-read nudge are genuine invocations and the guard cannot tell them from a decision.
That is an authorized consequence of gating the steer entry point across the whole home rather than per task.

The remedy is **one load**, not one per finding named.
A single `ask-user-authority` load clears a deny naming any number of unproven findings, and because the steer route does not consume, the whole nudge or recovery sequence that follows rides that one load.
`FM_ALLOW_ASK_USER=1` at session launch remains the deliberate exception.
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

A load is proven only by a **structural** `tool_use` entry in the transcript, never by prose anywhere else in it.
That distinction is load-bearing: this guard's own deny message names the skill, so a plain substring scan of the transcript would let the deny text satisfy the very finding it just denied.
`test_deny_text_cannot_satisfy_itself` replays a real deny message back into a transcript and asserts the gate stays shut.

Three accepted forms:

- the `Skill` tool invoked with `input.skill == "ask-user-authority"`;
- any tool whose `input.file_path` ends with `ask-user-authority/SKILL.md`;
- a shell command whose `input.command` contains `ask-user-authority/SKILL.md`, which is how a bypass-permissions session reads a file.

The first two require a real load.
The third does not, and that is a stated limit rather than an oversight.

**Stated limit: naming the skill's path in a shell command counts as reading it.**
The third form matches any `tool_use` whose `input.command` merely *contains* the path, so a command that names it without reading it satisfies the gate.
Verified against the shipped guard: with one finding open, `AskUserQuestion` denies, and a single `Bash` entry running `grep -n ask-user-authority/SKILL.md docs/ask-user-guard.md` makes the very next `AskUserQuestion` allow, with the skill never read.
An `ls -l` of that path, or any command quoting it, does the same.

This is not exotic in exactly the situation the guard creates: **this document contains the literal path string**, so a firstmate that grep-diagnoses its own deny by reading this contract can satisfy the very finding it was denied on.

What stays tight is the rest.
The `Skill` form compares `input.skill` for equality and the `file_path` form uses an `endswith` match, and neither can be satisfied without a real load.
The deny message deliberately never contains the path, so this is **not** the self-satisfaction loop `test_deny_text_cannot_satisfy_itself` pins; that one remains closed.

The known remedy, recorded but not applied: require the path to be an argument of a *placed reading command*, which `bin/fm-ask-user-command-policy.mjs` already has the classifier to decide.
Apply it if this limit ever stops being acceptable - that is, if a finding is ever satisfied by a command that named the skill without reading it.

### Per-finding, not per-session

Proof is positional, not chronological: status lines carry no timestamps, so a clock comparison was never available.

The guard keeps an observation ledger at `state/.ask-user-authority-guard`, one row per open finding **per session**:

```text
<identity>	<transcript-path>	<byte-offset-at-first-sight>
```

A load counts only if it appears in the transcript at or after that finding's recorded offset.

### One load buys one escalation to the captain

Proof is **consumed**, but by one route only.

When the guard allows an `AskUserQuestion`, it moves every open finding's recorded offset to just past the load that satisfied it, so that load can never satisfy anything else.
An allowed steer consumes nothing; see "The steer route does not consume" under the known limits.

Without consumption on the ask route, the gate would be per finding only in the temporal sense.
Several crewmates raise findings while firstmate is away, so it wakes to three or four open at once, loads the skill once, and escalates all of them; positional proof that is never spent lets one load cover the whole batch.
The skill's step 2 is "reconstruct the accepted contract from the captain's original request", and that reconstruction is specific to **one** finding.
One load covering four means three got no reconstruction at all, which is the 2026-08-24/25 failure compressed into a single wake instead of spread across a session.
The batch shape is the normal morning, not an edge case, and N loads per wake is trivial against what it buys: firstmate reads the procedure again with *this* finding in mind.
`test_one_load_does_not_cover_a_whole_batch` pins it.

Three properties of the consume rule are deliberate and are stated here rather than left to be discovered:

- **Only a permitted `AskUserQuestion` consumes.** An observation call still stamps first sight and never advances anything, which is what keeps first sight where "Why every tool call observes" below needs it, and a permitted steer leaves every position untouched.
- **Consumption is per call, not per finding-lifetime.** A second `AskUserQuestion` needs its own load even when the same single finding is the only thing open, and because the ask route consumes every open finding's proof, a steer that follows an escalation needs one too. `test_load_for_the_finding_allows_both_routes` walks that pair and asserts the intervening deny.
- **A ledger that cannot be written still allows.** Consumption is bookkeeping, and a guard must never turn its own bookkeeping failure into a deny.

The row is keyed on the pair, identity and transcript together, not on the identity alone.
Two sessions can be open on the same home - a captain-launched second `claude` in the firstmate checkout is the realistic case - and each has its own first sight of the same finding.
Keying on the identity alone let whichever session wrote last silently revoke the other's established position, so a load that session had genuinely made in response to the finding stopped counting and the finding denied indefinitely.
`test_two_sessions_keep_their_own_first_sight` reproduces that sequence and pins the fix.

A different transcript path still means a different session, so its recorded position means nothing here and the finding needs a fresh load in **this** transcript; what changed is that the other session's row is no longer destroyed to say so.
A transcript shorter than the recorded offset was rotated or truncated and is treated the same way.

Pruning on write is what keeps the file bounded now that it holds a row per session: a row survives only while its finding is still open and its transcript still exists, so a resolved finding and a session whose transcript is gone both drop out the next time anything writes.

**Residual: the concurrent write is narrowed, not eliminated.**
The sync is a read-modify-write finished by a single `mv`, so two sessions syncing in the same instant - which is exactly when both are missing a row, right after a finding appears - can still lose the later writer's rows to the winner's rename.
The guard re-reads after the rename and syncs once more when its own row is missing, which collapses the window to a retry rather than closing it.
The residual runs in both directions, and both are stated because the second one weakens the gate rather than the fleet.

- **Toward a spurious deny.** The losing writer's own row is gone, so its next call stamps first sight at the current size and a load it genuinely made stops counting. One extra load recovers it, against the indefinite denial the identity-only key produced.
- **Toward a spent load being refunded.** The sync copies every other session's rows verbatim from the snapshot it read before its own rename, so a rename that lands late writes back the winner's **pre-consumption** offset. The re-read only checks that its own row is present, never that another session's row still carries the offset that session consumed, so no retry fires and one load buys a second decision.

Both need the same two-concurrent-sessions precondition inside the same single-rename window, so the practical exposure is equally small, and the retry is deliberately not widened to chase the second direction.
`test_two_sessions_keep_their_own_first_sight` is strictly sequential and cannot see either case; the retry is asserted only by construction.

### Why every tool call observes

The guard runs its observation pass on **every** tool call, including calls it could never deny, and this is not incidental.

The ledger records where in the transcript a finding was first seen.
If it were written only on a gated call, first sight would be the `AskUserQuestion` or steer itself, which in a correct session is already **after** firstmate loaded the skill in response to the finding.
The guard would then deny work that was done right, on the very first attempt, every time.

Observing on every call moves first sight to the first tool call after the finding appeared, which precedes any load made in response to it.

Because that pass runs on every tool call, its cost is part of the contract, so the measured numbers belong here rather than the mechanism alone.
Timed against the shipped guard through its real stdin transport, in a home of twelve tasks with nine-line status files:

| Home state | Cost per tool call |
| --- | --- |
| no finding anywhere, ever | 16 ms |
| one long-resolved finding | 50 ms |
| one finding open | 52 ms |
| two findings open | 74 ms |
| four findings open | 113 ms |

The operational consequence, stated plainly: an ordinary armed morning with three or four findings open adds roughly 100 ms to every tool call of the primary session, for as long as the captain has not answered.
Some cost is paid even when nothing is currently open, because status files are append-only and a resolved finding leaves its opening line in place, so the per-file grep keeps matching for that task's whole life.
What keeps this a cost rather than a leak is that `bin/fm-teardown.sh` removes a task's status file at teardown, so the set is bounded by live tasks rather than growing forever.

Two greps carry the mechanism.
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
`test_fail_safe_states_allow_silently` and `test_missing_steer_classifier_allows_silently` assert every entry in that list, and none of them can pass by proving the fixture never denied.
The baselines come in two shapes, and the difference is worth stating so a reader checking the tests is not surprised.
The five cases that mutate only the payload or the transcript path - absent, unreadable, garbled, and shapeless transcripts, and malformed stdin - reuse one shared fixture, whose single `AskUserQuestion` deny is asserted once at the top before any of them run.
Every case that builds a fresh home and mutates it carries its own baseline deny immediately before the mutation, and the missing-Node case's baseline is a `Bash` steer deny rather than an `AskUserQuestion` one, because a missing Node disarms the steer route alone.

Three entries depend on file permissions the superuser ignores: under a root CI container `chmod 000` and `chmod 555` do not bite, and those cases print an explicit `skip` line naming the uid rather than passing green having asserted nothing.

The gate also has a cost in the other direction, paid while it is armed rather than while it is disarmed, and it is real enough to state next to these.
Three denials fall out of the design rather than out of a policy breach, and all three hold on every task while any one finding is open anywhere in this home:

- every use of `bin/fm-send.sh`, including the non-decision nudges recorded under "Routes this guard does not cover";
- every command carrying the steer path that the walk cannot place, which is the read-only class enumerated under "What the escalation costs" - a guarded existence check, a loop over the path, and inspection behind `nice`, `stdbuf`, `ssh`, or `watch`;
- every `AskUserQuestion`, whatever it is about. The guard routes on the tool name alone and has no notion of a question's subject, so a question with nothing to do with any finding is denied exactly like an escalation of one.

Fail-safe governs what the guard does when it cannot read something; the escalation rule under "The escalation rule" governs what it does when it can read a command but cannot place a steer token in it, and there the tie breaks toward denying.

The remedy differs between the first two classes and the third, and the difference is the whole of the arithmetic.
The first two are cleared by loading the skill **once**, however many findings the deny names, and stay cleared: neither class consumes, so a permitted steer spends nothing and a permitted read-only command in the escalation class spends nothing either.
The third costs **one load per call**: an allowed `AskUserQuestion` spends the proof of every open finding, so the next `AskUserQuestion` denies even when the same single finding is the only thing open, and a steer that follows an escalation needs its own load too.
That is the price of the batch property on the route where it earns its cost, and it is charged per question rather than per finding because the guard cannot tell the two apart.

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

**The dated result below is scoped, and does not cover the file as it stands.**

Recorded result on 2026-08-25, claude 2.1.241: all three cases passed **as the file was written that day**.
That run predates the attempt assertions described in the paragraph above: the second PreToolUse hook, the `assert_steer_attempted` call in all three cases, and the later tightening of its predicate were all added afterwards, and the lab home now also copies two policy modules the recorded run never had.
So the attempt assertions themselves have never been exercised against a real harness, and per the rule directly above, the date must not be trusted until `FM_CLAUDE_LIVE_E2E=1` is run again.

The open question that re-run has to settle is specific, so whoever runs it knows what to look for.
Cases A and C assert an attempt on a call the gate **denies**, which requires Claude Code to run the second PreToolUse hook even after the first returns exit 2.
Whether the harness runs the whole hook list or short-circuits on a deny is unverified.
If it short-circuits, those two cases fail at `never attempted <bin/fm-send.sh rac196>` rather than passing, and the fix is in the lab wiring, not in the guard.

The AskUserQuestion route is not exercised by that guard, because headless `claude -p` does not expose the tool.
Its live evidence is the interactive capture above; the portable regression pins the tool-name classification.

### Regression coverage

`tests/fm-ask-user-pretool-check.test.sh` is the portable regression, run by CI with no harness.
It pins both routes, the per-finding gate including the stale-load case, the reopened-key case, and the batch case, the steer route's non-consumption, the fail-safe family against a baseline that is proven to deny, the primary-home scoping, the structural-proof rule against this guard's own deny text, all three transport entry forms, the escape hatch, and the Claude wiring itself.
It also pins the steer classifier from the outside, through the guard rather than against the policy module: inspecting `bin/fm-send.sh` allows, invoking it denies from every shell position listed above, a steer the walk cannot place denies without re-denying inspection, and removing the policy module disarms the steer route alone.
