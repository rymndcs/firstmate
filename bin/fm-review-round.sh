#!/usr/bin/env bash
# Launch one fresh adversarial-review role and wait for its exit.
#
# Usage (from the task worktree):
#   fm-review-round.sh --init <task-id>
#   fm-review-round.sh reviewer|fixer --round <N> --in <file> [--out <file>]
#   fm-review-round.sh --help
#
# --init prints a new, unique task directory under the worktree's absolute Git
# directory/adv-review-loop. Keep that directory for all rounds and the report;
# never reuse another task's directory. No previous files are removed.
# --in must be a readable regular file in a subdirectory of that review root.
# Symlink inputs are refused. --out must be a NEW file next to the input;
# default: round-<N>-<role>.out. Both runtime streams go there, including errors.
# A role failure or empty output returns nonzero and names the output file.
#
# Compose ~/.claude/agents/adv-<role>.md, two newlines, "# This round", and the
# input. Round input supplies target, local merge-base, round, final-round flag,
# full ledger, approved findings (fixer), and previous handoff path. Workers
# orchestrate the adv-review-loop skill; this launcher never decides findings.
# The dated captain rule below is compiled from data/captain.md, not read from
# private home files at runtime. Local date selects the runtime; no fallback.
set -euo pipefail

CAPTAIN_REVIEW_CODEX_THROUGH=2026-10-11
CAPTAIN_REVIEW_CODEX_MODEL=gpt-6.1-sol
CAPTAIN_REVIEW_CODEX_REASONING=high
CAPTAIN_REVIEW_CLAUDE_MODEL=opus

die() { printf 'fm-review-round.sh: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  printf '\nCaptain review runtime rule: Codex %s (%s reasoning) through %s inclusive; then Claude %s.\n' \
    "$CAPTAIN_REVIEW_CODEX_MODEL" "$CAPTAIN_REVIEW_CODEX_REASONING" "$CAPTAIN_REVIEW_CODEX_THROUGH" "$CAPTAIN_REVIEW_CLAUDE_MODEL"
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --init) [ "$#" -eq 2 ] || die '--init requires one task id'; TASK_ID=$2; ROLE= ;;
  reviewer|fixer) ROLE=$1; shift ;;
  *) die 'expected reviewer, fixer, or --init; see --help' ;;
esac

GIT_DIR=$(git rev-parse --absolute-git-dir) || die 'run from the task worktree'
REVIEW_ROOT="$GIT_DIR/adv-review-loop"
[ ! -L "$REVIEW_ROOT" ] || die "review root must not be a symlink: $REVIEW_ROOT"
mkdir -p "$REVIEW_ROOT"
REVIEW_ROOT=$(cd "$REVIEW_ROOT" && pwd -P)

if [ -z "$ROLE" ]; then
  case "$TASK_ID" in ''|*[!a-zA-Z0-9_-]*) die 'task id must contain only letters, digits, dash, or underscore' ;; esac
  mktemp -d "$REVIEW_ROOT/$TASK_ID.XXXXXX"
  exit 0
fi

ROUND='' INPUT='' OUTPUT=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "missing value for $1"
  case "$1" in
    --round) ROUND=$2 ;;
    --in) INPUT=$2 ;;
    --out) OUTPUT=$2 ;;
    *) die "unknown option: $1" ;;
  esac
  shift 2
done
case "$ROUND" in ''|*[!0-9]*|0*) die '--round must be a positive integer without leading zeros' ;; esac
[ -f "$INPUT" ] && [ -r "$INPUT" ] && [ ! -L "$INPUT" ] || die "input must be a readable regular file, not a symlink: $INPUT"
INPUT_DIR=$(cd "$(dirname "$INPUT")" && pwd -P) || die "cannot resolve input: $INPUT"
case "$INPUT_DIR" in "$REVIEW_ROOT"/*) ;; *) die "input must be inside a task directory under $REVIEW_ROOT: $INPUT" ;; esac
INPUT="$INPUT_DIR/$(basename "$INPUT")"
[ -n "$OUTPUT" ] || OUTPUT="$INPUT_DIR/round-$ROUND-$ROLE.out"
OUTPUT_DIR=$(cd "$(dirname "$OUTPUT")" && pwd -P) || die "cannot resolve output: $OUTPUT"
[ "$OUTPUT_DIR" = "$INPUT_DIR" ] || die 'output must be next to the round input'
OUTPUT="$OUTPUT_DIR/$(basename "$OUTPUT")"
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || die "output must be a new file: $OUTPUT"

AGENT_FILE="$HOME/.claude/agents/adv-$ROLE.md"
[ -f "$AGENT_FILE" ] && [ -r "$AGENT_FILE" ] || die "missing readable role definition: $AGENT_FILE"
PROMPT=$(cat "$AGENT_FILE" && printf '\n\n# This round\n' && cat "$INPUT") || die 'could not build role prompt'
TODAY=$(date +%F) || die 'could not read local date'
[[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "invalid local date: $TODAY"
if [[ "$TODAY" > "$CAPTAIN_REVIEW_CODEX_THROUGH" ]]; then
  RUNTIME=claude
  COMMAND=(claude -p --model "$CAPTAIN_REVIEW_CLAUDE_MODEL" --dangerously-skip-permissions -- "$PROMPT")
else
  RUNTIME=codex
  COMMAND=(codex exec --model "$CAPTAIN_REVIEW_CODEX_MODEL" -c "model_reasoning_effort=\"$CAPTAIN_REVIEW_CODEX_REASONING\"" --dangerously-bypass-approvals-and-sandbox -- "$PROMPT")
fi
command -v "$RUNTIME" >/dev/null 2>&1 || die "required runtime is unavailable: $RUNTIME"
(set -o noclobber; : > "$OUTPUT") || die "cannot create fresh output: $OUTPUT"
RC=0
"${COMMAND[@]}" > "$OUTPUT" 2>&1 || RC=$?
if [ "$RC" -ne 0 ]; then
  printf 'fm-review-round.sh: %s round %s failed (%s exit %s); read %s\n' "$ROLE" "$ROUND" "$RUNTIME" "$RC" "$OUTPUT" >&2
  exit "$RC"
fi
[ -s "$OUTPUT" ] || die "$ROLE round $ROUND produced empty output; read $OUTPUT"
printf '%s\n' "$OUTPUT"
