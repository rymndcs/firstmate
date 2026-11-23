#!/usr/bin/env bash
# Queue once-per-PR merge follow-up reminders for registered Thanos PRs.
# Usage: fm-jira.sh owe|publish <task-id>
#        fm-jira.sh merged|followups <github-pr-url>
#        fm-jira.sh cleanup <task-id>|--home
#        fm-jira.sh retry-followups
# Each merged advisorfirst/thanos PR gets one check wake naming its two
# follow-ups: MCP coverage in a separate PR, and the /help-center update.
# Thanos ticket status is not moved here: Swivel Cards moves the card from the
# card key in the PR title or branch.
# The script keeps its historical name and state/jira/ path so running
# watchers and existing owed reminders keep working.
# fm-pr-merge.sh runs owe then publish after a confirmed merge; fm-pr-poll.sh
# runs merged; fm-watch.sh requires followups to succeed before retiring a
# merged poll, since followups returns nonzero on publication failure.
# Merge follow-ups use state/jira/<host>/<path>/<number>/followups.lock.
# Under that lock, followups.owed records the merged URL before publication;
# only a successful queue append and followups receipt clear the obligation.
# Task cleanup honors a URL-bearing success receipt before querying merge state,
# establishes owed work or refuses deletion, and attempts publication while
# preserving this directory; retry-followups and wake drain can replay it
# without task metadata or registry.
# When cleanup is the first to record the obligation, the merge-time
# fm-linear.sh Done move was skipped, so cleanup replays it once.
# cleanup guards task and whole-home removal through the same owner; a home
# cannot be removed while it holds unpaid or queued-undelivered merge reminders.
# Task removal may proceed once owed work is safely held outside task records.
# FM_JIRA_TIMEOUT bounds reminder publication and the cleanup merge-state
# lookup (default 5 seconds, plus the deadline helper's kill grace).
# Other projects and other repositories stay silent.
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

task_followups() (
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
  recorded=1
  if [ "$step" = cleanup ]; then
    if ! followups_published "$url"; then
      merged_state=$(fm_axi_bounded_run "${FM_JIRA_TIMEOUT:-5}" gh pr view "$url" --json state -q .state) || exit 2
      [ "$merged_state" = MERGED ] || exit 0
      [ -f "$STATE/jira/$FM_PR_META_HOST/$FM_PR_META_PATH/$FM_PR_META_NUMBER/followups.owed" ] || recorded=0
    fi
  fi
  fm_axi_bounded_run "${FM_JIRA_TIMEOUT:-5}" bash "$SCRIPT_DIR/fm-jira.sh" --followups "$url" owe || {
    printf 'MERGE FOLLOW-UPS: %s - could not record owed reminder\n' "$url" >&2
    exit 2
  }
  case "$step" in
    owe) exit 0 ;;
    followups) publish_followups_bounded "$url" || exit 2 ;;
    *)
      if [ "$recorded" -eq 0 ]; then
        "$SCRIPT_DIR/fm-linear.sh" transition "$id" 'done' || true
      fi
      publish_followups_bounded "$url" || true ;;
  esac
  exit 0
)

followups_published() {
  local url=$1
  fm_pr_url_parse "$url" || return 1
  grep -qxF "$url" "$STATE/jira/$FM_PR_HOST/$FM_PR_PATH/$FM_PR_NUMBER/followups" 2>/dev/null
}

guard_removal() {
  local container=$1 result=0 owed key keys
  if [ "$container" = task ]; then
    task_followups "$2" cleanup || result=$?
    [ "$result" -ne 2 ]
    return
  fi
  for owed in "$STATE"/jira/*/*/*/*/followups.owed; do
    [ ! -f "$owed" ] || return 1
  done
  keys=$(fm_wake_queued_keys check) || return 1
  while IFS= read -r key; do
    case "$key" in
      merge-followups:*)
        if fm_pr_url_parse "${key#merge-followups:}"; then
          return 1
        fi ;;
    esac
  done <<EOF
$keys
EOF
  return 0
}

publish_followups_bounded() {
  if fm_axi_bounded_run "${FM_JIRA_TIMEOUT:-5}" bash "$SCRIPT_DIR/fm-jira.sh" --followups "$1"; then
    return 0
  fi
  printf 'MERGE FOLLOW-UPS: %s - publication failed; retry on the next merge observation\n' "$1" >&2
  return 1
}

publish_followups() {
  url=$1 action=${2:-publish}
  fm_pr_url_parse "$url" || exit 1
  dir="$STATE/jira/$FM_PR_HOST/$FM_PR_PATH/$FM_PR_NUMBER"
  mkdir -p "$dir"
  lock="$dir/followups.lock"
  trap 'fm_lock_release "$lock"' EXIT
  trap 'exit 1' HUP INT TERM
  fm_lock_acquire_wait "$lock"
  if ! { [ "$FM_PR_PROVIDER" = github ] && [ "$(printf '%s' "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')" = advisorfirst/thanos ]; }; then
    printf '%s\n' "$url" > "$dir/followups" || exit 1
    return 0
  fi
  if [ "$action" = owe ]; then
    if ! followups_published "$url"; then
      printf '%s\n' "$url" > "$dir/followups.owed" || exit 1
    fi
    exit 0
  fi
  if ! followups_published "$url"; then
    fm_wake_append check "merge-followups:$url" "check: MERGE FOLLOW-UPS: $url - (1) check MCP covers what changed unless explicitly skipped; put any MCP gap in a separate follow-up PR; (2) update /help-center with the change" || exit 1
    printf '%s\n' "$url" > "$dir/followups" || exit 1
  fi
  rm -f -- "${dir:?}"/followups.owed
}

retry_followups() (
  result=0
  for owed in "$STATE"/jira/*/*/*/*/followups.owed; do
    [ -f "$owed" ] || continue
    url=$(cat "$owed")
    publish_followups_bounded "$url" || result=1
  done
  exit "$result"
)

case "${1:-}" in
  owe|publish)
    [ "$#" -eq 2 ] || exit 1
    result=0
    task_followups "$2" "$1" || result=$?
    [ "$result" -ne 2 ] || exit 1
    ;;
  cleanup)
    [ "$#" -eq 2 ] || exit 1
    if [ "$2" = --home ]; then
      fm_axi_bounded_run "${FM_JIRA_TIMEOUT:-5}" bash "$SCRIPT_DIR/fm-jira.sh" --guard-home || exit 1
    else
      guard_removal task "$2" || exit 1
    fi
    ;;
  --guard-home)
    guard_removal home || exit 1
    ;;
  retry-followups)
    retry_followups
    ;;
  merged|followups)
    [ "$#" -eq 2 ] || exit 0
    step=merged
    [ "$1" != followups ] || step=followups
    MERGED_URL=$2
    fm_pr_url_parse "$MERGED_URL" && [ "$FM_PR_PROVIDER" = github ] || exit 0
    if [ "$step" = followups ] && [ -f "$STATE/jira/$FM_PR_HOST/$FM_PR_PATH/$FM_PR_NUMBER/followups.owed" ]; then
      publish_followups_bounded "$FM_PR_URL"
      exit "$?"
    fi
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      result=0
      task_followups "$(basename "$meta" .meta)" "$step" || result=$?
      case "$result" in
        0) exit 0 ;;
        2) exit 1 ;;
      esac
    done
    ;;
  --followups)
    publish_followups "$2" "${3:-publish}"
    ;;
  --help|-h) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0" ;;
esac
exit 0
