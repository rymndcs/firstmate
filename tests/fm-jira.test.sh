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
