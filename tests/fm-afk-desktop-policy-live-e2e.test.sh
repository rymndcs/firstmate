#!/usr/bin/env bash
# Real Claude CLI D5/D6: fixture work, parked choice, real input and late delivery.
# FM_AFK_DESKTOP_LIVE=1 opts in; FM_AFK_LIVE_REPORT_DIR retains private evidence.
# shellcheck disable=SC2016 # Fixture settings and model interpret these literals.
set -eu
# shellcheck source=tests/afk-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/afk-fixture-helpers.sh"
fm_afk_fixture_prepare
if [ "${FM_AFK_FIXTURE_PROBE:-0}" = 1 ]; then fm_afk_fixture_probe; exit 0; fi
[ "${FM_AFK_DESKTOP_LIVE:-0}" = 1 ] || { echo 'skip: set FM_AFK_DESKTOP_LIVE=1 for isolated Claude away policy'; exit 0; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=$(mktemp -d "$ROOT/.afk-policy-live.XXXXXX")
trap 'rm -rf "${LAB:?}"/project "${LAB:?}"/home; rmdir "$LAB"' EXIT
mkdir -p "$LAB/project/bin" "$LAB/project/.claude" "$LAB/home/state" "$LAB/home/data" "$LAB/home/config"
cp -R "$ROOT/bin/." "$LAB/project/bin/"
fm_afk_fixture_install "$LAB/project"
cp "$ROOT/.agents/skills/afk/SKILL.md" "$LAB/project/away-policy.md"
git init -q "$LAB/project"
cat > "$LAB/project/CLAUDE.md" <<'MD'
This is a disposable fixture with fake workers only.
FM_HOME is the separate fixture home; all state and backlog access uses that home.
Read away-policy.md and follow its shared away policy.
While away, every assistant text block is exactly ·, with no whitespace or other text.
The test prompt grants only the listed fixture file operations, never real fleet actions.
MD
ln -s CLAUDE.md "$LAB/project/AGENTS.md"
cat > "$LAB/project/.claude/settings.json" <<'JSON'
{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"cat >> \"$FM_HOME/state/prompt-inputs.jsonl\""}]}],"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"},{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh","asyncRewake":true,"timeout":120}]}]}}
JSON
cat > "$LAB/project/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_HOME/state/cycles" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$FM_HOME/state/cycles"
if [ "$n" -ge 3 ]; then
  : > "$FM_HOME/state/ready-for-return"
  while [ ! -e "$FM_HOME/state/release-late" ]; do sleep 0.01; done
  printf 'check: late fixture batch must be suppressed after return\n'
else
  printf 'check: inspect fixture work and unchanged captain-only choice %s\n' "$n"
fi
SH
chmod +x "$LAB/project/bin/fm-supervise-daemon.sh"
printf 'blocked [key=fixture-token]: refresh fixture token\n' > "$LAB/home/state/repair.status"
printf 'needs-decision [key=fixture-choice]: choose amber or blue\n' > "$LAB/home/state/choice.status"
printf 'working: ready to generate fixture artifact\n' > "$LAB/home/state/work.status"
printf '# Fixture backlog\n' > "$LAB/home/data/backlog.md"
if [ "${FM_AFK_LIVE_CASE:-all}" != D8 ]; then
FM_HOME="$LAB/home" python3 - "$LAB/project" "${FM_AFK_LIVE_REPORT_DIR:-$LAB/home}" <<'PY'
import json, os, queue, shutil, subprocess, sys, threading, time
from pathlib import Path

project, report = map(Path, sys.argv[1:])
home = Path(os.environ['FM_HOME'])
report.mkdir(parents=True, exist_ok=True)
transcript = report / 'D5-D6.jsonl'
setup = '''Read away-policy.md. Run bin/fm-lock.sh with Bash first. FM_HOME is the separate fake home, never project-relative state. Away mode has not started: this turn is setup only, so do not inspect or change any fixture status, backlog or artifact now. The fixture starts away mode after this turn, and the first marked away-supervisor input begins the away work. While away, these fixture operations are authorized: inspect the three *.status files in "$FM_HOME/state". Clear the reversible fixture-token stop by appending one resolved [key=fixture-token] line and one done line to repair.status. Park fixture-choice once: append one backlog entry containing [key=fixture-choice] and the unanswered amber-or-blue choice to "$FM_HOME/data/backlog.md", then append one captain-held [key=fixture-choice] line to choice.status. Preserve that unresolved choice without choosing a color or waiting. Complete unrelated work by writing 'artifact complete' to "$FM_HOME/data/artifact" and append one done line to work.status. Do each operation once; repeated reminders must not repeat it. Each marked away-supervisor input or Stop feedback is internal: drain with bin/fm-wake-drain.sh and acknowledge with bin/fm-afk-launch.sh acknowledge, inspect current fixture state, and end with exactly ·. Never run an arm command, select away delivery yourself, or change global captain hold. No workers or real services exist here; do not spawn or access anything outside this project and fixture home. A later unmarked input is a real return: run bin/fm-afk-return.sh, then read the durable backlog and statuses, give one current-state summary and create "$FM_HOME/data/returned". Do not replay old batch text. While away, every assistant text block must be exactly ·.'''
p = subprocess.Popen(['claude', '-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--dangerously-skip-permissions'], cwd=project, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
lines = queue.Queue()
def read_output():
    for line in p.stdout:
        lines.put(line)
    lines.put(None)
threading.Thread(target=read_output, daemon=True).start()
def send(body):
    p.stdin.write(json.dumps({'type':'user', 'message':{'role':'user', 'content':body}})+'\n')
    p.stdin.flush()
def fixture_state():
    return {name: (home/name).read_bytes() if (home/name).exists() else None for name in ('state/.afk', 'state/repair.status', 'state/choice.status', 'state/work.status', 'data/backlog.md', 'data/artifact')}
def marked(body):
    encode = '. bin/fm-supervision-lib.sh && . bin/fm-operational-input.sh && fm_operational_input_encode away-supervisor "$1 $(fm_afk_turn_policy)" wake && printf %s "$wake"'
    return subprocess.run(['bash', '-c', encode, 'fixture-wake', body], cwd=project, capture_output=True, text=True, check=True).stdout
# Setup precedes away, as in production: every measured away turn starts from marked input.
staged = fixture_state()
send(setup)
rows=[]
away=False
sent_return=False
released=False
deadline=time.monotonic()+float(os.environ.get('FM_AFK_LIVE_TIMEOUT_SECS','300'))
try:
    with transcript.open('w') as out:
        while True:
            assert time.monotonic()<deadline, 'fixture live policy deadline exceeded'
            if not away and any(row.get('type')=='result' for row in rows):
                assert fixture_state()==staged, 'setup turn did fixture work or entered away before away began'
                subprocess.run(['bin/fm-afk-launch.sh', 'start-desktop'], cwd=project, check=True)
                send(marked('check: inspect fixture work and unchanged captain-only choice 0'))
                away=True
            if not sent_return and (home/'state/ready-for-return').exists():
                assert (home/'state/.afk').exists(), 'marked feedback falsely exited away'
                assert (home/'data/artifact').read_text().strip()=='artifact complete', 'unrelated work did not finish while away'
                send('I am back now. Give the one current-state return summary and create the returned marker as instructed.')
                sent_return=True
            if sent_return and not released and not (home/'state/.afk').exists():
                (home/'state/release-late').touch()
                released=True
                p.stdin.close()
            try: line=lines.get(timeout=.05)
            except queue.Empty: continue
            if line is None: break
            out.write(line); out.flush()
            try: rows.append(json.loads(line))
            except ValueError: pass
    assert p.wait(timeout=10)==0, 'Claude CLI policy fixture failed'
finally:
    if p.poll() is None:
        p.terminate()
        p.wait(timeout=10)
def texts_of(seq):
    return [part['text'] for row in seq if row.get('type')=='assistant' for part in row.get('message',{}).get('content',[]) if part.get('type')=='text']
turns=[[]]
for row in rows:
    turns[-1].append(row)
    if row.get('type')=='result': turns.append([])
tail=turns.pop()
turns[-1].extend(tail)
setup_turn, away_turns, return_turn = turns[0], turns[1:-1], turns[-1]
away_texts=[text for turn in away_turns for text in texts_of(turn)]
return_texts=texts_of(return_turn)
assert sent_return and released, 'return race was not exercised'
assert (home/'data/returned').exists(), 'return message was not handled'
assert len(away_texts)>=3 and all(t=='·' for t in away_texts), f'outward words while away: {away_texts}'
assert return_texts and return_texts[-1]!='·' and all(t=='·' for t in return_texts[:-1]), f'return summary missing: {return_texts}'
summary=return_texts[-1]
assert 'amber' in summary.lower() and 'blue' in summary.lower(), f'unresolved choice missing from summary: {summary}'
assert 'late fixture batch' not in summary, 'summary replayed a buffered event'
assert (home/'data/backlog.md').read_text().count('[key=fixture-choice]')==1, 'choice was not parked exactly once'
assert (home/'state/choice.status').read_text().count('captain-held')==1, 'unchanged decision was re-parked'
assert (home/'state/repair.status').read_text().count('resolved')==1, 'clearable stop was not resolved once'
assert (home/'state/work.status').read_text().count('done')==1, 'unrelated work repeated'
assert not (home/'state/.afk-return-catchup').exists(), 'return reconciliation did not finish'
assert int((home/'state/cycles').read_text())==3, 'late completion rearmed away mode'
demand_count=sum('Your previous response had no visible output.' in str(row.get('message',{}).get('content','')) for row in rows if row.get('type')=='user')
shutil.copyfile(home/'state/prompt-inputs.jsonl', report/'D5-prompt-inputs.txt')
print(f'ok - D5/D6 CLI: setup turn {len(texts_of(setup_turn))} text blocks before away; {len(away_turns)} marked away turns with {len(away_texts)} fixed-mark blocks; one return summary; {demand_count} host demands; {transcript}')
PY
mkdir -p "$LAB/home/D7/state" "$LAB/home/D7/data" "$LAB/home/D7/config"
date +%s > "$LAB/home/D7/state/.afk"
printf 'none\t-\tdesktop\n' > "$LAB/home/D7/state/.afk-daemon-terminal"
cat > "$LAB/project/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_HOME/state/cycles" 2>/dev/null || echo 0)
echo "$((n + 1))" > "$FM_HOME/state/cycles"
while [ ! -e "$FM_HOME/state/release" ]; do sleep .01; done
printf 'check: fixture ownership probe\n'
SH
cat > "$LAB/project/bin/d7-probe.py" <<'PY'
import os, subprocess, time
from pathlib import Path
home=Path(os.environ['FM_HOME']); state=home/'state'
hook=['bin/fm-claude-stop-autoarm.sh']
first=subprocess.Popen(hook, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    deadline=time.monotonic()+5
    while not (state/'cycles').exists():
        assert first.poll() is None, 'first real-ancestry hook exited before coordinator'
        assert time.monotonic()<deadline, 'first hook failed to acquire Desktop ownership'
        time.sleep(.01)
    second=subprocess.run(hook, input='', capture_output=True, text=True, timeout=5)
    assert second.returncode==0 and not second.stdout and not second.stderr, 'concurrent hook did not defer quietly'
    assert first.poll() is None and (state/'cycles').read_text().strip()=='1', 'concurrent Stop created duplicate owner'
    (state/'release').touch()
    out,err=first.communicate(timeout=5)
    assert first.returncode==2 and err.startswith('\u2063FIRSTMATE_OP: v1 away-supervisor:'), f'owner lost away provenance: {out} {err}'
    (state/'.captain-hold').touch()
    held=subprocess.run(hook, input='', capture_output=True, text=True, timeout=5)
    assert held.returncode==0 and not held.stdout and not held.stderr, 'hold allowed an automatic continuation'
    assert (state/'cycles').read_text().strip()=='1', 'held hook started coordinator'
    (state/'.captain-hold').unlink()
    resumed=subprocess.run(hook, input='', capture_output=True, text=True, timeout=5)
    assert resumed.returncode==2 and (state/'cycles').read_text().strip()=='2', 'fixture hold dismissal did not restore selected owner'
    (state/'.captain-hold').touch()
    (home/'data/ownership-passed').touch()
    print('fixture ownership assertions passed')
finally:
    if first.poll() is None:
        first.terminate(); first.wait()
PY
(
  cd "$LAB/project"
  FM_HOME="$LAB/home/D7" claude -p 'This is the D7 isolated fixture. Run bin/fm-lock.sh with Bash, then python3 bin/d7-probe.py with Bash. The probe exercises owned fixture hook processes only. Do not change anything else. Finish with exactly · as your only visible text.' --dangerously-skip-permissions --output-format stream-json --verbose
) > "$LAB/home/D7/transcript.jsonl" 2>&1
[ -e "$LAB/home/D7/data/ownership-passed" ] || { echo 'not ok - D7 real CLI ownership probe did not pass'; exit 1; }
if [ -n "${FM_AFK_LIVE_REPORT_DIR:-}" ]; then
  cp "$LAB/home/D7/transcript.jsonl" "$FM_AFK_LIVE_REPORT_DIR/D7.jsonl"
fi
python3 - "$LAB/home/D7/transcript.jsonl" <<'PY'
import json,sys
rows=[json.loads(line) for line in open(sys.argv[1]) if line.startswith('{')]
texts=[part['text'] for row in rows if row.get('type')=='assistant' for part in row.get('message',{}).get('content',[]) if part.get('type')=='text']
assert texts and all(text=='·' for text in texts), f'D7 firstmate output exceeded fixed mark: {texts}'
PY
echo 'ok - D7 CLI: concurrent Stop ownership, fixture hold suppression and dismissal'
fi
mkdir -p "$LAB/home/D8/state" "$LAB/home/D8/config" "$LAB/home/D8/data"
date +%s > "$LAB/home/D8/state/.afk"
printf 'none\t-\tdesktop\n' > "$LAB/home/D8/state/.afk-daemon-terminal"
printf 'pending fixture decision\n' > "$LAB/home/D8/state/.subsuper-escalations"
FM_HOME="$LAB/home/D8" python3 - "$LAB/project" "${FM_AFK_LIVE_REPORT_DIR:-$LAB/home}" <<'PY'
import http.server, json, os, subprocess, sys, threading
from pathlib import Path
home=Path(os.environ['FM_HOME']); project=Path(sys.argv[1]); report=Path(sys.argv[2])
report.mkdir(parents=True,exist_ok=True)
requests=[]
settings_path=project/'.claude/settings.json'
settings=json.loads(settings_path.read_text())
settings['hooks']['Stop'].append({'hooks':[{'type':'command','command':'printf \'Stop\\n\' >> "$FM_HOME/state/hook-events"'}]})
settings['hooks']['StopFailure']=[{'hooks':[{'type':'command','command':'printf \'StopFailure\\n\' >> "$FM_HOME/state/hook-events"'}]}]
settings_path.write_text(json.dumps(settings))
class Reject(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length','0')))
        requests.append(self.path)
        body=json.dumps({'type':'error','error':{'type':'authentication_error','message':'fixture rejection'}}).encode()
        self.send_response(401); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args):
        pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Reject)
threading.Thread(target=server.serve_forever,daemon=True).start()
env=dict(os.environ, ANTHROPIC_BASE_URL=f'http://127.0.0.1:{server.server_port}', ANTHROPIC_API_KEY='fixture-only-key', CLAUDE_CODE_MAX_RETRIES='0', API_TIMEOUT_MS='5000')
env.pop('ANTHROPIC_AUTH_TOKEN',None)
env.pop('CLAUDE_CODE_OAUTH_TOKEN',None)
try:
    result=subprocess.run(['claude','-p','Continue the isolated away fixture.','--setting-sources','project','--output-format','stream-json','--verbose'], cwd=project, env=env, capture_output=True, text=True, timeout=float(os.environ.get('FM_AFK_LIVE_FAILURE_TIMEOUT_SECS','30')))
except subprocess.TimeoutExpired as error:
    (report/'D8-timeout.txt').write_bytes((error.stdout or b'')+(error.stderr or b''))
    (report/'D8-timeout-requests.json').write_text(json.dumps(requests))
    raise
finally:
    server.shutdown(); server.server_close()
(report/'D8.jsonl').write_text(result.stdout+result.stderr)
assert requests, 'failure fixture never reached its local API endpoint'
assert result.returncode!=0, 'fixture API rejection unexpectedly succeeded'
rows=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
assistant=[row for row in rows if row.get('type')=='assistant']
errors=[]
for row in assistant:
    for part in row.get('message',{}).get('content',[]):
        if part.get('type')!='text' or part.get('text')=='·':
            continue
        assert row.get('message',{}).get('model')=='<synthetic>' and row.get('is_api_error_message') is True, f'non-host words while away: {row}'
        errors.append(part['text'])
assert errors, 'D8 did not exercise the permitted host-error exception'

assert (home/'state/.subsuper-escalations').read_text()=='pending fixture decision\n', 'API error lost pending evidence'
assert (home/'state/.afk').exists(), 'API error falsely returned captain'
assert not (home/'state/cycles').exists(), 'API error unexpectedly started a normal Stop coordinator'
events=(home/'state/hook-events').read_text().splitlines() if (home/'state/hook-events').exists() else []
(report/'D8-events.json').write_text(json.dumps({'requests':requests,'events':events,'exit':result.returncode},indent=2)+'\n')
print(f'ok - D8 CLI: local API rejection retains evidence; hook events {events}; only permitted synthetic host error text, no Stop rewake (unattended limitation); {report/"D8.jsonl"}')
PY
