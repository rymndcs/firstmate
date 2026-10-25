#!/usr/bin/env bash
# Behavioral tests of quiet worker supervision through the watcher executable.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-quiet)
WATCH="$ROOT/bin/fm-watch.sh"

quiet_case() {
  local name=$1 backend=$2 harness=${3:-grok} d
  d=$(make_case "$name")
  mkdir -p "$d/wt"
  printf 'idle composer\n' > "$d/pane"
  printf 'alive\n' > "$d/liveness"
  fm_write_meta "$d/state/quiet.meta" "window=test:fm-quiet" "backend=$backend" \
    "harness=$harness" "kind=scout" "worktree=$d/wt"
  cat > "$d/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
live=$(cat "$CASE/liveness")
case "$1" in
  list-windows) [ "$live" != missing ] && printf 'fm-quiet\n'; exit 0 ;;
  display-message)
    [ "$live" != missing ] || exit 1
    case "$*" in
      *pane_current_command*) [ "$live" = alive ] && printf 'claude\n' || printf 'zsh\n' ;;
      *pane_tty*) : ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) [ "$live" != missing ] || exit 1; cat "$CASE/pane" ;;
  *) exit 1 ;;
esac
SH
  cat > "$d/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
live=$(cat "$CASE/liveness")
case "$1 $2" in
  'pane get')
    if [ "$live" = missing ]; then printf '{"error":{"code":"pane_not_found"}}\n'
    else printf '{"result":{"pane":{"pane_id":"fm-quiet"}}}\n'; fi ;;
  'pane read') [ "$live" != missing ] || exit 1; cat "$CASE/pane" ;;
  'agent get')
    if [ "$live" = alive ]; then printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else printf '{"error":{"code":"agent_not_found"}}\n'; fi ;;
  'status --json') printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$d/fakebin/orca" <<'SH'
#!/usr/bin/env bash
printf '{"result":{"text":"idle composer"}}\n'
SH
  cat > "$d/fakebin/zellij" <<'SH'
#!/usr/bin/env bash
case "$*" in
  list-sessions*) printf 'test\n' ;;
  *list-panes*) printf '[{"id":1,"tab_id":1,"is_plugin":false}]\n' ;;
  *list-tabs*) printf '[{"tab_id":1,"name":"fm-quiet"}]\n' ;;
  *dump-screen*) cat "$CASE/pane" ;;
  *) exit 1 ;;
esac
SH
  cat > "$d/fakebin/cmux" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'workspace list') printf '{"workspaces":[{"id":"test","title":"%s"}]}\n' "$QUIET_TITLE" ;;
  'list-panes --workspace') printf '{"panes":[{"surface_ids":["fm-quiet"]}]}\n' ;;
  'read-screen --workspace') printf '{"text":"idle composer"}\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$d/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
n=$(cat "$CASE/polls" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$CASE/polls"
printf 'idle composer %s\n' "$n" > "$CASE/pane"
if [ "$n" -ge 3 ]; then
  : > "$CASE/completed"
  kill -TERM "$PPID"
fi
SH
  chmod +x "$d/fakebin/tmux" "$d/fakebin/herdr" "$d/fakebin/orca" "$d/fakebin/zellij" "$d/fakebin/cmux" "$d/fakebin/sleep"
  printf '%s\n' "$d"
}

quiet_run() {
  local d=$1 rc=0 sig pane_hash window key title
  sig=$(seen_sig "$d/state/quiet.status")
  printf '%s' "$sig" > "$d/state/.seen-quiet_status"
  printf '%s' "$(last_status_line "$d/state/quiet.status")" > "$d/state/.hb-surfaced-quiet"
  pane_hash=$(hash_text "$(cat "$d/pane")")
  window=$(fm_meta_get "$d/state/quiet.meta" window)
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$pane_hash" > "$d/state/.hash-$key"
  printf '1\n' > "$d/state/.count-$key"
  title=$(FM_HOME="$d" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source cmux; fm_backend_cmux_scoped_title fm-quiet' _ "$ROOT")
  rm -f "${d:?}/completed" "${d:?}/polls"
  CASE="$d" QUIET_TITLE="$title" PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 \
    "$WATCH" > "$d/out" 2> "$d/err" || rc=$?
  if [ -e "$d/completed" ]; then
    [ "$rc" -eq 1 ] || fail "bounded watcher returned $rc instead of its termination status"
  else
    [ "$rc" -eq 0 ] || fail "watcher failed before completing $d (exit $rc): $(cat "$d/err")"
  fi
}

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

test_quiet_class_opt_in() {
  local d state failures=0
  d=$(quiet_case classifier tmux)
  for state in parked 'done'; do
    if [ "$(FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE="state: $state · source: status-log · explicit state" \
      crew_absorb_class quiet)" != none ]; then
      printf 'not ok - ordinary %s caller must retain none\n' "$state"
      failures=$((failures + 1))
    fi
    [ "$(FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE="state: $state · source: status-log · explicit state" \
      crew_absorb_class quiet quiet)" = "$state" ] || fail "explicit quiet caller lost $state"
  done
  [ "$failures" -eq 0 ] || fail 'quiet states changed the ordinary absorb interface'
  pass 'quiet classification is opt-in; ordinary absorb callers keep their contract'
}

test_healthy_quiet() {
  local backend=$1 verb=$2 harness=$3 d round
  d=$(quiet_case "$backend-$verb-$harness" "$backend" "$harness")
  case "$verb" in
    parked) printf 'needs-decision [key=choice]: choose A or B\n' > "$d/state/quiet.status" ;;
    done) printf 'done: ready for review\n' > "$d/state/quiet.status" ;;
    resolved) printf 'done: ready for review\nresolved [key=note]: recorded\n' > "$d/state/quiet.status" ;;
  esac
  for round in 1 2 3; do
    printf '%s\n' $(( $(date +%s) - 500 )) > "$d/state/.stale-since-test_fm-quiet"
    quiet_run "$d"
    [ -e "$d/completed" ] || fail "$backend $verb $harness round $round raised repeated stale: $(cat "$d/out")"
    [ ! -s "$d/state/.wake-queue" ] || fail "$backend $verb $harness queued an ordinary stale wake"
  done
  printf 'dead\n' > "$d/liveness"
  quiet_run "$d"
  grep -F 'stale: test:fm-quiet' "$d/out" >/dev/null || fail "$backend $verb $harness hid an exited agent"
  pass "$backend $verb $harness: healthy quiet survives churn/re-arm; agent exit still surfaces"
}

test_missing_quiet() {
  local backend=$1 verb=$2 d
  d=$(quiet_case "$backend-missing-$verb" "$backend")
  printf '%s: waiting\n' "$verb" > "$d/state/quiet.status"
  printf 'missing\n' > "$d/liveness"
  quiet_run "$d"
  grep -F 'stale: test:fm-quiet' "$d/out" >/dev/null || fail "$backend $verb hid a missing endpoint"
  pass "$backend $verb: missing endpoint surfaces without a successful capture"
}

test_working_idle() {
  local d
  d=$(quiet_case working tmux)
  printf 'working: implementing\n' > "$d/state/quiet.status"
  # Prime the unchanged pane as already surfaced, exactly as a re-armed watcher.
  printf '%s' "$(hash_text 'idle composer')" > "$d/state/.hash-test_fm-quiet"
  printf '%s' "$(hash_text 'idle composer')" > "$d/state/.stale-test_fm-quiet"
  printf '1\n' > "$d/state/.count-test_fm-quiet"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$d/state/.stale-since-test_fm-quiet"
  quiet_run "$d"
  grep -F 'possible wedge, escalation 1' "$d/out" >/dev/null || fail "working-idle lost ordinary wedge escalation"
  pass 'working-idle: unchanged pane still escalates on the ordinary cadence'
}

test_unknown_liveness() {
  local backend=$1 d window key
  d=$(quiet_case "unknown-$backend" "$backend")
  printf 'done: ready\nresolved: bookkeeping\n' > "$d/state/quiet.status"
  window=test:fm-quiet
  [ "$backend" != zellij ] || window=test:1
  fm_write_meta "$d/state/quiet.meta" "window=$window" "backend=$backend" \
    "harness=grok" "kind=scout" "worktree=$d/wt"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle composer')" > "$d/state/.stale-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$d/state/.stale-since-$key"
  FM_CREW_STATE_BIN="$d/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: done · source: run-step · checks green' quiet_run "$d"
  grep -F 'possible wedge, escalation 1' "$d/out" >/dev/null || fail "$backend unknown liveness became quieter"
  local out
  out=$(FM_HOME="$d" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_alive "$2" test:fm-quiet' _ "$ROOT" "$backend")
  [ "$out" = unknown ] || fail "$backend unexpectedly claimed verified liveness: $out"
  pass "$backend: unknown agent liveness stays conservative"
}

backdate() {
  python3 - "$1" <<'PY'
import os, sys, time
os.utime(sys.argv[1], (time.time() - 7200, time.time() - 7200))
PY
}

test_long_cadence() {
  local d
  d=$(quiet_case long-cadence tmux)
  printf 'done: ready\n' > "$d/state/quiet.status"
  backdate "$d/state/quiet.status"
  quiet_run "$d"
  grep -F 'healthy idle agent, rechecked on a long cadence' "$d/out" >/dev/null || fail 'old completion did not receive its bounded recheck'
  quiet_run "$d"
  [ -e "$d/completed" ] || fail 'old completion repeated its bounded recheck immediately'
  printf 'dead\n' > "$d/liveness"
  quiet_run "$d"
  grep -F 'agent exited or endpoint gone' "$d/out" >/dev/null || fail 'recent quiet recheck hid agent death'
  quiet_run "$d"
  [ -e "$d/completed" ] || fail 'unchanged agent death repeated immediately'
  printf 'alive\n' > "$d/liveness"
  quiet_run "$d"
  [ -e "$d/completed" ] || fail 'agent return forgot the prior healthy recheck'
  printf 'dead\n' > "$d/liveness"
  quiet_run "$d"
  grep -F 'agent exited or endpoint gone' "$d/out" >/dev/null || fail 'a second agent death was hidden by the previous death'
  pass 'bounded quiet/dead rechecks preserve immediate detection of each new death'
}

test_quiet_resume() {
  local d
  d=$(quiet_case resume tmux)
  printf 'done: ready\n' > "$d/state/quiet.status"
  printf '6\n' > "$d/state/.wedge-escalations-test_fm-quiet"
  quiet_run "$d"
  [ -e "$d/completed" ] || fail 'resume fixture did not first become quiet'
  printf 'working: follow-up\n' >> "$d/state/quiet.status"
  printf '%s' "$(hash_text "$(cat "$d/pane")")" > "$d/state/.stale-test_fm-quiet"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$d/state/.stale-since-test_fm-quiet"
  quiet_run "$d"
  grep -F 'possible wedge, escalation 1' "$d/out" >/dev/null || fail 'new working status retained quiet suppression or an old escalation count'
  pass 'a new working event invalidates quiet classification on the same pane'
}

test_quiet_cache_expiry() {
  local d
  d=$(quiet_case cache-expiry tmux)
  printf 'done: ready\n' > "$d/state/quiet.status"
  printf 'state: done · source: run-step · checks green\n' > "$d/verdict"
  cat > "$d/state-reader" <<'SH'
#!/usr/bin/env bash
cat "$CASE/verdict"
SH
  chmod +x "$d/state-reader"
  FM_CREW_STATE_BIN="$d/state-reader" quiet_run "$d"
  [ -e "$d/completed" ] || fail 'cache fixture did not first become quiet'
  printf 'state: working · source: run-step · validating\n' > "$d/verdict"
  backdate "$d/state/.quiet-state-test_fm-quiet"
  printf '%s' "$(hash_text "$(cat "$d/pane")")" > "$d/state/.stale-test_fm-quiet"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$d/state/.stale-since-test_fm-quiet"
  FM_CREW_STATE_BIN="$d/state-reader" quiet_run "$d"
  grep -F 'possible wedge' "$d/out" >/dev/null || fail 'expired quiet classification hid a resumed run'
  pass 'quiet cache expiry rechecks authoritative run state without a status append'
}

case "${FM_QUIET_TEST:-all}" in
  all) ;;
  healthy) test_healthy_quiet tmux parked grok; exit ;;
  missing) test_missing_quiet tmux 'done'; exit ;;
  working) test_working_idle; exit ;;
  unknown) test_unknown_liveness orca; exit ;;
  cadence) test_long_cadence; exit ;;
  resume) test_quiet_resume; exit ;;
  expiry) test_quiet_cache_expiry; exit ;;
  classifier) test_quiet_class_opt_in; exit ;;
  *) fail 'unknown FM_QUIET_TEST selection' ;;
esac

failures=0
test_quiet_class_opt_in || exit 1
for backend in tmux herdr; do
  for verb in parked 'done' resolved; do
    for harness in claude codex opencode pi pi-signed grok kimi; do
      if ! (test_healthy_quiet "$backend" "$verb" "$harness"); then failures=$((failures + 1)); fi
    done
  done
  for verb in needs-decision 'done'; do
    if ! (test_missing_quiet "$backend" "$verb"); then failures=$((failures + 1)); fi
  done
done
if ! (test_working_idle); then failures=$((failures + 1)); fi
for backend in zellij cmux orca; do
  if ! (test_unknown_liveness "$backend"); then failures=$((failures + 1)); fi
done
for check in test_long_cadence test_quiet_resume test_quiet_cache_expiry; do
  if ! ("$check"); then failures=$((failures + 1)); fi
done
[ "$failures" -eq 0 ]
