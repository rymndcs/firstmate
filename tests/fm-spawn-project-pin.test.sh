#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-project-pin)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
TASK_TMP_ROOT=$(mktemp -d /tmp/fm-pin.XXXXXX)
FM_TEST_CLEANUP_DIRS+=("$TASK_TMP_ROOT")
ANOTHER_TMP_ROOT=$(mktemp -d /tmp/fm-pin-batch.XXXXXX)
FM_TEST_CLEANUP_DIRS+=("$ANOTHER_TMP_ROOT")
TASK_ID=${TASK_TMP_ROOT##*/fm-}
ANOTHER_ID=${ANOTHER_TMP_ROOT##*/fm-}
mkdir -p "$TMP_ROOT/user-home"
export HOME="$TMP_ROOT/user-home"

make_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  TEST_HOME="$CASE_DIR/home"
  PROJ="$CASE_DIR/source-with-a-different-name"
  WT="$CASE_DIR/task-worktree"
  mkdir -p "$TEST_HOME"/{config,data/"$TASK_ID",state,projects}
  fm_git_worktree "$PROJ" "$WT" task-branch
  ln -s "$PROJ" "$TEST_HOME/projects/thanos"
  printf '%s\n' '- thanos [no-mistakes] - test project' > "$TEST_HOME/data/projects.md"
  printf 'Delivery contract: mode=no-mistakes\n' > "$TEST_HOME/data/$TASK_ID/brief.md"
  printf 'claude\n' > "$TEST_HOME/config/crew-harness"
  printf '%s\n' '{"thanos":"claude/opus","*":"codex/gpt-6.1-sol"}' > "$TEST_HOME/config/project-harness-pins.json"
  FAKEBIN=$(fm_fakebin "$CASE_DIR")
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
esac
case "$1" in
  display-message) echo firstmate ;;
  list-windows) ;;
  new-window|new-session|send-keys) printf '%s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG" ;;
esac
SH
  chmod +x "$FAKEBIN/tmux"
  fm_fake_exit0 "$FAKEBIN" treehouse sleep
  : > "$CASE_DIR/launch.log"
}

run_spawn_args() {
  FM_HOME="$TEST_HOME" FM_CONFIG_OVERRIDE="$TEST_HOME/config" \
    FM_STATE_OVERRIDE="$TEST_HOME/state" FM_DATA_OVERRIDE="$TEST_HOME/data" \
    FM_PROJECTS_OVERRIDE="$TEST_HOME/projects" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$WT" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    TMUX=fake,1,0 CLAUDE_CONFIG_DIR='' PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

run_spawn() {
  local kind=$1
  shift
  local -a args
  args=()
  if [ "$kind" = ship ]; then
    args+=(--mode no-mistakes --yolo off)
  else
    args+=(--scout)
  fi
  run_spawn_args "$TASK_ID" "$PROJ" "${args[@]}" "$@"
}

refused() {
  local out rc=0
  out=$(run_spawn "$@") || rc=$?
  expect_code 1 "$rc" 'pin must refuse the launch'
  assert_contains "$out" 'thanos' 'refusal must name the registered project'
  assert_contains "$out" 'claude/opus' 'refusal must name the pin'
  assert_absent "$TEST_HOME/state/$TASK_ID.meta" 'refusal created task metadata'
  [ ! -s "$CASE_DIR/launch.log" ] || fail 'refusal created an endpoint'
}

for kind in ship scout; do
  make_case "$kind-missing-jq"
  cat > "$CASE_DIR/no-jq.bash" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then return 1; fi
  builtin command "$@"
}
jq() { return 127; }
SH
  rc=0
  out=$(BASH_ENV="$CASE_DIR/no-jq.bash" run_spawn "$kind" --harness claude --model opus --captain-pick claude/opus) || rc=$?
  expect_code 1 "$rc" 'missing jq must refuse pinned launch'
  assert_contains "$out" 'jq is required' 'missing jq must name the executable dependency'
  assert_contains "$out" 'project-harness-pins.json' 'missing jq must name its configuration'
  assert_not_contains "$out" 'invalid project harness/model pins' 'missing jq is not malformed JSON'
  assert_absent "$TEST_HOME/state/$TASK_ID.meta" 'missing jq created metadata'
  [ ! -s "$CASE_DIR/launch.log" ] || fail 'missing jq created an endpoint'
  rm "${TEST_HOME:?}/config/project-harness-pins.json"
  out=$(BASH_ENV="$CASE_DIR/no-jq.bash" run_spawn "$kind" --harness claude --captain-pick claude)
  assert_contains "$out" "spawned $TASK_ID harness=claude" 'no pin file must not require jq'
  pass "$kind diagnoses missing jq only when pins are configured"
done

for kind in ship scout; do
  make_case "$kind-mismatch"
  refused "$kind" --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol
  pass "$kind refuses a matching task pick that disagrees with the project pin"

  make_case "$kind-match"
  out=$(run_spawn "$kind" --harness claude --model opus --captain-pick claude/opus)
  assert_contains "$out" "spawned $TASK_ID harness=claude" 'matching launch failed'
  assert_grep "--model 'opus'" "$CASE_DIR/launch.log" 'pinned model was not launched'
  assert_no_grep 'tasktmp=/tmp/fm-task' "$TEST_HOME/state/$TASK_ID.meta" 'pin test must isolate task scratch from other test runs'
  assert_grep "tasktmp=$TASK_TMP_ROOT" "$TEST_HOME/state/$TASK_ID.meta" 'launch must use reserved task scratch'
  assert_present "$TASK_TMP_ROOT/gotmp" 'task scratch was not created in its reserved root'
  pass "$kind accepts the registered project pin through a differently named source path"
done

make_case wrong-model
refused ship --harness claude --model sonnet --captain-pick claude/sonnet
make_case missing-model
refused ship --harness claude --captain-pick claude
make_case pick-mismatch
refused ship --harness claude --model opus --captain-pick codex/gpt-6.1-sol
pass 'model and stated pick must both match the project pin'

make_case default-pin
mv "$TEST_HOME/projects/thanos" "$TEST_HOME/projects/wms"
printf '%s\n' '- wms [no-mistakes] - test project' > "$TEST_HOME/data/projects.md"
out=$(run_spawn ship --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol)
assert_contains "$out" "spawned $TASK_ID harness=codex" 'wildcard pin should cover other registered projects'
pass 'wildcard pin covers every other registered project'

make_case default-pin-mismatch
mv "$TEST_HOME/projects/thanos" "$TEST_HOME/projects/wms"
printf '%s\n' '- wms [no-mistakes] - test project' > "$TEST_HOME/data/projects.md"
rc=0
out=$(run_spawn scout --harness claude --model opus --captain-pick claude/opus) || rc=$?
expect_code 1 "$rc" 'wildcard must refuse a different harness/model'
assert_contains "$out" "project 'wms'" 'wildcard refusal must name the project'
assert_contains "$out" 'codex/gpt-6.1-sol' 'wildcard refusal must name the default pin'
assert_absent "$TEST_HOME/state/$TASK_ID.meta" 'wildcard mismatch created metadata'
pass 'wildcard pin refuses mismatches on other registered projects'

make_case no-pin
rm "${TEST_HOME:?}/config/project-harness-pins.json"
out=$(run_spawn ship --harness claude --captain-pick claude)
assert_contains "$out" "spawned $TASK_ID harness=claude" 'absent pin file must preserve defaults'
assert_grep 'model=default' "$TEST_HOME/state/$TASK_ID.meta" 'absent pin changed default model'
assert_no_grep 'project_pin' "$TEST_HOME/state/$TASK_ID.meta" 'absent pin added metadata'
pass 'no pin file preserves existing spawn behavior'

for kind in ship scout; do
  make_case "$kind-override"
  reason="I picked Codex for this one task = approved"
  out=$(run_spawn "$kind" --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol --project-pin-override "$reason") || fail "explicit override was refused: $out"
  assert_contains "$out" "spawned $TASK_ID harness=codex" 'explicit override did not launch'
  assert_grep 'project_pin_project=thanos' "$TEST_HOME/state/$TASK_ID.meta" 'override lost project identity'
  assert_grep 'project_pin=claude/opus' "$TEST_HOME/state/$TASK_ID.meta" 'override lost original pin'
  assert_grep "project_pin_override_reason=$reason" "$TEST_HOME/state/$TASK_ID.meta" 'override lost exact reason'
  pass "$kind records the explicit override with its reason and original pin"
done

reason_case=0
for reason in '' '   ' $'one\nmodel=injected' $'one\rmodel=injected'; do
  reason_case=$((reason_case + 1))
  make_case "bad-reason-$reason_case"
  rc=0
  out=$(run_spawn ship --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol --project-pin-override "$reason") || rc=$?
  expect_code 1 "$rc" 'override requires a nonblank single-line reason'
  assert_contains "$out" '--project-pin-override' 'invalid reason needs a useful diagnostic'
  assert_absent "$TEST_HOME/state/$TASK_ID.meta" 'invalid reason wrote metadata'
done
pass 'override reason cannot be blank or inject metadata lines'

make_case raw-command
refused ship --harness 'claude --model sonnet' --model opus --captain-pick claude/opus
pass 'raw commands cannot claim a pinned model while launching a different one'

make_case malformed-pin
printf '{bad json\n' > "$TEST_HOME/config/project-harness-pins.json"
rc=0
out=$(run_spawn ship --harness claude --model opus --captain-pick claude/opus) || rc=$?
expect_code 1 "$rc" 'malformed configured pins must refuse'
assert_contains "$out" 'project-harness-pins.json' 'malformed pin diagnostic missing file'
assert_absent "$TEST_HOME/state/$TASK_ID.meta" 'malformed pin launched'
pass 'malformed configured pins cannot silently disable enforcement'

make_case override-pick-agreement
rc=0
out=$(run_spawn ship --harness codex --model gpt-6.1-sol --captain-pick claude/opus --project-pin-override 'I picked another model') || rc=$?
expect_code 1 "$rc" 'project override must preserve stated pick agreement'
assert_contains "$out" "this spawn launches 'codex'" 'pick mismatch was not enforced'
pass 'project override preserves existing stated pick agreement'

make_case missing-reason
rc=0
out=$(run_spawn ship --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol --project-pin-override) || rc=$?
expect_code 1 "$rc" 'override flag must require a reason argument'
assert_contains "$out" '--project-pin-override requires a value' 'missing reason diagnostic'
pass 'override flag cannot be used without its reason'

make_case unresolved-project
printf '%s\n' '- other [no-mistakes] - unrelated' > "$TEST_HOME/data/projects.md"
rc=0
out=$(run_spawn ship --harness claude --model opus --captain-pick claude/opus) || rc=$?
expect_code 1 "$rc" 'active pins require a registered project identity'
assert_contains "$out" 'cannot resolve registered project' 'unknown project should explain resolution failure'
pass 'unresolved project identity cannot silently select the wrong pin'

for mapping in '{"thanos":"claude/"}' '{"thanos":"claude/default"}' '{"thanos":null}' '{"":"claude/opus"}' '{"thanos":"unknown/opus"}' '{} {}'; do
  make_case "invalid-schema-${#mapping}"
  printf '%s\n' "$mapping" > "$TEST_HOME/config/project-harness-pins.json"
  rc=0
  out=$(run_spawn ship --harness claude --model opus --captain-pick claude/opus) || rc=$?
  expect_code 1 "$rc" 'configured pins must be concrete harness/model mappings'
  assert_contains "$out" 'invalid project harness/model pins' 'schema diagnostic missing'
done
pass 'pin schema rejects unresolved models, unknown adapters and multiple JSON values'

make_case no-project-entry
printf '%s\n' '{"other":"claude/opus"}' > "$TEST_HOME/config/project-harness-pins.json"
out=$(run_spawn ship --harness claude --captain-pick claude)
assert_contains "$out" "spawned $TASK_ID harness=claude" 'unmapped project without wildcard should stay unpinned'
pass 'an unmapped registered project stays unpinned without a wildcard'

make_case batch-override
mkdir -p "$TEST_HOME/data/$ANOTHER_ID"
printf 'Delivery contract: mode=no-mistakes\n' > "$TEST_HOME/data/$ANOTHER_ID/brief.md"
out=$(run_spawn_args "$TASK_ID=$PROJ" "$ANOTHER_ID=$PROJ" --mode no-mistakes --yolo off \
  --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol --project-pin-override='I picked Codex for these tasks')
for id in "$TASK_ID" "$ANOTHER_ID"; do
  assert_contains "$out" "spawned $id harness=codex" 'batch override was not forwarded'
  assert_grep 'project_pin_override_reason=I picked Codex for these tasks' "$TEST_HOME/state/$id.meta" 'batch reason missing'
  assert_no_grep 'tasktmp=/tmp/fm-another' "$TEST_HOME/state/$id.meta" 'batch must isolate task scratch'
done
pass 'batch forwards the explicit override and records it for each task'

make_case secondmate-override
rc=0
out=$(run_spawn_args "$TASK_ID" "$PROJ" --secondmate --project-pin-override 'I picked another model') || rc=$?
expect_code 1 "$rc" 'project override does not apply to persistent supervisors'
assert_contains "$out" '--project-pin-override' 'secondmate override refusal needs a diagnostic'
pass 'project override is limited to ship and scout tasks'

for pin_case in mismatch malformed; do
  make_case "secondmate-$pin_case"
  if [ "$pin_case" = mismatch ]; then
    printf '%s\n' '{"*":"codex/gpt-6.1-sol"}' > "$TEST_HOME/config/project-harness-pins.json"
  else
    printf '{bad json\n' > "$TEST_HOME/config/project-harness-pins.json"
  fi
  PROJ="$CASE_DIR/secondmate"
  mkdir -p "$PROJ/bin" "$PROJ/data"
  printf '# Firstmate\n' > "$PROJ/AGENTS.md"
  printf '%s\n' "$TASK_ID" > "$PROJ/.fm-secondmate-home"
  printf 'charter\n' > "$PROJ/data/charter.md"
  printf 'claude opus\n' > "$TEST_HOME/config/secondmate-harness"
  rc=0
  out=$(run_spawn_args "$TASK_ID" "$PROJ" --secondmate) || rc=$?
  expect_code 0 "$rc" "persistent supervisor must ignore $pin_case project pins: $out"
  assert_contains "$out" "spawned $TASK_ID harness=claude" 'persistent supervisor did not launch'
  assert_grep "--model 'opus'" "$CASE_DIR/launch.log" 'persistent supervisor model was not launched'
  assert_grep 'kind=secondmate' "$TEST_HOME/state/$TASK_ID.meta" 'persistent supervisor metadata missing'
  assert_grep 'model=opus' "$TEST_HOME/state/$TASK_ID.meta" 'persistent supervisor model metadata missing'
  assert_no_grep 'project_pin' "$TEST_HOME/state/$TASK_ID.meta" 'project pins applied to persistent supervisor'
  assert_absent "$PROJ/config/project-harness-pins.json" 'home-local project pins were inherited'
  pass "persistent supervisor launches with active $pin_case project pins"
done
