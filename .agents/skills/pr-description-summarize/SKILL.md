---
name: pr-description-summarize
description: >-
  Agent-only procedure for turning a ship task's full intent into a short human-facing PR
  description instead of publishing the raw intent verbatim.
  Use for a direct-PR task immediately before running `gh-axi pr create`, and for a
  no-mistakes task once the run reaches the CI-ready `checks-passed` outcome but before
  reporting `done: PR <url> checks green`.
user-invocable: false
metadata:
  internal: true
---

# pr-description-summarize

## The defect this fixes

`no-mistakes axi run --intent` deliberately receives the full intent: every accepted
requirement, clarification, constraint, exclusion, and supersession, because the pipeline's
reviewers check the work against exactly that text.
That instruction is correct and this skill does not touch it - the string handed to
`--intent` stays exhaustive.

The defect is downstream: the pipeline's PR-body assembler publishes that same exhaustive
text verbatim as a `## Intent` section, which is the first thing a human reader meets.
A direct-PR worker can make the identical mistake by pasting the brief or the accepted
requirement list into `gh-axi pr create --body`.
Either way the reader gets an unreadable blob instead of a description.

This skill produces the replacement.
The captain's own bar, in her own words: *"a 1-2 sentence description should be max
for a very complicated change"*; *"the what changed section is totally unnecessary, you can
just define a bulleted list of what changed - the code should speak for itself"*; and
*"Testing is also totally not needed ... the PR description should be for humans. I can just
look at the test file changes if I want to know how you tested the code."*
A result proportional in length to the intent has failed, no matter how well-organized, and
so has one that reintroduces a what-changed narrative or a testing report under another name.

## What stays untouched

Exactly one section: the no-mistakes-generated `## Pipeline` block - the per-step audit
trail (intent, rebase, review, test, document, lint, push), including every collapsed
`<details>` evidence block inside it. Leave it byte-identical.

That exception is provisional. It survives because no captain decision has been taken on it
yet, not because an audit trail earns a place in a human-facing description; a later decision
may remove it too, and if it does, this section is what changes. Do not read it as permanent.

Every other section the pipeline generates - `## Intent`, `## What Changed`,
`## Risk Assessment`, `## Testing`, and any collapsed `<details>` evidence block under any of
them - is replaced along with the lead section, not preserved beneath it. The body is the
summary; it is not a replacement window inside a larger document.

This skill also never introduces a `<details>` block of its own: test output, screenshots,
and narrowing transcripts belong in CI and the pipeline's own run, not in a block this skill
writes.

### Why `## Pipeline` is the safe one to leave

Leaving a section alone is only safe if nothing rewrites the body after the edit lands.
Evidence, verified against the installed binary:

- `nm ~/.local/bin/no-mistakes` shows `buildPipelineSection` only as a method on `(*PRStep)`,
  never on `(*CIStep)`.
- `objdump -d` across the CI step's address range (`(*CIStep).Execute` through
  `(*CIStep).pushUpdatedHeadSHA`) contains no direct call to `buildPipelineSection`,
  `assemblePRBody`, or `buildPRBody`.
- A real merged PR in this repo (rymndcs/firstmate#4, 49,779 chars) carries a `## Pipeline`
  block with subsections for intent/Rebase/Review/Test/Document/Lint/Push and no CI
  subsection - nothing appended to it after the PR opened.

Static symbol and disassembly inspection cannot rule out an interface or indirect call, so
treat this as well-evidenced rather than proven: after pushing the new body, re-read it and
confirm the edit stuck.

## Writing the summary

Read the full intent (the exact string passed to `--intent`, or the equivalent accepted
requirement set for a direct-PR task) and the actual diff or commits.
Write exactly two parts, nothing else - and those two parts are the whole body a reader
gets, not a lead paragraph above a what-changed section or a testing report:

1. **One to two sentences.** State what the change does. That is the ceiling for the most
   complicated change in the repository, not a target that grows with difficulty - a
   seventy-file rollout gets the same one or two sentences as a one-line fix. The reader
   gets everything else from the diff and the bullets below.
2. **A plain bulleted list of what changed.** One line per change, in the reader's own
   terms, telling them where to look - not restating the diff in prose, not a sub-narrative
   per bullet.
   A deliberate constraint, an intentional exclusion, or a change that would otherwise read
   as a mistake still gets exactly one bullet, not a paragraph.
   Every requirement in the intent still has to be satisfied by the work; it does not follow
   that every requirement earns its own line here - fold siblings into one bullet when they
   are the same kind of change.

Compress ruthlessly.
Drop restated acceptance criteria, scaffold boilerplate, and process narration (status
protocol, delivery mode, escalation mechanics) that the intent had to carry for the pipeline
but that means nothing to a PR reader.
If something genuinely cannot be conveyed inside that budget, say so plainly in your task
report rather than quietly widening the description to fit it in.

For the current-shape calibration, read a few recently-merged PRs in this repo with
`gh-axi pr view <n> --full`; do not assume any specific PR is still representative, since
this shape has been tightened before and may be again.

## Applying it, per delivery mode

**direct-PR**: write the summary before calling `gh-axi pr create`, and pass it directly as
`--body`/`--body-file`.
There is no pipeline-generated body to preserve underneath it; do not paste the brief or
the accepted-requirement list into the body at any point.
This is a literal pre-post hook - the summary is the first and only body the PR ever gets.

**no-mistakes**: the pipeline opens the PR itself and keeps re-assembling its body as later
steps (test, document, lint, push, ci) report in, so there is no reachable point before the
pipeline posts, and editing right after PR creation risks the pipeline's own next step
silently overwriting the edit.
Apply the edit once, at the last point the mechanics above return `outcome: checks-passed`
and before reporting `done: PR <url> checks green` - by then the pipeline has finished
assembling every section it owns and only its background merge monitor remains, which does
not rewrite the body.

To read the pipeline-assembled body, `gh-axi pr view <n> --full` prints it as a single
double-quoted, backslash-escaped scalar (e.g. `body: "## Why\n\nLinear issues are ..."`),
not raw markdown - decode it before editing rather than pasting the escaped text back:
```sh
gh-axi pr view <n> --full > /tmp/pr-view.txt
python3 - <<'PY'
import json
raw = open('/tmp/pr-view.txt', encoding='utf-8').read()
prefix = '\n  body: "'
start = raw.index(prefix) + len(prefix)   # first char inside the scalar
i = start
while raw[i] != '"':                      # walk to the true closing quote
    i += 2 if raw[i] == '\\' else 1       # a backslash escapes the next char
body = json.loads(raw[start - 1:i + 1])   # decode the whole quoted scalar
open('/tmp/pr-body.md', 'w', encoding='utf-8').write(body)
PY
```
Two details in that recipe are load-bearing, both learned the hard way:

- **Find the closing quote by walking, not by matching.** A regex over the file is greedy
  and can run past the body field into a later TOON field that happens to end in a quote,
  and a body containing an escaped `\"` (real PR bodies do) defeats a naive
  shortest-match too. Locating the exact `  body: "` prefix and stepping character by
  character, skipping the char after any backslash, stops at the body's own closing quote.
- **Decode with `json.loads`, not `unicode_escape`.** The escaping is JSON-compatible, so
  `json.loads` handles every standard escape including `\uXXXX` with no double-encoding
  round trip. `unicode_escape` latin-1-decodes UTF-8 bytes and turns every em dash, arrow,
  and check mark into mojibake - which would silently corrupt the one section that has to
  stay byte-identical. Read and write with an explicit `utf-8` encoding too, so a C locale
  cannot fail or mangle non-ASCII.

Replace everything from the lead `## Intent` heading up to (not including) `## Pipeline`
with the new summary - `## Intent`, `## What Changed`, `## Risk Assessment` and `## Testing`
all go - keep `## Pipeline` and everything in it byte-identical, and push the merged body
back with `gh-axi pr edit <n> --body-file <path>`.
If the body has no `## Pipeline` section, the new summary is the entire body.
This still lands before any human reads the PR - the captain's actual requirement - even
though it is "before reading" rather than a literal "before posting" hook, because no such
hook exists on this path.
