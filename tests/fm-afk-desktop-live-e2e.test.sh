#!/usr/bin/env bash
# Real Claude Code hook chains in a disposable project, never the Desktop app.
# FM_AFK_DESKTOP_LIVE=1 enables credentialed D1/D2 CLI coverage.
# FM_AFK_LIVE_REPORT_DIR optionally retains transcripts outside the fixture.
# shellcheck disable=SC2016 # The model and child shell interpret these literals.
set -eu
# shellcheck source=tests/afk-fixture-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/afk-fixture-helpers.sh"
fm_afk_fixture_prepare
if [ "${FM_AFK_FIXTURE_PROBE:-0}" = 1 ]; then fm_afk_fixture_probe; exit 0; fi
if [ "${FM_AFK_DESKTOP_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_AFK_DESKTOP_LIVE=1 for isolated Claude away hook chains'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=$(mktemp -d "$ROOT/.afk-desktop-live.XXXXXX")
trap 'rm -rf "${LAB:?}"/project "${LAB:?}"/home; rmdir "$LAB"' EXIT
PROJECT="$LAB/project"
mkdir -p "$PROJECT/bin" "$PROJECT/.claude" "$LAB/home"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
fm_afk_fixture_install "$PROJECT"
cp "$ROOT/bin/fm-supervise-daemon.sh" "$PROJECT/bin/fm-supervise-daemon-real.sh"
git init -q "$PROJECT"
ln -s CLAUDE.md "$PROJECT/AGENTS.md"
cat > "$PROJECT/CLAUDE.md" <<'MD'
This is an isolated live test, with fake workers only.
Every assistant text block while away must be exactly ·, with no whitespace or other text.
Use only the commands in the test prompt and marked hook reminders.
FM_HOME names a separate fixture home; every state lookup must use "$FM_HOME/state", never project-relative state/.
While away, complete tool work and end each turn with exactly · as its only visible text.
This silent-away rule supersedes standing progress and acknowledgment conventions.
MD
cat > "$PROJECT/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"},{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-claude-stop-autoarm.sh","asyncRewake":true,"timeout":20}]}]}}
JSON
cat > "$PROJECT/bin/fm-supervise-daemon.sh" <<'SH'
#!/usr/bin/env bash
n=$(cat "$FM_HOME/state/cycles" 2>/dev/null || echo 0)
n=$((n + 1)); echo "$n" > "$FM_HOME/state/cycles"
if [ "$n" -gt "$FM_TEST_CYCLES" ]; then
  printf 'fixture chain complete\n' > "$FM_HOME/state/.captain-hold"
  exit 0
fi
if [ "$FM_TEST_CASE" = D2 ]; then
  exec "$(dirname "$0")/fm-supervise-daemon-real.sh" --stop-hook
fi
touch "$FM_HOME/state/ready.$n"
while [ ! -e "$FM_HOME/state/released.$n" ]; do sleep "${FM_AFK_FIXTURE_POLL_SECS:-0.01}"; done
printf 'check: fixture actionable event %s\n' "$n"
SH
chmod +x "$PROJECT/bin/fm-supervise-daemon.sh"
cat > "$PROJECT/bin/live-cli-driver.py" <<'PY'
import os, subprocess, time
from pathlib import Path
home=Path(os.environ['FM_HOME']); cycles=int(os.environ['FM_TEST_CYCLES'])
p=subprocess.Popen(['claude','-p',os.environ['FM_TEST_PROMPT'],'--dangerously-skip-permissions','--output-format','stream-json','--verbose'])
released=0
deadline=time.monotonic()+float(os.environ.get('FM_AFK_LIVE_TIMEOUT_SECS','300'))
try:
    while p.poll() is None:
        assert time.monotonic()<deadline, 'live CLI fixture exceeded its configurable deadline'
        if os.environ['FM_TEST_CASE']=='D1' and released<cycles and (home/f'state/ready.{released+1}').exists():
            released+=1
            (home/f'state/released.{released}').touch()
        time.sleep(float(os.environ.get('FM_AFK_FIXTURE_POLL_SECS','0.01')))
    assert p.returncode==0, f'Claude CLI failed with exit {p.returncode}'
    if os.environ['FM_TEST_CASE']=='D1':
        assert released==cycles, f'not all explicit event latches released: {released}/{cycles}'
finally:
    if p.poll() is None:
        p.terminate(); p.wait()
PY
for scenario in D1 D2; do
  HOME_DIR="$LAB/home/$scenario"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
  date +%s > "$HOME_DIR/state/.afk"
  printf 'none\t-\tdesktop\n' > "$HOME_DIR/state/.afk-daemon-terminal"
  cycles=10
  [ "$scenario" != D2 ] || cycles=2
  transcript="$HOME_DIR/transcript.jsonl"
  (
    cd "$PROJECT"
    FM_HOME="$HOME_DIR" FM_TEST_CASE="$scenario" FM_TEST_CYCLES="$cycles" \
      FM_AFK_RENEW_SECS=1 FM_AFK_TICK_SECS=0.01 FM_HOUSEKEEPING_TICK=0 \
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
      FM_TEST_PROMPT='FM_HOME is the separate fixture home provided in your environment. Inspect only "$FM_HOME/state" for presence and hold state, never project-relative state. Run bin/fm-lock.sh with Bash first, then test -f "$FM_HOME/state/.afk" with Bash to confirm away mode. Then stop with exactly · as the only visible text. Each Stop hook feedback containing the away-supervisor envelope is internal, never a captain return. On each such wake run bin/fm-wake-drain.sh and bin/fm-afk-launch.sh acknowledge with Bash, then stop with exactly · as the only visible text. Do not run an arm command. These are fake fixture workers. Do not inspect or change anything outside this fixture home. When the fixture global captain hold appears, end with exactly · as the only visible text; there is no real captain return in this test.' \
      python3 bin/live-cli-driver.py
  ) > "$transcript" 2>&1
  if [ -n "${FM_AFK_LIVE_REPORT_DIR:-}" ]; then
    mkdir -p "$FM_AFK_LIVE_REPORT_DIR"
    cp "$transcript" "$FM_AFK_LIVE_REPORT_DIR/$scenario.jsonl"
  fi
  actual=$(cat "$HOME_DIR/state/cycles" 2>/dev/null || echo 0)
  if [ "$actual" -ne $((cycles + 1)) ]; then
    printf 'not ok - %s: expected %s hook cycles plus quiet retirement, got %s\n' "$scenario" "$cycles" "$actual"
    exit 1
  fi
  python3 - "$transcript" "$cycles" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.startswith('{')]
texts = [part['text'] for row in rows if row.get('type') == 'assistant'
         for part in row.get('message', {}).get('content', [])
         if part.get('type') == 'text']
demand = 'Your previous response had no visible output. Please continue and produce a user-visible response.'
user_bodies = [row.get('message', {}).get('content', '') for row in rows if row.get('type') == 'user']
demands = sum(demand in (body if isinstance(body, str) else json.dumps(body)) for body in user_bodies)
print(f'assistant text blocks: {len(texts)}; host no-visible-output demands: {demands}; transcript: {sys.argv[1]}')
assert texts and all(text == '·' for text in texts), f'away text blocks must each equal ·: {texts}'
assert demands < 64, f'host no-visible-output demands did not drop from no-mark baseline 64: {demands}'
PY
  printf 'ok - %s: Claude %s completed %s silent hook continuations\n' "$scenario" "$(claude --version)" "$cycles"
done
