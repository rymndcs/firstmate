#!/usr/bin/env bash
# Credentialed opt-in: real omp on an isolated Herdr server, including safe
# away-message delivery and preservation of the captain's unsent draft.
set -euo pipefail
if [ "${FM_OMP_HERDR_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_OMP_HERDR_LIVE_E2E=1 for the real omp/Herdr away-mode regression'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v omp >/dev/null || { echo 'not ok - omp is required' >&2; exit 1; }
command -v herdr >/dev/null || { echo 'not ok - herdr is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'not ok - jq is required' >&2; exit 1; }
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-herdr.XXXXXX")
SESSION=$(fm_herdr_lab_name omp-away)
cleanup() {
  fm_herdr_lab_teardown "$SESSION" || true
  rm -rf "$LAB"
}
trap cleanup EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
run() { fm_herdr_lab_cli "$SESSION" "$@"; }
fm_herdr_lab_provision "$SESSION"
raw=$(run workspace create --label omp-away --cwd "$LAB" --no-focus)
pane=$(printf '%s' "$raw" | jq -er '.result.root_pane.pane_id')
sleep 2
model=${FM_OMP_LIVE_MODEL:-openai-codex/gpt-6.1-sol}
run pane run "$pane" "omp --model '$model' --thinking low --approval-mode yolo --no-extensions --no-skills --no-title --session-dir '$LAB/sessions'" >/dev/null
sleep 5
run pane send-text "$pane" 'Reply with exactly READY.' >/dev/null
run pane send-keys "$pane" enter >/dev/null
ready=0
for _ in $(seq 1 120); do
  screen=$(run pane read "$pane" --source visible --lines 50)
  if printf '%s' "$screen" | grep -qE '^[[:space:]]*READY[[:space:]]*$'; then ready=1; break; fi
  sleep 1
 done
[ "$ready" = 1 ] || fail 'omp did not finish its first turn'
sleep 1
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_ROOT_OVERRIDE="$ROOT"
export FM_SUPERVISOR_TARGET="$SESSION:$pane" FM_SUPERVISOR_BACKEND=herdr FM_DAEMON_PRIMARY_HARNESS=omp
mkdir -p "$LAB/state"
touch "$LAB/state/.afk"
. "$ROOT/bin/fm-supervise-daemon.sh"
LOG="$LAB/injection.log"
state=$(FM_COMPOSER_HARNESS=omp fm_backend_composer_state herdr "$SESSION:$pane")
[ "$state" = empty ] || fail "idle omp composer read $state"
# Confirmed acknowledgement must correspond to a real single submitted prompt,
# not merely a change somewhere else on the screen.
inject_msg 'HERDR_OMP_DELIVERED: end this away turn with exactly ·' "$LAB/state" \
  || { cat "$LOG" >&2; fail 'an idle omp did not acknowledge the away message'; }
settled=0
for _ in $(seq 1 120); do
  if jq -se '[.[] | select(.type == "message" and .message.role == "assistant") | .message.content[]? | select(.type == "text" and .text == "·")] | length == 1' "$LAB/sessions/"*.jsonl >/dev/null 2>&1; then
    settled=1; break
  fi
  sleep 1
 done
[ "$settled" = 1 ] || fail 'away prompt did not produce its real completion'
count=$(jq -s '[.[] | select(.type == "message" and .message.role == "user") | .message.content[]? | select(.type == "text" and (.text | contains("HERDR_OMP_DELIVERED")))] | length' "$LAB/sessions/"*.jsonl)
[ "$count" = 1 ] || fail "away message was submitted $count times"
sleep 1
run pane send-text "$pane" 'captain draft remains' >/dev/null
sleep 1
state=$(FM_COMPOSER_HARNESS=omp fm_backend_composer_state herdr "$SESSION:$pane")
[ "$state" = pending ] || fail "captain draft read $state"
if inject_msg 'MUST_NOT_REACH_DRAFT' "$LAB/state"; then fail 'a wake was injected over a pending draft'; fi
screen=$(run pane read "$pane" --source visible --lines 50)
printf '%s' "$screen" | grep -q 'captain draft remains' || fail 'draft was changed by deferred injection'
printf '%s' "$screen" | grep -q 'MUST_NOT_REACH_DRAFT' && fail 'deferred wake reached the input box'
echo 'ok - real omp/Herdr: idle wake delivered once and acknowledged, pending draft preserved'
