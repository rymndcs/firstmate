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
function run(command, {cwd = `${tmp}/task`, stdin = false, claude = true, input, env = {}} = {}) {
  const args = ['--home', `${tmp}/home`];
  if (claude) args.push('--claude');
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
  } else assert.equal(result.stderr, '', `stderr: ${command}`);
  checks++;
}
const denied = [
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
  'kill $PIDS', 'kill "$pid"', 'kill -9 0', 'kill -- -123', 'kill -1',
  'kill 123 $(pgrep agent)', 'kill 12$(pgrep agent)', 'kill 123*', 'kill -s', 'kill -s -- 123',
  'kill -n "bad?" 123', 'sudo --unknown pkill agent', 'eval "$CMD"', 'pkill -g 999 agent', 'pkill -P 999 agent',
  'pkill agent -g 0', 'p"kill" agent', "p$'\\x6b'ill agent",
  'pkill \\agent', 'pkill "unterminated', 'echo "unterminated', 'for x in 1; do echo pkill; done',
  'K=pkill; $K agent', "bash -c \"$CMD\" # pkill", 'builtin killall agent',
  'find . -exec killall agent \\;', '! pkill agent',
  "printf pkill | sh", "xargs sh -c 'pkill agent'",
  "for x in a; do p$'\\x6b'ill agent; done",
];
const allowed = [
  'git status', 'kill 123', '/bin/kill -TERM 123 456', 'command kill -9 -- 123',
  'sudo -n kill -s TERM 123', 'kill -0 123', 'kill -l',
  'pgrep -fl agent', 'pgrep agent | cat', "echo 'pkill -f agent'",
  "printf '%s\\n' 'killall agent'", 'rg pkill file', '# pkill agent\ngit status',
  "cat <<'EOF'\npkill agent\nEOF\n", "bash -c 'echo pkill'",
];
denied.push('('.repeat(14) + 'true' + ')'.repeat(14));
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
console.log(`ok - ${checks} process guard public-entry assertions`);
JS
