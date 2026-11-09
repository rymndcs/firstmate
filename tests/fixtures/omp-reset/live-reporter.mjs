import assert from 'node:assert/strict';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
const [root, lab] = process.argv.slice(2);
const cases = process.env.FM_RESET_REPORTER_CASE ? [process.env.FM_RESET_REPORTER_CASE] : ['error', 'empty', 'reuse', 'optout'];
for (const mode of cases) {
  const home = `${lab}/${mode}`;
  const bin = `${home}/bin`;
  mkdirSync(`${home}/tmp`, { recursive: true });
  mkdirSync(bin);
  const stub = (name, body) => writeFileSync(`${bin}/${name}`, `#!/usr/bin/env bash\nset -eu\n${body}\n`, { mode: 0o755 });
  stub('omp', `
[ "$#" -eq 1 ] && [ "$1" = --version ] || exit 91
printf 'version\\n' >> "$REPORT_HOME/calls"
case "$REPORT_MODE" in
  error) printf 'untrusted-version\\n'; exit 7 ;;
  empty) exit 0 ;;
esac
[ "$(wc -l < "$REPORT_HOME/calls" | tr -d ' ')" -eq 1 ] || exit 8
printf 'omp-reporter-fixture-1\\n'`);
  stub('node', `printf 'model-flow\\n' >> "$REPORT_HOME/launches"`);
  stub('git', `
[ "$1" = clone ] || exit 92
mkdir -p "$4/tests/fixtures/omp-reset"
: > "$4/tests/fixtures/omp-reset/live-driver.ts"`);
  stub('python3', `cat >/dev/null; printf '{}\\n' > "$4"`);
  stub('sleep', ':');
  stub('tmux', `
printf '%s\\n' "$*" >> "$REPORT_HOME/launches"
case "$3" in
  has-session) exit 1 ;;
  capture-pane) printf 'RESET_FAILURE_CHAT_PROOF\\n' ;;
  new-session)
    project=
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -c ]; then project=$2; break; fi
      shift
    done
    mode=$(basename "$project" -project)
    fixture_home=$(dirname "$project")/$mode-home
    mkdir -p "$fixture_home/state/.watch.lock"
    printf '%s\\n' "$REPORT_PARENT_PID" > "$fixture_home/state/.watch.lock/pid"
    : > "$fixture_home/state/.wake-queue"
    if [ "$mode" = away ]; then
      cat > "$fixture_home/events.jsonl" <<'JSON'
{"kind":"start"}
{"kind":"armed"}
{"kind":"startup"}
{"kind":"visible","text":"·"}
{"kind":"inspect","jobs":{"running":[{}]}}
JSON
    else
      cat > "$fixture_home/events.jsonl" <<'JSON'
{"kind":"start"}
{"kind":"armed","status":"watcher: started pid=999999999 (beacon fresh)"}
{"kind":"armed","status":"watcher: started pid=1 (beacon fresh)"}
{"kind":"startup"}
{"kind":"startup"}
{"kind":"switch"}
{"kind":"wake-drained"}
{"kind":"reset-tool","input":{"action":"prepare"}}
{"kind":"reset-tool","input":{"action":"ready"}}
{"kind":"inspect","jobs":{"running":[{}]}}
{"kind":"bash","input":{"command":"[ -f config/x-mode.env ] && . config/x-mode.env; exec bin/fm-watch-arm.sh","async":true,"timeout":0}}
{"kind":"error-ui"}
{"kind":"recovery","editor":"Wai"}
JSON
    fi
    ;;
esac`);
  const result = spawnSync('bash', [process.env.FM_RESET_LIVE_SCRIPT ?? `${root}/tests/fm-omp-reset-live-e2e.test.sh`], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, TMPDIR: `${home}/tmp`,
      REPORT_HOME: home, REPORT_MODE: mode, REPORT_PARENT_PID: String(process.pid),
      FM_OMP_RESET_LIVE: mode === 'optout' ? '0' : '1', FM_OMP_RESET_FLOW_ONLY: '0',
      FM_OMP_RESET_EVIDENCE: '', FM_OMP_RESET_TEMP_REGISTRY: '', FM_OMP_RESET_LIVE_POLLS: '1' },
    encoding: 'utf8',
  });
  const output = result.stdout + result.stderr;
  if (mode === 'optout') {
    assert.equal(result.status, 0, output);
    assert.match(output, /skip: set FM_OMP_RESET_LIVE=1/);
    assert.equal(existsSync(`${home}/calls`), false, 'opt-out must not query an installed executable');
    assert.equal(existsSync(`${home}/launches`), false, 'opt-out must not launch fixtures');
  } else if (mode === 'error' || mode === 'empty') {
    assert.equal(existsSync(`${home}/launches`), false, `${mode}: invalid version must stop before model or tmux launch; ${output}`);
    assert.notEqual(result.status, 0, `${mode}: invalid version must fail; ${output}`);
    assert.match(output, /not ok - .*omp.*version/i, `${mode}: report the version failure`);
    assert.doesNotMatch(output, /^ok -/m, 'invalid version must never print success');
    assert.equal(readFileSync(`${home}/calls`, 'utf8'), 'version\n', 'version failure must be checked exactly once');
  } else {
    assert.equal(result.status, 0, output);
    assert.equal(readFileSync(`${home}/calls`, 'utf8'), 'version\n', 'success must reuse the single prelaunch version capture');
    assert.match(output, /^ok - omp-reporter-fixture-1 normal error UI renders a visible chat line$/m);
    assert.match(output, /^ok - omp-reporter-fixture-1 normal integrated reset:/m);
    assert.match(output, /^ok - omp-reporter-fixture-1 away supervision:/m);
    assert.ok(readFileSync(`${home}/launches`, 'utf8').includes('model-flow'), 'neutral stub must reach the model-flow launch boundary');
  }
  console.log(`ok - native reporter portable ${mode}`);
}
