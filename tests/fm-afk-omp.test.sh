#!/usr/bin/env bash
# Portable omp away selection and real watcher completion, without a harness.
set -euo pipefail
# shellcheck source=tests/afk-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/afk-fixture-helpers.sh"
fm_afk_fixture_prepare
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-afk-omp)
trap 'rm -rf "${LAB:?}"' EXIT
export FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_ROOT_OVERRIDE="$ROOT"
export FM_SUPERVISOR_BACKEND=unsupported FM_SUPERVISOR_TARGET=fixture:never
mkdir -p "$LAB/state"
launch() { OMPCODE=1 "$ROOT/bin/fm-afk-launch.sh" "$@"; }
launch start-native
[ "$(cat "$LAB/state/.afk-daemon-terminal")" = $'none\t-\tomp' ] || fail 'omp selected a pane daemon instead of async completions'
printf 'pending evidence\n' > "$LAB/state/.subsuper-escalations"
launch start
assert_grep 'pending evidence' "$LAB/state/.subsuper-escalations" 'omp refresh lost evidence'
if launch start-desktop; then fail 'Desktop replaced the selected omp owner'; fi
if CLAUDECODE=1 "$ROOT/bin/fm-afk-launch.sh" start-native; then fail 'pane delivery replaced the selected omp owner'; fi
if OMPCODE=1 "$ROOT/bin/fm-afk-start.sh" > "$LAB/start.out" 2>&1; then fail 'omp started the pane daemon'; fi
assert_grep 'omp uses' "$LAB/start.out" 'omp refusal did not identify its supported wake path'
assert_absent "$LAB/state/.supervise-daemon.log" 'omp daemon actually started'
if "$ROOT/bin/fm-supervise-daemon.sh" > "$LAB/daemon.out" 2>&1; then fail 'direct daemon replaced omp delivery'; fi
assert_grep 'omp delivery' "$LAB/daemon.out" 'direct daemon did not enforce the selected owner'
FM_HOME="$LAB" bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2"' _ "$ROOT" "$LAB/state" || fail 'away omp without workers lost supervision'
pass 'omp selects one durable async owner, preserves refresh evidence, and refuses pane entry'
python3 - "$ROOT" "$LAB" <<'PY'
import os,subprocess,sys,time
from pathlib import Path
root,lab=map(Path,sys.argv[1:])
env=dict(os.environ,FM_POLL='0.05',FM_SIGNAL_GRACE='0',FM_HEARTBEAT='600',FM_ARM_ATTACH_POLL='0.05')
p=subprocess.Popen([str(root/'bin/fm-watch-arm.sh')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    status=p.stdout.readline()
    assert status.startswith('watcher: started'),status
    (lab/'state/lab-worker.status').write_text('needs-decision [key=lab]: action required\n')
    out,err=p.communicate(timeout=10)
    assert p.returncode==0,(out,err)
    assert 'signal:' in out,out
    assert '.status' in (lab/'state/.wake-queue').read_text()
    assert not (lab/'state/.supervise-daemon.lock').exists()
    print('ok - real one-shot watcher completes on a worker event during omp away mode')
finally:
    if p.poll() is None:
        p.terminate(); p.communicate(timeout=5)
PY
"$ROOT/bin/fm-afk-return.sh" > "$LAB/return.out" 2>&1
assert_grep 'catch-up clear' "$LAB/return.out" 'omp return gate did not clear'
assert_absent "$LAB/state/.afk" 'omp return left away flag'
assert_absent "$LAB/state/.afk-daemon-terminal" 'omp return left selected owner'
launch start
[ "$(cat "$LAB/state/.afk-daemon-terminal")" = $'none\t-\tomp' ] || fail 'generic omp start did not select async delivery'
launch stop
pass 'omp return clears through the shared return owner and generic entry selects async delivery'
