#!/usr/bin/env bash
# Opt-in real omp TUI proof for stow/reset and the next supervision cycle.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "${FM_OMP_RESET_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_OMP_RESET_LIVE=1 for the native omp stow/reset proof'
  exit 0
fi
command -v omp >/dev/null || fail 'omp not installed'
command -v tmux >/dev/null || fail 'tmux not installed'
LAB=$(fm_test_tmproot fm-omp-reset-live)
FM_TEST_CLEANUP_DIRS+=("$LAB")
SOCKET="fm-omp-reset-$$"
TMUX_BIN=$(command -v tmux)
cleanup() {
  "$TMUX_BIN" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.omp/extensions/fm-primary-omp.ts" "$PROJECT/.omp/extensions/"
cp "$ROOT/bin/fm-omp-reset-submit.sh" "$PROJECT/bin/"
cp "$ROOT/tests/fixtures/omp-reset/live-driver.ts" "$PROJECT/reset-live-driver.ts"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$LAB/sessions" "$LAB/shim"
for name in captain.md captain-shared.md learnings.md; do : > "$HOME_DIR/data/$name"; done
printf '4800\n' > "$HOME_DIR/config/startup-memory-budget"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'tmux\n' > "$HOME_DIR/config/backend"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'project=fixture\n' > "$HOME_DIR/state/fixture.meta"
printf 'working: fixture dispatch already reported\n' > "$HOME_DIR/state/fixture.status"
printf '# Backlog\n\n## In flight\n\n- fixture: Waiting for fixture result\n' > "$HOME_DIR/data/backlog.md"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$TMUX_BIN" "$SOCKET" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
MODEL=${FM_OMP_LIVE_MODEL:-anthropic/claude-sonnet-5-5}
"$TMUX_BIN" -L "$SOCKET" new-session -d -s reset -x 200 -y 60 -c "$PROJECT" \
  "exec env PATH='$LAB/shim:$PATH' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=0.1 FM_HEARTBEAT=3600 omp --model '$MODEL' --thinking low --approval-mode yolo --no-context-files --no-rules --no-skills --no-title --no-extensions -e '$PROJECT/reset-live-driver.ts' --session-dir '$LAB/sessions'"
wait_event() {
  local kind=$1 n=0
  while [ "$n" -lt 240 ]; do
    if [ -f "$HOME_DIR/events.jsonl" ] && jq -es --arg kind "$kind" 'any(.[]; .kind == $kind)' "$HOME_DIR/events.jsonl" >/dev/null; then return 0; fi
    sleep 0.25
    n=$((n + 1))
  done
  "$TMUX_BIN" -L "$SOCKET" capture-pane -p -t reset -S -150 >&2 || true
  [ ! -f "$HOME_DIR/events.jsonl" ] || cat "$HOME_DIR/events.jsonl" >&2 || true
  fail "omp did not produce $kind event"
}
send() {
  "$TMUX_BIN" -L "$SOCKET" send-keys -t reset -l "/fm-probe $1"
  sleep "${FM_OMP_RESET_SEND_SETTLE:-0.5}"
  "$TMUX_BIN" -L "$SOCKET" send-keys -t reset Enter
}
wait_event start
send failed
wait_event failed-stow
send draft
wait_event draft
"$TMUX_BIN" -L "$SOCKET" capture-pane -p -t reset -S -30 > "$LAB/draft.txt"
assert_contains "$(cat "$LAB/draft.txt")" 'half typed' 'draft did not survive reset refusal'
"$TMUX_BIN" -L "$SOCKET" send-keys -t reset C-u
send ready
wait_event ready
send input
wait_event input
[ "$(jq -s '[.[]|select(.kind=="switch")]|length' "$HOME_DIR/events.jsonl")" = 0 ] || fail 'failure, draft or new input switched the session'
send success
wait_event switch
wait_event startup
wait_event wake-drained
n=0
while [ "$n" -lt 240 ] && [ ! -s "$HOME_DIR/state/.watch.lock/pid" ]; do sleep 0.25; n=$((n + 1)); done
[ -s "$HOME_DIR/state/.watch.lock/pid" ] || fail 'fresh session did not arm supervision'
kill -0 "$(cat "$HOME_DIR/state/.watch.lock/pid")" || fail 'resumed supervision is not live'
send inspect
wait_event inspect
jq -es '
  ([.[]|select(.kind=="switch")]|length) == 1 and
  ([.[]|select(.kind=="startup")]|length) == 1 and
  all(.[]|select(.kind=="failed-stow" or .kind=="draft" or .kind=="input"); .error == true) and
  ([.[]|select(.kind=="inspect")][-1].jobs.running|length) == 1
' "$HOME_DIR/events.jsonl" >/dev/null || fail 'expected one switch, one startup, and one supervision job'
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail 'fresh startup did not consume the durable wake'
if [ -n "${FM_OMP_RESET_EVIDENCE:-}" ]; then
  cp "$HOME_DIR/events.jsonl" "$FM_OMP_RESET_EVIDENCE"
fi
printf 'ok - %s native reset: stow failure, draft and input cancellation; one seeded startup, durable wake, one supervision cycle, no reset loop\n' "$(omp --version)"
