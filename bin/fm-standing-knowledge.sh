#!/usr/bin/env bash
# fm-standing-knowledge.sh - resolve the captain's standing rules and standing
# environment facts that bind at ONE lifecycle moment, and print them verbatim.
#
# WHY THIS EXISTS. The knowledge files already own every rule in them, and every
# lifecycle script already runs at the moment those rules apply. What was missing
# is the join: a rule reached the moment it governs only if an agent chose to
# re-read a large file at the right instant, which is the documented failure this
# script removes. Written knowledge that depends on an agent choosing to read it
# is not a control, so the reading happens here, in a script the lifecycle
# already runs.
#
# THE KNOWLEDGE FILES, and why there are three of them:
#
#   data/captain.md        this home's own captain preferences.
#   data/captain-shared.md the main-authoritative fleet-wide captain-preference
#                          file: authored in the primary home and propagated
#                          read-only to every secondmate home
#                          (.agents/skills/secondmate-provisioning/SKILL.md).
#   data/learnings.md      fleet-local operational facts and gotchas.
#
# captain-shared.md is not optional decoration. bin/fm-home-seed.sh seeds a
# secondmate home with data/projects.md and data/charter.md only, and a home's
# local data/captain.md is trimmed to domain-specific content plus pointers to
# the shared file after its first propagation - so in a secondmate home, which
# runs its own crew spawns through the same bin/fm-spawn.sh, captain-shared.md is
# where the captain's standing preferences actually live. Reading only
# captain.md there would surface nothing, which is the exact failure this script
# exists to remove. It carries captain preferences, so it prints beside
# captain.md and ahead of fleet-local learnings.
#
# THIS SCRIPT OWNS NOTHING IT PRINTS. Those three files stay the sole owners of
# their rules; this only selects and quotes them. It never paraphrases, truncates
# a section, reorders one, or reformats one. It never decides anything either -
# no merge, approval, routing, or posture decision is taken or influenced here
# beyond putting the owner's own words in front of the agent making it.
#
# THE TAG. A `##` section in a knowledge file binds at a moment when the line
# DIRECTLY BELOW its heading is exactly:
#
#     <!-- fm-moment: <moment> [<moment>...] -->
#
# An HTML comment is invisible in rendered Markdown, so tagging does not change
# how the file reads. The marker must be the line immediately after the heading:
# one deterministic place to write it and one place to audit it. A section with
# no marker binds nowhere and is never printed - that is the correct outcome for
# a section that governs no lifecycle moment, not a gap to paper over.
# A section runs from its `##` heading to the line before the next `##` heading
# (or end of file), so `###` subsections travel with their parent. The marker
# line itself is metadata rather than content and is the only line withheld from
# the emitted text.
#
# THE MOMENTS, and why the set is exactly this. Each one is a point where a
# script already runs, so a tag can actually reach an agent:
#
#   intake     bin/fm-brief.sh          - defining, tiering and scoping the task
#   spawn      bin/fm-spawn.sh          - choosing and launching the worker
#   pr-ready   bin/fm-pr-check.sh       - the PR exists; hold it or land it
#   merge      bin/fm-pr-merge.sh, bin/fm-merge-local.sh - landing the work
#   teardown   bin/fm-teardown.sh       - the worker's work is finished with
#
# Three moments were considered and deliberately left out, so a later reader does
# not re-add them by reflex:
#   session-start - bin/fm-session-start.sh already prints data/captain.md and
#                   data/learnings.md IN FULL. A slice there would re-print what
#                   the digest already carries, and the failure at session start
#                   is skipping the digest, which a second copy does not fix.
#   stall         - no script owns the stalled-worker moment; it is reached
#                   through a skill. There is nothing to print from.
#   merge as a separate captain-authority read at PR time - merge authority binds
#                   the moment the PR is ready, not only when a merge command
#                   runs, so pr-ready carries it and merge repeats it for the
#                   local-only path, which never passes through pr-ready.
#
# OUTPUT. Everything this script writes goes to STDERR, never stdout, so no
# caller's parseable stdout contract changes. A moment with no tagged section
# prints nothing at all: an empty banner would read as "checked, nothing binds
# here", which is indistinguishable from "the file lost its tags". Diagnostics
# print BEFORE the banner opens, so everything between the banner lines is the
# owning files' own words and nothing else - a diagnostic sitting under the last
# line of a quoted rule would read as part of that rule.
#
# DEGRADED KNOWLEDGE FILES never abort the caller. A missing, unreadable, or
# entirely untagged file prints its own explicit diagnostic naming the file and
# what cannot be surfaced, and the run still exits 0. So are the three ways a
# hand-written marker can bind nowhere while reading exactly like a section
# deliberately left untagged: a tag naming a moment outside the set above; a
# well-formed marker that is not on the line directly below a `## ` heading,
# which a single stray blank line is enough to cause; and a line plainly meant to
# be a marker that misses the exact spelling, such as a missing space after
# `<!--`, a trailing space, or a leading indent. Each names the file, the
# offending marker or token and the section, because the tags are written by hand
# in files that live outside this repo and nothing else would ever report that a
# rule quietly stopped arriving. Only the exact spelling ever binds a section, so
# none of this changes what a moment resolves to. The caller's primary job is never blocked by
# knowledge that could not be read - the enforcement that DOES block lives in the
# lifecycle scripts themselves, on inputs they require. data/captain-shared.md in
# particular is absent in a home that has never been propagated to, and its
# diagnostic is the expected steady state there rather than a fault.
#
# Usage:
#   fm-standing-knowledge.sh <moment>     print the verbatim sections binding at
#                                         <moment> to stderr; exit 0
#   fm-standing-knowledge.sh --moments    print the known moments to stdout
#   fm-standing-knowledge.sh --audit      print every `##` heading in each
#                                         knowledge file with its tags, or
#                                         "untagged", to stdout, marking any tag
#                                         that names an unknown moment and any
#                                         marker that sits out of binding
#                                         position or misses the exact spelling,
#                                         rather than calling its section plainly
#                                         untagged
#   fm-standing-knowledge.sh --help       print this usage
#
# An unknown moment ON THE COMMAND LINE exits 2 with a diagnostic: moments are
# written by callers in this repo, so an unrecognised one is a bug in the caller,
# not captain data. An unknown moment IN THE DATA only warns, because captain
# data must never abort a lifecycle script's primary job.
#
# Knowledge files are read from ${FM_DATA_OVERRIDE:-$FM_HOME/data}, exactly like
# every other home-scoped script here.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# The knowledge files, in the order they print. The captain-preference files
# come first: a captain instruction outranks a fleet-local learning when both
# bind at one moment.
FM_KNOWLEDGE_FILES="captain.md captain-shared.md learnings.md"
FM_MOMENTS="intake spawn pr-ready merge teardown"

# THE MARKER FORMAT HAS EXACTLY ONE OWNER: this awk fragment. Every reader below
# - the resolver, the problem check, the has-any-tag check and the audit - runs
# it, so the syntax is written down once and audited from the same place it is
# written, which is the whole reason the marker sits in one deterministic
# position.
#
# is_marker is the STRICT recogniser and is the only thing that ever binds a
# section. looks_like_marker is deliberately LOOSE - an HTML comment mentioning
# fm-moment, indented or padded however it was typed - and never binds anything;
# it exists so a line that was plainly meant to be a marker but misses the exact
# spelling can be reported instead of vanishing.
FM_MARKER_AWK='
function is_marker(line) {
  return line ~ /^<!-- fm-moment:[^>]*-->$/
}
function looks_like_marker(line) {
  return line ~ /^[[:space:]]*<!--.*fm-moment.*-->[[:space:]]*$/
}
function marker_tags(line,   stripped) {
  stripped = line
  sub(/^<!-- fm-moment:[[:space:]]*/, "", stripped)
  sub(/[[:space:]]*-->$/, "", stripped)
  return stripped
}
'

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment, so the header cannot drift from --help.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

moment_known() {  # <moment>
  local m
  for m in $FM_MOMENTS; do
    [ "$m" = "$1" ] && return 0
  done
  return 1
}

# Print every tagged section for one moment from one file, verbatim, minus the
# marker line. Prints nothing when no section in the file binds at the moment.
sections_for_moment() {  # <file> <moment>
  awk -v want="$2" "$FM_MARKER_AWK"'
    # A heading closes any open section and opens a candidate one. Nothing is
    # emitted until the next line proves the candidate carries a matching tag.
    /^## / {
      emit = 0
      expect_marker = 1
      heading = $0
      next
    }
    expect_marker {
      expect_marker = 0
      # An untagged section binds nowhere: emit stays 0 and its body is skipped.
      if (!is_marker($0)) { next }
      n = split(marker_tags($0), t, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (t[i] == want) { emit = 1 }
      }
      if (emit) { print heading }
      # The marker itself is metadata, never content: it is withheld here.
      next
    }
    emit { print }
  ' "$1"
}

# Every way a written marker can bind nowhere, as "<kind>|<detail>|<heading>".
# The tags are hand-written in captain-private files outside this repo, and each
# slip below produces a section that simply stops arriving at its lifecycle
# script while reading exactly like a section deliberately left untagged:
#
#   unknown    the marker is well placed but names a moment that does not exist,
#              so it matches nothing at any moment.
#   orphan     the marker is well formed but is not on the line directly below a
#              `## ` heading - a blank line left between the two is enough - so
#              no section claims it.
#   malformed  the line was plainly meant to be a marker but misses the exact
#              spelling - a missing space after `<!--`, a trailing space, a
#              leading indent - so the strict recogniser never sees it.
marker_problems_in() {  # <file>
  awk -v moments="$FM_MOMENTS" "$FM_MARKER_AWK"'
    BEGIN {
      km = split(moments, m, /[[:space:]]+/)
      for (j = 1; j <= km; j++) { known[m[j]] = 1 }
    }
    /^## / { heading = $0; expect_marker = 1; next }
    {
      in_position = expect_marker
      expect_marker = 0
      if (is_marker($0)) {
        if (in_position) {
          n = split(marker_tags($0), t, /[[:space:]]+/)
          for (i = 1; i <= n; i++) {
            if (t[i] != "" && !(t[i] in known)) { printf "unknown|%s|%s\n", t[i], heading }
          }
        } else {
          printf "orphan|%s|%s\n", $0, (heading == "" ? "(no ## heading above it)" : heading)
        }
        next
      }
      if (looks_like_marker($0)) {
        printf "malformed|%s|%s\n", $0, (heading == "" ? "(no ## heading above it)" : heading)
      }
    }
  ' "$1"
}

# A file with no marker at all cannot bind anywhere, which is a real condition an
# operator must be told about rather than a silent no-match.
file_has_any_tag() {  # <file>
  awk "$FM_MARKER_AWK"'
    is_marker($0) { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

# One rendered diagnostic line per marker that cannot bind, on stdout so the
# caller decides where it lands. A slip in captain-private data is reported,
# never fatal: the exit status is untouched either way.
marker_problem_lines() {  # <file> <name>
  local problems kind detail heading
  problems=$(marker_problems_in "$1") || problems=
  [ -n "$problems" ] || return 0
  while IFS='|' read -r kind detail heading; do
    case "$kind" in
      unknown)
        printf 'standing-knowledge: data/%s tags a section with unknown lifecycle moment "%s"; that tag binds nowhere (known moments: %s) | %s\n' \
          "$2" "$detail" "$FM_MOMENTS" "$heading"
        ;;
      orphan)
        # shellcheck disable=SC2016 # literal Markdown heading syntax, not a substitution
        printf 'standing-knowledge: data/%s has the marker %s on a line that is not directly below a `## ` heading, so it binds nowhere | %s\n' \
          "$2" "$detail" "$heading"
        ;;
      malformed)
        printf 'standing-knowledge: data/%s has the line %s where a marker was meant; it does not match the exact marker spelling, so it binds nowhere | %s\n' \
          "$2" "$detail" "$heading"
        ;;
    esac
  done <<EOF
$problems
EOF
}

# Diagnostics are gathered and printed BEFORE the banner opens. Everything
# between the banner lines is then the owning files' own words and nothing else:
# a diagnostic landing under the last line of a quoted rule reads as part of that
# rule, and data/captain-shared.md being absent until it is propagated makes that
# the steady state rather than an edge case.
emit_moment() {  # <moment>
  local moment=$1 name path body problems line
  local -a diagnostics=() quoted=()
  for name in $FM_KNOWLEDGE_FILES; do
    path="$DATA/$name"
    if [ ! -f "$path" ]; then
      diagnostics+=("$(printf 'standing-knowledge: data/%s is missing at %s; its rules cannot be surfaced at %s' \
        "$name" "$path" "$moment")")
      continue
    fi
    if [ ! -r "$path" ]; then
      diagnostics+=("$(printf 'standing-knowledge: data/%s is unreadable at %s; its rules cannot be surfaced at %s' \
        "$name" "$path" "$moment")")
      continue
    fi
    if ! file_has_any_tag "$path"; then
      diagnostics+=("$(printf 'standing-knowledge: data/%s carries no lifecycle tags; nothing in it can bind at %s' \
        "$name" "$moment")")
      continue
    fi
    problems=$(marker_problem_lines "$path" "$name") || problems=
    if [ -n "$problems" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        diagnostics+=("$line")
      done <<EOF
$problems
EOF
    fi
    body=$(sections_for_moment "$path" "$moment") || body=
    [ -n "$body" ] || continue
    quoted+=("$(printf -- '[data/%s]' "$name")" "$body")
  done
  if [ "${#diagnostics[@]}" -gt 0 ]; then
    for line in "${diagnostics[@]}"; do printf '%s\n' "$line" >&2; done
  fi
  if [ "${#quoted[@]}" -gt 0 ]; then
    printf -- '--- standing knowledge: %s ---\n' "$moment" >&2
    for line in "${quoted[@]}"; do printf '%s\n' "$line" >&2; done
    printf -- '--- end standing knowledge: %s ---\n' "$moment" >&2
  fi
  return 0
}

audit() {
  local name path
  for name in $FM_KNOWLEDGE_FILES; do
    path="$DATA/$name"
    if [ ! -f "$path" ] || [ ! -r "$path" ]; then
      printf 'data/%s: unavailable at %s\n' "$name" "$path"
      continue
    fi
    awk -v file="$name" -v moments="$FM_MOMENTS" "$FM_MARKER_AWK"'
      BEGIN {
        km = split(moments, m, /[[:space:]]+/)
        for (j = 1; j <= km; j++) { known[m[j]] = 1 }
      }
      # A section whose marker never reached the binding position - out of place,
      # or written in a spelling the strict recogniser does not accept - is not
      # the same thing as a section deliberately left untagged, so each is
      # reported differently: the audit is the only place any of them can be seen
      # at all, since they all simply never print.
      function close_section() {
        if (heading == "") { return }
        if (defect_kind == "orphan") {
          printf "data/%s: orphaned-marker %s | %s\n", file, defect_line, heading
        } else if (defect_kind == "malformed") {
          printf "data/%s: malformed-marker %s | %s\n", file, defect_line, heading
        } else {
          printf "data/%s: untagged | %s\n", file, heading
        }
        heading = ""
        defect_kind = ""
        defect_line = ""
      }
      /^## / {
        close_section()
        heading = $0
        seen_heading = $0
        expect_marker = 1
        next
      }
      {
        in_position = expect_marker
        expect_marker = 0
        if (is_marker($0)) {
          if (in_position) {
            tags = marker_tags($0)
            # An unknown token is called out rather than echoed back as if it
            # were ordinary, for the same reason.
            bad = ""
            n = split(tags, t, /[[:space:]]+/)
            for (i = 1; i <= n; i++) {
              if (t[i] != "" && !(t[i] in known)) { bad = (bad == "" ? t[i] : bad " " t[i]) }
            }
            if (bad != "") {
              printf "data/%s: %s [unknown moment: %s] | %s\n", file, tags, bad, heading
            } else {
              printf "data/%s: %s | %s\n", file, tags, heading
            }
            heading = ""
            defect_kind = ""
            defect_line = ""
          } else if (heading != "") {
            if (defect_kind == "") { defect_kind = "orphan"; defect_line = $0 }
          } else {
            printf "data/%s: orphaned-marker %s | %s\n", file, $0, \
              (seen_heading == "" ? "(no ## heading above it)" : seen_heading)
          }
          next
        }
        if (looks_like_marker($0)) {
          if (heading != "") {
            if (defect_kind == "") { defect_kind = "malformed"; defect_line = $0 }
          } else {
            printf "data/%s: malformed-marker %s | %s\n", file, $0, \
              (seen_heading == "" ? "(no ## heading above it)" : seen_heading)
          }
        }
      }
      END { close_section() }
    ' "$path"
  done
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --moments)
    for m in $FM_MOMENTS; do printf '%s\n' "$m"; done
    exit 0
    ;;
  --audit) audit; exit 0 ;;
  '')
    echo "error: fm-standing-knowledge.sh needs a lifecycle moment; run --moments for the known set" >&2
    exit 2
    ;;
esac

if ! moment_known "$1"; then
  printf 'error: unknown lifecycle moment "%s"; known moments: %s\n' "$1" "$FM_MOMENTS" >&2
  exit 2
fi
emit_moment "$1"
