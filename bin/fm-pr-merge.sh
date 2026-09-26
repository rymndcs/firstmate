#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to gh-axi as separate arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Standing knowledge at the merge moment: before the merge is attempted this
# prints to stderr the verbatim knowledge-file sections tagged `merge`
# (bin/fm-standing-knowledge.sh owns the knowledge set and the tag format). It surfaces
# the captain's own words and decides nothing - no merge, authority, or posture
# verdict is derived here, and the print adds no refusal, touches no stdout, and
# can never fail a merge.
# Ship review gate: when this home's config/ship-review-gate requires it, the
# merge refuses before recording the PR or calling gh-axi unless the task's
# status log records a completed review pinned to the PR's current head commit
# (read with `gh pr view`), with an existing report, and names exactly what is
# missing - the same gate bin/fm-merge-local.sh applies, so both landing paths
# hold one standard. The captain's emergency override is
# FM_SHIP_REVIEW_OVERRIDE='<reason>' on one invocation, logged only once the
# merge request has succeeded.
# bin/fm-ship-review-lib.sh owns the line format, the override, and its log;
# docs/configuration.md "Ship review step" owns the config file.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra gh-axi pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-ship-review-lib.sh
. "$SCRIPT_DIR/fm-ship-review-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

# Landing the work is the merge moment: quote the captain's rules for it before
# the merge runs. Advisory only - this changes no merge decision.
"$SCRIPT_DIR/fm-standing-knowledge.sh" merge || true

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

# True when the caller only queued the merge for later: --auto hands the merge
# to the forge, so this run confirms nothing and must transition nothing.
caller_defers_merge() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto|--auto=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

reject_repo_overrides "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# shellcheck disable=SC2329 # Invoked by name from fm_ship_review_gate.
pr_head_commit() { gh pr view "$URL" --json headRefOid -q .headRefOid; }
fm_ship_review_gate "$ID" "$STATE/$ID.status" "$DATA" fm-pr-merge.sh pr_head_commit || exit 1

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

MERGE_STATUS=0
gh-axi pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@" \
  || MERGE_STATUS=$?

# A captain override is recorded only for a merge request that succeeded.
if [ "$MERGE_STATUS" -eq 0 ]; then
  fm_ship_review_record_override
fi

# A confirmed merge IS the Done transition, so it happens here rather than as a
# step an agent has to remember afterwards. bin/fm-linear.sh is silent for a
# task with no Linear identifier, nudges on stderr for a resolvable issue with
# no API key configured, reports loudly on stderr when a configured update
# fails, and can never unmake a merge that already landed. fm-pr-check.sh above
# owns the In Review transition.
if [ "$MERGE_STATUS" -eq 0 ] && ! caller_defers_merge "$@"; then
  "$SCRIPT_DIR/fm-linear.sh" transition "$ID" 'done' || true
fi
exit "$MERGE_STATUS"
