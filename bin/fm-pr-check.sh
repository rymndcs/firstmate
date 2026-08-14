#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
#
# Standing knowledge at the pr-ready moment, printed to STDERR after the poll is
# armed, in two parts:
#   1. The verbatim data/captain.md and data/learnings.md sections tagged
#      `pr-ready` (bin/fm-standing-knowledge.sh owns the tag format).
#   2. The task project's verbatim data/projects.md registry entry, as the
#      merge-authority source. The ENTRY is printed, not a parsed flag: a
#      project's merge authority can live in the freeform prose beside its
#      `[mode]` annotation, and a flag-parser reproduces exactly the failure this
#      output exists to remove. bin/fm-project-mode.sh remains the only parser,
#      and it deliberately answers a different question (registered delivery
#      posture), so nothing here reads or contradicts it.
# Both are advisory: this script surfaces the source and never decides a merge.
# An unregistered project prints an explicit unregistered notice, a missing
# registry prints an explicit diagnostic, and neither aborts the recording or
# the arming that already succeeded.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"

# The PR now exists, which is the moment merge authority binds. Surface the
# captain's own words for it rather than a verdict derived from them: the
# pr-ready rule slice, then this project's verbatim registry entry.
"$SCRIPT_DIR/fm-standing-knowledge.sh" pr-ready || true
print_registry_entry() {
  local registry="$DATA/projects.md" project name entry
  project=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  if [ -z "$project" ]; then
    printf 'standing-knowledge: task %s records no project; its merge-authority entry cannot be printed\n' \
      "$ID" >&2
    return 0
  fi
  name=$(basename -- "$project")
  if [ ! -f "$registry" ] || [ ! -r "$registry" ]; then
    printf 'standing-knowledge: data/projects.md is missing or unreadable at %s; the merge-authority source for %s cannot be printed\n' \
      "$registry" "$name" >&2
    return 0
  fi
  # An entry is its "- <name> ..." line plus any continuation lines up to the
  # next entry or heading, printed exactly as written.
  entry=$(awk -v n="$name" '
    $1 == "-" && $2 == n { found = 1; print; next }
    found && (/^- / || /^#/) { exit }
    found { print }
  ' "$registry")
  if [ -z "$entry" ]; then
    printf 'standing-knowledge: %s has no entry in data/projects.md; its merge authority is unregistered and belongs to the captain\n' \
      "$name" >&2
    return 0
  fi
  printf -- '--- merge-authority source for %s (data/projects.md) ---\n' "$name" >&2
  printf '%s\n' "$entry" >&2
  printf -- '--- end merge-authority source for %s ---\n' "$name" >&2
}
print_registry_entry

# Recording a PR against the task IS the In Review transition, so it happens
# here rather than as a step an agent has to remember afterwards.
# bin/fm-linear.sh is silent for a task with no Linear identifier, nudges on
# stderr for a resolvable issue with no API key configured, reports loudly on
# stderr when a configured update fails, and can never unmake the poll this
# run already armed.
"$SCRIPT_DIR/fm-linear.sh" transition "$ID" in-review || true
