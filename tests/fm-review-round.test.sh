#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-round)
TASK_REPO="$TMP_ROOT/task"
FIXTURE_HOME="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$TASK_REPO" "$FIXTURE_HOME/.claude/agents" "$FAKEBIN"
git -C "$TASK_REPO" init -q
printf '%s\n' '---' 'name: adv-reviewer' '---' 'Reviewer instructions.' > "$FIXTURE_HOME/.claude/agents/adv-reviewer.md"
printf '%s\n' '---' 'name: adv-fixer' '---' 'Fixer instructions.' > "$FIXTURE_HOME/.claude/agents/adv-fixer.md"
cat > "$FAKEBIN/codex" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
data = {'runtime': os.path.basename(sys.argv[0]), 'args': args}
with open(os.environ['FAKE_REVIEW_CALLS'], 'a') as calls:
    calls.write(json.dumps(data) + '\n')
if os.environ.get('FAKE_REVIEW_FAIL'):
    print('deliberate role failure', file=sys.stderr)
    sys.exit(23)
mode = os.environ.get('FAKE_REVIEW_MODE', 'reply')
if mode == 'stderr':
    print('runtime ready; no assistant reply', file=sys.stderr)
    sys.exit(0)
if mode == 'events':
    print('tool/event log; no assistant reply')
    sys.exit(0)
if os.environ.get('FAKE_REVIEW_EMPTY'):
    sys.exit(0)
reply = '  \n\t\n' if mode == 'whitespace' else json.dumps(data)
if '--output-last-message' in args:
    pathlib.Path(args[args.index('--output-last-message') + 1]).write_text(reply)
    print('tool/event log, separate from final reply')
elif '--output-format' in args:
    result = {'type': 'result', 'is_error': False, 'result': reply}
    if mode == 'error-result':
        result['is_error'] = True
    if mode == 'tool-result':
        result['type'] = 'assistant'
    if mode == 'nonstring-result':
        result['result'] = {'text': reply}
    print(json.dumps(result))
else:
    print(reply)
print('runtime diagnostic, separate from final reply', file=sys.stderr)
PY
cp "$FAKEBIN/codex" "$FAKEBIN/claude"
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_REVIEW_DATE"
SH
chmod +x "$FAKEBIN/"*

: > "$TMP_ROOT/calls.jsonl"

call_count() { wc -l < "$TMP_ROOT/calls.jsonl"; }
assert_one_call() {
  [ "$(( $(call_count) - $1 ))" -eq 1 ] || fail 'expected exactly one fresh role invocation'
}

launch() {
  (cd "$TASK_REPO" && env HOME="$FIXTURE_HOME" PATH="$FAKEBIN:$PATH" \
    FAKE_REVIEW_CALLS="$TMP_ROOT/calls.jsonl" FAKE_REVIEW_DATE="${FAKE_REVIEW_DATE:-2026-10-06}" "$ROOT/bin/fm-review-round.sh" "$@")
}

out=$(launch --help)
assert_contains "$out" 'Codex gpt-6.1-sol (high reasoning) through 2026-10-11 inclusive; then Claude opus.' 'help omitted the current runtime rule'

TASK_DIR=$(launch --init first-task)
OTHER_DIR=$(launch --init first-task)
[ "$TASK_DIR" != "$OTHER_DIR" ] || fail '--init reused old task files'
REVIEW_ROOT=$(git -C "$TASK_REPO" rev-parse --absolute-git-dir)/adv-review-loop
printf 'old evidence\n' > "$REVIEW_ROOT/report.md"
printf 'previous task\n' > "$OTHER_DIR/round3.out"
INPUT="$TASK_DIR/round-1-reviewer.md"
printf 'Target: task\nLedger: empty\n' > "$INPUT"
pass 'review-round: each initialization gives the task fresh files'

DOTTED_DIR=$(launch --init release.v2) || fail 'valid dotted task id release.v2 was refused'
DOTTED_OTHER=$(launch --init release.v2) || fail 'second dotted task initialization failed'
[ "$DOTTED_DIR" != "$DOTTED_OTHER" ] || fail 'dotted task id reused its directory'
for id in '' . .. .hidden '../escape' 'path/task' 'task with spaces' 'task;command' "$(printf '%065d' 1)"; do
  rc=0
  out=$(launch --init "$id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe task id accepted: $id"
done
pass 'review-round: supported dotted IDs create unique directories; unsafe IDs are refused'

bad_reply_failures=0
for day in 2026-10-06 2026-10-12; do
  for role in reviewer fixer; do
    for mode in stderr whitespace events; do
      output="$TASK_DIR/$day-$role-$mode.out"
      before=$(call_count)
      rc=0
      out=$(FAKE_REVIEW_DATE="$day" FAKE_REVIEW_MODE="$mode" launch "$role" --round 1 --in "$INPUT" --out "$output" 2>&1) || rc=$?
      assert_one_call "$before"
      if [ "$rc" -eq 0 ]; then
        printf 'not ok - %s/%s accepted %s without a meaningful role reply\n' "$day" "$role" "$mode" >&2
        bad_reply_failures=$((bad_reply_failures + 1))
      else
        assert_contains "$out" 'role reply' 'missing reply refusal lacked a clear reason'
        assert_contains "$out" "$output.diagnostics" 'missing reply refusal did not name preserved diagnostics'
        case "$mode" in
          stderr) assert_grep 'runtime ready; no assistant reply' "$output.diagnostics" 'failure discarded stderr evidence' ;;
          events)
            evidence="$output.diagnostics"
            [ "$day" != 2026-10-12 ] || evidence="$output.runtime.json"
            assert_grep 'tool/event log; no assistant reply' "$evidence" 'failure discarded stdout evidence'
            ;;
          whitespace) [ -s "$output" ] || fail 'whitespace reply evidence was discarded' ;;
        esac
      fi
    done
  done
done
[ "$bad_reply_failures" -eq 0 ] || fail "$bad_reply_failures diagnostic-only/whitespace roles passed"
pass 'review-round: both runtimes and roles reject diagnostics, events, and whitespace as replies'

assert_capture() {
  python3 - "$1" "$2" "$3" "$FIXTURE_HOME" "$INPUT" "$TMP_ROOT/calls.jsonl" <<'PY'
import json, pathlib, sys
output, runtime, role, home, input_file, calls_file = sys.argv[1:]
data = json.loads(pathlib.Path(output).read_text())
assert data['runtime'] == runtime, data
args = data['args']
if runtime == 'codex':
    expected = ['exec', '--output-last-message', output, '--model', 'gpt-6.1-sol', '-c', 'model_reasoning_effort="high"',
                '--dangerously-bypass-approvals-and-sandbox', '--']
else:
    expected = ['-p', '--output-format', 'json', '--model', 'opus', '--dangerously-skip-permissions', '--']
prompt = (pathlib.Path(home) / '.claude/agents' / f'adv-{role}.md').read_text()
prompt += '\n\n# This round\n' + pathlib.Path(input_file).read_text()
assert args == expected + [prompt.rstrip('\n')], args
assert args[-1].startswith('---\n'), args
assert 'runtime diagnostic' not in pathlib.Path(output).read_text()
assert 'runtime diagnostic' in pathlib.Path(output + '.diagnostics').read_text()
if runtime == 'codex':
    assert 'tool/event log' in pathlib.Path(output + '.diagnostics').read_text()
else:
    raw = json.loads(pathlib.Path(output + '.runtime.json').read_text())
    assert raw['result'] == pathlib.Path(output).read_text().rstrip('\n')
calls = [json.loads(line) for line in pathlib.Path(calls_file).read_text().splitlines()]
matching = [call for call in calls if call == data]
assert len(matching) == 1, f'expected exactly one fresh {runtime}/{role} invocation, got {len(matching)}'
PY
}

for day in 2026-10-04 2026-10-11 2026-10-12; do
  runtime=codex
  [ "$day" != 2026-10-12 ] || runtime=claude
  for role in reviewer fixer; do
    printf 'Target: task\nLedger: empty\nRequested: %s/%s\n' "$day" "$role" > "$INPUT"
    output="$TASK_DIR/$day-$role.out"
    FAKE_REVIEW_DATE="$day" launch "$role" --round 1 --in "$INPUT" --out "$output" >/dev/null
    assert_capture "$output" "$runtime" "$role" || fail "$day/$role prompt or runtime differs"
  done
done
pass 'review-round: both roles preserve frontmatter after -- and honor the inclusive dated runtime rule'

printf 'Target: task\nLedger: empty\n' > "$INPUT"
output=$(launch reviewer --round 2 --in "$INPUT")
[ "$output" = "$TASK_DIR/round-2-reviewer.out" ] || fail 'default output is not next to the input'
assert_capture "$output" codex reviewer || fail 'default output lost the prompt'
pass 'review-round: default output is a fresh role/round file next to the input'

rc=0
out=$(FAKE_REVIEW_FAIL=1 launch fixer --round 3 --in "$INPUT" 2>&1) || rc=$?
expect_code 23 "$rc" 'role failure must propagate'
assert_contains "$out" 'fixer round 3 failed (codex exit 23)' 'failure lacked role and exit code'
assert_contains "$out" "$TASK_DIR/round-3-fixer.out" 'failure lacked output path'
assert_grep 'deliberate role failure' "$TASK_DIR/round-3-fixer.out.diagnostics" 'role stderr was lost'
rc=0
out=$(FAKE_REVIEW_EMPTY=1 launch reviewer --round 4 --in "$INPUT" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'empty successful response passed'
assert_contains "$out" 'role reply' 'empty output lacked diagnostic'
pass 'review-round: failed and empty roles cannot pass as empty reviews'

for role in reviewer fixer; do
  for day in 2026-10-06 2026-10-12; do
    output="$TASK_DIR/$day-$role-failed.out"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" FAKE_REVIEW_FAIL=1 launch "$role" --round 3 --in "$INPUT" --out "$output" 2>&1) || rc=$?
    assert_one_call "$before"
    expect_code 23 "$rc" 'both runtimes must propagate the role failure'
    assert_grep 'deliberate role failure' "$output.diagnostics" 'failed role lost its stderr'
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" launch "$role" --round 3 --in "$INPUT" --out "$output" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'retry overwrote failed evidence'
    [ "$(call_count)" -eq "$before" ] || fail 'retry launched over old evidence'
    [ "$(cat "$output.diagnostics")" = 'deliberate role failure' ] || fail 'retry altered preserved diagnostics'
  done
  for mode in error-result tool-result nonstring-result; do
    output="$TASK_DIR/claude-$role-$mode.out"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE=2026-10-12 FAKE_REVIEW_MODE="$mode" launch "$role" --round 4 --in "$INPUT" --out "$output" 2>&1) || rc=$?
    assert_one_call "$before"
    [ "$rc" -ne 0 ] || fail "Claude $role accepted $mode as the role reply"
    assert_contains "$out" 'no valid role reply' 'malformed result lacked a clear failure reason'
    [ -s "$output.runtime.json" ] || fail 'invalid Claude result evidence was discarded'
  done
  for day in 2026-10-06 2026-10-12; do
    output="$TASK_DIR/$day-$role-empty.out"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" FAKE_REVIEW_EMPTY=1 launch "$role" --round 4 --in "$INPUT" --out "$output" 2>&1) || rc=$?
    assert_one_call "$before"
    [ "$rc" -ne 0 ] || fail "$day/$role accepted an absent reply"
    assert_contains "$out" 'role reply' 'missing reply lacked a clear failure reason'
  done
done
pass 'review-round: failures preserve evidence; absent, erroneous, and non-reply results are refused'

for day in 2026-10-06 2026-10-12; do
  sidecars=(diagnostics)
  [ "$day" != 2026-10-12 ] || sidecars+=(runtime.json)
  for suffix in "${sidecars[@]}"; do
    for kind in existing symlink; do
      output="$TASK_DIR/$day-$suffix-$kind.out"
      sentinel="$TMP_ROOT/$day-$suffix-$kind.sentinel"
      printf 'previous diagnostics\n' > "$sentinel"
      if [ "$kind" = existing ]; then
        cp "$sentinel" "$output.$suffix"
      else
        ln -s "$sentinel" "$output.$suffix"
      fi
      before=$(call_count)
      rc=0
      out=$(FAKE_REVIEW_DATE="$day" launch reviewer --round 6 --in "$INPUT" --out "$output" 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || fail "existing $suffix $kind was overwritten"
      assert_contains "$out" 'evidence must be a new file' 'existing evidence refusal lacked a reason'
      [ "$(call_count)" -eq "$before" ] || fail 'existing diagnostics allowed a role launch'
      assert_absent "$output" 'evidence preflight created output before refusing'
      [ "$(cat "$output.$suffix")" = 'previous diagnostics' ] || fail 'sidecar evidence changed'
      [ "$(cat "$sentinel")" = 'previous diagnostics' ] || fail 'sidecar symlink target changed'
    done
  done
done
pass 'review-round: existing diagnostics and raw responses, including symlinks, survive without launching'


printf 'outside\n' > "$TMP_ROOT/outside.md"
ln -s "$TMP_ROOT/outside.md" "$TASK_DIR/linked-input.md"
ln -s "$TMP_ROOT" "$REVIEW_ROOT/outside-dir"
for input in "$TMP_ROOT/outside.md" "$REVIEW_ROOT/report.md" "$TASK_DIR/linked-input.md" "$REVIEW_ROOT/outside-dir/outside.md"; do
  rc=0
  out=$(launch reviewer --round 5 --in "$input" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe input accepted: $input"
  assert_contains "$out" 'input must be' 'input refusal lacked diagnostic'
done
pass 'review-round: outside inputs, root-level leftovers, and symlink escapes are refused'

ln -s "$TMP_ROOT/new-output" "$TASK_DIR/linked-output"
for output in "$INPUT" "$TASK_DIR/round-2-reviewer.out" "$TASK_DIR/linked-output" "$OTHER_DIR/new.out" "$TMP_ROOT/new.out"; do
  rc=0
  out=$(launch reviewer --round 6 --in "$INPUT" --out "$output" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe output accepted: $output"
done
[ "$(cat "$REVIEW_ROOT/report.md")" = 'old evidence' ] || fail 'old root report changed'
[ "$(cat "$OTHER_DIR/round3.out")" = 'previous task' ] || fail 'previous task evidence changed'
[ "$(cat "$INPUT")" = $'Target: task\nLedger: empty' ] || fail 'input was overwritten'
pass 'review-round: outputs cannot overwrite input, past output, or another task; prior evidence survives'
