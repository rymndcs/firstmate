#!/usr/bin/env bash
# Opt-in real omp primary: retained busy row, two away completions, and return.
set -euo pipefail
if [ "${FM_AFK_OMP_HERDR_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_AFK_OMP_HERDR_LIVE_E2E=1 for the real omp away-owner regression'
  exit 0
fi
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
for tool in omp herdr jq python3; do
  command -v "$tool" >/dev/null || { echo "not ok - $tool is required"; exit 1; }
done
export HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-afk-omp-inject-never-delivers)
export HERDR_LAB_SESSION
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-omp-live.XXXXXX")
cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
  rm -rf "${LAB:?}"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
export HERDR_LAB_REAL_PATH=$PATH
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/sessions"
cat > "$LAB/shim/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$HERDR_LAB_SESSION" ] || exit 99; shift 2 ;;
    --session=*) [ "${1#*=}" = "$HERDR_LAB_SESSION" ] || exit 99; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH="$HERDR_LAB_REAL_PATH" exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/shim/herdr"
export ROOT LAB
python3 <<'PY'
import json,os,shlex,subprocess,time
from pathlib import Path
root,lab=map(Path,(os.environ['ROOT'],os.environ['LAB']))
helper,session=os.environ['HERDR_LAB_HELPER'],os.environ['HERDR_LAB_SESSION']
version=subprocess.check_output(['omp','--version'],text=True).strip()
def run(*args):
    return subprocess.check_output([helper,'run',session,*args],text=True)
def wait(what,predicate,seconds=120):
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        if predicate():return
        time.sleep(.2)
    raise AssertionError(f'{version}: {what}\n'+run('pane','read',pane,'--source','visible','--lines','40'))
def messages():
    rows=[]
    for file in (lab/'sessions').glob('*.jsonl'):
        for line in file.read_text().splitlines():
            try: rows.append(json.loads(line))
            except json.JSONDecodeError:pass
    return rows
def replied(text):
    return any(o.get('type')=='message' and o.get('message',{}).get('role')=='assistant'
               and any(c.get('type')=='text' and text==c.get('text') for c in o['message'].get('content',[]) if isinstance(c,dict))
               for o in messages())
def prompt(text):
    run('pane','send-text',pane,text);run('pane','send-keys',pane,'enter')
info=json.loads(run('workspace','create','--label','omp-away','--cwd',str(lab),'--no-focus'))
pane=info['result']['root_pane']['pane_id']
model=os.environ.get('FM_OMP_LIVE_MODEL','anthropic/claude-opus-5-5')
env={'FM_HOME':str(lab/'home'),'FM_ROOT_OVERRIDE':str(root),'FM_POLL':'0.1','FM_SIGNAL_GRACE':'0','FM_HEARTBEAT':'600','FM_WEDGE_ALARM_EXEC':'discard','PATH':str(lab/'shim')+':'+os.environ['PATH']}
cmd='env '+ ' '.join(f'{k}={shlex.quote(v)}' for k,v in env.items())+' omp --model '+shlex.quote(model)+' --thinking low --approval-mode yolo --no-extensions -e '+shlex.quote(str(root/'.omp/extensions/fm-primary-omp.ts'))+' --no-rules --no-skills --no-title --session-dir '+shlex.quote(str(lab/'sessions'))
launcher=lab/'start-omp.sh'
launcher.write_text('#!/usr/bin/env bash\nexec '+cmd+'\n')
launcher.chmod(0o700)
run('pane','run',pane,str(launcher))
wait('primary extension not loaded',lambda:(lab/'home/state/.omp-extension-loaded').exists())
start=str(root/'bin/fm-afk-launch.sh')+' start-native'
arm=str(root/'bin/fm-watch-arm.sh')
drain=str(root/'bin/fm-wake-drain.sh')
prompt(f'This is an isolated supervision lab. Use only the authorized lab home in FM_HOME. Run {root}/bin/fm-lock.sh synchronously, then {start} synchronously. Start {arm} in a standalone bash call with async:true timeout:0. Read its proc status once and reply exactly AWAY_ARMED. For every completion of that watcher job: run {drain} first, read the lab-worker.status event, append its last line to $FM_HOME/state/actions, re-arm {arm} in its own async:true timeout:0 bash call, and reply exactly ·. Process each event once. Never start a pane daemon. A genuine return prompt runs {root}/bin/fm-afk-return.sh first and replies RETURNED after catch-up clear. Do no other work.')
state=lab/'home/state'
wait('away watcher not armed',lambda:replied('AWAY_ARMED') and (state/'.watch.lock/pid').exists())
assert (state/'.afk-daemon-terminal').read_text().strip()=='none\t-\tomp'
assert not (state/'.supervise-daemon.lock').exists()
for n in (1,2):
    initial=(state/'.watch.lock/pid').read_text()
    t=time.monotonic()
    event=f'working: event-{n} requires an authorized lab action'
    (state/'lab-worker.status').write_text(event+'\n')
    wait(f'worker event {n} not handled',lambda:(state/'actions').exists() and event in (state/'actions').read_text(),110)
    wait(f'watcher {n} not rearmed',lambda:(state/'.watch.lock/pid').exists() and (state/'.watch.lock/pid').read_text()!=initial,110)
    elapsed=time.monotonic()-t
    print(f'ok - {version}: away worker event {n} acted on and rearmed in {elapsed:.1f}s',flush=True)
    assert elapsed<120
    assert (state/'actions').read_text().splitlines().count(event)==1
assert not (state/'.supervise-daemon.lock').exists()
prompt(f'I am back. Run {root}/bin/fm-afk-return.sh before handling this message; after catch-up clear reply exactly RETURNED. Do not re-enter away mode.')
wait('return did not clear through fm-afk-return.sh',lambda:replied('RETURNED') and not (state/'.afk').exists())
assert not (state/'.afk-daemon-terminal').exists()
assert not (state/'.afk-return-catchup').exists()
print(f'ok - {version}: shared return gate cleared and retired omp away selection',flush=True)
PY
