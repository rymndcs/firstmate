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
queue_rows() {
  local row sequence
  while IFS= read -r row; do
    sequence=$(cat "$LAB/state/.wake-queue.seq" 2>/dev/null || echo 0)
    sequence=$((sequence + 1))
    printf '%s\n' "$sequence" > "$LAB/state/.wake-queue.seq"
    printf '%s\n' "$row" | awk -F '\t' -v OFS='\t' -v seq="$sequence" '{$2=seq;print}'
  done
}
drain() {
  : > "$LAB/state/.wake-queue"
  bash -c '. "$1"; fm_wake_append heartbeat fixture "heartbeat: fixture"' _ "$LAB/bin/fm-wake-lib.sh"
  "$DRAIN" >/dev/null 2>&1
}
overlap_transactions() {
python3 - "$LAB" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys

home = Path(sys.argv[1])
shim = home / 'overlap-bin'
shim.mkdir()
for name in ('ready', 'release', 'contender', 'contender-resume'):
    os.mkfifo(home / name)
(shim / 'awk').write_text("""#!/usr/bin/env bash
if [ "${HOLD_IDLE_DRAIN:-}" = 1 ] && [ "$#" -eq 5 ] && [ "$1" = -F ] && [ "$2" = '\\t' ] && mkdir "$FM_HOME/receipt-seen" 2>/dev/null; then
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
      read -r _ < "$FM_HOME/contender-resume"
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
        assert 'stale' == ' '.join(json.loads((home / 'state/.omp-watch-transition').read_text())['classes'])
    with (home / 'release').open('w') as release:
        release.write('continue\n')
    assert idle.wait() == 0
    if serialized:
        with (home / 'contender-resume').open('w') as resume:
            resume.write('continue\n')
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
print(json.dumps(dict(serialized=serialized, receipt=(home / 'state/.omp-watch-transition').read_text(),
                      arm_exit=result.returncode, stdout=result.stdout, stderr=result.stderr, verdict=verdict)))
assert result.returncode == 2, 'overlapping idle drain erased fresh evidence: expected exit 2, got ' + str(result.returncode)
assert verdict['observed'] == 'clean', verdict
assert 'firstmate_watch_reset' in result.stderr
assert 'WARNING' not in result.stderr

(home / 'contender-seen').rmdir()
(home / 'receipt-seen').rmdir()
helper = str(home / 'bin/fm-omp-watch-transition.sh')
call([str(home / 'bin/fm-watch-arm.sh'), '--transition', 'work-pending', '--reason', 'begin cycle boundary'], {'PI_TOOL_CALL_ID': 'cycle-boundary-fixture'})
call(append + ['idle before replacement', 'idle-recheck'])
with (home / 'idle.out').open('w') as out, (home / 'idle.err').open('w') as err:
    idle = subprocess.Popen([drain], env=dict(env, HOLD_IDLE_DRAIN='1'), stdout=out, stderr=err)
    with (home / 'ready').open() as ready:
        assert ready.readline() == 'ready\n'
    successor = subprocess.Popen(['bash', '-c', '"$@"\nrc=$?\nif mkdir "$FM_HOME/contender-seen" 2>/dev/null; then\n  printf \'completed\\n\' > "$FM_HOME/contender"\nfi\nexit "$rc"', '_', str(home / 'bin/fm-watch-arm.sh'), '--transition', 'work-pending', '--reason', 'replacement'],
        env=dict(env, OVERLAP_CONTENDER='1', PI_TOOL_CALL_ID='successor-cycle'),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    with (home / 'contender').open() as contender:
        boundary = contender.readline()
    with (home / 'release').open('w') as release:
        release.write('continue\n')
    assert idle.wait() == 0
    if boundary == 'attempt\n':
        with (home / 'contender-resume').open('w') as resume:
            resume.write('continue\n')
    stdout, stderr = successor.communicate()
    assert successor.returncode == 0, (stdout, stderr)
    print('vacated-lock successor stderr=' + repr(stderr), flush=True)
    assert 'WARNING' not in stderr, 'a vacated owned lock was mistaken for unavailable evidence: ' + stderr
assert boundary == 'attempt\n', 'cycle replacement crossed an in-flight receipt transaction'
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
call([str(home / 'bin/fm-watch-arm.sh'), '--transition', 'work-pending', '--reason', 'begin arm boundary'], {'PI_TOOL_CALL_ID': 'arm-boundary-fixture'})
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
    if boundary == 'attempt\n':
        with (home / 'contender-resume').open('w') as resume:
            resume.write('continue\n')
    stdout, stderr = arm.communicate()
assert boundary == 'attempt\n', 'arm observed a receipt before its drain transaction committed'
assert arm.returncode == 2, 'arm ignored committed fresh evidence: expected exit 2, got ' + str(arm.returncode)
verdict = json.loads((home / 'state/.omp-watch-transitions.log').read_text().splitlines()[-1])
assert verdict['observed'] == 'clean', verdict
assert 'WARNING' not in stderr
previous_receipt = (home / 'state/.omp-watch-transition').read_text()
foreign = subprocess.run([helper, 'drain'], env=dict(env, PI_SESSION_ID='foreign-session'), capture_output=True, text=True)
assert foreign.returncode != 0
assert (home / 'state/.omp-watch-transition').read_text() == previous_receipt
PYTEST
}
grant_recovery() {
  local token
  token=$("$LAB/bin/fm-omp-watch-transition.sh" identity "$PI_SESSION_ID")
  "$LAB/bin/fm-omp-watch-transition.sh" recovery "$PI_SESSION_ID" "$token"
}
if [ -n "${FM_TRANSITION_LIFECYCLE_CASE:-}" ]; then
  case "$FM_TRANSITION_LIFECYCLE_CASE" in
    missing-current-record|missing-before-drain)
      arm
      drain
      rm -f "${LAB:?}/state/.omp-watch-transition"
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = missing-before-drain ]; then
        "$DRAIN" >/dev/null 2>&1
        rm -f "${LAB:?}/state/.omp-watch-arm-result"
      fi
      arm
      expect_code 0 "$rc" 'missing state must preserve arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'missing current-session record must warn'
      ;;
    dead-lock-owner)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker fresh-before-abandoned-lock' _ "$LAB/bin/fm-wake-lib.sh"
      bash -c '. "$1"; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"; printf "owner=%s\n" "${BASHPID:-$$}"; cat "$FM_WAKE_QUEUE_LOCK/pid"' _ "$LAB/bin/fm-wake-lib.sh"
      first=0
      first_out=$("$DRAIN" 2>&1) || first=$?
      second=0
      second_out=$("$DRAIN" 2>&1) || second=$?
      printf 'first rc=%s output=%s\nsecond rc=%s output=%s\n' "$first" "$first_out" "$second" "$second_out"
      expect_code 0 "$first" 'a drain retry must recover a verified dead owner'
      expect_code 0 "$second" 'empty drain after owner recovery must complete'
      assert_contains "$first_out" fresh-before-abandoned-lock 'recovered drain prints the pending wake'
      assert_not_contains "$first_out$second_out" WARNING 'verified dead owner recovery must remain known'
      [ ! -s "$LAB/state/.wake-queue" ] || fail 'recovered drain retained the pending wake'
      assert_absent "$LAB/state/.wake-queue.lock" 'recovered queue lock must be released'
      arm
      expect_code 2 "$rc" 'recovered drain must retain fresh reset enforcement'
      assert_observed clean
      ;;
    fresh-empty|fresh-queued|replacement-empty|replacement-queued|replacement-replay)
      case "$FM_TRANSITION_LIFECYCLE_CASE" in replacement-*)
        arm
        bash -c '. "$1"; fm_wake_append heartbeat startup prior-session-wake' _ "$LAB/bin/fm-wake-lib.sh"
        cp "$LAB/state/.wake-queue" "$LAB/prior-session-replay"
        "$DRAIN" >/dev/null 2>&1
        grant_recovery
        PI_SESSION_ID=replacement-startup
        PI_TOOL_CALL_ID=startup-drain
        ;;
      esac
      case "$FM_TRANSITION_LIFECYCLE_CASE" in *queued)
        bash -c '. "$1"; fm_wake_append heartbeat startup startup-pending-wake' _ "$LAB/bin/fm-wake-lib.sh"
        ;;
      esac
      cat > "$LAB/bin/fm-pr-auto-register.sh" <<'SH'
#!/usr/bin/env bash
printf registered >> "$FM_HOME/registration"
SH
      : > "$LAB/startup-replay"
      [ ! -f "$LAB/state/.wake-queue" ] || cp "$LAB/state/.wake-queue" "$LAB/startup-replay"
      startup_rc=0
      startup_out=$("$DRAIN" 2>&1) || startup_rc=$?
      retained=''
      [ ! -f "$LAB/state/.wake-queue" ] || retained=$(cat "$LAB/state/.wake-queue")
      if [ "$startup_rc" -eq 0 ]; then
        repeat_out=$("$DRAIN" 2>&1) || fail 'repeated pre-arm drain failed'
        assert_not_contains "$repeat_out" WARNING 'repeated verified startup admission remains known'
        denied=0
        "$LAB/bin/fm-omp-watch-transition.sh" identity "$PI_SESSION_ID" >/dev/null 2>&1 || denied=$?
        expect_code 1 "$denied" 'pre-arm admission must not expose a recovery identity'
        startup_token=$(jq -c '{session,arm,generation,watermark,batch}' "$LAB/state/.omp-watch-transition")
        denied=0
        "$LAB/bin/fm-omp-watch-transition.sh" recovery "$PI_SESSION_ID" "$startup_token" >/dev/null 2>&1 || denied=$?
        expect_code 1 "$denied" 'pre-arm admission must not grant recovery'
      fi
      arm
      printf 'startup drain rc=%s output=%s\nretained=%s\nfirst arm rc=%s output=%s\n' "$startup_rc" "$startup_out" "$retained" "$rc" "$output"
      expect_code 0 "$startup_rc" 'startup drain before first arm must complete'
      [ -z "$retained" ] || fail 'startup retained already printed wake'
      assert_present "$LAB/registration" 'startup PR registration must run'
      expect_code 0 "$rc" 'first arm after startup admission must launch'
      assert_observed startup
      assert_not_contains "$output" WARNING 'verified first startup stays known'
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = replacement-replay ]; then
        cp "$LAB/prior-session-replay" "$LAB/startup-replay"
      fi
      cp "$LAB/startup-replay" "$LAB/state/.wake-queue"
      "$DRAIN" >/dev/null 2>&1
      bash -c '. "$1"; fm_wake_append stale worker after-startup-idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 0 "$rc" 'replayed startup rows must not become successor fresh evidence'
      assert_observed idle-recheck
      assert_not_contains "$output" WARNING 'startup replay retains verifiable idle evidence'
      drain
      arm
      expect_code 2 "$rc" 'fresh post-startup wake must require reset without old recovery'
      assert_observed clean
      assert_not_contains "$output" WARNING 'later clean enforcement remains verifiable'
      ;;
    startup-same-call)
      "$DRAIN" >/dev/null 2>&1
      output=$("$ARM" 2>&1) || fail 'first arm sharing the drain call must launch'
      assert_present "$LAB/launches" 'a drain call must not impersonate a consumed arm'
      [ "$(wc -l < "$LAB/launches" | tr -d ' ')" = 1 ] || fail 'first same-call arm did not launch exactly once'
      output=$("$ARM" 2>&1) || fail 'duplicate arm must be idempotent'
      [ "$(wc -l < "$LAB/launches" | tr -d ' ')" = 1 ] || fail 'duplicate same-call arm launched twice'
      ;;
    startup-cycle)
      "$DRAIN" >/dev/null 2>&1
      "$LAB/bin/fm-omp-watch-transition.sh" cycle failed 42 before-arm
      arm
      expect_code 0 "$rc" 'pre-arm callback must preserve first startup'
      assert_observed startup
      assert_not_contains "$output" WARNING 'callback without an admitted arm cannot corrupt startup'
      ;;
    startup-unknown)
      printf '1\t1\talien\tfixture\tunknown startup row\n' | queue_rows > "$LAB/state/.wake-queue"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 0 "$rc" 'unknown startup input preserves arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'pre-arm uncertainty must remain visible'
      ;;
    startup-failed-publication)
      bash -c '. "$1"; fm_wake_append heartbeat startup unadmitted-startup' _ "$LAB/bin/fm-wake-lib.sh"
      mkdir "$LAB/startup-bin"
      cat > "$LAB/startup-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ]; then exit 1; fi
exec /bin/mv "$@"
SH
      chmod +x "$LAB/startup-bin/mv"
      denied=0
      failed=$(PATH="$LAB/startup-bin:$PATH" "$DRAIN" 2>&1) || denied=$?
      expect_code 1 "$denied" 'failed pre-arm publication must retain raw input'
      assert_contains "$failed" WARNING 'failed startup admission must warn'
      assert_grep unadmitted-startup "$LAB/state/.wake-queue" 'failed startup publication cannot consume input'
      "$DRAIN" >/dev/null 2>&1
      [ ! -s "$LAB/state/.wake-queue" ] || fail 'retried startup did not consume raw input'
      arm
      assert_observed startup
      ;;
    startup-missing-identity)
      bash -c '. "$1"; fm_wake_append heartbeat startup unidentified-startup' _ "$LAB/bin/fm-wake-lib.sh"
      denied=0
      failed=$(PI_TOOL_CALL_ID='' "$DRAIN" 2>&1) || denied=$?
      expect_code 1 "$denied" 'identity-less startup drain cannot admit input'
      assert_contains "$failed" WARNING 'identity-less startup warns'
      assert_grep unidentified-startup "$LAB/state/.wake-queue" 'identity-less startup retains raw input'
      "$DRAIN" >/dev/null 2>&1
      arm
      assert_observed startup
      ;;
    startup-invalid-record|startup-contradiction|startup-contradiction-arm|missing-malformed-observation|missing-observation-symlink)
      arm
      drain
      case "$FM_TRANSITION_LIFECYCLE_CASE" in
        startup-invalid-record) printf 'invalid\n' > "$LAB/state/.omp-watch-transition" ;;
        startup-contradiction|startup-contradiction-arm)
          jq '.session="prior-session"' "$LAB/state/.omp-watch-transition" > "$LAB/foreign-record"
          mv "$LAB/foreign-record" "$LAB/state/.omp-watch-transition"
          ;;
        missing-malformed-observation)
          rm -f "${LAB:?}/state/.omp-watch-transition"
          printf 'previous-session\nold-call' > "$LAB/state/.omp-watch-arm-result"
          ;;
        missing-observation-symlink)
          rm -f "${LAB:?}/state/.omp-watch-transition"
          mv "$LAB/state/.omp-watch-arm-result" "$LAB/arm-observation"
          printf 'previous-session\nold-call\n' > "$LAB/arm-observation"
          ln -s "$LAB/arm-observation" "$LAB/state/.omp-watch-arm-result"
          ;;
      esac
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" != startup-contradiction-arm ]; then
        "$DRAIN" >/dev/null 2>&1
      fi
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = startup-contradiction ]; then
        rm -f "${LAB:?}/state/.omp-watch-arm-result"
      fi
      arm
      expect_code 0 "$rc" 'unavailable startup evidence must preserve arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'unavailable startup evidence cannot silently become first startup'
      ;;
    dead-lock-obstruction|unknown-lock-owner)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker pending-behind-obstruction' _ "$LAB/bin/fm-wake-lib.sh"
      bash -c '. "$1"; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"' _ "$LAB/bin/fm-wake-lib.sh"
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = dead-lock-obstruction ]; then
        printf 'unknown steal obstruction\n' > "$LAB/state/.wake-queue.lock.steal"
      else
        printf 'unverifiable\n' > "$LAB/state/.wake-queue.lock/pid"
        python3 - "$LAB/state/.wake-queue.lock" <<'PYAGE'
import os,sys
os.utime(os.path.realpath(sys.argv[1]),(1,1))
os.utime(sys.argv[1],(1,1),follow_symlinks=False)
PYAGE
      fi
      prior=$(readlink "$LAB/state/.wake-queue.lock")
      denied=0
      failed=$(FM_OMP_TRANSITION_LOCK_ATTEMPTS=1 "$DRAIN" 2>&1) || denied=$?
      expect_code 1 "$denied" 'unverified obstruction must refuse drain admission'
      assert_contains "$failed" WARNING 'unverified recovery obstruction must warn'
      [ "$(readlink "$LAB/state/.wake-queue.lock")" = "$prior" ] || fail 'unverified owner was replaced'
      assert_grep pending-behind-obstruction "$LAB/state/.wake-queue" 'blocked lock recovery retains raw input'
      ;;
    startup-invalid-decision|startup-invalid-recovery|startup-invalid-pid|startup-observation-changed)
      "$DRAIN" >/dev/null 2>&1
      case "$FM_TRANSITION_LIFECYCLE_CASE" in
        startup-invalid-decision) corrupt='.decision={call:.arm,claim:"",detail:"",observed:"startup",verdict:"allow"}' ;;
        startup-invalid-recovery) corrupt='.recovery={session,arm,generation,watermark,batch}' ;;
        startup-invalid-pid) corrupt='.pid="42"' ;;
        startup-observation-changed)
          printf '%s\n' "$PI_SESSION_ID" prior-arm 'watcher: pending confirmation' > "$LAB/state/.omp-watch-arm-result"
          corrupt='.'
          ;;
      esac
      jq "$corrupt" "$LAB/state/.omp-watch-transition" > "$LAB/corrupt-startup"
      mv "$LAB/corrupt-startup" "$LAB/state/.omp-watch-transition"
      arm
      expect_code 0 "$rc" 'incomplete startup evidence must preserve arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'incomplete pre-arm evidence cannot certify startup'
      ;;
    startup-legacy|startup-blank-session|startup-blank-call)
      case "$FM_TRANSITION_LIFECYCLE_CASE" in
        startup-legacy) printf 'legacy\n' > "$LAB/state/.omp-watch-cycle" ;;
        startup-blank-session) printf '\nold-call\n' > "$LAB/state/.omp-watch-arm-result" ;;
        startup-blank-call) printf 'prior-session\n\n' > "$LAB/state/.omp-watch-arm-result" ;;
      esac
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 0 "$rc" 'unavailable history must preserve arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'legacy or incomplete observational history cannot certify startup'
      ;;
    dead-lock-steal-pipe)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker pending-behind-steal' _ "$LAB/bin/fm-wake-lib.sh"
      bash -c '. "$1"; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"' _ "$LAB/bin/fm-wake-lib.sh"
      python3 - "$LAB" <<'PYSTEAL'
import os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]); shim=home/'steal-bin';shim.mkdir()
owner=home/'unknown-steal';owner.mkdir();target=owner/'pid';os.mkfifo(target)
obstruction=home/'state/.wake-queue.lock.steal';obstruction.symlink_to(owner)
os.mkfifo(home/'steal-progress')
(shim/'cat').write_text("""#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ -p "$1" ]; then printf 'read-pipe\n' > "$FM_HOME/steal-progress"; fi
exec /bin/cat "$@"
""");(shim/'cat').chmod(0o755)
with (home/'steal.out').open('w') as out,(home/'steal.err').open('w') as err:
    child=subprocess.Popen(['bash','-c','"$1"; rc=$?; printf "completed\\n" > "$FM_HOME/steal-progress"; exit "$rc"','_',str(home/'bin/fm-wake-drain.sh')],env=dict(os.environ,PATH=str(shim)+':'+os.environ['PATH'],FM_OMP_TRANSITION_LOCK_ATTEMPTS='1'),stdout=out,stderr=err)
    reads=0
    while True:
        with (home/'steal-progress').open() as progress: event=progress.readline()
        if event=='completed\n': break
        assert event=='read-pipe\n',event
        reads+=1
        with target.open('w') as release: release.write('unknown\n')
    rc=child.wait()
assert reads==0, f'bounded recovery read an unknown steal obstruction {reads} times'
assert rc==1,(rc,(home/'steal.err').read_text())
assert 'WARNING' in (home/'steal.err').read_text()
assert obstruction.is_symlink() and target.is_fifo()
assert 'pending-behind-steal' in (home/'state/.wake-queue').read_text()
PYSTEAL
      ;;
    startup-dangling-canonical)
      ln -s "$LAB/missing-canonical" "$LAB/state/.omp-watch-transition"
      arm
      expect_code 0 "$rc" 'a dangling canonical destination preserves arming'
      assert_contains "$output" 'transition evidence is unknown' 'a dangling record cannot certify startup'
      [ -L "$LAB/state/.omp-watch-transition" ] || fail 'dangling canonical obstruction was replaced'
      ;;
    startup-corrupt-first)
      printf 'invalid canonical evidence\n' > "$LAB/state/.omp-watch-transition"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 0 "$rc" 'corrupt pre-arm evidence preserves supervision'
      assert_observed unknown
      assert_contains "$output" WARNING 'corrupt pre-arm evidence cannot become startup'
      ;;
    *) fail 'unknown lifecycle scenario' ;;
  esac
  pass "$FM_TRANSITION_LIFECYCLE_CASE"
  exit
fi
if [ -n "${FM_TRANSITION_CASE:-}" ]; then
  arm
  drain
  case "$FM_TRANSITION_CASE" in
    recovery-log|recovery-away|recovery-hold|recovery-declaration|recovery-new-wake|recovery-replay)
      token=$("$LAB/bin/fm-omp-watch-transition.sh" identity "$PI_SESSION_ID")
      grant_recovery
      case "$FM_TRANSITION_CASE" in
        recovery-log)
          mkdir "$LAB/log-bin"
          cat > "$LAB/log-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transitions.log" ]; then
  echo injected >> "$FM_HOME/log-failed"
  exit 1
fi
exec /bin/mv "$@"
SH
          chmod +x "$LAB/log-bin/mv"
          PATH="$LAB/log-bin:$PATH" arm
          assert_contains "$output" WARNING 'logging failure must warn'
          assert_grep injected "$LAB/log-failed" 'logging injection reached'
          ;;
        recovery-away|recovery-hold)
          flag=.afk
          [ "$FM_TRANSITION_CASE" != recovery-hold ] || flag=.captain-hold
          touch "$LAB/state/$flag"
          arm
          rm -f "${LAB:?}/state/$flag"
          ;;
        recovery-declaration) arm --transition work-pending --reason 'unfinished work' ;;
        recovery-new-wake)
          drain
          arm
          expect_code 2 "$rc" 'recovery cannot exempt a newer wake'
          pass 'recovery-new-wake'
          exit ;;
        recovery-replay)
          arm
          drain
          "$LAB/bin/fm-omp-watch-transition.sh" recovery "$PI_SESSION_ID" "$token"
          arm
          expect_code 2 "$rc" 'a retired callback cannot grant recovery over a successor fresh wake'
          assert_observed clean
          assert_not_contains "$output" WARNING 'retired recovery cannot alter current evidence'
          pass 'recovery-replay'
          exit ;;
      esac
      expect_code 0 "$rc" 'replacement arm must preserve supervision'
      drain
      arm
      expect_code 2 "$rc" 'recovery cannot survive a permitted replacement arm'
      assert_observed clean
      assert_not_contains "$output" WARNING 'completed recovery leaves verified clean evidence'
      ;;
    missing-drain-identity)
      arm --transition work-pending --reason 'begin idle receipt'
      bash -c '. "$1"; fm_wake_append stale worker prior-idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      bash -c '. "$1"; fm_wake_append stale worker fresh-without-identity' _ "$LAB/bin/fm-wake-lib.sh"
      bad=0
      missing=$(PI_TOOL_CALL_ID='' "$DRAIN" 2>&1) || bad=$?
      expect_code 1 "$bad" 'unidentified drain must not acknowledge admission'
      assert_contains "$missing" WARNING 'missing drain identity warns'
      assert_grep fresh-without-identity "$LAB/state/.wake-queue" 'unidentified drain retains raw fresh input'
      arm
      expect_code 0 "$rc" 'missing identity preserves arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'missing drain identity cannot leave a silently trusted idle record'
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 2 "$rc" 'retained fresh input still requires reset after an admitted retry'
      ;;
    unavailable-lock)
      printf 'unknown obstruction\n' > "$LAB/state/.wake-queue.lock"
      before=$(cat "$LAB/state/.omp-watch-transition")
      FM_OMP_TRANSITION_LOCK_ATTEMPTS=1 arm
      expect_code 0 "$rc" 'unavailable lock must warn and allow'
      assert_contains "$output" WARNING 'unavailable lock is visible'
      [ "$(cat "$LAB/state/.wake-queue.lock")" = 'unknown obstruction' ] || fail 'unknown obstruction was changed'
      [ "$(cat "$LAB/state/.omp-watch-transition")" = "$before" ] || fail 'canonical state changed without its lock'
      rm -f "${LAB:?}/state/.wake-queue.lock"
      arm
      expect_code 0 "$rc" 'stale record after unavailable lock must not force reset'
      assert_observed unknown
      assert_contains "$output" WARNING 'later arm cannot trust stale state after unlocked launch'
      ;;
    held-lock-budget)
      arm --transition work-pending --reason 'begin held lock budget'
      bash -c '. "$1"; fm_wake_append stale worker held-idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      python3 - "$LAB" <<'PYBUDGET'
import json,os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]);shim=home/'budget-bin';shim.mkdir()
for n in ('budget-ready','budget-release','budget-progress'):os.mkfifo(home/n)
(shim/'awk').write_text(r'''#!/usr/bin/env bash
if [ "${HOLD_BUDGET_DRAIN:-}" = 1 ] && [ "$#" -eq 5 ] && [ "$1" = -F ] && mkdir "$FM_HOME/budget-held" 2>/dev/null; then
  printf 'held\n' > "$FM_HOME/budget-ready"
  read -r _ < "$FM_HOME/budget-release"
fi
exec /usr/bin/awk "$@"
''')
(shim/'cat').write_text(r'''#!/usr/bin/env bash
if [ "${BUDGET_PROBE:-}" = 1 ] && [ "$#" -eq 1 ] && [ "$1" = "$FM_HOME/state/.wake-queue.lock/pid" ]; then
  owner=$(ps -p "$PPID" -o ppid= | tr -d '[:space:]')
  n=0
  [ ! -f "$FM_HOME/budget-count.$owner" ] || n=$(/bin/cat "$FM_HOME/budget-count.$owner")
  n=$((n + 1))
  printf '%s\n' "$n" > "$FM_HOME/budget-count.$owner"
  if [ "$n" -eq 2 ]; then printf 'over-budget\n' > "$FM_HOME/budget-progress"; fi
fi
exec /bin/cat "$@"
''')
(shim/'sleep').write_text('#!/usr/bin/env bash\n[ "$1" != 0.05 ] || exit 0\nexec /bin/sleep "$@"\n')
for f in shim.iterdir():f.chmod(0o755)
env=dict(os.environ,PATH=str(shim)+':'+os.environ['PATH'])
with (home/'holder.out').open('w') as out,(home/'holder.err').open('w') as err:
    holder=subprocess.Popen([str(home/'bin/fm-wake-drain.sh')],env=dict(env,HOLD_BUDGET_DRAIN='1'),stdout=out,stderr=err)
    with (home/'budget-ready').open() as ready:assert ready.readline()=='held\n'
    with (home/'budget.out').open('w') as ao,(home/'budget.err').open('w') as ae, os.fdopen(os.open(home/'budget-progress',os.O_RDWR)) as progress:
        arm=subprocess.Popen(['bash','-c','"$1"; rc=$?; printf "completed\\n" > "$FM_HOME/budget-progress"; exit "$rc"','_',str(home/'bin/fm-watch-arm.sh')],env=dict(env,BUDGET_PROBE='1',PI_TOOL_CALL_ID='held-budget-arm',FM_OMP_TRANSITION_LOCK_ATTEMPTS='1'),stdout=ao,stderr=ae)
        event=progress.readline()
        with (home/'budget-release').open('w') as release:release.write('continue\n')
        if event!='completed\n':
            while progress.readline()!='completed\n':
                pass
        rc=arm.wait()
    holder_rc=holder.wait()
counts={f.name:int(f.read_text()) for f in home.glob('budget-count.*')}
assert event=='completed\n', 'a held lock exceeded the injected attempt budget before allowing arming'
assert rc==0,(rc,(home/'budget.err').read_text())
assert counts and all(n==1 for n in counts.values()),counts
assert 'WARNING' in (home/'budget.err').read_text()
assert holder_rc==0,(holder_rc,(home/'holder.err').read_text())
print('held-lock budget counts='+json.dumps(counts),flush=True)
PYBUDGET
      arm
      expect_code 0 "$rc" 'a replacement after budget exhaustion must remain unknown'
      assert_observed unknown
      assert_contains "$output" WARNING 'a later arm cannot trust the unrecorded replacement'
      ;;
    lock-vacate)
      arm --transition work-pending --reason 'begin controlled lock vacation'
      overlap_transactions
      ;;
    batch-identity-unavailable)
      bash -c '. "$1"; fm_wake_append stale worker unadmitted-fresh' _ "$LAB/bin/fm-wake-lib.sh"
      mkdir "$LAB/hash-bin"
      cat > "$LAB/hash-bin/perl" <<'SH'
#!/usr/bin/env bash
echo unavailable >> "$FM_HOME/hash-failed"
exit 1
SH
      chmod +x "$LAB/hash-bin/perl"
      bad=0
      failed=$(PATH="$LAB/hash-bin:$PATH" "$DRAIN" 2>&1) || bad=$?
      expect_code 1 "$bad" 'unavailable batch identity cannot acknowledge fresh admission'
      assert_contains "$failed" WARNING 'unavailable batch identity warns'
      assert_grep unavailable "$LAB/hash-failed" 'batch identity implementation was reached'
      assert_grep unadmitted-fresh "$LAB/state/.wake-queue" 'batch identity failure retains raw input'
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 2 "$rc" 'successful batch identity retry must retain fresh eligibility'
      ;;
    sequence-reuse|recovery-reused-sequence)
      arm --transition work-pending --reason 'begin sequence identity case'
      bash -c '. "$1"; fm_wake_append stale worker old-idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      token=$("$LAB/bin/fm-omp-watch-transition.sh" identity "$PI_SESSION_ID")
      sequence=$(cat "$LAB/state/.wake-queue.seq")
      printf '%s\n' "$((sequence - 1))" > "$LAB/state/.wake-queue.seq"
      bash -c '. "$1"; fm_wake_append stale worker fresh-reused-sequence' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      if [ "$FM_TRANSITION_CASE" = recovery-reused-sequence ]; then
        late=$("$LAB/bin/fm-omp-watch-transition.sh" recovery "$PI_SESSION_ID" "$token" 2>&1)
        assert_contains "$late" WARNING 'a recovery callback must bind the admitted batch as well as its sequence'
      fi
      arm
      expect_code 0 "$rc" 'reused transport identity must preserve supervision'
      assert_observed unknown
      assert_contains "$output" WARNING 'a reused sequence cannot silently certify the old idle exemption'
      ;;
    recovery-unknown)
      printf '1\t1\talien\tfixture\tunknown kind\n' | queue_rows > "$LAB/state/.wake-queue"
      "$DRAIN" >/dev/null 2>&1
      grant_recovery
      arm
      expect_code 0 "$rc" 'recovery must preserve unknown-state arming'
      assert_observed unknown
      assert_contains "$output" WARNING 'recovery cannot conceal unknown admitted evidence'
      ;;
    canonical-arm-failure)
      grant_recovery
      mkdir "$LAB/canonical-bin"
      cat > "$LAB/canonical-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ]; then
  echo injected >> "$FM_HOME/canonical-failed"
  exit 1
fi
exec /bin/mv "$@"
SH
      chmod +x "$LAB/canonical-bin/mv"
      PATH="$LAB/canonical-bin:$PATH" arm
      expect_code 0 "$rc" 'canonical persistence failure must preserve arming'
      assert_contains "$output" WARNING 'canonical failure warns without claiming consumption'
      assert_grep injected "$LAB/canonical-failed" 'canonical publication really failed'
      arm
      expect_code 0 "$rc" 'a failed canonical successor cannot certify old recovery'
      assert_observed unknown
      assert_contains "$output" WARNING 'old recovery cannot be silently reused after failed publication'
      drain
      arm
      expect_code 2 "$rc" 'old recovery cannot survive the subsequent known successor'
      ;;
    replay-across-arm|publication-before-consumption)
      arm --transition work-pending --reason 'begin replay transaction'
      bash -c '. "$1"; fm_wake_append stale worker original-fresh' _ "$LAB/bin/fm-wake-lib.sh"
      cp "$LAB/state/.wake-queue" "$LAB/replay"
      if [ "$FM_TRANSITION_CASE" = publication-before-consumption ]; then
        mkdir "$LAB/crash-bin"
        cat > "$LAB/crash-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ] && jq -e '.uncertain == false' "$2" >/dev/null; then
  /bin/mv "$@"
  echo committed >> "$FM_HOME/commit-interval"
  exit 1
fi
exec /bin/mv "$@"
SH
        chmod +x "$LAB/crash-bin/mv"
        bad=0
        PATH="$LAB/crash-bin:$PATH" "$DRAIN" >/dev/null 2>&1 || bad=$?
        expect_code 1 "$bad" 'publication-before-consumption fault must retain raw input'
        assert_grep committed "$LAB/commit-interval" 'fault occurred after actual canonical publication'
        assert_grep original-fresh "$LAB/state/.wake-queue" 'raw input survives the commit interval'
      else
        "$DRAIN" >/dev/null 2>&1
      fi
      arm --transition work-pending --reason 'permitted replacement before raw replay'
      cp "$LAB/replay" "$LAB/state/.wake-queue"
      "$DRAIN" >/dev/null 2>&1
      bash -c '. "$1"; fm_wake_append stale worker successor-idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 0 "$rc" 'admitted raw replay cannot certify a successor'
      assert_observed idle-recheck
      assert_not_contains "$output" WARNING 'verified successor idle evidence remains known after replay'
      ;;
    invalid-record-class|invalid-record-decision|invalid-record-recovery|invalid-record-pid|invalid-record-identity|invalid-record-verdict|invalid-record-batch)
      case "$FM_TRANSITION_CASE" in
        invalid-record-class) corrupt='.classes=["unsupported"]' ;;
        invalid-record-decision) corrupt='.decision=null' ;;
        invalid-record-recovery) corrupt='.recovery={}' ;;
        invalid-record-pid) corrupt='.pid="unavailable"' ;;
        invalid-record-identity) corrupt='.decision.call="retired-arm"' ;;
        invalid-record-verdict) corrupt='.decision.verdict="refuse"' ;;
        invalid-record-batch) corrupt='.batch="unavailable"' ;;
      esac
      jq "$corrupt" "$LAB/state/.omp-watch-transition" > "$LAB/invalid-record"
      mv "$LAB/invalid-record" "$LAB/state/.omp-watch-transition"
      arm
      expect_code 0 "$rc" 'malformed canonical evidence cannot force reset'
      assert_observed unknown
      assert_contains "$output" WARNING 'malformed canonical class must warn'
      ;;
    slow-evidence|slow-transport)
      python3 - "$LAB" <<'PYSLOW'
import json,os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1])
status=home/'state/worker.status'
status.write_text('resolved [key=x]: item\n')
os.utime(status,ns=(1000000000000000000,1000000000000000000))
for n in ('snapshot-ready','snapshot-release'): os.mkfifo(home/n)
p=home/'bin/fm-fleet-snapshot.sh'
p.write_text('''#!/usr/bin/env bash
result=$("$FM_TRANSITION_SOURCE/bin/fm-fleet-snapshot.sh" "$@") || exit $?
if [ "${PAUSE_SNAPSHOT:-}" = 1 ]; then
  printf 'ready\\n' > "$FM_HOME/snapshot-ready"
  read -r _ < "$FM_HOME/snapshot-release"
fi
printf '%s\\n' "$result"
''')
with (home/'slow.out').open('w') as out,(home/'slow.err').open('w') as err:
    arm=subprocess.Popen([str(home/'bin/fm-watch-arm.sh')],env=dict(os.environ,PAUSE_SNAPSHOT='1',PI_TOOL_CALL_ID='slow-arm'),stdout=out,stderr=err)
    with (home/'snapshot-ready').open() as ready: assert ready.readline()=='ready\n'
    append=subprocess.run(['bash','-c','. "$1"; fm_wake_append heartbeat fixture during-snapshot','_',str(home/'bin/fm-wake-lib.sh')],capture_output=True,text=True)
    assert append.returncode==0,append.stderr
    drained=subprocess.run([str(home/'bin/fm-wake-drain.sh')],capture_output=True,text=True)
    assert drained.returncode==0,drained.stderr
    assert 'during-snapshot' in drained.stdout,drained.stdout
    if os.environ['FM_TRANSITION_CASE']=='slow-evidence':
        status.write_text('blocked  [key=x]: item\n')
        os.utime(status,ns=(1000000000000000000,1000000000001000000))
    with (home/'snapshot-release').open('w') as release: release.write('continue\n')
    rc=arm.wait()
verdict=json.loads((home/'state/.omp-watch-transitions.log').read_text().splitlines()[-1])
if os.environ['FM_TRANSITION_CASE']=='slow-evidence':
    assert rc==0, (rc,(home/'slow.err').read_text())
    assert verdict['observed']=='unknown',verdict
    assert 'WARNING' in (home/'slow.err').read_text()
else:
    assert rc==2, (rc,(home/'slow.err').read_text())
    assert verdict['observed']=='clean',verdict
    assert 'WARNING' not in (home/'slow.err').read_text()
PYSLOW
      ;;
    fold-provenance)
      arm --transition work-pending --reason 'begin provenance sequence'
      bash -c '. "$1"; fm_wake_append stale worker idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 0 "$rc" 'producer-tagged idle must preserve arming'
      assert_observed idle-recheck
      assert_not_contains "$output" WARNING 'verified idle cannot be unknown'
      bash -c '. "$1"; fm_wake_append stale worker fresh' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 2 "$rc" 'fresh producer input must require reset'
      assert_observed clean
      bash -c '. "$1"; fm_wake_append stale worker later-idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
      "$DRAIN" >/dev/null 2>&1
      arm
      expect_code 2 "$rc" 'later idle cannot erase fresh provenance'
      assert_observed clean
      ;;
    drain-publication-failure)
      mkdir "$LAB/drain-failure-bin"
      cat > "$LAB/drain-failure-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ]; then
  case "$FAIL_STAGE" in
    checkpoint) jq -e '.uncertain == true' "$2" >/dev/null && exit 1 ;;
    final) jq -e '.uncertain == false' "$2" >/dev/null && exit 1 ;;
  esac
fi
exec /bin/mv "$@"
SH
      chmod +x "$LAB/drain-failure-bin/mv"
      for stage in checkpoint final; do
        arm --transition work-pending --reason "begin $stage publication failure"
        bash -c '. "$1"; fm_wake_append stale worker idle idle-recheck' _ "$LAB/bin/fm-wake-lib.sh"
        "$DRAIN" >/dev/null 2>&1
        bash -c '. "$1"; fm_wake_append stale worker new-fresh' _ "$LAB/bin/fm-wake-lib.sh"
        bad=0
        failed=$(PATH="$LAB/drain-failure-bin:$PATH" FAIL_STAGE="$stage" "$DRAIN" 2>&1) || bad=$?
        expect_code 1 "$bad" 'either failed admission stage retains raw input'
        assert_contains "$failed" WARNING 'failed admission stage must warn'
        assert_grep new-fresh "$LAB/state/.wake-queue" 'unadmitted fresh wake must remain queued'
        arm
        expect_code 0 "$rc" 'publication failure must never force reset'
        if [ "$stage" = final ]; then
          assert_observed unknown
          assert_contains "$output" WARNING 'failed final publication leaves visible canonical uncertainty'
        else
          assert_observed queued-wakes
        fi
        "$DRAIN" >/dev/null 2>&1
      done
      ;;
    legacy-fragments)
      printf '%s\n' "$PI_SESSION_ID" "$PI_TOOL_CALL_ID" wake 42 legacy > "$LAB/state/.omp-watch-cycle"
      printf '%s\n' "$PI_SESSION_ID" "$PI_TOOL_CALL_ID" idle-recheck > "$LAB/state/.omp-watch-drain"
      printf '%s\n' "$PI_SESSION_ID" > "$LAB/state/.omp-watch-recovery"
      rm -f "${LAB:?}/state/.omp-watch-transition"
      arm
      expect_code 0 "$rc" 'legacy split fragments preserve supervision'
      assert_observed unknown
      assert_contains "$output" WARNING 'legacy fragments cannot combine into an exemption'
      [ -f "$LAB/state/.omp-watch-cycle" ] && [ -f "$LAB/state/.omp-watch-drain" ] && [ -f "$LAB/state/.omp-watch-recovery" ] || fail 'migration deleted existing state'
      drain
      arm
      expect_code 2 "$rc" 'complete new evidence cannot reuse legacy recovery'
      ;;
    log-obstruction)
      grant_recovery
      mv "$LAB/state/.omp-watch-transitions.log" "$LAB/prior-log"
      mkdir "$LAB/state/.omp-watch-transitions.log"
      arm
      expect_code 0 "$rc" 'unavailable diagnostic destination preserves arming'
      assert_contains "$output" WARNING 'unknown diagnostic obstruction must warn'
      [ -d "$LAB/state/.omp-watch-transitions.log" ] || fail 'unknown diagnostic obstruction was removed'
      rmdir "${LAB:?}/state/.omp-watch-transitions.log"
      drain
      arm
      expect_code 2 "$rc" 'diagnostic destination failure cannot preserve recovery'
      assert_observed clean
      ;;
    canonical-symlink)
      mv "$LAB/state/.omp-watch-transition" "$LAB/canonical-target"
      ln -s "$LAB/canonical-target" "$LAB/state/.omp-watch-transition"
      arm
      expect_code 0 "$rc" 'an unknown canonical obstruction cannot force reset'
      assert_contains "$output" WARNING 'canonical symlink must remain visibly unknown'
      [ -L "$LAB/state/.omp-watch-transition" ] || fail 'canonical writer replaced an unknown symlink'
      ;;
    unavailable-pipe|canonical-pipe)
      python3 - "$LAB" <<'PYPIPE'
import os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]); shim=home/'pipe-bin';shim.mkdir()
canonical=os.environ['FM_TRANSITION_CASE']=='canonical-pipe'
if canonical:
    obstruction=home/'state/.omp-watch-transition';obstruction.unlink();os.mkfifo(obstruction)
    target=obstruction
else:
    owner=home/'unknown-lock';owner.mkdir();target=owner/'pid';os.mkfifo(target)
    obstruction=home/'state/.wake-queue.lock';obstruction.symlink_to(owner)
os.mkfifo(home/'pipe-progress')
(shim/'cat').write_text('''#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ -p "$1" ]; then
  printf 'read-pipe\\n' > "$FM_HOME/pipe-progress"
fi
exec /bin/cat "$@"
''');(shim/'cat').chmod(0o755)
with (home/'pipe.out').open('w') as out,(home/'pipe.err').open('w') as err:
    arm=subprocess.Popen(['bash','-c','"$1"; rc=$?; printf "completed\\n" > "$FM_HOME/pipe-progress"; exit "$rc"','_',str(home/'bin/fm-watch-arm.sh')],env=dict(os.environ,PATH=str(shim)+':'+os.environ['PATH'],PI_TOOL_CALL_ID='pipe-arm',FM_OMP_TRANSITION_LOCK_ATTEMPTS='1'),stdout=out,stderr=err)
    reads=0
    while True:
        with (home/'pipe-progress').open() as progress: event=progress.readline()
        if event=='completed\n': break
        assert event=='read-pipe\n',event
        reads+=1
        with target.open('w') as release: release.write('unknown\n')
    rc=arm.wait()
assert reads==0, f'unknown obstruction was read as a stream {reads} times before arming'
assert rc==0,(rc,(home/'pipe.err').read_text())
assert 'WARNING' in (home/'pipe.err').read_text()
assert obstruction.is_fifo() if canonical else obstruction.is_symlink()
PYPIPE
      ;;
    fingerprint-unavailable)
      mkdir "$LAB/fingerprint-bin"
      printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/fingerprint-bin/perl"
      chmod +x "$LAB/fingerprint-bin/perl"
      PATH="$LAB/fingerprint-bin:$PATH" arm
      expect_code 0 "$rc" 'unavailable freshness proof cannot force reset'
      assert_observed unknown
      assert_contains "$output" WARNING 'unavailable fingerprint must warn'
      ;;
    duplicate-arm)
      grant_recovery
      before_launches=$(wc -l < "$LAB/launches" | tr -d ' ')
      PI_TOOL_CALL_ID=duplicate "$ARM" >/dev/null 2>&1
      PI_TOOL_CALL_ID=duplicate "$ARM" >/dev/null 2>&1
      after_launches=$(wc -l < "$LAB/launches" | tr -d ' ')
      [ "$after_launches" -eq "$((before_launches + 1))" ] || fail 'duplicate native arm launched twice'
      PI_TOOL_CALL_ID=retired "$LAB/bin/fm-omp-watch-transition.sh" cycle failed 42 retired
      drain
      arm
      expect_code 2 "$rc" 'duplicate command cannot consume twice or let a retired callback certify the successor'
      ;;
    *) fail 'unknown transition scenario' ;;
  esac
  pass "$FM_TRANSITION_CASE"
  exit
fi
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
printf '1\t2\tcheck\tlater\tcheck: waiting\n' | queue_rows > "$LAB/state/.wake-queue"
arm
expect_code 0 "$rc" 'undrained wakes must arm without resetting'
drain
printf 'not a cycle\n' > "$LAB/state/.omp-watch-transition"
arm
expect_code 0 "$rc" 'unreadable cycle must preserve supervision'
assert_contains "$output" WARNING 'unreadable cycle must warn'
printf 'not a cycle\n' > "$LAB/state/.omp-watch-transition"
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

printf '1\t2\talien\tfixture\tunsupported wake\n' | queue_rows > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 0 "$rc" 'an unknown wake kind must not require reset'
assert_contains "$output" WARNING 'an unknown wake kind must warn'
drain

stale_row() {
  local sequence
  sequence=$(cat "$LAB/state/.wake-queue.seq" 2>/dev/null || echo 0)
  sequence=$((sequence + 1))
  printf '%s\n' "$sequence" > "$LAB/state/.wake-queue.seq"
  printf '1\t%s\tstale\tworker\t%s' "$sequence" "$1"
  [ -z "${2:-}" ] || printf '\t%s' "$2"
  printf '\n'
}
arm --transition work-pending --reason 'begin unsupported event-kind case'
printf '1\t3\tidle-recheck\tworker\tunsupported kind named like an internal class\n' | queue_rows > "$LAB/state/.wake-queue"
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
overlap_transactions
pass 'overlapping real drains cannot replace fresh evidence with an older idle receipt'

arm --transition work-pending --reason 'begin failed receipt publication case'
stale_row 'previous idle recheck' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
mkdir "$LAB/failure-bin"
cat > "$LAB/failure-bin/mv" <<'SH'
#!/usr/bin/env bash
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ] && { [ "${FAIL_RECEIPT_STAGE:-}" = all ] || jq -e ' .uncertain == false ' "$2" >/dev/null; }; then
  printf 'failed receipt publication\n' >> "$FM_HOME/publication-failures"
  exit 1
fi
exec /bin/mv "$@"
SH
chmod +x "$LAB/failure-bin/mv"
stale_row 'newly consumed fresh event' > "$LAB/state/.wake-queue"
failure_rc=0
failure_output=$(PATH="$LAB/failure-bin:$PATH" "$DRAIN" 2>&1) || failure_rc=$?
expect_code 1 "$failure_rc" 'failed canonical admission must retain raw wakes'
assert_grep 'failed receipt publication' "$LAB/publication-failures" 'the receipt write must actually fail'
assert_contains "$failure_output" 'newly consumed fresh event' 'fresh row must be printed despite failed receipt publication'
assert_contains "$failure_output" WARNING 'drain must report failed receipt publication'
assert_grep 'newly consumed fresh event' "$LAB/state/.wake-queue" 'failed admission retains printed raw input'
arm
assert_observed unknown
assert_contains "$output" WARNING 'failed publication must be unknown before another drain'
"$DRAIN" >/dev/null 2>&1
stale_row 'later idle cannot repair lost fresh evidence' idle-recheck > "$LAB/state/.wake-queue"
"$DRAIN" >/dev/null 2>&1
arm
expect_code 2 "$rc" 'admitted retry of retained fresh evidence must require reset'
assert_observed clean
assert_not_contains "$output" WARNING 'retained fresh evidence was verified'
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
jq '.phase="running" | .pid="999999"' "$LAB/state/.omp-watch-transition" > "$LAB/state/fixture-record"
mv "$LAB/state/fixture-record" "$LAB/state/.omp-watch-transition"
arm
expect_code 0 "$rc" 'missing watcher must repair without reset'
jq -es '.[-1].observed == "repair"' "$LAB/state/.omp-watch-transitions.log" >/dev/null || fail 'missing watcher was not recognized as repair'
drain
grant_recovery
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

if [ -z "${FM_TRANSITION_CASE:-}" ]; then
  for scenario in recovery-log recovery-away recovery-hold recovery-declaration recovery-new-wake recovery-replay missing-drain-identity unavailable-lock fingerprint-unavailable duplicate-arm canonical-arm-failure sequence-reuse recovery-reused-sequence recovery-unknown batch-identity-unavailable replay-across-arm publication-before-consumption invalid-record-class invalid-record-decision invalid-record-recovery invalid-record-pid invalid-record-identity invalid-record-verdict invalid-record-batch slow-evidence slow-transport fold-provenance drain-publication-failure lock-vacate held-lock-budget legacy-fragments canonical-symlink unavailable-pipe canonical-pipe log-obstruction; do
    FM_TRANSITION_CASE="$scenario" bash "$0"
  done
fi

if [ -z "${FM_TRANSITION_CASE:-}" ] && [ -z "${FM_TRANSITION_LIFECYCLE_CASE:-}" ]; then
  for scenario in missing-current-record missing-before-drain fresh-empty fresh-queued replacement-empty replacement-queued dead-lock-owner startup-same-call startup-cycle startup-unknown startup-failed-publication startup-missing-identity startup-invalid-record startup-contradiction missing-malformed-observation missing-observation-symlink dead-lock-obstruction unknown-lock-owner replacement-replay startup-invalid-decision startup-invalid-recovery startup-invalid-pid startup-observation-changed startup-legacy startup-blank-session startup-blank-call dead-lock-steal-pipe startup-dangling-canonical startup-contradiction-arm startup-corrupt-first; do
    FM_TRANSITION_LIFECYCLE_CASE="$scenario" bash "$0"
  done
fi
