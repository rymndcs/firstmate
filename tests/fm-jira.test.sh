#!/usr/bin/env bash
set -eu
# shellcheck source=tests/pr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/pr-helpers.sh"
url=https://github.com/advisorfirst/thanos/pull/42
poll_pr() {
  local number=${1:-42}
  "$PR_CODE/bin/fm-pr-poll.sh" --validated github "https://github.com/advisorfirst/thanos/pull/$number" github.com advisorfirst/thanos "$number"
}
mkdir "$PR_TMP/denybin"
for service in jira gh gh-axi glab tmux treehouse herdr orca zellij linear curl wget; do
  cat > "$PR_TMP/denybin/$service" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$JIRA_DENIED_LOG"
exit 97
FAKE
  chmod +x "$PR_TMP/denybin/$service"
done
export JIRA_DENIED_LOG="$PR_TMP/denied.log"
export PATH="$PR_TMP/fakebin:$PR_TMP/denybin:$PATH"
export JIRA_LOG="$PR_TMP/jira.log"
: > "$JIRA_LOG"
printf '%s\n' '- thanos [no-mistakes] - team review' > "$FM_HOME/data/projects.md"
cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
exit "${JIRA_EXIT:-0}"
FAKE
chmod +x "$PR_TMP/fakebin/jira"
for service in gh jira; do
  [ -x "$PR_TMP/fakebin/$service" ] && [ "$(command -v "$service")" = "$PR_TMP/fakebin/$service" ] \
    || fail "initial fixture must resolve executable fake $service"
done
write_pr_task task-a 'project=/projects/thanos' 'branch=rcs/swvl-8080-contact-created'
register_pr task-a
[ "$(cat "$JIRA_LOG")" = 'issue|move|SWVL-8080|Ready for Review' ] || fail 'recording a Thanos PR must move only its ticket status to Ready for Review'
register_pr task-a
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 1 ] || fail 'repeated registration must not repeat the ready move'
pass 'PR recording moves the Thanos ticket to Ready for Review once'
drain_pr > /dev/null
FM_TEST_GH_STATE=MERGED
[ "$(poll_pr)" = merged ] || fail 'Jira must preserve the exact merge result'
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'an externally merged PR must move its Jira ticket'
[ "$(sed -n '2p' "$JIRA_LOG")" = 'issue|move|SWVL-8080|Done' ] || fail 'external merge must move only status to Done'
drain_pr > "$PR_TMP/followups-wake"
assert_grep "$url" "$PR_TMP/followups-wake" 'follow-ups must identify their merged PR'
assert_grep 'check MCP covers what changed unless explicitly skipped; put any MCP gap in a separate follow-up PR' "$PR_TMP/followups-wake" 'Thanos merge must name the MCP follow-up and separate PR'
assert_grep 'update /help-center with the change' "$PR_TMP/followups-wake" 'Thanos merge must name the help-center follow-up'
poll_pr > /dev/null
register_pr task-a
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'repeated merge wake or registration must never repeat or reverse Done'
drain_pr > "$PR_TMP/followups-repeat"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/followups-repeat" 'repeated merge must not repeat follow-ups after consumption'
pass 'external merge delivers both follow-ups once and preserves Done deduplication'
write_pr_task task-duplicate 'project=/projects/thanos' 'branch=rcs/swvl-8080-contact-created'
register_pr task-duplicate
poll_pr > /dev/null
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'two registrations for one PR must not repeat a Jira move'
drain_pr > "$PR_TMP/followups-duplicate"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/followups-duplicate" 'duplicate task registration must share the PR follow-up receipt'
pass 'duplicate PR registrations share transition and follow-up receipts'
write_pr_task task-other 'project=/projects/wms' 'branch=rcs/swvl-9090-not-thanos'
"$PR_CODE/bin/fm-pr-check.sh" task-other https://github.com/advisorfirst/thanos/pull/43 > /dev/null 2>&1
poll_pr 43 > /dev/null
[ "$(wc -l < "$JIRA_LOG" | tr -d ' ')" = 2 ] || fail 'non-Thanos work must not reach Jira'
drain_pr > "$PR_TMP/other-wake"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/other-wake" 'non-Thanos merge must not receive follow-ups'
assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/thanos/43/followups.owed" 'other projects must not acquire owed reminders'
pass 'other projects remain untouched'
fm_fake_exit0 "$PR_TMP/fakebin" gh-axi
write_pr_task task-help-center 'project=/projects/thanos' 'branch=help-center-update'
help_url=https://github.com/advisorfirst/help-center/pull/287
"$PR_CODE/bin/fm-pr-check.sh" task-help-center "$help_url" > /dev/null 2>&1
[ "$("$PR_CODE/bin/fm-pr-poll.sh" --validated github "$help_url" github.com advisorfirst/help-center 287)" = merged ] || fail 'help-center merge must preserve the merged result'
drain_pr > "$PR_TMP/help-center-wake"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/help-center-wake" 'help-center PRs registered under Thanos must not receive merge reminders'
assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/help-center/287/followups.owed" 'help-center merges must not acquire owed reminders'
"$PR_CODE/bin/fm-jira.sh" --followups "$help_url" owe
"$PR_CODE/bin/fm-jira.sh" --followups "$help_url"
drain_pr > "$PR_TMP/help-center-direct"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/help-center-direct" 'direct reminder publication must stay scoped to Thanos'
pass 'help-center merges and direct publication stay silent even under a Thanos task'
write_pr_task task-fail 'project=/projects/thanos' 'branch=rcs/swvl-8081-appointment'
JIRA_EXIT=1 "$PR_CODE/bin/fm-pr-check.sh" task-fail https://github.com/advisorfirst/thanos/pull/44 > "$PR_TMP/fail.out" 2> "$PR_TMP/fail.err" || fail 'Jira failure must not fail registration'
assert_grep 'move SWVL-8081 to Ready for Review yourself' "$PR_TMP/fail.err" 'failure must identify the manual ticket move'
[ "$(grep -c '^JIRA:' "$PR_TMP/fail.err")" = 1 ] || fail 'Jira failure must print exactly one diagnostic'
pass 'CLI failure prints one manual move and leaves lifecycle successful'
write_pr_task task-missing 'project=/projects/thanos' 'branch=rcs/swvl-8082-missing'
printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/45 >> "$FM_HOME/state/task-missing.meta"
mkdir "$PR_TMP/missingbin"
for tool in bash perl dirname sed tr awk stat uname mkdir mktemp chmod mv cat grep rm readlink ps date ln sleep basename rmdir base64; do
  ln -s "$(command -v "$tool")" "$PR_TMP/missingbin/$tool"
done
missing_out=$(PATH="$PR_TMP/missingbin" "$PR_CODE/bin/fm-jira.sh" transition task-missing 'done' 2>&1) || fail 'missing CLI must exit 0'
assert_contains "$missing_out" 'move SWVL-8082 to Done yourself' 'missing CLI must name the manual move'
pass 'missing CLI prints the manual move and exits 0'
cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'api /repos/advisorfirst/thanos/pulls/46'|'api /repos/advisorfirst/thanos/pulls/52')
    [ "$3" = --jq ] && [ "$4" = '.title + " " + .head.ref' ] || exit 2
    printf 'api_response:\n  body: %s\n  truncated: false\n' "${FAKE_GH_TITLE-fix: SWVL-8083 title fallback}" ;;
  'pr merge') exit "${MERGE_EXIT:-0}" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$PR_TMP/fakebin/gh-axi"
write_pr_task task-title 'project=/projects/thanos' 'branch=generic-branch'
"$PR_CODE/bin/fm-pr-check.sh" task-title https://github.com/advisorfirst/thanos/pull/46 > /dev/null 2>&1
assert_grep 'issue|move|SWVL-8083|Ready for Review' "$JIRA_LOG" 'title must resolve when the task branch carries no ticket'
[ "$(cat "$FM_HOME/state/jira/github.com/advisorfirst/thanos/46/transitions")" = in-review ] || fail 'lookup output must not leak into the transition receipt'
pass 'ticket resolution falls back to the PR title'
fm_fake_exit0 "$PR_CODE/bin" fm-protected-paths.sh
write_pr_task task-merge 'project=/projects/thanos' 'branch=rcs/swvl-8084-merge'
"$PR_CODE/bin/fm-pr-merge.sh" task-merge https://github.com/advisorfirst/thanos/pull/47 > /dev/null 2>&1 || fail 'successful merge must remain successful'
drain_pr > "$PR_TMP/direct-followups"
assert_grep 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/47' "$PR_TMP/direct-followups" 'direct merge must deliver the same follow-ups'
assert_grep 'issue|move|SWVL-8084|Done' "$JIRA_LOG" 'explicit successful merge must move to Done'
count=$(wc -l < "$JIRA_LOG")
poll_pr 47 > /dev/null
[ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'poll after explicit merge must not repeat Done'
drain_pr > "$PR_TMP/direct-repeat"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/direct-repeat" 'polling a direct merge must not repeat its follow-ups'
pass 'explicit merge and external merge share Done and follow-up receipts'
write_pr_task task-auto 'project=/projects/thanos' 'branch=rcs/swvl-8085-auto'
"$PR_CODE/bin/fm-pr-merge.sh" task-auto https://github.com/advisorfirst/thanos/pull/48 -- --auto > /dev/null 2>&1
assert_no_grep 'issue|move|SWVL-8085|Done' "$JIRA_LOG" 'queued auto-merge must not close Jira'
write_pr_task task-rejected 'project=/projects/thanos' 'branch=rcs/swvl-8086-failed'
if MERGE_EXIT=1 "$PR_CODE/bin/fm-pr-merge.sh" task-rejected https://github.com/advisorfirst/thanos/pull/49 > /dev/null 2>&1; then
  fail 'failed merge must retain its failure'
fi
assert_no_grep 'issue|move|SWVL-8086|Done' "$JIRA_LOG" 'failed merge must not close Jira'
FM_TEST_GH_STATE=CLOSED
poll_pr 49 > /dev/null
assert_no_grep 'issue|move|SWVL-8086|Done' "$JIRA_LOG" 'closed unmerged PR must not close Jira'
drain_pr > "$PR_TMP/unmerged-wake"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/unmerged-wake" 'queued, failed and closed unmerged PRs must not trigger follow-ups'
for number in 48 49; do
  assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/thanos/$number/followups.owed" 'unmerged PRs must not acquire owed reminders'
done
pass 'queued, failed and closed unmerged PRs do not move to Done or trigger follow-ups'
write_pr_task task-concurrent 'project=/projects/thanos' 'branch=rcs/swvl-8087-concurrent'
"$PR_CODE/bin/fm-pr-check.sh" task-concurrent https://github.com/advisorfirst/thanos/pull/50 > /dev/null 2>&1
FM_TEST_GH_STATE=MERGED
poll_pr 50 > /dev/null &
first=$!
poll_pr 50 > /dev/null &
second=$!
wait "$first"
wait "$second"
[ "$(grep -c 'issue|move|SWVL-8087|Done' "$JIRA_LOG")" = 1 ] || fail 'overlapping polls must move Jira once'
[ "$(grep -c 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/50' "$FM_HOME/state/.wake-queue")" = 1 ] || fail 'concurrent publication must enqueue once before drain deduplication'
drain_pr > "$PR_TMP/concurrent-followups"
[ "$(grep -c 'MERGE FOLLOW-UPS:' "$PR_TMP/concurrent-followups")" = 1 ] || fail 'overlapping observations must enqueue follow-ups once'
pass 'overlapping merge observations serialize one Jira move and follow-up notification'
write_pr_task task-merge-fail 'project=/projects/thanos' 'branch=rcs/swvl-8088-outage'
"$PR_CODE/bin/fm-pr-check.sh" task-merge-fail https://github.com/advisorfirst/thanos/pull/51 > /dev/null 2>&1
[ "$(JIRA_EXIT=1 poll_pr 51 2>/dev/null)" = merged ] || fail 'Jira outage must preserve merged output'
drain_pr > "$PR_TMP/manual-wake"
assert_grep 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/51' "$PR_TMP/manual-wake" 'Jira outage must not suppress follow-ups'
assert_grep 'move SWVL-8088 to Done yourself' "$PR_TMP/manual-wake" 'merge polling discards stderr, so manual Jira move must survive in the wake'
JIRA_EXIT=1 poll_pr 51 > /dev/null 2>&1
drain_pr > "$PR_TMP/manual-repeat"
assert_no_grep 'move SWVL-8088' "$PR_TMP/manual-repeat" 'repeated wake must not duplicate the manual-move notification'
pass 'merge-poll failures deliver the manual move durably once'
count=$(wc -l < "$JIRA_LOG")
write_pr_task task-no-key 'project=/projects/thanos' 'branch=generic'
FAKE_GH_TITLE='ordinary maintenance' "$PR_CODE/bin/fm-pr-check.sh" task-no-key https://github.com/advisorfirst/thanos/pull/52 > /dev/null 2>&1
[ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'a Thanos PR without an SWVL key must not move an unrelated issue'
FAKE_GH_TITLE='ordinary maintenance' poll_pr 52 > /dev/null
drain_pr > "$PR_TMP/no-ticket-followups"
assert_grep 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/52' "$PR_TMP/no-ticket-followups" 'Thanos follow-ups must not require a Jira ticket key'
write_pr_task task-unregistered 'project=/projects/thanos' 'branch=rcs/swvl-8089-unregistered'
printf '%s\n' '- wms [no-mistakes]' > "$FM_HOME/data/projects.md"
"$PR_CODE/bin/fm-pr-check.sh" task-unregistered https://github.com/advisorfirst/thanos/pull/53 > /dev/null 2>&1
poll_pr 53 > /dev/null
[ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'Jira moves require the Thanos registry entry'
drain_pr > "$PR_TMP/unregistered-followups"
assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/unregistered-followups" 'unregistered projects must remain silent'
printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
pass 'missing ticket keys and unregistered projects stay silent'
write_pr_task task-done-first 'project=/projects/thanos' 'branch=rcs/swvl-8090-done-first'
printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/54 >> "$FM_HOME/state/task-done-first.meta"
poll_pr 54 > /dev/null
assert_grep 'issue|move|SWVL-8090|Done' "$JIRA_LOG" 'merge seen before registration must still move to Done'
"$PR_CODE/bin/fm-pr-check.sh" task-done-first https://github.com/advisorfirst/thanos/pull/54 > /dev/null 2>&1
assert_no_grep 'issue|move|SWVL-8090|Ready for Review' "$JIRA_LOG" 'a later ready event must never reopen Done'
pass 'a merge observed first cannot be reversed by later registration'

jira_ordering_regression() {
  write_pr_task task-order 'project=/projects/thanos' 'branch=rcs/swvl-9998-order'
  printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/60 >> "$FM_HOME/state/task-order.meta"
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
  stalled_url=https://github.com/advisorfirst/thanos/pull/61
  "$PR_CODE/bin/fm-pr-check.sh" task-stalled "$stalled_url" > /dev/null 2>&1
  write_pr_task task-stalled-duplicate 'project=/projects/thanos' 'branch=rcs/swvl-9999-stalled'
  printf 'pr=%s\n' "$stalled_url" >> "$FM_HOME/state/task-stalled-duplicate.meta"
  for attempt in 1 2; do
    run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github "$stalled_url" github.com advisorfirst/thanos 61
    [ "$FM_CHECK_RESULT" = merged ] || fail "stalled Jira attempt $attempt must return exactly merged through production capture"
    drain_pr > "$PR_TMP/stalled-wake-$attempt"
    assert_grep 'move SWVL-9999 to Done yourself' "$PR_TMP/stalled-wake-$attempt" 'stalled Jira must deliver the manual instruction before the production deadline'
    assert_no_grep 'done' "$FM_HOME/state/jira/github.com/advisorfirst/thanos/61/transitions" 'a timed-out move must remain retryable'
    assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/thanos/61/transition.lock" 'a timed-out move must release its own transition lock'
    for pending in "$FM_HOME/state/jira/github.com/advisorfirst/thanos/61"/.transition.*; do
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
  run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github "$stalled_url" github.com advisorfirst/thanos 61
  [ "$FM_CHECK_RESULT" = merged ] || fail 'immediate-success Jira control must preserve merged'
  assert_grep 'done' "$FM_HOME/state/jira/github.com/advisorfirst/thanos/61/transitions" 'the fast control must publish Done'
  count=$(wc -l < "$JIRA_LOG")
  poll_pr 61 > /dev/null
  [ "$(wc -l < "$JIRA_LOG")" = "$count" ] || fail 'successful retry must restore receipt deduplication'
  pass 'immediate-success control completes the move and deduplicates later observations'

  write_pr_task task-locked 'project=/projects/thanos' 'branch=rcs/swvl-9997-lock'
  printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/62 >> "$FM_HOME/state/task-locked.meta"
  lock="$FM_HOME/state/jira/github.com/advisorfirst/thanos/62/transition.lock"
  mkdir -p "$(dirname "$lock")"
  fm_lock_try_acquire "$lock" || fail 'fixture must own a live transition lock'
  lock_owner=$FM_LOCK_OWNER_DIR
  run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/advisorfirst/thanos/pull/62 github.com advisorfirst/thanos 62
  [ "$FM_CHECK_RESULT" = merged ] || fail 'transition-lock wait must not swallow merged'
  drain_pr > "$PR_TMP/locked-wake"
  assert_grep 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/62' "$PR_TMP/locked-wake" 'a blocked Jira status move must not suppress merge follow-ups'
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
  printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/63 >> "$FM_HOME/state/task-lookup.meta"
  run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/advisorfirst/thanos/pull/63 github.com advisorfirst/thanos 63
  [ "$FM_CHECK_RESULT" = merged ] || fail 'stalled title lookup must not swallow merged'
  drain_pr > "$PR_TMP/lookup-wake"
  assert_grep 'move https://github.com/advisorfirst/thanos/pull/63 to Done yourself' "$PR_TMP/lookup-wake" 'an unresolved lookup timeout must identify its PR in the manual instruction'
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
    printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/64 >> "$FM_HOME/state/task-$deadline_tool.meta"
    PATH="$PR_TMP/deadlinebin" run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/advisorfirst/thanos/pull/64 github.com advisorfirst/thanos 64
    [ "$FM_CHECK_RESULT" = merged ] || fail "$deadline_tool must preserve merged"
    drain_pr > "$PR_TMP/$deadline_tool-wake"
    assert_grep 'move SWVL-9996 to Done yourself' "$PR_TMP/$deadline_tool-wake" "$deadline_tool must force termination and publish the manual move within the check budget"
    jira_pid=$(cat "$JIRA_PID_FILE")
    if kill -0 "$jira_pid" 2>/dev/null; then
      kill -KILL "$jira_pid" 2>/dev/null || true
      fail "$deadline_tool must not leave its Jira child running after returning"
    fi
    assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/thanos/64/transition.lock" "$deadline_tool must release its own transition lock"
    cp "$PR_TMP/fakebin/jira" "$PR_TMP/fakebin/gh-axi"
    write_pr_task task-installed-lookup 'project=/projects/thanos' 'branch=generic'
    printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/65 >> "$FM_HOME/state/task-installed-lookup.meta"
    PATH="$PR_TMP/deadlinebin" run_check_capture "$PR_CODE/bin/fm-pr-poll.sh" --validated github https://github.com/advisorfirst/thanos/pull/65 github.com advisorfirst/thanos 65
    [ "$FM_CHECK_RESULT" = merged ] || fail "$deadline_tool must preserve merged during prerequisite lookup"
    drain_pr > "$PR_TMP/$deadline_tool-lookup-wake"
    assert_grep 'move https://github.com/advisorfirst/thanos/pull/65 to Done yourself' "$PR_TMP/$deadline_tool-lookup-wake" "$deadline_tool lookup must deliver the manual instruction"
    jira_pid=$(cat "$JIRA_PID_FILE")
    if kill -0 "$jira_pid" 2>/dev/null; then
      kill -KILL "$jira_pid" 2>/dev/null || true
      fail "$deadline_tool must not leave its lookup child running after returning"
    fi
    for pending in "$FM_HOME/state/jira/github.com/advisorfirst/thanos/65"/.transition.*; do
      assert_absent "$pending" "$deadline_tool must clean up its lookup output"
    done
    PATH="$PR_TMP/deadlinebin" run_check_capture "$PR_TMP/bounded-jira.sh"
    [ "$FM_CHECK_RESULT" = bounded ] || fail "$deadline_tool must force termination of a TERM-resistant command within the check budget"
    rm -f "${PR_TMP:?}/deadlinebin/$deadline_tool"
    pass "$deadline_tool terminates and cleans up Jira, prerequisite lookup, and a TERM-resistant command"
  done
}

jira_publication_write_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_JIRA_TIMEOUT FM_TEST_GH_STATE
  export FM_HOME="$PR_TMP/write-home" FM_JIRA_TIMEOUT=1 FM_TEST_GH_STATE=MERGED
  export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
  mkdir -p "$FM_HOME/state" "$FM_HOME/data"
  printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
  cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
FAKE
  chmod +x "$PR_TMP/fakebin/jira"
  write_pr_task task-write 'project=/projects/thanos' 'branch=rcs/swvl-9990-write'
  printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/70 >> "$FM_HOME/state/task-write.meta"
  mkdir "$FM_HOME/state/.wake-queue.seq"
  poll_pr 70 > "$PR_TMP/write.out" 2> "$PR_TMP/write.err"
  assert_grep 'issue|move|SWVL-9990|Done' "$JIRA_LOG" 'reminder write failure must not prevent the healthy Jira Done update'
  [ "$(cat "$PR_TMP/write.out")" = merged ] || fail 'reminder failure must preserve the exact merged observation'
  assert_grep 'publication failed; retry on the next merge observation' "$PR_TMP/write.err" 'reminder failure must identify its own retry'
  assert_no_grep 'JIRA:' "$PR_TMP/write.err" 'healthy Jira must not be reported as failed when only reminder publication fails'
  assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/thanos/70/followups" 'failed publication must not write its receipt'
  if "$PR_CODE/bin/fm-jira.sh" followups https://github.com/advisorfirst/thanos/pull/70 > /dev/null 2> "$PR_TMP/write-readiness.err"; then
    fail 'terminal publication must report failure while the queue remains unwritable'
  fi
  rmdir "$FM_HOME/state/.wake-queue.seq"
  [ "$(poll_pr 70)" = merged ] || fail 'repaired publication must restore exact merged output'
  drain_pr > "$PR_TMP/write-wake"
  assert_grep 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/70' "$PR_TMP/write-wake" 'repaired publication must deliver the missing reminder'
  poll_pr 70 > /dev/null
  drain_pr > "$PR_TMP/write-repeat"
  assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/write-repeat" 'recovered publication must remain once per PR'
  [ "$(grep -c 'issue|move|SWVL-9990|Done' "$JIRA_LOG")" = 1 ] || fail 'publication retry must not repeat healthy Jira work'
  write_pr_task task-readiness 'project=/projects/thanos' 'branch=rcs/swvl-9992-readiness'
  printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/72 >> "$FM_HOME/state/task-readiness.meta"
  "$PR_CODE/bin/fm-jira.sh" followups https://github.com/advisorfirst/thanos/pull/72
  assert_no_grep 'issue|move|SWVL-9992' "$JIRA_LOG" 'terminal publication must never perform a Jira status move'
  pass 'reminder write failure preserves Jira Done and retries reminder delivery once'
}

jira_cleanup_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_JIRA_TIMEOUT FM_TEST_GH_STATE
  local mode task_url dir tool parent_home retirement_home retirement_id pool_home
  local -a retirement_args
  export FM_JIRA_TIMEOUT=1 FM_TEST_GH_STATE=MERGED
  for mode in ${FM_JIRA_CLEANUP_SCENARIO:-pending recovered pending-drain home-ordinary home-queued home-force home-nested home-pool}; do
    export FM_HOME="$PR_TMP/cleanup-$mode"
    export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
    if [ "$mode" = home-pool ]; then
      fm_git_init_commit "$PR_CODE"
      git -C "$PR_CODE" worktree add --detach -q "$FM_HOME" HEAD
    fi
    mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"
    "$PR_CODE/bin/fm-jira.sh" retry-followups > "$PR_TMP/cleanup-$mode.empty" 2>&1 \
      || fail 'retry with no owed work must succeed silently'
    [ ! -s "$PR_TMP/cleanup-$mode.empty" ] || fail 'retry with no owed work must succeed silently'
    printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
    fm_git_init_commit "$FM_HOME/thanos"
    git -C "$FM_HOME/thanos" update-ref refs/remotes/origin/main HEAD
    git -C "$FM_HOME/thanos" worktree add --detach -q "$FM_HOME/task-tree" HEAD
    fm_write_meta "$FM_HOME/state/task-cleanup.meta" 'window=firstmate:fm-task-cleanup' \
      'endpoint_task_id=task-cleanup' 'backend=tmux' "worktree=$FM_HOME/task-tree" \
      "project=$FM_HOME/thanos" 'branch=rcs/swvl-9993-cleanup' 'kind=ship' 'mode=no-mistakes'
    task_url=https://github.com/advisorfirst/thanos/pull/73
    dir="$FM_HOME/state/jira/github.com/advisorfirst/thanos/73"
    cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = 'pr merge' ] || exit 97
printf 'fake merge succeeded\n'
FAKE
    cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
FAKE
    for tool in tmux treehouse; do
      fm_fake_exit0 "$PR_TMP/fakebin" "$tool"
    done
    fm_fake_exit0 "$PR_CODE/bin" fm-protected-paths.sh fm-fleet-sync.sh
    chmod +x "$PR_TMP/fakebin/gh-axi" "$PR_TMP/fakebin/jira"
    for tool in gh gh-axi jira tmux treehouse; do
      [ -x "$PR_TMP/fakebin/$tool" ] && [ "$(command -v "$tool")" = "$PR_TMP/fakebin/$tool" ] \
        || fail "cleanup fixture must resolve executable fake $tool"
    done
    mkdir "$FM_HOME/state/.wake-queue.seq"
    "$PR_CODE/bin/fm-pr-merge.sh" task-cleanup "$task_url" > "$PR_TMP/cleanup-$mode.merge" 2> "$PR_TMP/cleanup-$mode.err"
    assert_grep 'fake merge succeeded' "$PR_TMP/cleanup-$mode.merge" 'direct merge must retain successful output'
    assert_grep 'issue|move|SWVL-9993|Done' "$JIRA_LOG" 'queue failure must preserve healthy Jira Done'
    assert_absent "$dir/followups" 'failed direct publication must not write its receipt'
    if "$PR_CODE/bin/fm-jira.sh" retry-followups > "$PR_TMP/cleanup-$mode.retry-failed" 2>&1; then
      fail 'owed retry must report publication failure while the queue remains unwritable'
    fi
    if [ "$mode" = recovered ]; then rmdir "$FM_HOME/state/.wake-queue.seq"; fi
    "$PR_CODE/bin/fm-teardown.sh" task-cleanup > "$PR_TMP/cleanup-$mode.out" 2> "$PR_TMP/cleanup-$mode.teardown.err" \
      || fail 'cleanup must preserve unpaid reminders outside disposable task records'
    assert_absent "$FM_HOME/state/task-cleanup.meta" 'normal cleanup must remove ephemeral task metadata'
    assert_absent "$FM_HOME/state/task-cleanup.check.sh" 'normal cleanup must remove the ephemeral poll'
    if [ "$mode" != recovered ]; then
      [ -f "$dir/followups.owed" ] || fail 'failed publication then normal cleanup must retain the owed reminder'
      [ "$(cat "$dir/followups.owed")" = "$task_url" ] || fail 'retained obligation must contain its own retry identity'
      case "$mode" in
        home-*)
          parent_home="$PR_TMP/parent-$mode"
          mkdir -p "$parent_home/state" "$parent_home/data" "$parent_home/config"
          printf '%s\n' '- wms [no-mistakes]' > "$parent_home/data/projects.md"
          printf '%s\n' home-sm > "$FM_HOME/.fm-secondmate-home"
          fm_write_meta "$parent_home/state/home-sm.meta" 'window=firstmate:fm-home-sm' \
            'endpoint_task_id=home-sm' 'backend=tmux' "worktree=$FM_HOME" "home=$FM_HOME" \
            "project=$PR_CODE" 'kind=secondmate' 'mode=secondmate'
          retirement_home=$parent_home retirement_id=home-sm
          retirement_args=(home-sm)
          case "$mode" in
            home-force) retirement_args+=(--force) ;;
            home-nested)
              retirement_home="$PR_TMP/grandparent-$mode" retirement_id=outer-sm
              mkdir -p "$retirement_home/state" "$retirement_home/data" "$retirement_home/config"
              printf '%s\n' outer-sm > "$parent_home/.fm-secondmate-home"
              fm_write_meta "$retirement_home/state/outer-sm.meta" 'window=firstmate:fm-outer-sm' \
                'endpoint_task_id=outer-sm' 'backend=tmux' "worktree=$parent_home" "home=$parent_home" \
                "project=$PR_CODE" 'kind=secondmate' 'mode=secondmate'
              retirement_args=(outer-sm --force) ;;
            home-pool)
              pool_home=$(cd "$FM_HOME" && pwd -P)
              export JIRA_HOME_RETURN_LOG="$PR_TMP/home-return.log"
              : > "$JIRA_HOME_RETURN_LOG"
              cat > "$PR_TMP/fakebin/treehouse" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = 'return --force' ] || exit 97
printf '%s\n' "$3" >> "$JIRA_HOME_RETURN_LOG"
git -C "$FM_ROOT_OVERRIDE" worktree remove --force "$3"
FAKE
              chmod +x "$PR_TMP/fakebin/treehouse" ;;
          esac
          if [ "$mode" != home-queued ]; then
            if FM_HOME="$retirement_home" FM_STATE_OVERRIDE="$retirement_home/state" \
                FM_DATA_OVERRIDE="$retirement_home/data" FM_CONFIG_OVERRIDE="$retirement_home/config" \
                "$PR_CODE/bin/fm-teardown.sh" "${retirement_args[@]}" > "$PR_TMP/$mode.unpaid" 2>&1; then
              fail 'home retirement must refuse while the reminder is unpaid'
            fi
            assert_grep 'merge follow-ups' "$PR_TMP/$mode.unpaid" 'unpaid retirement must reach the shared reminder guard'
            assert_grep "$task_url" "$dir/followups.owed" 'unpaid retirement must preserve the retry identity'
            assert_present "$retirement_home/state/$retirement_id.meta" 'unpaid retirement must preserve the parent record'
          fi
          rmdir "$FM_HOME/state/.wake-queue.seq"
          printf '%s\n' '- wms [no-mistakes]' > "$FM_HOME/data/projects.md"
          "$PR_CODE/bin/fm-jira.sh" retry-followups
          assert_absent "$dir/followups.owed" 'publication must clear the unpaid reminder'
          assert_grep "$task_url" "$dir/followups" 'publication must establish the URL receipt'
          cp "$FM_HOME/state/.wake-queue" "$PR_TMP/$mode.queue-before"
          if FM_HOME="$retirement_home" FM_STATE_OVERRIDE="$retirement_home/state" \
              FM_DATA_OVERRIDE="$retirement_home/data" FM_CONFIG_OVERRIDE="$retirement_home/config" \
              "$PR_CODE/bin/fm-teardown.sh" "${retirement_args[@]}" > "$PR_TMP/$mode.queued" 2>&1; then
            fail 'home retirement must refuse while the reminder is queued and undelivered'
          fi
          assert_grep 'merge follow-ups' "$PR_TMP/$mode.queued" 'queued retirement must reach the shared reminder guard'
          cmp "$FM_HOME/state/.wake-queue" "$PR_TMP/$mode.queue-before" || fail 'refused retirement must preserve the queued reminder bytes'
          assert_grep "$task_url" "$dir/followups" 'queued retirement must preserve the publication receipt'
          drain_pr > "$PR_TMP/$mode.delivered"
          [ "$(grep -c 'MERGE FOLLOW-UPS:' "$PR_TMP/$mode.delivered")" = 1 ] || fail 'retained home must deliver its reminder exactly once'
          assert_grep 'check MCP covers what changed unless explicitly skipped; put any MCP gap in a separate follow-up PR' "$PR_TMP/$mode.delivered" 'home recovery must deliver the MCP follow-up'
          assert_grep 'update /help-center with the change' "$PR_TMP/$mode.delivered" 'home recovery must deliver the help-center follow-up'
          "$PR_CODE/bin/fm-jira.sh" retry-followups
          drain_pr > "$PR_TMP/$mode.repeat"
          assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/$mode.repeat" 'home retry must not duplicate delivery'
          bash -c '
            . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
            fm_wake_append check unrelated-key "check: MERGE FOLLOW-UPS: $1"
            fm_wake_append check "$1" "unrelated URL key"
            fm_wake_append check merge-followups:unrelated "unrelated invalid URL key"
            fm_wake_append signal "merge-followups:$1" "unrelated signal"
          ' _ "$task_url"
          FM_HOME="$retirement_home" FM_STATE_OVERRIDE="$retirement_home/state" \
            FM_WAKE_QUEUE="$retirement_home/state/.wake-queue" FM_WAKE_QUEUE_LOCK="$retirement_home/state/.wake-queue.lock" \
            bash -c '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_wake_append check "merge-followups:$1" "parent-owned reminder"' _ "$task_url"
          FM_HOME="$retirement_home" FM_STATE_OVERRIDE="$retirement_home/state" \
            FM_DATA_OVERRIDE="$retirement_home/data" FM_CONFIG_OVERRIDE="$retirement_home/config" \
            "$PR_CODE/bin/fm-teardown.sh" "${retirement_args[@]}" > "$PR_TMP/$mode.retired" 2>&1 \
            || { cat "$PR_TMP/$mode.retired" >&2; fail 'delivered reminder and unrelated queue work must allow home retirement'; }
          assert_absent "$FM_HOME" 'delivered reminder must permit removal of its home'
          assert_absent "$retirement_home/state/$retirement_id.meta" 'successful retirement must remove the parent record'
          assert_grep 'parent-owned reminder' "$retirement_home/state/.wake-queue" 'retirement must not erase the parent queue'
          if [ "$mode" = home-pool ]; then
            [ "$(cat "$JIRA_HOME_RETURN_LOG")" = "$pool_home" ] || fail 'native pool return must run exactly once after delivery'
          fi
          pass "unpaid and queued home refusal, delivery and retirement: $mode"
          continue ;;
      esac
      rmdir "$FM_HOME/state/.wake-queue.seq"
      printf '%s\n' '- wms [no-mistakes]' > "$FM_HOME/data/projects.md"
      if [ "$mode" = pending ]; then
        "$PR_CODE/bin/fm-jira.sh" retry-followups
      else
        drain_pr > "$PR_TMP/cleanup-$mode.retry"
      fi
    else
      [ -f "$dir/followups" ] || fail 'cleanup must publish an owed reminder when the queue has recovered'
    fi
    [ -f "$dir/followups" ] || fail 'retry after cleanup must publish without task metadata or registration'
    assert_absent "$dir/followups.owed" 'successful receipt must clear the owed obligation'
    drain_pr > "$PR_TMP/cleanup-$mode.wake"
    if [ "$mode" = pending-drain ]; then cat "$PR_TMP/cleanup-$mode.retry" >> "$PR_TMP/cleanup-$mode.wake"; fi
    [ "$(grep -c 'MERGE FOLLOW-UPS:' "$PR_TMP/cleanup-$mode.wake")" = 1 ] || fail 'cleanup recovery must deliver exactly one reminder'
    assert_grep 'check MCP covers what changed' "$PR_TMP/cleanup-$mode.wake" 'cleanup recovery must retain MCP work'
    assert_grep 'update /help-center' "$PR_TMP/cleanup-$mode.wake" 'cleanup recovery must retain help-center work'
    "$PR_CODE/bin/fm-jira.sh" followups "$task_url"
    drain_pr > "$PR_TMP/cleanup-$mode.repeat"
    assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/cleanup-$mode.repeat" 'cleanup retry must share the original success receipt'
  done
  pass 'direct merge failure survives ordinary cleanup and publishes once after ephemeral state disappears'
}

jira_help_center_offline_cleanup_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_JIRA_TIMEOUT
  local task_url tool
  export FM_HOME="$PR_TMP/help-center-offline" FM_JIRA_TIMEOUT=1
  export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
  mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"
  printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
  fm_git_init_commit "$FM_HOME/thanos"
  git -C "$FM_HOME/thanos" update-ref refs/remotes/origin/main HEAD
  git -C "$FM_HOME/thanos" worktree add --detach -q "$FM_HOME/task-tree" HEAD
  fm_write_meta "$FM_HOME/state/task-help.meta" 'window=firstmate:fm-task-help' \
    'endpoint_task_id=task-help' 'backend=tmux' "worktree=$FM_HOME/task-tree" \
    "project=$FM_HOME/thanos" 'branch=rcs/swvl-1234-docs' 'kind=ship' 'mode=no-mistakes'
  task_url=https://github.com/advisorfirst/help-center/pull/287
  fm_fake_exit0 "$PR_CODE/bin" fm-linear.sh fm-protected-paths.sh fm-fleet-sync.sh
  for tool in tmux treehouse; do fm_fake_exit0 "$PR_TMP/fakebin" "$tool"; done
  "$PR_CODE/bin/fm-pr-check.sh" task-help "$task_url" > "$PR_TMP/help-offline.register" 2>&1
  "$PR_CODE/bin/fm-jira.sh" merged "$task_url" > "$PR_TMP/help-offline.merged" 2>&1 \
    || fail 'help-center fixture must observe the merged PR before GitHub becomes unavailable'
  assert_grep 'issue|move|SWVL-1234|Done' "$JIRA_LOG" 'help-center fixture must complete the observed merge before cleanup'
  for tool in gh gh-axi; do
    cp "$PR_TMP/fakebin/$tool" "$PR_TMP/help-offline.$tool.saved"
    cat > "$PR_TMP/fakebin/$tool" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$FM_HOME/offline-gh.calls"
exit 97
FAKE
    chmod +x "$PR_TMP/fakebin/$tool"
    [ "$(command -v "$tool")" = "$PR_TMP/fakebin/$tool" ] \
      || fail "offline cleanup must resolve private unavailable $tool"
  done
  "$PR_CODE/bin/fm-jira.sh" cleanup task-help > "$PR_TMP/help-offline.cleanup" 2>&1 \
    || fail 'observed merged help-center cleanup must exit 0 while GitHub is unavailable'
  "$PR_CODE/bin/fm-teardown.sh" task-help > "$PR_TMP/help-offline.teardown" 2>&1 \
    || { cat "$PR_TMP/help-offline.teardown" >&2; fail 'observed merged help-center task removal must succeed while GitHub is unavailable'; }
  assert_absent "$FM_HOME/state/task-help.meta" 'offline help-center cleanup must remove task metadata'
  assert_absent "$FM_HOME/state/task-help.check.sh" 'offline help-center cleanup must remove the poll'
  assert_absent "$FM_HOME/offline-gh.calls" 'observed merged help-center cleanup must not query GitHub again'
  assert_absent "$FM_HOME/state/jira/github.com/advisorfirst/help-center/287/followups.owed" 'skipped help-center reminders must not acquire an obligation'
  drain_pr > "$PR_TMP/help-offline.wake"
  assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/help-offline.wake" 'offline help-center cleanup must keep skipped reminders silent'
  for tool in gh gh-axi; do cp "$PR_TMP/help-offline.$tool.saved" "$PR_TMP/fakebin/$tool"; done
  pass 'observed merged help-center task is removed offline without a reminder or another GitHub call'
}

jira_cleanup_completed_status_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_JIRA_TIMEOUT FM_TEST_GH_STATE
  local scenario task_url dir tool
  export FM_JIRA_TIMEOUT=1 FM_TEST_GH_STATE=MERGED
  for scenario in ${FM_JIRA_COMPLETED_SCENARIO:-external title direct pending}; do
    export FM_HOME="$PR_TMP/completed-$scenario"
    export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
    mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"
    printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
    fm_git_init_commit "$FM_HOME/thanos"
    git -C "$FM_HOME/thanos" update-ref refs/remotes/origin/main HEAD
    git -C "$FM_HOME/thanos" worktree add --detach -q "$FM_HOME/task-tree" HEAD
    fm_write_meta "$FM_HOME/state/task-completed.meta" 'window=firstmate:fm-task-completed' \
      'endpoint_task_id=task-completed' 'backend=tmux' "worktree=$FM_HOME/task-tree" \
      "project=$FM_HOME/thanos" 'branch=rcs/swvl-9996-completed' 'kind=ship' 'mode=no-mistakes'
    if [ "$scenario" = title ]; then
      sed 's@branch=.*@branch=generic@' "$FM_HOME/state/task-completed.meta" > "$PR_TMP/completed.meta"
      cp "$PR_TMP/completed.meta" "$FM_HOME/state/task-completed.meta"
    fi
    task_url=https://github.com/advisorfirst/thanos/pull/76
    dir="$FM_HOME/state/jira/github.com/advisorfirst/thanos/76"
    export JIRA_COMPLETED_CALLS="$PR_TMP/completed-$scenario.calls"
    : > "$JIRA_COMPLETED_CALLS"
    cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  'pr merge') printf 'fake merge succeeded\n' ;;
  'api /repos/advisorfirst/thanos/pulls/76')
    printf 'api_response:\n  body: fix SWVL-9996 completed\n  truncated: false\n' ;;
  *) exit 97 ;;
esac
FAKE
    cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
FAKE
    cp "$ROOT/bin/fm-jira.sh" "$PR_CODE/bin/fm-jira.sh"
    fm_fake_exit0 "$PR_CODE/bin" fm-linear.sh fm-protected-paths.sh fm-fleet-sync.sh
    for tool in tmux treehouse; do fm_fake_exit0 "$PR_TMP/fakebin" "$tool"; done
    chmod +x "$PR_TMP/fakebin/gh-axi" "$PR_TMP/fakebin/jira"
    for tool in gh gh-axi jira tmux treehouse; do
      [ -x "$PR_TMP/fakebin/$tool" ] && [ "$(command -v "$tool")" = "$PR_TMP/fakebin/$tool" ] \
        || fail "completed cleanup fixture must resolve executable fake $tool"
    done
    : > "$JIRA_LOG"
    if [ "$scenario" = pending ]; then mkdir "$FM_HOME/state/.wake-queue.seq"; fi
    if [ "$scenario" = direct ]; then
      "$PR_CODE/bin/fm-pr-merge.sh" task-completed "$task_url" > "$PR_TMP/completed-$scenario.merge" 2>&1
    else
      printf 'pr=%s\n' "$task_url" >> "$FM_HOME/state/task-completed.meta"
      [ "$(poll_pr 76 2> "$PR_TMP/completed-$scenario.merge.err")" = merged ] || fail 'completed status fixture must observe an external merge'
    fi
    assert_grep 'issue|move|SWVL-9996|Done' "$JIRA_LOG" 'completed status fixture must really move Jira before cleanup'
    assert_grep 'done' "$dir/transitions" 'completed status fixture must hold the existing Done receipt'
    if [ "$scenario" = pending ]; then
      assert_present "$dir/followups.owed" 'failed reminder publication must retain its obligation despite completed status'
      "$PR_CODE/bin/fm-jira.sh" transition task-completed in-review > "$PR_TMP/completed-review.out" 2> "$PR_TMP/completed-review.err"
      assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/completed-review.err" 'ordinary status events must not acquire cleanup reminder recovery'
      rmdir "$FM_HOME/state/.wake-queue.seq"
    fi
    cp "$PR_CODE/bin/fm-jira.sh" "$PR_CODE/bin/fm-jira-real.sh"
    cat > "$PR_CODE/bin/fm-jira.sh" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" != --attempt ] || printf 'jira-attempt\n' >> "$JIRA_COMPLETED_CALLS"
exec "$(dirname "$0")/fm-jira-real.sh" "$@"
FAKE
    cat > "$PR_CODE/bin/fm-linear.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'linear\n' >> "$JIRA_COMPLETED_CALLS"
printf 'LINEAR: unexpected completed status replay\n' >&2
FAKE
    cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
printf 'title-lookup\n' >> "$JIRA_COMPLETED_CALLS"
exit 1
FAKE
    chmod +x "$PR_CODE/bin/fm-jira.sh" "$PR_CODE/bin/fm-linear.sh" "$PR_TMP/fakebin/gh-axi"
    : > "$JIRA_LOG"
    "$PR_CODE/bin/fm-teardown.sh" task-completed > "$PR_TMP/completed-$scenario.cleanup" 2> "$PR_TMP/completed-$scenario.cleanup.err" \
      || fail 'completed status cleanup must succeed'
    assert_absent "$FM_HOME/state/task-completed.meta" 'completed status cleanup must remove task metadata'
    [ ! -s "$JIRA_COMPLETED_CALLS" ] || fail 'completed status cleanup must call neither Linear nor the Jira attempt or title lookup'
    [ ! -s "$JIRA_LOG" ] || fail 'completed status cleanup must not invoke Jira'
    assert_no_grep 'LINEAR:' "$PR_TMP/completed-$scenario.cleanup.err" 'completed status cleanup must not emit a Linear diagnostic'
    assert_no_grep 'JIRA: move' "$PR_TMP/completed-$scenario.cleanup.err" 'completed status cleanup must not emit a manual Jira diagnostic'
    assert_no_grep 'jira:' "$FM_HOME/state/.wake-queue" 'completed status cleanup must not queue a manual status wake'
    assert_grep "$task_url" "$dir/followups" 'completed status cleanup must publish its reminder before later retry'
    assert_absent "$dir/followups.owed" 'completed status cleanup must clear owed work after successful publication'
    "$PR_CODE/bin/fm-jira.sh" retry-followups
    drain_pr > "$PR_TMP/completed-$scenario.wake"
    [ "$(grep -c 'MERGE FOLLOW-UPS:' "$PR_TMP/completed-$scenario.wake")" = 1 ] || fail 'completed status cleanup must preserve exactly one reminder'
    assert_grep 'check MCP covers what changed' "$PR_TMP/completed-$scenario.wake" 'completed status cleanup must preserve MCP work'
    assert_grep 'update /help-center' "$PR_TMP/completed-$scenario.wake" 'completed status cleanup must preserve help-center work'
    assert_no_grep 'JIRA: move' "$PR_TMP/completed-$scenario.wake" 'completed status cleanup must not deliver a manual Jira wake'
    "$PR_CODE/bin/fm-jira.sh" retry-followups
    drain_pr > "$PR_TMP/completed-$scenario.repeat"
    assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/completed-$scenario.repeat" 'completed status retry must remain once per PR'
    cp "$ROOT/bin/fm-jira.sh" "$PR_CODE/bin/fm-jira.sh"
    pass "completed status cleanup replays no status work: $scenario"
  done
  fm_fake_exit0 "$PR_CODE/bin" fm-linear.sh
}

jira_cleanup_record_failure_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_JIRA_TIMEOUT FM_TEST_GH_STATE
  local scenario task_url dir tool cleanup_home
  local -a cleanup_args
  export FM_JIRA_TIMEOUT=1 FM_TEST_GH_STATE=MERGED
  # shellcheck source=bin/fm-wake-lib.sh
  . "$PR_CODE/bin/fm-wake-lib.sh"
  for scenario in ${FM_JIRA_RECORD_SCENARIO:-lock record repaired receipt open other lookup-failure child retirement}; do
    export FM_HOME="$PR_TMP/record-cleanup-$scenario"
    export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
    export FM_TEST_GH_STATE=MERGED
    mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"
    printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
    fm_git_init_commit "$FM_HOME/thanos"
    git -C "$FM_HOME/thanos" update-ref refs/remotes/origin/main HEAD
    git -C "$FM_HOME/thanos" worktree add --detach -q "$FM_HOME/task-tree" HEAD
    fm_write_meta "$FM_HOME/state/task-record.meta" 'window=firstmate:fm-task-record' \
      'endpoint_task_id=task-record' 'backend=tmux' "worktree=$FM_HOME/task-tree" \
      "project=$FM_HOME/thanos" 'branch=rcs/swvl-9995-record' 'kind=ship' 'mode=no-mistakes'
    task_url=https://github.com/advisorfirst/thanos/pull/75
    dir="$FM_HOME/state/jira/github.com/advisorfirst/thanos/75"
    cat > "$PR_TMP/fakebin/gh-axi" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = 'pr merge' ] || exit 97
printf 'fake merge succeeded\n'
FAKE
    cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
FAKE
    cp "$ROOT/bin/fm-linear.sh" "$PR_CODE/bin/fm-linear.sh"
    for tool in tmux treehouse; do fm_fake_exit0 "$PR_TMP/fakebin" "$tool"; done
    fm_fake_exit0 "$PR_CODE/bin" fm-protected-paths.sh fm-fleet-sync.sh
    chmod +x "$PR_TMP/fakebin/gh-axi" "$PR_TMP/fakebin/jira"
    for tool in gh gh-axi jira tmux treehouse; do
      [ -x "$PR_TMP/fakebin/$tool" ] && [ "$(command -v "$tool")" = "$PR_TMP/fakebin/$tool" ] \
        || fail "record cleanup fixture must resolve executable fake $tool"
    done
    mkdir -p "$dir"
    case "$scenario" in
      lock) fm_lock_try_acquire "$dir/followups.lock" || fail 'fixture must hold the actual reminder lock' ;;
      *) mkdir "$dir/followups.owed" ;;
    esac
    : > "$JIRA_LOG"
    "$PR_CODE/bin/fm-pr-merge.sh" task-record "$task_url" > "$PR_TMP/record-$scenario.merge" 2> "$PR_TMP/record-$scenario.err" \
      || fail 'failed obligation recording must preserve successful direct merge'
    assert_grep 'fake merge succeeded' "$PR_TMP/record-$scenario.merge" 'direct merge must retain its successful output'
    assert_no_grep 'issue|move|SWVL-9995|Done' "$JIRA_LOG" 'initial recording failure must defer Jira Done'
    assert_no_grep 'to Done yourself' "$PR_TMP/record-$scenario.err" 'initial recording failure must defer Linear Done'
    [ ! -f "$dir/followups.owed" ] || fail 'fixture must reproduce failure to establish the owed file'
    assert_absent "$dir/followups" 'initial recording failure must not acquire a publication receipt'
    assert_present "$FM_HOME/state/task-record.check.sh" 'failed merge recording must retain poll discovery'
    if [ "$scenario" = retirement ]; then
      # shellcheck source=bin/fm-pr-lib.sh
      . "$PR_CODE/bin/fm-pr-lib.sh"
      fm_pr_poll_snapshot_capture "$FM_HOME/state" task-record "$PR_CODE/bin/fm-pr-poll.sh" \
        || fail 'fixture must capture the canonical poll identity'
      fm_pr_poll_retirement_publish "$FM_HOME/state" task-record "$PR_CODE/bin/fm-pr-poll.sh" merged \
        || fail 'fixture must establish a valid pending retirement'
    fi
    cleanup_home=$FM_HOME
    cleanup_args=(task-record)
    if [ "$scenario" = child ]; then
      cleanup_home="$PR_TMP/record-parent"
      cleanup_args=(parent-record --force)
      mkdir -p "$cleanup_home/state" "$cleanup_home/data" "$cleanup_home/config"
      printf '%s\n' '- wms [no-mistakes]' > "$cleanup_home/data/projects.md"
      printf '%s\n' parent-record > "$FM_HOME/.fm-secondmate-home"
      fm_write_meta "$cleanup_home/state/parent-record.meta" 'window=firstmate:fm-parent-record' \
        'endpoint_task_id=parent-record' 'backend=tmux' "worktree=$FM_HOME" "home=$FM_HOME" "project=$PR_CODE" \
        'kind=secondmate' 'mode=no-mistakes'
    fi
    if [ "$scenario" = lock ] || [ "$scenario" = record ] || [ "$scenario" = lookup-failure ] || [ "$scenario" = child ] || [ "$scenario" = retirement ]; then
      if [ "$scenario" = lookup-failure ]; then
        cp "$PR_TMP/fakebin/gh" "$PR_TMP/record-gh.saved"
        printf '#!/usr/bin/env bash\nexit 1\n' > "$PR_TMP/fakebin/gh"
      fi
      if FM_HOME="$cleanup_home" FM_STATE_OVERRIDE="$cleanup_home/state" \
          FM_DATA_OVERRIDE="$cleanup_home/data" FM_CONFIG_OVERRIDE="$cleanup_home/config" \
          "$PR_CODE/bin/fm-teardown.sh" "${cleanup_args[@]}" > "$PR_TMP/record-$scenario.cleanup" 2> "$PR_TMP/record-$scenario.cleanup.err"; then
        fail 'cleanup must refuse when it cannot establish the merged reminder obligation'
      fi
      assert_grep 'could not establish merged PR follow-ups' "$PR_TMP/record-$scenario.cleanup.err" 'cleanup must reach the reminder ownership boundary'
      assert_present "$FM_HOME/state/task-record.meta" 'refused cleanup must preserve metadata discovery'
      assert_present "$FM_HOME/state/task-record.check.sh" 'refused cleanup must preserve poll discovery'
      assert_present "$FM_HOME/state/task-record.pr-poll" 'refused cleanup must preserve the canonical PR identity'
      assert_no_grep 'issue|move|SWVL-9995|Done' "$JIRA_LOG" 'refused cleanup must keep Jira Done deferred'
      assert_no_grep 'to Done yourself' "$PR_TMP/record-$scenario.cleanup.err" 'refused cleanup must keep Linear Done deferred'
    fi
    case "$scenario" in
      lock) fm_lock_release "$dir/followups.lock" ;;
      *) rmdir "${dir:?}/followups.owed" ;;
    esac
    case "$scenario" in
      receipt)
        "$PR_CODE/bin/fm-jira.sh" followups "$task_url"
        cp "$PR_TMP/fakebin/gh" "$PR_TMP/receipt-gh.saved"
        cat > "$PR_TMP/fakebin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/offline-gh.calls"
exit 1
FAKE
        chmod +x "$PR_TMP/fakebin/gh" ;;
      open) export FM_TEST_GH_STATE=OPEN ;;
      other) ln -s "$FM_HOME/thanos" "$FM_HOME/wms"; sed 's@/thanos$@/wms@' "$FM_HOME/state/task-record.meta" > "$PR_TMP/record-other.meta"; cp "$PR_TMP/record-other.meta" "$FM_HOME/state/task-record.meta" ;;
      lookup-failure) cp "$PR_TMP/record-gh.saved" "$PR_TMP/fakebin/gh" ;;
    esac
    "$PR_CODE/bin/fm-teardown.sh" task-record > "$PR_TMP/record-$scenario.recovery" 2> "$PR_TMP/record-$scenario.recovery.err" \
      || { cat "$PR_TMP/record-$scenario.recovery.err" >&2; fail 'repaired recording or existing successful receipt must permit normal cleanup'; }
    if [ "$scenario" = receipt ]; then
      assert_absent "$FM_HOME/offline-gh.calls" 'successful publication receipt must bypass every GitHub merge lookup'
      cp "$PR_TMP/receipt-gh.saved" "$PR_TMP/fakebin/gh"
    fi
    assert_absent "$FM_HOME/state/task-record.meta" 'successful cleanup must remove task metadata'
    assert_absent "$FM_HOME/state/task-record.check.sh" 'successful cleanup must remove the poll'
    "$PR_CODE/bin/fm-jira.sh" retry-followups
    drain_pr > "$PR_TMP/record-$scenario.wake"
    case "$scenario" in
      open|other)
        assert_absent "$dir/followups.owed" 'unmerged or other-project cleanup must not create owed work'
        assert_absent "$dir/followups" 'unmerged or other-project cleanup must not publish a reminder'
        assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/record-$scenario.wake" 'unmerged or other-project cleanup must stay silent'
        assert_no_grep 'issue|move|SWVL-9995|Done' "$JIRA_LOG" 'unmerged or other-project cleanup must not move Jira Done'
        assert_no_grep 'to Done yourself' "$PR_TMP/record-$scenario.recovery.err" 'unmerged or other-project cleanup must not move Linear Done' ;;
      *)
        if [ "$scenario" = record ]; then
          assert_grep 'LINEAR: no API key configured - move SWVL-9995 to Done yourself' "$PR_TMP/record-$scenario.recovery.err" 'failed owe recovery must replay deferred status through the existing Linear owner'
        fi
        [ "$(grep -c 'issue|move|SWVL-9995|Done' "$JIRA_LOG")" = 1 ] || fail 'cleanup recovery must perform deferred Jira Done once'
        assert_grep "$task_url" "$dir/followups" 'recovery must leave a successful URL-bearing publication receipt'
        assert_absent "$dir/followups.owed" 'successful publication must clear owed state'
        [ "$(grep -c 'MERGE FOLLOW-UPS:' "$PR_TMP/record-$scenario.wake")" = 1 ] || fail 'cleanup recovery must deliver both follow-ups once'
        assert_grep 'check MCP covers what changed unless explicitly skipped; put any MCP gap in a separate follow-up PR' "$PR_TMP/record-$scenario.wake" 'recording recovery must deliver the accepted MCP follow-up'
        assert_grep 'update /help-center with the change' "$PR_TMP/record-$scenario.wake" 'recording recovery must deliver the help-center follow-up'
        "$PR_CODE/bin/fm-jira.sh" followups "$task_url"
        drain_pr > "$PR_TMP/record-$scenario.repeat"
        assert_no_grep 'MERGE FOLLOW-UPS:' "$PR_TMP/record-$scenario.repeat" 'recovered recording must share the once-per-PR receipt' ;;
    esac
    if [ "$scenario" = open ] || [ "$scenario" = other ]; then
      cleanup_home="$PR_TMP/excluded-parent-$scenario"
      mkdir -p "$cleanup_home/state" "$cleanup_home/data" "$cleanup_home/config"
      printf '%s\n' excluded-sm > "$FM_HOME/.fm-secondmate-home"
      fm_write_meta "$cleanup_home/state/excluded-sm.meta" 'window=firstmate:fm-excluded-sm' \
        'endpoint_task_id=excluded-sm' 'backend=tmux' "worktree=$FM_HOME" "home=$FM_HOME" \
        "project=$PR_CODE" 'kind=secondmate' 'mode=secondmate'
      FM_HOME="$cleanup_home" FM_STATE_OVERRIDE="$cleanup_home/state" \
        FM_DATA_OVERRIDE="$cleanup_home/data" FM_CONFIG_OVERRIDE="$cleanup_home/config" \
        "$PR_CODE/bin/fm-teardown.sh" excluded-sm > "$PR_TMP/record-$scenario.parent-recovery" 2>&1 \
        || { cat "$PR_TMP/record-$scenario.parent-recovery" >&2; fail 'unmerged and other-project homes must retire without reminders'; }
      assert_absent "$FM_HOME" 'unmerged and other-project homes must remain removable'
    fi
    if [ "$scenario" = child ]; then
      FM_HOME="$cleanup_home" FM_STATE_OVERRIDE="$cleanup_home/state" \
        FM_DATA_OVERRIDE="$cleanup_home/data" FM_CONFIG_OVERRIDE="$cleanup_home/config" \
        "$PR_CODE/bin/fm-teardown.sh" "${cleanup_args[@]}" > "$PR_TMP/record-child.parent-recovery" 2>&1 \
        || { cat "$PR_TMP/record-child.parent-recovery" >&2; fail 'forced home removal must succeed after child reminder delivery'; }
      assert_absent "$FM_HOME" 'forced parent recovery must remove the delivered child home'
    fi
    pass "failed obligation establishment, normal cleanup and retry: $scenario"
  done
  fm_fake_exit0 "$PR_CODE/bin" fm-linear.sh
}

jira_owed_contract_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_JIRA_TIMEOUT FM_TEST_GH_STATE
  local dir tool scenario
  export FM_JIRA_TIMEOUT=1 FM_TEST_GH_STATE=MERGED
  for scenario in ${FM_JIRA_CONTRACT_SCENARIO:-external direct record-failure direct-record-failure receipt-failure empty-receipt}; do
    export FM_HOME="$PR_TMP/contract-$scenario"
    export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
    mkdir -p "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/config"
    printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
    write_pr_task task-contract 'project=/projects/thanos' 'branch=rcs/swvl-9994-contract'
    printf 'pr=%s\n' https://github.com/advisorfirst/thanos/pull/74 >> "$FM_HOME/state/task-contract.meta"
    dir="$FM_HOME/state/jira/github.com/advisorfirst/thanos/74"
    mkdir -p "$dir"
    export JIRA_CONTRACT_DIR="$dir" JIRA_CONTRACT_LOG="$PR_TMP/contract-$scenario.log"
    : > "$JIRA_CONTRACT_LOG"
    cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
if [ "$4" = Done ]; then
  [ -f "$JIRA_CONTRACT_DIR/followups.owed" ] || [ -f "$JIRA_CONTRACT_DIR/followups" ] || printf 'jira-before-owed\n' >> "$JIRA_CONTRACT_LOG"
  printf 'jira-done\n' >> "$JIRA_CONTRACT_LOG"
fi
FAKE
    cat > "$PR_CODE/bin/fm-linear.sh" <<'FAKE'
#!/usr/bin/env bash
if [ "$3" = done ]; then
  [ -f "$JIRA_CONTRACT_DIR/followups.owed" ] || [ -f "$JIRA_CONTRACT_DIR/followups" ] || printf 'linear-before-owed\n' >> "$JIRA_CONTRACT_LOG"
  printf 'linear-done\n' >> "$JIRA_CONTRACT_LOG"
fi
FAKE
    chmod +x "$PR_TMP/fakebin/jira" "$PR_CODE/bin/fm-linear.sh"
    for tool in gh gh-axi jira; do
      [ -x "$PR_TMP/fakebin/$tool" ] && [ "$(command -v "$tool")" = "$PR_TMP/fakebin/$tool" ] \
        || fail "contract fixture must resolve executable fake $tool"
    done
    case "$scenario" in
      empty-receipt) : > "$dir/followups"; mkdir "$FM_HOME/state/.wake-queue.seq" ;;
      external|direct) mkdir "$FM_HOME/state/.wake-queue.seq" ;;
      record-failure|direct-record-failure) mkdir "$dir/followups.owed" ;;
      receipt-failure) mkdir "$dir/followups" ;;
    esac
    if [ "$scenario" = direct ] || [ "$scenario" = direct-record-failure ]; then
      "$PR_CODE/bin/fm-pr-merge.sh" task-contract https://github.com/advisorfirst/thanos/pull/74 > "$PR_TMP/contract-$scenario.out" 2> "$PR_TMP/contract-$scenario.err"
    else
      poll_pr 74 > "$PR_TMP/contract-$scenario.out" 2> "$PR_TMP/contract-$scenario.err"
      [ "$(cat "$PR_TMP/contract-$scenario.out")" = merged ] || fail 'owed recording must preserve exact merged output'
    fi
    if [ "$scenario" = record-failure ] || [ "$scenario" = direct-record-failure ]; then
      assert_no_grep '-done' "$JIRA_CONTRACT_LOG" 'Done must not run if the owed reminder could not be recorded'
    else
      assert_no_grep 'before-owed' "$JIRA_CONTRACT_LOG" 'owed reminder must exist before any Done status move'
      [ -f "$dir/followups.owed" ] || fail 'unpublished reminder must remain owed until a successful publication receipt'
      if [ "$scenario" = receipt-failure ]; then
        rmdir "$dir/followups"
      else
        rmdir "$FM_HOME/state/.wake-queue.seq"
      fi
      "$PR_CODE/bin/fm-jira.sh" followups https://github.com/advisorfirst/thanos/pull/74
      [ -f "$dir/followups" ] || fail 'repaired receipt must publish successfully'
      assert_absent "$dir/followups.owed" 'only a successful publication receipt clears the owed reminder'
    fi
  done
  fm_fake_exit0 "$PR_CODE/bin" fm-linear.sh
  pass 'owed reminders precede status work and survive recording or receipt failure'
}

jira_publication_lock_regression() {
  local FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_JIRA_TIMEOUT FM_TEST_GH_STATE
  export FM_HOME="$PR_TMP/lock-home" FM_JIRA_TIMEOUT=1 FM_TEST_GH_STATE=MERGED
  export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
  unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  mkdir -p "$FM_HOME/state" "$FM_HOME/data"
  printf '%s\n' '- thanos [no-mistakes]' > "$FM_HOME/data/projects.md"
  cat > "$PR_TMP/fakebin/jira" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "$@" >> "$JIRA_LOG"
FAKE
  chmod +x "$PR_TMP/fakebin/jira"
  write_pr_task task-lock 'project=/projects/thanos' 'branch=rcs/swvl-9991-lock'
  "$PR_CODE/bin/fm-pr-check.sh" task-lock https://github.com/advisorfirst/thanos/pull/71 > /dev/null 2>&1
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$FM_HOME/state/z-stop.check.sh"
  chmod 0700 "$FM_HOME/state/z-stop.check.sh"
  "$PR_CODE/bin/fm-check-register.sh" z-stop > /dev/null
  export JIRA_TIMEOUT_NOTICE="$PR_TMP/timeout-notice" JIRA_TIMEOUT_RESUME="$PR_TMP/timeout-resume"
  mkfifo "$JIRA_TIMEOUT_NOTICE" "$JIRA_TIMEOUT_RESUME"
  cat > "$PR_TMP/fakebin/timeout" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" != --kill-after=1 ] || shift
budget=$1
shift
rc=0
perl -e 'my $t=shift; my $pid=fork; die unless defined $pid; if (!$pid) { setpgrp(0,0); exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", -$pid; select undef,undef,undef,0.2; kill "KILL", -$pid; waitpid $pid,0; exit 124 }; alarm $t; waitpid $pid,0; exit($? >> 8)' "$budget" "$@" || rc=$?
if [ "$rc" -eq 124 ]; then
  printf 'timed-out\n' > "$JIRA_TIMEOUT_NOTICE"
  read -r _ < "$JIRA_TIMEOUT_RESUME"
fi
exit "$rc"
FAKE
  chmod +x "$PR_TMP/fakebin/timeout"
  export JIRA_REAL_SLEEP
  JIRA_REAL_SLEEP=$(command -v sleep)
  cat > "$PR_TMP/fakebin/sleep" <<'FAKE'
#!/usr/bin/env bash
case "$(ps -p "$PPID" -o command=)" in
  */bin/fm-watch.sh*)
    printf 'terminal-queue\n' > "$JIRA_TIMEOUT_NOTICE"
    read -r _ < "$JIRA_TIMEOUT_RESUME" ;;
esac
exec "$JIRA_REAL_SLEEP" "$@"
FAKE
  chmod +x "$PR_TMP/fakebin/sleep"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$PR_CODE/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$FM_WAKE_QUEUE_LOCK" || fail 'fixture must hold the real shared queue lock'
  queue_owner=$FM_LOCK_OWNER_DIR
  FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=8 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    "$PR_CODE/bin/fm-watch.sh" > "$PR_TMP/lock-watch.out" 2> "$PR_TMP/lock-watch.err" &
  watcher=$!
  read -r notice < "$JIRA_TIMEOUT_NOTICE"
  [ "$notice" = timed-out ] || fail 'fixture must observe a real bounded publication timeout'
  printf 'resume\n' > "$JIRA_TIMEOUT_RESUME"
  read -r notice < "$JIRA_TIMEOUT_NOTICE"
  case "$notice" in
    timed-out|terminal-queue) ;;
    *) fail 'fixture must hold contention through the terminal publication boundary' ;;
  esac
  fm_lock_points_to_owner "$FM_WAKE_QUEUE_LOCK" "$queue_owner" || fail 'timeout must preserve the live queue owner'
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  printf 'resume\n' > "$JIRA_TIMEOUT_RESUME"
  wait "$watcher" || fail 'watcher must finish its sweep after queue contention clears'
  receipt="$FM_HOME/state/jira/github.com/advisorfirst/thanos/71/followups"
  if [ ! -f "$receipt" ]; then
    [ -f "$FM_HOME/state/task-lock.check.sh" ] && [ -f "$FM_HOME/state/task-lock.pr-poll-registration" ] \
      || fail 'terminal poll must remain registered when its reminder was not durably published'
    assert_no_grep 'task-lock.check.sh: merged' "$PR_TMP/lock-watch.out" 'an unpublished reminder must not acknowledge terminal merge'
  fi
  assert_grep 'issue|move|SWVL-9991|Done' "$JIRA_LOG" 'queue contention must not block independent Jira Done'
  FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=8 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    "$PR_CODE/bin/fm-watch.sh" > "$PR_TMP/lock-retry.out" 2> "$PR_TMP/lock-retry.err"
  [ -f "$receipt" ] || fail 'next watcher sweep must durably publish the reminder'
  assert_absent "$FM_HOME/state/task-lock.check.sh" 'successful publication must allow terminal poll retirement'
  drain_pr > "$PR_TMP/lock-wake"
  [ "$(grep -c 'MERGE FOLLOW-UPS: https://github.com/advisorfirst/thanos/pull/71' "$PR_TMP/lock-wake")" = 1 ] || fail 'contention recovery must deliver one reminder'
  assert_grep 'check MCP covers what changed' "$PR_TMP/lock-wake" 'recovered reminder must retain MCP coverage'
  assert_grep 'update /help-center' "$PR_TMP/lock-wake" 'recovered reminder must retain help-center work'
  [ "$(grep -c 'issue|move|SWVL-9991|Done' "$JIRA_LOG")" = 1 ] || fail 'watcher retry must not repeat Jira Done'
  pass 'real watcher retains a timed-out reminder poll then publishes once before retirement'
}

case "${FM_JIRA_TEST_CASE:-all}" in
  all) jira_help_center_offline_cleanup_regression; jira_cleanup_completed_status_regression; jira_cleanup_record_failure_regression; jira_cleanup_regression; jira_owed_contract_regression; jira_ordering_regression; jira_deadline_regressions; jira_installed_deadlines; jira_publication_write_regression; jira_publication_lock_regression ;;
  contract) jira_owed_contract_regression ;;
  cleanup) jira_cleanup_regression ;;
  completed-cleanup) jira_cleanup_completed_status_regression ;;
  record-cleanup) jira_cleanup_record_failure_regression ;;
  publication-write) jira_publication_write_regression ;;
  publication-lock) jira_publication_lock_regression ;;
  ordering) jira_ordering_regression ;;
  deadline) jira_deadline_regressions ;;
  installed) jira_installed_deadlines ;;
esac

[ ! -s "$JIRA_DENIED_LOG" ] || fail "a service CLI escaped the private fake inventory: $(cat "$JIRA_DENIED_LOG")"
