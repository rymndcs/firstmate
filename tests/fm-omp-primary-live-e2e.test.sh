#!/usr/bin/env bash
# Opt-in credentialed omp regression for the primary seat: the session lock,
# the session_stop turn-end guard, the async-job watcher wake, and the
# watcher-arm seatbelt, all driven through a real interactive omp session.
set -u

if [ "${FM_OMP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LIVE_E2E=1 to run the interactive omp primary regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v omp >/dev/null 2>&1 || fail "omp not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX_BIN=$(command -v tmux)
SOCKET="fm-omp-live-e2e-$$"
SESSION=omp-live-e2e
LAB="$ROOT/.omp-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
STATE="$HOME_DIR/state"
SESSIONS="$LAB/sessions"
MODEL=${FM_OMP_LIVE_MODEL:-anthropic/claude-sonnet-5-5}
OMP_VERSION=$(omp --version | head -1)

capture() {
  "$TMUX_BIN" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -2000 2>/dev/null || true
}

wait_for() {  # <description> <attempts> <test command...>
  local what=$1 attempts=$2 i=0
  shift 2
  while [ "$i" -lt "$attempts" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  fail "$what"
}

send_prompt() {
  "$TMUX_BIN" -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 0.5
  "$TMUX_BIN" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

watcher_pid() {
  cat "$STATE/.watch.lock/pid" 2>/dev/null || true
}

live_watcher() {
  local pid
  pid=$(watcher_pid)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

lock_held_by_omp() {
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$omp_pid" ]
}

watcher_rearmed() {
  local pid
  pid=$(watcher_pid)
  [ -n "$pid" ] && [ "$pid" != "$initial_watcher" ] && kill -0 "$pid" 2>/dev/null
}

seatbelt_denied() {
  capture | grep -q 'watcher-background'
}

lab_pid_is_safe() {
  case "$(ps -p "$1" -o command= 2>/dev/null || true)" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid
  pid=$(watcher_pid)
  "$TMUX_BIN" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.2
  if [ -n "$pid" ] && lab_pid_is_safe "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$STATE" "$HOME_DIR/config" "$SESSIONS"
# One task in flight, so supervision is required and a blind stop is refused.
printf 'project=fixture\n' > "$STATE/omp-e2e.meta"

"$TMUX_BIN" -L "$SOCKET" new-session -d -x 200 -y 60 -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 omp --model '$MODEL' --thinking low --approval-mode yolo --session-dir '$SESSIONS' --no-title; printf 'OMP_EXIT=%s\n' \"\$?\"; sleep 300"

# The extension's session_start handler records itself before any prompt.
wait_for "omp did not load .omp/extensions/fm-primary-omp.ts" 120 test -s "$STATE/.omp-extension-loaded"
omp_pid=$(sed -n '2p' "$STATE/.omp-extension-loaded")
case "$(ps -o comm= -p "$omp_pid" 2>/dev/null)" in
  omp|*/omp) ;;
  *) fail "extension marker pid $omp_pid is not the omp process" ;;
esac
sleep 2

# 1. Lock, then the turn-end guard: the prompt never names the watcher, and the
#    transcript must hold the guard's refusal before the watcher counts.
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
send_prompt 'Run exactly `bin/fm-lock.sh` with the bash tool and reply LOCKED. Then follow any instruction you receive about supervision.'
wait_for "fm-lock.sh did not record the omp session as the lock holder" 240 lock_held_by_omp
wait_for "the turn-end guard did not lead omp to arm a watcher" 480 live_watcher
grep -rqs 'TURN WOULD END BLIND' "$SESSIONS" \
  || fail "the session transcript holds no session_stop guard refusal"
capture | grep -Fq 'fm-watch-arm.sh &' && fail "omp armed the watcher with a shell ampersand"
initial_watcher=$(watcher_pid)

# 2. Wake: an actionable status closes the watcher cycle. Only a turn started
#    by the finished async job can re-arm while the session is idle.
sleep 5
printf 'done: omp live e2e watcher fire\n' > "$STATE/omp-e2e.status"
wait_for "the action cycle was not classified in the lifecycle ledger" 240 \
  grep -Eqs 'reason=actionable-signal' "$STATE/.watch-cycle-exits.log"
wait_for "omp did not wake on the finished async job and re-arm" 480 watcher_rearmed

# 3. Seatbelt: a shell-ampersand arm is denied before it runs.
sleep 5
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
send_prompt 'Run exactly `bin/fm-watch-arm.sh &` with the bash tool as a normal call. If the tool refuses it, reply DENIED and do nothing else.'
wait_for "the watcher-arm seatbelt did not deny a shell-ampersand arm" 240 seatbelt_denied

# omp runs no .claude/settings.json command hooks; Claude's Stop auto-arm must
# never have run here.
[ ! -e "$STATE/.claude-autoarm-epoch" ] || fail "a Claude Stop hook ran inside omp"

printf 'ok - %s live E2E: lock, session_stop guard, async-job wake, and arm seatbelt\n' "$OMP_VERSION"
