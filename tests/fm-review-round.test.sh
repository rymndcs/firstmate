#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-round)
TASK_REPO="$TMP_ROOT/task"
FIXTURE_HOME="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
TASK_HOME="$TMP_ROOT/firstmate home"
mkdir -p "$TASK_HOME/state"
select_runtime() {
  printf "harness=%s\nmodel=%s\neffort=%s\n" "$1" "${2:-$1-task-model}" "${3:-medium}" > "$TASK_HOME/state/first-task.meta"
}
select_runtime codex
printf "harness=codex\nmodel=query-model\neffort=high\n" > "$TASK_HOME/state/query-regression.meta"
mkdir -p "$TASK_REPO" "$FIXTURE_HOME/.claude/agents" "$FAKEBIN"
TASK_REPO=$(cd "$TASK_REPO" && pwd -P)
git -C "$TASK_REPO" init -q
printf '%s\n' '---' 'name: adv-reviewer' '---' 'Reviewer instructions.' > "$FIXTURE_HOME/.claude/agents/adv-reviewer.md"
printf '%s\n' '---' 'name: adv-fixer' '---' 'Fixer instructions.' > "$FIXTURE_HOME/.claude/agents/adv-fixer.md"
cat > "$FAKEBIN/codex" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
if args == ['--help']:
    print('  --effort <level>' if not os.environ.get('FAKE_NO_EFFORT') else 'Usage: claude')
    sys.exit(0)
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
  (cd "$TASK_REPO" && env FM_HOME="$TASK_HOME" HOME="$FIXTURE_HOME" PATH="$FAKEBIN:$PATH" \
    FAKE_REVIEW_CALLS="$TMP_ROOT/calls.jsonl" FAKE_REVIEW_DATE="${FAKE_REVIEW_DATE:-2026-10-06}" "$ROOT/bin/fm-review-round.sh" "$@")
}

out=$(launch --help)
assert_contains "$out" 'state/<task-id>.meta' 'help omitted runtime metadata owner'


legacy=$(launch --init caller-path-regression)
REVIEW_ROOT=$(git -C "$TASK_REPO" rev-parse --absolute-git-dir)/adv-review-loop
case "$legacy" in /*) legacy_dir=$legacy ;; *) legacy_dir="$REVIEW_ROOT/$legacy" ;; esac
printf 'Target: task\n' > "$legacy_dir/old-input.md"
cp "$legacy_dir/old-input.md" "$legacy_dir/-round.md"
legacy_launch() {
  (cd "$legacy_dir" && env FM_HOME="$TASK_HOME" HOME="$FIXTURE_HOME" PATH="$FAKEBIN:$PATH" \
    FAKE_REVIEW_CALLS="$TMP_ROOT/calls.jsonl" FAKE_REVIEW_DATE="${FAKE_REVIEW_DATE:-2030-01-01}" "$ROOT/bin/fm-review-round.sh" "$@")
}
path_failures=0
for runtime in codex claude; do
  select_runtime "$runtime"
  for role in reviewer fixer; do
    for value in "$legacy_dir/old-input.md" -round.md ./-round.md; do
      before=$(call_count)
      rc=0
      out=$(legacy_launch "$role" --round 1 --in "$value" --out "$legacy_dir/$runtime-$role-${#value}.out" 2>&1) || rc=$?
      if [ "$rc" -eq 0 ] || [[ "$out" != *'unknown option: --in'* ]] || [ "$(call_count)" -ne "$before" ]; then
        printf 'not ok - %s/%s caller --in path was not rejected at the interface: exit=%s %s\n' "$runtime" "$role" "$rc" "$out" >&2
        path_failures=$((path_failures + 1))
      fi
    done
    rc=0
    out=$(legacy_launch "$role" --round 1 --out -round.out --in "$legacy_dir/old-input.md" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ] || [[ "$out" != *'unknown option: --out'* ]]; then
      printf 'not ok - %s/%s caller --out path was not rejected at the interface: %s\n' "$runtime" "$role" "$out" >&2
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
for runtime in codex claude; do
  select_runtime "$runtime"
  cp "$TASK_HOME/state/first-task.meta" "$TASK_HOME/state/query-regression.meta"
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
          out=$(launch "${query_args[@]}" 2>&1) || rc=$?
          inventory_after=$(artifact_inventory "$query_dir")
          if [ "$rc" -eq 0 ] || [[ "$out" != *'unknown path query'* ]] || \
            [ "$(call_count)" -ne "$before" ] || [ "$inventory_after" != "$inventory_before" ]; then
            printf 'not ok - %s/%s query=%q trailing=%s evidence=%s exit=%s calls=%s inventory_unchanged=%s: %s\n' \
              "$runtime" "$role" "$value" "$trailing" "$evidence" "$rc" "$(( $(call_count) - before ))" \
              "$([ "$inventory_after" = "$inventory_before" ] && echo yes || echo no)" "$out" >&2
            query_failures=$((query_failures + 1))
          elif [ "$evidence" = fresh ]; then
            before=$(call_count)
            out=$(launch "$role" --task "$query_token" --round 1)
            assert_one_call "$before"
            [ "$out" = "$query_reply" ] || fail 'malformed query consumed the intended launch slot'
            [ "$(cat "$query_input")" = 'Target: query-only request' ] || fail 'intended launch changed input'
          fi
        done
      done
    done
    rc=0
    before=$(call_count)
    out=$(launch "$role" --path elsewhere --task '' --round invalid 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'malformed query before invalid task/round was accepted'
    if [[ "$out" != *'unknown path query'* ]] || [ "$(call_count)" -ne "$before" ]; then
      printf 'not ok - %s/%s query was not rejected at option intake: %s\n' "$runtime" "$role" "$out" >&2
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
    expected = ['exec', '--output-last-message', output, '--model', 'codex-task-model', '-c', 'model_reasoning_effort="medium"',
                '--dangerously-bypass-approvals-and-sandbox', '--']
else:
    expected = ['-p', '--output-format', 'json', '--model', 'claude-task-model', '--effort', 'medium', '--dangerously-skip-permissions', '--']
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
for runtime in codex claude; do
  select_runtime "$runtime"
  for role in reviewer fixer; do
    prepare "$role"
    before=$(call_count)
    out=$(run_role)
    assert_one_call "$before"
    [ "$out" = "$OUTPUT" ] || fail 'CDPATH polluted reply path'
    assert_capture "$runtime" || fail "$runtime/$role prompt or runtime differs"
  done
done
select_runtime claude
for role in reviewer fixer; do
  prepare "$role"
  before=$(call_count)
  FAKE_REVIEW_DATE=2026-10-28 FAKE_REVIEW_MODE=json-padding run_role >/dev/null
  assert_one_call "$before"
  assert_capture claude || fail 'valid padded JSON refused'
done
pass 'review-round: task models and effort, exact prompts and one invocation survive CDPATH'

for runtime in codex claude; do
  select_runtime "$runtime"
  for role in reviewer fixer; do
    for mode in stderr whitespace events; do
      prepare "$role"
      before=$(call_count)
      rc=0
      out=$(FAKE_REVIEW_MODE="$mode" run_role 2>&1) || rc=$?
      assert_one_call "$before"
      [ "$rc" -ne 0 ] || fail "$runtime/$role accepted $mode without meaningful role reply"
      assert_contains "$out" 'role reply' 'missing reply refusal lacked reason'
      assert_contains "$out" "$OUTPUT.diagnostics" 'missing preserved diagnostics path'
      case "$mode" in
        stderr) assert_grep 'runtime ready; no assistant reply' "$OUTPUT.diagnostics" 'stderr lost' ;;
        events)
          evidence="$OUTPUT.diagnostics"
          [ "$runtime" != claude ] || evidence="$OUTPUT.runtime.json"
          assert_grep 'tool/event log; no assistant reply' "$evidence" 'stdout lost'
          ;;
        whitespace) [ -s "$OUTPUT" ] || fail 'whitespace evidence lost' ;;
      esac
    done
  done
done
pass 'review-round: both runtimes and roles refuse diagnostics, events and whitespace as replies'

select_runtime claude
for role in reviewer fixer; do
  for mode in success-error error-success duplicate-success extra-object object-first array malformed trailing missing-error-flag scalar null error-result tool-result nonstring-result; do
    prepare "$role"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_MODE="$mode" run_role 2>&1) || rc=$?
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
    out=$(run_role 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'invalid-result retry reused evidence'
    [ "$(call_count)" -eq "$before" ] || fail 'invalid-result retry launched'
    [ "$(cksum < "$OUTPUT.runtime.json")" = "$raw_before" ] || fail 'retry changed raw result'
    [ "$(cksum < "$OUTPUT.diagnostics")" = "$diagnostics_before" ] || fail 'retry changed diagnostics'
  done
done
pass 'review-round: Claude requires exactly one valid result; retry preserves invalid evidence'

for runtime in codex claude; do
  select_runtime "$runtime"
  for role in reviewer fixer; do
    prepare "$role"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_FAIL=1 run_role 2>&1) || rc=$?
    assert_one_call "$before"
    expect_code 23 "$rc" 'role failure must propagate'
    assert_contains "$out" "$OUTPUT" 'failure omitted reply path'
    assert_grep 'deliberate role failure' "$OUTPUT.diagnostics" 'failure lost stderr'
    before=$(call_count)
    rc=0
    out=$(run_role 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'retry overwrote failed evidence'
    [ "$(call_count)" -eq "$before" ] || fail 'retry launched over old evidence'
    [ "$(cat "$OUTPUT.diagnostics")" = 'deliberate role failure' ] || fail 'retry changed diagnostics'
    prepare "$role"
    before=$(call_count)
    rc=0
    out=$(FAKE_REVIEW_EMPTY=1 run_role 2>&1) || rc=$?
    assert_one_call "$before"
    [ "$rc" -ne 0 ] || fail 'absent reply passed'
    assert_contains "$out" 'role reply' 'missing reply lacks reason'
  done
done
pass 'review-round: failure codes propagate and failed or absent replies preserve evidence'

for runtime in codex claude; do
  select_runtime "$runtime"
  suffixes=('' .diagnostics)
  [ "$runtime" != claude ] || suffixes+=(.runtime.json)
  for suffix in "${suffixes[@]}"; do
    for kind in existing symlink; do
      prepare reviewer
      sentinel="$TMP_ROOT/sentinel-$ROUND"
      printf 'previous evidence\n' > "$sentinel"
      if [ "$kind" = existing ]; then cp "$sentinel" "$OUTPUT$suffix"; else ln -s "$sentinel" "$OUTPUT$suffix"; fi
      before=$(call_count)
      rc=0
      out=$(run_role 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || fail 'existing evidence overwritten'
      [ "$(call_count)" -eq "$before" ] || fail 'existing evidence allowed launch'
      [ "$(cat "$OUTPUT$suffix")" = 'previous evidence' ] || fail 'evidence changed'
      [ "$(cat "$sentinel")" = 'previous evidence' ] || fail 'symlink target changed'
      [ -z "$suffix" ] || assert_absent "$OUTPUT" 'preflight wrote reply before refusal'
    done
  done
done
pass 'review-round: existing reply and sidecars, including symlinks, survive without launching'

select_runtime codex
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

select_runtime codex
for role in reviewer fixer; do
  prepare "$role"
  FAKE_REVIEW_DATE=2030-01-01 run_role >/dev/null
  assert_capture codex || fail 'date switched a Codex task to another runtime'
done
pass 'review-round: dates after the retired cutoff keep the task runtime for reviewer and fixer'

for record in missing harness model effort default-effort unsupported-default; do
  prepare reviewer
  case "$record" in
    missing) mv "$TASK_HOME/state/first-task.meta" "$TASK_HOME/saved.meta"; expected='metadata' ;;
    harness) printf 'model=test\neffort=high\n' > "$TASK_HOME/state/first-task.meta"; expected='harness' ;;
    model) printf 'harness=codex\neffort=high\n' > "$TASK_HOME/state/first-task.meta"; expected='model' ;;
    effort) printf 'harness=codex\nmodel=test\n' > "$TASK_HOME/state/first-task.meta"; expected='effort' ;;
    default-effort) select_runtime codex codex-task-model default; expected='effort' ;;
    unsupported-default) select_runtime codex default; expected='model' ;;
  esac
  before=$(call_count)
  rc=0
  out=$(run_role 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$record metadata launched a role"
  assert_contains "$out" first-task 'refusal omitted task id'
  assert_contains "$out" "$expected" 'refusal omitted missing runtime field'
  [ "$(call_count)" -eq "$before" ] || fail 'invalid metadata invoked a runtime'
  assert_absent "$OUTPUT" 'invalid metadata reserved reply'
  select_runtime codex
done
for runtime in opencode pi pi-signed grok kimi unknown; do
  prepare fixer
  select_runtime "$runtime"
  before=$(call_count)
  rc=0
  out=$(run_role 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "$runtime silently switched runtime"
  assert_contains "$out" first-task 'unsupported refusal omitted task'
  assert_contains "$out" "$runtime" 'unsupported refusal omitted harness'
  [ "$(call_count)" -eq "$before" ] || fail 'unsupported harness invoked another runtime'
done
select_runtime claude
printf 'harness=claude\nmodel=claude-task-model\n' > "$TASK_HOME/state/first-task.meta"
prepare reviewer
run_role >/dev/null
python3 - "$OUTPUT" <<'PYTEST'
import json, pathlib, sys
args = json.loads(pathlib.Path(sys.argv[1]).read_text())['args']
assert '--effort' not in args, args
assert args[args.index('--model') + 1] == 'claude-task-model', args
PYTEST
select_runtime claude
prepare fixer
FAKE_NO_EFFORT=1 run_role >/dev/null
python3 - "$OUTPUT" <<'PYTEST'
import json, pathlib, sys
assert '--effort' not in json.loads(pathlib.Path(sys.argv[1]).read_text())['args']
PYTEST
pass 'review-round: missing runtime refuses without launch; Claude optional effort follows CLI support'

select_runtime codex
mkdir -p "$TASK_HOME/bin"
cp "$ROOT/bin/fm-review-round.sh" "$ROOT/bin/fm-pr-lib.sh" "$TASK_HOME/bin/"
prepare reviewer
(cd "$TASK_REPO" && unset FM_HOME && HOME="$FIXTURE_HOME" PATH="$FAKEBIN:$PATH" \
  FAKE_REVIEW_CALLS="$TMP_ROOT/calls.jsonl" "$TASK_HOME/bin/fm-review-round.sh" reviewer --task "$TOKEN" --round "$ROUND") >/dev/null
assert_capture codex || fail 'script-root home lookup depended on worker cwd'
pass 'review-round: script path locates home when worker environment omits FM_HOME'


python3 - "$ROOT" "$TMP_ROOT" "$FIXTURE_HOME" "$FAKEBIN" <<'PYTEST'
import json, os, pathlib, re, subprocess, sys
root, temp, roles, fakebin = map(pathlib.Path, sys.argv[1:])
lab = temp / 'operational-paths'
lab.mkdir()
launcher = root / 'bin/fm-review-round.sh'
worker = temp / 'task'
env = os.environ.copy()
for key in ['FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE']:
    env.pop(key, None)
env.update(HOME=str(roles), PATH=str(fakebin) + ':' + env['PATH'],
           FAKE_REVIEW_CALLS=str(temp / 'calls.jsonl'))
failures = []

def launch(case, run_env, prefix=''):
    token = subprocess.check_output([str(launcher), '--init', 'probe'], cwd=worker, env=env, text=True).strip()
    args = [str(launcher), 'reviewer', '--task', token, '--round', '1']
    input_file = subprocess.check_output(args + ['--path', 'input'], cwd=worker, env=env, text=True).strip()
    pathlib.Path(input_file).write_text('Fixture request.\n')
    result = subprocess.run(['bash', '-eu', '-c', prefix + '\nexec "$@"', 'fixture'] + args,
                            cwd=worker, env=run_env, text=True, capture_output=True)
    if result.returncode:
        failures.append(f'{case}: exit {result.returncode}: {result.stderr.strip()}')
        return
    data = json.loads(pathlib.Path(result.stdout.strip()).read_text())
    args = data['args']
    if args[args.index('--model') + 1] != 'owning-model':
        failures.append(f'{case}: selected stale default metadata: {args}')
    else:
        print(f'ok - {case}: owning runtime metadata selected after cwd change')

meta = 'kind=scout\nharness=codex\nmodel=owning-model\neffort=high\n'
home = lab / 'direct home'
(home / 'state').mkdir(parents=True)
(home / 'state/probe.meta').write_text(meta.replace('owning-model', 'stale-model'))
alternate = lab / 'alternate state'
alternate.mkdir()
(alternate / 'probe.meta').write_text(meta)
for location in [str(alternate), os.path.relpath(alternate, worker)]:
    launch('R1-2 direct override ' + location, dict(env, FM_HOME=str(home), FM_STATE_OVERRIDE=location))
for runtime in ['codex', 'claude']:
    (alternate / 'probe.meta').write_text(meta.replace('harness=codex', 'harness=' + runtime))
    launch('R1-2 override runtime ' + runtime, dict(env, FM_HOME=str(home), FM_STATE_OVERRIDE=str(alternate)))

fake_root = lab / 'fake-root/bin'
fake_root.mkdir(parents=True)
guard = fake_root / 'fm-guard.sh'
guard.write_text('#!/bin/sh\nexit 0\n')
guard.chmod(0o755)
for configured in [False, True]:
    for state_kind in ['default', 'relative', 'absolute']:
        case = f'R1-1/R1-2 promotion configured={configured} state={state_kind}'
        owner = lab / f'owner {configured} {state_kind}'
        (owner / 'home/state').mkdir(parents=True)
        (owner / 'home/config').mkdir()
        (owner / 'relative data').mkdir()
        state = owner / ('home/state' if state_kind == 'default' else 'alternate state')
        state.mkdir(exist_ok=True)
        (state / 'probe.meta').write_text(meta)
        if state_kind != 'default':
            (owner / 'home/state/probe.meta').write_text(meta.replace('owning-model', 'stale-model'))
        if configured:
            (owner / 'home/config/ship-review.md').write_text('<!-- FM_REVIEW_LAUNCH_SLOT -->\n')
        promote_env = dict(env, FM_HOME='home', FM_DATA_OVERRIDE='relative data', FM_ROOT_OVERRIDE=str(fake_root.parent))
        if state_kind != 'default':
            promote_env['FM_STATE_OVERRIDE'] = str(state) if state_kind == 'absolute' else 'alternate state'
        result = subprocess.run([str(root / 'bin/fm-brief.sh'), 'probe', 'fixture', '--mode', 'local-only', '--checks', 'targeted'],
                                cwd=owner, env=promote_env, text=True, capture_output=True)
        if result.returncode:
            failures.append(f'{case}: brief failed: {result.stderr}')
        else:
            brief = (owner / 'relative data/probe/brief.md').read_text()
            for index, command in enumerate(re.findall(r'`(export FM_HOME=[^`]+)`', brief)):
                launch(f'R1-2 brief {configured}/{state_kind} block={index}', dict(env, FM_STATE_OVERRIDE='/wrong-state'), command)
        result = subprocess.run([str(root / 'bin/fm-promote.sh'), 'probe', '--mode', 'local-only', '--yolo', 'off'],
                                cwd=owner, env=promote_env, text=True, capture_output=True)
        if result.returncode:
            failures.append(f'{case}: promotion failed: {result.stderr}')
            continue
        review = owner / 'relative data/probe/ship-review.md'
        exports = re.findall(r'`(export FM_HOME=[^`]+)`', review.read_text())
        if len(exports) != (2 if configured else 1):
            failures.append(f'{case}: missing generated environment instructions')
        for index, command in enumerate(exports):
            launch(f'{case} block={index}', dict(env, FM_HOME='/wrong-home', FM_STATE_OVERRIDE='/wrong-state'), command)
        if str(review) not in result.stdout:
            failures.append(f'{case}: next instruction persists a relative review-file path: {result.stdout.strip()}')

for name in ['FM_HOME', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE']:
    (state / 'probe.meta').write_text(meta)
    original_meta = (state / 'probe.meta').read_bytes()
    refused_env = dict(promote_env)
    missing = 'missing directory ' + name
    refused_env[name] = missing
    result = subprocess.run([str(root / 'bin/fm-promote.sh'), 'probe', '--mode', 'local-only', '--yolo', 'off'],
                            cwd=owner, env=refused_env, text=True, capture_output=True)
    if result.returncode == 0 or name not in result.stderr:
        failures.append(f'R1-1 invalid {name}: omitted resolution diagnostic: {result.stderr}')
    if (state / 'probe.meta').read_bytes() != original_meta:
        failures.append(f'R1-1 invalid {name}: changed task metadata before refusing')
    if (owner / missing).exists():
        failures.append(f'R1-1 invalid {name}: created the unresolvable directory')

smoke = lab / 'smoke'
(smoke / 'fakebin').mkdir(parents=True)
(smoke / 'tmp').mkdir()
shim = '''#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
k = pathlib.Path(sys.argv[0]).name
if a == ['--version']: print('fixture 1'); sys.exit(0)
if a == ['--help']: print('--effort <level>'); sys.exit(0)
if os.environ.get('SMOKE_FAIL'): sys.exit(23)
if k == 'codex':
 pathlib.Path(a[a.index('--output-last-message') + 1]).write_text('SMOKE_OK codex')
 print('model: gpt-6.1-sol\\nreasoning effort: high')
else: print(json.dumps({'type':'result', 'is_error':False, 'result':'SMOKE_OK claude', 'modelUsage':{'claude-opus-fixture':{}}}))
'''
for name in ['codex', 'claude']:
    path = smoke / 'fakebin' / name
    path.write_text(shim)
    path.chmod(0o755)
for failing in [False, True]:
    smoke_tmp = smoke / 'tmp' / str(failing)
    smoke_tmp.mkdir()
    smoke_env = dict(env, TMPDIR=str(smoke_tmp), FM_REVIEW_ROUND_LIVE='1', FM_STATE_OVERRIDE='/wrong-state',
                     PATH=str(smoke / 'fakebin') + ':' + env['PATH'])
    if failing:
        smoke_env['SMOKE_FAIL'] = '1'
    result = subprocess.run(['bash', str(root / 'tests/fm-review-round-live-e2e.test.sh')],
                            cwd=worker, env=smoke_env, text=True, capture_output=True)
    if (result.returncode != 0) != failing:
        failures.append(f'R1-3 smoke failure={failing}: unexpected exit {result.returncode}: {result.stderr}')
    if not failing and '# checked 2 installed supported harness(es)' not in result.stdout:
        failures.append(f'R1-3 inert smoke did not exercise both harnesses: {result.stdout}')
    leftovers = list(smoke_tmp.iterdir())
    if leftovers:
        failures.append(f'R1-3 smoke failure={failing}: left fixture roots: {leftovers}')
    else:
        print(f'ok - R1-3 smoke failure={failing}: parent removed fixture')
if failures:
    print('\n'.join('not ok - ' + failure for failure in failures), file=sys.stderr)
    sys.exit(1)
PYTEST
pass 'review-round: promoted home/state paths and live-smoke parent cleanup survive process boundaries'
