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
import json, os, sys
if os.environ.get('FAKE_REVIEW_FAIL'):
    print('deliberate role failure', file=sys.stderr)
    sys.exit(23)
if not os.environ.get('FAKE_REVIEW_EMPTY'):
    print(json.dumps({'runtime': os.path.basename(sys.argv[0]), 'args': sys.argv[1:]}))
PY
cp "$FAKEBIN/codex" "$FAKEBIN/claude"
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_REVIEW_DATE"
SH
chmod +x "$FAKEBIN/"*

launch() {
  (cd "$TASK_REPO" && env HOME="$FIXTURE_HOME" PATH="$FAKEBIN:$PATH" \
    FAKE_REVIEW_DATE="${FAKE_REVIEW_DATE:-2026-10-06}" "$ROOT/bin/fm-review-round.sh" "$@")
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

assert_capture() {
  python3 - "$1" "$2" "$3" "$FIXTURE_HOME" "$INPUT" <<'PY'
import json, pathlib, sys
output, runtime, role, home, input_file = sys.argv[1:]
data = json.loads(pathlib.Path(output).read_text())
assert data['runtime'] == runtime, data
args = data['args']
if runtime == 'codex':
    expected = ['exec', '--model', 'gpt-6.1-sol', '-c', 'model_reasoning_effort="high"',
                '--dangerously-bypass-approvals-and-sandbox', '--']
else:
    expected = ['-p', '--model', 'opus', '--dangerously-skip-permissions', '--']
prompt = (pathlib.Path(home) / '.claude/agents' / f'adv-{role}.md').read_text()
prompt += '\n\n# This round\n' + pathlib.Path(input_file).read_text()
assert args == expected + [prompt.rstrip('\n')], args
assert args[-1].startswith('---\n'), args
PY
}

for day in 2026-10-04 2026-10-11 2026-10-12; do
  runtime=codex
  [ "$day" != 2026-10-12 ] || runtime=claude
  for role in reviewer fixer; do
    output="$TASK_DIR/$day-$role.out"
    FAKE_REVIEW_DATE="$day" launch "$role" --round 1 --in "$INPUT" --out "$output" >/dev/null
    assert_capture "$output" "$runtime" "$role" || fail "$day/$role prompt or runtime differs"
  done
done
pass 'review-round: both roles preserve frontmatter after -- and honor the inclusive dated runtime rule'

output=$(launch reviewer --round 2 --in "$INPUT")
[ "$output" = "$TASK_DIR/round-2-reviewer.out" ] || fail 'default output is not next to the input'
assert_capture "$output" codex reviewer || fail 'default output lost the prompt'
pass 'review-round: default output is a fresh role/round file next to the input'

rc=0
out=$(FAKE_REVIEW_FAIL=1 launch fixer --round 3 --in "$INPUT" 2>&1) || rc=$?
expect_code 23 "$rc" 'role failure must propagate'
assert_contains "$out" 'fixer round 3 failed (codex exit 23)' 'failure lacked role and exit code'
assert_contains "$out" "$TASK_DIR/round-3-fixer.out" 'failure lacked output path'
assert_grep 'deliberate role failure' "$TASK_DIR/round-3-fixer.out" 'role stderr was lost'
rc=0
out=$(FAKE_REVIEW_EMPTY=1 launch reviewer --round 4 --in "$INPUT" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'empty successful response passed'
assert_contains "$out" 'empty output' 'empty output lacked diagnostic'
pass 'review-round: failed and empty roles cannot pass as empty reviews'

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
