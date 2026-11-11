#!/usr/bin/env bash
# Scoped process-kill PreToolUse transport for Claude and Codex.
# Usage: fm-process-pretool-check.sh [--home <firstmate-home>] [--claude]
#        [--command <exact-shell-command>]
# With no --command, consumes Claude/Codex tool_input.command JSON on stdin.
# Scope is the physical hook cwd: a recorded task worktree or descendant, or
# anywhere below $HOME/.no-mistakes. Secondmate metadata discovers child homes.
# --home defaults to FM_HOME, then this script's code root. Worker launches pin
# it explicitly. Outside scope: silent exit 0, even with malformed input.
# Inside scope: exit 0 allows; exit 2 and stderr denies. Stdout stays empty.
# Missing policy/runtime or invalid input denies within confirmed scope.
# The Node policy imports the shared shell classifier; no command is executed.
# See docs/process-kill-guard.md for the contract and coverage boundary.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || exit 2
CODE_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P) || exit 2
GUARD_HOME=${FM_HOME:-$CODE_ROOT}
POLICY_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || exit 2
      GUARD_HOME=$2
      shift 2
      ;;
    --claude) shift ;;
    --command)
      [ "$#" -ge 2 ] || exit 2
      POLICY_ARGS+=(--command "$2")
      shift 2
      ;;
    --help|-h)
      sed -n '2,14{s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) exit 2 ;;
  esac
done

HERE=$(pwd -P) || exit 2
within() {
  local parent
  parent=$(CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || return 1
  [ "$HERE" = "$parent" ] || [[ "$HERE" = "$parent/"* ]]
}

task_home() {
  local home=$1 depth=$2 meta line task kind child
  [ "$depth" -le 4 ] || return 1
  for meta in "$home"/state/*.meta; do
    [ -f "$meta" ] || continue
    task='' kind='' child=''
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        worktree=*) task=${line#worktree=} ;;
        kind=*) kind=${line#kind=} ;;
        home=*) child=${line#home=} ;;
      esac
    done < "$meta"
    if [ "$kind" = secondmate ]; then
      if [ -n "$child" ] && task_home "$child" "$((depth + 1))"; then return 0; fi
    elif [ -n "$task" ] && within "$task"; then
      return 0
    fi
  done
  return 1
}

if ! within "${HOME:?}/.no-mistakes" && ! task_home "$GUARD_HOME" 0; then
  exit 0
fi
if ! command -v node >/dev/null 2>&1 || [ ! -f "$CODE_ROOT/bin/fm-process-command-policy.mjs" ]; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[process-kill] classifier unavailable; use explicit positive PID arguments after restoring the guard runtime."}' >&2
  exit 2
fi
if [ "${#POLICY_ARGS[@]}" -gt 0 ]; then
  detail=$(node "$CODE_ROOT/bin/fm-process-command-policy.mjs" "${POLICY_ARGS[@]}" 2>&1)
else
  detail=$(node "$CODE_ROOT/bin/fm-process-command-policy.mjs" 2>&1)
fi
result=$?
if [ "$result" -eq 0 ] && [ -z "$detail" ]; then exit 0; fi
if [ "$result" -eq 2 ]; then
  printf '%s\n' "$detail" >&2
else
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[process-kill] classifier failed; restore the guard and use explicit positive PID arguments."}' >&2
fi
exit 2
