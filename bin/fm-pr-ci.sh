#!/usr/bin/env bash
# Publish a GitHub CI observation only for canonical registrations of that URL.
# The per-task receipt retains URL/head/outcome identities across retries,
# re-registration and restarts. Queue before receipt, then print the observation
# to wake the watcher; its matching queue append collapses at drain as usual.
# An interrupted publication may replay, matching the queue's at-least-once rule.
# Usage: fm-pr-ci.sh <github-pr-url> <head-sha> ci-pass|ci-fail
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi
[ "$#" -eq 3 ] || exit 2
fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] && fm_pr_head_valid "$2" || exit 2
case "$3" in ci-pass|ci-fail) ;; *) exit 2 ;; esac
URL=$1 HEAD=$2 OUTCOME=$3

publish_one() (
  local id=$1 receipt="$STATE/$1.pr-ci" record="$URL $HEAD $OUTCOME" tmp=''
  fm_lock_try_acquire "$STATE/$id.pr-ci.lock" || return 0
  trap 'fm_lock_release "$STATE/$id.pr-ci.lock"; [ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  fm_pr_poll_artifacts_valid "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 0
  [ "$FM_PR_META_URL" = "$URL" ] || return 0
  fm_pr_regular_destination_or_absent "$receipt" || return 1
  if [ -f "$receipt" ] && grep -qxF "$record" "$receipt"; then
    return 0
  fi
  tmp=$(mktemp "$STATE/.pr-ci.XXXXXX") || return 1
  if [ -f "$receipt" ]; then cat "$receipt" > "$tmp" || return 1; fi
  printf '%s\n' "$record" >> "$tmp" && chmod 0600 "$tmp" || return 1
  fm_wake_append check "$STATE/$id.check.sh" "check: $STATE/$id.check.sh: $OUTCOME head=$HEAD PR $URL" || return 1
  fm_pr_regular_destination_or_absent "$receipt" && mv -f -- "$tmp" "$receipt" || return 1
  tmp=''
  printf '%s head=%s PR %s\n' "$OUTCOME" "$HEAD" "$URL"
)

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  fm_pr_task_id_valid "$id" || continue
  fm_pr_metadata_identity_parse "$meta" && [ "$FM_PR_META_URL" = "$URL" ] || continue
  publish_one "$id" || exit 1
done
