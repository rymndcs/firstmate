#!/usr/bin/env bash
# Move only the Jira status for registered Thanos PRs.
# Usage: fm-jira.sh transition <task-id> in-review|done
#        fm-jira.sh merged <github-pr-url>
# fm-pr-check.sh owns Ready for Review; fm-pr-merge.sh and fm-pr-poll.sh own Done.
# Resolve SWVL keys from the recorded branch, falling back to the PR title/branch.
# Each PR has a serialized, forward-only receipt shared across task registrations.
# Missing or failed jira prints one manual-move line on stderr and exits 0.
# A durable check wake retains that line when the polling caller discards stderr.
# Failed attempts are receipted too: the diagnostic hands the move off by hand.
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
  fm_pr_task_id_valid "$id" || exit 0
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || exit 0
  project=$(sed -n 's/^project=//p' "$meta")
  [ "${project##*/}" = thanos ] || exit 0
  [ -f "$DATA/projects.md" ] && awk '$1 == "-" && $2 == "thanos" {found=1} END {exit !found}' "$DATA/projects.md" || exit 0
  fm_pr_metadata_identity_parse "$meta" && [ "$FM_PR_META_PROVIDER" = github ] || exit 0
  url=$FM_PR_META_URL
  [ -z "${MERGED_URL:-}" ] || [ "$url" = "$MERGED_URL" ] || exit 0
  branch=$(sed -n 's/^branch=//p' "$meta")
  ticket=$(identifier "$branch")
  if [ -z "$ticket" ]; then
    ref=$(gh-axi api "/repos/$FM_PR_META_PATH/pulls/$FM_PR_META_NUMBER" --jq '.title + " " + .head.ref' 2>/dev/null) || exit 0
    ticket=$(identifier "$ref")
  fi
  [ -n "$ticket" ] || exit 0
  fm_pr_url_parse "$url" || exit 0
  dir="$STATE/jira/$FM_PR_HOST/$FM_PR_PATH/$FM_PR_NUMBER"
  mkdir -p "$dir"
  lock="$dir/transition.lock"
  fm_lock_acquire_wait "$lock"
  tmp=
  trap 'fm_lock_release "$lock"; [ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  receipt="$dir/transitions"
  if [ -f "$receipt" ] && { grep -qxF 'done' "$receipt" || grep -qxF "$step" "$receipt"; }; then
    exit 0
  fi
  case "$step" in
    in-review) label='Ready for Review' ;;
    done) label=Done ;;
    *) exit 0 ;;
  esac
  tmp=$(mktemp "$dir/.transition.XXXXXX")
  if [ -f "$receipt" ]; then cat "$receipt" > "$tmp"; fi
  printf '%s\n' "$step" >> "$tmp"
  chmod 0600 "$tmp"
  if ! command -v jira >/dev/null 2>&1 || ! jira issue move "$ticket" "$label" > /dev/null 2>&1; then
    manual="JIRA: move $ticket to $label yourself - jira CLI unavailable or move failed"
    printf '%s\n' "$manual" >&2
    fm_wake_append check "jira:$url:$step" "check: $manual" || true
  fi
  mv -f -- "$tmp" "$receipt"
  tmp=
)

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
      transition_one "$(basename "$meta" .meta)" 'done' || true
    done
    ;;
  --help|-h) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0" ;;
esac
exit 0
