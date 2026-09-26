#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: which branch the approved local-only landing
# actually fast-forwards into the project's default branch.
#
# The task branch is fm/<task-id> for an ordinary task, but a task scaffolded on a
# tracker-supplied name (bin/fm-brief.sh --branch) records that name in its meta.
# Deriving fm/<task-id> from the id alone would look for a branch that was never
# created and refuse a perfectly landable merge, so the recorded name wins and the
# derived default remains the fallback.
#
# Matrix:
#   (a) branch= recorded, not the fm/ shape -> merges the recorded branch
#   (b) no branch= recorded                 -> merges fm/<task-id> (unchanged)
#   (c) branch= recorded but missing        -> refuses, naming the branch it wanted
#   (d) mode is not local-only              -> refuses before touching the project
#
# Ship review gate (config/ship-review-gate = required; bin/fm-ship-review-lib.sh):
#   (e) no review line                      -> refuses, says what is missing, main unmoved
#   (f) review line, report missing         -> refuses naming the report path
#   (g) review line + existing report       -> lands
#   (h) a later non-pass review line        -> withdraws the pass and refuses
#   (i) captain override with a reason      -> lands and logs the reason
#   (j) blank override                      -> refuses
#   (k) malformed gate file                 -> refuses naming the file, override or not
#   (l) gate file says off                  -> lands with no review line
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local)

# A project on `main` plus a worktree holding one commit on <task-branch>.
# Echoes the case dir.
make_case() {  # <name> <task-branch>
  local name=$1 branch=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data"

  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" worktree add -q -b "$branch" "$case_dir/wt" main
  printf 'landed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "task work"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {  # <case-dir> <mode> [<extra-meta-line>...]
  local case_dir=$1 mode=$2
  shift 2
  fm_write_meta "$case_dir/state/task-m1.meta" \
    "window=firstmate:fm-task-m1" \
    "endpoint_task_id=task-m1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=$mode" \
    "$@"
}

run_merge_local() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    "$MERGE_LOCAL" "$@"
}

main_head() {  # <case-dir>
  git -C "$1/project" rev-parse main
}

test_recorded_branch_is_the_one_that_lands() {
  local case_dir out linear
  linear="rcs/rac-105-purchase_order_params-permits-status-bypassing-the-state"
  case_dir=$(make_case recorded-branch "$linear")
  write_meta "$case_dir" local-only "branch=$linear"

  out=$(run_merge_local "$case_dir" task-m1 2>&1) \
    || fail "recorded-branch: approved landing refused a recorded branch: $out"

  assert_contains "$out" "merged $linear into local main" \
    "recorded-branch: the merge did not report landing the recorded branch"
  [ "$(main_head "$case_dir")" = "$(git -C "$case_dir/wt" rev-parse "$linear")" ] \
    || fail "recorded-branch: local main was not fast-forwarded to the recorded branch"
  pass "fm-merge-local lands the branch recorded in the task record"
}

test_default_branch_shape_still_lands() {
  local case_dir out
  case_dir=$(make_case default-branch fm/task-m1)
  write_meta "$case_dir" local-only

  out=$(run_merge_local "$case_dir" task-m1 2>&1) \
    || fail "default-branch: approved landing refused the derived default: $out"

  assert_contains "$out" "merged fm/task-m1 into local main" \
    "default-branch: a task recording no branch stopped deriving fm/<task-id>"
  [ "$(main_head "$case_dir")" = "$(git -C "$case_dir/wt" rev-parse fm/task-m1)" ] \
    || fail "default-branch: local main was not fast-forwarded to fm/<task-id>"
  pass "fm-merge-local still derives fm/<task-id> when the task records no branch"
}

test_missing_recorded_branch_refuses_by_name() {
  local case_dir out status before
  case_dir=$(make_case missing-branch fm/task-m1)
  write_meta "$case_dir" local-only "branch=rcs/rac-999-never-created"
  before=$(main_head "$case_dir")

  set +e
  out=$(run_merge_local "$case_dir" task-m1 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "missing-branch: expected a non-zero exit"
  assert_contains "$out" "branch rcs/rac-999-never-created does not exist" \
    "missing-branch: refusal did not name the branch it was told to land"
  [ "$(main_head "$case_dir")" = "$before" ] \
    || fail "missing-branch: a refused merge still moved local main"
  pass "fm-merge-local refuses by name when the recorded branch does not exist"
}

test_non_local_only_task_is_refused() {
  local case_dir out status before
  case_dir=$(make_case wrong-mode fm/task-m1)
  write_meta "$case_dir" no-mistakes "branch=fm/task-m1"
  before=$(main_head "$case_dir")

  set +e
  out=$(run_merge_local "$case_dir" task-m1 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "wrong-mode: expected a non-zero exit"
  assert_contains "$out" "not local-only" "wrong-mode: refusal did not explain the delivery mismatch"
  [ "$(main_head "$case_dir")" = "$before" ] \
    || fail "wrong-mode: a refused merge still moved local main"
  pass "fm-merge-local refuses a task whose delivery is not local-only"
}

# A local-only ship task on fm/task-m1 in a home whose review gate is required.
make_gated_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1" fm/task-m1)
  write_meta "$case_dir" local-only
  printf 'required\n' > "$case_dir/config/ship-review-gate"
  printf '%s\n' "$case_dir"
}

write_report() {  # <case-dir>; echoes the report path
  local report="$1/wt-gitdir/adv-review-loop/report.md"
  mkdir -p "${report%/*}"
  printf '# Review\nNo P1 or P2 open.\n' > "$report"
  printf '%s\n' "$report"
}

expect_gate_refusal() {  # <case-dir> <label> <expected-text> [env assignments...]
  local case_dir=$1 label=$2 want=$3 out status before
  shift 3
  before=$(main_head "$case_dir")
  set +e
  out=$(env "$@" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_DATA_OVERRIDE="$case_dir/data" \
    "$MERGE_LOCAL" task-m1 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "$label: the review gate let the landing through: $out"
  assert_contains "$out" "$want" "$label: the refusal did not say what is missing"
  [ "$(main_head "$case_dir")" = "$before" ] || fail "$label: a refused landing still moved local main"
}

test_review_gate_refuses_without_a_review_line() {
  local case_dir
  case_dir=$(make_gated_case gate-no-line)
  printf 'done: ready in branch fm/task-m1\n' > "$case_dir/state/task-m1.status"
  expect_gate_refusal "$case_dir" gate-no-line 'no "review: passed <report path>" line'
  pass "fm-merge-local review gate refuses a task with no review line"
}

test_review_gate_refuses_a_missing_report() {
  local case_dir
  case_dir=$(make_gated_case gate-no-report)
  printf 'review: passed %s/gone/report.md\n' "$case_dir" > "$case_dir/state/task-m1.status"
  expect_gate_refusal "$case_dir" gate-no-report "the review report $case_dir/gone/report.md"
  pass "fm-merge-local review gate refuses when the named report does not exist"
}

test_review_gate_passes_with_line_and_report() {
  local case_dir report out
  case_dir=$(make_gated_case gate-passes)
  report=$(write_report "$case_dir")
  printf 'working: implemented\nreview: passed %s\ndone: ready in branch fm/task-m1\n' "$report" \
    > "$case_dir/state/task-m1.status"
  out=$(run_merge_local "$case_dir" task-m1 2>&1) \
    || fail "gate-passes: a reviewed task was refused: $out"
  assert_contains "$out" "merged fm/task-m1 into local main" "gate-passes: the reviewed task did not land"
  assert_not_contains "$out" "SHIP REVIEW OVERRIDE" "gate-passes: a passing review was reported as an override"
  pass "fm-merge-local review gate lands a task with a review line and its report"
}

test_review_gate_later_line_withdraws_the_pass() {
  local case_dir report
  case_dir=$(make_gated_case gate-reopened)
  report=$(write_report "$case_dir")
  printf 'review: passed %s\nreview: reopened after rework\n' "$report" > "$case_dir/state/task-m1.status"
  expect_gate_refusal "$case_dir" gate-reopened 'the latest review line'
  pass "fm-merge-local review gate honours only the latest review line"
}

test_review_gate_override_lands_and_is_logged() {
  local case_dir out log
  case_dir=$(make_gated_case gate-override)
  out=$(FM_SHIP_REVIEW_OVERRIDE='captain: prod is down, review after' \
    run_merge_local "$case_dir" task-m1 2>&1) \
    || fail "gate-override: the captain's override did not land the task: $out"
  assert_contains "$out" "merged fm/task-m1 into local main" "gate-override: the override did not land"
  assert_contains "$out" "SHIP REVIEW OVERRIDE" "gate-override: the override was silent on stderr"
  log="$case_dir/data/task-m1/ship-review-overrides.log"
  assert_grep 'captain: prod is down, review after' "$log" "gate-override: the reason was not logged"
  assert_grep 'fm-merge-local.sh task=task-m1' "$log" "gate-override: the log does not name the landing and task"
  pass "fm-merge-local review gate override lands the task and logs the reason"
}

test_review_gate_blank_override_refuses() {
  local case_dir
  case_dir=$(make_gated_case gate-blank-override)
  expect_gate_refusal "$case_dir" gate-blank-override "set but blank" FM_SHIP_REVIEW_OVERRIDE='   '
  assert_absent "$case_dir/data/task-m1/ship-review-overrides.log" \
    "gate-blank-override: a refused override still wrote a log entry"
  pass "fm-merge-local review gate refuses an override with no reason"
}

test_review_gate_malformed_file_refuses() {
  local case_dir
  case_dir=$(make_gated_case gate-malformed)
  printf 'yes please\n' > "$case_dir/config/ship-review-gate"
  expect_gate_refusal "$case_dir" gate-malformed "$case_dir/config/ship-review-gate" \
    FM_SHIP_REVIEW_OVERRIDE='captain says go'
  pass "fm-merge-local review gate refuses a malformed gate file even with an override"
}

test_review_gate_dangling_file_refuses() {
  local case_dir
  case_dir=$(make_gated_case gate-dangling)
  rm -f "$case_dir/config/ship-review-gate"
  ln -s "$case_dir/config/missing-gate" "$case_dir/config/ship-review-gate"
  expect_gate_refusal "$case_dir" gate-dangling "$case_dir/config/ship-review-gate"
  pass "fm-merge-local review gate refuses a dangling gate file"
}

test_review_gate_off_lands_without_review() {
  local case_dir out
  case_dir=$(make_gated_case gate-off)
  printf 'off\n' > "$case_dir/config/ship-review-gate"
  out=$(run_merge_local "$case_dir" task-m1 2>&1) \
    || fail "gate-off: a gate set to off still refused: $out"
  assert_contains "$out" "merged fm/task-m1 into local main" "gate-off: the task did not land"
  pass "fm-merge-local lands without a review when the gate is off"
}

test_recorded_branch_is_the_one_that_lands
test_default_branch_shape_still_lands
test_review_gate_refuses_without_a_review_line
test_review_gate_refuses_a_missing_report
test_review_gate_passes_with_line_and_report
test_review_gate_later_line_withdraws_the_pass
test_review_gate_override_lands_and_is_logged
test_review_gate_blank_override_refuses
test_review_gate_malformed_file_refuses
test_review_gate_dangling_file_refuses
test_review_gate_off_lands_without_review
test_missing_recorded_branch_refuses_by_name
test_non_local_only_task_is_refused
echo "# all fm-merge-local tests passed"
