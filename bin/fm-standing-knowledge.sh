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
# here", which is indistinguishable from "the file lost its tags".
#
# DEGRADED KNOWLEDGE FILES never abort the caller. A missing, unreadable, or
# entirely untagged file prints its own explicit diagnostic naming the file and
# what cannot be surfaced, and the run still exits 0. A tag naming a moment that
# is not in the set above is reported the same way, naming the file, the token
# and the section it tags, because a typo'd or renamed moment is otherwise
# indistinguishable from a section deliberately left untagged. The caller's
# primary job is never blocked by knowledge that could not be read - the
# enforcement that DOES block lives in the lifecycle scripts themselves, on
# inputs they require. data/captain-shared.md in particular is absent in a home
# that has never been propagated to, and its diagnostic is the expected steady
# state there rather than a fault.
#
# Usage:
#   fm-standing-knowledge.sh <moment>     print the verbatim sections binding at
#                                         <moment> to stderr; exit 0
#   fm-standing-knowledge.sh --moments    print the known moments to stdout
#   fm-standing-knowledge.sh --audit      print every `##` heading in each
#                                         knowledge file with its tags, or
#                                         "untagged", to stdout, marking any tag
#                                         that names an unknown moment
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
# - the resolver, the unknown-tag check, the has-any-tag check and the audit -
# runs it, so the syntax is written down once and audited from the same place it
# is written, which is the whole reason the marker sits in one deterministic
# position.
FM_MARKER_AWK='
function is_marker(line) {
  return line ~ /^<!-- fm-moment:[^>]*-->$/
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

# Every tag token in a file that names no known moment, as "<token>|<heading>".
# A section whose only tag is misspelled or renamed reads exactly like a section
# deliberately left untagged - it simply never prints - so the difference is
# reported here rather than left for someone to notice a rule stopped arriving.
unknown_tags_in() {  # <file>
  awk -v moments="$FM_MOMENTS" "$FM_MARKER_AWK"'
    BEGIN {
      km = split(moments, m, /[[:space:]]+/)
      for (j = 1; j <= km; j++) { known[m[j]] = 1 }
    }
    /^## / { heading = $0; expect_marker = 1; next }
    expect_marker {
      expect_marker = 0
      if (!is_marker($0)) { next }
      n = split(marker_tags($0), t, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (t[i] != "" && !(t[i] in known)) { printf "%s|%s\n", t[i], heading }
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

# Warn about every tag that names a moment this script does not know. Stderr
# only, exit status untouched: a typo in captain-private data must never abort
# the lifecycle script whose primary job is running.
report_unknown_tags() {  # <file> <name>
  local unknown token heading
  unknown=$(unknown_tags_in "$1") || unknown=
  [ -n "$unknown" ] || return 0
  while IFS='|' read -r token heading; do
    [ -n "$token" ] || continue
    printf 'standing-knowledge: data/%s tags a section with unknown lifecycle moment "%s"; that tag binds nowhere (known moments: %s) | %s\n' \
      "$2" "$token" "$FM_MOMENTS" "$heading" >&2
  done <<EOF
$unknown
EOF
}

emit_moment() {  # <moment>
  local moment=$1 name path body printed=0
  for name in $FM_KNOWLEDGE_FILES; do
    path="$DATA/$name"
    if [ ! -f "$path" ]; then
      printf 'standing-knowledge: data/%s is missing at %s; its rules cannot be surfaced at %s\n' \
        "$name" "$path" "$moment" >&2
      continue
    fi
    if [ ! -r "$path" ]; then
      printf 'standing-knowledge: data/%s is unreadable at %s; its rules cannot be surfaced at %s\n' \
        "$name" "$path" "$moment" >&2
      continue
    fi
    if ! file_has_any_tag "$path"; then
      printf 'standing-knowledge: data/%s carries no lifecycle tags; nothing in it can bind at %s\n' \
        "$name" "$moment" >&2
      continue
    fi
    report_unknown_tags "$path" "$name"
    body=$(sections_for_moment "$path" "$moment") || body=
    [ -n "$body" ] || continue
    if [ "$printed" -eq 0 ]; then
      printf -- '--- standing knowledge: %s ---\n' "$moment" >&2
      printed=1
    fi
    printf -- '[data/%s]\n' "$name" >&2
    printf '%s\n' "$body" >&2
  done
  [ "$printed" -eq 0 ] || printf -- '--- end standing knowledge: %s ---\n' "$moment" >&2
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
      /^## / {
        if (heading != "") { printf "data/%s: untagged | %s\n", file, heading }
        heading = $0
        expect_marker = 1
        next
      }
      expect_marker {
        expect_marker = 0
        if (is_marker($0)) {
          tags = marker_tags($0)
          # An unknown token is called out here rather than echoed back as if it
          # were ordinary: the audit is the one place a misspelled moment can be
          # seen at all, since it binds nowhere and so never prints.
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
        }
      }
      END { if (heading != "") { printf "data/%s: untagged | %s\n", file, heading } }
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
