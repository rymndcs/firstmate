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
The captain's own bar: *"a 1-2 sentence description should be max for a very complicated
change"* and *"the what changed section is totally unnecessary, you can just define a
bulleted list of what changed - the code should speak for itself."*
A result proportional in length to the intent has failed, no matter how well-organized.

## What stays untouched

Never touch a no-mistakes-generated section below the top summary (`Risk Assessment`,
`Testing`, `Pipeline`, `Document`, `Lint`, `Push`, or any other pipeline step report),
including any collapsed `<details>` evidence block inside them - those carry proof a
reviewer may need and are not the complaint.
This skill only replaces the lead section - the part a reader meets before scrolling - and
never introduces a `<details>` block of its own: test output, screenshots, and narrowing
transcripts belong in CI and the pipeline's own run, not in a block this skill writes.

## Writing the summary

Read the full intent (the exact string passed to `--intent`, or the equivalent accepted
requirement set for a direct-PR task) and the actual diff or commits.
Write exactly two parts, nothing else:

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
not raw markdown - decode it before editing rather than pasting the escaped text back, for
example:
```sh
gh-axi pr view <n> --full > /tmp/pr-view.txt
python3 -c "
import re
raw = open('/tmp/pr-view.txt').read()
m = re.search(r'^  body: \"(.*)\"$', raw, re.S | re.M)
print(m.group(1).encode().decode('unicode_escape'))
" > /tmp/pr-body.md
```
Replace only the lead `## Intent` section in that decoded body with the new summary, leave
every section from `## Risk Assessment` onward byte-identical, and push the merged body back
with `gh-axi pr edit <n> --body-file <path>`.
This still lands before any human reads the PR - the captain's actual requirement - even
though it is "before reading" rather than a literal "before posting" hook, because no such
hook exists on this path.
