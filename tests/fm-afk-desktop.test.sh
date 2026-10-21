#!/usr/bin/env bash
# Desktop away-mode contracts through isolated executable interfaces.
# shellcheck disable=SC2016 # The fixture harness expands these child-shell commands.
set -u
# shellcheck source=tests/afk-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/afk-fixture-helpers.sh"
fm_afk_fixture_prepare
if [ "${FM_AFK_FIXTURE_PROBE:-0}" = 1 ]; then fm_afk_fixture_probe; exit 0; fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-afk-desktop)
trap 'rm -rf "${LAB:?}"/homes "${LAB:?}"/fakebin; rmdir "$LAB"' EXIT
mkdir -p "$LAB/homes" "$LAB/fakebin"
ln -s /bin/bash "$LAB/fakebin/claude"
export PATH="$LAB/fakebin:$PATH"
fm_git_identity
fixture() {
  local dir="$LAB/homes/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  cp -R "$ROOT/bin/." "$dir/bin/"
  fm_afk_fixture_install "$dir"
  printf '#!/usr/bin/env bash\nprintf "check: normal fixture arm\\n"\n' > "$dir/bin/fm-watch-arm.sh"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}
launch() { FM_HOME="$D" "$D/bin/fm-afk-launch.sh" "$@"; }
hook() {
  FM_HOME="$D" claude -c '
    echo "$$" > "$FM_HOME/state/.lock"
    "$FM_HOME/bin/fm-claude-stop-autoarm.sh" <<<'"'"'{"session_id":"fixture"}'"'"'
  '
}
select_desktop() {
  date +%s > "$D/state/.afk"
  printf 'none\t-\tdesktop\n' > "$D/state/.afk-daemon-terminal"
}
test_launch() {
  D=$(fixture launch)
  launch start-desktop > "$D/out" 2> "$D/err"
  expect_code 0 "$?" 'Desktop launch needs no pane'
  assert_present "$D/state/.afk" 'Desktop launch did not enter away mode'
  [ "$(cat "$D/state/.afk-daemon-terminal")" = $'none\t-\tdesktop' ] || fail 'owner selection not durable'
  printf 'pending decision\n' > "$D/state/.subsuper-escalations"
  launch start-desktop >/dev/null 2>&1
  expect_code 0 "$?" 'Desktop refresh must keep its selected owner'
  assert_grep 'pending decision' "$D/state/.subsuper-escalations" 'refresh lost current delivery'
  if launch start-native >/dev/null 2>&1; then fail 'pane launch replaced Desktop owner'; fi
  launch stop >/dev/null 2>&1
  assert_absent "$D/state/.afk" 'Desktop stop did not clear away state'
}
test_rewake() {
  D=$(fixture rewake)
  select_desktop
  cat > "$D/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FM_HOME/state/daemon-args"
printf 'check: fixture desktop batch\n'
SH
  chmod +x "$D/bin/fm-supervise-daemon.sh"
  local out rc=0 kind
  out=$(hook 2>&1) || rc=$?
  expect_code 2 "$rc" 'Desktop away must rewake even without active worker metadata'
  . "$ROOT/bin/fm-operational-input.sh"
  fm_operational_input_kind "$out" kind || fail 'away reminder lost operational provenance'
  [ "$kind" = away-supervisor ] || fail 'away reminder has wrong kind'
  assert_contains "$out" 'fixture desktop batch' 'away reminder lost reason'
  assert_contains "$out" 'End every away turn with exactly · as its only visible text.' 'away reminder lost fixed-mark contract'
  assert_grep --stop-hook "$D/state/daemon-args" 'Desktop did not reuse daemon policy'
}
test_late_return() {
  D=$(fixture late-return)
  : > "$D/state/task.meta"
  select_desktop
  cat > "$D/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/coordinator-ran"
rm -f "${FM_HOME:?}"/state/.afk
printf 'check: late away delivery\n'
SH
  chmod +x "$D/bin/fm-supervise-daemon.sh"
  local out rc=0
  out=$(hook 2>&1) || rc=$?
  assert_present "$D/state/coordinator-ran" 'return race never reached delivery'
  expect_code 0 "$rc" 'return must suppress a late away completion'
  [ -z "$out" ] || fail 'late away reminder escaped after return'
}
test_hold() {
  D=$(fixture hold)
  select_desktop
  : > "$D/state/.captain-hold"
  cat > "$D/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/ran"
printf 'check: should not run\n'
SH
  chmod +x "$D/bin/fm-supervise-daemon.sh"
  local out rc=0
  out=$(hook 2>&1) || rc=$?
  expect_code 0 "$rc" 'global hold must suppress Desktop away'
  [ -z "$out" ] || fail 'held Desktop away emitted a reminder'
  assert_absent "$D/state/ran" 'held Desktop away started coordinator'
}
test_policy_delivery() {
  D=$(fixture policy-delivery)
  select_desktop
  local out
  out=$(FM_HOME="$D" bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    FM_AFK_STOP_HOOK=1
    escalate_add "$FM_HOME/state" "fixture decision"
    escalate_flush "$FM_HOME/state"
  ')
  assert_contains "$out" 'check:' 'hook policy did not emit a reason'
  assert_present "$D/state/.subsuper-escalations" 'handoff lost pending evidence before acknowledgment'
  launch acknowledge >/dev/null 2>&1
  [ ! -s "$D/state/.subsuper-escalations" ] || fail 'acknowledgment left delivered digest pending'
}
test_renewal() {
  D=$(fixture renewal)
  select_desktop
  printf 'pending renewal evidence\n' > "$D/state/.subsuper-escalations"
  mkfifo "$D/state/quiet"
  printf '#!/usr/bin/env bash\nread -r ignored < "$FM_HOME/state/quiet"\n' > "$D/bin/fm-watch.sh"
  chmod +x "$D/bin/fm-watch.sh"
  local out
  out=$(FM_HOME="$D" FM_AFK_RENEW_SECS=0 FM_AFK_TICK_SECS=0.01 fm_afk_fixture_coordinator "$D") || fail 'quiet renewal coordinator failed'
  assert_contains "$out" 'check: away-renewal' 'quiet coordinator did not renew before hook timeout'
  assert_absent "$D/state/.supervise-daemon.lock" 'renewal left a coordinator owner'
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail 'cleanup emitted an extra batch after renewal'
  assert_grep 'pending renewal evidence' "$D/state/.subsuper-escalations" 'renewal cleanup lost pending evidence'
}


test_protocol() {
  D=$(fixture protocol)
  select_desktop
  local out
  out=$(FM_HOME="$D" "$D/bin/fm-supervision-instructions.sh" --harness claude --afk 1 --repair-line)
  assert_contains "$out" 'Stop' 'Desktop recovery asked for a pane daemon'
  out=$(FM_HOME="$D" "$D/bin/fm-supervision-instructions.sh" --harness claude --afk 1)
  assert_contains "$out" 'follow its output policy, and keep the Stop hook' 'selected away protocol lost its delivery owner'
}
test_parked() {
  D=$(fixture parked)
  select_desktop
  printf 'window=fixture:fm-task\nbackend=tmux\n' > "$D/state/task.meta"
  printf 'captain-held [key=choice]: tracked by task-decision-choice\n' > "$D/state/task.status"
  local out
  out=$(FM_HOME="$D" FM_STALE_ESCALATE_SECS=0 FM_ESCALATE_BATCH_SECS=999 bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    stale_window_is_busy() { return 1; }
    handle_wake "stale: fixture:fm-task" "$FM_HOME/state"
    housekeeping "$FM_HOME/state"
    handle_wake "stale: fixture:fm-task" "$FM_HOME/state"
    housekeeping "$FM_HOME/state"
  ')
  [ -z "$out" ] || fail 'parked decision surfaced again'
  [ ! -s "$D/state/.subsuper-escalations" ] || fail 'parked decision became a repeated wedge'
  assert_absent "$D/state/.subsuper-stale-task" 'parked decision kept wedge aging'
}
test_launch_conflicts() {
  D=$(fixture conflicts)
  : > "$D/state/.afk-return-catchup"
  if launch start-desktop >/dev/null 2>&1; then fail 'Desktop entered before return reconciliation'; fi
  rm -f "${D:?}"/state/.afk-return-catchup
  : > "$D/state/.afk"
  if launch start-desktop >/dev/null 2>&1; then fail 'Desktop replaced an existing pane owner'; fi
  rm -f "${D:?}"/state/.afk
  printf 'tmux\tfixture\t\n' > "$D/state/.afk-daemon-terminal"
  if launch start-desktop >/dev/null 2>&1; then fail 'Desktop replaced an unreconciled terminal'; fi
  rm -f "${D:?}"/state/.afk-daemon-terminal
  select_desktop
  if FM_SUPERVISOR_TARGET=fixture:supervisor FM_SUPERVISOR_BACKEND=tmux launch start > "$D/pane-start.out" 2>&1; then fail 'pane launch replaced Desktop owner'; fi
  assert_grep 'Desktop owns away supervision' "$D/pane-start.out" 'pane start bypassed selected Desktop ownership'
  [ "$(cat "$D/state/.afk-daemon-terminal")" = $'none\t-\tdesktop' ] || fail 'failed pane switch lost the Desktop selection'
}
test_launch_rollback() {
  D=$(fixture rollback)
  mkdir "$D/failbin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$D/failbin/date"
  chmod +x "$D/failbin/date"
  if PATH="$D/failbin:$PATH" launch start-desktop >/dev/null 2>&1; then fail 'failed flag write passed'; fi
  assert_absent "$D/state/.afk" 'failed entry left away active'
  assert_absent "$D/state/.afk-daemon-terminal" 'failed entry left orphan owner selection'
}
test_guard_provenance() {
  D=$(fixture guard-provenance)
  select_desktop
  local out rc=0 kind
  out=$(printf '%s\n' '{"session_id":"fixture"}' | FM_HOME="$D" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 "$D/bin/fm-turnend-guard.sh" --claude 2>&1) || rc=$?
  expect_code 2 "$rc" 'missing Desktop owner must request recovery'
  . "$ROOT/bin/fm-operational-input.sh"
  fm_operational_input_kind "$out" kind || fail 'guard recovery could be mistaken for captain return'
  [ "$kind" = away-supervisor ] || fail 'guard recovery used wrong away provenance'
  assert_contains "$out" 'End every away turn with exactly · as its only visible text.' 'guard reminder lost fixed-mark contract'
}
test_transition() {
  D=$(fixture transition)
  : > "$D/state/task.meta"
  cat > "$D/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
date +%s > "$FM_HOME/state/.afk"
printf 'none\t-\tdesktop\n' > "$FM_HOME/state/.afk-daemon-terminal"
printf 'check: away-owner transition\n'
SH
  cat > "$D/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/coordinator-ran"
printf 'check: selected Desktop coordinator\n'
SH
  chmod +x "$D/bin/fm-watch-arm.sh" "$D/bin/fm-supervise-daemon.sh"
  local out rc=0
  out=$(hook 2>&1) || rc=$?
  expect_code 2 "$rc" 'active normal cycle must hand ownership to Desktop'
  assert_present "$D/state/coordinator-ran" 'normal owner ended without starting Desktop successor'
}
test_idle_transition() {
  D=$(fixture idle-transition)
  if ! FM_HOME="$D" FM_POLL=0.01 FM_HEARTBEAT=999999 python3 - "$D" <<'PYTEST'
import os, subprocess, sys, time
from pathlib import Path
home=Path(sys.argv[1])
p=subprocess.Popen([str(home/'bin/fm-watch.sh')], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    deadline=time.monotonic()+5
    while not (home/'state/.last-watcher-beat').exists():
        assert p.poll() is None, 'fixture watcher exited before readiness'
        assert time.monotonic()<deadline, 'fixture watcher readiness timed out'
        time.sleep(.01)
    (home/'state/.afk-daemon-terminal').write_text('none\t-\tdesktop\n')
    (home/'state/.afk').write_text('1\n')
    try:
        out,err=p.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        p.terminate();out,err=p.communicate()
    assert 'check: away-owner' in out, f'quiet normal watcher did not transfer ownership: {out} {err}'
finally:
    if p.poll() is None:
        p.terminate();p.wait()
PYTEST
  then
    fail 'idle transition did not produce a durable handoff'
  fi
}
test_batch_snapshot() {
  D=$(fixture batch-snapshot)
  select_desktop
  printf 'needs-decision [key=new]: fixture choice B\n' > "$D/state/task.status"
  local out
  out=$(FM_HOME="$D" FM_ESCALATE_BATCH_SECS=0 FM_HEARTBEAT_SCAN_SECS=0 bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    FM_AFK_STOP_HOOK=1
    handle_wake "check: fixture choice A" "$FM_HOME/state"
    housekeeping "$FM_HOME/state"
  ')
  assert_contains "$out" 'fixture choice A' 'handoff lost pending batch'
  assert_contains "$out" 'fixture choice B' 'handoff omitted evidence acknowledgment would erase'
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] || fail 'one policy tick emitted duplicate handoffs'
}
test_parked_prior_stale() {
  D=$(fixture parked-prior-stale)
  select_desktop
  printf 'window=fixture:fm-task\nbackend=tmux\n' > "$D/state/task.meta"
  printf 'captain-held [key=choice]: tracked by task-decision-choice\n' > "$D/state/task.status"
  printf '0\n' > "$D/state/.subsuper-stale-task"
  FM_HOME="$D" FM_STALE_ESCALATE_SECS=0 bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    stale_window_is_busy() { return 1; }
    housekeeping "$FM_HOME/state"
    handle_wake "stale: fixture:fm-task (idle 99s, possible wedge, escalation 2)" "$FM_HOME/state"
  ' > "$D/out"
  [ ! -s "$D/state/.subsuper-escalations" ] || fail 'old or enriched stale revived a parked decision'
}
test_direct_owner_conflict() {
  D=$(fixture direct-owner-conflict)
  select_desktop
  printf 'pending decision\n' > "$D/state/.subsuper-escalations"
  local out rc=0
  out=$(FM_HOME="$D" FM_SUPERVISOR_BACKEND=unsupported "$D/bin/fm-afk-start.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'direct pane entry replaced Desktop selection'
  assert_contains "$out" 'Desktop' 'direct pane entry ignored explicit Desktop owner'
  assert_grep 'pending decision' "$D/state/.subsuper-escalations" 'direct pane entry erased Desktop pending evidence'
}
test_daemon_owner_conflict() {
  D=$(fixture daemon-owner-conflict)
  select_desktop
  local out rc=0
  out=$(FM_HOME="$D" FM_SUPERVISOR_BACKEND=unsupported "$D/bin/fm-supervise-daemon.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'pane daemon started under Desktop selection'
  assert_contains "$out" 'Desktop' 'pane daemon ignored explicit Desktop owner'
}
test_output_failure_owner() {
  D=$(fixture output-failure-owner)
  select_desktop
  mkdir "$D/failbin"
  cat > "$D/failbin/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in *.claude-autoarm-output.*) exit 1 ;; esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$D/failbin/mktemp"
  printf '#!/usr/bin/env bash\n: > "$FM_HOME/state/normal-arm-ran"\n' > "$D/bin/fm-watch-arm.sh"
  chmod +x "$D/bin/fm-watch-arm.sh"
  PATH="$D/failbin:$PATH" hook > "$D/out" 2>&1 || true
  assert_absent "$D/state/normal-arm-ran" 'output capture failure started normal owner during Desktop away'
}
test_live_pane_owner() {
  D=$(fixture live-pane-owner)
  FM_HOME="$D" python3 - "$D" <<'PYTEST'
import os, subprocess, sys, time
from pathlib import Path
home=Path(sys.argv[1]); state=home/'state'
os.mkfifo(state/'owner-wait')
script=home/'bin/fm-supervise-daemon.sh'
script.write_text('#!/usr/bin/env bash\nread -r ignored < "$FM_HOME/state/owner-wait"\n')
p=subprocess.Popen([str(script)])
try:
    lock=state/'.supervise-daemon.lock'; lock.mkdir()
    (lock/'pid').write_text(str(p.pid)+'\n')
    result=subprocess.run([str(home/'bin/fm-afk-launch.sh'), 'start-desktop'], capture_output=True, text=True)
    assert result.returncode!=0, 'Desktop replaced a live pane daemon'
    assert not (state/'.afk').exists(), 'rejected selection created away flag'
finally:
    p.terminate(); p.wait()
PYTEST
}
test_flush_hold() {
  D=$(fixture flush-hold)
  select_desktop
  local out
  out=$(FM_HOME="$D" bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    FM_AFK_STOP_HOOK=1
    escalate_add "$FM_HOME/state" "fixture held choice"
    : > "$FM_HOME/state/.captain-hold"
    escalate_flush "$FM_HOME/state" || true
  ')
  [ -z "$out" ] || fail 'hold during pending handoff emitted an automatic turn'
  assert_grep 'fixture held choice' "$D/state/.subsuper-escalations" 'hold lost pending evidence'
}
test_ack_wrong_owner() {
  D=$(fixture ack-wrong-owner)
  : > "$D/state/.afk"
  printf 'none\t-\tnative\n' > "$D/state/.afk-daemon-terminal"
  printf 'pane pending evidence\n' > "$D/state/.subsuper-escalations"
  if launch acknowledge >/dev/null 2>&1; then fail 'Desktop acknowledgment consumed pane delivery'; fi
  assert_grep 'pane pending evidence' "$D/state/.subsuper-escalations" 'wrong owner erased evidence'
}
test_flush_return() {
  D=$(fixture flush-return)
  select_desktop
  local out
  out=$(FM_HOME="$D" bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    FM_AFK_STOP_HOOK=1
    escalate_add "$FM_HOME/state" "pending return choice"
    rm -f "${FM_HOME:?}"/state/.afk
    escalate_flush "$FM_HOME/state" || true
  ')
  [ -z "$out" ] || fail 'returned captain received a late coordinator handoff'
}
test_hook_no_alarm() {
  D=$(fixture hook-no-alarm)
  select_desktop
  : > "$D/state/.captain-hold"
  printf 'held pending evidence\n' > "$D/state/.subsuper-escalations"
  printf '0\n' > "$D/state/.subsuper-escalations.since"
  FM_HOME="$D" FM_ESCALATE_BATCH_SECS=999999999999 FM_MAX_DEFER_SECS=1 bash -c '
    . "$FM_HOME/bin/fm-supervise-daemon.sh"
    FM_AFK_STOP_HOOK=1
    wedge_alarm_notify() { : > "$FM_HOME/state/notification"; }
    housekeeping "$FM_HOME/state"
  ' > "$D/out"
  assert_absent "$D/state/notification" 'Desktop hook tried an outward wedge notification'
  assert_absent "$D/state/.subsuper-inject-wedged" 'Desktop hook used pane alarm path'
}
test_coordinator_retirement() {
  D=$(fixture coordinator-retirement)
  select_desktop
  : > "$D/state/.captain-hold"
  local out
  out=$(FM_HOME="$D" FM_AFK_RENEW_SECS=0 fm_afk_fixture_coordinator "$D") || fail 'held coordinator did not retire'
  [ -z "$out" ] || fail 'held coordinator renewed an automatic turn'
  rm -f "${D:?}"/state/.afk "${D:?}"/state/.captain-hold
  out=$(FM_HOME="$D" FM_AFK_RENEW_SECS=0 fm_afk_fixture_coordinator "$D") || fail 'returned coordinator did not retire'
  [ -z "$out" ] || fail 'retired coordinator renewed after return'
}


test_one_handoff() {
  D=$(fixture one-handoff)
  select_desktop
  printf '#!/usr/bin/env bash\nprintf "check: fixture handoff\\n"\n' > "$D/bin/fm-watch.sh"
  chmod +x "$D/bin/fm-watch.sh"
  local out
  out=$(FM_HOME="$D" FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=0 FM_AFK_TICK_SECS=0.01 fm_afk_fixture_coordinator "$D") || fail 'coordinator did not retire after handoff'
  [ "$(printf '%s\n' "$out" | grep -c '^check: away-batch')" -eq 1 ] || fail 'duplicate or missing coordinator handoff'
}


test_selected_watcher() {
  D=$(fixture selected-watcher)
  select_desktop
  FM_HOME="$D" FM_POLL=0.01 FM_HEARTBEAT=999999 python3 - "$D" <<'PYTEST'
import subprocess,sys,time
from pathlib import Path
home=Path(sys.argv[1])
p=subprocess.Popen([str(home/'bin/fm-watch.sh')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    deadline=time.monotonic()+5
    while not (home/'state/.last-watcher-beat').exists():
        assert p.poll() is None, 'selected watcher incorrectly requested normal-to-away transfer'
        assert time.monotonic()<deadline, 'selected watcher did not reach its event loop'
        time.sleep(.01)
finally:
    if p.poll() is None: p.terminate()
    out,err=p.communicate()
assert 'away-owner' not in out, f'Desktop child requested another owner: {out} {err}'
PYTEST
}
test_hook_ignores_terminal_config() {
  D=$(fixture ignores-terminal-config)
  select_desktop
  local out
  out=$(FM_HOME="$D" FM_SUPERVISOR_BACKEND=unsupported FM_AFK_RENEW_SECS=0 fm_afk_fixture_coordinator "$D") || fail 'Desktop hook tried terminal startup validation'
  assert_contains "$out" 'check: away-renewal' 'Desktop hook depended on a terminal backend'
}


test_transition_queue_failure() {
  D=$(fixture transition-queue-failure)
  FM_HOME="$D" FM_POLL=0.01 FM_HEARTBEAT=999999 python3 - "$D" <<'PYTEST'
import subprocess,sys,time
from pathlib import Path
home=Path(sys.argv[1]);state=home/'state'
p=subprocess.Popen([str(home/'bin/fm-watch.sh')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    deadline=time.monotonic()+5
    while not (state/'.last-watcher-beat').exists():
        assert p.poll() is None and time.monotonic()<deadline, 'fixture watcher did not reach readiness'
        time.sleep(.01)
    (state/'.wake-queue').mkdir()
    (state/'.afk-daemon-terminal').write_text('none\t-\tdesktop\n')
    (state/'.afk').write_text('1\n')
    try:out,err=p.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        p.terminate();out,err=p.communicate()
        raise AssertionError('failed durable transition did not retire its watcher')
    assert p.returncode!=0 and 'check: away-owner' not in out, f'undurable transfer reported a successful wake: {out} {err}'
finally:
    if p.poll() is None:p.terminate();p.wait()
PYTEST
}
failed=0
for name in launch rewake late_return hold policy_delivery renewal protocol parked launch_conflicts launch_rollback guard_provenance transition idle_transition batch_snapshot parked_prior_stale direct_owner_conflict daemon_owner_conflict output_failure_owner live_pane_owner flush_hold ack_wrong_owner flush_return hook_no_alarm coordinator_retirement one_handoff selected_watcher hook_ignores_terminal_config transition_queue_failure; do
  if ("test_$name"); then pass "Desktop away: $name"; else failed=$((failed + 1)); fi
done
[ "$failed" -eq 0 ]
