#!/usr/bin/env bash
# Probe entry points without invoking any backend, even in the red run.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os, shutil, subprocess, sys, tempfile
from pathlib import Path
root=Path(sys.argv[1])
dirty=dict(os.environ,HERDR_ENV='1',HERDR_PANE_ID='w99:p99',HERDR_SESSION='default',HERDR_SOCKET_PATH='/fixture/not-a-socket',TMUX='/fixture/not-a-socket,1,1',TMUX_PANE='%999',CMUX_WORKSPACE_ID='fixture',ZELLIJ_SESSION_NAME='fixture',ORCA_SOCKET_PATH='/fixture/not-a-socket',FM_SUPERVISOR_TARGET='default:w99:p99',FM_SUPERVISOR_BACKEND='herdr',FM_BACKEND='herdr',FM_HOME='/fixture/not-a-home',FM_AFK_FIXTURE_PROBE='1')
leaks=[]
for name in ['fm-afk-desktop.test.sh','fm-afk-desktop-live-e2e.test.sh','fm-afk-desktop-policy-live-e2e.test.sh']:
    result=subprocess.run(['bash',str(root/'tests'/name)],env=dirty,capture_output=True,text=True,timeout=5)
    assert result.returncode==0 and 'fixture-probe-complete' in result.stdout, f'fixture probe did not run: {name}: {result.stderr}'
    inherited=set(result.stdout.splitlines()) & {'HERDR_ENV','HERDR_PANE_ID','HERDR_SESSION','HERDR_SOCKET_PATH','HERDR_TAB_ID','HERDR_WORKSPACE_ID','TMUX','TMUX_PANE','CMUX_WORKSPACE_ID','ZELLIJ_SESSION_NAME','ORCA_SOCKET_PATH','FM_SUPERVISOR_TARGET','FM_SUPERVISOR_BACKEND','FM_BACKEND','FM_HOME','__CFBundleIdentifier'}
    if inherited:
        leaks.append((name,sorted(inherited)))
assert not leaks, f'fixture entry points inherited live terminal inputs: {leaks}'
print('ok - all Desktop away fixture entry points strip inherited terminal inputs')
with tempfile.TemporaryDirectory(prefix='.afk-isolation-check.',dir=root) as name:
    lab=Path(name); project=lab/'project'; project.mkdir(); (project/'state').mkdir()
    shutil.copytree(root/'bin',project/'bin')
    sentinel=lab/'sentinel'; sentinel.mkdir()
    for cli in ['tmux','herdr','cmux','zellij','orca']:
        path=sentinel/cli
        path.write_text('#!/usr/bin/env bash\nprintf escaped >> "$FM_HOME/state/sentinel"\nexit 83\n')
        path.chmod(0o755)
    command='''
      . "$1/tests/afk-fixture-helpers.sh"
      fm_afk_fixture_prepare
      fm_afk_fixture_install "$2"
      export FM_HOME="$2" HERDR_ENV=1 HERDR_PANE_ID=w99:p99 FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET=default:w99:p99
      for cli in tmux herdr cmux zellij orca; do "$cli" fixture-path-call || true; done
      export PATH="$3"
      . "$2/bin/fm-backend.sh"
      fm_backend_target_exists herdr default:w99:p99 || true
      for cli in tmux herdr cmux zellij orca; do "$cli" fixture-call || true; done
    '''
    result=subprocess.run(['bash','-c',command,'fixture',str(root),str(project),str(sentinel)+os.pathsep+os.environ['PATH']],env=dict(dirty,PATH=str(sentinel)+os.pathsep+os.environ['PATH']),capture_output=True,text=True,timeout=5)
    assert result.returncode==0, result.stderr
    assert not (project/'state/sentinel').exists(), 'fixture backend call escaped to ambient PATH despite reintroduced terminal inputs'
    assert set((project/'state/fake-backend.calls').read_text().splitlines())=={'tmux','herdr','cmux','zellij','orca'}, 'fixture did not fake every terminal backend'
print('ok - copied backend interfaces stay fake when terminal inputs are reintroduced')
PY
