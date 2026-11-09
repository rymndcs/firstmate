#!/usr/bin/env bash
# Opt-in model-driven native omp proof using the complete current source tree.
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
if [ -n "${FM_OMP_RESET_TEMP_REGISTRY:-}" ]; then printf '%s\n' "$LAB" >> "$FM_OMP_RESET_TEMP_REGISTRY"; fi
SOCKET="fm-omp-reset-$$"
TMUX_BIN=$(command -v tmux)
OMP_BIN=$(realpath "$(command -v omp)")
export FM_OMP_RESET_EXECUTABLE="$OMP_BIN"
stop_fixture() {
  local n=0
  if "$TMUX_BIN" -L "$SOCKET" has-session -t reset 2>/dev/null; then
    "$TMUX_BIN" -L "$SOCKET" send-keys -t reset C-u
    "$TMUX_BIN" -L "$SOCKET" send-keys -t reset -l /quit
    "$TMUX_BIN" -L "$SOCKET" send-keys -t reset Enter
    while "$TMUX_BIN" -L "$SOCKET" has-session -t reset 2>/dev/null && [ "$n" -lt 100 ]; do
      sleep 0.1
      n=$((n + 1))
    done
  fi
  "$TMUX_BIN" -L "$SOCKET" kill-server 2>/dev/null || true
}
cleanup() {
  stop_fixture
  if [ -n "${FM_OMP_RESET_EVIDENCE:-}" ] && [ -n "${MODE:-}" ]; then
    [ ! -f "$LAB/$MODE-home/events.jsonl" ] || cp "$LAB/$MODE-home/events.jsonl" "$FM_OMP_RESET_EVIDENCE.$MODE.jsonl"
    [ ! -f "$LAB/$MODE-manifest.json" ] || cp "$LAB/$MODE-manifest.json" "$FM_OMP_RESET_EVIDENCE.$MODE.manifest.json"
  fi
  fm_test_cleanup
}
trap cleanup EXIT
node "$ROOT/tests/fixtures/omp-reset/model-flow.mjs" "$ROOT" "$LAB"
if [ "${FM_OMP_RESET_FLOW_ONLY:-0}" = 1 ]; then exit 0; fi
for MODE in normal away; do
PROJECT="$LAB/$MODE-project"
HOME_DIR="$LAB/$MODE-home"
git clone -q "$ROOT" "$PROJECT"
# Copy every current tracked file plus fixtures, never a selected overlay.
python3 - "$ROOT" "$PROJECT" "$LAB/$MODE-manifest.json" <<'PY'
from pathlib import Path
import hashlib, json, shutil, subprocess, sys
root, dest = map(Path, sys.argv[1:3])
names = subprocess.check_output(['git','-C',str(root),'ls-files','-z','--cached','--others','--exclude-standard']).decode().split('\0')
manifest = {}
for name in filter(None, names):
    source, target = root/name, dest/name
    if not source.is_file():
        if target.is_file(): target.unlink()
        continue
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source,target)
    manifest[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    assert manifest[name] == hashlib.sha256(target.read_bytes()).hexdigest()
Path(sys.argv[3]).write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n')
PY
cp "$PROJECT/tests/fixtures/omp-reset/live-driver.ts" "$PROJECT/reset-live-driver.ts"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$LAB/$MODE-sessions" "$LAB/$MODE-shim"
for dir in state data config; do ln -s "$HOME_DIR/$dir" "$PROJECT/$dir"; done
for name in captain.md captain-shared.md learnings.md; do : > "$HOME_DIR/data/$name"; done
printf '4800\n' > "$HOME_DIR/config/startup-memory-budget"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
printf 'tmux\n' > "$HOME_DIR/config/backend"
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
printf 'project=fixture\n' > "$HOME_DIR/state/fixture.meta"
printf 'working: fixture dispatch already reported\n' > "$HOME_DIR/state/fixture.status"
printf '# Backlog\n\n## In flight\n\n- fixture: Waiting for fixture result\n' > "$HOME_DIR/data/backlog.md"
printf '#!/usr/bin/env bash\nREAL_TMUX=%q\nSOCKET=%q\nFIXTURE_HOME=%q\n' "$TMUX_BIN" "$SOCKET" "$HOME_DIR" > "$LAB/$MODE-shim/tmux"
cat >> "$LAB/$MODE-shim/tmux" <<'SHIM'
case "${1:-}:${4:-}:${5:-}" in
  send-keys:-l:$'\033[?9001;'*)
    if [ -f "$FIXTURE_HOME/state/fixture-draft-race" ]; then
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$3" -l Wai
      rm -f "${FIXTURE_HOME:?}/state/fixture-draft-race"
    fi
    ;;
esac
exec "$REAL_TMUX" -L "$SOCKET" "$@"
SHIM
chmod +x "$LAB/$MODE-shim/tmux"
AWAY=0
if [ "$MODE" = away ]; then
  AWAY=1
  : > "$HOME_DIR/state/.afk"
  printf 'none\t-\tomp\n' > "$HOME_DIR/state/.afk-daemon-terminal"
fi
MODEL=${FM_OMP_LIVE_MODEL:-anthropic/claude-sonnet-5-5}
"$TMUX_BIN" -L "$SOCKET" new-session -d -s reset -x 200 -y 60 -c "$PROJECT" \
  "exec env PATH='$LAB/$MODE-shim:$PATH' FM_OMP_RESET_AWAY='$AWAY' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=0.1 FM_HEARTBEAT=3600 '$OMP_BIN' --model '$MODEL' --thinking low --approval-mode yolo --no-title --no-extensions -e '$PROJECT/reset-live-driver.ts' --session-dir '$LAB/$MODE-sessions'"
wait_count() {
  local kind=$1 count=$2 n=0
  while [ "$n" -lt "${FM_OMP_RESET_LIVE_POLLS:-1200}" ]; do
    if [ -f "$HOME_DIR/events.jsonl" ] && jq -es --arg kind "$kind" --argjson count "$count" '[.[]|select(.kind==$kind)]|length >= $count' "$HOME_DIR/events.jsonl" >/dev/null; then return 0; fi
    sleep 0.25
    n=$((n + 1))
  done
  "$TMUX_BIN" -L "$SOCKET" capture-pane -p -t reset -S -150 >&2 || true
  [ ! -f "$HOME_DIR/events.jsonl" ] || cat "$HOME_DIR/events.jsonl" >&2 || true
  fail "omp did not produce $count $kind event(s)"
}
send() {
  "$TMUX_BIN" -L "$SOCKET" send-keys -t reset -l "/fm-probe $1"
  sleep "${FM_OMP_RESET_SEND_SETTLE:-0.5}"
  "$TMUX_BIN" -L "$SOCKET" send-keys -t reset Enter
}
wait_count start 1
send startup
wait_count armed 1
if [ "$MODE" = away ]; then
  wait_count visible 1
  send inspect
  wait_count inspect 1
  jq -es '
    all(.[]|select(.kind=="visible"); .text=="·") and
    ([.[]|select(.kind=="visible")]|length)==1 and
    ([.[]|select(.kind=="armed")]|length)==1 and
    ([.[]|select(.kind=="startup")]|length)==1 and
    ([.[]|select(.kind=="reset-tool" or .kind=="switch")]|length)==0 and
    ([.[]|select(.kind=="inspect")][-1].jobs.running|length)==1
  ' "$HOME_DIR/events.jsonl" >/dev/null || fail 'away supervision must emit only the dot, arm once and never prepare, submit or switch'
  [ ! -e "$HOME_DIR/state/.omp-reset-handoff.json" ] || fail 'away startup prepared a reset handoff'
  printf 'ok - %s away supervision: dot only, one arm, no reset preparation, submission or switch\n' "$("$OMP_BIN" --version)"
else
# The existing job is deliberately still running when the answered message arrives.
send answered
wait_count switch 1
wait_count startup 2
wait_count armed 2
wait_count wake-drained 1
send inspect
wait_count inspect 1
jq -es '
  ([.[]|select(.kind=="switch")]|length) == 1 and
  ([.[]|select(.kind=="startup")]|length) == 2 and
  ([.[]|select(.kind=="reset-tool" and .input.action=="prepare")]|length) == 1 and
  ([.[]|select(.kind=="reset-tool" and .input.action=="ready")]|length) == 1 and
  ([.[]|select(.kind=="inspect")][-1].jobs.running|length) == 1
' "$HOME_DIR/events.jsonl" >/dev/null || fail 'expected one model-driven stow/reset, one startup per session, and one resumed supervision job'
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail 'new startup did not consume the durable wake'
old_pid=$(jq -sr '[.[]|select(.kind=="armed")][0].status | capture("pid=(?<pid>[0-9]+)").pid' "$HOME_DIR/events.jsonl")
new_pid=$(cat "$HOME_DIR/state/.watch.lock/pid")
[ "$new_pid" != "$old_pid" ] || fail 'native switch retained the old physical watcher'
kill -0 "$new_pid" 2>/dev/null || fail 'new physical watcher is not live'
if kill -0 "$old_pid" 2>/dev/null && ! ps -o stat= -p "$old_pid" | grep -q Z; then
  fail 'old physical watcher survived the native session switch'
fi
jq -es --arg arm '[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh' '
  [.[]|select(.kind=="bash" and .input.command==$arm and .input.async==true and .input.timeout==0)]|length >= 1
' "$HOME_DIR/events.jsonl" >/dev/null || fail 'native model did not use the supported unquoted arm before reset'
send race
wait_count recovery 1
jq -es '
  ([.[]|select(.kind=="switch")]|length) == 1 and
  ([.[]|select(.kind=="recovery")]|length) == 1 and
  ([.[]|select(.kind=="recovery")][0].editor == "Wai") and
  all(.[]|select(.kind=="input"); (.text|contains("Wai"))|not)
' "$HOME_DIR/events.jsonl" >/dev/null || fail 'interleaved draft must remain intact and unsubmitted with one recovery turn in the same session'
printf 'ok - %s %s integrated reset: model follows emitted wake protocol, stows, switches with live supervision, runs startup once, drains durable wake, arms one cycle, vetoes interleaved draft\n' "$("$OMP_BIN" --version)" "$MODE"
fi
stop_fixture
if [ -n "${FM_OMP_RESET_EVIDENCE:-}" ]; then
  cp "$HOME_DIR/events.jsonl" "$FM_OMP_RESET_EVIDENCE.$MODE.jsonl"
  cp "$LAB/$MODE-manifest.json" "$FM_OMP_RESET_EVIDENCE.$MODE.manifest.json"
fi
done
