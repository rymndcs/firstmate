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
  mkdir -p "$case_dir/state"

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

test_recorded_branch_is_the_one_that_lands
test_default_branch_shape_still_lands
test_missing_recorded_branch_refuses_by_name
test_non_local_only_task_is_refused
echo "# all fm-merge-local tests passed"
