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
python3 - "$ROOT" "$LAB" <<'PY'
import json,os,subprocess,sys
from pathlib import Path
root,lab=map(Path,sys.argv[1:])
fixture=lab/'live-isolation'
tools=fixture/'tools'
foreign=fixture/'unrelated'
tools.mkdir(parents=True)
foreign.mkdir()
for name in ('.omp-extension-loaded','queue','config','state-sentinel'):
    (foreign/name).write_text('unrelated '+name+'\n')
before={p.name:p.read_bytes() for p in foreign.iterdir()}
receipt=fixture/'receipt.json'
calls=fixture/'calls'
(tools/'init.mjs').write_text('''
import {writeFileSync,existsSync} from "node:fs";
import {pathToFileURL} from "node:url";
const handlers=new Map();
const {default:extension}=await import(pathToFileURL(process.env.EXTENSION_FILE).href);
extension({on(name,fn){handlers.set(name,fn);},sendMessage(){}});
await handlers.get("session_start")({}, {agent:{kind:"main"}});
writeFileSync(process.env.FIXTURE_RECEIPT,JSON.stringify({env:process.env,
  labMarker:existsSync(process.env.FM_HOME+"/state/.omp-extension-loaded")}));
''')
(tools/'omp').write_text('''#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo fixture-omp; exit 0; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = -e ]; then export EXTENSION_FILE="$2"; shift 2; else shift; fi
done
exec node --experimental-strip-types "$FIXTURE_INIT"
''')
(tools/'helper').write_text('''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE_CALLS"
case "$1" in
  name) printf 'fm-lab-isolation-%s\n' "$$" ;;
  provision|teardown) exit 0 ;;
  run)
    shift 2
    case "$1 $2" in
      'workspace create') echo '{"result":{"root_pane":{"pane_id":"fixture-pane"}}}' ;;
      'pane run') bash "$4"; echo fixture-initialization-complete >&2; exit 73 ;;
      *) exit 98 ;;
    esac ;;
  *) exit 97 ;;
esac
''')
(tools/'herdr').write_text('#!/usr/bin/env bash\nexit 99\n')
for name in ('omp','helper','herdr'):(tools/name).chmod(0o700)
env=dict(os.environ,PATH=str(tools)+':'+os.environ['PATH'],TMPDIR=str(fixture),
    FM_AFK_OMP_HERDR_LIVE_E2E='1',HERDR_LAB_HELPER=str(tools/'helper'),
    FM_HOME=str(foreign),FM_STATE_OVERRIDE=str(foreign),STATE=str(foreign),
    FM_CONFIG_OVERRIDE=str(foreign/'config'),
    FM_WAKE_QUEUE=str(foreign/'queue'),FM_WAKE_QUEUE_LOCK=str(foreign/'lock'),
    FIXTURE_INIT=str(tools/'init.mjs'),FIXTURE_RECEIPT=str(receipt),FIXTURE_CALLS=str(calls))
result=subprocess.run(['bash',str(root/'tests/fm-afk-omp-herdr-live-e2e.test.sh')],
    env=env,capture_output=True,text=True,timeout=15)
assert receipt.exists(),(result.stdout,result.stderr)
assert {p.name:p.read_bytes() for p in foreign.iterdir()}==before, \
    'direct live test changed unrelated scratch state through inherited overrides'
data=json.loads(receipt.read_text())
assert data['labMarker'],'actual extension did not initialize in the lab state'
child=data['env']
home=Path(child['FM_HOME'])
for key,value in {'FM_STATE_OVERRIDE':home/'state','STATE':home/'state',
    'FM_CONFIG_OVERRIDE':home/'config','FM_WAKE_QUEUE':home/'state/.wake-queue',
    'FM_WAKE_QUEUE_LOCK':home/'state/.wake-queue.lock'}.items():
    assert child[key]==str(value),(key,child.get(key),str(value))
assert result.returncode!=0 and 'fixture-initialization-complete' in result.stderr, \
    'inert transport did not stop at the initialization boundary'
operations=calls.read_text().splitlines()
assert any(x.startswith('provision fm-lab-isolation-') for x in operations),operations
assert operations[-1].startswith('teardown fm-lab-isolation-'),operations
assert not list(fixture.glob('fm-afk-omp-live.*')),'live fixture did not clean its lab'
print('ok - direct live test isolates actual extension initialization and all state/config/queue selectors')
PY
