#!/usr/bin/env bash
# Exercise omp transition enforcement through the real arm and drain entrypoints.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-watch-transition)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/state" "$LAB/data" "$LAB/config"
for file in fm-watch-arm.sh fm-wake-drain.sh fm-wake-lib.sh fm-classify-lib.sh; do
  cp "$ROOT/bin/$file" "$LAB/bin/"
done
if [ -f "$ROOT/bin/fm-omp-watch-transition.sh" ]; then
  cp "${FM_TRANSITION_IMPLEMENTATION:-$ROOT/bin/fm-omp-watch-transition.sh}" "$LAB/bin/fm-omp-watch-transition.sh"
fi
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cat > "$LAB/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
printf 'launched\n' >> "$FM_HOME/launches"
printf 'heartbeat: fixture\n'
SH
cat > "$LAB/bin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
exec "$FM_TRANSITION_SOURCE/bin/fm-fleet-snapshot.sh" "$@"
SH
for file in fm-jira.sh fm-pr-auto-register.sh fm-guard.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/$file"
done
chmod +x "$LAB/bin/"*.sh
export FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state"
export FM_DATA_OVERRIDE="$LAB/data" FM_CONFIG_OVERRIDE="$LAB/config"
export FM_TRANSITION_SOURCE="$ROOT" OMPCODE=1 PI_SESSION_ID=normal PI_TOOL_CALL_ID=first
ARM="$LAB/bin/fm-watch-arm.sh"
DRAIN="$LAB/bin/fm-wake-drain.sh"
arm_number=0
arm() {
  arm_number=$((arm_number + 1))
  export PI_TOOL_CALL_ID="arm-$arm_number"
  rc=0
  output=$("$ARM" "$@" 2>&1) || rc=$?
}
assert_observed() {
  local actual
  actual=$(jq -sr '.[-1].observed' "$LAB/state/.omp-watch-transitions.log")
  [ "$actual" = "$1" ] || fail "expected observed $1, got $actual"
}
drain() {
  printf '1\t1\theartbeat\tfixture\theartbeat: fixture\n' > "$LAB/state/.wake-queue"
  "$DRAIN" >/dev/null 2>&1
}
arm
expect_code 0 "$rc" 'startup must arm'
jq -es '.[-1].observed == "startup"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'startup was not recognized from native session state'
drain
owner_rc=0
printf '1\t1\tstale\tworker\tfresh event\n' | "$LAB/bin/fm-omp-watch-transition.sh" drain --queue-lock-held >/dev/null 2>&1 || owner_rc=$?
expect_code 1 "$owner_rc" 'a drain cannot claim a queue transaction it does not own'
PI_TOOL_CALL_ID=retired "$LAB/bin/fm-omp-watch-transition.sh" cycle failed 42 late-close
PI_SESSION_ID=foreign "$LAB/bin/fm-omp-watch-transition.sh" cycle failed 42 late-close
PI_TOOL_CALL_ID=bare
arm
expect_code 2 "$rc" 'a clean normal wake cannot finish by a bare re-arm'
assert_contains "$output" firstmate_watch_reset 'refusal names the reset tool'
[ "$(wc -l < "$LAB/launches" | tr -d ' ')" = 1 ] || fail 'refused re-arm launched a watcher'
pass 'clean ordinary wake refuses a bare re-arm before launching'

arm --transition work-pending
expect_code 2 "$rc" 'a declaration needs its concrete reason'
arm --transition invalid --reason 'invalid declaration'
expect_code 2 "$rc" 'unsupported declarations cannot silently arm'

for reason in work-pending unanswered-input chat-question stow-incomplete unknown; do
  PI_TOOL_CALL_ID="declared-$reason"
  arm --transition "$reason" --reason "fixture $reason remains"
  expect_code 0 "$rc" "$reason must preserve supervision"
  if [ "$reason" = unknown ]; then
    assert_contains "$output" WARNING 'unknown must warn visibly'
  fi
  assert_grep "$reason" "$LAB/state/.omp-watch-transitions.log" 'claim is durably recorded'
  drain
done
for operation in push merge cleanup steer; do
  arm --transition work-pending --reason "$operation is half done"
  expect_code 0 "$rc" "half-done $operation must arm"
  drain
done
pass 'explicit work, unanswered input, chat question and incomplete-stow declarations preserve arming'

printf 'needs-decision [key=shape]: choose shape\nworking: unrelated progress\n' > "$LAB/state/worker.status"
arm
expect_code 0 "$rc" 'an open decision cannot be masked by later progress'
assert_observed decision
assert_not_contains "$output" WARNING 'open status decision must be verified rather than unknown'
drain
printf 'resolved [key=shape]: chosen\n' >> "$LAB/state/worker.status"
arm
expect_code 2 "$rc" 'resolved decision must not remain an exemption'
printf 'blocked [key=next]: next step owed\n' >> "$LAB/state/worker.status"
arm
expect_code 0 "$rc" 'blocked next step must arm'
assert_observed decision
assert_not_contains "$output" WARNING 'blocked next step must be verified rather than unknown'
drain
printf 'resolved [key=next]: unblocked\n' >> "$LAB/state/worker.status"
pass 'keyed decisions and blocked work are verified from the complete status stream'

touch "$LAB/state/.afk"
arm
expect_code 0 "$rc" 'away mode must arm'
rm -f "${LAB:?}/state/.afk"
drain
printf 'none\t-\tomp\n' > "$LAB/state/.afk-daemon-terminal"
arm
expect_code 0 "$rc" 'selected away delivery must arm'
rm -f "${LAB:?}/state/.afk-daemon-terminal"
drain
PI_SESSION_ID=replacement
arm
expect_code 0 "$rc" 'replacement-session startup must arm'
jq -es '.[-1].observed == "startup"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'replacement startup was misclassified'
drain
pass 'away and replacement-session startup remain protected'

touch "$LAB/state/.captain-hold"
arm
expect_code 0 "$rc" 'a global hold must arm without resetting'
rm -f "${LAB:?}/state/.captain-hold"
drain
printf '1\t2\tcheck\tlater\tcheck: waiting\n' > "$LAB/state/.wake-queue"
arm
expect_code 0 "$rc" 'undrained wakes must arm without resetting'
drain
printf 'not a cycle\n' > "$LAB/state/.omp-watch-cycle"
arm
expect_code 0 "$rc" 'unreadable cycle must preserve supervision'
assert_contains "$output" WARNING 'unreadable cycle must warn'
printf 'not a cycle\n' > "$LAB/state/.omp-watch-cycle"
arm --transition work-pending --reason 'second instruction remains'
expect_code 0 "$rc" 'an explicit work claim must still preserve unknown-state arming'
assert_contains "$output" WARNING 'unknown evidence must warn even with a work declaration'
drain
pass 'holds, queued wakes and unknown state preserve arming'

printf '## Queued\n- [ ] choice - Choose behavior (repo: firstmate, kind: captain, hold: awaiting answer, hold-kind: captain)\n' > "$LAB/data/backlog.md"
arm
expect_code 0 "$rc" 'durable backlog hold must arm'
assert_observed decision
assert_not_contains "$output" WARNING 'backlog hold must be verified rather than unknown'
drain
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'decisions.json\n' > "$LAB/config/decision-inbox"
printf '{"open": [ ["firstmate", "choice", "answer", "Choose behavior"] ]}\n' > "$LAB/decisions.json"
printf '.open\n' > "$LAB/config/decision-inbox-query.jq"
arm
expect_code 0 "$rc" 'configured decision inbox must arm'
assert_not_contains "$output" WARNING 'a valid private projection must be read without changing its input shape'
drain
printf '{"open": []}\n' > "$LAB/decisions.json"
arm
expect_code 2 "$rc" 'empty inbox must not exempt a clean wake'
pass 'backlog holds and configured inbox questions are independently verified'

printf '## Done\n' > "$LAB/data/backlog.md"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  printf -- '- [x] completed-%s - Finished (repo: firstmate)\n' "$i" >> "$LAB/data/backlog.md"
done
arm
expect_code 2 "$rc" 'bounded completion history cannot exempt a clean wake'
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"

rm -f "${LAB:?}/config/decision-inbox"
ln -s "$LAB/missing-inbox-setting" "$LAB/config/decision-inbox"
arm
expect_code 0 "$rc" 'broken inbox configuration must preserve supervision'
assert_contains "$output" WARNING 'broken inbox configuration must warn'
rm -f "${LAB:?}/config/decision-inbox"
drain
mkdir "$LAB/state/unreadable.status"
arm
expect_code 0 "$rc" 'invalid status evidence must preserve supervision'
assert_contains "$output" WARNING 'invalid status evidence must warn'
rmdir "${LAB:?}/state/unreadable.status"
drain
pass 'irrelevant completion history stays clean while unreadable evidence warns and arms'

printf '1\t2\talien\tfixture\tunsupported wake\n' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 0 "$rc" 'an unknown wake kind must not require reset'
assert_contains "$output" WARNING 'an unknown wake kind must warn'
drain

stale_row() {
  printf '1\t3\tstale\tworker\t%s' "$1"
  [ -z "${2:-}" ] || printf '\t%s' "$2"
  printf '\n'
}
arm --transition work-pending --reason 'begin unsupported event-kind case'
printf '1\t3\tidle-recheck\tworker\tunsupported kind named like an internal class\n' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 0 "$rc" 'unsupported event kind must preserve unknown-state arming'
assert_contains "$output" WARNING 'unsupported kind must not impersonate the verified idle class'
assert_observed unknown

arm --transition work-pending --reason 'begin isolated stale cycle'
expect_code 0 "$rc" 'stale fixture starts a fresh cycle'
stale_row 'stale: worker (unresponsive; deep inspection required)' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'fresh actionable stale cannot acquire the idle exemption'
assert_observed clean
assert_contains "$output" firstmate_watch_reset 'fresh stale refusal names reset'
arm --transition watching-only --reason 'the new stale event is handled; no work remains'
expect_code 2 "$rc" 'fresh handled stale still requires reset'
assert_observed clean
arm --transition work-pending --reason 'begin misleading display-text case'
stale_row 'stale: worker (paused; rechecked)' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'display prose cannot establish idle provenance'
assert_observed clean
pass 'fresh stale wakes cannot bypass reset with bare or watching-only arms'

for class in parked 'done' paused; do
  mkdir -p "$LAB/fakebin"
  cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-worker\n' ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${PRODUCER_COMMAND:-claude}" ;;
      *pane_tty*) : ;;
      *) printf '%%1\n' ;;
    esac ;;
  capture-pane) printf 'idle composer\n' ;;
  *) exit 1 ;;
esac
SH
  cat > "$LAB/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: status-log · reported state\n' "$PRODUCER_CLASS"
SH
  chmod +x "$LAB/fakebin/tmux" "$LAB/fakebin/crew-state"
  for repetition in 1 2; do
    arm --transition work-pending --reason "begin $class recheck cycle"
    expect_code 0 "$rc" 'producer fixture starts a fresh cycle'
    kind=scout
    [ "$class" != paused ] || kind=secondmate
    printf 'window=test:fm-worker\nbackend=tmux\nharness=claude\nkind=%s\n' "$kind" > "$LAB/state/worker.meta"
    pane_hash=$(printf 'idle composer' | { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | awk '{print $1}'; fi; })
    printf '%s' "$pane_hash" > "$LAB/state/.hash-test_fm-worker"
    printf '1\n' > "$LAB/state/.count-test_fm-worker"
    printf '%s: already reported\n' "$class" > "$LAB/state/worker.status"
    if [ "$(uname)" = Darwin ]; then
      sig=$(stat -f '%z:%Fm' "$LAB/state/worker.status")
    else
      sig=$(stat -c '%s:%Y' "$LAB/state/worker.status")
    fi
    printf '%s' "$sig" > "$LAB/state/.seen-worker_status"
    touch "$LAB/state/.last-check"
    PATH="$LAB/fakebin:$PATH" PRODUCER_CLASS="$class" FM_CREW_STATE_BIN="$LAB/fakebin/crew-state" \
      FM_POLL=0 FM_SIGNAL_GRACE=0 FM_PAUSE_RESURFACE_SECS=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch.sh" > "$LAB/producer.out" 2> "$LAB/producer.err" || fail "real $class producer failed: $(cat "$LAB/producer.err")"
    assert_grep 'stale: test:fm-worker' "$LAB/producer.out" 'the real producer must surface its recheck'
    "$DRAIN" > "$LAB/drained.out" 2>&1
    rm -f "${LAB:?}/state/worker.meta" "${LAB:?}/state/worker.status"
    "$DRAIN" >/dev/null 2>&1
    if [ "$repetition" = 1 ]; then arm
    else arm --transition idle-recheck --reason 'already reported idle wait'; fi
    expect_code 0 "$rc" "$class recheck must not force reset"
    assert_observed idle-recheck
    assert_not_contains "$output" WARNING 'verified idle provenance must not degrade to unknown'
  done
  drain
done
pass 'real idle and paused producers retain verifiable provenance through drain and repeated arms'

for scenario in fresh terminal escalated dead; do
  arm --transition work-pending --reason "begin $scenario stale cycle"
  expect_code 0 "$rc" 'fresh producer fixture starts a new cycle'
  printf 'window=test:fm-worker\nbackend=tmux\nharness=claude\nkind=scout\n' > "$LAB/state/worker.meta"
  class=unknown
  command=claude
  case "$scenario" in
    terminal) status='done' ;;
    escalated) status=working; class=working ;;
    dead) status=working; command=zsh ;;
    *) status=working ;;
  esac
  printf '%s: already reported\n' "$status" > "$LAB/state/worker.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$LAB/state/worker.status")
  else sig=$(stat -c '%s:%Y' "$LAB/state/worker.status"); fi
  printf '%s' "$sig" > "$LAB/state/.seen-worker_status"
  pane_hash=$(printf 'idle composer' | { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | awk '{print $1}'; fi; })
  printf '%s' "$pane_hash" > "$LAB/state/.hash-test_fm-worker"
  printf '1\n' > "$LAB/state/.count-test_fm-worker"
  rm -f "${LAB:?}/state/.stale-test_fm-worker" "${LAB:?}/state/.paused-test_fm-worker" "${LAB:?}/state/.quiet-stale-test_fm-worker" "${LAB:?}/state/.quiet-state-test_fm-worker"
  if [ "$scenario" = escalated ]; then
    printf '%s' "$pane_hash" > "$LAB/state/.stale-test_fm-worker"
    printf '1\n' > "$LAB/state/.stale-since-test_fm-worker"
  fi
  touch "$LAB/state/.last-check"
  PATH="$LAB/fakebin:$PATH" PRODUCER_CLASS="$class" PRODUCER_COMMAND="$command" FM_CREW_STATE_BIN="$LAB/fakebin/crew-state" \
    FM_POLL=0 FM_SIGNAL_GRACE=0 FM_STALE_ESCALATE_SECS=0 FM_PAUSE_RESURFACE_SECS=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$LAB/producer.out" 2> "$LAB/producer.err" || fail "real $scenario producer failed: $(cat "$LAB/producer.err")"
  assert_grep 'stale: test:fm-worker' "$LAB/producer.out" 'the real fresh producer must surface'
  if [ "$scenario" = escalated ]; then assert_grep 'possible wedge, escalation' "$LAB/producer.out" 'the fixture must exercise wedge escalation'; fi
  if [ "$scenario" = dead ]; then assert_grep 'agent exited or endpoint gone' "$LAB/producer.out" 'the fixture must exercise death'; fi
  "$DRAIN" >/dev/null 2>&1
  rm -f "${LAB:?}/state/worker.meta" "${LAB:?}/state/worker.status"
  arm
  expect_code 2 "$rc" "$scenario stale requires reset after handling"
  assert_observed clean
  assert_contains "$output" firstmate_watch_reset 'fresh producer refusal must name reset'
  arm --transition watching-only --reason 'new event handled; nothing remains'
  expect_code 2 "$rc" "$scenario watching-only declaration cannot bypass reset"
  assert_observed clean
  assert_not_contains "$output" WARNING 'fresh producer must be classified, not unknown'
done
pass 'real fresh, terminal, escalated and dead producers require reset after handling'

for kind in signal check heartbeat; do
  arm --transition work-pending --reason 'begin non-stale provenance case'
  bash -c '. "$1"; fm_wake_append "$2" fixture "ordinary event" idle-recheck' _ "$LAB/bin/fm-wake-lib.sh" "$kind"
  "$DRAIN" > "$LAB/drained.out" 2>&1
  awk -F '\t' 'NF != 5 {exit 1}' "$LAB/drained.out" || fail 'non-stale queue rows gained stale provenance'
  arm
  expect_code 2 "$rc" 'stale provenance must not exempt a non-stale event'
  assert_observed clean
done
arm --transition work-pending --reason 'begin malformed provenance case'
stale_row 'stale recheck with an unexpected field' idle-recheck | awk '{print $0 "\textra"}' | "$LAB/bin/fm-omp-watch-transition.sh" drain
arm
expect_code 2 "$rc" 'malformed provenance must not establish an idle exemption'
assert_observed clean
arm --transition work-pending --reason 'begin malformed queued provenance case'
{
  stale_row 'stale recheck with an unexpected field' idle-recheck | awk '{print $0 "\textra"}'
  stale_row 'later idle recheck' idle-recheck
} > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'dedup must not bless malformed idle provenance'
assert_observed clean
pass 'stale provenance is structural and does not exempt other or malformed events'

for ordering in fresh-first idle-first; do
  arm --transition work-pending --reason 'begin duplicate stale cycle'
  if [ "$ordering" = fresh-first ]; then
    stale_row 'fresh actionable stale'
    stale_row 'idle recheck' idle-recheck
  else
    stale_row 'idle recheck' idle-recheck
    stale_row 'fresh actionable stale'
  fi > "$LAB/state/.wake-queue"
  "$DRAIN" >/dev/null 2>&1
  arm
  expect_code 2 "$rc" 'fresh duplicate must dominate an idle recheck in either order'
  assert_observed clean
  drain
done
arm --transition work-pending --reason 'begin successive stale drains'
stale_row 'idle recheck' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
stale_row 'new actionable stale' > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'fresh event in a later drain must dominate the earlier idle recheck'
assert_observed clean
stale_row 'idle recheck' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'later idle drain must not erase fresh provenance'
assert_observed clean
drain
arm --transition watching-only --reason 'nothing remains'
expect_code 2 "$rc" 'declared watching-only must use reset'
pass 'fresh events dominate duplicate and successive idle drains'

arm --transition work-pending --reason 'begin overlapping drains case'
python3 - "$LAB" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys

home = Path(sys.argv[1])
shim = home / 'overlap-bin'
shim.mkdir()
for name in ('ready', 'release', 'contender'):
    os.mkfifo(home / name)
(shim / 'awk').write_text("""#!/usr/bin/env bash
if [ "${HOLD_IDLE_DRAIN:-}" = 1 ] && [ "$#" -eq 3 ] && [ "$1" = -F ] && [ "$2" = '\\t' ] && mkdir "$FM_HOME/receipt-seen" 2>/dev/null; then
  printf 'ready\\n' > "$FM_HOME/ready"
  read -r _ < "$FM_HOME/release"
fi
exec /usr/bin/awk "$@"
""")
(shim / 'cat').write_text("""#!/usr/bin/env bash
if [ "${OVERLAP_CONTENDER:-}" = 1 ]; then
  case "$*" in *'.wake-queue.lock/pid')
    if mkdir "$FM_HOME/contender-seen" 2>/dev/null; then
      printf 'attempt\\n' > "$FM_HOME/contender"
    fi
    ;;
  esac
fi
exec /bin/cat "$@"
""")
for path in shim.iterdir():
    path.chmod(0o755)
env = dict(os.environ, PATH=str(shim) + ':' + os.environ['PATH'])
drain = str(home / 'bin/fm-wake-drain.sh')
append = ['bash', '-c', '. "$1"; fm_wake_append stale worker "$2" "${3:-}"',
          '_', str(home / 'bin/fm-wake-lib.sh')]

def call(command, extra=None):
    result = subprocess.run(command, env=dict(env, **(extra or {})), capture_output=True, text=True)
    assert result.returncode == 0, (command, result.stdout, result.stderr)
    lock = home / 'state/.wake-queue.lock'
    assert not lock.exists() and not lock.is_symlink(), 'completed helper left its queue lock behind'
    return result

call(append + ['already reported idle', 'idle-recheck'])
with (home / 'idle.out').open('w') as out, (home / 'idle.err').open('w') as err:
    idle = subprocess.Popen([drain], env=dict(env, HOLD_IDLE_DRAIN='1'), stdout=out, stderr=err)
    with (home / 'ready').open() as ready:
        assert ready.readline() == 'ready\n'
    serialized = (home / 'state/.wake-queue.lock').is_symlink()
    if serialized:
        fresh = subprocess.Popen(append + ['fresh actionable stale'],
                                 env=dict(env, OVERLAP_CONTENDER='1'),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        with (home / 'contender').open() as contender:
            assert contender.readline() == 'attempt\n'
    else:
        call(append + ['fresh actionable stale'])
        newer = call([drain])
        assert 'fresh actionable stale' in newer.stdout
        assert 'stale' == (home / 'state/.omp-watch-drain').read_text().splitlines()[2]
    with (home / 'release').open('w') as release:
        release.write('continue\n')
    assert idle.wait() == 0
    if serialized:
        stdout, stderr = fresh.communicate()
        assert fresh.returncode == 0, (stdout, stderr)
        newer = call([drain])
        assert 'fresh actionable stale' in newer.stdout
assert 'already reported idle' in (home / 'idle.out').read_text()
assert not (home / 'state/.wake-queue').read_text()
result = subprocess.run([str(home / 'bin/fm-watch-arm.sh')],
                        env=dict(env, PI_TOOL_CALL_ID='overlap-next-arm'),
                        capture_output=True, text=True)
verdict = json.loads((home / 'state/.omp-watch-transitions.log').read_text().splitlines()[-1])
print(json.dumps(dict(serialized=serialized, receipt=(home / 'state/.omp-watch-drain').read_text(),
                      arm_exit=result.returncode, stdout=result.stdout, stderr=result.stderr, verdict=verdict)))
assert result.returncode == 2, 'overlapping idle drain erased fresh evidence: expected exit 2, got ' + str(result.returncode)
assert verdict['observed'] == 'clean', verdict
assert 'firstmate_watch_reset' in result.stderr
assert 'WARNING' not in result.stderr

(home / 'contender-seen').rmdir()
(home / 'receipt-seen').rmdir()
helper = str(home / 'bin/fm-omp-watch-transition.sh')
call([helper, 'cycle', 'starting', '999999', 'cycle-boundary-fixture'])
call([helper, 'cycle', 'wake', '999999', 'actionable-stale'])
call(append + ['idle before replacement', 'idle-recheck'])
with (home / 'idle.out').open('w') as out, (home / 'idle.err').open('w') as err:
    idle = subprocess.Popen([drain], env=dict(env, HOLD_IDLE_DRAIN='1'), stdout=out, stderr=err)
    with (home / 'ready').open() as ready:
        assert ready.readline() == 'ready\n'
    successor = subprocess.Popen(['bash', '-c', '"$@"\nrc=$?\nif mkdir "$FM_HOME/contender-seen" 2>/dev/null; then\n  printf \'completed\\n\' > "$FM_HOME/contender"\nfi\nexit "$rc"', '_', helper, 'cycle', 'starting', '999999', 'replacement'],
        env=dict(env, OVERLAP_CONTENDER='1', PI_TOOL_CALL_ID='successor-cycle'),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    with (home / 'contender').open() as contender:
        boundary = contender.readline()
    with (home / 'release').open('w') as release:
        release.write('continue\n')
    assert idle.wait() == 0
    stdout, stderr = successor.communicate()
    assert successor.returncode == 0, (stdout, stderr)
assert boundary == 'attempt\n', 'cycle replacement crossed an in-flight receipt transaction'
call([helper, 'cycle', 'wake', '999999', 'actionable-stale'], {'PI_TOOL_CALL_ID': 'successor-cycle'})
call(append + ['fresh after replacement'])
call([drain])
result = subprocess.run([str(home / 'bin/fm-watch-arm.sh')],
                        env=dict(env, PI_TOOL_CALL_ID='replacement-next-arm'),
                        capture_output=True, text=True)
verdict = json.loads((home / 'state/.omp-watch-transitions.log').read_text().splitlines()[-1])
assert result.returncode == 2, (result.stdout, result.stderr)
assert verdict['observed'] == 'clean', verdict
assert 'WARNING' not in result.stderr

(home / 'contender-seen').rmdir()
(home / 'receipt-seen').rmdir()
call([helper, 'cycle', 'starting', '999999', 'arm-boundary-fixture'])
call([helper, 'cycle', 'wake', '999999', 'actionable-stale'])
call(append + ['earlier idle receipt', 'idle-recheck'])
call([drain])
call(append + ['fresh event in flight'])
with (home / 'idle.out').open('w') as out, (home / 'idle.err').open('w') as err:
    fresh_drain = subprocess.Popen([drain], env=dict(env, HOLD_IDLE_DRAIN='1'), stdout=out, stderr=err)
    with (home / 'ready').open() as ready:
        assert ready.readline() == 'ready\n'
    arm = subprocess.Popen(['bash', '-c', '"$@"\nrc=$?\nif mkdir "$FM_HOME/contender-seen" 2>/dev/null; then\n  printf \'completed\\n\' > "$FM_HOME/contender"\nfi\nexit "$rc"', '_', str(home / 'bin/fm-watch-arm.sh')],
        env=dict(env, OVERLAP_CONTENDER='1', PI_TOOL_CALL_ID='arm-during-drain'),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    with (home / 'contender').open() as contender:
        boundary = contender.readline()
    with (home / 'release').open('w') as release:
        release.write('continue\n')
    assert fresh_drain.wait() == 0
    stdout, stderr = arm.communicate()
assert boundary == 'attempt\n', 'arm observed a receipt before its drain transaction committed'
assert arm.returncode == 2, 'arm ignored committed fresh evidence: expected exit 2, got ' + str(arm.returncode)
verdict = json.loads((home / 'state/.omp-watch-transitions.log').read_text().splitlines()[-1])
assert verdict['observed'] == 'clean', verdict
assert 'WARNING' not in stderr
previous_receipt = (home / 'state/.omp-watch-drain').read_text()
call([helper, 'drain'], {'PI_SESSION_ID': 'foreign-session'})
assert (home / 'state/.omp-watch-drain').read_text() == previous_receipt
PYTEST
pass 'overlapping real drains cannot replace fresh evidence with an older idle receipt'

arm --transition work-pending --reason 'begin failed receipt publication case'
stale_row 'previous idle recheck' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
mkdir "$LAB/failure-bin"
cat > "$LAB/failure-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-drain" ] && { [ "${FAIL_RECEIPT_STAGE:-}" = all ] || [ "$(sed -n '3p' "$2")" != unknown ]; }; then
  printf 'failed receipt publication\n' >> "$FM_HOME/publication-failures"
  exit 1
fi
exec /bin/mv "$@"
SH
chmod +x "$LAB/failure-bin/mv"
stale_row 'newly consumed fresh event' > "$LAB/state/.wake-queue"
failure_output=$(PATH="$LAB/failure-bin:$PATH" "$DRAIN" 2>&1)
assert_grep 'failed receipt publication' "$LAB/publication-failures" 'the receipt write must actually fail'
assert_contains "$failure_output" 'newly consumed fresh event' 'fresh row must be printed despite failed receipt publication'
assert_contains "$failure_output" WARNING 'drain must report failed receipt publication'
[ ! -s "$LAB/state/.wake-queue" ] || fail 'publication failure must not silently leave the printed fresh event queued'
failure_verdict=$("$LAB/bin/fm-omp-watch-transition.sh" arm '' '' 2>&1)
assert_observed unknown
assert_contains "$failure_verdict" WARNING 'failed publication must be unknown before another drain'
"$DRAIN" >/dev/null 2>&1
stale_row 'later idle cannot repair lost fresh evidence' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 0 "$rc" 'failed receipt persistence must preserve supervision'
assert_observed unknown
assert_contains "$output" WARNING 'previous idle receipt cannot conceal failed fresh publication'
pass 'failed fresh receipt publication warns and cannot reuse an older idle exemption'

arm --transition work-pending --reason 'begin failed uncertainty publication case'
stale_row 'previous idle recheck' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
stale_row 'fresh row retained if uncertainty cannot be saved' > "$LAB/state/.wake-queue"
failure_rc=0
failure_output=$(PATH="$LAB/failure-bin:$PATH" FAIL_RECEIPT_STAGE=all "$DRAIN" 2>&1) || failure_rc=$?
expect_code 1 "$failure_rc" 'failure to save uncertainty must retain discoverable fresh evidence'
assert_contains "$failure_output" WARNING 'unavailable uncertainty receipt must warn'
assert_grep 'fresh row retained' "$LAB/state/.wake-queue" 'failed uncertainty write must restore the raw wake'
arm
expect_code 0 "$rc" 'unconsumed fresh wake must preserve supervision'
assert_observed queued-wakes
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'successfully retried fresh receipt must still require reset'
assert_observed clean
pass 'failed uncertainty publication retains the wake for a safe retry'

printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/fm-watch.sh"
arm --transition unknown --reason 'fixture failure'
expect_code 1 "$rc" 'fixture must actually fail its cycle'
printf '#!/usr/bin/env bash\nprintf "heartbeat: repaired\\n"\n' > "$LAB/bin/fm-watch.sh"
arm
expect_code 0 "$rc" 'failed watcher must repair without reset'
jq -es '.[-1].observed == "repair"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'failed cycle was not recognized as repair'
drain
printf '%s\n' "$PI_SESSION_ID" previous running 999999 fixture > "$LAB/state/.omp-watch-cycle"
arm
expect_code 0 "$rc" 'missing watcher must repair without reset'
jq -es '.[-1].observed == "repair"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'missing watcher was not recognized as repair'
drain
"$LAB/bin/fm-omp-watch-transition.sh" recovery "$PI_SESSION_ID"
arm
expect_code 0 "$rc" 'reset recovery must arm'
drain
arm
expect_code 2 "$rc" 'recovery exemption must not survive the replacement arm'
pass 'failed and missing cycles repair, and reset recovery is consumed once'

OMPCODE=0 arm
expect_code 0 "$rc" 'other primary harnesses must retain existing arming'
pass 'non-omp harnesses keep their existing arm behavior'

output=$(PI_SESSION_ID='' "$ARM" 2>&1) || fail 'unknown native identity must preserve arming'
assert_contains "$output" WARNING 'unknown native identity must warn'
output=$(PI_TOOL_CALL_ID='' "$ARM" 2>&1) || fail 'unknown native call must preserve arming'
assert_contains "$output" WARNING 'unknown native call must warn'
for i in $(seq 1 260); do printf '{"previous":%s}\n' "$i"; done > "$LAB/state/.omp-watch-transitions.log"
arm --transition unknown --reason 'bounded ledger proof'
expect_code 0 "$rc" 'bounded ledger fixture must arm'
jq -es 'length == 256 and .[-1].claim == "unknown"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'transition ledger is unbounded or lost the new claim'
python3 - "$LAB/state/.omp-watch-transitions.log" <<'PY'
import pathlib,sys
assert pathlib.Path(sys.argv[1]).stat().st_mode & 0o777 == 0o600
PY
pass 'unknown native identities warn and the private transition ledger stays bounded'
