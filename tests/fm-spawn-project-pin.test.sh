#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-project-pin)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
mkdir -p "$TMP_ROOT/user-home"
export HOME="$TMP_ROOT/user-home"

make_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  TEST_HOME="$CASE_DIR/home"
  PROJ="$CASE_DIR/source-with-a-different-name"
  WT="$CASE_DIR/task-worktree"
  mkdir -p "$TEST_HOME"/{config,data/task,state,projects}
  fm_git_worktree "$PROJ" "$WT" task-branch
  ln -s "$PROJ" "$TEST_HOME/projects/thanos"
  printf '%s\n' '- thanos [no-mistakes] - test project' > "$TEST_HOME/data/projects.md"
  printf 'Delivery contract: mode=no-mistakes\n' > "$TEST_HOME/data/task/brief.md"
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
  run_spawn_args task "$PROJ" "${args[@]}" "$@"
}

refused() {
  local out rc=0
  out=$(run_spawn "$@") || rc=$?
  expect_code 1 "$rc" 'pin must refuse the launch'
  assert_contains "$out" 'thanos' 'refusal must name the registered project'
  assert_contains "$out" 'claude/opus' 'refusal must name the pin'
  assert_absent "$TEST_HOME/state/task.meta" 'refusal created task metadata'
  [ ! -s "$CASE_DIR/launch.log" ] || fail 'refusal created an endpoint'
}

for kind in ship scout; do
  make_case "$kind-mismatch"
  refused "$kind" --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol
  pass "$kind refuses a matching task pick that disagrees with the project pin"

  make_case "$kind-match"
  out=$(run_spawn "$kind" --harness claude --model opus --captain-pick claude/opus)
  assert_contains "$out" 'spawned task harness=claude' 'matching launch failed'
  assert_grep "--model 'opus'" "$CASE_DIR/launch.log" 'pinned model was not launched'
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
assert_contains "$out" 'spawned task harness=codex' 'wildcard pin should cover other registered projects'
pass 'wildcard pin covers every other registered project'

make_case default-pin-mismatch
mv "$TEST_HOME/projects/thanos" "$TEST_HOME/projects/wms"
printf '%s\n' '- wms [no-mistakes] - test project' > "$TEST_HOME/data/projects.md"
rc=0
out=$(run_spawn scout --harness claude --model opus --captain-pick claude/opus) || rc=$?
expect_code 1 "$rc" 'wildcard must refuse a different harness/model'
assert_contains "$out" "project 'wms'" 'wildcard refusal must name the project'
assert_contains "$out" 'codex/gpt-6.1-sol' 'wildcard refusal must name the default pin'
assert_absent "$TEST_HOME/state/task.meta" 'wildcard mismatch created metadata'
pass 'wildcard pin refuses mismatches on other registered projects'

make_case no-pin
rm "${TEST_HOME:?}/config/project-harness-pins.json"
out=$(run_spawn ship --harness claude --captain-pick claude)
assert_contains "$out" 'spawned task harness=claude' 'absent pin file must preserve defaults'
assert_grep 'model=default' "$TEST_HOME/state/task.meta" 'absent pin changed default model'
assert_no_grep 'project_pin' "$TEST_HOME/state/task.meta" 'absent pin added metadata'
pass 'no pin file preserves existing spawn behavior'

for kind in ship scout; do
  make_case "$kind-override"
  reason="I picked Codex for this one task = approved"
  out=$(run_spawn "$kind" --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol --project-pin-override "$reason") || fail "explicit override was refused: $out"
  assert_contains "$out" 'spawned task harness=codex' 'explicit override did not launch'
  assert_grep 'project_pin_project=thanos' "$TEST_HOME/state/task.meta" 'override lost project identity'
  assert_grep 'project_pin=claude/opus' "$TEST_HOME/state/task.meta" 'override lost original pin'
  assert_grep "project_pin_override_reason=$reason" "$TEST_HOME/state/task.meta" 'override lost exact reason'
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
  assert_absent "$TEST_HOME/state/task.meta" 'invalid reason wrote metadata'
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
assert_absent "$TEST_HOME/state/task.meta" 'malformed pin launched'
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
assert_contains "$out" 'spawned task harness=claude' 'unmapped project without wildcard should stay unpinned'
pass 'an unmapped registered project stays unpinned without a wildcard'

make_case batch-override
mkdir -p "$TEST_HOME/data/another"
printf 'Delivery contract: mode=no-mistakes\n' > "$TEST_HOME/data/another/brief.md"
out=$(run_spawn_args "task=$PROJ" "another=$PROJ" --mode no-mistakes --yolo off \
  --harness codex --model gpt-6.1-sol --captain-pick codex/gpt-6.1-sol --project-pin-override='I picked Codex for these tasks')
for id in task another; do
  assert_contains "$out" "spawned $id harness=codex" 'batch override was not forwarded'
  assert_grep 'project_pin_override_reason=I picked Codex for these tasks' "$TEST_HOME/state/$id.meta" 'batch reason missing'
done
pass 'batch forwards the explicit override and records it for each task'

make_case secondmate-override
rc=0
out=$(run_spawn_args task "$PROJ" --secondmate --project-pin-override 'I picked another model') || rc=$?
expect_code 1 "$rc" 'project override does not apply to persistent supervisors'
assert_contains "$out" '--project-pin-override' 'secondmate override refusal needs a diagnostic'
pass 'project override is limited to ship and scout tasks'
