#!/usr/bin/env bash
# Durable omp watcher transitions, consumed by fm-watch-arm.sh before launching.
#
# Public arm syntax: fm-watch-arm.sh [--restart] --transition <reason>
#   --reason '<one-line description of what prevents reset>'
# Reasons: work-pending, unanswered-input, chat-question, stow-incomplete,
# decision, idle-recheck, unknown, watching-only.
# Semantic reasons are explicit claims, not independently proven chat state.
# Every arm attempt records its claim and observed verdict in the private,
# bounded state/.omp-watch-transitions.log. A clean ordinary transition without
# a declaration, or a watching-only declaration, exits 2 naming
# firstmate_watch_reset. No reset is ever performed by this script.
#
# Automatically observed startup, reset recovery, away delivery, watcher repair,
# queued wakes, open status decisions, backlog holds and inbox questions preserve
# arming. Unavailable or ambiguous evidence allows arming with a visible warning.
# Only drains consisting entirely of producer-tagged idle rechecks preserve
# arming as idle-recheck; fresh or escalated stale events remain clean-transition
# candidates. Other harnesses are unaffected.
#
# Internal producers (OMPCODE=1, PI_SESSION_ID and PI_TOOL_CALL_ID required):
#   cycle <starting|running|wake|failed> <watcher-pid> <cause>
#     owns .omp-watch-cycle: five lines, session/call/phase/pid/cause.
#     Terminal updates apply only to the current arm, never its successor.
#   drain  # drained canonical wake TSV on stdin, after queue consumption commits
#     owns .omp-watch-drain: session/call/space-separated wake classes.
#     Stale rows tagged idle-recheck use that class; other stale rows use stale.
#     Empty repeated drains retain the current cycle's earlier wake classes.
#   recovery <session>  # one replacement arm, consumed at the arm boundary
#   arm <declaration-or-empty> <description-or-empty>
# Recovery records are session-bound. A new session always starts by arming.
# Record publication is atomic and mode 0600. Writes never remove wake records.
# --help prints this contract. Missing jq or unwritable evidence never prevents
# supervision recovery; its warning must remain visible to the calling harness.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
CYCLE="$STATE/.omp-watch-cycle"
DRAIN="$STATE/.omp-watch-drain"
RECOVERY="$STATE/.omp-watch-recovery"
LOG="$STATE/.omp-watch-transitions.log"
SESSION=${PI_SESSION_ID:-}
CALL=${PI_TOOL_CALL_ID:-}

warn() { printf 'watcher: WARNING - %s; arming without reset.\n' "$*" >&2; }
publish() {
  local destination=$1 tmp
  tmp=$(umask 077; mktemp "$STATE/.omp-transition.XXXXXX") || return 1
  if cat > "$tmp" && mv -f "$tmp" "$destination"; then return 0; fi
  rm -f "${tmp:?}"
  return 1
}
load_cycle() {
  [ -f "$CYCLE" ] && [ -r "$CYCLE" ] || return 1
  {
    IFS= read -r cycle_session && IFS= read -r cycle_call && IFS= read -r phase \
      && IFS= read -r watcher_pid && IFS= read -r _cause
  } < "$CYCLE" || return 1
  [ -n "$cycle_session" ] && [ -n "$cycle_call" ] || return 1
  case "$phase" in starting|running|wake|failed) ;; *) return 1 ;; esac
  case "$watcher_pid" in ''|*[!0-9]*) return 1 ;; esac
}
record_cycle() {
  local new_phase=$1 pid=$2 why=$3
  if [ "$new_phase" != starting ]; then
    load_cycle && [ "$cycle_session" = "$SESSION" ] && [ "$cycle_call" = "$CALL" ] || return 0
  fi
  printf '%s\n' "$SESSION" "$CALL" "$new_phase" "$pid" "$why" | publish "$CYCLE"
}
record_drain() {
  local rows kinds previous_session='' previous_call='' previous_kinds=''
  rows=$(cat)
  load_cycle && [ "$cycle_session" = "$SESSION" ] || return 0
  if [ -f "$DRAIN" ]; then
    { IFS= read -r previous_session; IFS= read -r previous_call; IFS= read -r previous_kinds; } < "$DRAIN" || true
  fi
  kinds=$(printf '%s\n' "$rows" | awk -F '\t' '
    NF >= 5 {
      if ($3 == "stale" && NF == 6 && $6 == "idle-recheck") print "idle-recheck"
      else if ($3 ~ /^(check|heartbeat|signal|stale)$/) print $3
      else print "unknown"
    }
  ' | LC_ALL=C sort -u | paste -sd' ' -)
  if [ "$previous_session" = "$SESSION" ] && [ "$previous_call" = "$cycle_call" ]; then
    kinds=$(printf '%s\n%s\n' "$kinds" "$previous_kinds" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort -u | paste -sd' ' -)
  fi
  printf '%s\n' "$SESSION" "$cycle_call" "$kinds" | publish "$DRAIN"
}
record_verdict() {
  local claim=$1 detail=$2 verdict=$3 observed=$4 tmp
  command -v jq >/dev/null 2>&1 || return 1
  tmp=$(umask 077; mktemp "$STATE/.omp-transition.XXXXXX") || return 1
  if [ -f "$LOG" ]; then
    tail -n 255 "$LOG" > "$tmp" || { rm -f "${tmp:?}"; return 1; }
  fi
  if jq -cn --arg session "$SESSION" --arg call "$CALL" --arg claim "$claim" \
    --arg detail "$detail" --arg verdict "$verdict" --arg observed "$observed" \
    '{session:$session,call:$call,claim:$claim,detail:$detail,verdict:$verdict,observed:$observed}' >> "$tmp" \
    && mv -f "$tmp" "$LOG"; then return 0; fi
  rm -f "${tmp:?}"
  return 1
}
observe() {
  local f open snapshot inbox_path inbox_rows drain_session drain_call kinds
  OBSERVED=unknown
  if [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-daemon-terminal" ]; then OBSERVED=away; return; fi
  if [ -e "$STATE/.captain-hold" ]; then OBSERVED=hold; return; fi
  if [ -f "$RECOVERY" ] && [ "$(cat "$RECOVERY")" = "$SESSION" ]; then OBSERVED=recovery; return; fi
  if [ ! -e "$CYCLE" ]; then OBSERVED=startup; return; fi
  load_cycle || return
  if [ "$cycle_session" != "$SESSION" ]; then OBSERVED=startup; return; fi
  case "$phase" in
    failed|starting) OBSERVED=repair; return ;;
    running)
      if ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then
        OBSERVED=repair; return
      fi
      ;;
  esac
  if [ -s "$FM_WAKE_QUEUE" ]; then OBSERVED=queued-wakes; return; fi
  for f in "$STATE/"*.status; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || return
    open=$(status_open_decisions "$f") || return
    if [ -n "$open" ]; then OBSERVED=decision; return; fi
  done
  command -v jq >/dev/null 2>&1 || return
  if [ -e "$CONFIG/decision-inbox" ] || [ -L "$CONFIG/decision-inbox" ]; then
    inbox_path=$(cat "$CONFIG/decision-inbox") || return
    case "$inbox_path" in ''|*$'\n'*) return ;; /*) ;; *) inbox_path="$FM_HOME/$inbox_path" ;; esac
    inbox_rows=$(set -o pipefail; jq -c -f "$CONFIG/decision-inbox-query.jq" "$inbox_path" 2>/dev/null | jq -cs '.') || return
    printf '%s' "$inbox_rows" | jq -e 'length == 1 and (.[0] | type == "array" and all(.[]; type == "array" and length == 4 and all(.[]; type == "string")))' >/dev/null 2>&1 || return
    if [ "$(printf '%s' "$inbox_rows" | jq '.[0] | length')" -gt 0 ]; then OBSERVED=decision; return; fi
  fi
  snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null) || return
  printf '%s' "$snapshot" | jq -e '.schema == "fm-secondmate-home-summary.v1" and .valid == true' >/dev/null 2>&1 || return
  if printf '%s' "$snapshot" | jq -e '.counts.decisions_open > 0 or .counts.holds > 0 or any(.queued[]; .hold_kind != null)' >/dev/null 2>&1; then
    OBSERVED=decision; return
  fi
  if printf '%s' "$snapshot" | jq -e 'any(.active_children[]; .source != "pane" and .source != "run-step") or any(.omitted[]; .surface != "landed")' >/dev/null 2>&1; then return; fi
  [ -f "$DRAIN" ] || return
  { IFS= read -r drain_session && IFS= read -r drain_call && IFS= read -r kinds; } < "$DRAIN" || return
  [ "$drain_session" = "$SESSION" ] && [ "$drain_call" = "$cycle_call" ] || return
  case "$kinds" in
    idle-recheck) OBSERVED=idle-recheck ;;
    *)
      if printf '%s\n' "$kinds" | grep -Eq '^(check|heartbeat|signal|stale|idle-recheck)( (check|heartbeat|signal|stale|idle-recheck))*$'; then
        OBSERVED=clean
      fi
      ;;
  esac
}
arm_transition() {
  local claim=$1 detail=$2 verdict=allow observed
  observe
  observed=$OBSERVED
  if [ "$observed" = unknown ] && [ -n "$claim" ] && [ "$claim" != unknown ]; then
    warn 'transition evidence is unknown despite the declaration'
  fi
  case "$claim" in
    '')
      case "$observed" in clean) verdict=refuse ;; unknown) warn 'transition state is unknown; supply --transition unknown --reason with the unresolved state' ;; esac
      ;;
    watching-only) [ "$observed" != clean ] || verdict=refuse ;;
    unknown) warn "declared unknown transition: $detail" ;;
    work-pending|unanswered-input|chat-question|stow-incomplete) ;;
    decision|idle-recheck)
      [ "$observed" = "$claim" ] || { observed=unknown; warn "could not verify the declared $claim: $detail"; }
      ;;
    *) echo 'watcher: invalid --transition; see fm-watch-arm.sh --help' >&2; return 2 ;;
  esac
  if [ -n "$claim" ] && [ -z "$detail" ]; then
    echo 'watcher: --transition requires a nonempty --reason' >&2; return 2
  fi
  if ! record_verdict "$claim" "$detail" "$verdict" "$observed"; then
    warn 'could not persist the transition verdict'
    return 0
  fi
  if [ "$verdict" = refuse ]; then
    echo 'watcher: reset required - use firstmate_watch_reset for this clean watching-only transition; otherwise declare the work or unanswered input that prevents reset with --transition and --reason.' >&2
    return 2
  fi
  if [ "$observed" = recovery ]; then rm -f "${RECOVERY:?}"; fi
}

if [ "${1:-}" = --help ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi
[ "${OMPCODE:-}" = 1 ] || exit 0
case "${1:-}" in
  recovery)
    [ -n "${2:-}" ] || exit 2
    printf '%s\n' "$2" | publish "$RECOVERY"
    ;;
  *)
    if [ -z "$SESSION" ] || [ -z "$CALL" ]; then warn 'native omp session or tool identity is unavailable'; exit 0; fi
    case "${1:-}" in
      cycle) record_cycle "$2" "$3" "$4" ;;
      drain) record_drain ;;
      arm) arm_transition "${2:-}" "${3:-}" ;;
      *) exit 2 ;;
    esac
    ;;
esac
