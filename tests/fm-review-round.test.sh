#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-round)
TASK_REPO="$TMP_ROOT/task"
FIXTURE_HOME="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$TASK_REPO" "$FIXTURE_HOME/.claude/agents" "$FAKEBIN"
TASK_REPO=$(cd "$TASK_REPO" && pwd -P)
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
    encoded = json.dumps(result)
    extra = json.dumps({'type': 'result', 'is_error': True, 'result': 'failed'})
    outputs = {
        'success-error': encoded + '\n' + extra,
        'error-success': extra + '\n' + encoded,
        'duplicate-success': encoded + '\n' + encoded,
        'extra-object': encoded + '\n' + '{}',
        'object-first': '{}' + '\n' + encoded,
        'array': '[' + encoded + ']',
        'malformed': '{broken',
        'trailing': encoded + 'invalid trailing bytes',
        'missing-error-flag': json.dumps({'type': 'result', 'result': reply}),
        'scalar': json.dumps(reply),
        'null': 'null',
        'json-padding': '  \n' + encoded + '\n  \t',
    }
    print(outputs.get(mode, encoded))
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


legacy=$(launch --init caller-path-regression)
REVIEW_ROOT=$(git -C "$TASK_REPO" rev-parse --absolute-git-dir)/adv-review-loop
case "$legacy" in /*) legacy_dir=$legacy ;; *) legacy_dir="$REVIEW_ROOT/$legacy" ;; esac
printf 'Target: task\n' > "$legacy_dir/old-input.md"
cp "$legacy_dir/old-input.md" "$legacy_dir/-round.md"
legacy_launch() {
  (cd "$legacy_dir" && env HOME="$FIXTURE_HOME" PATH="$FAKEBIN:$PATH" \
    FAKE_REVIEW_CALLS="$TMP_ROOT/calls.jsonl" FAKE_REVIEW_DATE="$FAKE_REVIEW_DATE" "$ROOT/bin/fm-review-round.sh" "$@")
}
path_failures=0
for day in 2026-10-06 2026-10-12; do
  for role in reviewer fixer; do
    for value in "$legacy_dir/old-input.md" -round.md ./-round.md; do
      before=$(call_count)
      rc=0
      out=$(FAKE_REVIEW_DATE="$day" legacy_launch "$role" --round 1 --in "$value" --out "$legacy_dir/$day-$role-${#value}.out" 2>&1) || rc=$?
      if [ "$rc" -eq 0 ] || [[ "$out" != *'unknown option: --in'* ]] || [ "$(call_count)" -ne "$before" ]; then
        printf 'not ok - %s/%s caller --in path was not rejected at the interface: exit=%s %s\n' "$day" "$role" "$rc" "$out" >&2
        path_failures=$((path_failures + 1))
      fi
    done
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" legacy_launch "$role" --round 1 --out -round.out --in "$legacy_dir/old-input.md" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ] || [[ "$out" != *'unknown option: --out'* ]]; then
      printf 'not ok - %s/%s caller --out path was not rejected at the interface: %s\n' "$day" "$role" "$out" >&2
      path_failures=$((path_failures + 1))
    fi
  done
done
[ "$path_failures" -eq 0 ] || fail "$path_failures caller-path interfaces remain live"
pass 'review-round: removed caller paths are refused for both roles and runtimes, including leading-dash operands'

TOKEN=$(launch --init first-task)
OTHER_TOKEN=$(launch --init first-task)
[ "$TOKEN" != "$OTHER_TOKEN" ] || fail '--init reused old task files'
case "$TOKEN" in *'/'*) fail '--init returned a path instead of a token' ;; esac
TASK_DIR="$REVIEW_ROOT/$TOKEN"
OTHER_DIR="$REVIEW_ROOT/$OTHER_TOKEN"
[ -d "$TASK_DIR" ] && [ -d "$OTHER_DIR" ] || fail 'token does not identify an initialized task'
printf 'old evidence\n' > "$REVIEW_ROOT/report.md"
printf 'previous task\n' > "$OTHER_DIR/report.md"
DOTTED=$(launch --init release.v2)
[ "$DOTTED" != "$(launch --init release.v2)" ] || fail 'dotted task id reused its directory'
for id in '' . .. .hidden '../escape' 'path/task' 'task with spaces' 'task;command' "$(printf '%065d' 1)"; do
  rc=0
  out=$(launch --init "$id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe task id accepted: $id"
done
for size in 63 64; do launch --init "$(printf "%0${size}d" 1)" >/dev/null; done
DASH_TOKEN=$(launch --init -release.v2)
[ "$(launch reviewer --task "$DASH_TOKEN" --round 1 --path input)" = "$REVIEW_ROOT/$DASH_TOKEN/round-1-reviewer.md" ] || fail 'leading-dash task token broke derivation'
pass 'review-round: path-free unique tokens support dotted and boundary task IDs'

ROUND=0
prepare() {
  ROLE=$1
  ROUND=$((ROUND + 1))
  INPUT=$(launch "$ROLE" --task "$TOKEN" --round "$ROUND" --path input)
  OUTPUT=$(launch "$ROLE" --task "$TOKEN" --round "$ROUND" --path reply)
  [ "$INPUT" = "$TASK_DIR/round-$ROUND-$ROLE.md" ] || fail 'input query chose an unexpected destination'
  [ "$OUTPUT" = "$TASK_DIR/round-$ROUND-$ROLE.out" ] || fail 'reply query chose an unexpected destination'
  printf 'Target: task\nLedger: empty\nRequested: %s/%s\n' "$ROUND" "$ROLE" > "$INPUT"
}
run_role() { launch "$ROLE" --task "$TOKEN" --round "$ROUND"; }

before=$(call_count)
for role in reviewer fixer; do
  for kind in input reply report handoff summary; do
    out=$(launch "$role" --task "$TOKEN" --round 1 --path "$kind")
    case "$kind" in
      input) expected="$TASK_DIR/round-1-$role.md" ;;
      reply) expected="$TASK_DIR/round-1-$role.out" ;;
      report) expected="$TASK_DIR/report.md" ;;
      handoff) expected="$TASK_DIR/round-1-handoff.md" ;;
      summary) expected="$TASK_DIR/round-1-summary.report" ;;
    esac
    [ "$out" = "$expected" ] || fail "$kind query changed destination"
    assert_absent "$out" 'query reserved or wrote an artifact'
  done
done
[ "$(call_count)" -eq "$before" ] || fail 'query launched a role'
pass 'review-round: all artifact destinations are derived without writing or launching'

artifact_inventory() {
  python3 - "$1" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
entries = []
for path in sorted(root.rglob('*')):
    kind = 'symlink' if path.is_symlink() else 'directory' if path.is_dir() else 'file'
    content = str(path.readlink()) if kind == 'symlink' else path.read_bytes().hex() if kind == 'file' else ''
    entries.append([str(path.relative_to(root)), kind, content])
print(json.dumps(entries))
PY
}

query_failures=0
for day in 2026-10-06 2026-10-12; do
  for role in reviewer fixer; do
    for value in '' elsewhere; do
      for trailing in none valid; do
        for evidence in fresh existing; do
          query_token=$(launch --init query-regression)
          query_dir="$REVIEW_ROOT/$query_token"
          query_input=$(launch "$role" --task "$query_token" --round 1 --path input)
          query_reply=$(launch "$role" --task "$query_token" --round 1 --path reply)
          printf 'Target: query-only request\n' > "$query_input"
          if [ "$evidence" = existing ]; then
            for file in "$query_reply" "$query_reply.diagnostics" "$query_reply.runtime.json" \
              "$query_dir/report.md" "$query_dir/round-1-handoff.md" "$query_dir/round-1-summary.report"; do
              printf 'Previous evidence: %s\n\000\377' "$file" > "$file"
            done
          fi
          inventory_before=$(artifact_inventory "$query_dir")
          before=$(call_count)
          query_args=("$role" --task "$query_token" --round 1 --path "$value")
          [ "$trailing" != valid ] || query_args+=(--path input)
          rc=0
          out=$(FAKE_REVIEW_DATE="$day" launch "${query_args[@]}" 2>&1) || rc=$?
          inventory_after=$(artifact_inventory "$query_dir")
          if [ "$rc" -eq 0 ] || [[ "$out" != *'unknown path query'* ]] || \
            [ "$(call_count)" -ne "$before" ] || [ "$inventory_after" != "$inventory_before" ]; then
            printf 'not ok - %s/%s query=%q trailing=%s evidence=%s exit=%s calls=%s inventory_unchanged=%s: %s\n' \
              "$day" "$role" "$value" "$trailing" "$evidence" "$rc" "$(( $(call_count) - before ))" \
              "$([ "$inventory_after" = "$inventory_before" ] && echo yes || echo no)" "$out" >&2
            query_failures=$((query_failures + 1))
          elif [ "$evidence" = fresh ]; then
            before=$(call_count)
            out=$(FAKE_REVIEW_DATE="$day" launch "$role" --task "$query_token" --round 1)
            assert_one_call "$before"
            [ "$out" = "$query_reply" ] || fail 'malformed query consumed the intended launch slot'
            [ "$(cat "$query_input")" = 'Target: query-only request' ] || fail 'intended launch changed input'
          fi
        done
      done
    done
    rc=0
    before=$(call_count)
    out=$(FAKE_REVIEW_DATE="$day" launch "$role" --path elsewhere --task '' --round invalid 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'malformed query before invalid task/round was accepted'
    if [[ "$out" != *'unknown path query'* ]] || [ "$(call_count)" -ne "$before" ]; then
      printf 'not ok - %s/%s query was not rejected at option intake: %s\n' "$day" "$role" "$out" >&2
      query_failures=$((query_failures + 1))
    fi
  done
done
[ "$query_failures" -eq 0 ] || fail "$query_failures malformed queries violated intake rejection or evidence preservation"
pass 'review-round: malformed queries are rejected at intake without calls or artifact changes; omitted path still launches'

ln -s "$OTHER_DIR" "$REVIEW_ROOT/linked.abcdef"
mkdir -p "$REVIEW_ROOT/../escape.abcdef" "$REVIEW_ROOT/bad.abcde" "$REVIEW_ROOT/bad.abcdefg" "$REVIEW_ROOT/bad.a!cdef" "$REVIEW_ROOT/abcdef"
LONG_TOKEN="$(printf '%065d' 1).abcdef"
mkdir "$REVIEW_ROOT/$LONG_TOKEN"
for token in '' . .. ../escape.abcdef abcdef "$LONG_TOKEN" "$TASK_DIR" first-task bad.abcde bad.abcdefg 'bad.a!cdef' 'bad;cmd.abcdef' linked.abcdef missing.abcdef; do
  before=$(call_count)
  rc=0
  out=$(launch reviewer --task "$token" --round 1 --path input 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid or unowned task token accepted: $token"
  [ "$(call_count)" -eq "$before" ] || fail 'invalid token launched a role'
done
for round in '' 0 01 -1 ../1 abc; do
  rc=0
  out=$(launch reviewer --task "$TOKEN" --round "$round" --path input 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unsafe round accepted: $round"
done
rc=0
out=$(launch reviewer --task "$TOKEN" --round 1 --path elsewhere 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'unknown destination was accepted'
rc=0
out=$(launch reviewer --task "$TOKEN" --round 1 --task 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'missing option value was accepted'
pass 'review-round: invalid tokens, symlink tasks, rounds and queries are refused'

assert_capture() {
  python3 - "$OUTPUT" "$1" "$ROLE" "$FIXTURE_HOME" "$INPUT" "$TMP_ROOT/calls.jsonl" <<'PY'
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
assert sum(call == data for call in calls) == 1, 'expected exactly one fresh role invocation'
PY
}

export CDPATH="$TMP_ROOT:$TASK_REPO"
for day in 2026-10-04 2026-10-11 2026-10-12; do
  runtime=codex
  [ "$day" != 2026-10-12 ] || runtime=claude
  for role in reviewer fixer; do
    prepare "$role"
    before=$(call_count)
    out=$(FAKE_REVIEW_DATE="$day" run_role)
    assert_one_call "$before"
    [ "$out" = "$OUTPUT" ] || fail 'CDPATH polluted reply path'
    assert_capture "$runtime" || fail "$day/$role prompt or runtime differs"
  done
done
for role in reviewer fixer; do
  prepare "$role"
  before=$(call_count)
  FAKE_REVIEW_DATE=2026-10-12 FAKE_REVIEW_MODE=json-padding run_role >/dev/null
  assert_one_call "$before"
  assert_capture claude || fail 'valid padded JSON refused'
done
pass 'review-round: inclusive dated models, exact prompts and one invocation survive CDPATH'

for day in 2026-10-06 2026-10-12; do
  for role in reviewer fixer; do
    for mode in stderr whitespace events; do
      prepare "$role"
      before=$(call_count)
      rc=0
      out=$(FAKE_REVIEW_DATE="$day" FAKE_REVIEW_MODE="$mode" run_role 2>&1) || rc=$?
      assert_one_call "$before"
      [ "$rc" -ne 0 ] || fail "$day/$role accepted $mode without meaningful role reply"
      assert_contains "$out" 'role reply' 'missing reply refusal lacked reason'
      assert_contains "$out" "$OUTPUT.diagnostics" 'missing preserved diagnostics path'
      case "$mode" in
        stderr) assert_grep 'runtime ready; no assistant reply' "$OUTPUT.diagnostics" 'stderr lost' ;;
        events)
          evidence="$OUTPUT.diagnostics"
          [ "$day" != 2026-10-12 ] || evidence="$OUTPUT.runtime.json"
          assert_grep 'tool/event log; no assistant reply' "$evidence" 'stdout lost'
          ;;
        whitespace) [ -s "$OUTPUT" ] || fail 'whitespace evidence lost' ;;
      esac
    done
  done
done
pass 'review-round: both runtimes and roles refuse diagnostics, events and whitespace as replies'

for role in reviewer fixer; do
  for mode in success-error error-success duplicate-success extra-object object-first array malformed trailing missing-error-flag scalar null error-result tool-result nonstring-result; do
    prepare "$role"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE=2026-10-12 FAKE_REVIEW_MODE="$mode" run_role 2>&1) || rc=$?
    assert_one_call "$before"
    [ "$rc" -ne 0 ] || fail "Claude $role accepted $mode as one valid result"
    assert_contains "$out" 'no valid role reply' 'invalid result lacks reason'
    assert_contains "$out" "$OUTPUT.runtime.json" 'invalid result lacks raw evidence path'
    assert_contains "$out" "$OUTPUT.diagnostics" 'invalid result lacks diagnostics path'
    assert_grep 'runtime diagnostic' "$OUTPUT.diagnostics" 'stderr lost'
    [ -s "$OUTPUT.runtime.json" ] || fail 'invalid result lost raw bytes'
    raw_before=$(cksum < "$OUTPUT.runtime.json")
    diagnostics_before=$(cksum < "$OUTPUT.diagnostics")
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE=2026-10-12 run_role 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'invalid-result retry reused evidence'
    [ "$(call_count)" -eq "$before" ] || fail 'invalid-result retry launched'
    [ "$(cksum < "$OUTPUT.runtime.json")" = "$raw_before" ] || fail 'retry changed raw result'
    [ "$(cksum < "$OUTPUT.diagnostics")" = "$diagnostics_before" ] || fail 'retry changed diagnostics'
  done
done
pass 'review-round: Claude requires exactly one valid result; retry preserves invalid evidence'

for day in 2026-10-06 2026-10-12; do
  for role in reviewer fixer; do
    prepare "$role"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" FAKE_REVIEW_FAIL=1 run_role 2>&1) || rc=$?
    assert_one_call "$before"
    expect_code 23 "$rc" 'role failure must propagate'
    assert_contains "$out" "$OUTPUT" 'failure omitted reply path'
    assert_grep 'deliberate role failure' "$OUTPUT.diagnostics" 'failure lost stderr'
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" run_role 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'retry overwrote failed evidence'
    [ "$(call_count)" -eq "$before" ] || fail 'retry launched over old evidence'
    [ "$(cat "$OUTPUT.diagnostics")" = 'deliberate role failure' ] || fail 'retry changed diagnostics'
    prepare "$role"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_DATE="$day" FAKE_REVIEW_EMPTY=1 run_role 2>&1) || rc=$?
    assert_one_call "$before"
    [ "$rc" -ne 0 ] || fail 'absent reply passed'
    assert_contains "$out" 'role reply' 'missing reply lacks reason'
  done
done
pass 'review-round: failure codes propagate and failed or absent replies preserve evidence'

for day in 2026-10-06 2026-10-12; do
  suffixes=('' .diagnostics)
  [ "$day" != 2026-10-12 ] || suffixes+=(.runtime.json)
  for suffix in "${suffixes[@]}"; do
    for kind in existing symlink; do
      prepare reviewer
      sentinel="$TMP_ROOT/sentinel-$ROUND"
      printf 'previous evidence\n' > "$sentinel"
      if [ "$kind" = existing ]; then cp "$sentinel" "$OUTPUT$suffix"; else ln -s "$sentinel" "$OUTPUT$suffix"; fi
      before=$(call_count)
      rc=0
      out=$(FAKE_REVIEW_DATE="$day" run_role 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || fail 'existing evidence overwritten'
      [ "$(call_count)" -eq "$before" ] || fail 'existing evidence allowed launch'
      [ "$(cat "$OUTPUT$suffix")" = 'previous evidence' ] || fail 'evidence changed'
      [ "$(cat "$sentinel")" = 'previous evidence' ] || fail 'symlink target changed'
      [ -z "$suffix" ] || assert_absent "$OUTPUT" 'preflight wrote reply before refusal'
    done
  done
done
pass 'review-round: existing reply and sidecars, including symlinks, survive without launching'

prepare reviewer
printf 'outside\n' > "$TMP_ROOT/outside.md"
ln -s "$TMP_ROOT/outside.md" "$INPUT.link"
mv "$INPUT.link" "$INPUT"
before=$(call_count)
rc=0
out=$(run_role 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail 'derived symlink input accepted'
[ "$(call_count)" -eq "$before" ] || fail 'symlink input launched'
assert_absent "$OUTPUT" 'symlink input wrote output'
[ "$(cat "$REVIEW_ROOT/report.md")" = 'old evidence' ] || fail 'old root report changed'
[ "$(cat "$OTHER_DIR/report.md")" = 'previous task' ] || fail 'previous task changed'
prepare fixer
before=$(call_count)
saved_input=$(cksum < "$INPUT")
out=$(run_role)
assert_one_call "$before"
[ "$out" = "$OUTPUT" ] || fail 'fresh round after prior failures changed destination'
[ "$(cksum < "$INPUT")" = "$saved_input" ] || fail 'role overwrote input'
for file in "$OUTPUT" "$OUTPUT.diagnostics"; do
  saved=$(cksum < "$file")
  before=$(call_count)
  rc=0
  out=$(run_role 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'successful reply was reused'
  [ "$(call_count)" -eq "$before" ] || fail 'successful retry relaunched'
  [ "$(cksum < "$file")" = "$saved" ] || fail 'successful evidence changed'
done
pass 'review-round: derived inputs remain regular files; other tasks and root leftovers survive'
