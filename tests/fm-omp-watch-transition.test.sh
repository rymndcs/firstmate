#!/usr/bin/env bash
# Exercise omp transition enforcement through the real arm and drain entrypoints.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-omp-watch-transition)
FM_TEST_CLEANUP_DIRS+=("$LAB")
trap fm_test_cleanup EXIT
mkdir -p "$LAB/bin" "$LAB/state" "$LAB/data" "$LAB/config"
for file in fm-watch-arm.sh fm-wake-drain.sh fm-wake-lib.sh fm-state-path.pl fm-classify-lib.sh; do
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
(shim / 'perl').write_text("""#!/usr/bin/env bash
if [ "${OVERLAP_CONTENDER:-}" = 1 ]; then
  case "${4:-}:${5:-}" in lock-pid:*'.wake-queue.lock')
    if mkdir "$FM_HOME/contender-seen" 2>/dev/null; then
      printf 'attempt\\n' > "$FM_HOME/contender"
      read -r _ < "$FM_HOME/contender-resume"
    fi
    ;;
  esac
fi
exec /usr/bin/perl "$@"
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
    steal-recheck-unstamped)
      arm
      drain
      python3 - "$LAB" <<'PYRECHECK'
import json,os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]);lib=str(home/'bin/fm-wake-lib.sh');lock=home/'state/.wake-queue.lock';queue=home/'state/.wake-queue'
env=dict(os.environ)
def call(command,extra=None):
    p=subprocess.run(command,env=dict(env,**(extra or {})),capture_output=True,text=True)
    print(json.dumps(dict(command=command,rc=p.returncode,stdout=p.stdout,stderr=p.stderr)),flush=True)
    return p
assert call(['bash','-c','. "$1"; fm_wake_append stale recheck retained-recheck-input; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"','_',lib]).returncode==0
before=queue.read_bytes();shim=home/'recheck-bin';shim.mkdir()
for name in ('recheck-ready','recheck-resume'):os.mkfifo(home/name)
(shim/'mktemp').write_text('''#!/usr/bin/env bash
if [ "${1:-}" = -d ] && [ "${2:-}" = "$FM_STATE_OVERRIDE/.wake-queue.lock.steal.owner.XXXXXX" ] && mkdir "$FM_HOME/recheck-paused" 2>/dev/null; then
  printf 'ready\\n' > "$FM_HOME/recheck-ready"
  read -r _ < "$FM_HOME/recheck-resume"
fi
exec /usr/bin/mktemp "$@"
''');(shim/'mktemp').chmod(0o755)
with (home/'recheck.out').open('w') as out,(home/'recheck.err').open('w') as err:
    child=subprocess.Popen([str(home/'bin/fm-wake-drain.sh')],env=dict(env,OMPCODE='0',PATH=str(shim)+':'+env['PATH'],FM_OMP_TRANSITION_LOCK_ATTEMPTS='3'),stdout=out,stderr=err)
    with (home/'recheck-ready').open() as f:assert f.readline()=='ready\n'
    try:
        replacement=call(['bash','-c','. "$1"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1; printf "%s\\n" "${BASHPID:-$$}"','_',lib],dict(OMPCODE='0'))
        assert replacement.returncode==0,'concurrent genuine holder must reclaim and naturally exit'
        pid=int(replacement.stdout.strip());owner=lock.readlink();expected={p.name:p.read_bytes() for p in lock.iterdir()}
        assert not (lock/'lock-identity').exists(),'replacement fixture must be genuinely unstamped'
        assert int((lock/'pid').read_text())==pid
        try:os.kill(pid,0)
        except ProcessLookupError:pass
        else:raise AssertionError('replacement holder must exit naturally')
    finally:
        with (home/'recheck-resume').open('w') as f:f.write('continue\n')
        rc=child.wait()
stdout=(home/'recheck.out').read_text();stderr=(home/'recheck.err').read_text()
print(json.dumps(dict(rc=rc,stdout=stdout,stderr=stderr,expected_owner=str(owner))),flush=True)
assert lock.is_symlink() and lock.readlink()==owner,'recovery recheck removed a newly unstamped dead owner'
assert {p.name:p.read_bytes() for p in lock.iterdir()}==expected,'recovery recheck changed an unstamped owner'
assert rc==1 and not stdout,'recovery recheck must refuse unlocked delivery'
assert queue.read_bytes()==before,'recovery recheck consumed retained input'
assert 'WARNING' in stderr,'recovery recheck refusal must be visible'
assert not Path(str(lock)+'.steal').is_symlink(),'refused recovery must release its owned secondary'
lock.rename(home/'recheck-retired-fixture')
result=call([str(home/'bin/fm-wake-drain.sh')]);assert result.returncode==0 and 'retained-recheck-input' in result.stdout,'retiring the own fixture obstruction must permit delivery'
PYRECHECK
      ;;
    steal-absent-drain|steal-absent-append|steal-dead-drain|steal-dead-append|steal-primary|steal-unknown|steal-unstamped|steal-live|steal-budget|steal-cross-drain|steal-cross-append|steal-replacement-budget|steal-unknown-pipe)
      arm
      drain
      python3 - "$LAB" <<'PYROUND7'
import json,os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]);case=os.environ['FM_TRANSITION_LIFECYCLE_CASE']
env=dict(os.environ);lib=str(home/'bin/fm-wake-lib.sh');lock=home/'state/.wake-queue.lock';steal=Path(str(lock)+'.steal')
queue=home/'state/.wake-queue';drain=str(home/'bin/fm-wake-drain.sh');arm=str(home/'bin/fm-watch-arm.sh')
def call(cmd,extra=None):
    result=subprocess.run(cmd,env=dict(env,**(extra or {})),capture_output=True,text=True)
    print(json.dumps(dict(command=cmd,rc=result.returncode,stdout=result.stdout,stderr=result.stderr)),flush=True)
    return result
def holder(path,extra=None):
    result=call(['bash','-c','. "$1"; fm_lock_try_create "$2" || exit 1; printf "%s\\n" "${BASHPID:-$$}"','_',lib,str(path)],extra)
    assert result.returncode==0,'real holder must acquire before naturally exiting'
    pid=int(result.stdout.strip());assert int((path/'pid').read_text())==pid
    try:os.kill(pid,0)
    except ProcessLookupError:pass
    else:raise AssertionError('fixture holder must have naturally exited')
    return path.readlink()
def snapshot(path):
    return (str(path.readlink()),{p.name:(p.lstat().st_mode,p.read_bytes() if p.is_file() else None) for p in path.iterdir()})
append=['bash','-ec','. "$1"; if fm_wake_append stale "$2" "$2"; then exit 0; else exit $?; fi','_',lib]
assert call(append+['retained-r7-input']).returncode==0
before=queue.read_bytes();primary_owner=None;secondary_owner=None;live=None
if case.startswith('steal-dead') or case in ('steal-primary','steal-budget','steal-replacement-budget'):primary_owner=holder(lock)
if case=='steal-primary':pass
elif case in ('steal-unknown','steal-unknown-pipe'):
    target=home/'unrelated-secondary';target.mkdir()
    dead=call(['bash','-c','printf "%s\\n" "$$"']).stdout.strip()
    if case=='steal-unknown-pipe':os.mkfifo(target/'pid')
    else:(target/'pid').write_text(dead+'\n')
    (target/'note').write_text('unrelated data\n');steal.symlink_to(target)
elif case=='steal-unstamped':secondary_owner=holder(steal,dict(OMPCODE='0'))
elif case=='steal-live':
    for name in ('r7-ready','r7-release'):os.mkfifo(home/name)
    live=subprocess.Popen(['bash','-c','. "$1"; fm_lock_try_create "$2" || exit 1; printf "ready\\n" > "$FM_HOME/r7-ready"; read -r _ < "$FM_HOME/r7-release"; fm_lock_release "$2"','_',lib,str(steal)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    with (home/'r7-ready').open() as f:assert f.readline()=='ready\n'
else:secondary_owner=holder(steal)
obstruction=steal
if case=='steal-budget':
    obstruction=Path(str(steal)+'.steal');obstruction.write_text('unknown deeper obstruction\n')
if case.startswith('steal-cross') or case=='steal-unknown-pipe':env['OMPCODE']='0'
protected=snapshot(steal) if steal.is_symlink() else None
shim=home/'r7-bin';shim.mkdir()
for name in ('r7-progress','r7-resume'):os.mkfifo(home/name)
(shim/'perl').write_text('''#!/usr/bin/env bash
if [ "${FM_R7_TRACE:-}" = 1 ] && [ "${4:-}" = owner-create ]; then
  printf 'attempt\\t%s\\n' "$5" > "$FM_HOME/r7-progress"
  read -r _ < "$FM_HOME/r7-resume"
fi
exec /usr/bin/perl "$@"
''');(shim/'perl').chmod(0o755)
(shim/'sleep').write_text('#!/usr/bin/env bash\n[ "$1" != 0.05 ] || exit 0\nexec /bin/sleep "$@"\n');(shim/'sleep').chmod(0o755)
(shim/'mktemp').write_text('''#!/usr/bin/env bash
if [ "${FM_R7_TRACE:-}" = 1 ] && [ "${1:-}" = -d ]; then
  case "${2:-}" in "$FM_STATE_OVERRIDE/.wake-queue.lock"*.owner.XXXXXX)
    printf 'attempt\\t%s\\n' "$2" > "$FM_HOME/r7-progress"
    read -r _ < "$FM_HOME/r7-resume" ;;
  esac
fi
exec /usr/bin/mktemp "$@"
''');(shim/'mktemp').chmod(0o755)
(shim/'cat').write_text('''#!/usr/bin/env bash
if [ "${FM_R7_TRACE:-}" = 1 ] && [ "$#" -eq 1 ] && [ -p "$1" ]; then
  printf 'read-pipe\\t%s\\n' "$1" > "$FM_HOME/r7-progress"
fi
exec /bin/cat "$@"
''');(shim/'cat').chmod(0o755)

refused=case in ('steal-unknown','steal-unstamped','steal-live','steal-budget','steal-replacement-budget','steal-unknown-pipe')
command=append+['appended-r7-input'] if case.endswith('append') else [drain]
extra=dict(PATH=str(shim)+':'+env['PATH'],FM_R7_TRACE='1',FM_OMP_TRANSITION_LOCK_ATTEMPTS='3' if case=='steal-budget' else '4' if case=='steal-replacement-budget' else '12')
wrapper=['bash','-c','"$@"; rc=$?; printf "completed\\n" > "$FM_HOME/r7-progress"; exit "$rc"','_',*command]
try:
    with (home/'r7.out').open('w') as out,(home/'r7.err').open('w') as err,os.fdopen(os.open(home/'r7-progress',os.O_RDWR)) as progress:
        child=subprocess.Popen(wrapper,env=dict(env,**extra),stdout=out,stderr=err)
        attempts=[];reads=0
        while True:
            event=progress.readline()
            if event=='completed\n':break
            if event.startswith('read-pipe\t'):
                reads+=1
                with Path(event.rstrip('\n').split('\t')[1]).open('w') as f:f.write('unverified\n')
                continue
            assert event.startswith('attempt\t'),event
            attempts.append(event.rstrip('\n').split('\t')[1])
            # Even a removed/reset budget naturally completes: retire only this synthetic obstruction.
            if case=='steal-budget' and len(attempts)==8:obstruction.rename(home/'r7-over-budget-obstruction')
            with (home/'r7-resume').open('w') as f:f.write('continue\n')
        rc=child.wait()
    stdout=(home/'r7.out').read_text();stderr=(home/'r7.err').read_text()
    print(json.dumps(dict(case=case,attempts=attempts,reads=reads,rc=rc,stdout=stdout,stderr=stderr)),flush=True)
    if case=='steal-budget':assert len(attempts)==3,'primary and secondary must share exactly three acquisition attempts'
    if case=='steal-replacement-budget':assert len(attempts)==4,'replacement creates must consume the same finite acquisition budget'
    if refused:
        assert reads==0,'secondary recovery read an unverified stream'
        assert rc!=0,'unverified/live secondary must refuse consumption'
        assert not stdout,'refused drain printed unlocked queued input'
        assert 'WARNING' in stderr,'secondary refusal must warn visibly'
        assert queue.read_bytes()==before,'secondary refusal changed queued input'
        if case!='steal-replacement-budget':assert snapshot(steal)==protected,'secondary recovery changed a protected target'
        if primary_owner is not None and case!='steal-replacement-budget':assert lock.is_symlink() and lock.readlink()==primary_owner,'blocked recovery removed its primary'
        result=call([arm],dict(OMPCODE='1',PI_TOOL_CALL_ID='r7-unknown-arm',FM_OMP_TRANSITION_LOCK_ATTEMPTS='0' if case=='steal-replacement-budget' else '3'))
        assert result.returncode==0 and 'WARNING' in result.stderr,'secondary refusal must allow unknown arming with warning'
        if case!='steal-replacement-budget':assert snapshot(steal)==protected,'unknown arm changed a protected secondary'
    else:
        assert rc==0,'genuine dead stamped recovery must complete through the public entrypoint'
        assert 'WARNING' not in stderr,'verified secondary recovery must stay known'
        if case.endswith('append'):
            assert 'appended-r7-input' in queue.read_text(),'recovered append must actually publish'
            result=call([drain]);assert result.returncode==0 and 'appended-r7-input' in result.stdout and 'retained-r7-input' in result.stdout
        else:assert 'retained-r7-input' in stdout,'recovered drain must deliver its queued wake'
        assert not queue.read_bytes(),'recovered drain must consume delivered input'
        assert not lock.is_symlink() and not steal.is_symlink(),'completed recovery must release both levels'
        assert not list((home/'state').glob('.wake-queue.lock*')),'completed recovery left a lock artifact'
        result=call([arm],dict(OMPCODE='1',PI_TOOL_CALL_ID='r7-clean-arm'))
        if case.startswith('steal-cross'):
            assert result.returncode==0 and 'WARNING' in result.stderr,'non-omp consumption must retain conservative unknown observation'
        else:assert result.returncode==2 and 'WARNING' not in result.stderr,'recovered delivery must retain known clean refusal'
finally:
    if live is not None:
        with (home/'r7-release').open('w') as f:f.write('release\n')
        out,err=live.communicate();assert live.returncode==0,(out,err)
if refused:
    if case=='steal-budget':obstruction.rename(home/'r7-retired-obstruction')
    elif live is None and case!='steal-replacement-budget':steal.rename(home/'r7-retired-obstruction')
    assert call(append+['after-r7-release']).returncode==0,'subsequent public append must recover after owned fixture retirement'
    result=call([drain]);assert result.returncode==0 and 'retained-r7-input' in result.stdout and 'after-r7-release' in result.stdout,'subsequent public drain must deliver retained and new wakes'
PYROUND7
      ;;
    caller-pid|claim-rollback|claim-foreign-pid|candidate-foreign-pid|selected-state|selected-state-link|selected-state-identity|bounded-append|bounded-non-omp|bounded-keys|legacy-release|legacy-dead|bounded-watch|bounded-procevent|bounded-procevent-start|bounded-jira)
      arm
      drain
      python3 - "$LAB" "$ROOT" <<'PYROUND6'
import json,os,subprocess,sys
from pathlib import Path
home,root=map(Path,sys.argv[1:]);case=os.environ['FM_TRANSITION_LIFECYCLE_CASE']
env=dict(os.environ);lib=str(home/'bin/fm-wake-lib.sh');drain=str(home/'bin/fm-wake-drain.sh');arm=str(home/'bin/fm-watch-arm.sh')
def call(cmd,extra=None):
    p=subprocess.run(cmd,env=dict(env,**(extra or {})),capture_output=True,text=True)
    print(json.dumps(dict(command=cmd,rc=p.returncode,stdout=p.stdout,stderr=p.stderr)),flush=True)
    return p
append=['bash','-c','. "$1"; fm_wake_append stale r6 retained-before-refusal','_',lib]
assert call(append).returncode==0
queue=home/'state/.wake-queue';before=queue.read_bytes();lock=home/'state/.wake-queue.lock'
if case=='bounded-keys':
    assert call(['bash','-c','. \"$1\"; fm_wake_append check queued-key retained-check','_',lib]).returncode==0
    before=queue.read_bytes()
if case=='caller-pid':
    fork=call(['bash','-c','printf "%s\\n" "$$"']).stdout.strip()
    sim=home/'pid-semantics.sh'
    sim.write_text('''. "$FM_SAFETY_ENV"
if [ -z "${BASHPID:-}" ]; then
  set -T
  trap 'if [ "$BASH_SUBSHELL" -gt 0 ]; then BASHPID=$FM_SIMULATED_FORK_PID; else BASHPID=$$; fi' DEBUG
fi
''')
    extra=dict(BASH_ENV=str(sim),FM_SAFETY_ENV=env.get('BASH_ENV','/dev/null'),FM_SIMULATED_FORK_PID=fork)
    neutral=call(['bash','-c','caller=${BASHPID:-$$}; late=$(printf "%s" "${BASHPID:-$$}"); printf "%s %s %s\\n" "$$" "$caller" "$late"'],extra)
    actual,captured,late=neutral.stdout.split()
    assert actual==captured and late!=captured,'PID simulation must distinguish pre-fork capture'
    result=call([drain],extra)
    assert result.returncode==0,'caller identity must survive substitution: expected drain exit 0'
    assert not lock.exists() and not lock.is_symlink(),'caller identity left a queue link'
    result=call([arm],dict(extra,PI_TOOL_CALL_ID='pid-next-arm'))
    assert result.returncode==2,'simulated caller must retain clean refusal'
    assert 'WARNING' not in result.stderr
elif case.startswith('selected-state'):
    state=home/'outside-selected-state';state.mkdir();identity_home=home/'identity-home';identity_home.mkdir()
    extra=dict(FM_HOME=str(identity_home),FM_STATE_OVERRIDE=str(state),PI_SESSION_ID='selected-root',PI_TOOL_CALL_ID='selected-drain')
    if case=='selected-state-link':
        alias=home/'selected-alias';alias.symlink_to(state);extra['FM_STATE_OVERRIDE']=str(alias)
    elif case=='selected-state-identity':
        injection=home/'state-injection';injection.mkdir()
        (injection/'FixtureState.pm').write_text("""package FixtureState;
BEGIN {
 *CORE::GLOBAL::lstat = sub {
   my @s=CORE::lstat($_[0]);
   if (@s && $_[0] eq $ENV{FM_STATE_OVERRIDE}) {
     $s[1]++;
     open my $proof, '>>', \"$ENV{FM_HOME}/state-mismatch\" or die $!;
     print {$proof} \"mismatch\\n\";
   }
   return wantarray ? @s : scalar @s;
 };
}
1;
""")
        extra.update(PERL5LIB=str(injection),PERL5OPT='-MFixtureState')
    result=call([drain],extra)
    if case!='selected-state':
        assert result.returncode==1,'unverified selected root must refuse consumption'
        assert 'WARNING' in result.stderr
        assert not list(state.iterdir()),'unverified selected root was modified'
        if case=='selected-state-identity':assert (identity_home/'state-mismatch').exists()
        sys.exit(0)
    assert result.returncode==0,'configured outside-home state must drain'
    result=call([arm],dict(extra,PI_TOOL_CALL_ID='selected-arm'))
    assert result.returncode==0
    assert (state/'.omp-watch-arm-result').exists(),'selected state must publish native receipt'
    assert 'WARNING' not in result.stderr
elif case in ('claim-rollback','claim-foreign-pid','candidate-foreign-pid'):
    shim=home/'rollback-bin';shim.mkdir()
    (shim/'perl').write_text('''#!/usr/bin/env bash
if [ "$FM_TRANSITION_LIFECYCLE_CASE" = candidate-foreign-pid ] && [ "${4:-}" = lock-link ]; then
  printf '999999\\n' > "$6/pid"
  cp -R "$6/" "$FM_HOME/foreign-candidate-owner"
  printf '%s\\n' "$6" > "$FM_HOME/foreign-candidate-path"
fi
if [ "${4:-}" = lock-check ] && [ -n "${6:-}" ] && mkdir "$FM_HOME/claim-refused" 2>/dev/null; then
  if [ "$FM_TRANSITION_LIFECYCLE_CASE" = claim-foreign-pid ]; then
    printf '%s\\n' "$FM_FOREIGN_CALLER_PID" > "$6/pid"
    cp -R "$6/" "$FM_HOME/foreign-claim-owner"
    readlink "$5" > "$FM_HOME/foreign-claim-link"
  fi
  echo 'injected claim refusal' >&2
  exit 1
fi
exec /usr/bin/perl "$@"
''');(shim/'perl').chmod(0o755)
    result=call([drain],dict(PATH=str(shim)+':'+env['PATH'],FM_OMP_TRANSITION_LOCK_ATTEMPTS='1',FM_FOREIGN_CALLER_PID=str(os.getpid())))
    if case=='candidate-foreign-pid':
        target=Path((home/'foreign-candidate-path').read_text().strip());expected=home/'foreign-candidate-owner'
        assert target.is_dir(),'rollback removed a mismatched unlinked candidate'
        assert {f.name:f.read_bytes() for f in target.iterdir()}=={f.name:f.read_bytes() for f in expected.iterdir()},'rollback changed a mismatched candidate'
        assert not lock.is_symlink(),'mismatched candidate must not be linked'
        assert queue.read_bytes()==before
        sys.exit(0)
    assert (home/'claim-refused').exists(),'claim refusal must execute'
    assert result.returncode==1,'failed claim must refuse drain'
    if case=='claim-foreign-pid':
        assert lock.is_symlink(),'rollback removed a mismatched claim link'
        target=lock.readlink();expected=home/'foreign-claim-owner'
        assert {f.name:f.read_bytes() for f in target.iterdir()}=={f.name:f.read_bytes() for f in expected.iterdir()},'rollback removed a mismatched claim owner'
        assert queue.read_bytes()==before,'mismatched rollback consumed input'
        sys.exit(0)
    assert not lock.exists() and not lock.is_symlink(),'failed claim left its matching lock link'
    assert not list((home/'state').glob('.wake-queue.lock.owner.*')),'failed claim left its matching owner'
    assert queue.read_bytes()==before,'failed claim consumed input'
    assert call([drain]).returncode==0,'claim rollback must permit subsequent wake delivery'
else:
    shim=home/'bound-bin';shim.mkdir()
    for name in ('bound-progress','bound-resume','holder-ready','holder-release'):os.mkfifo(home/name)
    for tool,condition in (
        ('perl','[ "${4:-}" = owner-create ] && [ "${5:-}" = "$FM_STATE_OVERRIDE/.wake-queue.lock" ]'),
        ('mktemp','[ "$#" -eq 2 ] && [ "$1" = -d ] && [ "$2" = "$FM_STATE_OVERRIDE/.wake-queue.lock.owner.XXXXXX" ]')):
        (shim/tool).write_text('#!/usr/bin/env bash\nif '+condition+"; then\n  n=0\n  [ ! -f \"$FM_HOME/bound-attempts\" ] || read -r n < \"$FM_HOME/bound-attempts\"\n  printf '%s\\n' \"$((n + 1))\" > \"$FM_HOME/bound-attempts\"\nfi\nexec /usr/bin/"+tool+' \"$@\"\n')
        (shim/tool).chmod(0o755)
    (shim/'sleep').write_text('''#!/usr/bin/env bash
case "$1" in 0.05|0.1)
  printf 'retry\\n' > "$FM_HOME/bound-progress"
  read -r _ < "$FM_HOME/bound-resume"
  exit 0 ;;
esac
exec /bin/sleep "$@"
''');(shim/'sleep').chmod(0o755)
    holder=None
    if case=='legacy-release':
        holder=subprocess.Popen(['bash','-c','. "$1"; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK" || exit 1; printf "ready\\n" > "$FM_HOME/holder-ready"; read -r _ < "$FM_HOME/holder-release"; fm_lock_release "$FM_WAKE_QUEUE_LOCK"','_',lib],env=dict(env,OMPCODE='0'),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        with (home/'holder-ready').open() as f:assert f.readline()=='ready\n'
    elif case=='legacy-dead':
        assert call(['bash','-c','. "$1"; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"','_',lib],dict(OMPCODE='0')).returncode==0
    else:lock.write_text('unknown permanent obstruction\n')
    original_link=lock.readlink() if lock.is_symlink() else None
    if case=='bounded-keys':command=['bash','-ec','. "$1"; if fm_wake_queued_keys check; then exit 0; else exit $?; fi','_',lib]
    elif case=='bounded-jira':command=[str(root/'bin/fm-jira.sh'),'--manual','fixture','r6','bounded refusal']
    elif case in ('bounded-procevent','bounded-procevent-start'):
        inbox=home/'state/procevent-inbox';inbox.mkdir()
        if case=='bounded-procevent':
            (inbox/'fixture.1.result').write_text('captured result\n');(inbox/'fixture.1.adapter').write_text('lavish\n')
        command=[str(root/'bin/fm-procevent.sh'),'reconcile']
        if case=='bounded-procevent-start':
            adapter=home/'bin/fm-procevent-fixture.sh';adapter.write_text('#!/usr/bin/env bash\nexit 1\n');adapter.chmod(0o755)
            assert call([str(root/'bin/fm-procevent.sh'),'register','fixture','round6','--','bash','-c','printf "captured-round6\\n"']).returncode==0
            command=[str(root/'bin/fm-procevent.sh'),'start','round6']
    elif case=='bounded-watch':
        command=[str(root/'bin/fm-watch.sh')]
        queue.write_text('1\t1\tcheck\tprocevent:fixture:1\tcheck: captured\n');before=queue.read_bytes()
    elif case in ('legacy-release','legacy-dead','bounded-non-omp'):command=[drain]
    else:command=['bash','-ec','. "$1"; if fm_wake_append heartbeat r6 forbidden-unlocked-append; then exit 0; else exit $?; fi','_',lib]
    extra=dict(PATH=str(shim)+':'+env['PATH'],FM_OMP_TRANSITION_LOCK_ATTEMPTS='3',FM_POLL='0',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='0')
    if case=='bounded-non-omp':extra['OMPCODE']='0'
    wrapper=['bash','-c','"$@"; rc=$?; printf "completed\\n" > "$FM_HOME/bound-progress"; exit "$rc"','_',*command]
    with (home/'bound.out').open('w') as out,(home/'bound.err').open('w') as err,os.fdopen(os.open(home/'bound-progress',os.O_RDWR)) as progress:
        child=subprocess.Popen(wrapper,env=dict(env,**extra),stdout=out,stderr=err)
        retries=0;released=False
        while True:
            event=progress.readline()
            if event=='completed\n':break
            assert event=='retry\n',event
            retries+=1
            if holder is not None and not released:
                with (home/'holder-release').open('w') as f:f.write('release\n')
                stdout,stderr=holder.communicate();assert holder.returncode==0,(stdout,stderr);released=True
            # Old code naturally finishes after exceeding the accepted budget.
            if retries==4:lock.rename(home/'after-budget-obstruction')
            with (home/'bound-resume').open('w') as f:f.write('retry\n')
        rc=child.wait()
    if holder is not None and not released:
        with (home/'holder-release').open('w') as f:f.write('release\n')
        stdout,stderr=holder.communicate();assert holder.returncode==0,(stdout,stderr)
    stdout=(home/'bound.out').read_text();stderr=(home/'bound.err').read_text()
    attempts=int((home/'bound-attempts').read_text())
    print(json.dumps(dict(case=case,attempts=attempts,retries=retries,rc=rc,stdout=stdout,stderr=stderr)),flush=True)
    if case=='legacy-release':
        assert attempts>1 and attempts<=3 and retries>0 and retries<3,'live legacy holder must get the finite retry budget'
        assert rc==0,'live legacy holder release must let the drain complete'
        assert 'retained-before-refusal' in stdout
    else:
        assert attempts==3,'guarded acquisition must use exactly three attempts'
        assert retries==2,'guarded acquisition must pause only between attempts'
        if case=='bounded-keys':assert not stdout,'refused queued-keys read ran without its lock'
        assert rc!=0,'guarded refusal must propagate nonzero, including errexit-exempt callers'
        assert 'WARNING' in stderr,'bounded refusal must warn visibly'
        assert queue.read_bytes()==before,'bounded refusal changed queued input'
        if original_link is not None:assert lock.is_symlink() and lock.readlink()==original_link,'dead PID must not authorize legacy cleanup'
        assert not list((home/'state').glob('.seen-procevent-*')),'unlocked watcher marked a result surfaced'
        if case=='bounded-procevent':assert (inbox/'fixture.1.result').read_text()=='captured result\n'
        elif case=='bounded-procevent-start':
            assert (inbox/'round6.1.result').read_text()=='captured-round6\n','failed publication must retain captured output'
            (home/'state/procevent/round6.source').rename(home/'retired-fixture-source')
        result=call([arm],dict(PI_TOOL_CALL_ID='after-bound-refusal',FM_OMP_TRANSITION_LOCK_ATTEMPTS='1'))
        assert result.returncode==0 and 'WARNING' in result.stderr,'refusal must preserve unknown arming'
        if original_link is not None:lock.unlink()
        else:lock.rename(home/'retired-obstruction')
        if case=='bounded-watch':
            delivered=call([str(root/'bin/fm-watch.sh')],dict(FM_POLL='0',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='0',FM_CHECK_INTERVAL='999999'))
            assert delivered.returncode==0 and 'check: process-event result captured:' in delivered.stdout,'subsequent watcher must deliver retained process event'
        elif case.startswith('bounded-procevent'):
            assert call([str(root/'bin/fm-procevent.sh'),'reconcile']).returncode==0,'captured result must remain eligible for publication'
            key='procevent:round6:1' if case=='bounded-procevent-start' else 'procevent:fixture:1'
            assert key in queue.read_text(),'retried process event must reach the wake queue'
        elif case=='bounded-jira':assert call(command).returncode==0,'manual wake retry must remain available'
        assert call([drain]).returncode==0,'subsequent wake must remain deliverable'
PYROUND6
      ;;
    non-omp-stamped-owner)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker cross-harness-pending; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"' _ "$LAB/bin/fm-wake-lib.sh"
      got=$(OMPCODE=0 "$DRAIN" 2>&1) || fail 'a non-omp drain could not recover a genuine stamped owner'
      assert_contains "$got" cross-harness-pending 'non-omp drain retains normal queue delivery'
      assert_not_contains "$got" WARNING 'verified cross-harness owner recovery stays known'
      [ ! -e "$LAB/state/.wake-queue.lock" ] && [ ! -L "$LAB/state/.wake-queue.lock" ] || fail 'non-omp drain did not release its queue lock'
      [ -z "$(find "$LAB/state" -name '.wake-queue.lock.owner.*' -print)" ] || fail 'non-omp recovery left the stamped owner directory behind'
      ;;
    nested-queue-lock)
      arm
      drain
      mkdir "$LAB/state/nested"
      export FM_WAKE_QUEUE_LOCK="$LAB/state/nested/.wake-queue.lock"
      denied=0
      got=$("$DRAIN" 2>&1) || denied=$?
      printf 'nested drain rc=%s output=%s\n' "$denied" "$got"
      expect_code 0 "$denied" 'a home-owned nested queue lock must preserve normal drain'
      assert_not_contains "$got" WARNING 'a genuine nested lock remains known'
      bash -c '. "$1"; fm_wake_append stale nested nested-pending-wake; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"' _ "$LAB/bin/fm-wake-lib.sh"
      got=$("$DRAIN" 2>&1) || fail 'nested abandoned owner was not recovered'
      assert_contains "$got" nested-pending-wake 'nested recovery prints pending input'
      assert_not_contains "$got" WARNING 'nested abandoned owner identity is verifiable'
      [ ! -e "$FM_WAKE_QUEUE_LOCK" ] && [ ! -L "$FM_WAKE_QUEUE_LOCK" ] || fail 'nested queue lock was not released'
      [ -z "$(find "$LAB/state/nested" -mindepth 1 -print)" ] || fail 'nested candidate cleanup left an owned artifact'
      arm
      expect_code 2 "$rc" 'nested recovery retains fresh reset enforcement'
      assert_observed clean
      ;;
    foreign-lock-owner)
      arm
      drain
      python3 - "$LAB" <<'PYFOREIGN'
import os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1])
for name in ('foreign-ready','foreign-release'):os.mkfifo(home/name)
command=['bash','-c','. "$1"; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK" || exit 1; printf "ready\\n" > "$FM_HOME/foreign-ready"; read -r _ < "$FM_HOME/foreign-release"; fm_lock_release "$FM_WAKE_QUEUE_LOCK"','_',str(home/'bin/fm-wake-lib.sh')]
with (home/'foreign-holder.out').open('w') as out,(home/'foreign-holder.err').open('w') as err:
    holder=subprocess.Popen(command,stdout=out,stderr=err)
    with (home/'foreign-ready').open() as ready:assert ready.readline()=='ready\n'
    before=(home/'state/.omp-watch-transition').read_bytes()
    try:
        forged=subprocess.run([str(home/'bin/fm-omp-watch-transition.sh'),'drain','--queue-lock-held'],input='1\t2\tstale\tforeign\tunowned-admission\n',text=True,capture_output=True)
    finally:
        with (home/'foreign-release').open('w') as release:release.write('continue\n')
        holder_rc=holder.wait()
assert holder_rc==0,(home/'foreign-holder.err').read_text()
assert forged.returncode==1, 'another process claimed a genuine lock: expected exit 1, got '+str(forged.returncode)
assert (home/'state/.omp-watch-transition').read_bytes()==before, 'unowned admission changed the transition'
print('foreign owner refused with rc='+str(forged.returncode),flush=True)
PYFOREIGN
      ;;
    sequence-pipe)
      arm
      drain
      python3 - "$LAB" <<'PYSEQUENCE'
import os,subprocess,sys
from pathlib import Path
home=Path(sys.argv[1]); seq=home/'state/.wake-queue.seq';seq.unlink();os.mkfifo(seq)
os.mkfifo(home/'sequence-progress')
shim=home/'sequence-bin';shim.mkdir()
(shim/'cat').write_text('''#!/usr/bin/env bash
if [ "${1:-}" = "$FM_HOME/state/.wake-queue.seq" ]; then printf 'read-pipe\\n' > "$FM_HOME/sequence-progress"; fi
exec /bin/cat "$@"
''');(shim/'cat').chmod(0o755)
with os.fdopen(os.open(home/'sequence-progress',os.O_RDWR)) as progress, (home/'sequence.out').open('w') as out, (home/'sequence.err').open('w') as err:
    child=subprocess.Popen(['bash','-c','"$1"; rc=$?; printf "completed\\n" > "$FM_HOME/sequence-progress"; exit "$rc"','_',str(home/'bin/fm-watch-arm.sh')], env=dict(os.environ,PATH=str(shim)+':'+os.environ['PATH'],PI_TOOL_CALL_ID='sequence-pipe-arm'),stdout=out,stderr=err)
    reads=0
    while True:
        event=progress.readline()
        if event=='completed\n':break
        assert event=='read-pipe\n',event
        reads+=1
        with seq.open('w') as release:release.write('1\n')
    rc=child.wait()
print('sequence reads='+str(reads)+' rc='+str(rc)+' output='+(home/'sequence.err').read_text(),flush=True)
assert reads==0, 'unknown sequence was read as a stream'
assert rc==0,rc
assert 'WARNING' in (home/'sequence.err').read_text()
assert seq.is_fifo()
PYSEQUENCE
      ;;
    queue-read-error|log-read-error)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker unreadable-queue-fresh' _ "$LAB/bin/fm-wake-lib.sh"
      cp "$LAB/state/.wake-queue" "$LAB/expected-queue"
      cp "$LAB/state/.omp-watch-transitions.log" "$LAB/expected-log"
      mkdir "$LAB/read-injection"
      cat > "$LAB/read-injection/FixtureRead.pm" <<'PM'
package FixtureRead;
BEGIN {
  *CORE::GLOBAL::readline = sub (*) {
    if ($ENV{FM_TRANSITION_LIFECYCLE_CASE} eq 'queue-read-error' && $ARGV[2] =~ /\A(?:snapshot|clear)\z/) {
      open my $proof, '>>', "$ENV{FM_HOME}/read-injected" or die $!;
      print {$proof} "queue read error\n";
      close $proof;
      $! = 5;
      return undef;
    }
    return CORE::readline($_[0]);
  };
  *CORE::GLOBAL::read = sub (*\$$;$) {
    if ($ENV{FM_TRANSITION_LIFECYCLE_CASE} eq 'log-read-error' && $ARGV[2] eq 'read' && $ARGV[3] =~ /\.omp-watch-transitions.log\z/) {
      open my $proof, '>>', "$ENV{FM_HOME}/read-injected" or die $!;
      print {$proof} "log read error\n";
      close $proof;
      $! = 5;
      return undef;
    }
    return @_ == 4 ? CORE::read($_[0], ${$_[1]}, $_[2], $_[3]) : CORE::read($_[0], ${$_[1]}, $_[2]);
  };
}
1;
PM
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-read-error ]; then
        denied=0
        got=$(PERL5LIB="$LAB/read-injection" PERL5OPT=-MFixtureRead "$DRAIN" 2>&1) || denied=$?
        printf 'drain rc=%s output=%s\n' "$denied" "$got"
        assert_grep 'queue read error' "$LAB/read-injected" 'queue read error must execute'
        cmp "$LAB/expected-queue" "$LAB/state/.wake-queue" || fail 'a failed read cleared the unread queue'
        expect_code 1 "$denied" 'unreadable queue must refuse consumption'
      else
        PERL5LIB="$LAB/read-injection" PERL5OPT=-MFixtureRead arm --transition work-pending --reason 'preserve an unread diagnostic log'
        got=$output
        expect_code 0 "$rc" 'unreadable diagnostics preserve arming'
        assert_grep 'log read error' "$LAB/read-injected" 'log read error must execute'
        cmp "$LAB/expected-log" "$LAB/state/.omp-watch-transitions.log" || fail 'a failed read rewrote an unread diagnostic log'
      fi
      assert_contains "$got" WARNING 'read failure must warn visibly'
      ;;
    publication-temp-link|publication-temp-replaced)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker temporary-publication-fresh' _ "$LAB/bin/fm-wake-lib.sh"
      cp "$LAB/state/.omp-watch-transition" "$LAB/expected-record"
      printf 'unrelated publication sentinel\n' > "$LAB/unrelated-temp-data"
      cp "$LAB/unrelated-temp-data" "$LAB/expected-temp-data"
      mkdir "$LAB/temp-injection"
      cat > "$LAB/temp-injection/FixtureTemporary.pm" <<'PM'
package FixtureTemporary;
BEGIN {
  *CORE::GLOBAL::close = sub (*) {
    my ($handle)=@_;
    my @before=CORE::stat($handle);
    my $ok=CORE::close($handle);
    if ($ok && @before && $ARGV[2] eq 'replace' && $ARGV[3] =~ /\.omp-watch-transition\z/ && !-e "$ENV{FM_HOME}/temp-substituted") {
      for my $path (glob '.omp-state.*') {
        my @s=CORE::lstat($path);
        next unless @s && $s[0]==$before[0] && $s[1]==$before[1];
        rename($path, "$ENV{FM_HOME}/original-temporary") or die $!;
        if ($ENV{FM_TRANSITION_LIFECYCLE_CASE} eq 'publication-temp-link') {
          symlink("$ENV{FM_HOME}/unrelated-temp-data", $path) or die $!;
        } else {
          open my $replacement, '>', $path or die $!;
          print {$replacement} "unrelated replacement contents\n";
          CORE::close($replacement);
        }
        open my $proof, '>', "$ENV{FM_HOME}/temp-substituted" or die $!;
        print {$proof} "substituted\n";
        CORE::close($proof);
        last;
      }
    }
    return $ok;
  };
}
1;
PM
      denied=0
      got=$(PERL5LIB="$LAB/temp-injection" PERL5OPT=-MFixtureTemporary "$DRAIN" 2>&1) || denied=$?
      printf 'drain rc=%s output=%s\n' "$denied" "$got"
      assert_grep substituted "$LAB/temp-substituted" 'temporary substitution must execute'
      cmp "$LAB/expected-record" "$LAB/state/.omp-watch-transition" || fail 'publication accepted an unverified temporary source'
      [ ! -L "$LAB/state/.omp-watch-transition" ] || fail 'publication installed an unverified temporary link'
      cmp "$LAB/expected-temp-data" "$LAB/unrelated-temp-data" || fail 'publication changed unrelated temporary target'
      expect_code 1 "$denied" 'temporary identity change must refuse admission'
      assert_contains "$got" WARNING 'temporary identity change must warn'
      ;;
    lock-other-lock)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker different-lock-owner; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK.steal"' _ "$LAB/bin/fm-wake-lib.sh"
      owner=$(readlink "$LAB/state/.wake-queue.lock.steal")
      rm -f "${LAB:?}/state/.wake-queue.lock.steal"
      ln -s "$owner" "$LAB/state/.wake-queue.lock"
      cp -R "$owner/" "$LAB/expected-owner"
      denied=0
      got=$("$DRAIN" 2>&1) || denied=$?
      diff -r "$LAB/expected-owner" "$owner/" || fail 'a different generated lock lost its owner files'
      expect_code 1 "$denied" 'generated owner must belong to this exact lock'
      assert_contains "$got" WARNING 'a different generated lock must warn'
      ;;
    queue-hardlink|queue-outside-home|queue-parent-link|queue-directory|queue-owner|queue-snapshot-swap|queue-content-change|queue-inode-change)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker path-identity-fresh' _ "$LAB/bin/fm-wake-lib.sh"
      cp "$LAB/state/.wake-queue" "$LAB/expected-target"
      case "$FM_TRANSITION_LIFECYCLE_CASE" in
        queue-hardlink)
          mv "$LAB/state/.wake-queue" "$LAB/unrelated-target"
          ln "$LAB/unrelated-target" "$LAB/state/.wake-queue"
          ;;
        queue-outside-home)
          cp "$LAB/expected-target" "$LAB/unrelated-target"
          export FM_WAKE_QUEUE="$LAB/unrelated-target"
          ;;
        queue-parent-link)
          mkdir "$LAB/unrelated-dir"
          cp "$LAB/expected-target" "$LAB/unrelated-dir/queue"
          ln -s "$LAB/unrelated-dir" "$LAB/state/redirected"
          export FM_WAKE_QUEUE="$LAB/state/redirected/queue"
          ;;
        queue-directory)
          mv "$LAB/state/.wake-queue" "$LAB/unrelated-target"
          mkdir "$LAB/state/.wake-queue"
          ;;
        queue-owner)
          mkdir "$LAB/perl-modules"
          cat > "$LAB/perl-modules/FixtureOwnership.pm" <<'PM'
package FixtureOwnership;
BEGIN {
  *CORE::GLOBAL::lstat = sub {
    my @s = CORE::lstat($_[0]);
    if (@s && $_[0] eq '.wake-queue') {
      $s[4] = $> + 1;
      open my $proof, '>>', "$ENV{FM_HOME}/ownership-injected" or die $!;
      print {$proof} "foreign UID\n";
    }
    return wantarray ? @s : scalar @s;
  };
}
1;
PM
          export PERL5LIB="$LAB/perl-modules" PERL5OPT=-MFixtureOwnership
          ;;
        queue-snapshot-swap|queue-content-change|queue-inode-change)
          mkdir "$LAB/swap-bin"
          cat > "$LAB/swap-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ] && jq -e '.uncertain == false and (.classes | index("stale") != null)' "$2" >/dev/null; then
  if [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-content-change ]; then
    printf '2\t999\tstale\treplacement\tnew content must survive\n' > "$FM_HOME/state/.wake-queue"
    cp "$FM_HOME/state/.wake-queue" "$FM_HOME/expected-target"
  elif [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-inode-change ]; then
    /bin/mv "$FM_HOME/state/.wake-queue" "$FM_HOME/admitted-queue"
    cp "$FM_HOME/expected-target" "$FM_HOME/state/.wake-queue"
  else
    cp "$FM_HOME/expected-target" "$FM_HOME/unrelated-target"
    /bin/mv "$FM_HOME/state/.wake-queue" "$FM_HOME/admitted-queue"
    ln -s "$FM_HOME/unrelated-target" "$FM_HOME/state/.wake-queue"
  fi
fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
          chmod +x "$LAB/swap-bin/perl"
          export PATH="$LAB/swap-bin:$PATH"
          ;;
      esac
      denied=0
      got=$("$DRAIN" 2>&1) || denied=$?
      printf 'drain rc=%s output=%s\n' "$denied" "$got"
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-parent-link ]; then
        cmp "$LAB/expected-target" "$LAB/unrelated-dir/queue" || fail 'queue parent link target changed'
      elif [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-content-change ] || [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-inode-change ]; then
        cmp "$LAB/expected-target" "$LAB/state/.wake-queue" || fail 'new queue content was cleared after admission'
      elif [ -f "$LAB/unrelated-target" ]; then
        cmp "$LAB/expected-target" "$LAB/unrelated-target" || fail 'unverified queue object was changed'
      fi
      expect_code 1 "$denied" 'unverified or changed queue must refuse consumption'
      assert_contains "$got" WARNING 'unverified or changed queue must warn'
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" = queue-owner ]; then
        assert_grep 'foreign UID' "$LAB/ownership-injected" 'foreign ownership injection must execute'
      fi
      if [ "$FM_TRANSITION_LIFECYCLE_CASE" != queue-content-change ] && [ "$FM_TRANSITION_LIFECYCLE_CASE" != queue-inode-change ]; then
        arm
        expect_code 0 "$rc" 'unverified queue preserves arming'
        assert_contains "$output" WARNING 'unverified queue arm must remain visible'
      fi
      ;;
    lock-wrong-identity|lock-owner-link|lock-child-link|lock-wrong-home|lock-wrong-path)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker lock-identity-fresh; fm_lock_try_create "$FM_WAKE_QUEUE_LOCK"' _ "$LAB/bin/fm-wake-lib.sh"
      owner=$(readlink "$LAB/state/.wake-queue.lock")
      case "$FM_TRANSITION_LIFECYCLE_CASE" in
        lock-wrong-identity|lock-wrong-home|lock-wrong-path)
          python3 - "$owner" "$FM_TRANSITION_LIFECYCLE_CASE" "$LAB" <<'PYIDENTITY'
from pathlib import Path
import sys
owner=Path(sys.argv[1]); scenario=sys.argv[2]; home=sys.argv[3]
identity=owner.stat()
recorded_home='/another-home' if scenario=='lock-wrong-home' else home
recorded_lock=home+'/state/another.lock' if scenario=='lock-wrong-path' else home+'/state/.wake-queue.lock'
stamp='0:0' if scenario=='lock-wrong-identity' else f'{identity.st_dev}:{identity.st_ino}'
(owner/'lock-identity').write_text(f'v1\n{recorded_home}\n{recorded_lock}\n{stamp}\n')
PYIDENTITY
          ;;
        lock-owner-link)
          mv "$owner" "$LAB/unrelated-owner"
          ln -s "$LAB/unrelated-owner" "$owner"
          ;;
        lock-child-link)
          printf 'unrelated role\n' > "$LAB/unrelated-role"
          ln -s "$LAB/unrelated-role" "$owner/role"
          ;;
      esac
      cp -R "$owner/" "$LAB/expected-owner"
      denied=0
      got=$("$DRAIN" 2>&1) || denied=$?
      printf 'drain rc=%s output=%s\n' "$denied" "$got"
      diff -r "$LAB/expected-owner" "$owner/" || fail 'unverified lock identity lost files'
      expect_code 1 "$denied" 'unverified lock identity must refuse recovery'
      assert_contains "$got" WARNING 'unverified lock identity must warn'
      [ "$(readlink "$LAB/state/.wake-queue.lock")" = "$owner" ] || fail 'unverified owner link was removed'
      arm
      expect_code 0 "$rc" 'unverified owner must allow arming'
      assert_contains "$output" WARNING 'unverified owner arm warns'
      ;;
    arm-result-link)
      arm
      drain
      mv "$LAB/state/.omp-watch-arm-result" "$LAB/unrelated-observation"
      cp "$LAB/unrelated-observation" "$LAB/expected-observation"
      ln -s "$LAB/unrelated-observation" "$LAB/state/.omp-watch-arm-result"
      arm --transition work-pending --reason 'preserve an unknown observation'
      expect_code 0 "$rc" 'unknown observation must preserve arming'
      [ -L "$LAB/state/.omp-watch-arm-result" ] || fail 'arm replaced an unverified observation link'
      cmp "$LAB/unrelated-observation" "$LAB/expected-observation" || fail 'arm rewrote an unverified observation target'
      assert_contains "$output" WARNING 'refused observation publication must warn'
      ;;
    unrelated-lock-target)
      arm
      drain
      bash -c '. "$1"; fm_wake_append stale worker pending-safety-probe' _ "$LAB/bin/fm-wake-lib.sh"
      mkdir "$LAB/unrelated"
      exited=$(bash -c 'printf "%s\n" "$$"')
      printf '%s\n' "$exited" > "$LAB/unrelated/pid"
      for name in fm-home pid-identity role watcher-path; do printf 'unrelated sentinel %s\n' "$name" > "$LAB/unrelated/$name"; done
      printf 'retained unrelated note\n' > "$LAB/unrelated/note"
      cp -R "$LAB/unrelated" "$LAB/expected-unrelated"
      ln -s "$LAB/unrelated" "$LAB/state/.wake-queue.lock"
      denied=0
      got=$("$DRAIN" 2>&1) || denied=$?
      printf 'drain rc=%s output=%s\n' "$denied" "$got"
      diff -r "$LAB/expected-unrelated" "$LAB/unrelated" || fail 'unverified lock target lost unrelated files'
      expect_code 1 "$denied" 'unverified lock target must retain queued wakes'
      assert_contains "$got" WARNING 'unverified lock target must warn'
      [ "$(readlink "$LAB/state/.wake-queue.lock")" = "$LAB/unrelated" ] || fail 'unknown lock link changed'
      assert_grep pending-safety-probe "$LAB/state/.wake-queue" 'unverified lock retains input'
      arm
      expect_code 0 "$rc" 'unverified lock must allow arming'
      assert_contains "$output" WARNING 'unverified lock arm must warn'
      diff -r "$LAB/expected-unrelated" "$LAB/unrelated" || fail 'arm changed the unverified lock target'
      ;;
    unrelated-queue-target)
      arm
      drain
      printf '1\t1\theartbeat\tfixture\tunrelated-target-row\n' > "$LAB/unrelated-queue-data"
      cp "$LAB/unrelated-queue-data" "$LAB/expected-queue-data"
      rm -f "${LAB:?}/state/.wake-queue"
      ln -s "$LAB/unrelated-queue-data" "$LAB/state/.wake-queue"
      denied=0
      got=$("$DRAIN" 2>&1) || denied=$?
      printf 'drain rc=%s output=%s\ntarget bytes=%s\n' "$denied" "$got" "$(wc -c < "$LAB/unrelated-queue-data")"
      cmp "$LAB/unrelated-queue-data" "$LAB/expected-queue-data" || fail 'unverified queue symlink target was truncated'
      expect_code 1 "$denied" 'unverified queue must refuse admission'
      assert_contains "$got" WARNING 'unverified queue must warn'
      [ -L "$LAB/state/.wake-queue" ] || fail 'unknown queue link changed'
      arm
      expect_code 0 "$rc" 'unverified queue must allow arming'
      assert_contains "$output" WARNING 'unverified queue arm must warn'
      cmp "$LAB/unrelated-queue-data" "$LAB/expected-queue-data" || fail 'arm changed the unverified queue target'
      ;;
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
      cat > "$LAB/startup-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ]; then exit 1; fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
      chmod +x "$LAB/startup-bin/perl"
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
          cat > "$LAB/log-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transitions.log" ]; then
  echo injected >> "$FM_HOME/log-failed"
  exit 1
fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
          chmod +x "$LAB/log-bin/perl"
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
(shim/'perl').write_text(r'''#!/usr/bin/env bash
if [ "${BUDGET_PROBE:-}" = 1 ] && [ "${4:-}" = lock-pid ] && [ "${5:-}" = "$FM_HOME/state/.wake-queue.lock" ]; then
  owner=$(ps -p "$PPID" -o ppid= | tr -d '[:space:]')
  n=0
  [ ! -f "$FM_HOME/budget-count.$owner" ] || n=$(/bin/cat "$FM_HOME/budget-count.$owner")
  n=$((n + 1))
  printf '%s\n' "$n" > "$FM_HOME/budget-count.$owner"
  if [ "$n" -eq 2 ]; then printf 'over-budget\n' > "$FM_HOME/budget-progress"; fi
fi
exec /usr/bin/perl "$@"
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
if [ "${1:-}" = -MDigest::SHA=sha256_hex ]; then
  echo unavailable >> "$FM_HOME/hash-failed"
  exit 1
fi
exec /usr/bin/perl "$@"
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
      cat > "$LAB/canonical-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ]; then
  echo injected >> "$FM_HOME/canonical-failed"
  exit 1
fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
      chmod +x "$LAB/canonical-bin/perl"
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
        cat > "$LAB/crash-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ] && jq -e '.uncertain == false' "$2" >/dev/null; then
  /usr/bin/perl "${original[@]}" < "$injection_input"
  echo committed >> "$FM_HOME/commit-interval"
  exit 1
fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
        chmod +x "$LAB/crash-bin/perl"
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
      cat > "$LAB/drain-failure-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ]; then
  case "$FAIL_STAGE" in
    checkpoint) jq -e '.uncertain == true' "$2" >/dev/null && exit 1 ;;
    final) jq -e '.uncertain == false' "$2" >/dev/null && exit 1 ;;
  esac
fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
      chmod +x "$LAB/drain-failure-bin/perl"
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
      cat > "$LAB/fingerprint-bin/perl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -MTime::HiRes=stat ] || exit 1
exec /usr/bin/perl "$@"
SH
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
cat > "$LAB/failure-bin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${4:-}" != replace ]; then exec /usr/bin/perl "$@"; fi
original=("$@")
injection_input=$(mktemp "$FM_HOME/injected-input.XXXXXX")
trap 'rm -f "${injection_input:?}"' EXIT
cat > "$injection_input"
set -- -f "$injection_input" "$5"
for destination; do :; done
if [ "$destination" = "$FM_HOME/state/.omp-watch-transition" ] && { [ "${FAIL_RECEIPT_STAGE:-}" = all ] || jq -e ' .uncertain == false ' "$2" >/dev/null; }; then
  printf 'failed receipt publication\n' >> "$FM_HOME/publication-failures"
  exit 1
fi
exec /usr/bin/perl "${original[@]}" < "$injection_input"
SH
chmod +x "$LAB/failure-bin/perl"
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
  for scenario in steal-recheck-unstamped steal-absent-drain steal-absent-append steal-dead-drain steal-dead-append steal-primary steal-unknown steal-unstamped steal-live steal-budget steal-cross-drain steal-cross-append steal-replacement-budget steal-unknown-pipe caller-pid claim-rollback claim-foreign-pid candidate-foreign-pid selected-state selected-state-link selected-state-identity bounded-append bounded-non-omp bounded-keys legacy-release legacy-dead bounded-watch bounded-procevent bounded-procevent-start bounded-jira non-omp-stamped-owner nested-queue-lock foreign-lock-owner sequence-pipe queue-read-error log-read-error publication-temp-link publication-temp-replaced lock-other-lock queue-hardlink queue-outside-home queue-parent-link queue-directory queue-owner queue-snapshot-swap queue-content-change queue-inode-change lock-wrong-identity lock-owner-link lock-child-link lock-wrong-home lock-wrong-path arm-result-link unrelated-lock-target unrelated-queue-target missing-current-record missing-before-drain fresh-empty fresh-queued replacement-empty replacement-queued dead-lock-owner startup-same-call startup-cycle startup-unknown startup-failed-publication startup-missing-identity startup-invalid-record startup-contradiction missing-malformed-observation missing-observation-symlink dead-lock-obstruction unknown-lock-owner replacement-replay startup-invalid-decision startup-invalid-recovery startup-invalid-pid startup-observation-changed startup-legacy startup-blank-session startup-blank-call dead-lock-steal-pipe startup-dangling-canonical startup-contradiction-arm startup-corrupt-first; do
    FM_TRANSITION_LIFECYCLE_CASE="$scenario" bash "$0"
  done
fi
