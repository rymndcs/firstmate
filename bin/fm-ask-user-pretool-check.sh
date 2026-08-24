#!/usr/bin/env bash
# PreToolUse guard that makes the ask-user-authority skill impossible to skip.
#
# AGENTS.md section 13 requires loading `ask-user-authority` before deciding any
# ask-user finding. Nothing enforced it, and on 2026-08-24/25 a firstmate primary
# loaded it once early in a long session and then handled roughly a dozen findings
# across five tickets without invoking it again. The gate is therefore PER FINDING,
# never per session: a load that happened before a finding appeared does not
# satisfy that finding.
#
# There are exactly two tool-mediated routes out of an ask-user finding, and
# gating one alone just pushes the decision to the other:
#   1. Asking the captain      - the AskUserQuestion tool.
#   2. Answering the worker    - a shell call invoking bin/fm-send.sh.
# Both are denied while any open ask-user finding has no skill load recorded
# since that finding appeared.
#
# bin/fm-classify-lib.sh is the sole owner of keyed open/resolved status
# semantics and bin/fm-ask-user-command-policy.mjs owns the steer command-word
# decision on top of the shell classifier in bin/fm-arm-command-policy.mjs; this
# guard re-implements neither parse. See docs/ask-user-guard.md
# for the complete contract, the recorded harness payload evidence, and the
# limitations this guard deliberately does not cover.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-ask-user-pretool-check.sh
#   bin/fm-ask-user-pretool-check.sh --tool <name> [--command <cmd>] \
#                                    [--transcript <path>]
#
# Stdin mode extracts .tool_name / .tool_input.command / .transcript_path for
# Claude and Codex, or .toolName / .toolInput.command for Grok. CLI mode is for
# adapters that already hold those values. Only Claude is wired today; see the
# harness table in docs/ask-user-guard.md.
#
# Exit/output contract (identical shape to bin/fm-subagent-pretool-check.sh):
#   ALLOW  - exit 0 and no output.
#   DENY   - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#            deny object on stdout unless --claude was supplied.
#   INERT  - not a genuine primary home: exit 0 with no output, like ALLOW.
#   ESCAPE - FM_ALLOW_ASK_USER=1 in the environment allows deliberately.
#   FAIL SAFE - EVERY undeterminable state allows and stays silent: malformed or
#            empty stdin, missing jq, an unavailable classify library or primary
#            scope library, no readable state directory, an absent or unreadable
#            session transcript, a transcript whose entry format this guard no
#            longer recognizes, an unwritable observation ledger, and a missing
#            Node runtime or steer command policy. A guard
#            that wrongly denies blocks the whole fleet, including the steering
#            needed to unblock it, so it is worse than the problem it solves.
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

# The skill this guard exists to force. Also the deny reason code.
SKILL_NAME='ask-user-authority'

TOOL=""
CMD=""
TRANSCRIPT=""
ARGS_GIVEN=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-ask-user-pretool-check.sh [--tool <name>] [--command <cmd>]
                                    [--transcript <path>] [--claude]

With none of --tool/--command/--transcript, reads a PreToolUse-style JSON payload
on stdin (Claude/Codex tool_name + tool_input.command + transcript_path, or Grok
toolName + toolInput.command).

Denies the AskUserQuestion tool and any shell call invoking bin/fm-send.sh while
an ask-user finding is open in this home's state and the ask-user-authority skill
has not been loaded since that finding appeared. The gate is per finding: an
earlier load in the same session never satisfies a later finding.

Fires only in a genuine firstmate primary home; it is a silent no-op in a
crewmate/scout task worktree or any non-firstmate repo.
Exits 0 to allow and 2 to deny, naming the finding and the skill to invoke.
Set FM_ALLOW_ASK_USER=1 in the session environment to allow deliberately.
Every undeterminable state allows silently.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)
      [ "$#" -gt 1 ] || { echo "error: --tool requires a value" >&2; exit 2; }
      TOOL=$2; ARGS_GIVEN=1; shift 2 ;;
    --tool=*)
      TOOL=${1#--tool=}; ARGS_GIVEN=1; shift ;;
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2; ARGS_GIVEN=1; shift 2 ;;
    --command=*)
      CMD=${1#--command=}; ARGS_GIVEN=1; shift ;;
    --transcript)
      [ "$#" -gt 1 ] || { echo "error: --transcript requires a value" >&2; exit 2; }
      TRANSCRIPT=$2; ARGS_GIVEN=1; shift 2 ;;
    --transcript=*)
      TRANSCRIPT=${1#--transcript=}; ARGS_GIVEN=1; shift ;;
    --claude)
      CLAUDE_MODE=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

if [ "$ARGS_GIVEN" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || CMD=""
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '(.transcript_path // .transcriptPath // empty)' 2>/dev/null) || TRANSCRIPT=""
fi

# --- route classification ---------------------------------------------------
#
# ROUTE is the caller's way OUT of an ask-user finding, and only a nonempty ROUTE
# can be denied. An empty ROUTE still runs the observation pass below, because
# that pass is what timestamps a finding's arrival against the transcript; see
# "why every call observes" there.
ROUTE=""

LC_ALL=C NORMALIZED=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
[ "$NORMALIZED" != askuserquestion ] || ROUTE=ask

# Strict-superset FAST PATH only; it owns no classification semantics. Strip the
# syntax bytes a shell joins within one word before looking for the steer entry
# point, so an ordinary quoted or escaped fragment cannot hide it, then let
# bin/fm-ask-user-command-policy.mjs decide below whether the command actually
# INVOKES the steer. Anything this substring test misses can never be denied, so
# it must stay broader than the classifier.
#
# A quoting-decoder marker (`$'…'`, `$"…"`) deliberately does not escalate here,
# unlike in the arm and cd transports. There, escalation hands an undecidable
# command to a classifier that can still decide it precisely; here the marker
# would have to escalate past a fast path that already allows, which during an
# open finding would mean denying every command containing `$'`. Deliberate
# obfuscation stays out of scope under the same agent-mistake threat model.
if [ -z "$ROUTE" ] && [ -n "$CMD" ]; then
  PREFILTER=$CMD
  PREFILTER=${PREFILTER//\\/}
  PREFILTER=${PREFILTER//\"/}
  PREFILTER=${PREFILTER//\'/}
  PREFILTER=${PREFILTER//$'\n'/}
  PREFILTER=${PREFILTER//$'\r'/}
  case "$PREFILTER" in
    *fm-send*) ROUTE=send ;;
  esac
fi

# The single deliberate escape hatch, matching bin/fm-subagent-pretool-check.sh.
# An environment variable is unforgeable in-session: it must be present when the
# harness process is launched, so no tool call can enable it for the call that
# follows, and it therefore cannot weaken the per-finding gate within a session.
[ "${FM_ALLOW_ASK_USER:-}" != "1" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
ACTIVE_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$ACTIVE_HOME/state}

[ -f "$SCRIPT_DIR/fm-primary-scope-lib.sh" ] || exit 0
[ -f "$SCRIPT_DIR/fm-classify-lib.sh" ] || exit 0

# Cheap whole-fleet precheck, deliberately ahead of the scope and library work.
# The overwhelmingly common case is that no ask-user finding exists anywhere, and
# this guard runs on EVERY tool call, so that case must cost one grep rather than
# two git calls and two library sources.
grep -l 'needs-decision' "$STATE"/*.status >/dev/null 2>&1 || exit 0

# Scope to a genuine primary home, exactly as the session-start nudge, the
# turn-end guard, and the delegation guard do. A crewmate/scout task worktree is a
# linked git worktree and stays inert: a worker raises findings, it never decides
# them, and denying its own steering would strand it.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" 2>/dev/null || exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh" 2>/dev/null || exit 0
command -v status_open_decisions >/dev/null 2>&1 || exit 0
command -v status_decision_openings >/dev/null 2>&1 || exit 0

# --- open ask-user findings -------------------------------------------------
#
# Only `needs-decision` opens an ask-user finding. `blocked` also opens a keyed
# status decision, but it means "firstmate action is needed", not "a reviewer
# asked a product question", so it is deliberately outside this gate.
#
# A finding's IDENTITY is "<task>|<key>|<nth-opening-of-that-key>|<note-checksum>".
# The ordinal is what makes a REOPENED key a new finding rather than the old one:
# without it, a worker that raises a second question under the same key would
# inherit the first finding's satisfied proof.
OPEN_IDENTITIES=""
OPEN_LABELS=""

for status_file in "$STATE"/*.status; do
  [ -f "$status_file" ] || continue
  # Per-file twin of the whole-fleet precheck above, and what keeps the steady
  # state cheap once any task has ever had a finding: status files are
  # append-only, so a resolved finding leaves its opening line behind and the
  # fleet-wide grep stops short-circuiting for that home's whole lifetime. A line
  # whose verb parses to needs-decision must contain that substring, so a file
  # without it cannot contribute an identity.
  grep -q 'needs-decision' "$status_file" 2>/dev/null || continue
  task=${status_file##*/}
  task=${task%.status}
  openings=$(status_decision_openings "$status_file" 2>/dev/null) || continue
  [ -n "$openings" ] || continue
  while IFS="$(printf '\t')" read -r key verb note; do
    [ "$verb" = needs-decision ] || continue
    [ -n "$key" ] || continue
    ordinal=$(printf '%s\n' "$openings" | awk -F'\t' -v k="$key" '$1 == k && $2 == "needs-decision" { n++ } END { print n + 0 }')
    sum=$(printf '%s' "$note" | cksum 2>/dev/null | awk '{ print $1 }')
    [ -n "$sum" ] || sum=0
    OPEN_IDENTITIES="${OPEN_IDENTITIES}${task}|${key}|${ordinal}|${sum}"$'\n'
    OPEN_LABELS="${OPEN_LABELS}${task} [key=${key}]"$'\n'
  done <<EOF
$(status_open_decisions "$status_file" 2>/dev/null)
EOF
done

[ -n "$OPEN_IDENTITIES" ] || exit 0

# From here on a finding IS open, so the transcript is the only remaining
# evidence. No transcript means no way to tell a satisfied finding from a skipped
# one, and an undeterminable state must allow.
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] || exit 0
TRANSCRIPT_SIZE=$(wc -c < "$TRANSCRIPT" 2>/dev/null | tr -d '[:space:]') || exit 0
case "$TRANSCRIPT_SIZE" in
  ''|*[!0-9]*) exit 0 ;;
esac

# --- observation ledger -----------------------------------------------------
#
# Why every call observes, including calls this guard can never deny:
# the ledger records WHERE IN THE TRANSCRIPT each finding was first seen, and a
# skill load only counts if it appears after that point. If the ledger were
# written only on a gated call, the first sight of a finding would be the
# AskUserQuestion or steer itself - already after a correct firstmate had loaded
# the skill in response to the finding - and the guard would deny work that was
# done right. Observing on every call moves first sight to the first tool call
# after the finding appeared, which precedes any load made in response to it.
#
# PreToolUse fires BEFORE the calling tool's own entry is appended to the
# transcript (verified; see docs/ask-user-guard.md), so recording the current size
# never swallows the very load being recorded against.
LEDGER="$STATE/.ask-user-authority-guard"

# A row is keyed on the PAIR <identity, transcript>, not on the identity alone.
# Two sessions can be open on the same home, and each has its own first sight of
# the same finding. Keying on the identity alone would let whichever session
# wrote last silently revoke the other's established position, which re-denies a
# load that session genuinely made in response to the finding - the wedge this
# guard must never become.
ledger_lookup() {  # <identity> -> prints this transcript's recorded offset, or fails
  local want=$1 lid ltp loff
  [ -f "$LEDGER" ] || return 1
  while IFS="$(printf '\t')" read -r lid ltp loff; do
    [ "$lid" = "$want" ] || continue
    # A different transcript is a different session: its recorded position means
    # nothing here, so keep looking for this session's own row. The finding still
    # needs a fresh load in THIS transcript, which is what a missing row gives.
    [ "$ltp" = "$TRANSCRIPT" ] || continue
    case "$loff" in ''|*[!0-9]*) return 1 ;; esac
    # A transcript shorter than the recorded position was rotated or truncated.
    [ "$loff" -le "$TRANSCRIPT_SIZE" ] || return 1
    printf '%s' "$loff"
    return 0
  done < "$LEDGER"
  return 1
}

ledger_identity_is_open() {  # <identity>
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] || continue
    return 0
  done <<EOF
$OPEN_IDENTITIES
EOF
  return 1
}

# Offsets a permitted gated call is consuming, one "<identity><TAB><offset>" row.
# Empty on every other call: only a gated call the guard actually ALLOWS may
# advance a position, and an observation call never does.
CONSUMED_OFFSETS=""

consumed_offset() {  # <identity> -> prints the consuming offset, or fails
  local want=$1 cid coff
  [ -n "$CONSUMED_OFFSETS" ] || return 1
  while IFS="$(printf '\t')" read -r cid coff; do
    [ "$cid" = "$want" ] || continue
    case "$coff" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$coff"
    return 0
  done <<EOF
$CONSUMED_OFFSETS
EOF
  return 1
}

# Rewrite the ledger to every currently-open finding in this transcript, plus
# every other session's still-live rows, preserving each known first-sight
# position and stamping the current one for new findings.
# Pruning on write is what keeps this file bounded now that it holds one row per
# <finding, session>: a row survives only while its finding is still open AND its
# transcript still exists, so a resolved finding and a vanished session both drop
# out the next time anything writes.
ledger_sync() {
  local tmp identity offset lid ltp loff
  tmp="$LEDGER.$$"
  # Redirections are opened left to right, so 2>/dev/null must come FIRST or a
  # read-only state directory prints bash's own "Permission denied" to the real
  # stderr - which Claude reads as hook output on an allow.
  : 2>/dev/null > "$tmp" || return 1
  if [ -f "$LEDGER" ]; then
    while IFS="$(printf '\t')" read -r lid ltp loff; do
      [ -n "$lid" ] || continue
      [ "$ltp" != "$TRANSCRIPT" ] || continue
      [ -n "$ltp" ] && [ -f "$ltp" ] || continue
      case "$loff" in ''|*[!0-9]*) continue ;; esac
      ledger_identity_is_open "$lid" || continue
      printf '%s\t%s\t%s\n' "$lid" "$ltp" "$loff" 2>/dev/null >> "$tmp" || {
        rm -f "$tmp" 2>/dev/null
        return 1
      }
    done < "$LEDGER"
  fi
  while IFS= read -r identity; do
    [ -n "$identity" ] || continue
    offset=$(consumed_offset "$identity") \
      || offset=$(ledger_lookup "$identity") \
      || offset=$TRANSCRIPT_SIZE
    printf '%s\t%s\t%s\n' "$identity" "$TRANSCRIPT" "$offset" 2>/dev/null >> "$tmp" || {
      rm -f "$tmp" 2>/dev/null
      return 1
    }
  done <<EOF
$OPEN_IDENTITIES
EOF
  mv -f "$tmp" "$LEDGER" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }
  return 0
}

# ledger_sync is a read-modify-write finished by one mv, so two sessions syncing
# in the same instant - which is exactly when both are missing a row, right after
# a finding appears - can still lose the later writer's rows to the winner's mv.
# Re-reading afterwards and syncing once more collapses that window to a retry.
# It can never deny on its own: a failed re-sync just leaves the ledger as the
# other session wrote it, and the caller treats any failure as an allow.
ledger_sync_checked() {
  local identity
  ledger_sync || return 1
  while IFS= read -r identity; do
    [ -n "$identity" ] || continue
    ledger_lookup "$identity" >/dev/null && continue
    ledger_sync
    return $?
  done <<EOF
$OPEN_IDENTITIES
EOF
  return 0
}

# Sync whenever the ledger does not already describe exactly this open set with a
# usable position, so the steady state costs no writes at all.
NEEDS_SYNC=0
while IFS= read -r identity; do
  [ -n "$identity" ] || continue
  ledger_lookup "$identity" >/dev/null || { NEEDS_SYNC=1; break; }
done <<EOF
$OPEN_IDENTITIES
EOF
if [ "$NEEDS_SYNC" -eq 1 ]; then
  ledger_sync_checked || exit 0
fi

# Observation is complete. A call this guard could never deny stops here, having
# paid only for the ledger, never for the transcript work below.
[ -n "$ROUTE" ] || exit 0

# Resolve the steer route precisely, now that a finding is open and the answer
# can change the decision. The prefilter above is a strict superset that also
# matches read-only inspection of the steer script itself;
# bin/fm-ask-user-command-policy.mjs answers the real question - is a command word
# whose basename is fm-send.sh executed anywhere in this program? - reusing the
# shell classifier owned by bin/fm-arm-command-policy.mjs. Every undeterminable
# state here allows silently like all the others: no Node, a missing policy file,
# a lexer error inside the policy, or an answer this transport does not recognize.
if [ "$ROUTE" = send ]; then
  ASK_USER_POLICY="$SCRIPT_DIR/fm-ask-user-command-policy.mjs"
  command -v node >/dev/null 2>&1 || exit 0
  [ -f "$ASK_USER_POLICY" ] || exit 0
  POLICY_OUTPUT=$(node "$ASK_USER_POLICY" --command "$CMD" 2>/dev/null) || exit 0
  [ "$POLICY_OUTPUT" = deny ] || exit 0
fi

# Before treating "no load found" as evidence, confirm this guard can still read
# the transcript format at all. A future harness release that changes the
# transcript shape would otherwise turn every scan into a silent no-match and
# deny the whole fleet on a format change rather than a policy breach. One
# recognizable entry anywhere in the recent tail is enough; none at all means the
# evidence is unreadable, which is an undeterminable state, which allows.
TRANSCRIPT_READABLE=$(tail -n 50 "$TRANSCRIPT" 2>/dev/null | jq -R -r '
  fromjson? // empty
  | select(type == "object")
  | select(has("type"))
  | "readable"
' 2>/dev/null | head -1)
[ "$TRANSCRIPT_READABLE" = readable ] || exit 0

# --- proof of load ----------------------------------------------------------
#
# A load is proven only by a STRUCTURAL tool_use entry in the transcript, never by
# the skill's name appearing as text. That distinction is load-bearing: this
# guard's own deny message names the skill, and a substring match would let the
# deny text satisfy the very finding it just denied.
#
# Three accepted forms, all of them a real load of the skill's content:
#   - the Skill tool invoked with skill == ask-user-authority
#   - any tool reading that skill's SKILL.md by file_path
#   - a shell command reading that skill's SKILL.md by path
#
# The answer is the byte position just PAST the proving entry, not a yes or no,
# because a permitted call consumes the proof it used: each finding's position
# moves past that load so the same load cannot also satisfy the next finding.
# awk runs under LC_ALL=C so its lengths are bytes, matching the byte offsets the
# ledger and tail -c speak in.
skill_load_end() {  # <offset> -> prints the offset just past the proving load, or fails
  local offset=$1 hit
  hit=$(tail -c "+$((offset + 1))" "$TRANSCRIPT" 2>/dev/null \
    | LC_ALL=C awk -v base="$offset" '{ seen += length($0) + 1; printf "%d\t%s\n", base + seen, $0 }' \
    | jq -R -r --arg skill "$SKILL_NAME" '
        (index("\t")) as $tab
        | select($tab != null)
        | .[:$tab] as $end
        | (.[$tab + 1:] | fromjson? // empty)
        | (.message.content? // empty)
        | select(type == "array")
        | .[]
        | select((.type? // "") == "tool_use")
        | select(
            ((((.name? // "") | ascii_downcase) == "skill") and ((.input.skill? // "") == $skill))
            or (((.input.file_path? // "") | endswith($skill + "/SKILL.md")))
            or (((.input.command? // "") | contains($skill + "/SKILL.md")))
          )
        | $end
      ' 2>/dev/null | head -1) || return 1
  case "$hit" in ''|*[!0-9]*) return 1 ;; esac
  # A final line with no trailing newline makes awk's count one byte long, and a
  # position past the file would look like a rotated transcript on the next call.
  [ "$hit" -le "$TRANSCRIPT_SIZE" ] || hit=$TRANSCRIPT_SIZE
  printf '%s' "$hit"
}

UNPROVEN_LABELS=""
line_no=0
while IFS= read -r identity; do
  [ -n "$identity" ] || continue
  line_no=$((line_no + 1))
  offset=$(ledger_lookup "$identity") || offset=$TRANSCRIPT_SIZE
  if proof=$(skill_load_end "$offset"); then
    [ "$ROUTE" != ask ] \
      || CONSUMED_OFFSETS="${CONSUMED_OFFSETS}${identity}$(printf '\t')${proof}"$'\n'
    continue
  fi
  label=$(printf '%s\n' "$OPEN_LABELS" | sed -n "${line_no}p")
  UNPROVEN_LABELS="${UNPROVEN_LABELS}${label}; "
done <<EOF
$OPEN_IDENTITIES
EOF

# Permitted, so every open finding had its own proof. An allowed AskUserQuestion
# consumes that proof, moving each finding's recorded position past the load, so
# the next finding escalated in the same batch needs its own load rather than
# riding one load through a whole wake.
#
# An allowed steer consumes nothing, on purpose. bin/fm-send.sh is also
# firstmate's ordinary fleet transport, and the guard cannot tell a decision
# delivery from a nudge or a recovery interrupt without attributing the call -
# an attribution that cost more in wrong denies than the batch property was worth
# on this route. The steer route is still GATED, so the first delivery while a
# finding is open still requires a load; what is given up is that later steers
# ride it. docs/ask-user-guard.md records that as a known limit.
#
# A ledger that cannot be written still allows, because a guard must never turn
# its own bookkeeping failure into a deny.
if [ -z "$UNPROVEN_LABELS" ]; then
  ledger_sync_checked
  exit 0
fi
UNPROVEN_LABELS=${UNPROVEN_LABELS%; }

case "$ROUTE" in
  ask)  ACTION='asking the captain' ;;
  *)    ACTION='sending a decision to the worker' ;;
esac

REASON="[$SKILL_NAME] $ACTION is one of the two ways out of an ask-user finding, and these open findings have no $SKILL_NAME load recorded since they appeared: $UNPROVEN_LABELS. Invoke the $SKILL_NAME skill now (Skill tool, skill: $SKILL_NAME), decide the finding under its procedure, then retry this call. Loading it earlier in this session does not satisfy a finding that appeared later, and a load already spent on another finding does not carry over to this one - the gate is per finding, because a stale or shared load is exactly the failure this guard exists to stop. Launch the session with FM_ALLOW_ASK_USER=1 for a deliberate exception."

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$REASON")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
