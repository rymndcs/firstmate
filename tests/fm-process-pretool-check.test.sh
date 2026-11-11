#!/usr/bin/env bash
# Behavior tests for the scoped process-kill guard's public hook transport.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TASK_TMP=$(fm_test_tmproot fm-process-pretool)
FM_TEST_CLEANUP_DIRS+=("$TASK_TMP")
mkdir -p "$TASK_TMP/home/state" "$TASK_TMP/task/sub" "$TASK_TMP/task-neighbor" "$TASK_TMP/user/.no-mistakes/worktrees/run" "$TASK_TMP/ordinary"
printf 'worktree=%s\n' "$TASK_TMP/task" > "$TASK_TMP/home/state/task.meta"
export PROCESS_GUARD_ROOT="$ROOT" PROCESS_GUARD_TMP="$TASK_TMP"

node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { symlinkSync, mkdirSync, writeFileSync, copyFileSync, chmodSync } from 'node:fs';
const root = process.env.PROCESS_GUARD_ROOT;
const tmp = process.env.PROCESS_GUARD_TMP;
const check = `${root}/bin/fm-process-pretool-check.sh`;
let checks = 0;
function run(command, {cwd = `${tmp}/task`, stdin = false, input, env = {}} = {}) {
  const args = ['--home', `${tmp}/home`];
  if (!stdin) args.push('--command', command);
  const result = spawnSync('bash', [check, ...args], {
    cwd, encoding: 'utf8', input: input ?? JSON.stringify({cwd, tool_name: 'Bash', tool_input: {command}}),
    env: {...process.env, HOME: `${tmp}/user`, ...env},
  });
  return result;
}
function expect(command, denied, options = {}) {
  const result = run(command, options);
  assert.equal(result.status, denied ? 2 : 0, `${command}: ${result.stderr}`);
  assert.equal(result.stdout, '', `stdout: ${command}`);
  if (denied) {
    const error = JSON.parse(result.stderr);
    assert.equal(error.hookSpecificOutput.permissionDecision, 'deny');
    assert.match(error.systemMessage, /explicit.*PID/i);
    assert.match(error.systemMessage, /grep -e 'pk''ill'/);
  } else assert.equal(result.stderr, '', `stderr: ${command}`);
  checks++;
}
const denied = [
  'echo pkill',
  'pkill -f agent -n -P 123', 'pkill -f agent', '/usr/bin/pkill agent',
  'command pkill agent', 'sudo -n pkill agent', 'env X=1 pkill agent',
  'killall agent', '/usr/bin/killall -9 agent', 'command killall agent',
  'kill $(pgrep -f agent)', 'kill "$(pgrep agent)"', 'kill `pgrep agent`',
  'pgrep -f agent | xargs kill', 'pgrep agent | xargs -r /bin/kill -9',
  'pgrep agent | while read -r pid; do kill "$pid"; done',
  'for x in agent; do pkill -f "$x"; done', 'if true; then killall agent; fi',
  '(pkill agent)', '{ killall agent; }', 'echo "$(pkill agent)"',
  "bash -lc 'pkill agent'", "eval 'killall agent'", "env -S 'pkill agent'",
  "bash <<'EOF'\npkill agent\nEOF\n", "bash <<< 'pkill agent'",
  'sudo --unknown pkill agent', 'pkill -g 999 agent', 'pkill -P 999 agent',
  'pkill agent -g 0', 'pkill "unterminated', 'for x in 1; do echo pkill; done',
  'K=pkill; $K agent', "bash -c \"$CMD\" # pkill", 'builtin killall agent',
  'find . -exec killall agent \\;', '! pkill agent',
  'printf pkill | sh', "xargs sh -c 'pkill agent'",
  'cat > notes.md <<EOF\nUse `pkill -f agent` to stop it\nEOF\n',
  'cat <<EOF\n$(pkill -f agent)\nEOF\n', 'git commit -F - <<EOF\nfix: `killall agent`\nEOF\n',
  'cat <<-EOF\n\t$(killall agent)\n\tEOF\n',
  'nice pkill -f agent', 'setsid pkill agent', '/usr/bin/time pkill -f agent', 'stdbuf -o0 killall agent',
  'doas pkill agent', "watch -n1 'pkill agent'", 'pgrep agent | parallel kill', 'nice -n 5 sudo pkill agent',
  'command -p pkill agent', 'pgrep agent | xargs kill',
  "pgrep agent | xargs sh -c 'kill \"$@\"' _", 'echo pkill | xargs -I CMD CMD agent', 'echo pkill | xargs sh',
  'find . -name x -exec pkill agent \\;', 'find . -execdir /usr/bin/killall agent \\;',
  'K=pkill; find . -exec $K \\;',
  'arch -arm64 pkill -f agent', 'xcrun pkill agent', 'sandbox-exec -n no-network pkill agent', 'bundle exec pkill agent',
  'uv run pkill agent', 'npx pkill agent', 'mise exec -- pkill agent', 'screen -dm pkill agent', 'tmux new -d pkill agent',
  'ssh localhost pkill agent', 'echo pkill | xargs arch', 'arch kill $(pgrep agent)', "watch 'kill $(pgrep agent)'",
  'command env -v pkill agent', 'command timeout -v 5 pkill agent', 'env -u command -v pkill agent',
  'cat <<EOF\n$\\\n(pkill agent)\nEOF\n',
  'bash <(echo pkill agent)', 'source <(echo pkill agent)', 'sh -s -- < <(echo pkill agent)',
  "dash -c 'pkill agent'", "ksh -c 'pkill agent'", "fish -c 'pkill agent'", 'echo pkill agent | dash',
  'bash < pkill-steps.sh', 'CMD=pkill; bash <<EOF\n$CMD agent\nEOF\n', "bash -c '$1 agent' _ pkill",
  "find . -name '*killall*' -exec wc -l {} +", "find . -name '*pkill*' -delete", 'rg pkill bin | sort',
  "git commit -m 'drop pkill'", 'man -P pkill ls', 'git grep -O pkill agent', 'echo pkill | cat | sh', 'echo pkill | (sh)',
  'pgrep agent | xargs kill 123', 'pgrep agent | xargs nice kill 123', 'rg --pre pkill agent',
  "git --paginate -c 'core.pager=pkill -f agent' log -1",
  "git -c 'core.pager=killall agent' --paginate show --stat",
  "echo 'pkill -f agent'", "printf '%s\\n' 'killall agent'", 'rg pkill file', '# pkill agent\ngit status',
  "cat <<'EOF'\npkill agent\nEOF\n", "bash -c 'echo pkill'", "find . -name '*pkill*'",
  'rg -l killall | xargs wc -l', 'cat bin/pkill-notes.md', 'whereis pkill', 'man pkill',
  'git log --grep pkill', 'git -C repo show HEAD:bin/pkill.sh', 'git grep killall', 'echo pkill | cat',
  'echo pgrep; echo kill', "printf 'pgrep kill'", 'kill 123 # pgrep',
  'command -v pkill; true', 'command -V killall && true', 'type pkill | sh', 'which killall > found',
  'command -v pkill extra', 'type -a pkill', 'which pkill killall', 'sudo command -v pkill',
  'command -v pkill\necho ok', 'NAME=pkill command -v pkill',
];
const allowed = [
  'git status', 'kill 123', '/bin/kill -TERM 123 456', 'command kill -9 -- 123',
  'sudo -n kill -s TERM 123', 'kill -0 123', 'kill -l', 'kill -- -123',
  'pgrep -fl agent', 'pgrep agent | cat', 'nice -n 5 kill -TERM 123', 'ls | xargs arch',
  'command -v pkill', 'command -V pkill', 'command -v killall', 'command -V killall',
  'type pkill', 'type killall', 'which pkill', 'which killall', '  command -v pkill  ',
  "grep -e 'pk''ill' file", "rg 'kill''all' file", "grep -e 'pg''rep' -e 'ki''ll' file",
  'echo skill', 'echo pkilling', 'echo killalligator', 'echo pgrep; echo skilled',
];
for (const stdin of [false, true]) {
  for (const command of denied) expect(command, true, {stdin});
  for (const command of allowed) expect(command, false, {stdin});
}
expect('killall agent', true, {cwd: `${tmp}/task/sub`});
for (const cwd of [`${tmp}/ordinary`, `${tmp}/home`, `${tmp}/task-neighbor`]) {
  expect('pkill agent', false, {cwd});
  expect('', false, {cwd, stdin: true, input: 'broken JSON'});
}
expect('pkill agent', true, {cwd: `${tmp}/user/.no-mistakes/worktrees/run`});
expect('', true, {stdin: true});
expect('', true, {stdin: true, input: 'broken JSON'});
expect('', true, {stdin: true, input: '{"tool_input":{"command":42}}'});
expect('', true, {stdin: true, input: ''});
symlinkSync(`${tmp}/task`, `${tmp}/alias`);
expect('pkill agent', true, {cwd: `${tmp}/alias`});
mkdirSync(`${tmp}/sm/state`, {recursive: true});
mkdirSync(`${tmp}/sm-task`);
writeFileSync(`${tmp}/home/state/second.meta`, `kind=secondmate\nhome=${tmp}/sm\nworktree=${tmp}/sm\n`);
writeFileSync(`${tmp}/sm/state/worker.meta`, `worktree=${tmp}/sm-task\n`);
expect('pkill agent', true, {cwd: `${tmp}/sm-task`});
expect('pkill agent', false, {cwd: `${tmp}/sm`});
mkdirSync(`${tmp}/user/.no-mistakes-neighbor`);
expect('pkill agent', false, {cwd: `${tmp}/user/.no-mistakes-neighbor`});
mkdirSync(`${tmp}/no-node`);
symlinkSync('/bin/bash', `${tmp}/no-node/bash`);
symlinkSync('/usr/bin/dirname', `${tmp}/no-node/dirname`);
for (const cwd of [`${tmp}/task`, `${tmp}/ordinary`]) {
  const result = run('pkill agent', {cwd, env: {PATH: `${tmp}/no-node`}});
  assert.equal(result.status, cwd.endsWith('/task') ? 2 : 0, result.stderr);
  if (result.status === 2) assert.match(result.stderr, /explicit.*PID/i);
  else assert.equal(result.stderr, '');
  checks++;
}
writeFileSync(`${tmp}/no-node/node`, '#!/bin/bash\nprintf invalid-response\n');
chmodSync(`${tmp}/no-node/node`, 0o755);
const invalid = run('pkill agent', {env: {PATH: `${tmp}/no-node`}});
assert.equal(invalid.status, 2);
assert.match(invalid.stderr, /explicit.*PID/i);
checks++;
mkdirSync(`${tmp}/missing-policy/bin`, {recursive: true});
copyFileSync(check, `${tmp}/missing-policy/bin/fm-process-pretool-check.sh`);
const missing = spawnSync('/bin/bash', [`${tmp}/missing-policy/bin/fm-process-pretool-check.sh`, '--home', `${tmp}/home`, '--command', 'pkill agent'], {cwd: `${tmp}/task`, encoding: 'utf8'});
assert.equal(missing.status, 2);
assert.match(missing.stderr, /explicit.*PID/i);
checks++;
const help = spawnSync('bash', [check, '--help'], {encoding: 'utf8'});
assert.equal(help.status, 0);
const helpLines = help.stdout.trimEnd().split('\n');
assert.match(helpLines[0], /^Scoped process-kill PreToolUse transport/);
assert.match(helpLines.at(-1), /^See docs\/process-kill-guard\.md/);
assert.doesNotMatch(help.stdout, /set -u/);
checks++;
console.log(`ok - ${checks} process guard public-entry assertions`);
JS
