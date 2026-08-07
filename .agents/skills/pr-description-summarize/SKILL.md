---
name: pr-description-summarize
description: >-
  Agent-only procedure for turning a ship task's full intent into a short human-facing PR
  description instead of publishing the raw intent verbatim.
  Use for a direct-PR task immediately before running `gh-axi pr create`, and for a
  no-mistakes task immediately after the pipeline opens the PR but before reporting
  `done: PR <url> checks green`.
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

This skill produces the replacement: a short, human-facing summary that stands in for that
blob at the top of the PR.
It is a summary in place of the blob, not a second blob with a nicer heading - if the
result is proportional in length to the intent, it has failed.

## What stays untouched

Never touch a collapsed `<details>` evidence block, and never touch a no-mistakes-generated
section below the top summary (`Risk Assessment`, `Testing`, `Pipeline`, `Document`,
`Lint`, `Push`, or any other pipeline step report).
Those carry proof a reviewer may need and are not the complaint.
This skill only replaces the lead section - the part a reader meets before scrolling.

## Writing the summary

Read the full intent (the exact string passed to `--intent`, or the equivalent accepted
requirement set for a direct-PR task) and the actual diff or commits.
Write two sections, in this order, using this repo's own PR style as the shape to match
(`## Why` then `## What Changed` - `gh pr view <n> --repo rymndcs/racingr-wms --json body`
on a merged PR shows worked examples):

1. **`## Why`** - the situation before the change, in enough words that a reader who has
   never seen the intent understands what problem existed and what the change does about
   it.
   Fold in, as prose rather than a checklist: constraints that were deliberate rather than
   oversights, and anything that changed on purpose that a reader would otherwise flag as a
   mistake (an unrelated-looking file touched, a behavior altered as a side effect, scope
   deliberately held back for a later PR).
   This is the section that answers "why does this PR look the way it does."
2. **`## What Changed`** - what the change actually does, oriented around the reader's
   next action (what to look at, what changed and why it's structured that way), not a
   diff-shaped file-by-file list.
   A short bulleted list is fine when the change has genuinely separate pieces; prose is
   fine when it does not.

Target a few short paragraphs and, where useful, a short bulleted list per section - not a
paragraph per accepted requirement.
Every requirement in the intent still has to be satisfied by the work; it does not follow
that every requirement earns its own sentence in the description.
Compress ruthlessly: keep what changes the reader's understanding of the diff or their
review priorities, drop restated acceptance criteria, scaffold boilerplate, and process
narration (status protocol, delivery mode, escalation mechanics) that the intent had to
carry for the pipeline but that means nothing to a PR reader.

If the intent's own exclusions or omissions are substantial and structured (for example,
one reason per skipped item across many files), a collapsed `<details>` block under
`## What Changed` is the right place for that table - it is exactly the kind of evidence
this skill leaves alone once written, not something to inline into the prose.

## Applying it, per delivery mode

**direct-PR**: write the summary before calling `gh-axi pr create`, and pass it directly as
`--body`/`--body-file`.
There is no pipeline-generated body to preserve underneath it; do not paste the brief or
the accepted-requirement list into the body at any point.
This is a literal pre-post hook - the summary is the first and only body the PR ever gets.

**no-mistakes**: the pipeline opens the PR itself once a run reaches the CI-ready point, and
`no-mistakes axi run --help`'s current mechanics are the authority for exactly when that
happens - this skill does not restate them.
There is no reachable point before the pipeline posts, so the point that matters is
immediately after: once the PR exists and before reporting `done: PR <url> checks green`,
fetch the current body (`gh-axi pr view <n> --full`), replace only the lead `## Intent`
section with the `## Why` / `## What Changed` summary, leave every section from
`## Risk Assessment` onward byte-identical, and push the merged body back with
`gh-axi pr edit <n> --body-file <path>`.
This still lands before any human reads the PR - the captain's actual requirement - even
though it is "before reading" rather than a literal "before posting" hook, because no such
hook exists on this path.
