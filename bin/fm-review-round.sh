#!/usr/bin/env bash
# Launch one fresh adversarial-review role and wait for its exit.
#
# Usage (from the task worktree):
#   fm-review-round.sh --init <task-id>
#   fm-review-round.sh reviewer|fixer --task <token> --round <N>
#   fm-review-round.sh reviewer|fixer --task <token> --round <N> --path <kind>
#   fm-review-round.sh --help
#
# --init creates a unique task directory under the worktree's absolute Git
# directory/adv-review-loop and prints its opaque, non-path token. Retain that
# token across rounds and resumptions; never reuse another task's token.
# --path queries input, reply, report, handoff or summary without launching or
# reserving files. All destinations are derived inside that task directory:
#   input: round-<N>-<role>.md     reply: round-<N>-<role>.out
#   report: report.md             handoff: round-<N>-handoff.md
#   summary: round-<N>-summary.report
# Write input only to its queried path, then launch with the same role/token/round.
# Input must be a readable regular file, not a symlink. Caller paths (--in/--out)
# are not accepted. Queries do not authorize overwriting earlier evidence.
# Replies contain only the role response; diagnostics go to <reply>.diagnostics
# and Claude JSON to <reply>.runtime.json. Keep all review evidence private here;
# never commit summaries or reports into the project tree.
# Claude must emit exactly one JSON result object, is_error=false and a string
# result. Extra objects, malformed bytes and blank replies cannot pass.
# All evidence files must be NEW. A failed or blank reply returns nonzero and
# names the preserved output and diagnostics.
#
# Compose ~/.claude/agents/adv-<role>.md, two newlines, "# This round", and the
# input. Round input supplies target, local merge-base, round, final-round flag,
# full ledger, approved findings (fixer), and previous handoff path. Workers
# orchestrate the adv-review-loop skill; this launcher never decides findings.
# Runtime comes only from $FM_HOME/state/<task-id>.meta, or the same task file
# under FM_STATE_OVERRIDE when set. The task id comes from the initialized token.
# FM_HOME defaults to this script's repo
# root, never the worker's current directory; generated instructions export the
# owning home and resolved state directory for shared-code/secondmate use.
# Read meta each launch.
# Supported review harnesses: codex and claude. Missing metadata, harness/model,
# an unresolved default model, or missing/default Codex effort refuses launch.
# Claude effort is optional and passed only when claude --help exposes --effort.
# Other harnesses refuse rather than switching to another runtime or model.
set -euo pipefail
unset CDPATH

die() { printf 'fm-review-round.sh: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
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

# shellcheck source=bin/fm-pr-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-lib.sh"
if [ -z "$ROLE" ]; then
  fm_task_id_creation_valid "$TASK_ID" || die 'task id must be a supported path-safe task id (at most 64 characters)'
  TASK_DIR=$(mktemp -d "$REVIEW_ROOT/$TASK_ID.XXXXXX")
  printf '%s\n' "${TASK_DIR##*/}"
  exit 0
fi

ROUND='' TASK_TOKEN='' PATH_KIND=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || die "missing value for $1"
  case "$1" in
    --round) ROUND=$2 ;;
    --task) TASK_TOKEN=$2 ;;
    --path)
      case "$2" in
        input|reply|report|handoff|summary) PATH_KIND=$2 ;;
        *) die 'unknown path query; expected input, reply, report, handoff or summary' ;;
      esac
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift 2
done
case "$ROUND" in ''|*[!0-9]*|0*) die '--round must be a positive integer without leading zeros' ;; esac
TASK_ID=${TASK_TOKEN%.*}
TASK_SUFFIX=${TASK_TOKEN##*.}
fm_task_id_creation_valid "$TASK_ID" || die 'invalid task token; use --init'
case "$TASK_SUFFIX" in ''|*[!A-Za-z0-9]*) die 'invalid task token; use --init' ;; esac
[ "${#TASK_SUFFIX}" -eq 6 ] && [ "$TASK_TOKEN" != "$TASK_ID" ] || die 'invalid task token; use --init'
TASK_DIR="$REVIEW_ROOT/$TASK_TOKEN"
[ -d "$TASK_DIR" ] && [ ! -L "$TASK_DIR" ] || die 'task token must identify an initialized non-symlink task directory'
INPUT="$TASK_DIR/round-$ROUND-$ROLE.md"
OUTPUT="$TASK_DIR/round-$ROUND-$ROLE.out"
case "$PATH_KIND" in
  '') ;;
  input) printf '%s\n' "$INPUT"; exit 0 ;;
  reply) printf '%s\n' "$OUTPUT"; exit 0 ;;
  report) printf '%s\n' "$TASK_DIR/report.md"; exit 0 ;;
  handoff) printf '%s\n' "$TASK_DIR/round-$ROUND-handoff.md"; exit 0 ;;
  summary) printf '%s\n' "$TASK_DIR/round-$ROUND-summary.report"; exit 0 ;;
  *) die 'unknown path query; expected input, reply, report, handoff or summary' ;;
esac
[ -f "$INPUT" ] && [ -r "$INPUT" ] && [ ! -L "$INPUT" ] || die "input must be a readable regular file, not a symlink: $INPUT"

AGENT_FILE="$HOME/.claude/agents/adv-$ROLE.md"
[ -f "$AGENT_FILE" ] && [ -r "$AGENT_FILE" ] || die "missing readable role definition: $AGENT_FILE"
PROMPT=$(cat "$AGENT_FILE" && printf '\n\n# This round\n' && cat "$INPUT") || die 'could not build role prompt'
SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
REVIEW_HOME=${FM_HOME:-$SCRIPT_ROOT}
META="${FM_STATE_OVERRIDE:-$REVIEW_HOME/state}/$TASK_ID.meta"
[ -f "$META" ] && [ -r "$META" ] || die "task $TASK_ID: missing readable runtime metadata: $META"
RUNTIME=$(awk '/^harness=/ { sub(/^harness=/, ""); print; exit }' "$META")
MODEL=$(awk '/^model=/ { sub(/^model=/, ""); print; exit }' "$META")
EFFORT=$(awk '/^effort=/ { sub(/^effort=/, ""); print; exit }' "$META")
[ -n "$RUNTIME" ] || die "task $TASK_ID: missing harness in $META"
[ -n "$MODEL" ] && [ "$MODEL" != default ] || die "task $TASK_ID: missing explicit model in $META"
case "$RUNTIME" in
  codex|claude) ;;
  *) die "task $TASK_ID: unsupported review harness '$RUNTIME' in $META; supported: codex, claude" ;;
esac
command -v "$RUNTIME" >/dev/null 2>&1 || die "task $TASK_ID: required runtime is unavailable: $RUNTIME"
if [ "$RUNTIME" = claude ]; then
  command -v jq >/dev/null 2>&1 || die 'jq is required to extract the Claude role reply'
  COMMAND=(claude -p --output-format json --model "$MODEL")
  if [ -n "$EFFORT" ] && [ "$EFFORT" != default ]; then
    CLAUDE_HELP=$(claude --help) || die "task $TASK_ID: cannot inspect claude --help for effort support"
    if [[ "$CLAUDE_HELP" == *'--effort '* ]]; then
      COMMAND+=(--effort "$EFFORT")
    fi
  fi
  COMMAND+=(--dangerously-skip-permissions -- "$PROMPT")
else
  [ -n "$EFFORT" ] && [ "$EFFORT" != default ] || die "task $TASK_ID: missing explicit Codex effort in $META"
  COMMAND=(codex exec --output-last-message "$OUTPUT" --model "$MODEL" -c "model_reasoning_effort=\"$EFFORT\"" --dangerously-bypass-approvals-and-sandbox -- "$PROMPT")
fi
DIAGNOSTICS="$OUTPUT.diagnostics"
EVIDENCE=("$OUTPUT" "$DIAGNOSTICS")
if [ "$RUNTIME" = claude ]; then
  RAW_OUTPUT="$OUTPUT.runtime.json"
  EVIDENCE+=("$RAW_OUTPUT")
fi
for file in "${EVIDENCE[@]}"; do
  [ ! -e "$file" ] && [ ! -L "$file" ] || die "evidence must be a new file: $file"
done
for file in "${EVIDENCE[@]}"; do
  (set -o noclobber; : > "$file") || die "cannot create fresh evidence: $file"
done
RC=0
if [ "$RUNTIME" = codex ]; then
  "${COMMAND[@]}" > "$DIAGNOSTICS" 2>&1 || RC=$?
else
  "${COMMAND[@]}" > "$RAW_OUTPUT" 2> "$DIAGNOSTICS" || RC=$?
fi
if [ "$RC" -ne 0 ]; then
  printf 'fm-review-round.sh: %s round %s failed (%s exit %s); reply %s; diagnostics %s\n' "$ROLE" "$ROUND" "$RUNTIME" "$RC" "$OUTPUT" "$DIAGNOSTICS" >&2
  exit "$RC"
fi
if [ "$RUNTIME" = claude ]; then
  jq -ser 'if length == 1 and (.[0] | type == "object")
    then .[0] | select(.type == "result" and .is_error == false) | .result | select(type == "string")
    else empty end' \
    "$RAW_OUTPUT" > "$OUTPUT" 2>> "$DIAGNOSTICS" \
    || die "$ROLE round $ROUND produced no valid role reply; raw response $RAW_OUTPUT; diagnostics $DIAGNOSTICS"
fi
grep -q '[^[:space:]]' "$OUTPUT" || die "$ROLE round $ROUND produced an empty or whitespace-only role reply; reply $OUTPUT; diagnostics $DIAGNOSTICS"
printf '%s\n' "$OUTPUT"
