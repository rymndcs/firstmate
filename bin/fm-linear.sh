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
#   bin/fm-spawn.sh     in-progress  after a successful ship or scout spawn
#   bin/fm-pr-check.sh  in-review    when a PR is recorded against the task
#   bin/fm-pr-merge.sh  done         after a merge is confirmed
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
# ISSUE RESOLUTION, in order:
#   1. branch=<name> in state/<task-id>.meta - the Linear branch name that
#      bin/fm-brief.sh --branch recorded (rcs/rac-125-select2-font-size).
#   2. the task id itself (rac125-select2-font-size).
# Both yield RAC-125. A team key that contains digits is resolvable only
# through the recorded branch name, where the dash separates key from number.
# A task with NO resolvable identifier is the normal case rather than an error,
# because most firstmate tasks are not Linear-tracked: it exits 0 in silence,
# as does an issue that already sits in the target state.
#
# TARGET STATE, matched case-insensitively by name against the issue's own
# team, in preference order:
#   in-progress  In Progress, Started     (else the first `started` state)
#   in-review    In Review, Code Review   (no type fallback: `started` covers
#                                          In Progress AND In Review, so a type
#                                          guess could move the issue backwards)
#   done         Done, Completed, Merged  (else the first `completed` state)
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

# A Linear team key is uppercase alphanumeric, and only an all-letter key of two
# to five characters can be told apart from the issue number in the run-together
# task-id form, so that is what both resolvers accept. Sets TEAM_KEY and
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

# rac125-select2-font-size -> RAC 125, the fallback used when the task recorded
# no branch of its own.
identifier_from_task_id() {  # <task-id>
  local id=$1 head key
  head=${id%%-*}
  key=${head%%[0-9]*}
  accept_identifier "$key" "${head#"$key"}"
}

# The identifier for a task, preferring its recorded branch name. Failure means
# "not Linear-tracked", never an error.
resolve_identifier() {  # <task-id>
  local id=$1 meta branch
  meta="$STATE/$id.meta"
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    branch=$(sed -n 's/^branch=//p' "$meta" | tail -n 1)
    if [ -n "$branch" ] && identifier_from_branch "$branch"; then
      return 0
    fi
  fi
  identifier_from_task_id "$id"
}

# --- transition vocabulary --------------------------------------------------

transition_targets() {  # <transition>
  case "$1" in
    in-progress)
      STATE_NAMES='["In Progress","Started"]'
      STATE_FALLBACK_TYPE=started
      ;;
    in-review)
      STATE_NAMES='["In Review","Code Review"]'
      STATE_FALLBACK_TYPE=
      ;;
    done)
      STATE_NAMES='["Done","Completed","Merged"]'
      STATE_FALLBACK_TYPE=completed
      ;;
    *) return 1 ;;
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
graphql() {  # <payload-file> <body-file>
  local payload=$1 body=$2 code
  code=$(curl -m 20 -s -o "$body" -w '%{http_code}' \
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
  local id transition tool query mutation payload body code issue current target_id target_name
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

  # issue id, current state id, target state id, target state name.
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
    | [$issue.id, ($issue.state.id // ""), ($target.id // ""), ($target.name // "")]
    | @tsv
  ' "$body" 2>/dev/null) || issue=
  [ -n "$issue" ] \
    || loud "$IDENT -> $transition failed - that issue is not in the workspace this Linear API key can read"

  IFS=$'\t' read -r ISSUE_ID current target_id target_name <<EOF
$issue
EOF
  [ -n "$ISSUE_ID" ] \
    || loud "$IDENT -> $transition failed - that issue is not in the workspace this Linear API key can read"
  [ -n "$target_id" ] \
    || loud "$IDENT -> $transition failed - that issue's team has no matching workflow state; add one or move the issue by hand"
  # Already there: nothing to do, and nothing worth saying.
  [ "$current" != "$target_id" ] || exit 0

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
