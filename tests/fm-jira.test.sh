#!/usr/bin/env bash
set -eu
# shellcheck source=tests/pr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-helpers.sh"
export JIRA_LOG="$PR_TMP/jira.log"
: > "$JIRA_LOG"
printf '%s\n' '- thanos [no-mistakes] - team review' > "$FM_HOME/data/projects.md"
cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
exit "${JIRA_EXIT:-0}"
FAKE
chmod +x "$PR_TMP/fakebin/jira"
write_pr_task task-a 'project=/projects/thanos' 'branch=rcs/swvl-8080-contact-created'
register_pr task-a
[ "$(cat "$JIRA_LOG")" = 'issue|move|SWVL-8080|Ready for Review' ] || fail 'recording a Thanos PR must move only its ticket status to Ready for Review'
register_pr task-a
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 1 ] || fail 'repeated registration must not repeat the ready move'
pass 'PR recording moves the Thanos ticket to Ready for Review once'
FM_TEST_GH_STATE=MERGED
[ "$(poll_pr)" = merged ] || fail 'Jira must preserve the exact merge result'
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'an externally merged PR must move its Jira ticket'
[ "$(sed -n '2p' "$JIRA_LOG")" = 'issue|move|SWVL-8080|Done' ] || fail 'external merge must move only status to Done'
poll_pr > /dev/null
register_pr task-a
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'repeated merge wake or registration must never repeat or reverse Done'
pass 'external merge moves to Done once across repeated polls'
write_pr_task task-duplicate 'project=/projects/thanos' 'branch=rcs/swvl-8080-contact-created'
register_pr task-duplicate
poll_pr > /dev/null
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'two registrations for one PR must not repeat a Jira move'
pass 'duplicate PR registrations share transition receipts'
write_pr_task task-other 'project=/projects/wms' 'branch=rcs/swvl-9090-not-thanos'
"$PR_CODE/bin/fm-pr-check.sh" task-other https://github.com/owner/repo/pull/43 > /dev/null 2>&1
poll_pr 43 > /dev/null
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'non-Thanos work must not reach Jira'
pass 'other projects remain untouched'
write_pr_task task-fail 'project=/projects/thanos' 'branch=rcs/swvl-8081-appointment'
JIRA_EXIT=1 "$PR_CODE/bin/fm-pr-check.sh" task-fail https://github.com/owner/repo/pull/44 > "$PR_TMP/fail.out" 2> "$PR_TMP/fail.err" || fail 'Jira failure must not fail registration'
assert_grep 'move SWVL-8081 to Ready for Review yourself' "$PR_TMP/fail.err" 'failure must identify the manual ticket move'
[ "$(grep -c '^JIRA:' "$PR_TMP/fail.err")" = 1 ] || fail 'Jira failure must print exactly one diagnostic'
pass 'CLI failure prints one manual move and leaves lifecycle successful'
write_pr_task task-missing 'project=/projects/thanos' 'branch=rcs/swvl-8082-missing'
printf 'pr=%s\n' https://github.com/owner/repo/pull/45 >> "$FM_HOME/state/task-missing.meta"
mkdir "$PR_TMP/missingbin"
for tool in bash dirname sed tr awk stat uname mkdir mktemp chmod mv cat grep rm readlink ps date ln sleep basename rmdir base64; do
  ln -s "$(command -v "$tool")" "$PR_TMP/missingbin/$tool"
done
missing_out=$(PATH="$PR_TMP/missingbin" "$PR_CODE/bin/fm-jira.sh" transition task-missing 'done' 2>&1) || fail 'missing CLI must exit 0'
assert_contains "$missing_out" 'move SWVL-8082 to Done yourself' 'missing CLI must name the manual move'
pass 'missing CLI prints the manual move and exits 0'
cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'api /repos/owner/repo/pulls/46'|'api /repos/owner/repo/pulls/52')
    [ "$3" = --jq ] && [ "$4" = '.title + " " + .head.ref' ] || exit 2
    printf 'api_response:\n  body: %s\n  truncated: false\n' "${FAKE_GH_TITLE-fix: SWVL-8083 title fallback}" ;;
  'pr merge') exit "${MERGE_EXIT:-0}" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$PR_TMP/fakebin/gh-axi"
write_pr_task task-title 'project=/projects/thanos' 'branch=generic-branch'
"$PR_CODE/bin/fm-pr-check.sh" task-title https://github.com/owner/repo/pull/46 > /dev/null 2>&1
assert_grep 'issue|move|SWVL-8083|Ready for Review' "$JIRA_LOG" 'title must resolve when the task branch carries no ticket'
[ "$(cat "$FM_HOME/state/jira/github.com/owner/repo/46/transitions")" = in-review ] || fail 'lookup output must not leak into the transition receipt'
pass 'ticket resolution falls back to the PR title'
fm_fake_exit0 "$PR_CODE/bin" fm-protected-paths.sh
write_pr_task task-merge 'project=/projects/thanos' 'branch=rcs/swvl-8084-merge'
"$PR_CODE/bin/fm-pr-merge.sh" task-merge https://github.com/owner/repo/pull/47 > /dev/null 2>&1 || fail 'successful merge must remain successful'
assert_grep 'issue|move|SWVL-8084|Done' "$JIRA_LOG" 'explicit successful merge must move to Done'
count=$(wc -l < "$JIRA_LOG")
poll_pr 47 > /dev/null
[ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'poll after explicit merge must not repeat Done'
pass 'explicit merge and external merge share Done receipts'
write_pr_task task-auto 'project=/projects/thanos' 'branch=rcs/swvl-8085-auto'
"$PR_CODE/bin/fm-pr-merge.sh" task-auto https://github.com/owner/repo/pull/48 -- --auto > /dev/null 2>&1
assert_no_grep 'issue|move|SWVL-8085|Done' "$JIRA_LOG" 'queued auto-merge must not close Jira'
write_pr_task task-rejected 'project=/projects/thanos' 'branch=rcs/swvl-8086-failed'
if MERGE_EXIT=1 "$PR_CODE/bin/fm-pr-merge.sh" task-rejected https://github.com/owner/repo/pull/49 > /dev/null 2>&1; then
  fail 'failed merge must retain its failure'
fi
assert_no_grep 'issue|move|SWVL-8086|Done' "$JIRA_LOG" 'failed merge must not close Jira'
FM_TEST_GH_STATE=CLOSED
poll_pr 49 > /dev/null
assert_no_grep 'issue|move|SWVL-8086|Done' "$JIRA_LOG" 'closed unmerged PR must not close Jira'
pass 'queued, failed and closed unmerged PRs do not move to Done'
write_pr_task task-concurrent 'project=/projects/thanos' 'branch=rcs/swvl-8087-concurrent'
"$PR_CODE/bin/fm-pr-check.sh" task-concurrent https://github.com/owner/repo/pull/50 > /dev/null 2>&1
FM_TEST_GH_STATE=MERGED
poll_pr 50 > /dev/null &
first=$!
poll_pr 50 > /dev/null &
second=$!
wait "$first"
wait "$second"
[ "$(grep -c 'issue|move|SWVL-8087|Done' "$JIRA_LOG")" = 1 ] || fail 'overlapping polls must move Jira once'
pass 'overlapping merge observations serialize one Jira move'
write_pr_task task-merge-fail 'project=/projects/thanos' 'branch=rcs/swvl-8088-outage'
"$PR_CODE/bin/fm-pr-check.sh" task-merge-fail https://github.com/owner/repo/pull/51 > /dev/null 2>&1
[ "$(JIRA_EXIT=1 poll_pr 51 2>/dev/null)" = merged ] || fail 'Jira outage must preserve merged output'
drain_pr > "$PR_TMP/manual-wake"
assert_grep 'move SWVL-8088 to Done yourself' "$PR_TMP/manual-wake" 'merge polling discards stderr, so manual Jira move must survive in the wake'
JIRA_EXIT=1 poll_pr 51 > /dev/null 2>&1
drain_pr > "$PR_TMP/manual-repeat"
assert_no_grep 'move SWVL-8088' "$PR_TMP/manual-repeat" 'repeated wake must not duplicate the manual-move notification'
pass 'merge-poll failures deliver the manual move durably once'
count=$(wc -l < "$JIRA_LOG")
write_pr_task task-no-key 'project=/projects/thanos' 'branch=generic'
FAKE_GH_TITLE='ordinary maintenance' "$PR_CODE/bin/fm-pr-check.sh" task-no-key https://github.com/owner/repo/pull/52 > /dev/null 2>&1
[ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'a Thanos PR without an SWVL key must not move an unrelated issue'
write_pr_task task-unregistered 'project=/projects/thanos' 'branch=rcs/swvl-8089-unregistered'
printf '%s\n' '- wms [no-mistakes]' > "$FM_HOME/data/projects.md"
"$PR_CODE/bin/fm-pr-check.sh" task-unregistered https://github.com/owner/repo/pull/53 > /dev/null 2>&1
poll_pr 53 > /dev/null
[ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'Jira moves require the Thanos registry entry'
printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
pass 'missing ticket keys and unregistered projects stay silent'
write_pr_task task-done-first 'project=/projects/thanos' 'branch=rcs/swvl-8090-done-first'
printf 'pr=%s\n' https://github.com/owner/repo/pull/54 >> "$FM_HOME/state/task-done-first.meta"
poll_pr 54 > /dev/null
assert_grep 'issue|move|SWVL-8090|Done' "$JIRA_LOG" 'merge seen before registration must still move to Done'
"$PR_CODE/bin/fm-pr-check.sh" task-done-first https://github.com/owner/repo/pull/54 > /dev/null 2>&1
assert_no_grep 'issue|move|SWVL-8090|Ready for Review' "$JIRA_LOG" 'a later ready event must never reopen Done'
pass 'a merge observed first cannot be reversed by later registration'

jira_ordering_regression() {
  write_pr_task task-order 'project=/projects/thanos' 'branch=rcs/swvl-9998-order'
  printf 'pr=%s\n' https://github.com/owner/repo/pull/60 >> "$FM_HOME/state/task-order.meta"
  export JIRA_MERGE_OUTPUT="$PR_TMP/merge-order.out"
  cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
[ "$(cat "$JIRA_MERGE_OUTPUT")" = merged ] || printf 'jira-before-merged\n' >> "$JIRA_LOG"
exit 0
FAKE
  poll_pr 60 > "$JIRA_MERGE_OUTPUT"
  assert_no_grep jira-before-merged "$JIRA_LOG" 'merged must be visible before Jira starts, not merely returned eventually'
  [ "$(cat "$JIRA_MERGE_OUTPUT")" = merged ] || fail 'merge-first output must remain exactly merged'
  pass 'merge output is visible before the Jira executable starts'
}

jira_deadline_regressions() {
  # shellcheck source=bin/fm-watch.sh
  . "$PR_CODE/bin/fm-watch.sh"
  CHECK_TIMEOUT=4
  export FM_CHECK_FORCE_FALLBACK=1 FM_JIRA_TIMEOUT=1
  export JIRA_BLOCK_FIFO="$PR_TMP/jira-block"
  mkfifo "$JIRA_BLOCK_FIFO"
  cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
if [ "$4" = Done ]; then
  trap '' TERM
  read -r _ < "$JIRA_BLOCK_FIFO"
fi
exit 0
FAKE
  write_pr_task task-stalled 'project=/projects/thanos' 'branch=rcs/swvl-9999-stalled'
  stalled_url=https://github.com/owner/repo/pull/61
  "$PR_CODE/bin/fm-pr-check.sh" task-stalled "$stalled_url" > /dev/null 2>&1
  write_pr_task task-stalled-duplicate 'project=/projects/thanos' 'branch=rcs/swvl-9999-stalled'
  printf 'pr=%s\n' "$stalled_url" >> "$FM_HOME/state/task-stalled-duplicate.meta"
  for attempt in 1 2; do
    run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github "$stalled_url" github.com owner/repo 61
    [ "$FM_CHECK_RESULT" = merged ] || fail "stalled Jira attempt $attempt must return exactly merged through production capture"
    drain_pr > "$PR_TMP/stalled-wake-$attempt"
    assert_grep 'move SWVL-9999 to Done yourself' "$PR_TMP/stalled-wake-$attempt" 'stalled Jira must deliver the manual instruction before the production deadline'
    assert_no_grep 'done' "$FM_HOME/state/jira/github.com/owner/repo/61/transitions" 'a timed-out move must remain retryable'
    assert_absent "$FM_HOME/state/jira/github.com/owner/repo/61/transition.lock" 'a timed-out move must release its own transition lock'
    for pending in "$FM_HOME/state/jira/github.com/owner/repo/61"/.transition.*; do
      assert_absent "$pending" 'a timed-out move must remove its partial receipt'
    done
  done
  [ "$(grep -c 'issue|move|SWVL-9999|Done' "$JIRA_LOG")" = 2 ] || fail 'each observation may retry a timed-out Jira move only once'
  pass 'two stalled FIFO moves preserve merged, durable manual instructions, and one attempt per wake'

  "$PR_CODE/bin/fm-jira.sh" transition task-stalled 'done' > "$PR_TMP/stalled.out" 2> "$PR_TMP/stalled.err"
  [ ! -s "$PR_TMP/stalled.out" ] || fail 'Jira timeout must not add stdout'
  assert_grep 'move SWVL-9999 to Done yourself' "$PR_TMP/stalled.err" 'timeout must preserve the existing stderr instruction'
  pass 'a Jira deadline preserves the stderr manual instruction and exits successfully'

  cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
exit 0
FAKE
  run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github "$stalled_url" github.com owner/repo 61
  [ "$FM_CHECK_RESULT" = merged ] || fail 'immediate-success Jira control must preserve merged'
  assert_grep 'done' "$FM_HOME/state/jira/github.com/owner/repo/61/transitions" 'the fast control must publish Done'
  count=$(wc -l < "$JIRA_LOG")
  poll_pr 61 > /dev/null
  [ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'successful retry must restore receipt deduplication'
  pass 'immediate-success control completes the move and deduplicates later observations'

  write_pr_task task-locked 'project=/projects/thanos' 'branch=rcs/swvl-9997-lock'
  printf 'pr=%s\n' https://github.com/owner/repo/pull/62 >> "$FM_HOME/state/task-locked.meta"
  lock="$FM_HOME/state/jira/github.com/owner/repo/62/transition.lock"
  mkdir -p "$(dirname "$lock")"
  fm_lock_try_acquire "$lock" || fail 'fixture must own a live transition lock'
  lock_owner=$FM_LOCK_OWNER_DIR
  run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/owner/repo/pull/62 github.com owner/repo 62
  [ "$FM_CHECK_RESULT" = merged ] || fail 'transition-lock wait must not swallow merged'
  drain_pr > "$PR_TMP/locked-wake"
  assert_grep 'move SWVL-9997 to Done yourself' "$PR_TMP/locked-wake" 'transition-lock deadline must deliver the manual instruction'
  fm_lock_points_to_owner "$lock" "$lock_owner" || fail 'deadline must preserve another live lock owner'
  fm_lock_release "$lock"
  pass 'a live transition lock has a deadline and retains its existing owner'

  cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
trap '' TERM
read -r _ < "$JIRA_BLOCK_FIFO"
FAKE
  write_pr_task task-lookup 'project=/projects/thanos' 'branch=generic'
  printf 'pr=%s\n' https://github.com/owner/repo/pull/63 >> "$FM_HOME/state/task-lookup.meta"
  run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/owner/repo/pull/63 github.com owner/repo 63
  [ "$FM_CHECK_RESULT" = merged ] || fail 'stalled title lookup must not swallow merged'
  drain_pr > "$PR_TMP/lookup-wake"
  assert_grep 'move https://github.com/owner/repo/pull/63 to Done yourself' "$PR_TMP/lookup-wake" 'an unresolved lookup timeout must identify its PR in the manual instruction'
  pass 'a stalled prerequisite lookup delivers merged and identifies the PR for its manual move'
}

jira_installed_deadlines() {
  # shellcheck source=bin/fm-watch.sh
  . "$PR_CODE/bin/fm-watch.sh"
  CHECK_TIMEOUT=4
  export FM_CHECK_FORCE_FALLBACK=1 FM_JIRA_TIMEOUT=1
  export JIRA_BLOCK_FIFO="$PR_TMP/installed-jira-block" JIRA_PID_FILE="$PR_TMP/installed-jira.pid"
  mkfifo "$JIRA_BLOCK_FIFO"
  cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
trap '' TERM
printf '%s\n' "$$" > "$JIRA_PID_FILE"
read -r _ < "$JIRA_BLOCK_FIFO"
FAKE
  cat > "$PR_TMP/deadline" <<'FAKE'
#!/usr/bin/env perl
use strict;
use warnings;
my $grace;
$grace = $1 if $ARGV[0] =~ /^--kill-after=(.*)/ && shift @ARGV;
my $timeout = shift;
my $pid = fork;
die 'fork failed' unless defined $pid;
if (!$pid) { setpgrp(0, 0); exec @ARGV; die 'exec failed'; }
my $stop = sub { kill 'KILL', -$pid; waitpid $pid, 0; exit 124; };
local $SIG{TERM} = $stop;
local $SIG{HUP} = $stop;
local $SIG{INT} = $stop;
my $expired = 0;
local $SIG{ALRM} = sub {
  $stop->() if $expired++;
  kill 'TERM', -$pid;
  alarm $grace if defined $grace;
};
alarm $timeout;
while (waitpid($pid, 0) < 0) {}
exit($? >> 8);
FAKE
  chmod +x "$PR_TMP/deadline"
  cat > "$PR_TMP/bounded-jira.sh" <<'FAKE'
#!/usr/bin/env bash
. "$FM_ROOT_OVERRIDE/bin/fm-dispatch-axi-lib.sh"
fm_axi_bounded_run "$FM_JIRA_TIMEOUT" jira issue move SWVL-9996 Done && exit 1
printf 'bounded\n'
FAKE
  mkdir "$PR_TMP/deadlinebin"
  for tool in bash perl dirname sed tr awk stat uname mkdir mktemp chmod mv cat grep rm readlink ps date ln sleep basename rmdir base64 gh jira gh-axi; do
    ln -s "$(command -v "$tool")" "$PR_TMP/deadlinebin/$tool"
  done
  for deadline_tool in timeout gtimeout; do
    cp "$PR_TMP/deadline" "$PR_TMP/deadlinebin/$deadline_tool"
    write_pr_task "task-$deadline_tool" 'project=/projects/thanos' 'branch=rcs/swvl-9996-hard-deadline'
    printf 'pr=%s\n' https://github.com/owner/repo/pull/64 >> "$FM_HOME/state/task-$deadline_tool.meta"
    PATH="$PR_TMP/deadlinebin" run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/owner/repo/pull/64 github.com owner/repo 64
    [ "$FM_CHECK_RESULT" = merged ] || fail "$deadline_tool must preserve merged"
    drain_pr > "$PR_TMP/$deadline_tool-wake"
    assert_grep 'move SWVL-9996 to Done yourself' "$PR_TMP/$deadline_tool-wake" "$deadline_tool must force termination and publish the manual move within the check budget"
    jira_pid=$(cat "$JIRA_PID_FILE")
    if kill -0 "$jira_pid" 2>/dev/null; then
      kill -KILL "$jira_pid" 2>/dev/null || true
      fail "$deadline_tool must not leave its Jira child running after returning"
    fi
    assert_absent "$FM_HOME/state/jira/github.com/owner/repo/64/transition.lock" "$deadline_tool must release its own transition lock"
    cp "$PR_TMP/fakebin/jira" "$PR_TMP/fakebin/gh-axi"
    write_pr_task task-installed-lookup 'project=/projects/thanos' 'branch=generic'
    printf 'pr=%s\n' https://github.com/owner/repo/pull/65 >> "$FM_HOME/state/task-installed-lookup.meta"
    PATH="$PR_TMP/deadlinebin" run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/owner/repo/pull/65 github.com owner/repo 65
    [ "$FM_CHECK_RESULT" = merged ] || fail "$deadline_tool must preserve merged during prerequisite lookup"
    drain_pr > "$PR_TMP/$deadline_tool-lookup-wake"
    assert_grep 'move https://github.com/owner/repo/pull/65 to Done yourself' "$PR_TMP/$deadline_tool-lookup-wake" "$deadline_tool lookup must deliver the manual instruction"
    jira_pid=$(cat "$JIRA_PID_FILE")
    if kill -0 "$jira_pid" 2>/dev/null; then
      kill -KILL "$jira_pid" 2>/dev/null || true
      fail "$deadline_tool must not leave its lookup child running after returning"
    fi
    for pending in "$FM_HOME/state/jira/github.com/owner/repo/65"/.transition.*; do
      assert_absent "$pending" "$deadline_tool must clean up its lookup output"
    done
    PATH="$PR_TMP/deadlinebin" run_check_capture "$PR_TMP/bounded-jira.sh"
    [ "$FM_CHECK_RESULT" = bounded ] || fail "$deadline_tool must force termination of a TERM-resistant command within the check budget"
    rm -f "${PR_TMP:?}/deadlinebin/$deadline_tool"
    pass "$deadline_tool terminates and cleans up Jira, prerequisite lookup, and a TERM-resistant command"
  done
}

case "${FM_JIRA_TEST_CASE:-all}" in
  all) jira_ordering_regression; jira_deadline_regressions; jira_installed_deadlines ;;
  ordering) jira_ordering_regression ;;
  deadline) jira_deadline_regressions ;;
  installed) jira_installed_deadlines ;;
esac
