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
# A FENCED BLOCK IS CONTENT, never structure. A knowledge file may show the tag
# format as a worked example, so nothing inside ``` or ~~~ opens a section, binds
# one, or is reported as a defective marker - it is quoted with the section it
# sits in, exactly as written. A block is a MATCHED PAIR: an opening delimiter and
# the first later one of the same character at the same run length or longer, so
# a ````-wrapped example containing ``` stays one block. A delimiter that never
# finds its partner opens nothing and is read as the ordinary text it is, which
# keeps one mistyped closer from swallowing every section below it; it gets its
# own diagnostic instead.
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
# OUTPUT. Every quoted rule and every diagnostic goes to STDERR, so no caller's
# parseable stdout contract changes; the --moments and --audit inspection
# commands are the only things here that write stdout, and no lifecycle script
# runs them. A moment with no tagged section
# prints nothing at all: an empty banner would read as "checked, nothing binds
# here", which is indistinguishable from "the file lost its tags". Diagnostics
# print BEFORE the banner opens, so everything between the banner lines is the
# owning files' own words and nothing else - a diagnostic sitting under the last
# line of a quoted rule would read as part of that rule.
#
# DEGRADED KNOWLEDGE FILES never abort the caller. A missing, unreadable, or
# entirely untagged file prints its own explicit diagnostic naming the file and
# what cannot be surfaced, and the run still exits 0. So are the four ways a
# hand-written marker can bind nowhere while reading exactly like a section
# deliberately left untagged: a tag naming a moment outside the set above; a
# marker naming no moment at all, which is what deleting the last token out of
# one leaves behind; a well-formed marker that opens its section but sits one
# line too low, which a single stray blank line after the heading is enough to
# cause; and a line plainly meant to be a marker that misses the exact spelling,
# such as a missing space after `<!--`, a trailing space, or a leading indent.
# Each names the file, the offending marker or token and the section, because the
# tags are written by hand in files that live outside this repo and nothing else
# would ever report that a rule quietly stopped arriving. Only the exact spelling
# in the binding position ever binds a section, so none of this changes what a
# moment resolves to. WHAT IS NOT REPORTED, because a knowledge file may DOCUMENT
# the tag format: anything inside a fenced block, and any marker-shaped line
# further into a section body than its first non-blank line. Every slip above is
# a hand-edit at the top of a section, where the marker was meant to go; a marker
# quoted mid-body is an example, and a false "this binds nowhere" printed above a
# section that IS binding is worse than the silence these checks exist to remove.
# A fence delimiter that never finds its partner is reported too, since what it
# was meant to enclose is then read as structure rather than as example text.
# The caller's primary job is never blocked by
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
#                                         that names an unknown moment, any
#                                         marker naming none at all, and any
#                                         marker that sits out of binding
#                                         position or misses the exact spelling,
#                                         rather than calling its section plainly
#                                         untagged, and naming any fence
#                                         delimiter left unclosed
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

# HOW A LINE IN A KNOWLEDGE FILE IS CLASSIFIED HAS EXACTLY ONE OWNER: the awk
# fragment below. All four readers - the resolver, the problem check, the
# has-any-tag check and the audit - call classify() once per line and act on what
# it returns; not one of them keeps its own fence or binding-position bookkeeping.
# That is deliberate and load-bearing. When each pass re-derived what a line was,
# they drifted: the reporting passes learned about fenced blocks while the binding
# pass did not, so a documented example could be quoted as a captain rule and a
# real rule could be truncated mid-body while --audit reported something else
# again. Two consumers can no longer disagree about what a line is, because there
# is only one answer to ask for.
#
# classify(line) returns one of:
#
#   fence     a fenced-block delimiter, opening or closing the block
#   fenced    a line inside a fenced block
#   heading   a `## ` heading, outside any fenced block
#   marker    a line matching the marker spelling EXACTLY, outside any fence
#   nearmiss  an HTML comment mentioning fm-moment that is not an exact marker
#   body      anything else
#
# and sets two facts about that line:
#
#   K_in_position    it is the line DIRECTLY below a `## ` heading, the one and
#                    only place a marker binds its section
#   K_first_content  it is the first non-blank line of the current section
#
# A FENCED BLOCK IS A MATCHED PAIR, decided before any line is classified. Every
# consumer reads its file TWICE: fence_record() collects the lines, fence_pairs()
# then walks them and pairs each opening delimiter with the first later delimiter
# of the same character and at least the same run length, the way Markdown itself
# closes a fence. Only a paired delimiter opens a block, so a ````-wrapped example
# containing ``` stays inside one block - that being the only way to show a fenced
# example of a fence.
#
# A delimiter that never finds its partner is NOT a fence and is read as the
# ordinary text it is, which is why the pairing is a whole pass rather than a
# running toggle. A single mistyped closer would otherwise swallow every section
# below it: those rules would stop binding at their own moments and would instead
# be quoted, marker line and all, as part of whatever section preceded the fence.
# Silently dropping the captain rules from the moment they govern is the exact
# failure this script exists to remove, so it cannot be reachable from one typo.
# The unmatched delimiter is reported as its own diagnostic rather than guessed at.
FM_LINE_AWK='
function is_marker(line) {
  return line ~ /^<!-- fm-moment:[^>]*-->$/
}
function looks_like_marker(line) {
  return line ~ /^[[:space:]]*<!--.*fm-moment.*-->[[:space:]]*$/
}
function is_fence_delim(line) {
  return line ~ /^[[:space:]]*(```|~~~)/
}
function fence_run(line, want,   s, c, n) {
  s = line
  sub(/^[[:space:]]*/, "", s)
  c = substr(s, 1, 1)
  if (want == "char") { return c }
  n = 0
  while (substr(s, n + 1, 1) == c) { n++ }
  return n
}
function fence_record(line) {
  P_lines++
  P_text[P_lines] = line
}
function fence_pairs(   i, j, c, n, jc, jn, matched, skip_to) {
  skip_to = 0
  for (i = 1; i <= P_lines; i++) {
    if (i <= skip_to || !is_fence_delim(P_text[i])) { continue }
    c = fence_run(P_text[i], "char")
    n = fence_run(P_text[i], "len")
    matched = 0
    for (j = i + 1; j <= P_lines; j++) {
      if (!is_fence_delim(P_text[j])) { continue }
      jc = fence_run(P_text[j], "char")
      jn = fence_run(P_text[j], "len")
      if (jc == c && jn >= n) { matched = j; break }
    }
    if (matched) {
      P_opener[i] = 1
      P_closer[matched] = 1
      skip_to = matched
    } else if (!P_unclosed_line) {
      P_unclosed_line = i
      P_unclosed_text = P_text[i]
    }
  }
}
function classify(line) {
  K_in_position = 0
  K_first_content = 0
  if (K_fence_open) {
    K_expect = 0
    K_seen_content = 1
    if (P_closer[FNR]) { K_fence_open = 0; return "fence" }
    return "fenced"
  }
  if (P_opener[FNR]) {
    K_fence_open = 1
    K_expect = 0
    K_seen_content = 1
    return "fence"
  }
  if (line ~ /^## /) {
    K_heading = line
    K_expect = 1
    K_seen_content = 0
    return "heading"
  }
  K_in_position = K_expect
  K_expect = 0
  if (line !~ /^[[:space:]]*$/) {
    if (!K_seen_content) { K_first_content = 1 }
    K_seen_content = 1
  }
  if (is_marker(line)) { return "marker" }
  if (looks_like_marker(line)) { return "nearmiss" }
  return "body"
}
function marker_tags(line,   stripped) {
  stripped = line
  sub(/^<!-- fm-moment:[[:space:]]*/, "", stripped)
  sub(/[[:space:]]*-->$/, "", stripped)
  return stripped
}
function marker_token_count(line,   parts, k, c) {
  c = 0
  k = split(marker_tags(line), parts, /[[:space:]]+/)
  while (k > 0) { if (parts[k] != "") { c++ } k-- }
  return c
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
  awk -v want="$2" "$FM_LINE_AWK"'
    NR == FNR { fence_record($0); next }
    FNR == 1 { fence_pairs() }
    {
      kind = classify($0)
      # A heading closes any open section and opens a candidate one. Nothing is
      # emitted until the next line proves the candidate carries a matching tag.
      if (kind == "heading") { emit = 0; next }
      if (kind == "marker" && K_in_position) {
        # An untagged section binds nowhere: emit stays 0 and its body is skipped.
        n = split(marker_tags($0), t, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (t[i] == want) { emit = 1 }
        }
        if (emit) { print K_heading }
        # The marker itself is metadata, never content: it is withheld here.
        next
      }
      # Everything else is body, fenced example included, and travels with the
      # section it sits in rather than cutting it short.
      if (emit) { print }
    }
  ' "$1" "$1"
}

# Every way a written marker can bind nowhere, as "<kind>|<detail>|<heading>".
# The tags are hand-written in captain-private files outside this repo, and each
# slip below produces a section that simply stops arriving at its lifecycle
# script while reading exactly like a section deliberately left untagged:
#
#   unknown    the marker is well placed but names a moment that does not exist,
#              so it matches nothing at any moment.
#   empty      the marker is well placed and well formed but names no moment at
#              all, which is what deleting the last token out of one leaves.
#   orphan     the marker is well formed and is the first thing the section says,
#              but a blank line was left between it and the heading, so it missed
#              the binding position and no section claims it.
#   malformed  the line directly below a heading was plainly meant to be that
#              section marker but misses the exact spelling - a missing space
#              after `<!--`, a trailing space, a leading indent - so the strict
#              recogniser never sees it.
#   unclosed   a fence delimiter that never finds its partner. It opens no block,
#              so a marker or heading below it is read as the structure it looks
#              like rather than as example text, which may not be what was meant.
#
# WHAT IS DELIBERATELY NOT REPORTED, because a knowledge file explaining the tag
# format is an ordinary thing for one of these files to contain: anything inside
# a fenced block, and any marker-shaped line further into a section body than its
# first non-blank line. Every marker slip above is a hand-edit at the top of a
# section, where the marker was meant to go; a marker quoted mid-body is an
# example, and a false "this binds nowhere" printed above a section that IS
# binding is worse than the silence this whole check exists to remove.
marker_problems_in() {  # <file>
  awk -v moments="$FM_MOMENTS" "$FM_LINE_AWK"'
    BEGIN {
      km = split(moments, m, /[[:space:]]+/)
      for (j = 1; j <= km; j++) { known[m[j]] = 1 }
    }
    NR == FNR { fence_record($0); next }
    FNR == 1 {
      fence_pairs()
      if (P_unclosed_line) {
        printf "unclosed|%s|(opened at line %d)\n", P_unclosed_text, P_unclosed_line
      }
    }
    {
      kind = classify($0)
      if (kind == "marker" && K_in_position) {
        n = split(marker_tags($0), t, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (t[i] != "" && !(t[i] in known)) { printf "unknown|%s|%s\n", t[i], K_heading }
        }
        if (marker_token_count($0) == 0) { printf "empty|%s|%s\n", $0, K_heading }
        next
      }
      if (kind == "marker" && K_first_content && K_heading != "") {
        printf "orphan|%s|%s\n", $0, K_heading
        next
      }
      if (kind == "nearmiss" && K_in_position && K_heading != "") {
        printf "malformed|%s|%s\n", $0, K_heading
      }
    }
  ' "$1" "$1"
}

# A file with no marker at all cannot bind anywhere, which is a real condition an
# operator must be told about rather than a silent no-match. A marker quoted
# inside a fenced example is not one, or a file that only documents the format
# would look tagged; a marker that merely missed the binding position IS one, so
# that file still reaches its own sharper diagnostic instead of this blunt one.
file_has_any_tag() {  # <file>
  awk "$FM_LINE_AWK"'
    NR == FNR { fence_record($0); next }
    FNR == 1 { fence_pairs() }
    { if (classify($0) == "marker") { found = 1 } }
    END { exit(found ? 0 : 1) }
  ' "$1" "$1"
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
      empty)
        printf 'standing-knowledge: data/%s has the marker %s naming no lifecycle moment at all, so it binds nowhere (known moments: %s) | %s\n' \
          "$2" "$detail" "$FM_MOMENTS" "$heading"
        ;;
      unclosed)
        printf 'standing-knowledge: data/%s opens a fenced block with %s that is never closed; an unmatched delimiter is read as ordinary text, so anything below it that looks like a heading or a marker is treated as one | %s\n' \
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
    awk -v file="$name" -v moments="$FM_MOMENTS" "$FM_LINE_AWK"'
      BEGIN {
        km = split(moments, m, /[[:space:]]+/)
        for (j = 1; j <= km; j++) { known[m[j]] = 1 }
      }
      # A section whose marker never reached the binding position - out of place,
      # or written in a spelling the strict recogniser does not accept - is not
      # the same thing as a section deliberately left untagged, so each is
      # reported differently: the audit is the only place any of them can be seen
      # at all, since they all simply never print. Which lines count is decided by
      # classify(), the same call the resolver makes, so this can never report a
      # section as anything other than what actually binds.
      function close_section() {
        if (pending == "") { return }
        if (defect_kind == "orphan") {
          printf "data/%s: orphaned-marker %s | %s\n", file, defect_line, pending
        } else if (defect_kind == "malformed") {
          printf "data/%s: malformed-marker %s | %s\n", file, defect_line, pending
        } else {
          printf "data/%s: untagged | %s\n", file, pending
        }
        pending = ""
        defect_kind = ""
        defect_line = ""
      }
      NR == FNR { fence_record($0); next }
      FNR == 1 {
        fence_pairs()
        if (P_unclosed_line) {
          printf "data/%s: unclosed-fence %s | (opened at line %d)\n", file, P_unclosed_text, P_unclosed_line
        }
      }
      {
        kind = classify($0)
        if (kind == "heading") {
          close_section()
          pending = K_heading
          next
        }
        if (kind == "marker" && K_in_position) {
          tags = marker_tags($0)
          # An unknown or absent token is called out rather than echoed back as
          # if it were ordinary, for the same reason.
          bad = ""
          n = split(tags, t, /[[:space:]]+/)
          for (i = 1; i <= n; i++) {
            if (t[i] != "" && !(t[i] in known)) { bad = (bad == "" ? t[i] : bad " " t[i]) }
          }
          if (marker_token_count($0) == 0) {
            printf "data/%s: empty-marker %s | %s\n", file, $0, K_heading
          } else if (bad != "") {
            printf "data/%s: %s [unknown moment: %s] | %s\n", file, tags, bad, K_heading
          } else {
            printf "data/%s: %s | %s\n", file, tags, K_heading
          }
          pending = ""
          defect_kind = ""
          defect_line = ""
          next
        }
        if (kind == "marker" && K_first_content && pending != "") {
          if (defect_kind == "") { defect_kind = "orphan"; defect_line = $0 }
          next
        }
        if (kind == "nearmiss" && K_in_position && pending != "") {
          if (defect_kind == "") { defect_kind = "malformed"; defect_line = $0 }
        }
      }
      END { close_section() }
    ' "$path" "$path"
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
