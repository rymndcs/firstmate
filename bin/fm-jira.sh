#!/usr/bin/env bash
# Move Jira status and queue merge follow-ups for registered Thanos PRs.
# Usage: fm-jira.sh transition <task-id> in-review|done
#        fm-jira.sh merged <github-pr-url>
# fm-pr-check.sh owns Ready for Review; fm-pr-merge.sh and fm-pr-poll.sh own Done.
# Resolve SWVL keys from the recorded branch, falling back to the PR title/branch.
# Each PR has a serialized, forward-only receipt shared across task registrations.
# Missing or failed jira prints one manual-move line on stderr and exits 0.
# A durable check wake retains that line when the polling caller discards stderr.
# Failed attempts are receipted too: the diagnostic hands the move off by hand.
# FM_JIRA_TIMEOUT bounds each attempt, including lookup and lock waits (default
# 5 seconds, plus the deadline helper's kill grace); timeouts remain retryable.
# Merge follow-ups have their own per-PR lock and receipt before Jira work.
# No comments or other Jira fields are written; other projects stay silent.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-dispatch-axi-lib.sh
. "$SCRIPT_DIR/fm-dispatch-axi-lib.sh"

identifier() {
  printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]' | awk '
    match($0, /(^|[^A-Z0-9])SWVL-[0-9]+([^A-Z0-9]|$)/) {
      key=substr($0, RSTART, RLENGTH)
      sub(/^[^S]*/, "", key); sub(/[^0-9]$/, "", key)
      print key; exit
    }'
}

transition_one() (
  id=$1 step=$2
  fm_pr_task_id_valid "$id" || exit 1
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || exit 1
  project=$(sed -n 's/^project=//p' "$meta")
  [ "${project##*/}" = thanos ] || exit 1
  [ -f "$DATA/projects.md" ] && awk '$1 == "-" && $2 == "thanos" {found=1} END {exit !found}' "$DATA/projects.md" || exit 1
  fm_pr_metadata_identity_parse "$meta" && [ "$FM_PR_META_PROVIDER" = github ] || exit 1
  url=$FM_PR_META_URL
  [ -z "${MERGED_URL:-}" ] || [ "$url" = "$MERGED_URL" ] || exit 1
  branch=$(sed -n 's/^branch=//p' "$meta")
  ticket=$(identifier "$branch")
  case "$step" in
    in-review) label='Ready for Review' ;;
    done) label=Done ;;
    *) exit 1 ;;
  esac
  if ! resolved=$(fm_axi_bounded_run "${FM_JIRA_TIMEOUT:-5}" bash "$SCRIPT_DIR/fm-jira.sh" --attempt "$url" "$step" "$ticket" "$label"); then
    manual="JIRA: move ${resolved:-${ticket:-$url}} to $label yourself - jira CLI unavailable or move failed"
    printf '%s\n' "$manual" >&2
    fm_axi_bounded_run "${FM_JIRA_TIMEOUT:-5}" bash "$SCRIPT_DIR/fm-jira.sh" --manual "$url" "$step" "$manual" || true
  fi
  exit 0
)

transition_attempt() {
  url=$1 step=$2 ticket=$3 label=$4
  fm_pr_url_parse "$url" || exit 1
  dir="$STATE/jira/$FM_PR_HOST/$FM_PR_PATH/$FM_PR_NUMBER"
  mkdir -p "$dir"
  lock="$dir/transition.lock"
  tmp=
  child=
  trap '
    if [ -n "$child" ]; then
      kill -KILL "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
    fi
    fm_lock_release "$lock"
    [ -z "$tmp" ] || rm -f -- "${tmp:?}"
  ' EXIT
  trap 'exit 1' HUP INT TERM
  if [ "$step" = 'done' ]; then
    lock="$dir/followups.lock"
    fm_lock_acquire_wait "$lock"
    if [ ! -f "$dir/followups" ]; then
      fm_wake_append check "merge-followups:$url" "check: MERGE FOLLOW-UPS: $url - (1) check MCP covers what changed unless explicitly skipped; put any MCP gap in a separate follow-up PR; (2) update /help-center with the change" || exit 1
      printf '%s\n' "$url" > "$dir/followups"
    fi
    fm_lock_release "$lock"
    lock="$dir/transition.lock"
  fi
  if [ -z "$ticket" ]; then
    tmp=$(mktemp "$dir/.transition.XXXXXX")
    gh-axi api "/repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" --jq '.title + " " + .head.ref' > "$tmp" 2>/dev/null &
    child=$!
    if wait "$child"; then child=; else child=; exit 1; fi
    ref=$(cat "$tmp")
    ticket=$(identifier "$ref")
  fi
  [ -n "$ticket" ] || exit 0
  printf '%s\n' "$ticket"
  fm_lock_acquire_wait "$lock"
  receipt="$dir/transitions"
  if [ -f "$receipt" ] && { grep -qxF 'done' "$receipt" || grep -qxF "$step" "$receipt"; }; then
    exit 0
  fi
  [ -n "$tmp" ] || tmp=$(mktemp "$dir/.transition.XXXXXX")
  : > "$tmp"
  if [ -f "$receipt" ]; then cat "$receipt" > "$tmp"; fi
  printf '%s\n' "$step" >> "$tmp"
  chmod 0600 "$tmp"
  failed=1
  if command -v jira >/dev/null 2>&1; then
    jira issue move "$ticket" "$label" > /dev/null 2>&1 &
    child=$!
    if wait "$child"; then failed=0; fi
    child=
  fi
  mv -f -- "$tmp" "$receipt"
  tmp=
  exit "$failed"
}

case "${1:-}" in
  transition)
    [ "$#" -eq 3 ] || exit 0
    transition_one "$2" "$3" || true
    ;;
  merged)
    [ "$#" -eq 2 ] || exit 0
    MERGED_URL=$2
    fm_pr_url_parse "$MERGED_URL" && [ "$FM_PR_PROVIDER" = github ] || exit 0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      if transition_one "$(basename "$meta" .meta)" 'done'; then break; fi
    done
    ;;
  --attempt)
    [ "$#" -eq 5 ] || exit 1
    transition_attempt "$2" "$3" "$4" "$5"
    ;;
  --manual)
    [ "$#" -eq 4 ] || exit 1
    fm_wake_append check "jira:$2:$3" "check: $4"
    ;;
  --help|-h) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0" ;;
esac
exit 0
