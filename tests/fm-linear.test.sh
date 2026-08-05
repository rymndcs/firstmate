#!/usr/bin/env bash
# Behavior tests for the Linear status binding: bin/fm-linear.sh and the four
# lifecycle owners that call it (bin/fm-spawn.sh, bin/fm-pr-check.sh,
# bin/fm-pr-merge.sh, bin/fm-merge-local.sh).
#
# The binding exists so the issue transition happens as part of the lifecycle
# step rather than as something an agent remembers afterwards, which means the
# three properties worth pinning are:
#   - it is INVISIBLE when unconfigured or when the task is not Linear-tracked,
#     so every home that never configures Linear behaves exactly as before;
#   - it is LOUD but NEVER blocking when a configured update fails, so a Linear
#     outage cannot stop a spawn, a PR record, or a merge;
#   - it only ever moves an issue FORWARD, so re-running a lifecycle step
#     cannot drag a finished issue back out of the state a later step gave it.
#
# The Linear transport is stubbed with a fakebin `curl` (the same technique
# tests/fm-x-mode.test.sh uses for the relay), so these stay hermetic: no
# network, no credentials, deterministic in CI. jq stays the real tool.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

LINEAR="$ROOT/bin/fm-linear.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
LINEAR_BRANCH=rcs/rac-125-select2-font-size
TMP_ROOT=$(fm_test_tmproot fm-linear-tests)

# A key shaped like a real one, so the "never printed" assertions are meaningful.
API_KEY=lin_api_TESTKEY0000000000000000
export FM_BACKEND=tmux

# The workspace the fake Linear serves: one issue RAC-125 sitting in Todo, on a
# team whose workflow states cover both `started` states plus Done.
LINEAR_ISSUE_BODY='{"data":{"issues":{"nodes":[{"id":"issue-uuid","identifier":"RAC-125","state":{"id":"st-todo","name":"Todo"},"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-prog","name":"In Progress","type":"started","position":2},
  {"id":"st-rev","name":"In Review","type":"started","position":3},
  {"id":"st-done","name":"Done","type":"completed","position":4}]}}}]}}}'

# The same workspace with the issue already sitting in In Progress.
LINEAR_ISSUE_BODY_IN_PROGRESS='{"data":{"issues":{"nodes":[{"id":"issue-uuid","identifier":"RAC-125","state":{"id":"st-prog","name":"In Progress"},"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-prog","name":"In Progress","type":"started","position":2},
  {"id":"st-rev","name":"In Review","type":"started","position":3},
  {"id":"st-done","name":"Done","type":"completed","position":4}]}}}]}}}'

# The same workspace with the issue already in In Review, and already Done: the
# two states a re-run of an earlier lifecycle step must not undo.
LINEAR_ISSUE_BODY_IN_REVIEW='{"data":{"issues":{"nodes":[{"id":"issue-uuid","identifier":"RAC-125","state":{"id":"st-rev","name":"In Review"},"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-prog","name":"In Progress","type":"started","position":2},
  {"id":"st-rev","name":"In Review","type":"started","position":3},
  {"id":"st-done","name":"Done","type":"completed","position":4}]}}}]}}}'

LINEAR_ISSUE_BODY_DONE='{"data":{"issues":{"nodes":[{"id":"issue-uuid","identifier":"RAC-125","state":{"id":"st-done","name":"Done"},"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-prog","name":"In Progress","type":"started","position":2},
  {"id":"st-rev","name":"In Review","type":"started","position":3},
  {"id":"st-done","name":"Done","type":"completed","position":4}]}}}]}}}'

# The same workspace with no In Review state, for the unmatched-state case.
LINEAR_ISSUE_BODY_NO_REVIEW='{"data":{"issues":{"nodes":[{"id":"issue-uuid","identifier":"RAC-125","state":{"id":"st-todo","name":"Todo"},"team":{"states":{"nodes":[
  {"id":"st-todo","name":"Todo","type":"unstarted","position":1},
  {"id":"st-prog","name":"In Progress","type":"started","position":2},
  {"id":"st-done","name":"Done","type":"completed","position":4}]}}}]}}}'

# A fakebin `curl` standing in for the Linear GraphQL endpoint. It records every
# call to FAKE_LINEAR_LOG (full argv, the resolved Authorization header, and the
# request body), then answers from env: FAKE_LINEAR_ISSUE_BODY for the issue
# query, FAKE_LINEAR_HTTP/FAKE_LINEAR_ERROR_BODY to force a rejection, and
# FAKE_LINEAR_CURL_EXIT to simulate a transport failure with no HTTP answer.
make_fake_curl() {
  local fakebin=$1
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" url="" data="" auth=""
argv=$*
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    --data-binary)
      case "$2" in
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H)
      case "$2" in
        @*) while IFS= read -r header; do case "$header" in Authorization:*) auth=$header ;; esac; done < "${2#@}" ;;
        Authorization:*) auth=$2 ;;
      esac
      shift 2
      ;;
    -m|-w|-X) shift 2 ;;
    -s) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
if [ -n "${FAKE_LINEAR_LOG:-}" ]; then
  { echo "argv=$argv"; echo "url=$url"; echo "auth=$auth"; echo "data=$data"; } >> "$FAKE_LINEAR_LOG"
fi
if [ -n "${FAKE_LINEAR_CURL_EXIT:-}" ]; then
  exit "$FAKE_LINEAR_CURL_EXIT"
fi
if [ "${FAKE_LINEAR_HTTP:-200}" != 200 ]; then
  [ -n "$ofile" ] && printf '%s' "${FAKE_LINEAR_ERROR_BODY:-}" > "$ofile"
  printf '%s' "$FAKE_LINEAR_HTTP"
  exit 0
fi
case "$data" in
  *FirstmateIssue*)
    [ -n "$ofile" ] && printf '%s' "${FAKE_LINEAR_ISSUE_BODY:-}" > "$ofile"
    ;;
  *FirstmateTransition*)
    [ -n "$ofile" ] && printf '%s' '{"data":{"issueUpdate":{"success":true}}}' > "$ofile"
    ;;
esac
printf '200'
SH
  chmod +x "$fakebin/curl"
}

# A home with its own state and config directories and a fake Linear on PATH.
# Echoes the home path.
make_home() {  # <name>
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  make_fake_curl "$(fm_fakebin "$home")"
  printf '%s\n' "$home"
}

configure_key() {  # <home>
  printf '%s\n' "$API_KEY" > "$1/config/linear-api-key"
}

# The task record a Linear-tracked task carries: the Linear branch name that
# bin/fm-brief.sh --branch recorded, which is the only thing that resolves an
# issue at all.
write_linear_meta() {  # <home> <task-id>
  fm_write_meta "$1/state/$2.meta" "kind=ship" "branch=$LINEAR_BRANCH"
}

# Run the helper against <home>, with the fake Linear on PATH and its call log
# at <home>/linear.log (truncated first so each case reads only its own calls).
run_linear() {  # <home> <args...>
  local home=$1
  shift
  : > "$home/linear.log"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FAKE_LINEAR_LOG="$home/linear.log" \
    FAKE_LINEAR_ISSUE_BODY="${FAKE_LINEAR_ISSUE_BODY:-$LINEAR_ISSUE_BODY}" \
    FAKE_LINEAR_HTTP="${FAKE_LINEAR_HTTP:-200}" \
    FAKE_LINEAR_ERROR_BODY="${FAKE_LINEAR_ERROR_BODY:-}" \
    FAKE_LINEAR_CURL_EXIT="${FAKE_LINEAR_CURL_EXIT:-}" \
    PATH="$home/fakebin:$PATH" \
    "$LINEAR" "$@"
}

# How many transition requests this case produced.
mutation_calls() {  # <home>
  local n
  n=$(grep -c 'FirstmateTransition' "$1/linear.log" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# The recorded argv of every call, so a test can prove the key never rode in it.
# The log also records the header file's resolved Authorization line, which is
# where the key is supposed to be, so this deliberately reads argv lines only.
write_argv_log() {  # <home>
  grep '^argv=' "$1/linear.log" > "$1/argv.log" || :
  printf '%s\n' "$1/argv.log"
}

# ---------------------------------------------------------------------------

test_no_configured_key_is_a_clean_noop() {
  local home out rc
  home=$(make_home no-key)
  write_linear_meta "$home" rac125-font

  set +e
  out=$(run_linear "$home" transition rac125-font in-progress 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "no-key: an unconfigured home must succeed"
  [ -z "$out" ] || fail "no-key: an unconfigured home must print nothing, got: $out"
  [ ! -s "$home/linear.log" ] || fail "no-key: an unconfigured home must not reach the network"
  pass "an unconfigured home makes no Linear call, says nothing, and succeeds"
}

test_task_without_identifier_is_a_clean_noop() {
  local home out rc
  home=$(make_home no-identifier)
  configure_key "$home"
  fm_write_meta "$home/state/fm-linear-status-binding.meta" \
    "kind=ship" "branch=fm/fm-linear-status-binding"

  set +e
  out=$(run_linear "$home" transition fm-linear-status-binding in-progress 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "no-identifier: a task with no Linear issue must succeed"
  [ -z "$out" ] || fail "no-identifier: a non-Linear task must print nothing, got: $out"
  [ ! -s "$home/linear.log" ] || fail "no-identifier: a non-Linear task must not reach the network"
  pass "a task with no resolvable issue identifier is a silent no-op, not an error"
}

test_identifier_is_read_from_the_recorded_branch() {
  local home out rc
  home=$(make_home branch-identifier)
  configure_key "$home"
  # The task id is shaped like a reference to a completely different issue, so
  # only the recorded Linear branch name may decide which issue moves.
  fm_write_meta "$home/state/abc7-legacy-id.meta" \
    "kind=ship" "branch=$LINEAR_BRANCH"

  out=$(run_linear "$home" resolve abc7-legacy-id) \
    || fail "branch-identifier: resolve failed"
  [ "$out" = RAC-125 ] || fail "branch-identifier: expected RAC-125 from the branch, got '$out'"

  set +e
  run_linear "$home" transition abc7-legacy-id in-progress 2>/dev/null
  rc=$?
  set -e
  expect_code 0 "$rc" "branch-identifier: transition should succeed"
  assert_grep '"key": "RAC"' "$home/linear.log" \
    "branch-identifier: the issue query did not carry the branch's team key"
  assert_grep '"number": 125' "$home/linear.log" \
    "branch-identifier: the issue query did not carry the branch's issue number"
  assert_no_grep '"key": "ABC"' "$home/linear.log" \
    "branch-identifier: the task id was used even though a branch was recorded"
  pass "the issue identifier is extracted from the recorded branch name, never from the task id"
}

test_task_without_a_recorded_branch_is_a_clean_noop() {
  local home out rc
  home=$(make_home no-branch)
  configure_key "$home"
  # This id reads exactly like an issue reference, and is deliberately never
  # treated as one: guessing it would move a real but unrelated RAC-125.
  fm_write_meta "$home/state/rac125-select2-font-size.meta" "kind=ship"

  set +e
  out=$(run_linear "$home" transition rac125-select2-font-size in-progress 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "no-branch: a task with no recorded branch must succeed"
  [ -z "$out" ] || fail "no-branch: a task with no recorded branch must print nothing, got: $out"
  [ ! -s "$home/linear.log" ] \
    || fail "no-branch: a task with no recorded branch must not reach the network"
  out=$(run_linear "$home" resolve rac125-select2-font-size)
  [ -z "$out" ] \
    || fail "no-branch: the task id resolved '$out' on its own, which may never happen"
  pass "a task id that reads like an issue reference resolves nothing without a recorded branch"
}

test_api_failure_is_loud_and_never_prints_the_key() {
  local home err rc
  home=$(make_home api-rejected)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2

  set +e
  err=$(FAKE_LINEAR_HTTP=401 \
    FAKE_LINEAR_ERROR_BODY="{\"errors\":[{\"message\":\"Authentication failed for $API_KEY\"}]}" \
    run_linear "$home" transition rac125-select2 in-progress 2>&1 >/dev/null)
  rc=$?
  set -e

  expect_code 1 "$rc" "api-rejected: a failed Linear update must report failure"
  assert_contains "$err" "LINEAR: RAC-125" "api-rejected: the diagnostic must name the issue"
  assert_contains "$err" "HTTP 401" "api-rejected: the diagnostic must name what Linear said"
  assert_not_contains "$err" "$API_KEY" "api-rejected: the diagnostic leaked the API key"
  assert_no_grep "$API_KEY" "$(write_argv_log "$home")" \
    "api-rejected: the API key reached curl's argv"
  grep -q "Authorization: $API_KEY" "$home/linear.log" \
    || fail "api-rejected: the key must still be delivered through the header file"
  pass "a rejected Linear call fails loudly, names the issue, and never prints the key"
}

test_unreachable_linear_is_loud() {
  local home err rc
  home=$(make_home api-unreachable)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2

  set +e
  err=$(FAKE_LINEAR_CURL_EXIT=7 run_linear "$home" transition rac125-select2 'done' 2>&1 >/dev/null)
  rc=$?
  set -e

  expect_code 1 "$rc" "api-unreachable: a transport failure must report failure"
  assert_contains "$err" "LINEAR: RAC-125" "api-unreachable: the diagnostic must name the issue"
  pass "an unreachable Linear fails loudly rather than silently doing nothing"
}

test_missing_workflow_state_is_loud() {
  local home err rc
  home=$(make_home no-review-state)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2

  set +e
  err=$(FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY_NO_REVIEW" \
    run_linear "$home" transition rac125-select2 in-review 2>&1 >/dev/null)
  rc=$?
  set -e

  expect_code 1 "$rc" "no-review-state: an unmatched workflow state must report failure"
  assert_contains "$err" "no matching workflow state" \
    "no-review-state: the diagnostic must explain that the team has no such state"
  [ "$(mutation_calls "$home")" = 0 ] \
    || fail "no-review-state: no update may be sent when no state matched"
  pass "a team with no matching workflow state is reported rather than guessed at"
}

test_issue_already_in_target_state_sends_no_update() {
  local home out rc
  home=$(make_home already-there)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2

  set +e
  out=$(FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY_IN_PROGRESS" \
    run_linear "$home" transition rac125-select2 in-progress 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "already-there: an issue already in the target state must succeed"
  [ -z "$out" ] || fail "already-there: nothing should be reported, got: $out"
  [ "$(mutation_calls "$home")" = 0 ] \
    || fail "already-there: an issue already in the target state must not be updated"
  pass "an issue already in the target state is left alone without an update"
}

test_a_finished_issue_is_never_moved_back_to_in_review() {
  local home out rc
  home=$(make_home forward-done)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2

  set +e
  out=$(FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY_DONE" \
    run_linear "$home" transition rac125-select2 in-review 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "forward-done: a step re-run against a finished issue must succeed"
  [ -z "$out" ] || fail "forward-done: nothing should be reported, got: $out"
  [ "$(mutation_calls "$home")" = 0 ] \
    || fail "forward-done: a Done issue must never be dragged back to In Review"
  pass "a Done issue asked for In Review keeps its state, so re-running a merge cannot reopen it"
}

test_an_in_review_issue_is_never_moved_back_to_in_progress() {
  local home out rc
  home=$(make_home forward-review)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2

  set +e
  out=$(FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY_IN_REVIEW" \
    run_linear "$home" transition rac125-select2 in-progress 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "forward-review: a re-dispatch of a reviewed task must succeed"
  [ -z "$out" ] || fail "forward-review: nothing should be reported, got: $out"
  [ "$(mutation_calls "$home")" = 0 ] \
    || fail "forward-review: an In Review issue must never be dragged back to In Progress"
  pass "an In Review issue asked for In Progress keeps its state, so a re-dispatch cannot undo the review"
}

test_transition_targets_each_lifecycle_state() {
  local home rc transition expected
  home=$(make_home each-state)
  configure_key "$home"
  write_linear_meta "$home" rac125-select2
  while IFS='|' read -r transition expected; do
    [ -n "$transition" ] || continue
    set +e
    run_linear "$home" transition rac125-select2 "$transition" 2>/dev/null
    rc=$?
    set -e
    expect_code 0 "$rc" "each-state: $transition should succeed"
    assert_grep "\"stateId\": \"$expected\"" "$home/linear.log" \
      "each-state: $transition did not target $expected"
  done <<'ROWS'
in-progress|st-prog
in-review|st-rev
done|st-done
ROWS
  pass "in-progress, in-review, and done each target their own workflow state"
}

# --- lifecycle owners -------------------------------------------------------

# gh-axi/gh mocks matching tests/fm-pr-merge.test.sh: gh-axi records every call,
# gh answers fm-pr-check.sh's pr_head lookup.
add_forge_mocks() {  # <home> [merge-fails]
  local home=$1 merge_fails=${2-}
  local fakebin="$home/fakebin"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$FM_TEST_GH_AXI_LOG"
case "\${1:-} \${2:-}" in
  "pr merge") [ -z "$merge_fails" ] || { echo "error: pr merge failed" >&2; exit 1; } ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefOid*) printf '%s\n' deadbeefcafefeed0000000000000000deadbeef ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
}

make_pr_home() {  # <name>
  local home
  home=$(make_home "$1")
  configure_key "$home"
  add_forge_mocks "$home"
  mkdir -p "$home/wt"
  fm_write_meta "$home/state/rac125-font.meta" \
    "window=fm-rac125-font" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "branch=$LINEAR_BRANCH"
  printf '%s\n' "$home"
}

run_pr_script() {  # <script> <home> <args...>
  local script=$1 home=$2
  shift 2
  : > "$home/linear.log"
  : > "$home/gh-axi.log"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TEST_GH_AXI_LOG="$home/gh-axi.log" \
    FAKE_LINEAR_LOG="$home/linear.log" \
    FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY" \
    FAKE_LINEAR_HTTP="${FAKE_LINEAR_HTTP:-200}" \
    FAKE_LINEAR_CURL_EXIT="${FAKE_LINEAR_CURL_EXIT:-}" \
    PATH="$home/fakebin:$PATH" \
    "$script" "$@"
}

test_pr_check_moves_the_issue_to_in_review() {
  local home out rc
  home=$(make_pr_home pr-check-review)

  set +e
  out=$(run_pr_script "$PR_CHECK" "$home" rac125-font https://github.com/example/repo/pull/9 2>/dev/null)
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-check-review: recording the PR should succeed"
  assert_contains "$out" "armed: state/rac125-font.check.sh" \
    "pr-check-review: the PR record must still arm its merge poll"
  assert_grep '"stateId": "st-rev"' "$home/linear.log" \
    "pr-check-review: recording a PR did not move the issue to In Review"
  pass "recording a PR against a task moves its Linear issue to In Review"
}

test_pr_check_survives_a_linear_failure() {
  local home out err rc
  home=$(make_pr_home pr-check-linear-down)

  set +e
  out=$(FAKE_LINEAR_CURL_EXIT=7 \
    run_pr_script "$PR_CHECK" "$home" rac125-font https://github.com/example/repo/pull/11 \
    2> "$home/stderr")
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "pr-check-linear-down: a Linear outage must not fail the PR record"
  assert_contains "$out" "armed: state/rac125-font.check.sh" \
    "pr-check-linear-down: the merge poll must still be armed"
  assert_grep 'pr=https://github.com/example/repo/pull/11' "$home/state/rac125-font.meta" \
    "pr-check-linear-down: the PR must still be recorded in the task record"
  assert_contains "$err" "LINEAR: RAC-125" \
    "pr-check-linear-down: the Linear failure must be reported"
  pass "a Linear outage is reported but never blocks recording a PR"
}

test_pr_merge_moves_the_issue_to_done() {
  local home rc
  home=$(make_pr_home pr-merge-done)

  set +e
  run_pr_script "$PR_MERGE" "$home" rac125-font https://github.com/example/repo/pull/12 >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-merge-done: the merge should succeed"
  assert_grep 'pr merge 12 --repo example/repo --squash' "$home/gh-axi.log" \
    "pr-merge-done: the merge itself must still run"
  assert_grep '"stateId": "st-done"' "$home/linear.log" \
    "pr-merge-done: a confirmed merge did not move the issue to Done"
  pass "a confirmed merge moves its Linear issue to Done"
}

test_pr_merge_survives_a_linear_failure() {
  local home err rc
  home=$(make_pr_home pr-merge-linear-down)

  set +e
  FAKE_LINEAR_CURL_EXIT=7 \
    run_pr_script "$PR_MERGE" "$home" rac125-font https://github.com/example/repo/pull/13 \
    >/dev/null 2> "$home/stderr"
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "pr-merge-linear-down: a Linear outage must not fail the merge"
  assert_grep 'pr merge 13 --repo example/repo --squash' "$home/gh-axi.log" \
    "pr-merge-linear-down: the merge must still happen while Linear is down"
  assert_contains "$err" "LINEAR: RAC-125" \
    "pr-merge-linear-down: the Linear failure must be reported"
  pass "a Linear outage is reported but never blocks a merge"
}

test_pr_merge_does_not_close_a_failed_merge() {
  local home rc
  home=$(make_pr_home pr-merge-failed)
  add_forge_mocks "$home" merge-fails

  set +e
  run_pr_script "$PR_MERGE" "$home" rac125-font https://github.com/example/repo/pull/15 >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-merge-failed: a failed merge must still be reported as a failure"
  assert_no_grep '"stateId": "st-done"' "$home/linear.log" \
    "pr-merge-failed: a merge that did not land must not close the issue"
  pass "a merge that failed leaves the issue open rather than reporting it Done"
}

test_pr_merge_does_not_close_an_auto_merge() {
  local home rc
  home=$(make_pr_home pr-merge-auto)

  set +e
  run_pr_script "$PR_MERGE" "$home" rac125-font https://github.com/example/repo/pull/14 -- --auto \
    >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-merge-auto: queuing an auto-merge should succeed"
  assert_no_grep '"stateId": "st-done"' "$home/linear.log" \
    "pr-merge-auto: a merge only queued for later must not be reported as Done"
  pass "an auto-merge is queued rather than confirmed, so the issue is not closed yet"
}

test_pr_merge_does_not_close_an_auto_equals_merge() {
  local home rc
  home=$(make_pr_home pr-merge-auto-equals)

  set +e
  run_pr_script "$PR_MERGE" "$home" rac125-font https://github.com/example/repo/pull/16 -- --auto=true \
    >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-merge-auto-equals: queuing an auto-merge should succeed"
  assert_no_grep '"stateId": "st-done"' "$home/linear.log" \
    "pr-merge-auto-equals: the --auto=<value> spelling still only queues the merge"
  pass "an auto-merge written as --auto=true is recognised as queued rather than confirmed"
}

# --- approved local-only landing --------------------------------------------

# A home whose project sits on main with a landable task branch, plus the fake
# Linear already on PATH: the shape bin/fm-merge-local.sh needs to fast-forward.
make_local_merge_home() {  # <name>
  local name=$1 home
  home=$(make_home "$name")
  configure_key "$home"
  fm_git_init_commit "$home/project"
  git -C "$home/project" branch -M main
  git -C "$home/project" worktree add -q -b "$LINEAR_BRANCH" "$home/wt" main
  printf 'landed\n' > "$home/wt/feature.txt"
  git -C "$home/wt" add feature.txt
  git -C "$home/wt" commit -qm "task work"
  touch "$home/state/.last-watcher-beat"
  fm_write_meta "$home/state/rac125-font.meta" \
    "window=firstmate:fm-rac125-font" \
    "worktree=$home/wt" \
    "project=$home/project" \
    "kind=ship" \
    "mode=local-only" \
    "branch=$LINEAR_BRANCH"
  printf '%s\n' "$home"
}

run_merge_local() {  # <home> <args...>
  local home=$1
  shift
  : > "$home/linear.log"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FAKE_LINEAR_LOG="$home/linear.log" \
    FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY" \
    FAKE_LINEAR_HTTP="${FAKE_LINEAR_HTTP:-200}" \
    FAKE_LINEAR_CURL_EXIT="${FAKE_LINEAR_CURL_EXIT:-}" \
    PATH="$home/fakebin:$PATH" \
    "$MERGE_LOCAL" "$@"
}

landed_head() {  # <home>
  [ "$(git -C "$1/project" rev-parse main)" = "$(git -C "$1/wt" rev-parse "$LINEAR_BRANCH")" ]
}

test_local_merge_moves_the_issue_to_done() {
  local home out rc
  home=$(make_local_merge_home local-merge-done)

  set +e
  out=$(run_merge_local "$home" rac125-font 2>/dev/null)
  rc=$?
  set -e

  expect_code 0 "$rc" "local-merge-done: the approved landing should succeed"
  assert_contains "$out" "into local main" \
    "local-merge-done: the fast-forward must still report what it landed"
  landed_head "$home" || fail "local-merge-done: local main was not fast-forwarded"
  assert_grep '"stateId": "st-done"' "$home/linear.log" \
    "local-merge-done: an approved local landing did not move the issue to Done"
  pass "an approved local-only landing moves its Linear issue to Done"
}

test_local_merge_survives_a_linear_failure() {
  local home out err rc
  home=$(make_local_merge_home local-merge-linear-down)

  set +e
  out=$(FAKE_LINEAR_CURL_EXIT=7 run_merge_local "$home" rac125-font 2> "$home/stderr")
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "local-merge-linear-down: a Linear outage must not fail the landing"
  assert_contains "$out" "into local main" \
    "local-merge-linear-down: the fast-forward must still land while Linear is down"
  landed_head "$home" \
    || fail "local-merge-linear-down: local main was not fast-forwarded"
  assert_contains "$err" "LINEAR: RAC-125" \
    "local-merge-linear-down: the Linear failure must be reported"
  pass "a Linear outage is reported but never blocks an approved local landing"
}

# --- spawn ------------------------------------------------------------------

# Fake tmux answering the pane-path query and swallowing every send, so a spawn
# completes with no terminal. Paired with the fake curl already in this fakebin.
make_spawn_fakebin() {  # <home>
  local home=$1
  local fakebin="$home/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
}

# A home ready for one real fm-spawn.sh run against a real git worktree, with a
# ship brief whose delivery contract carries the Linear branch name. <branch>
# defaults to that name and an empty <branch> scaffolds the brief the way
# bin/fm-brief.sh does without --branch, recording no branch at all. <body> is an
# extra brief line, for the task material an issue identifier arrives in.
make_spawn_home() {  # <name> <task-id> [<branch>] [<body>]
  local name=$1 id=$2 home delivery
  local branch=${3-$LINEAR_BRANCH} body=${4-}
  home=$(make_home "$name")
  configure_key "$home"
  make_spawn_fakebin "$home"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$home/project" "$home/wt" "wt-$name"
  mkdir -p "$home/data/$id"
  delivery="Delivery contract: mode=no-mistakes"
  [ -z "$branch" ] || delivery="$delivery branch=$branch"
  {
    printf 'brief for %s\n' "$id"
    [ -z "$body" ] || printf '%s\n' "$body"
    printf '%s\n' "$delivery"
  } > "$home/data/$id/brief.md"
  printf '%s\n' "$home"
}

run_spawn() {  # <home> <task-id>
  local home=$1 id=$2
  : > "$home/linear.log"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$home/wt" TMUX="fake,1,0" \
    FAKE_LINEAR_LOG="$home/linear.log" \
    FAKE_LINEAR_ISSUE_BODY="$LINEAR_ISSUE_BODY" \
    FAKE_LINEAR_HTTP="${FAKE_LINEAR_HTTP:-200}" \
    FAKE_LINEAR_CURL_EXIT="${FAKE_LINEAR_CURL_EXIT:-}" \
    PATH="$home/fakebin:$PATH" \
    "$SPAWN" "$id" "$home/project" --mode no-mistakes --yolo off
}

test_spawn_moves_the_issue_to_in_progress() {
  local home out rc
  home=$(make_spawn_home spawn-progress rac125-font)

  set +e
  out=$(run_spawn "$home" rac125-font 2>/dev/null)
  rc=$?
  set -e

  expect_code 0 "$rc" "spawn-progress: the spawn should succeed"
  assert_contains "$out" "spawned rac125-font" "spawn-progress: the spawn should report success"
  assert_grep '"stateId": "st-prog"' "$home/linear.log" \
    "spawn-progress: dispatching the task did not move the issue to In Progress"
  pass "dispatching a Linear-tracked task moves its issue to In Progress"
}

test_spawn_survives_a_linear_failure() {
  local home out err rc
  home=$(make_spawn_home spawn-linear-down rac125-font)

  set +e
  out=$(FAKE_LINEAR_CURL_EXIT=7 run_spawn "$home" rac125-font 2> "$home/stderr")
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "spawn-linear-down: a Linear outage must not fail the spawn"
  assert_contains "$out" "spawned rac125-font" \
    "spawn-linear-down: the task must still be dispatched while Linear is down"
  assert_grep 'window=' "$home/state/rac125-font.meta" \
    "spawn-linear-down: the task record must still be written"
  assert_contains "$err" "LINEAR: RAC-125" \
    "spawn-linear-down: the Linear failure must be reported"
  pass "a Linear outage is reported but never blocks a dispatch"
}

test_spawn_names_a_linear_task_scaffolded_without_a_branch() {
  local home out err rc
  home=$(make_spawn_home spawn-no-branch rac125-font "" "Fixes RAC-125: the Select2 font size.")

  set +e
  out=$(run_spawn "$home" rac125-font 2> "$home/stderr")
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "spawn-no-branch: the spawn must not be refused"
  assert_contains "$out" "spawned rac125-font" \
    "spawn-no-branch: the task must still be dispatched"
  assert_contains "$err" "rac125-font" \
    "spawn-no-branch: the diagnostic must name the task"
  assert_contains "$err" "RAC-125" \
    "spawn-no-branch: the diagnostic must name the issue the brief states"
  assert_contains "$err" "--branch" \
    "spawn-no-branch: the diagnostic must say how the gap is closed at intake"
  [ ! -s "$home/linear.log" ] \
    || fail "spawn-no-branch: detecting an identifier must never call Linear"
  pass "a Linear brief scaffolded without its branch is named loudly, and still spawns"
}

test_spawn_with_a_recorded_branch_says_nothing_about_intake() {
  local home err rc
  home=$(make_spawn_home spawn-branch-quiet rac125-font "$LINEAR_BRANCH" \
    "Fixes RAC-125: the Select2 font size.")

  set +e
  run_spawn "$home" rac125-font > /dev/null 2> "$home/stderr"
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "spawn-branch-quiet: the spawn should succeed"
  assert_not_contains "$err" "records no branch" \
    "spawn-branch-quiet: a properly scaffolded task must not be complained about"
  assert_grep '"stateId": "st-prog"' "$home/linear.log" \
    "spawn-branch-quiet: the dispatch should transition the issue as usual"
  pass "a Linear brief that recorded its branch transitions quietly, with no complaint"
}

test_spawn_without_any_linear_issue_stays_silent() {
  local home err rc
  home=$(make_spawn_home spawn-not-linear plain-task "" "Tidy the config loader.")

  set +e
  run_spawn "$home" plain-task > /dev/null 2> "$home/stderr"
  rc=$?
  set -e
  err=$(cat "$home/stderr")

  expect_code 0 "$rc" "spawn-not-linear: the spawn should succeed"
  assert_not_contains "$err" "Linear" \
    "spawn-not-linear: work that is not Linear-tracked must not be complained about"
  [ ! -s "$home/linear.log" ] \
    || fail "spawn-not-linear: a task with no identifier must not reach the network"
  pass "a task with no Linear issue anywhere spawns silently and calls nothing"
}

test_no_configured_key_is_a_clean_noop
test_task_without_identifier_is_a_clean_noop
test_identifier_is_read_from_the_recorded_branch
test_task_without_a_recorded_branch_is_a_clean_noop
test_api_failure_is_loud_and_never_prints_the_key
test_unreachable_linear_is_loud
test_missing_workflow_state_is_loud
test_issue_already_in_target_state_sends_no_update
test_a_finished_issue_is_never_moved_back_to_in_review
test_an_in_review_issue_is_never_moved_back_to_in_progress
test_transition_targets_each_lifecycle_state
test_pr_check_moves_the_issue_to_in_review
test_pr_check_survives_a_linear_failure
test_pr_merge_moves_the_issue_to_done
test_pr_merge_survives_a_linear_failure
test_pr_merge_does_not_close_a_failed_merge
test_pr_merge_does_not_close_an_auto_merge
test_pr_merge_does_not_close_an_auto_equals_merge
test_local_merge_moves_the_issue_to_done
test_local_merge_survives_a_linear_failure
test_spawn_moves_the_issue_to_in_progress
test_spawn_survives_a_linear_failure
test_spawn_names_a_linear_task_scaffolded_without_a_branch
test_spawn_with_a_recorded_branch_says_nothing_about_intake
test_spawn_without_any_linear_issue_stays_silent
