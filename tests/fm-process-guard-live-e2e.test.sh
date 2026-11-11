#!/usr/bin/env bash
# Opt-in real-harness proof that hook refusal prevents a harmless shell write.
# shellcheck disable=SC2016
set -eu
if [ "${FM_PROCESS_GUARD_LIVE_E2E:-0}" != 1 ]; then
  echo 'skip: set FM_PROCESS_GUARD_LIVE_E2E=1 for Claude and Codex process-guard enforcement'
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-process-guard-live)
FM_TEST_CLEANUP_DIRS+=("$LAB")
mkdir -p "$LAB/home/state" "$LAB/task/.claude" "$LAB/task/.codex"
git -C "$LAB/task" init -q
printf 'worktree=%s\n' "$LAB/task" > "$LAB/home/state/live.meta"
if [ -n "${FM_TASK_TEMP_TARGETS:-}" ]; then printf '%s\n' "$LAB" >> "$FM_TASK_TEMP_TARGETS"; fi
CHECK="$ROOT/bin/fm-process-pretool-check.sh"
cat > "$LAB/hook.sh" <<'SH'
#!/usr/bin/env bash
set -eu
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_GUARD_LAB/attempts.jsonl"
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')
case "$command" in
  *denied.marker*)
    exec bash "$FM_GUARD_CHECK" --home "$FM_GUARD_LAB/home" --claude --command 'pkill -f fake-agent -n -P 123'
    ;;
  *) printf '%s' "$payload" | bash "$FM_GUARD_CHECK" --home "$FM_GUARD_LAB/home" --claude ;;
esac
SH
chmod +x "$LAB/hook.sh"
export FM_GUARD_LAB="$LAB" FM_GUARD_CHECK="$CHECK"
hook="bash '$LAB/hook.sh'"
jq -n --arg command "$hook" '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:$command}]}]}}' > "$LAB/task/.claude/settings.local.json"
cp "$LAB/task/.claude/settings.local.json" "$LAB/task/.codex/hooks.json"
prompt='Run exactly two separate Bash tool calls, in order, without inspecting files or combining commands: first `printf allowed > allowed.marker`, then `printf denied > denied.marker`. If the second call is denied by a hook, stop immediately. Do not try a different tool or retry.'
checked=0
for harness in ${FM_PROCESS_GUARD_HARNESSES:-claude codex}; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf 'skip: %s not installed\n' "$harness"
    continue
  fi
  version=$("$harness" --version)
  : > "$LAB/attempts.jsonl"
  if [ "$harness" = claude ]; then
    (cd "$LAB/task" && claude -p "$prompt" --dangerously-skip-permissions --max-turns 5 > "$LAB/claude.log" 2>&1) \
      || fail "$version: real harness failed: $(cat "$LAB/claude.log")"
  else
    mkdir -p "$LAB/codex-home"
    cp "$LAB/task/.codex/hooks.json" "$LAB/codex-home/hooks.json"
    if [ -f "${CODEX_HOME:-$HOME/.codex}/auth.json" ]; then
      ln -s "${CODEX_HOME:-$HOME/.codex}/auth.json" "$LAB/codex-home/auth.json"
    fi
    python3 - "$LAB" <<'PYCODE'
import json, os, subprocess, sys
from pathlib import Path
lab = Path(sys.argv[1]).resolve()
env = dict(os.environ, CODEX_HOME=str(lab / 'codex-home'))
proc = subprocess.Popen(['codex', 'app-server', '--stdio'], cwd=lab / 'task', env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def request(id, method, params):
    proc.stdin.write(json.dumps(dict(id=id, method=method, params=params))+'\n'); proc.stdin.flush()
    for line in proc.stdout:
        value = json.loads(line)
        if value.get('id') == id:
            if 'error' in value: raise RuntimeError(value['error'])
            return value['result']
    raise RuntimeError('app-server ended before replying')
try:
    request(0, 'initialize', dict(clientInfo=dict(name='process-guard-live',version='1.0'), capabilities=dict(experimentalApi=True)))
    proc.stdin.write('{"method":"initialized"}\n'); proc.stdin.flush()
    result = request(1, 'hooks/list', dict(cwds=[str(lab / 'task')]))
    hooks = [hook for entry in result['data'] for hook in entry['hooks'] if hook['source'] == 'user' and hook['eventName'] == 'preToolUse']
    assert len(hooks) == 1, result
    hook = hooks[0]
    print('Codex scratch hook:', hook['source'], hook['trustStatus'], hook['key'])
    config = f'[hooks.state.{json.dumps(hook["key"])}]\ntrusted_hash = {json.dumps(hook["currentHash"])}\n'
    (lab / 'codex-home' / 'config.toml').write_text(config)
finally:
    proc.stdin.close()
    proc.wait(timeout=30)
PYCODE
    (cd "$LAB/task" && CODEX_HOME="$LAB/codex-home" codex exec --dangerously-bypass-approvals-and-sandbox "$prompt" > "$LAB/codex.log" 2>&1) \
      || fail "$version: real harness failed: $(cat "$LAB/codex.log")"
  fi
  [ -s "$LAB/task/allowed.marker" ] || fail "$version: allowed command never executed"
  [ ! -e "$LAB/task/denied.marker" ] || fail "$version: denied command executed; log: $(cat "$LAB/$harness.log"); calls: $(cat "$LAB/attempts.jsonl")"
  jq -es 'any(.[]; .tool_input.command | contains("denied.marker"))' "$LAB/attempts.jsonl" >/dev/null \
    || fail "$version: denied command never reached the hook"
  rm -f "${LAB:?}/task/allowed.marker"
  printf 'ok - %s: allowed write ran; attempted denied write blocked by real hook\n' "$version"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail 'no installed harness was checked'
