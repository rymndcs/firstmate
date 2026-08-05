#!/usr/bin/env bash
# fm-linear.sh - single owner of Linear API mechanics for firstmate.
# It moves a Linear-tracked task's issue as PART of the lifecycle step that
# already happened, so the transition is never something an agent has to
# remember afterwards.
#
# Usage:
#   fm-linear.sh transition <task-id> in-progress|in-review|done
#   fm-linear.sh resolve <task-id>     # print the resolved issue identifier
#   fm-linear.sh -h | --help
#
# Lifecycle owners, one transition each:
#   bin/fm-spawn.sh        in-progress  after a successful ship or scout spawn
#   bin/fm-pr-check.sh     in-review    when a PR is recorded against the task
#   bin/fm-pr-merge.sh     done         after a PR merge is confirmed
#   bin/fm-merge-local.sh  done         after an approved local-only landing
#
# CREDENTIAL
# The key is the first line of the effective home's local, gitignored
# config/linear-api-key (FM_CONFIG_OVERRIDE, else $FM_HOME/config), a Linear
# API key. Absent, unreadable, or empty means the feature is OFF: exit 0, no
# output, no network, firstmate behaves exactly as it did before. The key is
# never printed: it reaches curl only through a 0600 temp header file rather
# than argv, and any Linear-supplied message is redacted before it is reported.
# This file is local to its home and is NOT part of secondmate inherited
# configuration, because pushing a credential to another host is a decision for
# the captain rather than a side effect of provisioning.
#
# ISSUE RESOLUTION
# The issue comes from one place only: branch=<name> in state/<task-id>.meta,
# the Linear branch name that bin/fm-brief.sh --branch recorded, whose leaf
# rac-125-select2-font-size yields RAC-125. Linear-tracked work always carries
# a Linear branch, so a task id is deliberately never read as an issue
# reference: an ordinary id such as db2-index-cleanup would otherwise resolve
# DB-2 and move a completely unrelated issue. Only an all-letter team key of
# two to five characters is accepted, so a team key containing digits has to be
# moved by hand.
# A task with NO resolvable identifier is the normal case rather than an error,
# because most firstmate tasks are not Linear-tracked: it exits 0 in silence
# and never touches the network.
#
# TARGET STATE, matched case-insensitively by name against the issue's own
# team, in preference order:
#   in-progress  In Progress, Started     (else the first `started` state)
#   in-review    In Review, Code Review   (no type fallback: `started` covers
#                                          In Progress AND In Review, so a type
#                                          guess could move the issue backwards)
#   done         Done, Completed, Merged  (else the first `completed` state)
#
# FORWARD ONLY
# Transitions run in the lifecycle order in-progress -> in-review -> done, and
# an issue already sitting at or past the requested step is left exactly where
# it is: no update, no output, exit 0. The issue's CURRENT state is ranked by
# the same vocabulary the targets use, with a `completed` or `canceled` state
# terminal, so re-running a lifecycle step - a second fm-pr-merge.sh against an
# already merged PR, a re-armed fm-pr-check.sh - can never drag an issue
# backwards out of the state a later step gave it.
#
# OUTPUT AND EXIT STATUS
# Every line goes to STDERR, so a caller's stdout contract is unchanged.
# A completed transition prints one `LINEAR: <identifier> -> <state>` line and
# exits 0. A configured key that then fails - missing curl or jq, rejected
# auth, network error, unknown issue, no matching workflow state, refused
# update - prints one `LINEAR: ...` line and exits 1. Callers must invoke it so
# that failure never blocks their own operation: a spawn still spawns and a
# merge still merges while Linear is unreachable.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
KEY_FILE="$CONFIG/linear-api-key"
LINEAR_API=https://api.linear.app/graphql

# Sourced for fm_task_id_path_safe, the one owner of the task-id path rule that
# every task-derived path in this repo is validated against.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

API_KEY=
IDENT=
ISSUE_ID=
TEAM_KEY=
ISSUE_NUMBER=
STATE_NAMES=
STATE_FALLBACK_TYPE=
TARGET_RANK=
WORK=
AUTH_HEADER=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

# One loud, non-blocking diagnostic. The caller keeps going; this exit status
# only tells it that the Linear side did not land.
loud() {
  printf 'LINEAR: %s\n' "$1" >&2
  exit 1
}

# --- identifier resolution --------------------------------------------------

# A Linear team key is uppercase alphanumeric, but only an all-letter key of two
# to five characters is accepted, so an ordinary branch leaf such as
# v2-3-hotfix-rollup is never mistaken for an issue reference. Sets TEAM_KEY and
# ISSUE_NUMBER.
accept_identifier() {  # <key> <number>
  local key=$1 number=$2
  case "$key" in
    [A-Za-z][A-Za-z] | [A-Za-z][A-Za-z][A-Za-z] | \
    [A-Za-z][A-Za-z][A-Za-z][A-Za-z] | [A-Za-z][A-Za-z][A-Za-z][A-Za-z][A-Za-z]) ;;
    *) return 1 ;;
  esac
  case "$number" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#number}" -le 6 ] || return 1
  TEAM_KEY=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')
  ISSUE_NUMBER=$((10#$number))
}

# rcs/rac-125-select2-font-size -> RAC 125. A firstmate default branch such as
# fm/fm-linear-status-binding has no <key>-<number> segment and resolves to
# nothing, which is the silent no-op case.
identifier_from_branch() {  # <branch>
  local branch=$1 leaf rest
  leaf=${branch##*/}
  case "$leaf" in
    *-*) ;;
    *) return 1 ;;
  esac
  rest=${leaf#*-}
  accept_identifier "${leaf%%-*}" "${rest%%-*}"
}

# The identifier for a task, read only from the branch name it recorded.
# Failure means "not Linear-tracked", never an error.
resolve_identifier() {  # <task-id>
  local id=$1 meta branch
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  branch=$(sed -n 's/^branch=//p' "$meta" | tail -n 1)
  [ -n "$branch" ] || return 1
  identifier_from_branch "$branch"
}

# --- transition vocabulary --------------------------------------------------

transition_targets() {  # <transition>
  case "$1" in
    in-progress)
      STATE_NAMES='["In Progress","Started"]'
      STATE_FALLBACK_TYPE=started
      TARGET_RANK=1
      ;;
    in-review)
      STATE_NAMES='["In Review","Code Review"]'
      STATE_FALLBACK_TYPE=
      TARGET_RANK=2
      ;;
    done)
      STATE_NAMES='["Done","Completed","Merged"]'
      STATE_FALLBACK_TYPE=completed
      TARGET_RANK=3
      ;;
    *) return 1 ;;
  esac
}

# Where a workflow state sits in the lifecycle order this script drives: 0 not
# started, 1 in-progress, 2 in-review, 3 terminal. The state's own name decides
# first, because Linear's `started` type covers In Progress AND In Review;
# `completed` and `canceled` are terminal and outrank every target, which is
# what stops a re-run of a landing step from reopening a finished issue.
state_rank() {  # <name> <type>
  local name
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$2" in
    completed|canceled) printf '%s' 3; return 0 ;;
  esac
  case "$name" in
    done|completed|merged) printf '%s' 3 ;;
    'in review'|'code review') printf '%s' 2 ;;
    'in progress'|started) printf '%s' 1 ;;
    *)
      case "$2" in
        started) printf '%s' 1 ;;
        *) printf '%s' 0 ;;
      esac
      ;;
  esac
}

# --- API transport ----------------------------------------------------------

work_cleanup() {
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}

# Replace every occurrence of the key with a placeholder, in-process, so a
# Linear-supplied message can never carry the credential into a log or a pane.
redact() {  # <text>
  local text=$1
  if [ -n "$API_KEY" ]; then
    text=${text//"$API_KEY"/<redacted>}
  fi
  printf '%s' "$text"
}

# POST one GraphQL document and echo the HTTP status; the body lands in <body>.
# The short connect timeout bounds the common partition case, so an unreachable
# Linear costs a lifecycle step seconds rather than the full overall cap.
graphql() {  # <payload-file> <body-file>
  local payload=$1 body=$2 code
  code=$(curl --connect-timeout 5 -m 20 -s -o "$body" -w '%{http_code}' \
    -X POST \
    -H "@$AUTH_HEADER" \
    -H 'Content-Type: application/json' \
    --data-binary "@$payload" \
    "$LINEAR_API" 2>/dev/null) || return 1
  printf '%s' "$code"
}

# The first GraphQL error message, redacted, or the empty string.
graphql_error() {  # <body-file>
  local message
  message=$(jq -r '(.errors[0].message // "") | tostring' "$1" 2>/dev/null) || message=
  [ -z "$message" ] || redact "$message"
}

# ": <message>" when Linear explained itself, otherwise nothing.
reason_suffix() {  # <body-file>
  local message
  message=$(graphql_error "$1")
  [ -z "$message" ] || printf ': %s' "$message"
}

# Why a non-200 answer, or a 200 with nothing usable in it, could not be used.
http_reason() {  # <code> <body-file>
  local code=$1 body=$2
  case "$code" in
    400|401|403) printf 'Linear rejected the API key or request (HTTP %s)' "$code" ;;
    200) printf 'Linear returned no usable answer' ;;
    *) printf 'Linear returned HTTP %s' "$code" ;;
  esac
  reason_suffix "$body"
}

# --- subcommands ------------------------------------------------------------

require_task_id() {  # <task-id>
  fm_task_id_path_safe "${1-}" || { echo "error: invalid task id" >&2; exit 2; }
}

read_api_key() {
  local raw
  [ -f "$KEY_FILE" ] && [ ! -L "$KEY_FILE" ] || return 1
  raw=$(head -n 1 "$KEY_FILE" 2>/dev/null | tr -d '[:space:]') || return 1
  [ -n "$raw" ] || return 1
  API_KEY=$raw
}

cmd_resolve() {  # <task-id>
  require_task_id "${1-}"
  resolve_identifier "$1" || return 0
  printf '%s-%s\n' "$TEAM_KEY" "$ISSUE_NUMBER"
}

cmd_transition() {  # <task-id> <transition>
  local id transition tool query mutation payload body code issue
  local current_name current_type target_id target_name
  id=${1-}
  transition=${2-}
  require_task_id "$id"
  transition_targets "$transition" \
    || { echo "error: unknown transition '$transition'" >&2; exit 2; }

  # Unconfigured and not-Linear-tracked are both ordinary, silent, and free.
  read_api_key || exit 0
  resolve_identifier "$id" || exit 0
  IDENT="$TEAM_KEY-$ISSUE_NUMBER"

  for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 \
      || loud "$IDENT -> $transition failed - $tool is required for the Linear update"
  done

  # Private by construction: everything this run writes lives under one 0700
  # directory removed on every exit path, and the credential header inside it
  # keeps the key out of argv and out of any process listing.
  umask 077
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-linear.XXXXXX") \
    || loud "$IDENT -> $transition failed - no writable temporary directory"
  trap work_cleanup EXIT
  trap 'work_cleanup; exit 143' HUP INT TERM
  payload="$WORK/payload.json"
  body="$WORK/body.json"
  AUTH_HEADER="$WORK/auth"
  printf 'Authorization: %s\n' "$API_KEY" > "$AUTH_HEADER" \
    || loud "$IDENT -> $transition failed - the Linear credential could not be staged"

  # shellcheck disable=SC2016  # $key/$number are GraphQL variables, not shell ones.
  query='query FirstmateIssue($key: String!, $number: Float!) {
  issues(filter: { team: { key: { eq: $key } }, number: { eq: $number } }, first: 1) {
    nodes {
      id
      identifier
      state { id name }
      team { states(first: 100) { nodes { id name type position } } }
    }
  }
}'
  jq -n --arg q "$query" --arg key "$TEAM_KEY" --argjson number "$ISSUE_NUMBER" \
    '{query: $q, variables: {key: $key, number: $number}}' > "$payload" \
    || loud "$IDENT -> $transition failed - the Linear request could not be built"

  code=$(graphql "$payload" "$body") \
    || loud "$IDENT -> $transition failed - Linear could not be reached"
  [ "$code" = 200 ] || loud "$IDENT -> $transition failed - $(http_reason "$code" "$body")"

  # issue id, current state name and type, target state id and name. The
  # current state is read out of the team's own list so it carries the same
  # name and type vocabulary the target was matched against.
  issue=$(jq -r --argjson names "$STATE_NAMES" --arg fallback "$STATE_FALLBACK_TYPE" '
    (.data.issues.nodes[0] // empty) as $issue
    | (($issue.team.states.nodes) // []) as $states
    | ([$names[] as $want
        | $states[]
        | select((.name | ascii_downcase) == ($want | ascii_downcase))] | first) as $named
    | (if $fallback == "" then null
       else ($states | map(select(.type == $fallback)) | sort_by(.position) | first)
       end) as $typed
    | (($named // $typed) // {}) as $target
    | ((($states | map(select(.id == ($issue.state.id // ""))) | first)
        // $issue.state) // {}) as $current
    | [$issue.id, ($current.name // ""), ($current.type // ""),
       ($target.id // ""), ($target.name // "")]
    | @tsv
  ' "$body" 2>/dev/null) || issue=
  [ -n "$issue" ] \
    || loud "$IDENT -> $transition failed - that issue is not in the workspace this Linear API key can read"

  IFS=$'\t' read -r ISSUE_ID current_name current_type target_id target_name <<EOF
$issue
EOF
  [ -n "$ISSUE_ID" ] \
    || loud "$IDENT -> $transition failed - that issue is not in the workspace this Linear API key can read"
  [ -n "$target_id" ] \
    || loud "$IDENT -> $transition failed - that issue's team has no matching workflow state; add one or move the issue by hand"
  # Forward only: an issue already at or past this step - including one already
  # sitting in the target state - keeps the state a later step gave it, with
  # nothing sent and nothing worth saying.
  [ "$(state_rank "$current_name" "$current_type")" -lt "$TARGET_RANK" ] || exit 0

  # shellcheck disable=SC2016  # $id/$stateId are GraphQL variables, not shell ones.
  mutation='mutation FirstmateTransition($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) { success }
}'
  jq -n --arg q "$mutation" --arg id "$ISSUE_ID" --arg stateId "$target_id" \
    '{query: $q, variables: {id: $id, stateId: $stateId}}' > "$payload" \
    || loud "$IDENT -> $target_name failed - the Linear request could not be built"

  code=$(graphql "$payload" "$body") \
    || loud "$IDENT -> $target_name failed - Linear could not be reached"
  [ "$code" = 200 ] || loud "$IDENT -> $target_name failed - $(http_reason "$code" "$body")"
  [ "$(jq -r '.data.issueUpdate.success // false' "$body" 2>/dev/null)" = true ] \
    || loud "$IDENT -> $target_name failed - Linear refused the update$(reason_suffix "$body")"

  printf 'LINEAR: %s -> %s\n' "$IDENT" "$target_name" >&2
}

case "${1-}" in
  transition) shift; cmd_transition "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
