#!/usr/bin/env bash
# Behavior tests for bin/fm-standing-knowledge.sh and the lifecycle enforcement
# built on it.
#
# The point of the mechanism is that a standing rule reaches the moment it
# governs without an agent choosing to read anything, so every test here drives a
# real executable and reads what an operator would actually see. Nothing asserts
# the source bytes of any script.
#
# The captain's real data/captain.md, data/captain-shared.md, data/learnings.md
# and data/projects.md are private, gitignored, and never consulted: every case
# builds its own fixture knowledge files under an isolated FM_HOME, so a change
# to the captain's notes can neither pass nor fail this suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KNOW="$ROOT/bin/fm-standing-knowledge.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-standing-knowledge)

# --- fixture knowledge files -------------------------------------------------

# A data dir carrying the whole knowledge set: a tagged captain file, a tagged
# shared-captain file, and a tagged learnings file. The exact prose is fixture
# text so the assertions below pin verbatim quoting rather than any real rule.
make_data() {  # <name>
  local name=$1 data="$TMP_ROOT/$1/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## Pick the runtime every time (fixture rule, 2026-01-01)
<!-- fm-moment: spawn -->

The captain picks the runtime. Firstmate never picks it alone.

### A sub-heading that travels with its parent

Indented body:

- a bullet with **bold** and `code`
- a second bullet

## Tear down once the PR exists (fixture rule, 2026-01-02)
<!-- fm-moment: pr-ready teardown -->

The completion point is PR creation, not merge.

## A rule that governs no lifecycle moment (fixture, 2026-01-03)

This section is untagged and must never be printed at any moment.

## Land it when it is green (fixture rule, 2026-01-04)
<!-- fm-moment: merge -->

Merge green work; never merge red work.
MD
  cat > "$data/captain-shared.md" <<'MD'
# Shared captain preferences

## Name the workspace before dispatching (fixture shared rule, 2026-01-07)
<!-- fm-moment: spawn -->

Shared preference: every crew launch states which workspace it lands in.

## Say who may land it (fixture shared rule, 2026-01-08)
<!-- fm-moment: pr-ready merge -->

Shared preference: merge authority is stated, never assumed.
MD
  cat > "$data/learnings.md" <<'MD'
# Learnings

## the shared daemon dies if you restart it (fixture learning, 2026-01-05)
<!-- fm-moment: teardown -->

Never restart the shared daemon during cleanup.

## define the task before dispatching it (fixture learning, 2026-01-06)
<!-- fm-moment: intake -->

State what changes and how anyone tells whether it worked.
MD
  printf '%s\n' "$data"
}

run_know() {  # <data-dir> <args...>
  local data=$1
  shift
  FM_DATA_OVERRIDE="$data" "$KNOW" "$@" 2>&1
}

# --- resolver ----------------------------------------------------------------

test_resolver_returns_the_verbatim_tagged_section() {
  local data out
  data=$(make_data verbatim)
  out=$(run_know "$data" spawn)
  assert_contains "$out" '## Pick the runtime every time (fixture rule, 2026-01-01)' \
    'the tagged section heading must be quoted'
  assert_contains "$out" 'The captain picks the runtime. Firstmate never picks it alone.' \
    'the tagged section body must be quoted'
  assert_contains "$out" '### A sub-heading that travels with its parent' \
    'a subsection must travel with its parent section'
  # shellcheck disable=SC2016 # literal Markdown inline code, not a substitution
  assert_contains "$out" '- a bullet with **bold** and `code`' \
    'the body must be quoted byte for byte, markup included'
  assert_contains "$out" '- a second bullet' 'the whole body must be quoted, not the first lines'
  assert_contains "$out" 'data/captain.md' 'the owning file must be named'
  pass 'resolver returns the verbatim text of a tagged section'
}

test_resolver_skips_sections_tagged_for_other_moments() {
  local data out
  data=$(make_data other-moments)
  out=$(run_know "$data" spawn)
  assert_not_contains "$out" 'Tear down once the PR exists' \
    'a section tagged for another moment must not print'
  assert_not_contains "$out" 'Merge green work' \
    'a section tagged for another moment must not print'
  pass 'resolver prints only the sections tagged for the requested moment'
}

test_resolver_never_prints_an_untagged_section() {
  local data moment out
  data=$(make_data untagged-section)
  for moment in $("$KNOW" --moments); do
    out=$(run_know "$data" "$moment")
    assert_not_contains "$out" 'A rule that governs no lifecycle moment' \
      "an untagged section must not print at $moment"
  done
  pass 'resolver never prints an untagged section at any moment'
}

test_resolver_withholds_the_marker_from_the_quoted_text() {
  local data out
  data=$(make_data marker-hidden)
  out=$(run_know "$data" spawn)
  assert_contains "$out" '## Pick the runtime every time (fixture rule, 2026-01-01)' \
    'the section must have printed at all'
  assert_not_contains "$out" 'fm-moment' \
    'the machine-readable marker is metadata and must not reach the quoted text'
  pass 'resolver withholds the lifecycle marker from the quoted text'
}

test_resolver_binds_one_section_at_several_moments() {
  local data pr_ready teardown
  data=$(make_data several-moments)
  pr_ready=$(run_know "$data" pr-ready)
  teardown=$(run_know "$data" teardown)
  assert_contains "$pr_ready" 'The completion point is PR creation, not merge.' \
    'a multi-moment section must print at its first moment'
  assert_contains "$teardown" 'The completion point is PR creation, not merge.' \
    'a multi-moment section must print at its second moment'
  pass 'resolver binds one section at every moment it is tagged with'
}

test_resolver_reads_both_knowledge_files() {
  local data teardown intake
  data=$(make_data both-files)
  teardown=$(run_know "$data" teardown)
  assert_contains "$teardown" 'Never restart the shared daemon during cleanup.' \
    'a learnings section must print at its moment'
  assert_contains "$teardown" 'data/learnings.md' 'the owning learnings file must be named'
  intake=$(run_know "$data" intake)
  assert_contains "$intake" 'State what changes and how anyone tells whether it worked.' \
    'the intake moment must resolve from data/learnings.md'
  pass 'resolver reads both knowledge files'
}

# The shared captain-preference file is main-authoritative and propagated
# read-only into every secondmate home, where a trimmed local captain.md means it
# is the only place the captain's preferences still live. It must resolve like
# any other knowledge file.
test_resolver_reads_the_shared_captain_file() {
  local data spawn merge
  data=$(make_data shared-captain)
  spawn=$(run_know "$data" spawn)
  assert_contains "$spawn" '## Name the workspace before dispatching (fixture shared rule, 2026-01-07)' \
    'a tagged shared-captain section must print at its moment'
  assert_contains "$spawn" 'Shared preference: every crew launch states which workspace it lands in.' \
    'the shared-captain body must be quoted verbatim'
  assert_contains "$spawn" 'data/captain-shared.md' \
    'the shared-captain section must be attributed to its owning file'
  assert_not_contains "$spawn" 'Shared preference: merge authority is stated, never assumed.' \
    'a shared-captain section tagged for other moments must not print at spawn'
  merge=$(run_know "$data" merge)
  assert_contains "$merge" 'Shared preference: merge authority is stated, never assumed.' \
    'a multi-moment shared-captain section must print at each moment it names'
  pass 'resolver reads the shared captain-preference file'
}

test_resolver_reports_an_absent_shared_captain_file() {
  local data out status
  # A home that has never been propagated to: captain-shared.md is simply not
  # there, which is the expected steady state and must degrade, not fail.
  data="$TMP_ROOT/no-shared/data"
  mkdir -p "$data"
  printf '# Captain preferences\n\n## Local rule\n<!-- fm-moment: spawn -->\n\nLocal body.\n' \
    > "$data/captain.md"
  printf '# Learnings\n\n## Local learning\n<!-- fm-moment: spawn -->\n\nLearned body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" spawn)
  status=$?
  expect_code 0 "$status" 'an absent shared captain file must not fail the resolver'
  assert_contains "$out" 'data/captain-shared.md is missing' \
    'the absent shared captain file must be named explicitly'
  assert_contains "$out" 'Local body.' 'the local captain file must still resolve'
  assert_contains "$out" 'Learned body.' 'the learnings file must still resolve'
  pass 'resolver reports an absent shared captain file and keeps resolving the rest'
}

# A tag naming a moment outside the known set binds nowhere, so the section it
# tags simply never prints. That is indistinguishable from a section left
# deliberately untagged unless it is reported, which is what this pins.
test_resolver_reports_an_unknown_moment_tag_in_the_data() {
  local data out status audit
  data="$TMP_ROOT/unknown-tag/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## A rule whose tag is misspelled (fixture, 2026-01-09)
<!-- fm-moment: pr_ready -->

This body binds at no moment because its tag names none.

## A correctly tagged rule (fixture, 2026-01-10)
<!-- fm-moment: spawn -->

Correct body.
MD
  printf '# Shared captain preferences\n\n## Shared\n<!-- fm-moment: spawn -->\n\nShared body.\n' \
    > "$data/captain-shared.md"
  printf '# Learnings\n\n## Learned\n<!-- fm-moment: spawn -->\n\nLearned body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" spawn)
  status=$?
  expect_code 0 "$status" 'an unknown moment in the data must not fail the resolver'
  assert_contains "$out" 'unknown lifecycle moment "pr_ready"' \
    'the offending token must be named exactly'
  assert_contains "$out" 'data/captain.md' 'the diagnostic must name the owning file'
  assert_contains "$out" '## A rule whose tag is misspelled (fixture, 2026-01-09)' \
    'the diagnostic must name the section the bad tag sits on'
  assert_contains "$out" 'Correct body.' \
    'a bad tag elsewhere in the file must not stop the well-tagged sections resolving'
  assert_not_contains "$out" 'This body binds at no moment because its tag names none.' \
    'a section whose tag names no known moment must still not print'
  audit=$(run_know "$data" --audit)
  assert_contains "$audit" 'unknown moment: pr_ready' \
    '--audit must mark an unknown tag rather than echo it back as ordinary'
  pass 'resolver reports a tag naming an unknown lifecycle moment, in emission and in --audit'
}

# The other way a hand-written marker binds nowhere: a stray blank line between
# a heading and its marker. The rule silently stops arriving at its lifecycle
# script, and the section reads exactly like one deliberately left untagged.
test_resolver_reports_a_marker_out_of_binding_position() {
  local data out status audit
  data="$TMP_ROOT/orphan-marker/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## A correctly tagged rule (fixture, 2026-01-11)
<!-- fm-moment: merge -->

Correct merge body.

## A rule whose marker slipped a line (fixture, 2026-01-12)

<!-- fm-moment: merge -->

This body binds at no moment because its marker is out of position.
MD
  printf '# Shared captain preferences\n\n## Shared\n<!-- fm-moment: merge -->\n\nShared body.\n' \
    > "$data/captain-shared.md"
  printf '# Learnings\n\n## Learned\n<!-- fm-moment: merge -->\n\nLearned body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" merge)
  status=$?
  expect_code 0 "$status" 'a misplaced marker must not fail the resolver'
  # shellcheck disable=SC2016 # literal Markdown heading syntax, not a substitution
  assert_contains "$out" 'not directly below a `## ` heading' \
    'the diagnostic must say what is actually wrong with the marker'
  assert_contains "$out" 'data/captain.md' 'the diagnostic must name the owning file'
  assert_contains "$out" '<!-- fm-moment: merge -->' 'the diagnostic must quote the marker it found'
  assert_contains "$out" '## A rule whose marker slipped a line (fixture, 2026-01-12)' \
    'the diagnostic must name the section the misplaced marker belongs to'
  assert_contains "$out" 'Correct merge body.' \
    'a misplaced marker elsewhere must not stop the well-placed sections resolving'
  assert_contains "$out" 'Learned body.' 'the other knowledge files must still resolve'
  assert_not_contains "$out" 'This body binds at no moment because its marker is out of position.' \
    'a section whose marker is out of position must still not print'
  audit=$(run_know "$data" --audit)
  assert_contains "$audit" 'orphaned-marker <!-- fm-moment: merge --> | ## A rule whose marker slipped a line (fixture, 2026-01-12)' \
    '--audit must distinguish an out-of-position marker from a deliberately untagged section'
  pass 'resolver reports a marker that sits out of binding position, in emission and in --audit'
}

# The third way: the marker is in position but hand-typed a character off. Only
# the exact spelling ever binds, so each of these unbinds its rule, and none of
# them may do so silently.
test_resolver_reports_a_marker_that_misses_the_exact_spelling() {
  local data out status audit spelling label body
  while IFS='|' read -r label spelling body; do
    [ -n "$label" ] || continue
    data="$TMP_ROOT/malformed-$label/data"
    mkdir -p "$data"
    {
      printf '# Captain preferences\n\n'
      printf '## A correctly tagged rule (fixture, 2026-01-13)\n<!-- fm-moment: merge -->\n\nCorrect merge body.\n\n'
      printf '## A rule whose marker is a character off (fixture, 2026-01-14)\n%s\n\n%s\n' "$spelling" "$body"
    } > "$data/captain.md"
    printf '# Shared captain preferences\n\n## Shared\n<!-- fm-moment: merge -->\n\nShared body.\n' \
      > "$data/captain-shared.md"
    printf '# Learnings\n\n## Learned\n<!-- fm-moment: merge -->\n\nLearned body.\n' \
      > "$data/learnings.md"
    out=$(run_know "$data" merge)
    status=$?
    expect_code 0 "$status" "$label: a malformed marker must not fail the resolver"
    assert_contains "$out" 'does not match the exact marker spelling' \
      "$label: the diagnostic must say what is actually wrong with the line"
    assert_contains "$out" 'data/captain.md' "$label: the diagnostic must name the owning file"
    assert_contains "$out" "$spelling" "$label: the diagnostic must quote the line it found"
    assert_contains "$out" '## A rule whose marker is a character off (fixture, 2026-01-14)' \
      "$label: the diagnostic must name the section the bad line belongs to"
    assert_contains "$out" 'Correct merge body.' \
      "$label: a malformed marker elsewhere must not stop the well-formed sections resolving"
    assert_contains "$out" 'Learned body.' "$label: the other knowledge files must still resolve"
    assert_not_contains "$out" "$body" \
      "$label: only the exact spelling binds, so this section must still not print"
    audit=$(run_know "$data" --audit)
    assert_contains "$audit" "malformed-marker $spelling | ## A rule whose marker is a character off (fixture, 2026-01-14)" \
      "$label: --audit must distinguish a malformed marker from a deliberately untagged section"
  done <<'ROWS'
no-space-after-open|<!--fm-moment: merge -->|Body A binds nowhere.
trailing-space|<!-- fm-moment: merge --> |Body B binds nowhere.
leading-indent|  <!-- fm-moment: merge -->|Body C binds nowhere.
ROWS
  pass 'resolver reports a marker that misses the exact spelling, in emission and in --audit'
}

# The fourth way: the marker is in position and well formed but names nothing,
# which is what deleting the last moment out of one leaves behind.
test_resolver_reports_a_marker_naming_no_moment_at_all() {
  local data out status audit
  data="$TMP_ROOT/empty-marker/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## A correctly tagged rule (fixture, 2026-01-17)
<!-- fm-moment: merge -->

Correct merge body.

## A rule whose marker names nothing (fixture, 2026-01-18)
<!-- fm-moment: -->

This body binds at no moment because its marker names none.
MD
  printf '# Shared captain preferences\n\n## Shared\n<!-- fm-moment: merge -->\n\nShared body.\n' \
    > "$data/captain-shared.md"
  printf '# Learnings\n\n## Learned\n<!-- fm-moment: merge -->\n\nLearned body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" merge)
  status=$?
  expect_code 0 "$status" 'an empty marker must not fail the resolver'
  assert_contains "$out" 'naming no lifecycle moment at all' \
    'the diagnostic must say what is actually wrong with the marker'
  assert_contains "$out" 'data/captain.md' 'the diagnostic must name the owning file'
  assert_contains "$out" '## A rule whose marker names nothing (fixture, 2026-01-18)' \
    'the diagnostic must name the section the empty marker belongs to'
  assert_contains "$out" 'Correct merge body.' \
    'an empty marker elsewhere must not stop the well-formed sections resolving'
  assert_not_contains "$out" 'This body binds at no moment because its marker names none.' \
    'a section whose marker names no moment must still not print'
  audit=$(run_know "$data" --audit)
  assert_contains "$audit" 'empty-marker <!-- fm-moment: --> | ## A rule whose marker names nothing (fixture, 2026-01-18)' \
    '--audit must label an empty marker rather than render a blank tag field'
  pass 'resolver reports a marker naming no lifecycle moment, in emission and in --audit'
}

# A knowledge file may document the tag format itself. A worked example in a
# section BODY is not a defective marker, and claiming it is would print a false
# "this binds nowhere" directly above rules that are in fact binding.
test_resolver_leaves_documented_marker_examples_alone() {
  local data out status audit
  data="$TMP_ROOT/marker-examples/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## How the lifecycle tags work (fixture, 2026-01-19)
<!-- fm-moment: merge -->

Write the marker as:

    <!-- fm-moment: spawn -->

on the line directly under the heading.
MD
  cat > "$data/captain-shared.md" <<'MD'
# Shared captain preferences

## How the tags are written down (fixture, 2026-01-20)
<!-- fm-moment: merge -->

A fenced example:

```markdown
<!-- fm-moment: spawn -->
<!--fm-moment: teardown -->
```

That is the shape.
MD
  printf '# Learnings\n\n## Learned\n<!-- fm-moment: merge -->\n\nLearned body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" merge)
  status=$?
  expect_code 0 "$status" 'a documented example must not fail the resolver'
  assert_not_contains "$out" 'binds nowhere' \
    'a marker example in a section body must not be reported as a defective marker'
  assert_contains "$out" '## How the lifecycle tags work (fixture, 2026-01-19)' \
    'the indented-example section must still bind and print'
  assert_contains "$out" '## How the tags are written down (fixture, 2026-01-20)' \
    'the fenced-example section must still bind and print'
  assert_contains "$out" 'Learned body.' 'the other knowledge files must still resolve'
  audit=$(run_know "$data" --audit)
  assert_not_contains "$audit" 'malformed-marker' \
    '--audit must not call a documented example a malformed marker'
  assert_contains "$audit" 'merge | ## How the lifecycle tags work (fixture, 2026-01-19)' \
    '--audit must report the documenting section by its own real tag'
  pass 'resolver leaves a knowledge file its own worked marker examples'
}

# The two shapes a documenting file actually takes that the body-example case
# above cannot reach: a flush-left example marker in ordinary prose, and a
# nested fence, which is the only way to show a fenced example of a fence.
test_resolver_leaves_flush_left_and_nested_fence_examples_alone() {
  local data out status audit
  data="$TMP_ROOT/marker-examples-hard/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## How the tags are written (fixture, 2026-01-21)
<!-- fm-moment: merge -->

Write the marker as:

<!-- fm-moment: spawn -->

directly under the heading.
MD
  cat > "$data/captain-shared.md" <<'MD'
# Shared captain preferences

## How a fenced example is shown (fixture, 2026-01-22)
<!-- fm-moment: merge -->

To show a fenced example of a fence:

````markdown
```
<!-- fm-moment: spawn -->
```
````

That is the shape.
MD
  printf '# Learnings\n\n## Learned\n<!-- fm-moment: merge -->\n\nLearned body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" merge)
  status=$?
  expect_code 0 "$status" 'a documented example must not fail the resolver'
  assert_not_contains "$out" 'binds nowhere' \
    'neither a flush-left nor a nested-fence example may be reported as defective'
  assert_contains "$out" '## How the tags are written (fixture, 2026-01-21)' \
    'the flush-left-example section must still bind and print'
  assert_contains "$out" 'directly under the heading.' \
    'the flush-left-example section must print in full'
  assert_contains "$out" '## How a fenced example is shown (fixture, 2026-01-22)' \
    'the nested-fence section must still bind and print'
  assert_contains "$out" 'That is the shape.' 'the nested-fence section must print in full'
  audit=$(run_know "$data" --audit)
  assert_not_contains "$audit" 'orphaned-marker' \
    '--audit must not call a documented example an orphaned marker'
  assert_not_contains "$audit" 'malformed-marker' \
    '--audit must not call a documented example a malformed marker'
  pass 'resolver leaves flush-left and nested-fence marker examples alone'
}

# A fenced block is content, never structure. A `## ` line inside one must not
# open a section - which would quote text the captain never wrote as a rule - and
# must not close the section it sits in, which would truncate a real rule.
test_fenced_headings_neither_fabricate_a_rule_nor_truncate_one() {
  local data out status audit
  data="$TMP_ROOT/fenced-heading/data"
  mkdir -p "$data"
  cat > "$data/captain.md" <<'MD'
# Captain preferences

## How a tagged section looks (fixture, 2026-01-23)
<!-- fm-moment: spawn -->

A whole tagged section reads:

```markdown
## Some rule the captain never wrote
<!-- fm-moment: spawn -->

Fabricated body that must never be quoted as a rule.
```

That is the shape.

## A real rule with a fenced heading in it (fixture, 2026-01-24)
<!-- fm-moment: merge -->

Step one.

```md
## Not a heading, just an example
```

Step two, which is part of the same rule.
MD
  printf '# Shared captain preferences\n\n## Shared\n<!-- fm-moment: merge -->\n\nShared body.\n' \
    > "$data/captain-shared.md"
  printf '# Learnings\n\n## Learned\n<!-- fm-moment: merge -->\n\nLearned body.\n' \
    > "$data/learnings.md"

  out=$(run_know "$data" spawn)
  status=$?
  expect_code 0 "$status" 'a fenced heading must not fail the resolver'
  assert_contains "$out" '## How a tagged section looks (fixture, 2026-01-23)' \
    'the documenting section must bind at its own moment'
  assert_contains "$out" '## Some rule the captain never wrote' \
    'the fenced example must be quoted verbatim inside its owning section'
  assert_contains "$out" 'That is the shape.' \
    'the documenting section must print past its fenced example'
  assert_not_contains "$out" '[data/captain.md]
## Some rule the captain never wrote' \
    'a fenced heading must never be quoted as a section of its own'

  out=$(run_know "$data" merge)
  assert_contains "$out" '## A real rule with a fenced heading in it (fixture, 2026-01-24)' \
    'the real merge rule must bind'
  assert_contains "$out" 'Step one.' 'the rule must print from its start'
  assert_contains "$out" '## Not a heading, just an example' \
    'a fenced heading inside a rule body must be quoted verbatim'
  assert_contains "$out" 'Step two, which is part of the same rule.' \
    'a fenced heading must not truncate the rule it sits in'
  assert_not_contains "$out" 'Fabricated body that must never be quoted as a rule.' \
    'a fenced example tagged for another moment must not leak into this one'

  # --audit is the surface a reader is told to trust, so it must name exactly the
  # sections that bind - no phantom section for a fenced heading.
  audit=$(run_know "$data" --audit)
  assert_contains "$audit" 'spawn | ## How a tagged section looks (fixture, 2026-01-23)' \
    '--audit must report the documenting section by its real tag'
  assert_contains "$audit" 'merge | ## A real rule with a fenced heading in it (fixture, 2026-01-24)' \
    '--audit must report the real merge rule by its real tag'
  assert_not_contains "$audit" '## Some rule the captain never wrote' \
    '--audit must not invent a section for a fenced heading'
  assert_not_contains "$audit" '## Not a heading, just an example' \
    '--audit must not invent a section for a fenced heading in a rule body'
  assert_not_contains "$audit" 'binds nowhere' \
    '--audit must report no defect for a file whose fences are examples'
  pass 'a fenced heading neither fabricates a section nor truncates the one it sits in'
}

# Everything between the banner lines is the owning files' own words. A
# diagnostic landing under the last line of a quoted rule would read as part of
# that rule, and an absent data/captain-shared.md makes that the steady state.
test_diagnostics_print_outside_the_verbatim_banner() {
  local data out banner_region
  data="$TMP_ROOT/banner-purity/data"
  mkdir -p "$data"
  printf '# Captain preferences\n\n## A tagged rule (fixture, 2026-01-15)\n<!-- fm-moment: merge -->\n\nCaptain merge body.\n' \
    > "$data/captain.md"
  printf '# Learnings\n\n## A tagged learning (fixture, 2026-01-16)\n<!-- fm-moment: merge -->\n\nLearned merge body.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" merge)
  assert_contains "$out" 'data/captain-shared.md is missing' \
    'the absent shared file must still be reported, not suppressed'
  assert_contains "$out" 'Captain merge body.' 'the first file must still resolve'
  assert_contains "$out" 'Learned merge body.' 'the last file must still resolve in the same order'
  banner_region=$(printf '%s\n' "$out" | sed -n '/^--- standing knowledge: merge ---$/,/^--- end standing knowledge: merge ---$/p')
  [ -n "$banner_region" ] || fail 'the banner must have opened at all'
  case "$banner_region" in
    *standing-knowledge:*)
      fail "a diagnostic landed inside the verbatim banner: $banner_region"
      ;;
  esac
  printf '%s\n' "$banner_region" | grep -Fq 'Captain merge body.' \
    || fail 'the banner must still carry the quoted rules it frames'
  pass 'file diagnostics print outside the verbatim banner, which carries only quoted text'
}

# The distinction has to cut both ways: a section with no marker anywhere is
# still reported as plainly untagged, not as a marker slip.
test_audit_still_calls_a_deliberately_untagged_section_untagged() {
  local data audit
  data=$(make_data audit-untagged)
  audit=$(run_know "$data" --audit)
  assert_contains "$audit" 'untagged | ## A rule that governs no lifecycle moment (fixture, 2026-01-03)' \
    'a section carrying no marker at all must still audit as plainly untagged'
  assert_not_contains "$audit" 'orphaned-marker' \
    'a knowledge set with every marker in position must report no orphaned marker'
  pass 'audit still reports a section with no marker at all as plainly untagged'
}

test_resolver_prints_nothing_when_no_section_binds() {
  local data out status
  # Every knowledge file is present and tagged, so "prints nothing" is tested
  # against a complete set rather than against files that are merely absent.
  data="$TMP_ROOT/empty-moment/data"
  mkdir -p "$data"
  printf '# Captain preferences\n\n## Only a merge rule\n<!-- fm-moment: merge -->\n\nBody.\n' \
    > "$data/captain.md"
  printf '# Shared captain preferences\n\n## Only a merge shared rule\n<!-- fm-moment: merge -->\n\nBody.\n' \
    > "$data/captain-shared.md"
  printf '# Learnings\n\n## Only a merge learning\n<!-- fm-moment: merge -->\n\nBody.\n' \
    > "$data/learnings.md"
  out=$(run_know "$data" spawn)
  status=$?
  expect_code 0 "$status" 'a moment with no tagged section must still exit 0'
  [ -z "$out" ] || fail "a moment with no tagged section must print nothing at all, got: $out"
  pass 'resolver prints nothing, not an empty banner, when no section binds'
}

test_resolver_writes_only_to_stderr() {
  local data stdout
  data=$(make_data stderr-only)
  stdout=$(FM_DATA_OVERRIDE="$data" "$KNOW" spawn 2>/dev/null)
  [ -z "$stdout" ] || fail "the resolver must leave stdout untouched, got: $stdout"
  pass 'resolver writes its quoted rules to stderr only'
}

test_resolver_reports_an_unknown_moment_as_a_caller_bug() {
  local data out status
  data=$(make_data unknown-moment)
  out=$(run_know "$data" not-a-moment)
  status=$?
  expect_code 2 "$status" 'an unknown moment must exit 2'
  assert_contains "$out" 'unknown lifecycle moment' 'the refusal must name the problem'
  assert_contains "$out" 'spawn' 'the refusal must list the known moments'
  pass 'resolver refuses an unknown lifecycle moment'
}

test_resolver_lists_its_moments_and_audits_its_tags() {
  local data moments audit
  data=$(make_data audit)
  moments=$("$KNOW" --moments)
  assert_contains "$moments" 'spawn' '--moments must list the spawn moment'
  assert_contains "$moments" 'teardown' '--moments must list the teardown moment'
  audit=$(run_know "$data" --audit)
  assert_contains "$audit" 'spawn | ## Pick the runtime every time (fixture rule, 2026-01-01)' \
    '--audit must report a section with its tags'
  assert_contains "$audit" 'untagged | ## A rule that governs no lifecycle moment (fixture, 2026-01-03)' \
    '--audit must report an untagged section as untagged'
  pass 'resolver lists its moments and audits every section tag'
}

# --- degraded knowledge files ------------------------------------------------

test_resolver_reports_a_missing_knowledge_file() {
  local data out status
  data="$TMP_ROOT/missing/data"
  mkdir -p "$data"
  printf '# Learnings\n\n## Tagged\n<!-- fm-moment: spawn -->\n\nBody.\n' > "$data/learnings.md"
  out=$(run_know "$data" spawn)
  status=$?
  expect_code 0 "$status" 'a missing knowledge file must not fail the resolver'
  assert_contains "$out" 'data/captain.md is missing' 'the missing file must be named explicitly'
  assert_contains "$out" 'Body.' 'the readable file must still resolve'
  pass 'resolver reports a missing knowledge file and keeps going'
}

test_resolver_reports_an_unreadable_knowledge_file() {
  local data out status
  data=$(make_data unreadable)
  chmod 000 "$data/captain.md"
  out=$(run_know "$data" spawn)
  status=$?
  chmod 644 "$data/captain.md"
  if [ "$(id -u)" = 0 ]; then
    pass 'resolver unreadable-file case skipped: running as root reads anything'
    return 0
  fi
  expect_code 0 "$status" 'an unreadable knowledge file must not fail the resolver'
  assert_contains "$out" 'data/captain.md is unreadable' 'the unreadable file must be named explicitly'
  pass 'resolver reports an unreadable knowledge file and keeps going'
}

test_resolver_reports_an_entirely_untagged_knowledge_file() {
  local data out status
  data="$TMP_ROOT/untagged-file/data"
  mkdir -p "$data"
  printf '# Captain preferences\n\n## A rule\n\nBody with no marker anywhere.\n' > "$data/captain.md"
  printf '# Learnings\n\n## Tagged\n<!-- fm-moment: spawn -->\n\nLearned body.\n' > "$data/learnings.md"
  out=$(run_know "$data" spawn)
  status=$?
  expect_code 0 "$status" 'an untagged knowledge file must not fail the resolver'
  assert_contains "$out" 'data/captain.md carries no lifecycle tags' \
    'an entirely untagged file must be reported explicitly, not silently missed'
  assert_contains "$out" 'Learned body.' 'the tagged file must still resolve'
  pass 'resolver reports an entirely untagged knowledge file and keeps going'
}

# --- spawn enforcement -------------------------------------------------------

# A home with a project directory and a tmux that refuses, so any spawn that got
# past the checks under test would still create no endpoint.
# Echoes "<home>|<project-dir>|<fakebin>".
make_spawn_home() {  # <name>
  local name=$1 home projects fakebin data
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  data=$(make_data "$name")
  ln -s "$data" "$home/data"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> <mode>
  local home=$1 id=$2 mode=$3
  mkdir -p "$home/data/$id"
  printf 'You are a crewmate.\n\n# Definition of done\nDelivery contract: mode=%s\n' "$mode" \
    > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_refuses_a_ship_launch_with_no_captain_pick() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home spawn-ship-nopick)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" nopick-ship no-mistakes
  out=$(run_spawn "$home" "$fakebin" nopick-ship "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail 'a ship spawn with no captain pick must be refused'
  assert_contains "$out" 'no evidence the captain was presented the runtime choice' \
    'the refusal must say what is actually missing'
  assert_contains "$out" '--captain-pick' 'the refusal must name the exact missing input'
  assert_contains "$out" 'claude/opus' 'the refusal must show how to supply the input'
  assert_not_contains "$out" 'define and tier the task' \
    'the refusal must point at the printed rules, never carry a second copy of them'
  assert_absent "$home/state/nopick-ship.meta" 'a refused spawn must leave no task metadata'
  pass 'spawn refuses a ship launch with no evidence of the captain runtime choice'
}

test_spawn_refuses_a_scout_launch_with_no_captain_pick() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home spawn-scout-nopick)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$fakebin" nopick-scout "$proj" claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail 'a scout spawn with no captain pick must be refused'
  assert_contains "$out" 'no evidence the captain was presented the runtime choice' \
    'the scout refusal must say what is actually missing'
  assert_absent "$home/state/nopick-scout.meta" 'a refused scout spawn must leave no task metadata'
  pass 'spawn refuses a scout launch with no evidence of the captain runtime choice'
}

test_spawn_prints_the_spawn_rules_with_its_refusal() {
  local rec home proj fakebin out
  rec=$(make_spawn_home spawn-prints-rules)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" prints-rules no-mistakes
  out=$(run_spawn "$home" "$fakebin" prints-rules "$proj" claude --mode no-mistakes --yolo off)
  assert_contains "$out" 'The captain picks the runtime. Firstmate never picks it alone.' \
    'the spawn moment rules must print with the refusal'
  assert_not_contains "$out" 'Never restart the shared daemon during cleanup.' \
    'a teardown rule must not print at the spawn moment'
  pass 'spawn prints the verbatim spawn-moment rules alongside its refusal'
}

# The print-once signal for a batch must not be reachable from the ambient
# environment: an exported variable would be a session-wide off switch through
# the very control this mechanism exists to be. An ordinary single spawn prints
# the rules no matter what is exported around it.
test_spawn_rules_print_despite_an_ambient_suppression_variable() {
  local rec home proj fakebin out
  rec=$(make_spawn_home spawn-ambient-suppress)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" ambient-suppress no-mistakes
  out=$(
    export FM_SPAWN_STANDING_KNOWLEDGE_SHOWN=1
    run_spawn "$home" "$fakebin" ambient-suppress "$proj" claude \
      --mode no-mistakes --yolo off
  )
  assert_contains "$out" 'The captain picks the runtime. Firstmate never picks it alone.' \
    'no exported variable may suppress the spawn-moment rules on a single spawn'
  pass 'spawn rules print for a single spawn whatever the ambient environment says'
}

# The dedup the batch loop needs is still real: one dispatch prints the rules
# once, in the parent, not once per re-exec'd pair.
test_spawn_batch_prints_the_rules_once_for_the_whole_batch() {
  local rec home proj fakebin out count
  rec=$(make_spawn_home spawn-batch-once)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # Neither pair has a brief, so both fail after the rules would have printed.
  out=$(run_spawn "$home" "$fakebin" "batch-once-a=$proj" "batch-once-b=$proj" \
    --harness claude --mode no-mistakes --yolo off --captain-pick claude)
  assert_contains "$out" 'batch: FAILED to spawn batch-once-a' 'the first pair must be dispatched'
  assert_contains "$out" 'batch: FAILED to spawn batch-once-b' 'the second pair must be dispatched'
  count=$(printf '%s\n' "$out" | grep -c -F 'The captain picks the runtime. Firstmate never picks it alone.' || true)
  [ "$count" = 1 ] || fail "a batch must print the spawn rules exactly once, got $count copies"
  pass 'a batch prints the spawn-moment rules once in the parent, not once per pair'
}

test_spawn_refuses_a_pick_that_names_another_runtime() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home spawn-wrong-runtime)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" wrong-runtime no-mistakes
  out=$(run_spawn "$home" "$fakebin" wrong-runtime "$proj" claude \
    --mode no-mistakes --yolo off --captain-pick codex)
  status=$?
  [ "$status" -ne 0 ] || fail 'a pick naming another runtime must be refused'
  assert_contains "$out" "names runtime 'codex'" 'the refusal must name the captain pick'
  assert_contains "$out" "launches 'claude'" 'the refusal must name the runtime actually launching'
  assert_absent "$home/state/wrong-runtime.meta" 'a refused spawn must leave no task metadata'
  pass 'spawn refuses a captain pick that names a different runtime than it launches'
}

test_spawn_refuses_a_pick_that_omits_the_model_being_launched() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home spawn-model-omitted)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" model-omitted no-mistakes
  out=$(run_spawn "$home" "$fakebin" model-omitted "$proj" claude \
    --mode no-mistakes --yolo off --model opus --captain-pick claude)
  status=$?
  [ "$status" -ne 0 ] || fail 'a pick that omits the launched model must be refused'
  assert_contains "$out" "launches model 'opus'" 'the refusal must name the model being launched'
  assert_contains "$out" '--captain-pick claude/opus' 'the refusal must show how to supply it'
  pass 'spawn refuses a captain pick that omits the model it is about to launch'
}

test_spawn_refuses_a_pick_naming_a_model_it_will_not_launch() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home spawn-model-phantom)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" model-phantom no-mistakes
  out=$(run_spawn "$home" "$fakebin" model-phantom "$proj" claude \
    --mode no-mistakes --yolo off --captain-pick claude/opus)
  status=$?
  [ "$status" -ne 0 ] || fail 'a pick naming an unlaunched model must be refused'
  assert_contains "$out" "names model 'opus'" 'the refusal must name the phantom model'
  assert_contains "$out" '--model opus' 'the refusal must name the missing input'
  pass 'spawn refuses a captain pick naming a model the launch would not use'
}

test_spawn_refuses_a_captain_pick_on_a_secondmate() {
  local rec home proj fakebin out status
  rec=$(make_spawn_home spawn-secondmate-pick)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$fakebin" sm-pick "$home" --secondmate --captain-pick claude)
  status=$?
  [ "$status" -ne 0 ] || fail 'a captain pick on a secondmate spawn must be refused'
  assert_contains "$out" 'applies only to ship and scout spawns' \
    'the refusal must say where the flag belongs'
  pass 'spawn refuses a captain pick on a secondmate, which is not a crew spawn'
}

test_spawn_accepts_a_matching_captain_pick() {
  local rec home proj fakebin out
  rec=$(make_spawn_home spawn-matching-pick)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" matching-pick no-mistakes
  # tmux refuses, so this cannot complete; it must fail for a BACKEND reason,
  # never for a captain-pick reason.
  out=$(run_spawn "$home" "$fakebin" matching-pick "$proj" claude \
    --mode no-mistakes --yolo off --model opus --captain-pick claude/opus)
  assert_not_contains "$out" 'captain was presented the runtime choice' \
    'a matching pick must clear the presence check'
  assert_not_contains "$out" "names runtime" 'a matching pick must clear the runtime check'
  assert_not_contains "$out" 'names model' 'a matching pick must clear the model check'
  pass 'spawn accepts a captain pick that matches the runtime it launches'
}

# --- pr-ready: the merge-authority source ------------------------------------

WMS_ENTRY='- wms [no-mistakes] - fixture entry. Merge authority is NOT read from this flag: the captain granted firstmate merges, and the yolo flag is deliberately absent so open questions still reach them (added 2026-01-01)'

# A home whose task metadata points at a project, with a fake gh so no forge is
# reached. Echoes "<home>|<project-dir>".
make_pr_home() {  # <name> [<registry-line>...]
  local name=$1 home proj fakebin data
  shift
  home="$TMP_ROOT/$name/home"
  proj="$TMP_ROOT/$name/projects/wms"
  fakebin=$(fm_fakebin "$TMP_ROOT/$name/fake")
  fm_fake_exit0 "$fakebin" gh
  mkdir -p "$home/state" "$home/config" "$proj"
  data=$(make_data "$name")
  ln -s "$data" "$home/data"
  if [ "$#" -gt 0 ]; then
    printf '# Projects\n\n' > "$data/projects.md"
    printf '%s\n' "$@" >> "$data/projects.md"
  fi
  fm_write_meta "$home/state/$name.meta" \
    "window=firstmate:fm-$name" "worktree=$proj" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  chmod 0600 "$home/state/$name.meta"
  printf '%s\n' "$home|$fakebin"
}

run_pr_check() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    PATH="$fakebin:$PATH" "$PR_CHECK" "$@" 2>&1
}

test_pr_check_prints_the_registered_entry_verbatim() {
  local rec home fakebin out status
  rec=$(make_pr_home pr-registered "$WMS_ENTRY")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  out=$(run_pr_check "$home" "$fakebin" pr-registered https://github.com/o/r/pull/7)
  status=$?
  expect_code 0 "$status" 'recording a PR must still succeed'
  assert_contains "$out" "$WMS_ENTRY" \
    'the registry entry must be printed exactly as written, prose and all'
  assert_contains "$out" 'merge-authority source for wms' 'the entry must be labelled as the source'
  assert_contains "$out" 'armed: state/pr-registered.check.sh' 'the existing stdout contract must survive'
  pass 'pr-ready prints the verbatim registry entry as the merge-authority source'
}

test_pr_check_prints_the_pr_ready_rules() {
  local rec home fakebin out
  rec=$(make_pr_home pr-rules "$WMS_ENTRY")
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  out=$(run_pr_check "$home" "$fakebin" pr-rules https://github.com/o/r/pull/8)
  assert_contains "$out" 'The completion point is PR creation, not merge.' \
    'the pr-ready moment rules must print'
  assert_not_contains "$out" 'The captain picks the runtime.' \
    'a spawn rule must not print at the pr-ready moment'
  pass 'pr-ready prints the verbatim rules tagged for that moment'
}

test_pr_check_notices_an_unregistered_project() {
  local rec home fakebin out status
  rec=$(make_pr_home pr-unregistered '- other [local-only] - a different project (added 2026-01-01)')
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  out=$(run_pr_check "$home" "$fakebin" pr-unregistered https://github.com/o/r/pull/9)
  status=$?
  expect_code 0 "$status" 'an unregistered project must not fail the recording'
  assert_contains "$out" 'has no entry in data/projects.md' \
    'an unregistered project must be reported explicitly, not silently skipped'
  assert_contains "$out" 'armed: state/pr-unregistered.check.sh' 'the primary job must still complete'
  pass 'pr-ready reports an unregistered project without aborting'
}

test_pr_check_reports_a_missing_registry() {
  local rec home fakebin out status
  rec=$(make_pr_home pr-noregistry)
  IFS='|' read -r home fakebin <<EOF
$rec
EOF
  out=$(run_pr_check "$home" "$fakebin" pr-noregistry https://github.com/o/r/pull/10)
  status=$?
  expect_code 0 "$status" 'a missing registry must not fail the recording'
  assert_contains "$out" 'data/projects.md is missing or unreadable' \
    'a missing registry must be reported explicitly'
  assert_contains "$out" 'armed: state/pr-noregistry.check.sh' 'the primary job must still complete'
  pass 'pr-ready reports a missing registry without aborting'
}

test_pr_check_survives_missing_knowledge_files() {
  local home proj fakebin out status
  home="$TMP_ROOT/pr-nodata/home"
  proj="$TMP_ROOT/pr-nodata/projects/wms"
  fakebin=$(fm_fakebin "$TMP_ROOT/pr-nodata/fake")
  fm_fake_exit0 "$fakebin" gh
  mkdir -p "$home/state" "$home/data" "$proj"
  fm_write_meta "$home/state/pr-nodata.meta" \
    "window=firstmate:fm-pr-nodata" "worktree=$proj" "project=$proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  chmod 0600 "$home/state/pr-nodata.meta"
  out=$(run_pr_check "$home" "$fakebin" pr-nodata https://github.com/o/r/pull/11)
  status=$?
  expect_code 0 "$status" 'absent knowledge files must not fail the recording'
  assert_contains "$out" 'data/captain.md is missing' 'the absent knowledge file must be reported'
  assert_contains "$out" 'armed: state/pr-nodata.check.sh' 'the primary job must still complete'
  pass 'pr-ready degrades to a diagnostic when the knowledge files are absent'
}

# --- teardown ----------------------------------------------------------------

run_teardown() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$TEARDOWN" "$@" 2>&1
}

test_teardown_surfaces_the_pr_creation_completion_point() {
  local home data out
  home="$TMP_ROOT/teardown-rules/home"
  mkdir -p "$home/state"
  data=$(make_data teardown-rules)
  ln -s "$data" "$home/data"
  # No metadata for this id, so teardown stops immediately: the rules must
  # already have printed, because they print before any cleanup work.
  out=$(run_teardown "$home" teardown-rules-task)
  assert_contains "$out" 'The completion point is PR creation, not merge.' \
    'teardown must surface the rule that moved the completion point to PR creation'
  assert_contains "$out" 'Never restart the shared daemon during cleanup.' \
    'teardown must surface every rule tagged for its moment'
  assert_not_contains "$out" 'The captain picks the runtime.' \
    'a spawn rule must not print at the teardown moment'
  pass 'teardown surfaces the PR-creation completion point before doing any work'
}

test_teardown_survives_missing_knowledge_files() {
  local home out status
  home="$TMP_ROOT/teardown-nodata/home"
  mkdir -p "$home/state" "$home/data"
  out=$(run_teardown "$home" teardown-nodata-task)
  status=$?
  assert_contains "$out" 'data/captain.md is missing' 'the absent knowledge file must be reported'
  assert_contains "$out" 'no meta for task teardown-nodata-task' \
    'teardown must reach and report its own outcome unchanged'
  expect_code 1 "$status" 'teardown must keep its own exit code for a missing task'
  pass 'teardown degrades to a diagnostic when the knowledge files are absent'
}

# --- intake ------------------------------------------------------------------

test_brief_prints_the_intake_rules() {
  local home data out status
  home="$TMP_ROOT/brief-intake/home"
  mkdir -p "$home/state" "$TMP_ROOT/brief-intake/data-src"
  data=$(make_data brief-intake)
  ln -s "$data" "$home/data"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" \
    "$BRIEF" intake-task some-repo --mode no-mistakes 2>&1)
  status=$?
  expect_code 0 "$status" 'scaffolding a brief must still succeed'
  assert_contains "$out" 'State what changes and how anyone tells whether it worked.' \
    'the intake moment rules must print when a brief is scaffolded'
  assert_present "$home/data/intake-task/brief.md" 'the brief must still be written'
  pass 'intake prints the verbatim rules tagged for that moment'
}

test_brief_prints_no_intake_rules_for_a_secondmate_charter() {
  local home data out status
  home="$TMP_ROOT/brief-charter/home"
  mkdir -p "$home/state"
  data=$(make_data brief-charter)
  ln -s "$data" "$home/data"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_STATE_OVERRIDE="$home/state" FM_SECONDMATE_CHARTER='fixture charter' \
    "$BRIEF" charter-task --secondmate --no-projects 2>&1)
  status=$?
  expect_code 0 "$status" 'scaffolding a charter must still succeed'
  assert_not_contains "$out" 'State what changes and how anyone tells whether it worked.' \
    'a persistent secondmate home takes in no task and must print no intake rules'
  pass 'a secondmate charter prints no intake rules'
}

test_resolver_returns_the_verbatim_tagged_section
test_resolver_skips_sections_tagged_for_other_moments
test_resolver_never_prints_an_untagged_section
test_resolver_withholds_the_marker_from_the_quoted_text
test_resolver_binds_one_section_at_several_moments
test_resolver_reads_both_knowledge_files
test_resolver_reads_the_shared_captain_file
test_resolver_reports_an_absent_shared_captain_file
test_resolver_reports_an_unknown_moment_tag_in_the_data
test_resolver_reports_a_marker_out_of_binding_position
test_resolver_reports_a_marker_that_misses_the_exact_spelling
test_resolver_reports_a_marker_naming_no_moment_at_all
test_resolver_leaves_documented_marker_examples_alone
test_resolver_leaves_flush_left_and_nested_fence_examples_alone
test_fenced_headings_neither_fabricate_a_rule_nor_truncate_one
test_diagnostics_print_outside_the_verbatim_banner
test_audit_still_calls_a_deliberately_untagged_section_untagged
test_resolver_prints_nothing_when_no_section_binds
test_resolver_writes_only_to_stderr
test_resolver_reports_an_unknown_moment_as_a_caller_bug
test_resolver_lists_its_moments_and_audits_its_tags
test_resolver_reports_a_missing_knowledge_file
test_resolver_reports_an_unreadable_knowledge_file
test_resolver_reports_an_entirely_untagged_knowledge_file
test_spawn_refuses_a_ship_launch_with_no_captain_pick
test_spawn_refuses_a_scout_launch_with_no_captain_pick
test_spawn_prints_the_spawn_rules_with_its_refusal
test_spawn_rules_print_despite_an_ambient_suppression_variable
test_spawn_batch_prints_the_rules_once_for_the_whole_batch
test_spawn_refuses_a_pick_that_names_another_runtime
test_spawn_refuses_a_pick_that_omits_the_model_being_launched
test_spawn_refuses_a_pick_naming_a_model_it_will_not_launch
test_spawn_refuses_a_captain_pick_on_a_secondmate
test_spawn_accepts_a_matching_captain_pick
test_pr_check_prints_the_registered_entry_verbatim
test_pr_check_prints_the_pr_ready_rules
test_pr_check_notices_an_unregistered_project
test_pr_check_reports_a_missing_registry
test_pr_check_survives_missing_knowledge_files
test_teardown_surfaces_the_pr_creation_completion_point
test_teardown_survives_missing_knowledge_files
test_brief_prints_the_intake_rules
test_brief_prints_no_intake_rules_for_a_secondmate_charter
